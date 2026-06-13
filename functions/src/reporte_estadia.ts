/**
 * Reporte de estadía en plantas YPF (Fase 2 auditoría — "detention report").
 *
 * Sobre `ZONA_DESCARGA_HISTORICO` (que ya fluye: cada estadía de una unidad
 * dentro de una geocerca YPF, con entrada/salida/duración). Produce:
 *   - por PLANTA: n estadías, promedio/mediana/máx de minutos, % sobre umbral.
 *   - TOP unidades retenidas (por minutos totales).
 *   - por FRANJA horaria de entrada (madrugada/mañana/tarde/noche).
 *
 * Dos consumidores:
 *   - `reporteEstadiaYpf` (callable admin/sup, rango parametrizable) → lo usa la
 *     pantalla (release) y consultas on-demand.
 *   - `resumenEstadiaYpfSemanal` (cron, lunes 08:00 ART) → arma el resumen de la
 *     semana anterior, lo manda por WhatsApp al destinatario `reporteEstadiaYpf`
 *     (fallback Santiago) y lo guarda en `STATS/reporte_estadia_ypf`.
 *
 * Argumento duro para negociar turnos con YPF.
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { Timestamp, FieldValue } from "firebase-admin/firestore";
import { db } from "./setup";
import {
  onScheduleConLatido,
  obtenerDestinatarioDni,
  adquirirIdempotenciaDiaria,
  MANTENIMIENTO_DESTINATARIO_DNI,
} from "./comun";
import { expiraEnMin } from "./helpers";

const UMBRAL_MIN_DEFAULT = 120; // estadía "larga" (alineado con la alerta de cola)
const TOP_UNIDADES = 10;
const TTL_RESUMEN_MIN = 24 * 60;

// ─── Lógica PURA (testeada en reporte_estadia.test.js) ───────────────────────

/** Registro mínimo de una estadía para el cálculo (sin tipos Firestore). */
export interface EstadiaRec {
  slug: string;
  nombre: string;
  patente: string;
  choferNombre: string;
  horaArt: number; // hora de ENTRADA en ART (0-23) → franja
  duracionMin: number;
}

export interface ReporteEstadia {
  totalEstadias: number;
  umbralMin: number;
  porPlanta: Array<{
    slug: string; nombre: string; n: number;
    promedioMin: number; medianaMin: number; maxMin: number;
    totalMin: number; pctSobreUmbral: number;
  }>;
  topUnidades: Array<{
    patente: string; n: number; totalMin: number;
    promedioMin: number; maxMin: number;
  }>;
  porFranja: Array<{ franja: string; n: number; promedioMin: number }>;
}

/** Franja horaria de una hora ART (0-23). PURA. */
export function franjaDeHora(h: number): string {
  if (h < 0 || h > 23) return "desconocida";
  if (h < 6) return "madrugada";
  if (h < 12) return "mañana";
  if (h < 18) return "tarde";
  return "noche";
}

const _prom = (xs: number[]): number =>
  xs.length ? Math.round(xs.reduce((a, b) => a + b, 0) / xs.length) : 0;

const _mediana = (xs: number[]): number => {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor((s.length - 1) / 2)]; // mediana baja (suficiente p/ reporte)
};

/**
 * Agrega las estadías en el reporte de detention. PURA. `umbralMin` define
 * "estadía larga" para el % sobre umbral. Ordena plantas por promedio desc y
 * unidades por minutos totales desc (las más retenidas primero).
 */
export function computarReporteEstadia(
  estadias: EstadiaRec[],
  umbralMin: number = UMBRAL_MIN_DEFAULT,
  topN: number = TOP_UNIDADES,
): ReporteEstadia {
  const porPlantaMap = new Map<string, { nombre: string; dur: number[] }>();
  const porUnidadMap = new Map<string, number[]>();
  const porFranjaMap = new Map<string, number[]>();

  for (const e of estadias) {
    const p = porPlantaMap.get(e.slug) ?? { nombre: e.nombre, dur: [] };
    p.dur.push(e.duracionMin);
    porPlantaMap.set(e.slug, p);

    const u = porUnidadMap.get(e.patente) ?? [];
    u.push(e.duracionMin);
    porUnidadMap.set(e.patente, u);

    const fr = franjaDeHora(e.horaArt);
    const f = porFranjaMap.get(fr) ?? [];
    f.push(e.duracionMin);
    porFranjaMap.set(fr, f);
  }

  const porPlanta = [...porPlantaMap.entries()].map(([slug, v]) => ({
    slug,
    nombre: v.nombre,
    n: v.dur.length,
    promedioMin: _prom(v.dur),
    medianaMin: _mediana(v.dur),
    maxMin: Math.max(...v.dur),
    totalMin: v.dur.reduce((a, b) => a + b, 0),
    pctSobreUmbral: Math.round(
      (v.dur.filter((d) => d > umbralMin).length / v.dur.length) * 100),
  })).sort((a, b) => b.promedioMin - a.promedioMin);

  const topUnidades = [...porUnidadMap.entries()].map(([patente, dur]) => ({
    patente,
    n: dur.length,
    totalMin: dur.reduce((a, b) => a + b, 0),
    promedioMin: _prom(dur),
    maxMin: Math.max(...dur),
  })).sort((a, b) => b.totalMin - a.totalMin).slice(0, topN);

  const ordenFranja = ["madrugada", "mañana", "tarde", "noche"];
  const porFranja = [...porFranjaMap.entries()].map(([franja, dur]) => ({
    franja,
    n: dur.length,
    promedioMin: _prom(dur),
  })).sort((a, b) => ordenFranja.indexOf(a.franja) - ordenFranja.indexOf(b.franja));

  return {
    totalEstadias: estadias.length,
    umbralMin,
    porPlanta,
    topUnidades,
    porFranja,
  };
}

const _hhmm = (min: number): string => {
  const h = Math.floor(min / 60);
  const m = min % 60;
  return h > 0 ? `${h}h${String(m).padStart(2, "0")}` : `${m}min`;
};

/** Arma el texto WhatsApp del resumen semanal. PURA. */
export function formatearMensajeEstadia(
  rep: ReporteEstadia,
  rangoLabel: string,
): string {
  if (rep.totalEstadias === 0) {
    return `🏭 *Estadía plantas YPF* — ${rangoLabel}\n\nSin estadías registradas en el período.`;
  }
  const lineas: string[] = [];
  lineas.push(`🏭 *Estadía plantas YPF* — ${rangoLabel}`);
  lineas.push(`${rep.totalEstadias} estadías · umbral ${_hhmm(rep.umbralMin)}`);
  lineas.push("");
  lineas.push("*Por planta* (promedio · máx · n · % largas):");
  for (const p of rep.porPlanta) {
    lineas.push(
      `• ${p.nombre}: ${_hhmm(p.promedioMin)} · máx ${_hhmm(p.maxMin)} · ` +
      `${p.n} · ${p.pctSobreUmbral}%`);
  }
  lineas.push("");
  lineas.push("*Top unidades retenidas* (tiempo total):");
  for (const u of rep.topUnidades.slice(0, 5)) {
    lineas.push(`• ${u.patente}: ${_hhmm(u.totalMin)} en ${u.n} estadías`);
  }
  if (rep.porFranja.length) {
    lineas.push("");
    lineas.push("*Por franja de entrada* (promedio):");
    for (const f of rep.porFranja) {
      lineas.push(`• ${f.franja}: ${_hhmm(f.promedioMin)} (${f.n})`);
    }
  }
  return lineas.join("\n");
}

// ─── I/O ─────────────────────────────────────────────────────────────────────

/** Hora (0-23) de un Timestamp en horario ART. */
function horaArtDe(ts: Timestamp): number {
  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: "America/Argentina/Buenos_Aires",
    hour: "2-digit",
    hour12: false,
  });
  const h = parseInt(fmt.format(ts.toDate()), 10);
  // h12:false usa reloj h23 (medianoche = 0, nunca 24); el `===24` es guard
  // defensivo por si algún runtime usara h24.
  return Number.isFinite(h) ? (h === 24 ? 0 : h) : 0;
}

/** Carga las estadías de [desde, hasta) y las mapea a EstadiaRec (paginado).
 *  Query de un solo campo (entrada_ts) → la sirve el índice single-field
 *  AUTOMÁTICO de Firestore; no requiere índice compuesto en indexes.json. */
async function cargarEstadias(desde: Date, hasta: Date): Promise<EstadiaRec[]> {
  const recs: EstadiaRec[] = [];
  let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
  for (;;) {
    let q = db.collection("ZONA_DESCARGA_HISTORICO")
      .where("entrada_ts", ">=", Timestamp.fromDate(desde))
      .where("entrada_ts", "<", Timestamp.fromDate(hasta))
      .orderBy("entrada_ts", "asc")
      .limit(2000);
    if (cursor) q = q.startAfter(cursor);
    const snap = await q.get();
    if (snap.empty) break;
    for (const d of snap.docs) {
      const data = d.data();
      const entrada = data.entrada_ts as Timestamp | undefined;
      if (!entrada) continue;
      recs.push({
        slug: (data.slug_zona ?? "").toString(),
        nombre: (data.nombre_zona ?? data.slug_zona ?? "—").toString(),
        patente: (data.patente ?? "—").toString(),
        choferNombre: (data.chofer_nombre ?? "").toString(),
        horaArt: horaArtDe(entrada),
        duracionMin: Number(data.duracion_min ?? 0),
      });
    }
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < 2000) break;
  }
  return recs;
}

// ─── Callable: reporte on-demand (lo usa la pantalla / consultas ad-hoc) ─────

export const reporteEstadiaYpf = onCall(
  { timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    const rol = request.auth?.token?.rol;
    if (!request.auth || (rol !== "ADMIN" && rol !== "SUPERVISOR")) {
      throw new HttpsError(
        "permission-denied",
        "Solo ADMIN o SUPERVISOR pueden ver el reporte de estadía.");
    }
    const desdeStr = (request.data?.desde ?? "").toString();
    const hastaStr = (request.data?.hasta ?? "").toString();
    // 'YYYY-MM-DD' (date-only) lo tomaría new Date() como UTC midnight (−3h vs
    // ART) → rango corrido. Anclamos a 03:00Z = 00:00 ART. (El cron no usa esto:
    // ventanaSemanaAnterior ya ancla bien.)
    const aFecha = (s: string): Date | null => {
      if (!s) return null;
      const iso = /^\d{4}-\d{2}-\d{2}$/.test(s) ? `${s}T03:00:00.000Z` : s;
      const d = new Date(iso);
      return isNaN(d.getTime()) ? null : d;
    };
    const desde = aFecha(desdeStr);
    const hasta = aFecha(hastaStr);
    if (!desde || !hasta || hasta <= desde) {
      throw new HttpsError(
        "invalid-argument",
        "Pasá `desde` y `hasta` válidos (YYYY-MM-DD, con hasta > desde).");
    }
    // Cap defensivo: evita una query enorme accidental (un supervisor pidiendo
    // meses). 92 días = un trimestre, cubre cualquier ventana razonable.
    const MAX_DIAS = 92;
    if ((hasta.getTime() - desde.getTime()) / 864e5 > MAX_DIAS) {
      throw new HttpsError(
        "invalid-argument", `El rango no puede superar ${MAX_DIAS} días.`);
    }
    const umbral = Number(request.data?.umbralMin ?? UMBRAL_MIN_DEFAULT);
    const estadias = await cargarEstadias(desde, hasta);
    return computarReporteEstadia(
      estadias, Number.isFinite(umbral) ? umbral : UMBRAL_MIN_DEFAULT);
  },
);

// ─── Cron semanal: resumen de la semana anterior por WhatsApp ────────────────

/** [lunes 00:00, lunes 00:00) de la semana ANTERIOR, en ART. PURA (testeada). */
export function ventanaSemanaAnterior(ahora: Date): {
  desde: Date; hasta: Date; label: string;
} {
  // Día de la semana en ART (0=dom..6=sáb) y fecha YYYY-MM-DD ART.
  const fmtDow = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Argentina/Buenos_Aires", weekday: "short",
  });
  const fmtYmd = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric", month: "2-digit", day: "2-digit",
  });
  const dowMap: Record<string, number> = {
    Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6,
  };
  const dowKey = fmtDow.format(ahora);
  const dow = dowMap[dowKey];
  // Si el runtime devuelve un nombre de día inesperado, fallar ruidoso (lo caza
  // el watchdog) en vez de asumir lunes y reportar la semana equivocada.
  if (dow === undefined) {
    throw new Error(`ventanaSemanaAnterior: día desconocido '${dowKey}'`);
  }
  // Medianoche ART de hoy, como instante UTC: tomamos la fecha ART y le
  // anclamos 03:00Z (ART = UTC-3 todo el año) = 00:00 ART.
  const hoyYmd = fmtYmd.format(ahora); // YYYY-MM-DD
  const medianocheHoyArt = new Date(`${hoyYmd}T03:00:00.000Z`);
  // Lunes de ESTA semana (días desde el lunes: lun=0..dom=6).
  const desdeLunes = (dow + 6) % 7;
  const lunesEsta = new Date(medianocheHoyArt.getTime() - desdeLunes * 864e5);
  const hasta = lunesEsta; // exclusivo (inicio de esta semana)
  const desde = new Date(lunesEsta.getTime() - 7 * 864e5); // lunes anterior
  const finInclusivo = new Date(hasta.getTime() - 864e5);
  // dd/mm con ceros desde el YYYY-MM-DD ART (en-CA SÍ respeta 2-digit; es-AR no).
  const ddmm = (d: Date): string => {
    const s = fmtYmd.format(d); // YYYY-MM-DD
    return `${s.slice(8, 10)}/${s.slice(5, 7)}`;
  };
  return {
    desde, hasta,
    label: `semana ${ddmm(desde)}–${ddmm(finInclusivo)}`,
  };
}

export const resumenEstadiaYpfSemanal = onScheduleConLatido(
  "resumenEstadiaYpfSemanal",
  {
    schedule: "0 8 * * 1", // lunes 08:00 ART
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 300,
    memory: "512MiB",
  },
  async () => {
    const { desde, hasta, label } = ventanaSemanaAnterior(new Date());

    // Idempotencia semanal: Cloud Scheduler tiene semántica at-least-once. Si
    // reintenta el cron (timeout/error tras el add a COLA_WHATSAPP), el receptor
    // recibiría el resumen 2 veces. El lock create-once por semana lo evita
    // (mismo patrón que los resúmenes diarios).
    const idemId = `estadia_ypf_${label.replace(/[^0-9]/g, "_")}`;
    const histRef = db.collection("AVISOS_AUTOMATICOS_HISTORICO").doc(idemId);
    if (!(await adquirirIdempotenciaDiaria(histRef, "reporte_estadia_ypf"))) {
      logger.info("[reporteEstadiaYpf] semana ya procesada — skip", { label });
      return;
    }

    const estadias = await cargarEstadias(desde, hasta);
    const reporte = computarReporteEstadia(estadias);

    // Persistir el último reporte (lo puede leer la pantalla / histórico).
    await db.collection("STATS").doc("reporte_estadia_ypf").set({
      ultimo_label: label,
      ultimo_total: reporte.totalEstadias,
      ultimo_por_planta: reporte.porPlanta,
      ultimo_run_at: Timestamp.now(),
    }, { merge: true });

    if (reporte.totalEstadias === 0) {
      logger.info("[reporteEstadiaYpf] semana sin estadías — no encolo", { label });
      return;
    }

    const dni = await obtenerDestinatarioDni(
      "reporteEstadiaYpf", MANTENIMIENTO_DESTINATARIO_DNI);
    const emp = await db.collection("EMPLEADOS").doc(dni).get();
    const tel = (emp.data()?.TELEFONO ?? "").toString().trim();
    if (!tel) {
      logger.warn("[reporteEstadiaYpf] destinatario sin TELEFONO — no encolo", {
        dni, label,
      });
      return;
    }
    await db.collection("COLA_WHATSAPP").add({
      telefono: tel,
      mensaje: formatearMensajeEstadia(reporte, label),
      estado: "PENDIENTE",
      encolado_en: FieldValue.serverTimestamp(),
      expira_en: expiraEnMin(TTL_RESUMEN_MIN),
      enviado_en: null,
      error: null,
      intentos: 0,
      origen: "reporte_estadia_ypf",
      destinatario_coleccion: "EMPLEADOS",
      destinatario_id: dni,
      campo_base: "REPORTE_ESTADIA_YPF",
      admin_dni: "CRON",
      admin_nombre: "Reporte estadía YPF",
    });
    logger.info("[reporteEstadiaYpf] resumen encolado", {
      label, total: reporte.totalEstadias, plantas: reporte.porPlanta.length,
    });
  },
);
