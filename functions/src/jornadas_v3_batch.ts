// ============================================================================
// Vigilador de jornada — v3 · Capa de I/O del registro a posteriori (Paso 2)
// ============================================================================
//
// Ver docs/PLAN_vigilador_jornada_v3.md. Este módulo es el ENVOLTORIO de I/O
// alrededor de la lógica PURA de `jornadas_v3.ts` (Paso 1): lee los
// SITRACK_EVENTOS de una ventana, los agrupa por chofer, reconstruye la(s)
// jornada(s) y persiste el `RegistroJornada` en una colección NUEVA. Calcado
// del patrón ya probado en `jornada_historico.ts` (cron diario + backfill +
// función pura testeable), pero usando la reconstrucción por SEÑALES de v3
// (Contacto OFF/ON, detenido, pausa encubierta, confianza) en lugar de la
// inferencia por velocidad del histórico.
//
// ── ESTADO: DORMIDO, NO DEPLOYADO ──
// Este módulo NO se re-exporta desde `index.ts` a propósito → Firebase no lo ve
// y `firebase deploy` no crea nada. Para ACTIVARLO (con OK de Santiago):
//   1. Agregar `export * from "./jornadas_v3_batch";` en index.ts.
//   2. `firebase deploy --only functions:registrarJornadasV3Diario` (+ backfill)
//      y `firebase deploy --only firestore:rules` (regla de REGISTRO_JORNADAS).
//   3. Prender el flag `META/config_vigilador_v3.registro_batch_activo = true`.
// El cron además está DARK por flag (default false) → aunque se deploye, no
// escribe nada hasta prender el flag, y se apaga al instante bajándolo. Jornada
// = horas de trabajo, sensible: doble red (no wired + flag).
//
// NO toca el v2 (vigilador en vivo → JORNADAS) ni el histórico
// (jornada_historico → VOLVO_JORNADAS_HISTORICO). Colección propia, en paralelo.

import { onSchedule } from "firebase-functions/v2/scheduler";
import { onCall } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";
import { adquirirLockTick } from "./index";
import {
  EventoJornadaLite,
  RegistroJornada,
  reconstruirJornadas,
} from "./jornadas_v3";

/** Colección del registro a posteriori (la VERDAD auditable). Permanente —
 * es un destilado, no evento crudo (como VOLVO_JORNADAS_HISTORICO). */
export const COLECCION_REGISTRO = "REGISTRO_JORNADAS";

/** Kill switch: META/config_vigilador_v3.registro_batch_activo (default false).
 * Permite deployar el cron DARK y prenderlo/apagarlo sin redeploy. */
const FLAG_DOC = "config_vigilador_v3";
const FLAG_CAMPO = "registro_batch_activo";

// ─── Mapeo SITRACK_EVENTOS → EventoJornadaLite (PURO) ────────────────────────

/** Convierte un `report_date` (Timestamp Firestore | Date | epoch ms) a ms. */
function tsToMs(v: unknown): number | null {
  if (v == null) return null;
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  const o = v as { toMillis?: () => number; getTime?: () => number };
  if (typeof o.toMillis === "function") return o.toMillis();
  if (typeof o.getTime === "function") return o.getTime();
  return null;
}

/** Mapea un doc de SITRACK_EVENTOS (campos del poller `sitrack.ts:691`) al
 * `EventoJornadaLite` que consume la lógica pura. `null` si no tiene fecha. */
export function mapearDocEvento(
  data: Record<string, unknown>
): EventoJornadaLite | null {
  const ms = tsToMs(data.report_date);
  if (ms == null) return null;
  return {
    ms,
    eventId: typeof data.event_id === "number" ? data.event_id : null,
    eventName: typeof data.event_name === "string" ?
      data.event_name : undefined,
    speed: typeof data.speed === "number" ? data.speed : null,
    gpsSpeed: typeof data.gps_speed === "number" ? data.gps_speed : null,
    ignition: data.ignition === 0 || data.ignition === 1 ?
      data.ignition : null,
    lat: typeof data.latitude === "number" ? data.latitude : null,
    lng: typeof data.longitude === "number" ? data.longitude : null,
    gpsValidity: typeof data.gps_validity === "number" ?
      data.gps_validity : null,
  };
}

// ─── Identidad de fecha / doc (PURO) ─────────────────────────────────────────

/** Fecha ART (YYYY-MM-DD) de un epoch ms. `en-CA` da el formato ISO. */
export function fechaArt(ms: number): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date(ms));
}

/** Doc id determinístico = `{dni}_{fecha-ART-del-inicio-de-turno}`. Idempotente
 * (re-procesar la misma jornada pisa el mismo doc) y compatible con la regla de
 * Firestore que da al chofer su propio registro (`doc.split('_')[0] == uid`),
 * igual que VOLVO_JORNADAS_HISTORICO. */
export function docIdRegistro(dni: string, inicioTurnoMs: number): string {
  return `${dni}_${fechaArt(inicioTurnoMs)}`;
}

// ─── Agrupar + reconstruir (PURO) ────────────────────────────────────────────

export interface RegistroConMeta {
  dni: string;
  patente: string | null;
  registro: RegistroJornada;
}

function patentePrincipal(conteo: Map<string, number>): string | null {
  let mejor: string | null = null;
  let max = 0;
  for (const [pat, n] of conteo) {
    if (n > max) {
      max = n;
      mejor = pat;
    }
  }
  return mejor;
}

/**
 * Agrupa docs crudos de SITRACK_EVENTOS por chofer y reconstruye TODAS las
 * jornadas de cada uno (parte por descanso de 8 h vía `reconstruirJornadas`).
 * PURA — testeable sin Firestore. Devuelve una entrada por TURNO reconstruido.
 */
export function agruparYReconstruir(
  docs: Array<Record<string, unknown>>
): RegistroConMeta[] {
  const porDni = new Map<string, EventoJornadaLite[]>();
  const patPorDni = new Map<string, Map<string, number>>();
  for (const data of docs) {
    const dni = (data.driver_dni ?? "").toString().trim();
    if (!dni) continue;
    const ev = mapearDocEvento(data);
    if (!ev) continue;
    if (!porDni.has(dni)) porDni.set(dni, []);
    porDni.get(dni)!.push(ev);
    // Patente: asset_id viene CRUDO (no como el doc id de POSICIONES) → trim+up.
    const pat = (data.asset_id ?? "").toString().trim().toUpperCase();
    if (pat) {
      if (!patPorDni.has(dni)) patPorDni.set(dni, new Map());
      const c = patPorDni.get(dni)!;
      c.set(pat, (c.get(pat) ?? 0) + 1);
    }
  }
  const out: RegistroConMeta[] = [];
  for (const [dni, evs] of porDni) {
    const patente = patentePrincipal(patPorDni.get(dni) ?? new Map());
    for (const registro of reconstruirJornadas(evs)) {
      out.push({ dni, patente, registro });
    }
  }
  return out;
}

// ─── Serialización a Firestore (PURO) ────────────────────────────────────────

/** Arma el doc a persistir. Tiempos → Timestamp; arrays a forma plana. */
export function registroToFirestore(
  dni: string, patente: string | null, r: RegistroJornada
): Record<string, unknown> {
  const inicio = r.inicioTurnoMs as number;
  const fin = r.finTurnoMs as number;
  return {
    version: 3,
    chofer_dni: dni,
    patente: patente ?? null,
    fecha: fechaArt(inicio),
    inicio_turno: Timestamp.fromMillis(inicio),
    fin_turno: Timestamp.fromMillis(fin),
    manejo_neto_seg: r.manejoNetoSeg,
    pausa_total_seg: r.pausaTotalSeg,
    bloques_excedidos: r.bloquesExcedidos,
    jornada_excedida: r.jornadaExcedida,
    confianza: r.confianza,
    bloques: r.bloques.map((b) => ({
      indice: b.indice,
      manejo_neto_seg: b.manejoNetoSeg,
      inicio: Timestamp.fromMillis(b.inicioMs),
      fin: Timestamp.fromMillis(b.finMs),
      excedido: b.excedido,
    })),
    pausas: r.pausas.map((p) => ({
      inicio: Timestamp.fromMillis(p.inicioMs),
      fin: Timestamp.fromMillis(p.finMs),
      dur_seg: p.durSeg,
      origen: p.origen,
      confianza: p.confianza,
      lat: p.lat,
      lng: p.lng,
      cierra_bloque: p.cierraBloque,
    })),
    segmentos: r.segmentos.map((s) => ({
      tipo: s.tipo,
      inicio: Timestamp.fromMillis(s.inicioMs),
      fin: Timestamp.fromMillis(s.finMs),
      dur_seg: s.durSeg,
      confianza: s.confianza,
      origen: s.origen ?? null,
      lat: s.lat,
      lng: s.lng,
      motivo_baja: s.motivoBaja ?? null,
    })),
    explicacion: r.explicacion,
    procesado_en: FieldValue.serverTimestamp(),
  };
}

// ─── I/O: procesar una ventana de eventos ────────────────────────────────────

export interface ResultadoProceso {
  eventos: number;
  choferes: number;
  registros: number;
  persistidos: number;
}

/**
 * Lee SITRACK_EVENTOS en `[desde, hasta)`, reconstruye y persiste cada turno.
 * `inicioMin/inicioMax` (opcionales) acotan QUÉ turnos se persisten por su
 * inicio: la ventana puede traer un buffer extra para COMPLETAR un turno que
 * cruza medianoche, sin por eso persistir fragmentos del turno siguiente. Doc
 * id determinístico → idempotente (re-ejecutable sin duplicar).
 */
export async function procesarVentana(
  desde: Date, hasta: Date,
  inicioMin?: number, inicioMax?: number
): Promise<ResultadoProceso> {
  const snap = await db.collection("SITRACK_EVENTOS")
    .where("report_date", ">=", Timestamp.fromDate(desde))
    .where("report_date", "<", Timestamp.fromDate(hasta))
    .get();
  const docs = snap.docs.map((d) => d.data());
  let entradas = agruparYReconstruir(docs);
  if (inicioMin != null || inicioMax != null) {
    const lo = inicioMin ?? -Infinity;
    const hi = inicioMax ?? Infinity;
    entradas = entradas.filter((e) => {
      const i = e.registro.inicioTurnoMs;
      return i != null && i >= lo && i < hi;
    });
  }
  let persistidos = 0;
  for (const { dni, patente, registro } of entradas) {
    const docId = docIdRegistro(dni, registro.inicioTurnoMs as number);
    try {
      await db.collection(COLECCION_REGISTRO).doc(docId)
        .set(registroToFirestore(dni, patente, registro));
      persistidos++;
    } catch (e) {
      logger.warn("[jornadas_v3_batch] persistir falló", {
        docId, error: (e as Error).message,
      });
    }
  }
  const choferes = new Set(entradas.map((e) => e.dni)).size;
  return { eventos: snap.size, choferes, registros: entradas.length,
    persistidos };
}

async function batchActivo(): Promise<boolean> {
  try {
    const s = await db.collection("META").doc(FLAG_DOC).get();
    return s.exists && s.data()?.[FLAG_CAMPO] === true;
  } catch {
    return false; // fail-safe: ante duda, NO escribir (jornada sensible)
  }
}

/** Medianoche ART (00:00) de hace `diasAtras` días, como Date UTC. ART = UTC-3
 * → 00:00 ART = 03:00 UTC del mismo día calendario ART. */
function medianocheArt(diasAtras: number): Date {
  const ahoraArt = new Date(Date.now() - 3 * 60 * 60 * 1000);
  return new Date(Date.UTC(
    ahoraArt.getUTCFullYear(),
    ahoraArt.getUTCMonth(),
    ahoraArt.getUTCDate() - diasAtras,
    3, 0, 0, 0,
  ));
}

// ─── Cron diario (DORMIDO: no exportado desde index + dark por flag) ──────────

/**
 * Reconstruye y persiste las jornadas de AYER. Corre 06:45 ART (después del
 * cron de iButtons 06:00 y el histórico 06:30). Ventana [ayer 00:00, ahora]
 * para completar turnos que cruzan medianoche; persiste solo los que INICIARON
 * ayer (filtro inicioMin/Max) → sin fragmentos del turno de hoy.
 */
export const registrarJornadasV3Diario = onSchedule(
  {
    schedule: "45 6 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 540,
    memory: "1GiB",
  },
  async () => {
    if (!(await batchActivo())) {
      logger.info("[jornadas_v3_batch] dark (flag off) — no se procesa nada");
      return;
    }
    const liberar = await adquirirLockTick(
      "registrar_jornadas_v3", 9 * 60 * 1000,
    );
    if (!liberar) return;
    try {
      const ayer00 = medianocheArt(1);
      const hoy00 = medianocheArt(0);
      const res = await procesarVentana(
        ayer00, new Date(), ayer00.getTime(), hoy00.getTime(),
      );
      logger.info("[jornadas_v3_batch] OK", {
        fecha: fechaArt(ayer00.getTime()), ...res,
      });
    } catch (e) {
      logger.error("[jornadas_v3_batch] error", {
        error: (e as Error).message,
      });
    } finally {
      await liberar();
    }
  },
);

// ─── Backfill ADMIN (DORMIDO) ────────────────────────────────────────────────

/**
 * Reprocesa los últimos `dias` días (ADMIN). Por día usa ventana
 * [día 00:00, día+1 06:00) para completar cruces de medianoche, persistiendo
 * solo los turnos que iniciaron ESE día. Idempotente. No exige el flag (es una
 * acción manual y explícita del admin).
 */
export const backfillRegistrosV3 = onCall(
  { timeoutSeconds: 540, memory: "1GiB" },
  async (req) => {
    const rol = (req.auth?.token?.rol as string | undefined) || "";
    if (rol !== "ADMIN") throw new Error("Solo ADMIN puede correr el backfill.");
    const dias = Number(req.data?.dias ?? 7);
    if (!Number.isInteger(dias) || dias < 1 || dias > 60) {
      throw new Error("dias debe ser entero entre 1 y 60.");
    }
    let totEv = 0, totReg = 0, totPers = 0;
    const detalle: Array<{ fecha: string } & ResultadoProceso> = [];
    for (let i = 1; i <= dias; i++) {
      const dia00 = medianocheArt(i);
      const finVentana = new Date(dia00.getTime() + 30 * 60 * 60 * 1000);
      const diaSig00 = medianocheArt(i - 1);
      const fecha = fechaArt(dia00.getTime());
      try {
        const r = await procesarVentana(
          dia00, finVentana, dia00.getTime(), diaSig00.getTime(),
        );
        totEv += r.eventos; totReg += r.registros; totPers += r.persistidos;
        detalle.push({ fecha, ...r });
      } catch (e) {
        logger.error(`[backfillRegistrosV3] error día ${fecha}`, {
          error: (e as Error).message,
        });
        detalle.push({ fecha, eventos: -1, choferes: -1, registros: -1,
          persistidos: -1 });
      }
    }
    return {
      ok: true, dias_procesados: dias, total_eventos: totEv,
      total_registros: totReg, total_persistidos: totPers, detalle,
    };
  },
);
