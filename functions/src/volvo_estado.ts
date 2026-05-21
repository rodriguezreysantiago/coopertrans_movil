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
/**
 * Quita null/undefined y arrays vacíos de un objeto. CLAVE para el `merge:true`:
 * la flota Vecchi manda el snapshot por CONTENIDO (un poll trae SNAPSHOT, otro
 * UPTIME) → si escribiéramos `tell_tales:[]` cuando no vino, borraríamos los
 * 44 testigos que capturó el poll anterior. Omitir = preservar último conocido.
 * Mantiene `false` y `0` (son significativos: velocidad 0, motor apagado).
 */
function limpiarNulos(o: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, val] of Object.entries(o)) {
    if (val === null || val === undefined) continue;
    if (Array.isArray(val) && val.length === 0) continue;
    out[k] = val;
  }
  return out;
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
  /** engineSpeed>0 ⇒ encendido; si no viene, speed>0 ⇒ encendido; else null. */
  motor_encendido: boolean | null;
  /**
   * driver1WorkingState del tacógrafo (DRIVE/WORK/REST/DRIVE_AVAILABLE/…). Viene
   * en CADA snapshot de la flota Vecchi — señal directa para el vigilador de
   * jornada (#36), más fiable que inferir manejo/pausa por posición.
   */
  conductor_estado: string | null;
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
    // engineSpeed casi nunca viene (3/53). Fallback: si hay velocidad > 0 el
    // motor está encendido. Con velocidad 0 NO afirmamos apagado (puede estar
    // ralentí parado) → null.
    motor_encendido:
      engineSpeed != null
        ? engineSpeed > 0
        : speed != null && speed > 0
          ? true
          : null,
    conductor_estado: asStr(snap?.driver1WorkingState),
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

// ─── fetch helper (3 reintentos con backoff) ─────────────────────────────────
/**
 * GET a `vehiclestatuses` con 3 reintentos. Devuelve el array
 * `vehicleStatuses` o [] si falló. `etiqueta` distingue las consultas en logs.
 */
async function fetchStatuses(
  url: string,
  authHeader: string,
  etiqueta: string
): Promise<unknown[]> {
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
          etiqueta,
          statusCode: res.status,
          intento: intentos,
        });
        if (intentos >= 3) return [];
        await new Promise((r) => setTimeout(r, 5000 * intentos));
        continue;
      }
      const body = (await res.json()) as Record<string, unknown>;
      const sr = body?.vehicleStatusResponse as
        | Record<string, unknown>
        | undefined;
      if (Array.isArray(sr?.vehicleStatuses)) {
        return sr!.vehicleStatuses as unknown[];
      }
      return [];
    } catch (e) {
      logger.warn("[estadoVolvo] error consultando Volvo", {
        etiqueta,
        error: (e as Error).message,
        intento: intentos,
      });
      if (intentos >= 3) return [];
      await new Promise((r) => setTimeout(r, 5000 * intentos));
    }
  }
  return [];
}

// ─── poller ──────────────────────────────────────────────────────────────────
export const estadoVolvoPoller = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [volvoUsername, volvoPassword],
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async () => {
    const authHeader =
      "Basic " +
      Buffer.from(
        `${volvoUsername.value()}:${volvoPassword.value()}`
      ).toString("base64");

    // Consulta 1 — estado general (posición/velocidad/combustible/odo/horas).
    const qs = new URLSearchParams({
      latestOnly: "true",
      contentFilter: "ACCUMULATED,SNAPSHOT,UPTIME",
      additionalContent: "VOLVOGROUPSNAPSHOT",
    });
    const cache = await fetchStatuses(
      `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`,
      authHeader,
      "estado"
    );

    if (cache.length === 0) {
      logger.warn("[estadoVolvo] flota Volvo vacía, abortando");
      return;
    }

    // Consulta 2 — SOLO UPTIME (testigos del tablero + serviceDistance + temp).
    // Con `latestOnly` el record más nuevo por unidad suele ser SNAPSHOT y NO
    // trae `tellTaleInfo` (sólo 2/53). Pidiendo UPTIME explícito forzamos el
    // último record de uptime de cada unidad → advertencias EXACTAS de toda la
    // flota para mantenimiento (#43). Ver project_volvo_estado_fundacion.md.
    const qsUptime = new URLSearchParams({
      latestOnly: "true",
      contentFilter: "UPTIME",
    });
    const cacheUptime = await fetchStatuses(
      `${VOLVO_BASE}/vehicle/vehiclestatuses?${qsUptime.toString()}`,
      authHeader,
      "uptime"
    );
    // VIN → {tell_tales, service_distance_km, temp_motor_c} del record UPTIME.
    const uptimePorVin = new Map<
      string,
      Pick<EstadoVolvo, "tell_tales" | "service_distance_km" | "temp_motor_c">
    >();
    let conTellTales = 0;
    for (const raw of cacheUptime) {
      const e = parseEstadoVolvo(raw);
      if (!e) continue;
      uptimePorVin.set(e.vin, {
        tell_tales: e.tell_tales,
        service_distance_km: e.service_distance_km,
        temp_motor_c: e.temp_motor_c,
      });
      if (e.tell_tales.length > 0) conTellTales++;
    }
    logger.info("[estadoVolvo] uptime", {
      recibidosUptime: cacheUptime.length,
      conTellTales,
    });

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
      // Overlay de la consulta UPTIME: testigos + service + temp del record
      // de uptime (más fiable que lo que trajo el record de estado, que casi
      // nunca incluye uptimeData). limpiarNulos + merge preservan lo previo.
      const up = uptimePorVin.get(est.vin);
      if (up) {
        if (up.tell_tales.length > 0) est.tell_tales = up.tell_tales;
        if (up.service_distance_km != null) {
          est.service_distance_km = up.service_distance_km;
        }
        if (up.temp_motor_c != null) est.temp_motor_c = up.temp_motor_c;
      }
      batch.set(
        db.collection("VOLVO_ESTADO").doc(patente),
        {
          patente,
          ...limpiarNulos(est as unknown as Record<string, unknown>),
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
