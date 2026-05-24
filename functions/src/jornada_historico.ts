// =============================================================================
// HISTÓRICO DE JORNADA — reconstruye día completo desde SITRACK_EVENTOS
// =============================================================================
//
// Para cada par (chofer, día ART), agrupa los eventos del día y reconstruye:
//   - Tramos de manejo (velocidad >= 15 km/h sostenida): inicio, fin, km,
//     velocidad máx, velocidad promedio.
//   - Paradas entre tramos: duración + clasificación según política Vecchi v2
//     (cumple_15min para corte de bloque, cumple_8h para fin de jornada).
//   - Serie de velocidad para gráfico (downsampled a 240 puntos máx).
//   - KPIs: manejo total, paradas total, km, velocidad máx, patentes usadas.
//
// Reusa los UMBRALES de `jornadas_v2.ts` (UMBRAL_MOVIMIENTO_KMH=15,
// PAUSA_BLOQUE_SEGUNDOS=900, DESCANSO_MIN_SEGUNDOS=28800) para que el
// modelo de "descanso suficiente" coincida con el vigilador en vivo.
//
// Datos en `VOLVO_JORNADAS_HISTORICO/{dni}_{YYYY-MM-DD}` (doc id
// determinístico → idempotente).
//
// 2 functions exportadas:
//   - reconstruirJornadasDiario: cron 06:30 ART (procesa AYER, después
//     del cron de iButtons que corre a las 06:00).
//   - backfillJornadas: callable ADMIN para procesar N días pasados.
//
// El módulo "Jornada" del hub ICM lee directamente de esta colección.

import { onSchedule } from "firebase-functions/v2/scheduler";
import { onCall } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";
import { adquirirLockTick } from "./index";
import {
  UMBRAL_MOVIMIENTO_KMH,
  PAUSA_BLOQUE_SEGUNDOS,
  DESCANSO_MIN_SEGUNDOS,
} from "./jornadas_v2";

const VEL_MOVIMIENTO = UMBRAL_MOVIMIENTO_KMH; // 15 km/h
const PAUSA_MIN_MS = PAUSA_BLOQUE_SEGUNDOS * 1000; // 15 min
const DESCANSO_MIN_MS = DESCANSO_MIN_SEGUNDOS * 1000; // 8 h

/** Cap de puntos en la serie del gráfico — 240 = 1 punto cada 6 min en
 *  un día de 24h. Suficiente resolución para ver subidas/bajadas en la UI
 *  sin que el doc de Firestore se infle. */
const MAX_PUNTOS_GRAFICO = 240;

// ============================================================================
// Tipos públicos (también los usa la suite de tests)
// ============================================================================

export interface EventoIn {
  ts: Date;
  speed: number;
  ignition: boolean;
  patente: string;
  driverDni: string;
  driverName?: string;
  lat?: number;
  lng?: number;
  odometer?: number;
}

export interface Parada {
  desde: Date;
  hasta: Date;
  duracion_min: number;
  lat?: number;
  lng?: number;
  /** Cumple corte de bloque (>= 15 min). */
  cumple_15min: boolean;
  /** Cumple descanso entre jornadas (>= 8h). */
  cumple_8h: boolean;
}

export interface TramoManejo {
  desde: Date;
  hasta: Date;
  duracion_min: number;
  km_aprox: number;
  velocidad_max: number;
  velocidad_prom: number;
}

export interface JornadaDia {
  chofer_dni: string;
  chofer_nombre?: string;
  patente_principal: string;
  patentes: string[];
  fecha: string;
  inicio: Date;
  fin: Date;
  manejo_min: number;
  paradas_min: number;
  tramos: TramoManejo[];
  paradas: Parada[];
  serie_velocidad: { ts_ms: number; speed: number }[];
  km_total: number;
  velocidad_max: number;
  total_eventos: number;
}

// ============================================================================
// Función pura — testeable sin Firestore
// ============================================================================

/** Reconstruye la jornada de un (chofer, día) a partir de sus eventos
 *  Sitrack ordenados. Devuelve `null` si el chofer no manejó (sin tramos
 *  > 1 min con velocidad >= 15 km/h). */
export function reconstruirJornadaDia(
  dni: string,
  fecha: string,
  eventosRaw: EventoIn[],
): JornadaDia | null {
  if (eventosRaw.length === 0) return null;

  const eventos = [...eventosRaw].sort(
    (a, b) => a.ts.getTime() - b.ts.getTime(),
  );

  const tramos: TramoManejo[] = [];
  const paradas: Parada[] = [];

  type Estado = "inicial" | "moviendo" | "parado";
  let estado: Estado = "inicial";

  let bufferDesde: EventoIn | null = null;
  let bufferUltimo: EventoIn | null = null;
  let bufferSpeedMax = 0;
  let bufferSpeedSum = 0;
  let bufferCount = 0;
  let bufferOdometroInicio: number | undefined;

  const cerrarTramo = () => {
    if (!bufferDesde || !bufferUltimo) return;
    const durMs = bufferUltimo.ts.getTime() - bufferDesde.ts.getTime();
    if (durMs >= 60_000) {
      const odoFin = bufferUltimo.odometer;
      const odoIni = bufferOdometroInicio;
      const km = (odoFin != null && odoIni != null && odoFin >= odoIni) ?
        Math.round(odoFin - odoIni) :
        0;
      tramos.push({
        desde: bufferDesde.ts,
        hasta: bufferUltimo.ts,
        duracion_min: Math.round(durMs / 60_000),
        km_aprox: km,
        velocidad_max: Math.round(bufferSpeedMax),
        velocidad_prom: bufferCount > 0 ?
          Math.round(bufferSpeedSum / bufferCount) :
          0,
      });
    }
    bufferDesde = null;
    bufferUltimo = null;
    bufferSpeedMax = 0;
    bufferSpeedSum = 0;
    bufferCount = 0;
    bufferOdometroInicio = undefined;
  };

  const cerrarParada = () => {
    if (!bufferDesde || !bufferUltimo) return;
    const durMs = bufferUltimo.ts.getTime() - bufferDesde.ts.getTime();
    if (durMs >= 60_000) {
      paradas.push({
        desde: bufferDesde.ts,
        hasta: bufferUltimo.ts,
        duracion_min: Math.round(durMs / 60_000),
        lat: bufferDesde.lat,
        lng: bufferDesde.lng,
        cumple_15min: durMs >= PAUSA_MIN_MS,
        cumple_8h: durMs >= DESCANSO_MIN_MS,
      });
    }
    bufferDesde = null;
    bufferUltimo = null;
  };

  for (const e of eventos) {
    const moviendo = e.speed >= VEL_MOVIMIENTO;
    if (moviendo) {
      if (estado === "parado") cerrarParada();
      if (estado !== "moviendo") {
        bufferDesde = e;
        bufferOdometroInicio = e.odometer;
        bufferSpeedMax = e.speed;
        bufferSpeedSum = e.speed;
        bufferCount = 1;
        estado = "moviendo";
      } else {
        bufferSpeedMax = Math.max(bufferSpeedMax, e.speed);
        bufferSpeedSum += e.speed;
        bufferCount++;
      }
      bufferUltimo = e;
    } else {
      if (estado === "moviendo") cerrarTramo();
      if (estado !== "parado") {
        bufferDesde = e;
        estado = "parado";
      }
      bufferUltimo = e;
    }
  }
  if (estado === "moviendo") cerrarTramo();
  else if (estado === "parado") cerrarParada();

  if (tramos.length === 0) return null;

  const inicio = tramos[0].desde;
  const fin = tramos[tramos.length - 1].hasta;
  const manejo_min = tramos.reduce((s, t) => s + t.duracion_min, 0);
  const paradas_min = paradas.reduce((s, p) => s + p.duracion_min, 0);
  const km_total = tramos.reduce((s, t) => s + t.km_aprox, 0);
  const velocidad_max = tramos.reduce(
    (m, t) => Math.max(m, t.velocidad_max), 0,
  );

  // Downsample serie velocidad para gráfico
  const step = Math.max(1, Math.ceil(eventos.length / MAX_PUNTOS_GRAFICO));
  const serie: { ts_ms: number; speed: number }[] = [];
  for (let i = 0; i < eventos.length; i += step) {
    const e = eventos[i];
    serie.push({ ts_ms: e.ts.getTime(), speed: Math.round(e.speed) });
  }
  // Asegurar último punto incluido
  if (eventos.length > 0 && serie[serie.length - 1].ts_ms !==
      eventos[eventos.length - 1].ts.getTime()) {
    const last = eventos[eventos.length - 1];
    serie.push({ ts_ms: last.ts.getTime(), speed: Math.round(last.speed) });
  }

  const patenteCount = new Map<string, number>();
  for (const e of eventos) {
    patenteCount.set(e.patente, (patenteCount.get(e.patente) || 0) + 1);
  }
  const patentes = Array.from(patenteCount.keys());
  const patente_principal = patentes.sort(
    (a, b) => (patenteCount.get(b) || 0) - (patenteCount.get(a) || 0),
  )[0];

  const choferName = eventos.find((e) => e.driverName)?.driverName;

  return {
    chofer_dni: dni,
    chofer_nombre: choferName,
    patente_principal,
    patentes,
    fecha,
    inicio,
    fin,
    manejo_min,
    paradas_min,
    tramos,
    paradas,
    serie_velocidad: serie,
    km_total,
    velocidad_max,
    total_eventos: eventos.length,
  };
}

// ============================================================================
// Persistencia
// ============================================================================

function jornadaToFirestore(j: JornadaDia): Record<string, unknown> {
  return {
    chofer_dni: j.chofer_dni,
    chofer_nombre: j.chofer_nombre ?? null,
    patente_principal: j.patente_principal,
    patentes: j.patentes,
    fecha: j.fecha,
    inicio: Timestamp.fromDate(j.inicio),
    fin: Timestamp.fromDate(j.fin),
    manejo_min: j.manejo_min,
    paradas_min: j.paradas_min,
    km_total: j.km_total,
    velocidad_max: j.velocidad_max,
    total_eventos: j.total_eventos,
    tramos: j.tramos.map((t) => ({
      desde: Timestamp.fromDate(t.desde),
      hasta: Timestamp.fromDate(t.hasta),
      duracion_min: t.duracion_min,
      km_aprox: t.km_aprox,
      velocidad_max: t.velocidad_max,
      velocidad_prom: t.velocidad_prom,
    })),
    paradas: j.paradas.map((p) => ({
      desde: Timestamp.fromDate(p.desde),
      hasta: Timestamp.fromDate(p.hasta),
      duracion_min: p.duracion_min,
      lat: p.lat ?? null,
      lng: p.lng ?? null,
      cumple_15min: p.cumple_15min,
      cumple_8h: p.cumple_8h,
    })),
    serie_velocidad: j.serie_velocidad,
    procesado_en: FieldValue.serverTimestamp(),
  };
}

async function persistirJornada(j: JornadaDia): Promise<void> {
  const docId = `${j.chofer_dni}_${j.fecha}`;
  await db.collection("VOLVO_JORNADAS_HISTORICO")
    .doc(docId)
    .set(jornadaToFirestore(j));
}

// ============================================================================
// Procesar un día completo
// ============================================================================

async function procesarDia(
  desde: Date, hasta: Date, fechaLabel: string,
): Promise<{ eventos: number; choferes: number; jornadas: number }> {
  const snap = await db.collection("SITRACK_EVENTOS")
    .where("report_date", ">=", Timestamp.fromDate(desde))
    .where("report_date", "<", Timestamp.fromDate(hasta))
    .get();

  // Agrupar por driver_dni
  const porDni = new Map<string, EventoIn[]>();
  for (const d of snap.docs) {
    const m = d.data();
    // OJO: la patente está en `asset_id`, no `asset_name` (ver
    // historico_ibuttons.ts comentario). `asset_name` viene vacío
    // en la cuenta ws41629VecchiSRL.
    const patente = (m.asset_id as string | undefined)?.trim().toUpperCase();
    const dni = (m.driver_dni as string | undefined)?.trim();
    const ts = m.report_date as Timestamp | undefined;
    if (!patente || !dni || !ts) continue;

    const speed = typeof m.gps_speed === "number" ?
      m.gps_speed :
      (typeof m.speed === "number" ? m.speed : 0);
    const ignition = m.ignition === 1 || m.ignition === true;
    const lat = typeof m.latitude === "number" ? m.latitude : undefined;
    const lng = typeof m.longitude === "number" ? m.longitude : undefined;
    const odo = typeof m.odometer === "number" ?
      m.odometer :
      (typeof m.gps_odometer === "number" ? m.gps_odometer : undefined);

    const evt: EventoIn = {
      ts: ts.toDate(),
      speed,
      ignition,
      patente,
      driverDni: dni,
      driverName: (m.driver_name as string | undefined)?.trim() || undefined,
      lat,
      lng,
      odometer: odo,
    };
    if (!porDni.has(dni)) porDni.set(dni, []);
    porDni.get(dni)!.push(evt);
  }

  let jornadasOk = 0;
  for (const [dni, eventos] of porDni) {
    const j = reconstruirJornadaDia(dni, fechaLabel, eventos);
    if (!j) continue;
    try {
      await persistirJornada(j);
      jornadasOk++;
    } catch (e) {
      logger.warn("[procesarDia] persistir falló", {
        dni, error: (e as Error).message,
      });
    }
  }

  return {
    eventos: snap.size,
    choferes: porDni.size,
    jornadas: jornadasOk,
  };
}

// ============================================================================
// Cron diario — procesa ayer (06:30 ART, 30 min después del cron iButtons)
// ============================================================================

export const reconstruirJornadasDiario = onSchedule(
  {
    schedule: "30 6 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 540,
    memory: "1GiB",
  },
  async () => {
    const liberar = await adquirirLockTick(
      "reconstruir_jornadas_diario", 9 * 60 * 1000,
    );
    if (!liberar) return;
    try {
      const ahoraArt = new Date(Date.now() - 3 * 60 * 60 * 1000);
      const hoyArt = new Date(Date.UTC(
        ahoraArt.getUTCFullYear(),
        ahoraArt.getUTCMonth(),
        ahoraArt.getUTCDate(),
        3, 0, 0, 0,
      ));
      const ayerArt = new Date(hoyArt.getTime() - 24 * 60 * 60 * 1000);
      const fechaLabel = ayerArt.toISOString().substring(0, 10);
      logger.info("[reconstruirJornadasDiario] iniciando", {
        fecha: fechaLabel,
      });
      const res = await procesarDia(ayerArt, hoyArt, fechaLabel);
      logger.info("[reconstruirJornadasDiario] OK", res);
    } catch (e) {
      logger.error("[reconstruirJornadasDiario] error", {
        error: (e as Error).message,
      });
    } finally {
      await liberar();
    }
  },
);

// ============================================================================
// Callable de backfill
// ============================================================================

export const backfillJornadas = onCall(
  {
    timeoutSeconds: 540,
    memory: "1GiB",
    region: "us-central1",
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

    let totalEv = 0, totalCho = 0, totalJor = 0;
    const detalle: { fecha: string; eventos: number;
      choferes: number; jornadas: number }[] = [];
    for (let i = 1; i <= dias; i++) {
      const fin = new Date(hoyArt.getTime() - (i - 1) * 24 * 60 * 60 * 1000);
      const ini = new Date(fin.getTime() - 24 * 60 * 60 * 1000);
      const fechaLabel = ini.toISOString().substring(0, 10);
      logger.info(`[backfillJornadas] día ${i}/${dias} (${fechaLabel})`);
      try {
        const r = await procesarDia(ini, fin, fechaLabel);
        totalEv += r.eventos;
        totalCho += r.choferes;
        totalJor += r.jornadas;
        detalle.push({ fecha: fechaLabel, ...r });
      } catch (e) {
        logger.error(`[backfillJornadas] error día ${fechaLabel}`, {
          error: (e as Error).message,
        });
        detalle.push({ fecha: fechaLabel, eventos: -1, choferes: -1,
          jornadas: -1 });
      }
    }
    return {
      ok: true,
      dias_procesados: dias,
      total_eventos: totalEv,
      total_choferes: totalCho,
      total_jornadas: totalJor,
      detalle,
    };
  },
);
