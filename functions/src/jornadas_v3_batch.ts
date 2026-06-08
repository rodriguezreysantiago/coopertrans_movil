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
import { expiraEnMin, primerNombre } from "./helpers";
import { cargarExcluidos } from "./excluidos";
import {
  EventoJornadaLite,
  RegistroJornada,
  reconstruirJornadas,
  horaMinArt,
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
    // asset_id viene CRUDO → trim+upper, para detectar drift CHOFER_DISTINTO.
    patente: ((data.asset_id ?? "").toString().trim().toUpperCase()) || null,
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

/** Doc id determinístico = `{dni}_{fecha-ART}_{HHMM-inicio-ART}`. Incluye la HORA
 * de inicio porque un chofer puede tener DOS turnos el mismo día calendario
 * (separados por un descanso ≥ 7 h — caso real GARCIA 05-19: turno 09:54 + turno
 * 19:09); con solo la fecha, el 2º pisaba al 1º (pérdida de datos). Sigue siendo
 * idempotente (re-procesar el mismo turno da el mismo inicio → mismo id) y el
 * prefijo antes del 1er `_` sigue siendo el DNI, así que la regla de Firestore
 * (`doc.split('_')[0] == uid`) le da al chofer su propio registro. */
export function docIdRegistro(dni: string, inicioTurnoMs: number): string {
  const hhmm = horaMinArt(inicioTurnoMs).replace(":", "");
  return `${dni}_${fechaArt(inicioTurnoMs)}_${hhmm}`;
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
    recorrido_km: Math.round(r.recorridoKm),
    bloques_excedidos: r.bloquesExcedidos,
    jornada_excedida: r.jornadaExcedida,
    descanso_previo_seg: r.descansoPrevioSeg,
    descanso_insuficiente: r.descansoInsuficiente,
    manejo_nocturno_seg: r.manejoNocturnoSeg,
    veda_excedida: r.vedaExcedida,
    drift_filtrado: r.driftFiltrado,
    confianza: r.confianza,
    bloques: r.bloques.map((b) => ({
      indice: b.indice,
      manejo_neto_seg: b.manejoNetoSeg,
      inicio: Timestamp.fromMillis(b.inicioMs),
      fin: Timestamp.fromMillis(b.finMs),
      excedido: b.excedido,
      km_aprox: b.kmAprox,
      vel_max: b.velMax,
      vel_prom: b.velProm,
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
      // km/vel solo van en segmentos de manejo (las pausas las dejan null).
      km_aprox: s.kmAprox ?? null,
      vel_max: s.velMax ?? null,
      vel_prom: s.velProm ?? null,
    })),
    // Serie velocidad downsampleada (~240 pts) para el gráfico velocidad/tiempo
    // de la UI v3. Forma plana: ts_ms (epoch ms) + speed (km/h, entero).
    serie_velocidad: r.serieVelocidad.map((p) => ({
      ts_ms: p.tsMs,
      speed: p.speed,
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

// ─── Resumen diario de infracciones a Molina (Paso 4 — fuente oficial v3) ─────
//
// Reemplaza la data del resumen del v2 (flags del tick en vivo) por el registro
// v3 a posteriori (preciso). Mismo destinatario (Molina / Seg e Higiene) y mismo
// horario (lo dispara el cron `resumenExcesosJornadaDiario` 08:00 ART, ya que el
// registro v3 se escribe 06:45). El v2 queda solo como aviso preventivo en vivo.

/** DNI de Molina (Seg e Higiene) — mismo destinatario que el resumen v2. */
const MOLINA_DNI = "34730329";
const TTL_RESUMEN_MIN = 24 * 60;

export interface ViolacionJornadaV3 {
  choferDni: string;
  patente: string | null;
  inicioMs: number;
  manejoNetoSeg: number;
  recorridoKm: number;
  confianza: string;
  jornadaExcedida: boolean;
  bloquesExcedidos: number;
  descansoInsuficiente: boolean;
  descansoPrevioSeg: number | null;
  vedaExcedida: boolean;
}

function hhmmDur(s: number): string {
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return `${h}:${m.toString().padStart(2, "0")}`;
}

/**
 * Texto del resumen diario de jornadas con incidencias para Molina, a partir del
 * registro v3. PURA — testeable sin Firestore.
 */
export function construirMensajeResumenV3(
  viol: ViolacionJornadaV3[],
  nombrePorDni: Map<string, string>,
  saludo: string,
  fmtFecha: string,
): string {
  const cierre = "_Bot-On — Coopertrans Móvil_";
  const header = `📋 *Resumen jornadas (registro v3) — ${fmtFecha}*`;
  if (viol.length === 0) {
    return (
      `${saludo},\n\n${header}\n\n` +
      "✅ Sin incidencias: ninguna jornada de ayer registró exceso de bloque, " +
      "jornada > 12 h, descanso corto ni veda nocturna.\n\n" +
      `${cierre}`
    );
  }
  const lineas = viol.map((x) => {
    const nombre = nombrePorDni.get(x.choferDni) || `DNI ${x.choferDni}`;
    const flags: string[] = [];
    if (x.bloquesExcedidos > 0) {
      flags.push(`${x.bloquesExcedidos} bloque(s) > 4 h sin pausa`);
    }
    if (x.jornadaExcedida) flags.push("jornada > 12 h");
    if (x.descansoInsuficiente && x.descansoPrevioSeg != null) {
      flags.push(`descanso previo ${hhmmDur(x.descansoPrevioSeg)} (< 8 h)`);
    }
    if (x.vedaExcedida) flags.push("circuló en veda nocturna (00:00–06:00)");
    const conf = x.confianza !== "alta" ? ` · confianza ${x.confianza}` : "";
    return (
      `🚛 *${x.patente || "—"}* — ${nombre} (DNI ${x.choferDni})\n` +
      `   Arrancó ${horaMinArt(x.inicioMs)} · ${hhmmDur(x.manejoNetoSeg)} hs ` +
      `manejo · ${x.recorridoKm} km${conf}\n` +
      `   ⚠️ ${flags.join(", ")}`
    );
  });
  return (
    `${saludo},\n\n${header}\n\n` +
    `${viol.length} jornada${viol.length === 1 ? "" : "s"} con incidencias:\n\n` +
    `${lineas.join("\n\n")}\n\n` +
    "_Registro reconstruido a posteriori desde Sitrack (señales de contacto/" +
    "detenido + corroboración por distancia). 'confianza media/baja' = hubo " +
    "tramos sin reporte; verificá antes de accionar._\n\n" +
    `${cierre}`
  );
}

/**
 * Arma y encola el resumen v3 de infracciones de AYER a Molina. Lo llama el cron
 * `resumenExcesosJornadaDiario` (08:00 ART). Lee REGISTRO_JORNADAS (fecha=ayer).
 */
export async function armarResumenJornadasV3Diario(): Promise<void> {
  logger.info("[jornadas_v3.resumen] iniciando");
  const fechaAyer = fechaArt(Date.now() - 24 * 60 * 60 * 1000);

  const snap = await db.collection(COLECCION_REGISTRO)
    .where("fecha", "==", fechaAyer).get();
  const excluidos = await cargarExcluidos(db);

  const viol: ViolacionJornadaV3[] = [];
  for (const d of snap.docs) {
    const r = d.data();
    const tiene =
      r.jornada_excedida === true ||
      ((r.bloques_excedidos as number) ?? 0) > 0 ||
      r.descanso_insuficiente === true ||
      r.veda_excedida === true;
    if (!tiene) continue;
    const dni = (r.chofer_dni ?? "").toString();
    if (excluidos.dnis.has(dni)) continue;
    viol.push({
      choferDni: dni,
      patente: (r.patente as string | null) ?? null,
      inicioMs: (r.inicio_turno as Timestamp | undefined)?.toMillis() ?? 0,
      manejoNetoSeg: (r.manejo_neto_seg as number) ?? 0,
      recorridoKm: (r.recorrido_km as number) ?? 0,
      confianza: (r.confianza as string) ?? "alta",
      jornadaExcedida: r.jornada_excedida === true,
      bloquesExcedidos: (r.bloques_excedidos as number) ?? 0,
      descansoInsuficiente: r.descanso_insuficiente === true,
      descansoPrevioSeg: (r.descanso_previo_seg as number | null) ?? null,
      vedaExcedida: r.veda_excedida === true,
    });
  }
  viol.sort((a, b) => a.inicioMs - b.inicioMs);

  const empSnap = await db.collection("EMPLEADOS").doc(MOLINA_DNI).get();
  if (!empSnap.exists) {
    logger.error("[jornadas_v3.resumen] destinatario no existe", {
      dni: MOLINA_DNI,
    });
    return;
  }
  const empData = empSnap.data() ?? {};
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") {
    logger.error("[jornadas_v3.resumen] destinatario sin TELEFONO");
    return;
  }
  const apodo = (empData.APODO ?? "").toString().trim();
  const saludoNombre =
    apodo || primerNombre((empData.NOMBRE ?? "").toString().trim()) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";
  const fmtFecha = fechaAyer.split("-").reverse().join("/");

  const nombrePorDni = new Map<string, string>();
  const dnis = new Set(viol.map((v) => v.choferDni));
  if (dnis.size > 0) {
    try {
      const refs = [...dnis].map((dni) => db.collection("EMPLEADOS").doc(dni));
      const snaps = await db.getAll(...refs);
      for (const s of snaps) {
        nombrePorDni.set(
          s.id, s.exists ? (s.data()?.NOMBRE ?? "").toString().trim() : "");
      }
    } catch (e) {
      logger.warn("[jornadas_v3.resumen] getAll nombres falló", {
        error: (e as Error).message,
      });
    }
  }

  const mensaje = construirMensajeResumenV3(
    viol, nombrePorDni, saludo, fmtFecha);
  await db.collection("COLA_WHATSAPP").add({
    telefono: tel, mensaje, estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    expira_en: expiraEnMin(TTL_RESUMEN_MIN),
    enviado_en: null, error: null, intentos: 0,
    origen: "resumen_jornadas_v3", destinatario_coleccion: "EMPLEADOS",
    destinatario_id: MOLINA_DNI, campo_base: "JORNADA",
    admin_dni: "BOT", admin_nombre: "Bot resumen jornadas v3",
  });
  logger.info("[jornadas_v3.resumen] OK", {
    incidencias: viol.length, destinatario: MOLINA_DNI,
  });
}
