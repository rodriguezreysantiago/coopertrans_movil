// ============================================================================
// Cruce diario PARADAS_REPORTADAS ↔ REGISTRO_JORNADAS v3 (D Fase 2)
// ============================================================================
//
// Contexto: el bot WhatsApp tiene una tool `registrar_parada_reportada` que el
// agente invoca cuando el chofer avisa "ya pare hora 11:40" (caso real
// FERNANDEZ 7-jun). Persiste en PARADAS_REPORTADAS con `estado=pendiente_cruce`.
// Esta CF corre 07:00 ART (después del cron v3 06:45 que arma REGISTRO_JORNADAS
// del día anterior) y CRUZA cada parada reportada contra las pausas que v3
// detectó:
//
//   - Match → estado = "confirmada_v3" + detalle de la pausa v3 que matchea.
//     (Tranquilidad para el chofer: el GPS lo vio, no hay falsa pérdida.)
//   - Sin match → estado = "no_vista_v3" + se crea automáticamente un
//     REPORTES_DISCREPANCIA para que la oficina lo revise contra el GPS bruto
//     (puede que v3 también lo haya perdido por gap GSM).
//
// Idempotente: el doc PARADAS_REPORTADAS guarda el estado final + cualquier
// REPORTES_DISCREPANCIA creado lleva `origen=parada_reportada_auto` y el id
// de la parada, así re-ejecutar el cron no duplica.
//
// LÓGICA PURA en `cruzarParadasConJornadas` para testear sin Firestore — mismo
// patrón ganador que `evaluarTickJornada` y `reconstruirJornadas`.

import { onSchedule } from "firebase-functions/v2/scheduler";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";
import { adquirirLockTick } from "./index";

// ── Tipos puros ──────────────────────────────────────────────────────────────

/** Parada que el chofer reportó por WhatsApp (vía bot). Subset mínimo del doc
 *  de PARADAS_REPORTADAS para testear sin tocar Firestore. */
export interface ParadaReportadaLite {
  id: string;
  choferDni: string;
  choferNombre: string | null;
  fecha: string; // YYYY-MM-DD ART
  inicioMs: number | null;
  inicioLabel: string | null; // "HH:MM"
  finMs: number | null;
  finLabel: string | null;
  motivo: string | null;
}

/** Pausa que v3 detectó (subset del array `pausas[]` del registro). */
export interface PausaV3Lite {
  inicioMs: number;
  finMs: number;
  durSeg: number;
  origen: string;
  confianza: string;
  cierraBloque: boolean;
}

/** Veredicto del cruce de UNA parada reportada contra las pausas v3 del día. */
export type Veredicto =
  | { estado: "confirmada_v3"; pausa: PausaV3Lite; razon: string }
  | { estado: "no_vista_v3"; razon: string };

/** Ventanas de match (mismas constantes que el script
 *  `cerrar_reportes_resueltos_por_v3.js`, ver heurística doble). */
export const TOL_HORA_EXPLICITA_MS = 20 * 60 * 1000;
export const VENTANA_RECIENCIA_ANTES_MS = 90 * 60 * 1000;
export const VENTANA_RECIENCIA_DESPUES_MS = 30 * 60 * 1000;
export const DUR_MIN_PAUSA_OPERATIVA_SEG = 15 * 60;

/**
 * Cruza UNA parada reportada contra las pausas v3 del día y devuelve un
 * veredicto. PURA — testeable.
 *
 * Heurística (en orden):
 *  1. HORA EXPLÍCITA: si la parada tiene inicio_ms, matcheamos contra pausas
 *     v3 (≥ 15 min) que arranquen ±20 min de ese inicio.
 *  2. (Caso solo presente acá): si la parada NO tiene inicio_ms (parser falló
 *     o el chofer no dio hora), no podemos cruzar → "no_vista_v3" con razón.
 *
 * No usamos la "reciencia" del script de cerrar reportes porque acá SÍ tenemos
 * la hora exacta que el chofer reportó (la tool la persistió en inicio_ms).
 */
export function cruzarUnaParada(
  parada: ParadaReportadaLite,
  pausas: PausaV3Lite[]
): Veredicto {
  if (parada.inicioMs == null) {
    return { estado: "no_vista_v3", razon: "parada sin hora de inicio parseable" };
  }
  const candidatas = pausas.filter((p) => p.durSeg >= DUR_MIN_PAUSA_OPERATIVA_SEG);
  if (candidatas.length === 0) {
    return { estado: "no_vista_v3", razon: "v3 no detectó pausas ≥ 15 min ese día" };
  }
  const tol = TOL_HORA_EXPLICITA_MS;
  const match = candidatas.find((p) =>
    Math.abs(p.inicioMs - (parada.inicioMs as number)) <= tol
  );
  if (match) {
    const hhmm = (ms: number) =>
      new Intl.DateTimeFormat("es-AR", {
        timeZone: "America/Argentina/Buenos_Aires",
        hour: "2-digit", minute: "2-digit",
      }).format(new Date(ms));
    return {
      estado: "confirmada_v3",
      pausa: match,
      razon:
        `v3 detectó pausa ${hhmm(match.inicioMs)}→${hhmm(match.finMs)} ` +
        `(${Math.round(match.durSeg / 60)} min, ${match.origen}, conf=${match.confianza})`,
    };
  }
  return {
    estado: "no_vista_v3",
    razon:
      `v3 detectó ${candidatas.length} pausa(s) ≥ 15 min pero ` +
      "ninguna ±20 min del inicio reportado",
  };
}

/**
 * Cruza N paradas contra las pausas v3 del/los turno(s) del chofer ese día.
 * Devuelve los veredictos en el mismo orden. PURA.
 */
export function cruzarParadasConJornadas(
  paradas: ParadaReportadaLite[],
  pausas: PausaV3Lite[]
): Array<{ parada: ParadaReportadaLite; veredicto: Veredicto }> {
  return paradas.map((p) => ({
    parada: p,
    veredicto: cruzarUnaParada(p, pausas),
  }));
}

// ── I/O: cargar paradas pendientes + pausas v3 + persistir ───────────────────

/** Doc → ParadaReportadaLite. */
function mapearParada(
  doc: { id: string; data: () => Record<string, unknown> }
): ParadaReportadaLite {
  const d = doc.data();
  const tsMs = (v: unknown): number | null => {
    if (v == null) return null;
    const o = v as { toMillis?: () => number };
    return typeof o.toMillis === "function" ? o.toMillis() : null;
  };
  return {
    id: doc.id,
    choferDni: (d.chofer_dni as string | null) || "",
    choferNombre: (d.chofer_nombre as string | null) || null,
    fecha: (d.fecha as string | null) || "",
    inicioMs: typeof d.inicio_ms === "number" ? d.inicio_ms : tsMs(d.inicio_ms),
    inicioLabel: (d.inicio_label as string | null) || null,
    finMs: typeof d.fin_ms === "number" ? d.fin_ms : tsMs(d.fin_ms),
    finLabel: (d.fin_label as string | null) || null,
    motivo: (d.motivo as string | null) || null,
  };
}

/** Lee TODAS las pausas v3 del chofer en una fecha ART (pueden ser 1+ turnos). */
async function cargarPausasV3(dni: string, fechaArt: string): Promise<PausaV3Lite[]> {
  const snap = await db.collection("REGISTRO_JORNADAS")
    .where("chofer_dni", "==", dni)
    .where("fecha", "==", fechaArt)
    .get();
  const out: PausaV3Lite[] = [];
  for (const d of snap.docs) {
    for (const p of ((d.data().pausas as unknown[]) || [])) {
      const pp = p as Record<string, unknown>;
      const ini = pp.inicio as { toMillis?: () => number } | undefined;
      const fin = pp.fin as { toMillis?: () => number } | undefined;
      const inicioMs = ini?.toMillis?.() ?? 0;
      const finMs = fin?.toMillis?.() ?? 0;
      out.push({
        inicioMs, finMs,
        durSeg: (pp.dur_seg as number) ?? Math.round((finMs - inicioMs) / 1000),
        origen: (pp.origen as string) || "?",
        confianza: (pp.confianza as string) || "alta",
        cierraBloque: pp.cierra_bloque === true,
      });
    }
  }
  return out.sort((a, b) => a.inicioMs - b.inicioMs);
}

/** Persiste el resultado del cruce sobre el doc de PARADAS_REPORTADAS + escala
 *  a REPORTES_DISCREPANCIA si v3 no la vio. Idempotente — usa docId
 *  determinístico para el reporte auto. */
async function persistirVeredicto(
  parada: ParadaReportadaLite, veredicto: Veredicto
): Promise<void> {
  const update: Record<string, unknown> = {
    estado: veredicto.estado,
    cruzado_en: FieldValue.serverTimestamp(),
    cruce_razon: veredicto.razon,
  };
  if (veredicto.estado === "confirmada_v3") {
    update.pausa_v3 = {
      inicio: Timestamp.fromMillis(veredicto.pausa.inicioMs),
      fin: Timestamp.fromMillis(veredicto.pausa.finMs),
      dur_seg: veredicto.pausa.durSeg,
      origen: veredicto.pausa.origen,
      confianza: veredicto.pausa.confianza,
    };
  }
  await db.collection("PARADAS_REPORTADAS").doc(parada.id).update(update);

  if (veredicto.estado === "no_vista_v3") {
    // Docid determinístico para que re-ejecutar el cron no duplique reportes.
    const repId = `parada_auto_${parada.id}`;
    await db.collection("REPORTES_DISCREPANCIA").doc(repId).set({
      chofer_dni: parada.choferDni,
      chofer_nombre: parada.choferNombre,
      tema: "jornada",
      detalle:
        `Auto: el chofer avisó una parada ${parada.inicioLabel || "?"}` +
        (parada.finLabel ? `→${parada.finLabel}` : "") +
        (parada.motivo ? ` (${parada.motivo})` : "") +
        `. El registro v3 NO la ve: ${veredicto.razon}. ` +
        "Revisar contra GPS bruto.",
      estado: "pendiente",
      origen: "parada_reportada_auto",
      parada_id: parada.id,
      creado_en: FieldValue.serverTimestamp(),
    });
  }
}

// ── Cron diario + callable manual ────────────────────────────────────────────

export interface ResultadoCruce {
  procesadas: number;
  confirmadas: number;
  no_vistas: number;
  escaladas_a_reporte: number;
}

/**
 * Procesa todas las paradas reportadas pendientes_cruce hasta `hastaFechaArt`
 * inclusive (default: ayer ART, para que v3 ya las haya procesado).
 */
export async function procesarParadasPendientes(
  hastaFechaArt: string
): Promise<ResultadoCruce> {
  const snap = await db.collection("PARADAS_REPORTADAS")
    .where("estado", "==", "pendiente_cruce").get();
  let confirmadas = 0;
  let noVistas = 0;
  let escaladas = 0;
  let procesadas = 0;

  for (const doc of snap.docs) {
    const parada = mapearParada(doc);
    if (!parada.choferDni || !parada.fecha) continue;
    // Solo paradas cuyo día ya pasó (v3 ya tiene que estar escrita).
    if (parada.fecha > hastaFechaArt) continue;
    try {
      const pausas = await cargarPausasV3(parada.choferDni, parada.fecha);
      const veredicto = cruzarUnaParada(parada, pausas);
      await persistirVeredicto(parada, veredicto);
      procesadas++;
      if (veredicto.estado === "confirmada_v3") confirmadas++;
      else {
        noVistas++;
        escaladas++;
      }
    } catch (e) {
      logger.warn("[paradas_reportadas] error procesando parada", {
        id: parada.id, error: (e as Error).message,
      });
    }
  }
  return {
    procesadas,
    confirmadas,
    no_vistas: noVistas,
    escaladas_a_reporte: escaladas,
  };
}

/** Fecha YYYY-MM-DD ART de ayer (relativa a `ahora`). */
function ayerArt(ahora: Date = new Date()): string {
  const ayer = new Date(ahora.getTime() - 24 * 60 * 60 * 1000);
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).format(ayer);
}

/**
 * Corre 07:00 ART (después del cron v3 06:45). Procesa todas las paradas
 * pendientes hasta AYER inclusive — las de HOY se dejan (v3 aún no las
 * escribió). Idempotente.
 */
export const cruzarParadasReportadasV3Diario = onSchedule(
  {
    schedule: "0 7 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async () => {
    const liberar = await adquirirLockTick(
      "cruzar_paradas_reportadas", 9 * 60 * 1000
    );
    if (!liberar) return;
    try {
      const res = await procesarParadasPendientes(ayerArt());
      logger.info("[paradas_reportadas] OK", res);
    } catch (e) {
      logger.error("[paradas_reportadas] error", {
        error: (e as Error).message,
      });
    } finally {
      await liberar();
    }
  },
);

/** Callable manual para ADMIN — útil para reprocesar tras un cambio de
 *  heurística o cuando quiere forzar el cierre del día actual. */
export const cruzarParadasReportadasManual = onCall(
  { timeoutSeconds: 540, memory: "512MiB" },
  async (req) => {
    const rol = (req.auth?.token?.rol as string | undefined) || "";
    if (rol !== "ADMIN") {
      throw new HttpsError("permission-denied", "Solo ADMIN puede correr el cruce manual.");
    }
    const hasta = (req.data?.hastaFechaArt as string | undefined) || ayerArt();
    const res = await procesarParadasPendientes(hasta);
    return { ok: true, hasta, ...res };
  },
);
