/**
 * Poller Volvo "estado en vivo" → colección `VOLVO_ESTADO/{patente}`.
 *
 * FUNDACIÓN del plan Volvo (2026-05-21). Cada 5 min trae el snapshot completo
 * de `vehiclestatuses` (rFMS VOLVOGROUPSNAPSHOT) y guarda por unidad todo lo
 * que hoy desperdiciábamos: posición, velocidad (tacógrafo), ignición/motor,
 * el **timestamp REAL del reporte del equipo** (clave para el vigilador de
 * jornada), combustible/AdBlue/autonomía, odómetro, **horas de motor**,
 * **peso por eje** y los **tell-tales exactos** (testigos del tablero).
 *
 * NO toca nada existente — es una colección nueva. Alimenta:
 *   - #36 jornada (staleness con el timestamp real, no `consultado_en`)
 *   - #43 advertencias exactas para mantenimiento (tell-tales)
 *   - #44 service por horas de motor
 *   - #46 control de carga (peso por eje)
 *   - #47 telemetría en vivo (fuel/AdBlue/autonomía frescos)
 *
 * El parser `parseEstadoVolvo` es PURO (sin I/O) → testeable. Los paths rFMS
 * se prueban defensivamente (varios candidatos + null) igual que en
 * telemetria.ts; el poller loguea una MUESTRA del primer vehículo para
 * verificar la estructura real de la flota Vecchi post-deploy.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { FieldValue } from "firebase-admin/firestore";

import { db } from "./setup";
import { fetchWithTimeout } from "./comun";
import {
  volvoUsername,
  volvoPassword,
  VOLVO_BASE,
  ACCEPT_STATUSES,
} from "./volvo";

// ─── helpers de parseo defensivo ────────────────────────────────────────────
function asNum(v: unknown): number | null {
  if (v == null) return null;
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}
function asObj(v: unknown): Record<string, unknown> | undefined {
  return v && typeof v === "object" ? (v as Record<string, unknown>) : undefined;
}
function asStr(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

export interface TellTale {
  id: string;
  estado: string;
}

export interface EstadoVolvo {
  vin: string;
  lat: number | null;
  lng: number | null;
  /** km/h — preferencia tachographSpeed > wheelBasedSpeed > gnss.speed. */
  speed_kmh: number | null;
  heading: number | null;
  /** engineSpeed (rpm) > 0 ⇒ motor encendido. null si el campo no viene. */
  motor_encendido: boolean | null;
  /** TIMESTAMP REAL en que el equipo reportó la posición (ISO). Clave jornada. */
  posicion_ts: string | null;
  /** Timestamp del snapshot (created/received). */
  snapshot_ts: string | null;
  odometro_km: number | null;
  horas_motor: number | null;
  combustible_pct: number | null;
  adblue_pct: number | null;
  autonomia_km: number | null;
  /** Pesos por eje en toneladas (si la flota los transmite). */
  peso_eje_t: number[] | null;
  peso_total_t: number | null;
  temp_motor_c: number | null;
  /** Testigos del tablero EXACTOS (para el parte a mantenimiento). */
  tell_tales: TellTale[];
  service_distance_km: number | null;
}

/**
 * Parsea un `vehicleStatuses[i]` (rFMS, additionalContent=VOLVOGROUPSNAPSHOT)
 * al estado que persistimos. PURO. Devuelve null si no hay VIN.
 */
export function parseEstadoVolvo(raw: unknown): EstadoVolvo | null {
  const v = asObj(raw);
  if (!v) return null;
  const vin = (v.vin ?? "").toString().trim().toUpperCase();
  if (!vin) return null;

  const snap = asObj(v.snapshotData);
  const vgs = asObj(snap?.volvoGroupSnapshot);
  const uptime = asObj(v.uptimeData);
  const gnss = asObj(snap?.gnssPosition) ?? asObj(vgs?.gnssPosition);

  const speed =
    asNum(snap?.tachographSpeed) ??
    asNum(snap?.wheelBasedSpeed) ??
    asNum(gnss?.speed);
  const engineSpeed = asNum(snap?.engineSpeed);

  // Tell-tales: uptimeData.tellTaleInfo[] = [{tellTale, status}].
  const tellTales: TellTale[] = [];
  const tti = uptime?.tellTaleInfo ?? snap?.tellTaleInfo;
  if (Array.isArray(tti)) {
    for (const t of tti) {
      const to = asObj(t);
      if (!to) continue;
      const id = (to.tellTale ?? to.id ?? "").toString();
      const estado = (to.status ?? to.state ?? "").toString();
      if (id) tellTales.push({ id, estado });
    }
  }

  // Peso por eje: snapshotData.axleWeight[] (kg) — paths posibles.
  let pesoEje: number[] | null = null;
  const aw = snap?.axleWeight ?? snap?.axleWeights ?? vgs?.axleWeight;
  if (Array.isArray(aw)) {
    const pesos = aw
      .map((x) => {
        const xo = asObj(x);
        const kg = asNum(xo?.weight ?? xo?.axleWeight ?? x);
        return kg != null ? kg / 1000 : null;
      })
      .filter((p): p is number => p != null);
    if (pesos.length > 0) pesoEje = pesos;
  }

  const odoM = asNum(v.hrTotalVehicleDistance) ?? asNum(v.lastKnownOdometer);
  const edt =
    asObj(vgs?.estimatedDistanceToEmpty) ??
    asObj(snap?.estimatedDistanceToEmpty);
  const autonM = asNum(edt?.fuel) ?? asNum(edt?.total);
  const serviceM = asNum(uptime?.serviceDistance) ?? asNum(v.serviceDistance);
  const pesoTotalKg =
    asNum(v.grossCombinationVehicleWeight) ??
    asNum(snap?.grossCombinationVehicleWeight);

  return {
    vin,
    lat: asNum(gnss?.latitude),
    lng: asNum(gnss?.longitude),
    speed_kmh: speed,
    heading: asNum(gnss?.heading),
    motor_encendido: engineSpeed != null ? engineSpeed > 0 : null,
    posicion_ts: asStr(gnss?.positionDateTime),
    snapshot_ts: asStr(v.createdDateTime) ?? asStr(v.receivedDateTime),
    odometro_km: odoM != null ? odoM / 1000 : null,
    horas_motor:
      asNum(v.totalEngineHours) ?? asNum(snap?.engineTotalHoursOfOperation),
    combustible_pct:
      asNum(snap?.fuelLevel1) ?? asNum(snap?.fuelLevel) ?? asNum(v.fuelLevel1),
    adblue_pct:
      asNum(snap?.catalystFuelLevel) ??
      asNum(snap?.defLevel) ??
      asNum(snap?.adblueLevel),
    autonomia_km: autonM != null ? autonM / 1000 : null,
    peso_eje_t: pesoEje,
    peso_total_t: pesoTotalKg != null ? pesoTotalKg / 1000 : null,
    temp_motor_c:
      asNum(uptime?.engineCoolantTemperature) ??
      asNum(snap?.engineCoolantTemperature),
    tell_tales: tellTales,
    service_distance_km: serviceM != null ? serviceM / 1000 : null,
  };
}

// ─── poller ──────────────────────────────────────────────────────────────────
export const estadoVolvoPoller = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [volvoUsername, volvoPassword],
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    const authHeader =
      "Basic " +
      Buffer.from(
        `${volvoUsername.value()}:${volvoPassword.value()}`
      ).toString("base64");

    const qs = new URLSearchParams({
      latestOnly: "true",
      contentFilter: "ACCUMULATED,SNAPSHOT,UPTIME",
      additionalContent: "VOLVOGROUPSNAPSHOT",
    });
    const url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;

    let cache: unknown[] = [];
    let intentos = 0;
    while (intentos < 3) {
      intentos++;
      try {
        const res = await fetchWithTimeout(url, {
          method: "GET",
          headers: { "Authorization": authHeader, "Accept": ACCEPT_STATUSES },
        });
        if (!res.ok) {
          logger.warn("[estadoVolvo] Volvo HTTP error", {
            statusCode: res.status,
            intento: intentos,
          });
          if (intentos >= 3) return;
          await new Promise((r) => setTimeout(r, 5000 * intentos));
          continue;
        }
        const body = (await res.json()) as Record<string, unknown>;
        const sr = body?.vehicleStatusResponse as
          | Record<string, unknown>
          | undefined;
        if (Array.isArray(sr?.vehicleStatuses)) cache = sr!.vehicleStatuses;
        break;
      } catch (e) {
        logger.warn("[estadoVolvo] error consultando Volvo", {
          error: (e as Error).message,
          intento: intentos,
        });
        if (intentos >= 3) return;
        await new Promise((r) => setTimeout(r, 5000 * intentos));
      }
    }

    if (cache.length === 0) {
      logger.warn("[estadoVolvo] flota Volvo vacía, abortando");
      return;
    }

    // MUESTRA para verificar la estructura real (se quita tras confirmar paths).
    try {
      const s0 = asObj(cache[0]);
      const snap0 = asObj(s0?.snapshotData);
      logger.info("[estadoVolvo] muestra estructura", {
        topKeys: s0 ? Object.keys(s0) : [],
        snapKeys: snap0 ? Object.keys(snap0) : [],
        uptimeKeys: asObj(s0?.uptimeData)
          ? Object.keys(asObj(s0?.uptimeData)!)
          : [],
        gnssKeys: asObj(snap0?.gnssPosition)
          ? Object.keys(asObj(snap0?.gnssPosition)!)
          : [],
        parsedSample: parseEstadoVolvo(cache[0]),
      });
    } catch {
      // best-effort
    }

    // VIN → patente
    const vehiculosSnap = await db.collection("VEHICULOS").limit(5000).get();
    const vinToPatente = new Map<string, string>();
    for (const doc of vehiculosSnap.docs) {
      const vin = (doc.data().VIN ?? "").toString().trim().toUpperCase();
      if (vin && vin !== "-") vinToPatente.set(vin, doc.id);
    }

    const batch = db.batch();
    let escritos = 0;
    let sinVin = 0;
    let sinPatente = 0;
    for (const raw of cache) {
      const est = parseEstadoVolvo(raw);
      if (!est) {
        sinVin++;
        continue;
      }
      const patente = vinToPatente.get(est.vin);
      if (!patente) {
        sinPatente++;
        continue;
      }
      batch.set(
        db.collection("VOLVO_ESTADO").doc(patente),
        {
          patente,
          ...est,
          consultado_en: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      escritos++;
    }

    await batch.commit();
    logger.info("[estadoVolvo] OK", {
      recibidos: cache.length,
      escritos,
      sinVin,
      sinPatente,
      vinesEnFirestore: vinToPatente.size,
    });
  }
);
