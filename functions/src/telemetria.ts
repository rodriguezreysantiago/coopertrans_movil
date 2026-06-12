/**
 * Cloud Function de telemetría — `telemetriaSnapshotScheduled`.
 *
 * Extraído de index.ts (refactor split 2026-05-19). Cron cada 6h que
 * pega a Volvo `/vehicle/vehiclestatuses`, cruza VIN→patente con
 * VEHICULOS y escribe un snapshot idempotente por día y patente a
 * TELEMETRIA_HISTORICO (via Admin SDK, para cerrar la rule a write:false).
 *
 * Depende de la infra de Volvo (secrets + VOLVO_BASE + ACCEPT_STATUSES,
 * importados de volvo.ts) + fetchWithTimeout (comun.ts). Re-exportado
 * desde index con `export * from "./telemetria"`.
 */

import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";
import { fetchWithTimeout,
  onScheduleConLatido,
} from "./comun";
import {
  volvoUsername,
  volvoPassword,
  VOLVO_BASE,
  ACCEPT_STATUSES,
} from "./volvo";

// ============================================================================
// telemetriaSnapshotScheduled
// ============================================================================
// Scheduled function que cada 6 horas:
//   1) Llama Volvo `/vehicle/vehicles` con secrets server-side.
//   2) Cruza con la colección VEHICULOS para mapear VIN → patente.
//   3) Escribe un snapshot idempotente por día y patente en
//      TELEMETRIA_HISTORICO (id `{patente}_{YYYY-MM-DD}`).
//
// Reemplaza la lógica que antes corría en el cliente Flutter
// (`AutoSyncService` → `VehiculoRepository.guardarSnapshotsDiarios`).
// Vivir server-side permite:
//   - Cerrar `TELEMETRIA_HISTORICO` con `write: if false` en las rules
//     (solo Admin SDK puede escribir).
//   - Que el snapshot se capture aún cuando ningún admin tenga la app
//     abierta.
//
// Frecuencia: cada 6 horas. El doc es idempotente por día, con lo cual
// múltiples corridas se sobreescriben. La frecuencia da resiliencia
// ante fallos puntuales sin generar costos significativos (4 calls
// Volvo + 4 batch writes por día).

export const telemetriaSnapshotScheduled = onScheduleConLatido(
  "telemetriaSnapshotScheduled",
  {
    schedule: "every 6 hours",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [volvoUsername, volvoPassword],
    // Bajado de 120s a 45s. La function hace fetch a Volvo + batch
    // write a Firestore. Ambas operaciones nunca tardaron mas de 20s
    // en operacion normal; 45s deja margen para latencia alta sin
    // pagar 75s de invocacion innecesarios.
    timeoutSeconds: 45,
    memory: "256MiB",
  },
  async () => {
    logger.info("[telemetriaSnapshot] iniciando ciclo");

    // ─── 1. Fetch flota Volvo ──────────────────────────────────────
    const authHeader = "Basic " + Buffer.from(
      `${volvoUsername.value()}:${volvoPassword.value()}`
    ).toString("base64");

    // El endpoint `/vehicle/vehicles` NO trae telemetría (solo metadata
    // como vin/marca/modelo). Para `accumulatedData.totalFuelConsumption`
    // y `hrTotalVehicleDistance` hay que pegarle a `/vehicle/vehiclestatuses`
    // con `latestOnly=true` (devuelve el último snapshot de cada unidad
    // en una sola request).
    // Bug M5 del code review: antes el fetch a Volvo se hacía una sola
    // vez. Si fallaba transient (timeout, glitch del API, latencia)
    // perdíamos el snapshot del día. Ahora hacemos hasta 3 intentos
    // con backoff exponencial (5s, 15s) antes de abortar.
    const qs = new URLSearchParams({
      latestOnly: "true",
      contentFilter: "ACCUMULATED,SNAPSHOT,UPTIME",
      additionalContent: "VOLVOGROUPSNAPSHOT",
    });
    const url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;

    let cache: unknown[] = [];
    let intentos = 0;
    const maxIntentos = 3;

    while (intentos < maxIntentos) {
      intentos++;
      try {
        const res = await fetchWithTimeout(url, {
          method: "GET",
          headers: {
            "Authorization": authHeader,
            "Accept": ACCEPT_STATUSES,
          },
        });
        if (!res.ok) {
          logger.warn("[telemetriaSnapshot] Volvo HTTP error", {
            statusCode: res.status,
            intento: intentos,
          });
          if (intentos >= maxIntentos) return;
          await new Promise((r) => setTimeout(r, 5000 * intentos));
          continue;
        }
        const body = (await res.json()) as Record<string, unknown>;
        const statusResponse = body?.vehicleStatusResponse as
          | Record<string, unknown>
          | undefined;
        const list = statusResponse?.vehicleStatuses;
        if (Array.isArray(list)) cache = list;
        logger.info("[telemetriaSnapshot] estados recibidos", {
          recibidos: cache.length,
          intento: intentos,
          sampleKeys: cache.length > 0 ?
            Object.keys(cache[0] as object).slice(0, 20) :
            [],
        });
        break;
      } catch (e) {
        logger.warn("[telemetriaSnapshot] error consultando Volvo", {
          error: (e as Error).message,
          intento: intentos,
        });
        if (intentos >= maxIntentos) {
          logger.error("[telemetriaSnapshot] agotados los reintentos");
          return;
        }
        await new Promise((r) => setTimeout(r, 5000 * intentos));
      }
    }

    if (cache.length === 0) {
      logger.warn("[telemetriaSnapshot] flota Volvo vacía después de los reintentos, abortando");
      return;
    }

    // ─── 2. Map VIN → patente desde Firestore ──────────────────────
    // .limit(5000) defensivo: la flota Vecchi tiene ~127 vehículos
    // (57 tractores + 70 enganches), pero un cap explícito evita
    // sorpresas si en el futuro alguien duplica la colección o un
    // import malformado infla docs. 5000 = 40x growth ceiling.
    const vehiculosSnap = await db.collection("VEHICULOS").limit(5000).get();
    const vinToPatente = new Map<string, string>();
    for (const doc of vehiculosSnap.docs) {
      const data = doc.data();
      const vin = (data.VIN ?? "").toString().trim().toUpperCase();
      if (vin && vin !== "-") {
        vinToPatente.set(vin, doc.id);
      }
    }

    // ─── 3. Fecha del snapshot (midnight ARG) ──────────────────────
    // Buenos Aires es UTC-3 sin DST. Construimos la fecha en TZ ARG
    // para que `fechaTxt` y `fecha` Timestamp sean consistentes con la
    // versión cliente original (que usaba DateTime.now() local).
    const ahora = new Date();
    const fechaTxt = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Argentina/Buenos_Aires",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(ahora); // "2026-04-29"
    const [year, month, day] = fechaTxt.split("-").map(Number);
    const fechaMidnight = new Date(Date.UTC(year, month - 1, day, 3, 0, 0));

    // ─── 4. Batch write a TELEMETRIA_HISTORICO ─────────────────────
    const batch = db.batch();
    let escritos = 0;
    let saltadosVin = 0;
    let saltadosPatente = 0;
    let saltadosCeros = 0;

    for (const v of cache) {
      const vehiculo = v as Record<string, unknown>;
      const vin = (vehiculo.vin ?? "").toString().trim().toUpperCase();
      if (!vin) {
        saltadosVin++;
        continue;
      }
      const patente = vinToPatente.get(vin);
      if (!patente) {
        saltadosPatente++;
        continue;
      }

      // Litros acumulados — el endpoint vehiclestatuses lo expone como
      // `engineTotalFuelUsed` al primer nivel **en MILILITROS**. Para
      // que el campo `litros_acumulados` esté efectivamente en litros
      // (consistente con su nombre y con el reporte de consumo),
      // dividimos por 1000. Mantenemos `accumulatedData.totalFuelConsumption`
      // como fallback por si en algún tipo de unidad viene nested.
      let litrosMl = 0;
      const top = vehiculo.engineTotalFuelUsed;
      if (typeof top === "number") {
        litrosMl = top;
      } else if (top != null) {
        litrosMl = Number(top);
      } else {
        const acc = vehiculo.accumulatedData;
        if (acc && typeof acc === "object") {
          const accObj = acc as Record<string, unknown>;
          const total = accObj.totalFuelConsumption;
          if (typeof total === "number") {
            litrosMl = total;
          } else if (total != null) {
            litrosMl = Number(total);
          }
        }
      }
      if (Number.isNaN(litrosMl)) litrosMl = 0;
      const litros = litrosMl / 1000;

      // Odómetro — Volvo lo entrega en metros.
      const metros = Number(
        vehiculo.hrTotalVehicleDistance ?? vehiculo.lastKnownOdometer ?? 0
      );
      const km = metros / 1000;

      // serviceDistance — km al próximo service programado. Volvo lo
      // entrega en metros y PUEDE SER NEGATIVO (vencido). Lo guardamos
      // como `service_distance_km` para alimentar el dashboard de
      // mantenimiento preventivo.
      //
      // Path oficial según doc Volvo Group Vehicle API v1.0.6:
      //   vehicleStatuses[i].uptimeData.serviceDistance
      // (junto con tellTaleInfo, engineCoolantTemperature).
      // Probamos primero ese path y caemos a legacy si no aparece.
      let serviceMetros: number | null = null;
      const serviceCandidatos: unknown[] = [
        (vehiculo.uptimeData as Record<string, unknown> | undefined)
          ?.serviceDistance,
        vehiculo.serviceDistance,
        (vehiculo.snapshotData as Record<string, unknown> | undefined)
          ?.serviceDistance,
        ((vehiculo.snapshotData as Record<string, unknown> | undefined)
          ?.volvoGroupSnapshot as Record<string, unknown> | undefined)
          ?.serviceDistance,
      ];
      for (const c of serviceCandidatos) {
        if (c == null) continue;
        const n = typeof c === "number" ? c : Number(c);
        if (!Number.isNaN(n)) {
          serviceMetros = n;
          break;
        }
      }
      const serviceKm = serviceMetros != null ? serviceMetros / 1000 : null;

      // Sin telemetría útil no escribimos.
      if (litros === 0 && km === 0 && serviceKm == null) {
        saltadosCeros++;
        continue;
      }

      const docId = `${patente}_${fechaTxt}`;
      // TTL: el campo `expira_en` (fecha + 18 meses) marca cuándo
      // GCP debe borrar este doc automáticamente. La policy se activa
      // por separado con: `gcloud firestore fields ttls update
      // expira_en --collection-group=TELEMETRIA_HISTORICO
      // --enable-ttl --project=coopertrans-movil`. 18 meses cubre
      // reportes anuales y comparativos año-a-año sin acumular
      // indefinidamente (snapshot diario × 127 vehículos × N años).
      // 18 meses calendario (no 18*30 dias = 540 dias = ~17.7 meses).
      // Antes la cuenta erronea borraba ~8 dias antes de los 18 meses
      // reales — para data anual y comparativos año-a-año hace falta el
      // calendario exacto. Usamos setUTCMonth para evitar drift.
      const ttl = new Date(fechaMidnight);
      ttl.setUTCMonth(ttl.getUTCMonth() + 18);
      const expiraEnMs = ttl.getTime();
      const doc: Record<string, unknown> = {
        patente,
        vin,
        fecha: Timestamp.fromDate(fechaMidnight),
        litros_acumulados: litros,
        km,
        timestamp: FieldValue.serverTimestamp(),
        expira_en: Timestamp.fromMillis(expiraEnMs),
      };
      if (serviceKm != null) {
        doc.service_distance_km = serviceKm;
      }
      batch.set(db.collection("TELEMETRIA_HISTORICO").doc(docId), doc);
      escritos++;
    }

    if (escritos === 0) {
      logger.info("[telemetriaSnapshot] sin datos útiles, nada que escribir", {
        recibidos: cache.length,
        saltadosVin,
        saltadosPatente,
        saltadosCeros,
        vinesEnFirestore: vinToPatente.size,
      });
      return;
    }

    await batch.commit();
    logger.info("[telemetriaSnapshot] OK", {
      escritos,
      fechaTxt,
      recibidos: cache.length,
      saltadosVin,
      saltadosPatente,
      saltadosCeros,
    });
  }
);
