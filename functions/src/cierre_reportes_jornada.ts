// =============================================================================
// CIERRE AUTOMÁTICO de reclamos de JORNADA — cron 08:00 ART
// =============================================================================
// Revisa los REPORTES_DISCREPANCIA DIRECTOS de tema "jornada" que siguen
// pendientes y, cruzándolos contra el registro v3 + el GPS crudo, los resuelve
// solo cuando hay evidencia CLARA — seteando el veredicto, que dispara la
// devolución por WhatsApp al chofer (CF onReporteDiscrepanciaRevisado).
//
// Decisión por reclamo (conservadora — ante la duda NO cierra, deja revisión
// manual; nunca acusa a un chofer de mentir sin respaldo del GPS):
//   1. v3 CONFIRMA la pausa reclamada (±20 min de la hora, o reciente) → CIERTO.
//   2. v3 NO la ve → mira el GPS crudo (SITRACK_EVENTOS) en la franja reclamada:
//      - DETENIDO (Sitrack marcó parada que cubre la franja) → CIERTO
//        (v3 la perdió por gap GSM, pero paró de verdad).
//      - EN MOVIMIENTO (velocidad sostenida en la franja) → NO_CIERTO, con la
//        evidencia ("el GPS te registra a X km/h a las HH:MM").
//      - HUECO de señal / ambiguo / sin hora concreta → null (revisión manual).
//
// Automático (pedido Santiago 2026-06-11): cierra + contesta directo, sin paso de
// validación previa. Kill-switch SIN redeploy: poner
// `META/config_cierre_reportes.activo = false` lo apaga (vuelve a solo loguear sin
// tocar nada). Sin ese doc — o con activo:true — corre normal.
//
// El objetivo: contestarle a TODOS los reclamos (tuvieran razón o no) para cerrar
// el loop y desincentivar reclamos inventados.

import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";
import {
  adquirirIdempotenciaDiaria,
  liberarLockConReintentos,
  onScheduleConLatido,
} from "./comun";

// ── Constantes de criterio ───────────────────────────────────────────────────
const TOL_HORA_MS = 20 * 60 * 1000; // ±20 min: pausa v3 "cerca" de la hora reclamada
const DUR_MIN_PAUSA_SEG = 15 * 60; // pausa operativamente relevante
const VENTANA_ANTES_MS = 90 * 60 * 1000; // reciencia: pausa terminó -90 min del reporte
const VENTANA_DESPUES_MS = 30 * 60 * 1000;
const UMBRAL_MOVIMIENTO_KMH = 25; // velocidad clara de "andando" (margen sobre el 15 del vigilador)
const MARGEN_VENTANA_GPS_MS = 15 * 60 * 1000; // ensanche de la franja al mirar el GPS
const PAUSA_ASUMIDA_MS = 20 * 60 * 1000; // si el chofer dio 1 sola hora, asumimos ~20 min de parada

const TZ = "America/Argentina/Buenos_Aires";

// ── Tipos puros (sin Firestore) ──────────────────────────────────────────────
export interface PausaV3 {
  inicioMs: number;
  finMs: number;
  durSeg: number;
}
export interface GpsEvento {
  ms: number;
  speed: number | null;
  eventName: string; // "Inicio de detenido", "Fin de detenido", ...
}
export type Decision =
  | { veredicto: "cierto" | "no_cierto"; nota: string }
  | null;

// ── Helpers de fecha ART ─────────────────────────────────────────────────────
export function hhmm(ms: number): string {
  return new Date(ms).toLocaleTimeString("es-AR", {
    timeZone: TZ,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}
/** Epoch ms de la hora HH:MM en una fecha ART (UTC-3 fijo). */
function msDeHoraArt(fechaArt: string, h: number, min: number): number {
  const hh = String(h).padStart(2, "0");
  const mm = String(min).padStart(2, "0");
  return Date.parse(`${fechaArt}T${hh}:${mm}:00-03:00`);
}

// ── Lógica pura ──────────────────────────────────────────────────────────────

/** Horas HH:MM o H.MM mencionadas en el texto del reclamo (válidas 0-23/0-59). */
export function horasDelReclamo(
  texto: string
): { h: number; min: number; label: string }[] {
  const re = /(\d{1,2})[:.](\d{2})/g;
  const out: { h: number; min: number; label: string }[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(texto || "")) !== null) {
    const h = parseInt(m[1], 10);
    const min = parseInt(m[2], 10);
    if (h >= 0 && h <= 23 && min >= 0 && min <= 59) {
      out.push({
        h,
        min,
        label: `${String(h).padStart(2, "0")}:${String(min).padStart(2, "0")}`,
      });
    }
  }
  return out;
}

/** Franja [t0,t1] que el chofer reclama haber estado parado, derivada de las
 *  horas del texto. 2 horas → [h1,h2]; 1 hora → [h, h+~20min]. null si no hay. */
export function ventanaReclamada(
  texto: string,
  fechaArt: string
): { t0: number; t1: number } | null {
  const horas = horasDelReclamo(texto);
  if (horas.length === 0) return null;
  const ms = horas.map((x) => msDeHoraArt(fechaArt, x.h, x.min)).sort((a, b) => a - b);
  if (ms.length >= 2) return { t0: ms[0], t1: ms[ms.length - 1] };
  return { t0: ms[0], t1: ms[0] + PAUSA_ASUMIDA_MS };
}

/** ¿v3 confirma una pausa que respalda el reclamo? (hora explícita ±20 min, o
 *  reciencia respecto del momento del reporte). Devuelve la nota si confirma. */
export function v3ConfirmaPausa(
  detalle: string,
  fechaArt: string,
  pausas: PausaV3[],
  reporteMs: number
): { confirma: boolean; nota: string } {
  const cand = pausas.filter((p) => p.durSeg >= DUR_MIN_PAUSA_SEG);
  if (cand.length === 0) return { confirma: false, nota: "" };
  const notaDe = (p: PausaV3) =>
    `El registro del día confirma tu pausa de ${hhmm(p.inicioMs)} a ` +
    `${hhmm(p.finMs)} (${Math.round(p.durSeg / 60)} min).`;

  for (const claim of horasDelReclamo(detalle)) {
    const claimMs = msDeHoraArt(fechaArt, claim.h, claim.min);
    const hit = cand.find((p) => Math.abs(p.inicioMs - claimMs) <= TOL_HORA_MS);
    if (hit) return { confirma: true, nota: notaDe(hit) };
  }
  const reciente = cand.find(
    (p) => p.finMs >= reporteMs - VENTANA_ANTES_MS && p.finMs <= reporteMs + VENTANA_DESPUES_MS
  );
  if (reciente) return { confirma: true, nota: notaDe(reciente) };
  return { confirma: false, nota: "" };
}

/** Mira el GPS crudo en la franja reclamada. Devuelve un veredicto sólido o
 *  "incierto" (gap / ambiguo) para no acusar sin respaldo. */
export function analizarGpsVentana(
  eventos: GpsEvento[],
  t0: number,
  t1: number
): { resultado: "detenido" | "movimiento" | "incierto"; nota: string } {
  const enVentana = eventos
    .filter((e) => e.ms >= t0 - MARGEN_VENTANA_GPS_MS && e.ms <= t1 + MARGEN_VENTANA_GPS_MS)
    .sort((a, b) => a.ms - b.ms);
  if (enVentana.length === 0) {
    return {
      resultado: "incierto",
      nota: "sin datos GPS en la franja (posible hueco de señal)",
    };
  }

  // DETENIDO: Sitrack marcó una detención que solapa la franja reclamada.
  const inicioDet = enVentana.find(
    (e) => /inicio de detenido|detenido/i.test(e.eventName) && e.ms <= t1
  );
  const finDet = enVentana.find(
    (e) => /fin de detenido/i.test(e.eventName) && e.ms >= t0
  );
  if (inicioDet) {
    const desde = inicioDet.ms;
    const hasta = finDet ? finDet.ms : t1;
    if (hasta - desde >= DUR_MIN_PAUSA_SEG * 1000) {
      return {
        resultado: "detenido",
        nota: `El GPS confirma que estuviste detenido de ${hhmm(desde)} a ${hhmm(hasta)}.`,
      };
    }
  }

  // MOVIMIENTO: velocidad clara y sostenida dentro de la franja (no solo el
  // pico de cuando arranca). Exigimos ≥2 muestras > umbral DENTRO de [t0,t1].
  const dentro = enVentana.filter((e) => e.ms >= t0 && e.ms <= t1);
  const andando = dentro.filter((e) => (e.speed ?? 0) > UMBRAL_MOVIMIENTO_KMH);
  if (andando.length >= 2) {
    const velMax = Math.max(...andando.map((e) => e.speed ?? 0));
    const cuando = hhmm(andando[0].ms);
    return {
      resultado: "movimiento",
      nota:
        `El GPS te registra en movimiento en esa franja (a las ${cuando} ` +
        `ibas a ${Math.round(velMax)} km/h); no figura una parada ahí.`,
    };
  }

  return { resultado: "incierto", nota: "el GPS no es concluyente en la franja" };
}

/** Decisión final de cierre para UN reclamo. null = dejar para revisión manual. */
export function decidirCierre(p: {
  detalle: string;
  fechaArt: string;
  reporteMs: number;
  pausasV3: PausaV3[];
  eventosGps: GpsEvento[];
}): Decision {
  const v3 = v3ConfirmaPausa(p.detalle, p.fechaArt, p.pausasV3, p.reporteMs);
  if (v3.confirma) return { veredicto: "cierto", nota: v3.nota };

  const ventana = ventanaReclamada(p.detalle, p.fechaArt);
  if (!ventana) return null; // sin hora concreta (ej. justifica un exceso) → manual

  const gps = analizarGpsVentana(p.eventosGps, ventana.t0, ventana.t1);
  if (gps.resultado === "detenido") return { veredicto: "cierto", nota: gps.nota };
  if (gps.resultado === "movimiento") return { veredicto: "no_cierto", nota: gps.nota };
  return null; // incierto → manual
}

// ── Cloud Function (cron 08:00 ART) ──────────────────────────────────────────

async function cierreActivo(): Promise<boolean> {
  try {
    const snap = await db.collection("META").doc("config_cierre_reportes").get();
    // Activo por default; SOLO se apaga con el kill-switch explícito activo:false.
    return !(snap.exists && snap.data()?.activo === false);
  } catch (e) {
    // Un error de LECTURA del flag no es el kill-switch. La semántica
    // declarada arriba ("sin ese doc — o con activo:true — corre normal")
    // equipara ausencia con activo; un error transitorio de Firestore no
    // debe apagar la corrida en silencio: el log de APAGADO era
    // indistinguible del kill-switch real y los reclamos del día quedaban
    // pendientes sin que nadie se entere (auditoría 2026-06-12).
    logger.warn(
      "[cierreReportesJornada] error leyendo el kill-switch — asumo ACTIVO",
      e
    );
    return true;
  }
}

/** YYYY-MM-DD ART de un Timestamp. */
function fechaArtIso(ts: Timestamp | undefined): string {
  const d = ts?.toDate ? ts.toDate() : new Date();
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(d);
}

async function pausasV3DelDia(dni: string, fechaArt: string): Promise<PausaV3[]> {
  const snap = await db
    .collection("REGISTRO_JORNADAS")
    .where("chofer_dni", "==", dni)
    .where("fecha", "==", fechaArt)
    .get();
  const out: PausaV3[] = [];
  for (const d of snap.docs) {
    for (const p of (d.data().pausas ?? []) as Record<string, unknown>[]) {
      const inicioMs = (p.inicio as Timestamp)?.toMillis?.() ?? 0;
      const finMs = (p.fin as Timestamp)?.toMillis?.() ?? 0;
      out.push({
        inicioMs,
        finMs,
        durSeg: (p.dur_seg as number) ?? Math.round((finMs - inicioMs) / 1000),
      });
    }
  }
  return out;
}

async function eventosGpsDelDia(dni: string, fechaArt: string): Promise<GpsEvento[]> {
  const desde = new Date(`${fechaArt}T00:00:00-03:00`);
  const hasta = new Date(`${fechaArt}T23:59:59-03:00`);
  const snap = await db
    .collection("SITRACK_EVENTOS")
    .where("report_date", ">=", Timestamp.fromDate(desde))
    .where("report_date", "<=", Timestamp.fromDate(hasta))
    .get();
  const out: GpsEvento[] = [];
  snap.forEach((doc) => {
    const e = doc.data();
    if (String(e.driver_dni ?? "") !== dni) return;
    const ms = (e.report_date as Timestamp)?.toMillis?.();
    if (!ms) return;
    out.push({
      ms,
      speed: typeof e.speed === "number" ? e.speed : null,
      eventName: String(e.event_name ?? ""),
    });
  });
  return out;
}

export const cerrarReportesJornadaDiario = onScheduleConLatido(
  "cerrarReportesJornadaDiario",
  {
    schedule: "0 8 * * *",
    timeZone: TZ,
    // Hace N reads SERIALES por reclamo (REGISTRO_JORNADAS + un día entero
    // de SITRACK_EVENTOS): con ~20 reclamos pendientes supera fácil los
    // 60s/256MB default (auditoría 2026-06-12). Mismos valores que el cron
    // hermano cruzarParadasReportadasV3Diario.
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async () => {
    const activo = await cierreActivo();
    const modo = activo ? "ACTIVO" : "APAGADO";

    // Idempotencia diaria (mismo patrón que los 4 crons de resúmenes): un
    // double-trigger de Cloud Scheduler no debe procesar los reclamos dos
    // veces. Solo se toma el lock en modo ACTIVO — el dry-run (kill-switch
    // apagado) no escribe nada, puede correr n veces y NO debe "consumir"
    // el día (permite re-disparo manual el mismo día tras re-activar).
    const histRef = db
      .collection("AVISOS_AUTOMATICOS_HISTORICO")
      .doc(`cierre_reportes_${fechaArtIso(undefined)}`);
    if (
      activo &&
      !(await adquirirIdempotenciaDiaria(histRef, "cierre_reportes_jornada"))
    ) {
      logger.info("[cierreReportesJornada] ya corrió hoy, skip");
      return;
    }

    // Si la corrida falla a mitad, liberamos el lock para que un retry del
    // scheduler (o un disparo manual) pueda completar los reclamos del día.
    let exitoCron = false;
    try {
      const snap = await db
        .collection("REPORTES_DISCREPANCIA")
        .where("estado", "==", "pendiente")
        .get();
      const pendientes = snap.docs.filter((d) => {
        const r = d.data();
        // Solo reclamos DIRECTOS de jornada (los auto de paradas tienen detalle
        // técnico y se manejan aparte; los otros temas no se cruzan con v3).
        return r.tema === "jornada" && r.origen !== "parada_reportada_auto";
      });
      logger.info(
        `[cierreReportesJornada] ${modo} · ${pendientes.length} reclamos de jornada pendientes`
      );

      let cerrados = 0;
      let manual = 0;
      let sinV3 = 0;
      for (const doc of pendientes) {
        const r = doc.data();
        const dni = String(r.chofer_dni ?? "");
        const reporteMs = (r.creado_en as Timestamp)?.toMillis?.() ?? Date.now();
        const fechaArt = fechaArtIso(r.creado_en as Timestamp);
        if (!dni) continue;

        const pausasV3 = await pausasV3DelDia(dni, fechaArt);
        if (pausasV3.length === 0) {
          // No hay turno v3 de ese día todavía (reclamo de hoy, v3 se arma mañana)
          // o el chofer no tuvo jornada. Lo dejamos para el próximo cron.
          sinV3++;
          continue;
        }
        const eventosGps = await eventosGpsDelDia(dni, fechaArt);
        const decision = decidirCierre({
          detalle: String(r.detalle ?? ""),
          fechaArt,
          reporteMs,
          pausasV3,
          eventosGps,
        });

        if (!decision) {
          manual++;
          logger.info(
            `[cierreReportesJornada] ${modo} MANUAL ${r.chofer_nombre ?? dni}: ` +
            `"${String(r.detalle ?? "").slice(0, 60)}" → sin evidencia clara, queda pendiente`
          );
          continue;
        }
        logger.info(
          `[cierreReportesJornada] ${modo} ${decision.veredicto.toUpperCase()} ` +
          `${r.chofer_nombre ?? dni}: ${decision.nota}`
        );
        cerrados++;
        if (!activo) continue; // dry-run: no escribe ni dispara devolución

        await doc.ref.update({
          estado: "revisado",
          veredicto: decision.veredicto,
          nota_revision: decision.nota,
          revisado_por_dni: "BOT_AUTO_V3",
          revisado_por_nombre: "Cierre automático (cron jornada)",
          revisado_en: FieldValue.serverTimestamp(),
        });
      }
      logger.info(
        `[cierreReportesJornada] ${modo} fin · cerrados=${cerrados} ` +
        `manual=${manual} sin-v3=${sinV3}`
      );
      exitoCron = true;
    } finally {
      if (activo && !exitoCron) {
        await liberarLockConReintentos(histRef, "cerrarReportesJornadaDiario");
      }
    }
  }
);
