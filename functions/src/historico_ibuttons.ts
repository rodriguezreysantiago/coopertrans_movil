// =============================================================================
// HISTÓRICO REAL DE iBUTTONS — reconstruye desde SITRACK_EVENTOS
// =============================================================================
//
// Cada evento Sitrack en SITRACK_EVENTOS trae `driver_dni` (el iButton físico
// pasado por el chofer al subir) + `asset_name` (patente) + `report_date`.
// Si agrupamos por (patente) y ordenamos por timestamp, cada CAMBIO de DNI
// marca un "fin de tramo" del iButton anterior y "inicio" del nuevo.
//
// Esto es la fuente DE VERDAD del iButton — lo que físicamente pasó el
// chofer — y permite reconstruir "quién manejó qué patente y desde cuándo"
// para multas tardías, investigaciones y auditoría de asignaciones del
// sistema (que se cargan a mano y pueden divergir).
//
// 2 functions exportadas:
//   - reconstruirHistoricoIButtonsDiario: cron 06:00 ART (procesa AYER)
//   - backfillHistoricoIButtons: callable para procesar un rango pasado
//     (uso de migración inicial / recuperación si el cron se cayó)
//
// Schema doc `SITRACK_IBUTTONS_HISTORICO/{patente}_{dni}_{desde_ms}`:
//   { patente, chofer_dni, chofer_nombre, desde, hasta, duracion_min,
//     eventos_count, procesado_en }
// Desde/hasta = primer y último evento del tramo continuo. Si el iButton
// vuelve a aparecer en la misma patente >30 min después, es un tramo nuevo.

import { onCall } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";
import { adquirirLockTick,
  onScheduleConLatido,
} from "./comun";

/** Si entre 2 eventos del mismo (patente, dni) hay menos de este gap,
 *  los consideramos parte del mismo tramo continuo. Si hay más, abrimos
 *  uno nuevo. 30 min cubre paradas largas en estación, descargas, etc. */
const GAP_TRAMO_MS = 30 * 60 * 1000;

/** Mínimo de eventos para considerar un tramo válido. Filtra ruido (un
 *  iButton que se pasó por error y se sacó al toque). */
const MIN_EVENTOS_TRAMO = 2;

interface EventoMin {
  patente: string;
  driverDni: string;
  driverNombre?: string;
  ts: Timestamp;
}

interface Tramo {
  patente: string;
  driverDni: string;
  driverNombre?: string;
  desde: Timestamp;
  hasta: Timestamp;
  eventosCount: number;
}

/** Procesa los eventos del rango [desde, hasta) y devuelve tramos del
 *  histórico. Función pura: testeable sin Firestore. */
export function reconstruirTramos(eventos: EventoMin[]): Tramo[] {
  // Agrupar por patente
  const porPatente = new Map<string, EventoMin[]>();
  for (const e of eventos) {
    if (!e.patente || !e.driverDni) continue;
    if (!porPatente.has(e.patente)) porPatente.set(e.patente, []);
    porPatente.get(e.patente)!.push(e);
  }

  const tramos: Tramo[] = [];

  for (const [patente, evts] of porPatente) {
    // Orden cronológico ascendente
    evts.sort((a, b) => a.ts.toMillis() - b.ts.toMillis());

    let actual: Tramo | null = null;

    for (const e of evts) {
      const tsMs = e.ts.toMillis();
      const nuevoTramo = !actual ||
        actual.driverDni !== e.driverDni ||
        tsMs - actual.hasta.toMillis() > GAP_TRAMO_MS;

      if (nuevoTramo) {
        if (actual && actual.eventosCount >= MIN_EVENTOS_TRAMO) {
          tramos.push(actual);
        }
        actual = {
          patente,
          driverDni: e.driverDni,
          driverNombre: e.driverNombre,
          desde: e.ts,
          hasta: e.ts,
          eventosCount: 1,
        };
      } else {
        actual!.hasta = e.ts;
        actual!.eventosCount++;
        // El nombre puede llegar vacío en algunos eventos; nos quedamos
        // con el primero no vacío.
        if (!actual!.driverNombre && e.driverNombre) {
          actual!.driverNombre = e.driverNombre;
        }
      }
    }
    if (actual && actual.eventosCount >= MIN_EVENTOS_TRAMO) {
      tramos.push(actual);
    }
  }

  return tramos;
}

/** Persiste un tramo a Firestore con doc id determinístico. Idempotente
 *  (si el cron se re-ejecuta el mismo día, sobrescribe el mismo doc). */
async function persistirTramo(t: Tramo): Promise<void> {
  const docId = `${t.patente}_${t.driverDni}_${t.desde.toMillis()}`;
  const duracionMin = Math.round(
    (t.hasta.toMillis() - t.desde.toMillis()) / 60000,
  );
  await db.collection("SITRACK_IBUTTONS_HISTORICO").doc(docId).set({
    patente: t.patente,
    chofer_dni: t.driverDni,
    chofer_nombre: t.driverNombre ?? null,
    desde: t.desde,
    hasta: t.hasta,
    duracion_min: duracionMin,
    eventos_count: t.eventosCount,
    procesado_en: FieldValue.serverTimestamp(),
  });
}

/** Trae eventos del rango y procesa. Compartido entre el cron diario y
 *  el callable de backfill. */
async function procesarRango(
  desde: Date, hasta: Date,
): Promise<{ eventos: number; tramos: number }> {
  // Paginamos por chunks de 1 día porque SITRACK_EVENTOS puede tener
  // miles de docs por día. Para 1 día solo, hacemos 1 query.
  const snap = await db.collection("SITRACK_EVENTOS")
    .where("report_date", ">=", Timestamp.fromDate(desde))
    .where("report_date", "<", Timestamp.fromDate(hasta))
    .get();

  const eventos: EventoMin[] = [];
  for (const d of snap.docs) {
    const m = d.data();
    // OJO: en la cuenta `ws41629VecchiSRL`, Sitrack manda la PATENTE en
    // `assetId` (ej. "AF472BG"). `assetName` llega vacío. El poller
    // `sitrackEventosPoller` guarda ambos crudos — acá tomamos `asset_id`.
    const patente = (m.asset_id as string | undefined)?.trim().toUpperCase();
    const driverDni = (m.driver_dni as string | undefined)?.trim();
    const ts = m.report_date as Timestamp | undefined;
    if (!patente || !driverDni || !ts) continue;
    eventos.push({
      patente,
      driverDni,
      driverNombre: (m.driver_name as string | undefined)?.trim() || undefined,
      ts,
    });
  }

  const tramos = reconstruirTramos(eventos);
  await Promise.all(tramos.map(persistirTramo));
  return { eventos: eventos.length, tramos: tramos.length };
}

// ============================================================================
// Cron diario — procesa ayer
// ============================================================================

export const reconstruirHistoricoIButtonsDiario = onScheduleConLatido(
  "reconstruirHistoricoIButtonsDiario",
  {
    schedule: "0 6 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async () => {
    const liberar = await adquirirLockTick(
      "reconstruir_ibuttons_diario", 9 * 60 * 1000,
    );
    if (!liberar) return;
    try {
      // Rango: AYER 00:00 ART → HOY 00:00 ART
      const ahoraArt = new Date(Date.now() - 3 * 60 * 60 * 1000);
      const hoyArt = new Date(Date.UTC(
        ahoraArt.getUTCFullYear(),
        ahoraArt.getUTCMonth(),
        ahoraArt.getUTCDate(),
        3, 0, 0, 0,
      )); // 00:00 ART = 03:00 UTC
      const ayerArt = new Date(hoyArt.getTime() - 24 * 60 * 60 * 1000);

      logger.info("[reconstruirHistoricoIButtonsDiario] iniciando", {
        desde: ayerArt.toISOString(), hasta: hoyArt.toISOString(),
      });
      const res = await procesarRango(ayerArt, hoyArt);
      logger.info("[reconstruirHistoricoIButtonsDiario] OK", res);
    } catch (e) {
      logger.error("[reconstruirHistoricoIButtonsDiario] error", {
        error: (e as Error).message,
      });
    } finally {
      await liberar();
    }
  },
);

// ============================================================================
// Callable de backfill — para llenar histórico de N días pasados de una
// (uso: corrida inicial después del deploy + recuperación post-caída)
// ============================================================================

export const backfillHistoricoIButtons = onCall(
  {
    timeoutSeconds: 540,
    memory: "1GiB",
    // Hereda la región global (southamerica-east1, mismo DC que Firestore).
    // Auditoría 2026-05-30: estaba en us-central1 (cross-region); ningún cliente
    // la llama por URL fija, así que mover es seguro.
  },
  async (req) => {
    const rol = (req.auth?.token?.rol as string | undefined) || "";
    if (rol !== "ADMIN") {
      throw new Error("Solo ADMIN puede correr el backfill.");
    }
    const dias = Number(req.data?.dias ?? 7);
    if (!Number.isInteger(dias) || dias < 1 || dias > 60) {
      throw new Error("dias debe ser entero entre 1 y 60.");
    }
    const ahoraArt = new Date(Date.now() - 3 * 60 * 60 * 1000);
    const hoyArt = new Date(Date.UTC(
      ahoraArt.getUTCFullYear(),
      ahoraArt.getUTCMonth(),
      ahoraArt.getUTCDate(),
      3, 0, 0, 0,
    ));

    let totalEventos = 0, totalTramos = 0;
    const detalle: { fecha: string; eventos: number; tramos: number }[] = [];
    for (let i = 1; i <= dias; i++) {
      const fin = new Date(hoyArt.getTime() - (i - 1) * 24 * 60 * 60 * 1000);
      const ini = new Date(fin.getTime() - 24 * 60 * 60 * 1000);
      const fechaLabel = ini.toISOString().substring(0, 10);
      logger.info(`[backfill] día ${i}/${dias} (${fechaLabel})`);
      try {
        const r = await procesarRango(ini, fin);
        totalEventos += r.eventos;
        totalTramos += r.tramos;
        detalle.push({ fecha: fechaLabel, ...r });
      } catch (e) {
        logger.error(`[backfill] error día ${fechaLabel}`, {
          error: (e as Error).message,
        });
        detalle.push({ fecha: fechaLabel, eventos: -1, tramos: -1 });
      }
    }
    return {
      ok: true,
      dias_procesados: dias,
      total_eventos: totalEventos,
      total_tramos: totalTramos,
      detalle,
    };
  },
);
