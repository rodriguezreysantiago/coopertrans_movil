// ============================================================================
// Vigilador de jornada — v2 (refactor 2026-05-15)
// ============================================================================
//
// Modelo operativo Vecchi (alineado con norma YPF NO_0002913 + Excepción
// Rev01 firmada ago/2025 para carga general):
//
//   Una JORNADA = 24 hs = 12 hs conducción + 12 hs descanso.
//   12 hs conducción = 3 BLOQUES de 4 hs cada uno (3h45 manejo + 15 min pausa).
//     - Total manejo neto por jornada: 11h15 min.
//   12 hs descanso entre jornadas: mínimo 8 hs con camión detenido en MISMA
//   posición (radio 1000 m, margen GPS drift).
//
// La jornada NO se mide por día calendario. Cada jornada es lógica y se
// identifica por su `jornada_inicio_ts`. La colección `JORNADAS` reemplaza
// a la legacy `JORNADAS_CHOFER` (deprecada, se borra con script aparte).
//
// Disparadores que detienen al chofer (cualquiera dispara aviso + flag):
//   1. Bloque actual llegó a 4 hs sin pausa de 15 min → bloque excedido.
//   2. Cumplió 3 bloques → cuota cumplida.
//   3. Hora ART ≥ 00:00 → veda nocturna (política Vecchi: no maneja de noche).
//
// Reanudación: solo después de ≥ 8 hs detenido en misma posición.
//
// Fuente de datos (HÍBRIDA desde 2026-05-21, fix #36):
//   - SITRACK_POSICIONES → QUIÉN maneja (driver_dni del iButton). Volvo no
//     sabe el conductor (drivertimes vacío para Vecchi).
//   - VOLVO_ESTADO → movimiento REAL del camión: speed_kmh + `posicion_ts`
//     (timestamp REAL del reporte del equipo). PRIMARIO.
// El bug que se arregla: la staleness se medía sobre `consultado_en` (cuándo
// NOSOTROS consultamos SITRACK — SIEMPRE fresco), no sobre el reporte real.
// Un camión PARADO cuyo último reporte SITRACK (de hace 30 min) decía 74 km/h
// se contaba como "manejando" → la parada no cerraba el bloque (caso AG218ZD,
// AF869ZU). Volvo da speed=0 con timestamp fresco apenas el camión frena.
// Ver memoria project_volvo_estado_fundacion.md.

import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";

// Helpers compartidos (antes duplicados aca + en index.ts).
// Ver helpers.ts para historia del refactor 2026-05-18.
import { expiraEnMin, primerNombre, rrPick } from "./helpers";
import { cargarExcluidos } from "./excluidos";

// Resolver lazy de Firestore: initializeApp() corre en index.ts antes
// de invocarse cualquier export de este módulo, pero si llamamos
// admin.firestore() al top-level se evalúa durante el import (antes
// del initializeApp). Por eso lo envolvemos en un getter.
function db(): FirebaseFirestore.Firestore {
  return admin.firestore();
}
const Timestamp = admin.firestore.Timestamp;
const FieldValue = admin.firestore.FieldValue;
type FsTimestamp = admin.firestore.Timestamp;

// ─── Constantes ─────────────────────────────────────────────────────────────

export const UMBRAL_MOVIMIENTO_KMH = 15;
export const POLL_STALE_SEGUNDOS = 10 * 60;
// Pausa entre bloques (decision Vecchi 2026-05-18):
//   - Interno (lo que mide el sistema): 15 min — alineado con norma YPF.
//   - Mensajes al chofer: pedimos 20 min — 5 min extra de margen para
//     no quedar cortos por GPS lag de Sitrack (~1-3 min) + para que el
//     chofer no pare justo 15 min y por delay aparezca 14:50 = falla.
//   - Si el chofer obedece (para 20 min reales) -> sistema mide ~17-19 min
//     -> >= 15 min -> bloque cerrado OK.
//   - Si el chofer para solo 15 min -> sistema mide ~12-14 min ->
//     < 15 min -> bloque NO cierra -> sigue manejando ese bloque hasta
//     completar la pausa o llegar a 4h (infraccion).
export const PAUSA_BLOQUE_SEGUNDOS = 15 * 60;
export const BLOQUE_ALERTA_TEMPRANA_SEGUNDOS = 3 * 3600 + 30 * 60; // 3h30
export const BLOQUE_LIMITE_SEGUNDOS = 3 * 3600 + 45 * 60; // 3h45 (fin bloque)
export const BLOQUE_EXCEDIDO_SEGUNDOS = 4 * 3600; // 4h sin pausa = falta
export const BLOQUES_POR_JORNADA = 3;

// Umbrales de aviso por MANEJO NETO acumulado (no por bloques contados).
//
// Fix Santiago 2026-05-19: antes el aviso "12 horas de jornada" se
// disparaba con `bloques_completos >= 3`, pero un bloque se cuenta
// completo con CUALQUIER manejo previo + pausa de 15 min. Un chofer
// que hace pausas cortas y frecuentes (30 min manejo + 20 min pausa
// repetido) llegaba a "3 bloques" con apenas 1h30 manejo neto y le
// salía "Llegás al límite de 12 horas de jornada" — falso positivo
// confuso. Ahora avisamos por manejo NETO real.
//
// Clarificación Santiago 2026-05-19 (segundo mensaje): el LÍMITE son
// 12 hs de manejo neto, no 11 hs. Las paradas obligatorias de 15 min
// entre bloques suceden DENTRO de las 12 hs (la pausa es descanso,
// no manejo, pero la jornada total permitida son 12 hs completas de
// conducción). 3 bloques × 4h continuos = 12h, con las 3 paradas de
// 15 min embebidas.
//   - 11h neto → aviso temprano (heads-up "te queda 1 hora").
//   - 12h neto → aviso de límite firme.
export const JORNADA_MANEJO_PROXIMA_SEGUNDOS = 11 * 3600;
export const JORNADA_MANEJO_LIMITE_SEGUNDOS = 12 * 3600;

// TTLs para avisos en COLA_WHATSAPP (Fase 2 - 2026-05-18).
// Si el bot esta caido y el aviso se entrega despues del TTL, el
// consumer lo descarta sin enviar (mejor silencio que mensaje
// desactualizado / confuso para el chofer). Ver
// whatsapp-bot/src/index.js linea ~318 (chequeo expira_en).
const TTL_JORNADA_BLOQUE_MIN = 30;       // 3h30, 3h45, cuota cumplida
// Veda nocturna (00:00-08:00 ART dura ~8h). Subido de 60 a 180 min en
// auditoria 24/7 2026-05-18 — es info de seguridad critica que vale la
// pena entregar tarde si el bot estuvo caido en la madrugada.
const TTL_JORNADA_VEDA_MIN = 180;
const TTL_RESUMEN_DIARIO_MIN = 24 * 60;  // resumen diario vale el dia

// _expiraEnMin movido a helpers.ts como `expiraEnMin` (refactor 2026-05-18).
export const DESCANSO_MIN_SEGUNDOS = 8 * 3600;
export const DESCANSO_RADIO_METROS = 1000;
export const VEDA_NOCTURNA_DESDE_HORA = 0; // 00:00 ART
export const VEDA_NOCTURNA_HASTA_HORA = 6; // 06:00 ART (no se usa para alertar,
// el descanso de 8h ya garantiza no arrancar antes)
export const DELTA_MAX_SEGUNDOS = 600;
// Ventana de SITRACK_EVENTOS que el tick analiza por chofer para medir las
// pausas reales (fix bug AB493CP 2026-05-29). 2h cubre cualquier pausa
// intra-bloque que pueda "caer entre ticks"; las detenciones más largas ya
// se detectan en curso (pausa = ahora − paró) tick a tick.
export const VENTANA_EVENTOS_SEGUNDOS = 2 * 3600;
export const COLECCION = "JORNADAS";

// Banner de testing eliminado 2026-05-18 — el bot ya opera 24/7 con
// choferes reales. Si en algun momento se vuelve a necesitar, agregar
// const BANNER_TESTING aca y pre-pendear en los mensajes que se quieran
// marcar como prueba.

// ─── Schema del doc JORNADAS/{dni}_{jornada_inicio_ms} ──────────────────────

export interface JornadaDoc {
  chofer_dni: string;
  jornada_inicio_ts: FsTimestamp;
  jornada_fin_ts: FsTimestamp | null;

  // Estado de bloques
  bloques_completos: number; // 0..3
  bloque_actual_manejo_seg: number;
  bloque_actual_pausa_seg: number;

  // Acumulados
  total_manejo_seg: number;
  ultima_actualizacion_ts: FsTimestamp;
  ultima_patente: string;
  ultima_lat: number | null;
  ultima_lng: number | null;

  // Tracking de descanso entre jornadas (8h misma posición)
  descanso_inicio_ts: FsTimestamp | null;
  descanso_inicio_lat: number | null;
  descanso_inicio_lng: number | null;
  descanso_segundos: number;

  // Estado actual descriptivo
  estado: string; // 'manejando' | 'pausa_intra_bloque' | 'descanso_post_bloque'
  //                | 'cuota_cumplida' | 'veda_nocturna' | 'descanso_jornada'

  // Flags de "alerta enviada" (idempotencia: 1 vez por jornada)
  alerta_3_30_enviada: boolean;
  alerta_3_45_enviada: boolean;
  alerta_cuota_proxima_enviada: boolean; // 10h manejo neto (heads-up)
  alerta_cuota_enviada: boolean;         // 11h manejo neto (límite)
  alerta_veda_enviada: boolean;

  // Flags de infracción (alimentan resumen a Molina)
  bloque_excedido: boolean;
  cuota_excedida: boolean;
  veda_excedida: boolean;

  // Auditoría
  creado_en: FsTimestamp;
}

// ─── Helpers ────────────────────────────────────────────────────────────────

/**
 * Distancia Haversine entre 2 puntos GPS en metros.
 */
export function distanciaMetros(
  lat1: number, lng1: number,
  lat2: number, lng2: number
): number {
  const R = 6371000; // radio Tierra en metros
  const toRad = (g: number) => (g * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
      Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * Hora ART (0..23) de un timestamp en ms. ART es UTC-3 fijo.
 *
 * Bug fix 2026-05-18 (descubierto por test): Node `Intl.DateTimeFormat`
 * con `en-CA` + `hour: "2-digit"` + `hour12: false` devuelve **"24"**
 * para medianoche, no "00". Sin la normalización abajo, durante la hora
 * 00:00-00:59 ART el vigilador devolvía 24, y la condición de veda
 * nocturna `horaActual >= 0 && horaActual < 6` daba false → el chofer
 * que arrancaba 00:30 ART NO recibía aviso de veda. Normalizamos 24→0.
 */
export function horaArt(tsMs: number): number {
  const partes = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    hour: "2-digit",
    hour12: false,
  }).format(new Date(tsMs));
  const h = parseInt(partes, 10);
  return h === 24 ? 0 : h;
}

// ─── Decisión de movimiento (PURA, fix #36) ─────────────────────────────────

/** Lo que necesita `decidirManejando` de cada fuente (sin I/O). */
export interface FuenteMovimiento {
  /** VOLVO_ESTADO[patente] — primario. null si la unidad no es Volvo. */
  volvoSpeedKmh: number | null;
  /** ISO string del reporte GNSS real (ej. "2026-05-21T14:25:56Z"). */
  volvoPosicionTs: string | null;
  volvoLat: number | null;
  volvoLng: number | null;
  /** SITRACK_POSICIONES — fallback (y fuente del driver_dni aguas arriba). */
  sitrackSpeed: number;
  sitrackIgnition: boolean;
  sitrackLat: number | null;
  sitrackLng: number | null;
  /** epoch ms del `report_date` REAL de SITRACK (NO `consultado_en`). */
  sitrackReportMs: number | null;
}

export interface DecisionMovimiento {
  manejando: boolean;
  lat: number | null;
  lng: number | null;
  fuente: "volvo" | "sitrack" | "ninguna";
}

/**
 * Decide si un camión está MANEJANDO, con qué posición, y de qué fuente —
 * PURA, testeable sin Firestore. Corazón del fix #36.
 *
 * Gana la fuente MÁS FRESCA (no Volvo a ciegas). Clave: VOLVO_ESTADO guarda
 * el último `posicion_ts` conocido (merge-preserve) → SIEMPRE hay un valor,
 * pero puede estar viejo (un camión parado deja de reportar). Si priorizáramos
 * Volvo apenas exista el campo, un Volvo viejo (camión moviéndose pero equipo
 * lageado) lo marcaría "parado" ignorando un SITRACK fresco. Por eso:
 *   - Volvo fresco (≤ POLL_STALE)            → Volvo (velocidad más precisa).
 *   - Volvo viejo pero SITRACK fresco        → SITRACK (report_date REAL).
 *   - Ninguno fresco                          → PARADO (fail-safe), posición
 *                                               = la fuente menos vieja.
 * El gate de frescura corta el bug original (SITRACK con `consultado_en`
 * siempre fresco enmascaraba paradas: camión mudo hace 30 min "a 74 km/h").
 */
export function decidirManejando(
  f: FuenteMovimiento,
  nowMs: number
): DecisionMovimiento {
  const volvoMs = f.volvoPosicionTs != null ? Date.parse(f.volvoPosicionTs) : NaN;
  const volvoEdadSeg = Number.isFinite(volvoMs)
    ? (nowMs - volvoMs) / 1000
    : Infinity;
  const sitEdadSeg =
    f.sitrackReportMs != null && f.sitrackReportMs > 0
      ? (nowMs - f.sitrackReportMs) / 1000
      : Infinity;
  const volvoFresco = volvoEdadSeg <= POLL_STALE_SEGUNDOS;
  const sitFresco = sitEdadSeg <= POLL_STALE_SEGUNDOS;

  if (volvoFresco) {
    const manejando =
      f.volvoSpeedKmh != null && f.volvoSpeedKmh > UMBRAL_MOVIMIENTO_KMH;
    return {
      manejando,
      lat: f.volvoLat ?? f.sitrackLat,
      lng: f.volvoLng ?? f.sitrackLng,
      fuente: "volvo",
    };
  }
  if (sitFresco) {
    const manejando =
      f.sitrackIgnition && f.sitrackSpeed > UMBRAL_MOVIMIENTO_KMH;
    return {
      manejando,
      lat: f.sitrackLat ?? f.volvoLat,
      lng: f.sitrackLng ?? f.volvoLng,
      fuente: "sitrack",
    };
  }
  // Ninguna fuente fresca → parado. Damos la posición MENOS vieja para que el
  // tracking de descanso (8h misma posición) no se corte.
  const usarVolvoPos = volvoEdadSeg <= sitEdadSeg;
  return {
    manejando: false,
    lat: usarVolvoPos
      ? f.volvoLat ?? f.sitrackLat
      : f.sitrackLat ?? f.volvoLat,
    lng: usarVolvoPos
      ? f.volvoLng ?? f.sitrackLng
      : f.sitrackLng ?? f.volvoLng,
    fuente: "ninguna",
  };
}

// ─── Detección de pausas por EVENTOS Sitrack (fix bug AB493CP 2026-05-29) ────
//
// PROBLEMA que resuelve: el vigilador infería "maneja/para" del speed
// INSTANTÁNEO de un snapshot (VOLVO_ESTADO / SITRACK_POSICIONES). Eso falla:
//   1. Motor apagado: Volvo deja de transmitir y su último speed>0 queda
//      "fresco" ~10 min -> el tick ve "manejando" y resetea la pausa
//      (`bloque_actual_pausa_seg = 0`). Caso real: AB493CP paró 17 min, el
//      sistema contó ~7 y le mandó "descansá 20 min" indebidamente.
//   2. Gaps de reporte: la pausa se acumulaba `+= deltaSeg` tick a tick; si
//      no hay reportes en el medio, se perdía tiempo.
//   3. Pausas que empiezan y terminan ENTRE dos ticks de 5 min.
//
// SOLUCIÓN: mirar la SECUENCIA de eventos del chofer (últimas 2h) y deducir
// el estado real de detención por VELOCIDAD (no por contacto — el 95% de las
// pausas pasan en ralentí con motor encendido, validado con datos 2026-05-29):
//   - parado + `paroEnMs`: cuándo empezó la detención actual (primer evento
//     sin movimiento tras el último con movimiento) -> pausa = ahora − paró.
//   - manejando + `pausaPreviaSeg`/`arrancoMs`: si acaba de arrancar, la
//     duración REAL de la pausa que terminó (arranque − paró), aunque haya
//     caído entre ticks -> cierra el bloque retroactivo si fue ≥ 15 min.
// Robusto ante Volvo congelado, gaps y ralentí. Idempotente vía el gate
// `arrancoMs > ultima_actualizacion` (no recuenta la misma pausa).

/** Evento Sitrack mínimo para reconstruir detención (speed + arranque). */
export interface EventoDetencionLite {
  ms: number;
  speed: number | null;
  gpsSpeed: number | null;
  eventId: number | null;
  /** Patente (asset_id del evento, normalizada trim+upper). null si el doc no
   * la trae (dato viejo). Se usa para no mezclar eventos de 2 unidades cuando
   * un DNI sufre drift CHOFER_DISTINTO. */
  patente: string | null;
}

export interface DeteccionDetencion {
  /** true = el chofer está detenido ahora (último evento sin movimiento). */
  parado: boolean;
  /** si parado: epoch ms en que empezó la detención actual. */
  paroEnMs: number | null;
  /** si manejando tras una pausa: epoch ms del arranque (1er movimiento). */
  arrancoMs: number | null;
  /** si manejando tras una pausa: duración de la pausa terminada (seg). */
  pausaPreviaSeg: number | null;
  /** "eventos" si hubo datos; "sin_eventos" => el caller usa el fallback. */
  fuente: "eventos" | "sin_eventos";
}

/** Un evento es MOVIMIENTO si supera el umbral o es "Fin de detenido". */
function esEventoMovimiento(ev: EventoDetencionLite): boolean {
  return (
    (ev.speed != null && ev.speed > UMBRAL_MOVIMIENTO_KMH) ||
    (ev.gpsSpeed != null && ev.gpsSpeed > UMBRAL_MOVIMIENTO_KMH) ||
    ev.eventId === 7 // "Fin de detenido" siempre marca arranque
  );
}

/**
 * PURA — reconstruye el estado de detención de un chofer a partir de sus
 * eventos Sitrack recientes. Ver bloque de comentario de arriba. Sin I/O.
 */
export function analizarEventosDetencion(
  eventos: EventoDetencionLite[],
  ahoraMs: number,
  patenteEsperada?: string
): DeteccionDetencion {
  // Drift CHOFER_DISTINTO: un mismo DNI puede tener eventos de DOS patentes (su
  // iButton en una unidad + otra reportando su nombre legacy). Si se pasa la
  // patente que se está evaluando, descartamos los eventos de OTRA patente —
  // sin esto el estado parado/manejando podía salir de la unidad equivocada
  // (auditoría 2026-06). Los eventos sin patente (dato viejo) se conservan para
  // no perder señal en el caso normal (y no mandar a todos al fallback).
  const enPatente = (patenteEsperada != null && patenteEsperada !== "")
    ? eventos.filter((e) => e.patente == null || e.patente === patenteEsperada)
    : eventos;
  const evs = enPatente
    .filter((e) => e.ms <= ahoraMs)
    .sort((a, b) => a.ms - b.ms);
  if (evs.length === 0) {
    return {
      parado: false, paroEnMs: null, arrancoMs: null,
      pausaPreviaSeg: null, fuente: "sin_eventos",
    };
  }
  const ult = evs[evs.length - 1];
  if (esEventoMovimiento(ult)) {
    // Manejando ahora. Inicio de la racha de movimiento final = arranque.
    let i = evs.length - 1;
    while (i > 0 && esEventoMovimiento(evs[i - 1])) i--;
    const arrancoMs = evs[i].ms;
    // Detención inmediatamente anterior al arranque (si la hubo en la ventana).
    let pausaPreviaSeg: number | null = null;
    if (i > 0) {
      let j = i - 1;
      while (j > 0 && !esEventoMovimiento(evs[j - 1])) j--;
      pausaPreviaSeg = (arrancoMs - evs[j].ms) / 1000;
    }
    return {
      parado: false, paroEnMs: null, arrancoMs, pausaPreviaSeg,
      fuente: "eventos",
    };
  }
  // Parado ahora. Inicio de la racha de detención final = cuándo paró.
  let i = evs.length - 1;
  while (i > 0 && !esEventoMovimiento(evs[i - 1])) i--;
  return {
    parado: true, paroEnMs: evs[i].ms, arrancoMs: null,
    pausaPreviaSeg: null, fuente: "eventos",
  };
}

// `primerNombre` y `rrPick` movidos a helpers.ts (refactor 2026-05-18).
//
// NOTA: las versiones nuevas tienen MEJOR comportamiento que las que
// vivian aca:
//   - primerNombre ahora CAPITALIZA ("Juan" en vez de "JUAN") — mensajes
//     al chofer mas naturales: "Hola Juan" en vez de "Hola JUAN".
//   - rrPick ahora es round-robin con counter (en vez de Math.random()
//     puro) — garantiza diversidad consecutiva en variantes anti-baneo
//     de WhatsApp (importante porque mensajes repetidos a corto plazo
//     son signal de bot).

/**
 * Chequea si el chofer cumplio descanso minimo (>= 8h misma posicion)
 * en su jornada anterior. Usado para evitar avisar veda nocturna a
 * choferes que arrancan legitimamente entre 00:00 y 06:00 ART despues
 * de un descanso completo.
 *
 * Decision Vecchi 2026-05-18: la veda 00:00-06:00 se LEVANTA si el
 * chofer cumplio 8h descanso en el mismo lugar antes de arrancar. Asi
 * el chofer que sale legitimamente a las 5:30 AM no recibe falso aviso
 * de "veda activa".
 *
 * Returns true si la JORNADA PREVIA cerro con descanso completo.
 * Returns false en cualquier otro caso (fail-safe: ante duda, avisar).
 */
async function descansoPrevioCumplido(dni: string): Promise<boolean> {
  try {
    const snap = await db()
      .collection(COLECCION)
      .where("chofer_dni", "==", dni)
      // jornada_fin_ts != null se expresa como > 0 (Timestamp epoch).
      // Firestore no permite where != null directamente.
      .where("jornada_fin_ts", ">", Timestamp.fromMillis(0))
      .orderBy("jornada_fin_ts", "desc")
      .limit(1)
      .get();
    if (snap.empty) return false;
    const j = snap.docs[0].data() as JornadaDoc;
    return (j.descanso_segundos || 0) >= DESCANSO_MIN_SEGUNDOS;
  } catch (e) {
    logger.warn("[descansoPrevioCumplido] query fallo", {
      dni, error: (e as Error).message,
    });
    return false; // fail-safe: avisar si dudamos
  }
}

/**
 * Cargar set de DNIs de choferes dados de baja (soft-delete con
 * `ACTIVO=false`). El tick del vigilador skipea estos DNIs antes de
 * crear/actualizar jornada → no se generan jornadas falsas ni avisos
 * para ex-empleados. Santiago 2026-05-19 (bug Erasmo).
 *
 * No usa cache compartido a propósito: el tick corre cada 1 min y un
 * empleado puede darse de baja en cualquier momento — queremos que
 * el efecto sea inmediato (max 1 ciclo de delay).
 */
async function cargarChoferesInactivos(): Promise<Set<string>> {
  try {
    const snap = await db()
      .collection("EMPLEADOS")
      .where("ACTIVO", "==", false)
      .limit(1000)
      .get();
    const set = new Set<string>();
    for (const d of snap.docs) set.add(d.id);
    return set;
  } catch (e) {
    logger.warn("[jornadas_v2.cargarChoferesInactivos] falló", {
      error: (e as Error).message,
    });
    // Fail-safe: devolvemos set vacío → no se filtra nadie por inactivo
    // (el check downstream en obtenerEmpleadoLite sigue siendo red de
    // seguridad). Mejor avisar a 1 ex-empleado por 1 ciclo que romper
    // el vigilador entero por una query caída.
    return new Set();
  }
}

/**
 * Cargar set de choferes silenciados (comando /silenciar).
 */
async function cargarSilenciados(): Promise<Set<string>> {
  try {
    const snap = await db()
      .collection("BOT_SILENCIADOS_CHOFER")
      .where("silenciado_hasta", ">", Timestamp.now())
      .limit(500)
      .get();
    const set = new Set<string>();
    for (const d of snap.docs) set.add(d.id);
    return set;
  } catch (e) {
    logger.warn("[jornadas_v2.cargarSilenciados] falló", {
      error: (e as Error).message,
    });
    return new Set();
  }
}

// ─── Avisos al chofer ───────────────────────────────────────────────────────

interface EmpleadoLite {
  tel: string;
  saludo: string;
}

/**
 * Decide si un empleado está dado de baja. Defensivo contra valores
 * raros en `ACTIVO` (Santiago 2026-05-19 reportó que el bot mandó
 * mensaje a un chofer dado de baja — Erasmo). El check anterior era
 * solo `=== false`, dejaba pasar:
 *   - "false" / "FALSE" (string en lugar de bool)
 *   - 0 (número)
 *   - Por contraste, considera ACTIVO ausente / null / undefined como
 *     ACTIVO (compat retro: empleados pre-soft-delete no tenían el
 *     campo y debían operar normal).
 */
function empleadoEstaInactivo(empData: Record<string, unknown>): boolean {
  const v = empData.ACTIVO;
  if (v === false) return true;
  if (typeof v === "string" && v.toLowerCase() === "false") return true;
  if (v === 0) return true;
  return false;
}

async function obtenerEmpleadoLite(dni: string): Promise<EmpleadoLite | null> {
  const empSnap = await db().collection("EMPLEADOS").doc(dni).get();
  if (!empSnap.exists) return null;
  const empData = empSnap.data() ?? {};
  if (empleadoEstaInactivo(empData)) {
    logger.warn("[jornadas_v2] skip aviso a empleado inactivo", {
      dni,
      activo_raw: empData.ACTIVO,
      activo_tipo: typeof empData.ACTIVO,
    });
    return null;
  }
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") return null;
  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";
  return { tel, saludo };
}

async function encolarAviso3h30(
  dni: string, patente: string
): Promise<void> {
  const emp = await obtenerEmpleadoLite(dni);
  if (!emp) return;
  const variantes = [
    `${emp.saludo},\n\n` +
      "Llevás 3 h 30 min de manejo en este bloque. Buscá un lugar seguro " +
      `para detener el ${patente} a *descansar un mínimo de 20 minutos* ` +
      "antes de continuar.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
    `${emp.saludo}.\n\n` +
      "Aviso: llevás 3 h 30 manejando seguido. Frená el " +
      `${patente} en un lugar seguro y *descansá un mínimo de 20 minutos* ` +
      "antes de retomar.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
    `${emp.saludo}, atención.\n\n` +
      "Tu bloque actual llegó a 3 h 30 min. Buscá dónde parar y " +
      `*descansá un mínimo de 20 minutos* antes de continuar con el ${patente}.\n\n` +
      "_Bot-On — Coopertrans Móvil_",
  ];
  await db().collection("COLA_WHATSAPP").add({
    telefono: emp.tel,
    mensaje: variantes[rrPick(variantes.length)],
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_v2_bloque_3h30",
    expira_en: expiraEnMin(TTL_JORNADA_BLOQUE_MIN),
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: dni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada v2",
    alert_patente: patente,
  });
}

// NOTA 2026-05-18 (decision Santiago): el aviso 3h45 ("PARÁ AHORA")
// fue ELIMINADO porque era spam — ya avisamos a las 3h30 con "buscá
// lugar seguro a descansar 20 min". Mandar otro 15 min despues
// repite la misma info. La logica de medicion (BLOQUE_LIMITE_SEGUNDOS,
// alerta_3_45_enviada) se MANTIENE intacta por backward-compat con
// docs JORNADAS existentes y para que el cliente / commands.js pueda
// seguir mostrando "🔴 alcanzaste el limite del bloque" si quiere.
// Si en el futuro se quiere reactivar, ver git log de este archivo.

/**
 * Aviso al chofer cuando CRUZA las 4 horas de manejo continuo sin
 * pausar. Es una infraccion real (queda registrada en el flag
 * `bloque_excedido` que alimenta el resumen a Molina). Al chofer le
 * mandamos un mensaje firme para que sepa que esta en infraccion en
 * tiempo real y pare cuanto antes.
 *
 * Decision Santiago 2026-05-18 (auditoria vigilador): aunque ya le
 * avisamos a 3h30, si llego a 4h es porque ignoro. Mandar un aviso
 * firme refuerza el mensaje "esto es serio, queda anotado". 1 vez por
 * bloque (idempotencia via flag `bloque_excedido` que ya se usa).
 */
async function encolarAvisoBloqueExcedido(
  dni: string, patente: string
): Promise<void> {
  const emp = await obtenerEmpleadoLite(dni);
  if (!emp) return;
  const variantes = [
    `${emp.saludo}.\n\n` +
      "*Pasaste las 4 horas de manejo continuo sin pausar.* Esto " +
      "*queda registrado como infracción.*\n\n" +
      `Frená el ${patente} en un lugar seguro AHORA y descansá los ` +
      "20 minutos reglamentarios antes de seguir.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
    `${emp.saludo}, atención.\n\n` +
      "*Cumpliste 4 horas sin tomar pausa.* Esto es *infracción " +
      "registrada* — el supervisor lo va a ver mañana.\n\n" +
      `Detené el ${patente} ya y descansá 20 min antes de continuar.\n\n` +
      "_Bot-On — Coopertrans Móvil_",
    `${emp.saludo}, urgente.\n\n` +
      "*Manejo continuo > 4 horas detectado.* Esto figura como " +
      "*falta* en el reporte diario al supervisor.\n\n" +
      `Frená el ${patente} ahora mismo y descansá los 20 minutos ` +
      "reglamentarios.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
  ];
  await db().collection("COLA_WHATSAPP").add({
    telefono: emp.tel,
    mensaje: variantes[rrPick(variantes.length)],
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_v2_bloque_excedido",
    expira_en: expiraEnMin(TTL_JORNADA_BLOQUE_MIN),
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: dni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada v2",
    alert_patente: patente,
  });
}

async function encolarAvisoCuotaProxima(
  dni: string, patente: string
): Promise<void> {
  const emp = await obtenerEmpleadoLite(dni);
  if (!emp) return;
  // Heads-up cuando lleva 11h manejo neto. Diferente del aviso 3h30
  // (que es POR BLOQUE actual) — este mira el TOTAL acumulado en la
  // jornada. Sirve para el caso del chofer que hace pausas frecuentes
  // y cortas y nunca cruza 3h30 dentro de un bloque pero sí acumula
  // jornada larga.
  const variantes = [
    `${emp.saludo},\n\n` +
      "*Ya llevás 11 horas de manejo en esta jornada.* Te queda 1 hora " +
      "para el límite de 12 horas.\n\n" +
      `Buscá dónde estacionar el ${patente} y planificá el descanso ` +
      "(mínimo 8 horas de corrido).\n\n" +
      "_Bot-On — Coopertrans Móvil_",
    `${emp.saludo}.\n\n` +
      "*Cumpliste 11 horas de conducción acumulada.* Te queda 1 hora " +
      "antes del límite de 12 horas.\n\n" +
      `Ubicá un lugar seguro para frenar el ${patente} y descansar ` +
      "8 horas mínimo de corrido.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
    `${emp.saludo}, atención.\n\n` +
      "*Llevás 11 horas de jornada de manejo.* Empezá a buscar dónde " +
      `estacionar el ${patente} — al llegar a 12 horas debés frenar ` +
      "sí o sí.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
  ];
  await db().collection("COLA_WHATSAPP").add({
    telefono: emp.tel,
    mensaje: variantes[rrPick(variantes.length)],
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_v2_cuota_proxima",
    expira_en: expiraEnMin(TTL_JORNADA_BLOQUE_MIN),
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: dni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada v2",
    alert_patente: patente,
  });
}

async function encolarAvisoCuotaCumplida(
  dni: string, patente: string
): Promise<void> {
  const emp = await obtenerEmpleadoLite(dni);
  if (!emp) return;
  // 3 variantes anti-baneo. Decision Santiago 2026-05-18:
  // NO mencionar "bloques" (jerga interna) — al chofer le hablamos
  // de "12 horas de jornada diaria" y "8 horas de descanso".
  const variantes = [
    `${emp.saludo},\n\n` +
      "*Estás cerca de las 12 horas de jornada diaria.* Frená el " +
      `${patente} en un lugar seguro y descansá *mínimo 8 horas de ` +
      "corrido* antes de seguir.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
    `${emp.saludo}.\n\n` +
      "*Llegás al límite de 12 horas de jornada.* Buscá dónde " +
      `estacionar el ${patente} — necesitás *mínimo 8 horas de descanso ` +
      "de corrido* antes de retomar.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
    `${emp.saludo}, atención.\n\n` +
      "*Tu jornada diaria está cerca de las 12 horas.* Detené el " +
      `${patente} en un lugar seguro y descansá *al menos 8 horas ` +
      "seguidas* antes de continuar.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
  ];
  await db().collection("COLA_WHATSAPP").add({
    telefono: emp.tel,
    mensaje: variantes[rrPick(variantes.length)],
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_v2_cuota_cumplida",
    expira_en: expiraEnMin(TTL_JORNADA_BLOQUE_MIN),
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: dni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada v2",
    alert_patente: patente,
  });
}

async function encolarAvisoVedaNocturna(
  dni: string, patente: string
): Promise<void> {
  const emp = await obtenerEmpleadoLite(dni);
  if (!emp) return;
  const variantes = [
    `${emp.saludo},\n\n` +
      "*Entraste en veda nocturna (00:00 ART).* Por política, no se " +
      "maneja después de las 00:00.\n\n" +
      `Detené el ${patente} en un lugar seguro y descansá. El ` +
      "incumplimiento queda registrado.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
    `${emp.saludo}.\n\n` +
      "*00:00 ART — veda nocturna activa.* Por norma de Vecchi no " +
      "podés seguir manejando.\n\n" +
      `Frená el ${patente} ahora en un lugar seguro y descansá hasta ` +
      "completar 8 h sin moverte.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
    `${emp.saludo}, urgente.\n\n` +
      "*Veda nocturna iniciada (00:00 ART).* No podés conducir hasta " +
      "que tengas 8 h de descanso completo.\n\n" +
      `Estacioná el ${patente} ahora — el incumplimiento se registra ` +
      "para Seg e Higiene.\n\n" +
      "_Bot-On — Coopertrans Móvil_",
  ];
  await db().collection("COLA_WHATSAPP").add({
    telefono: emp.tel,
    mensaje: variantes[rrPick(variantes.length)],
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_v2_veda_nocturna",
    expira_en: expiraEnMin(TTL_JORNADA_VEDA_MIN),
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: dni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada v2",
    alert_patente: patente,
  });
}

// ─── Helpers de jornada (load + create) ─────────────────────────────────────

/**
 * Carga la jornada abierta (jornada_fin_ts == null) de un chofer.
 * Devuelve null si no tiene jornada abierta.
 */
async function cargarJornadaAbierta(
  dni: string
): Promise<{ ref: FirebaseFirestore.DocumentReference;
            data: JornadaDoc } | null> {
  const snap = await db()
    .collection(COLECCION)
    .where("chofer_dni", "==", dni)
    .where("jornada_fin_ts", "==", null)
    .limit(1)
    .get();
  if (snap.empty) return null;
  const d = snap.docs[0];
  return { ref: d.ref, data: d.data() as JornadaDoc };
}

/**
 * Crea una jornada nueva para un chofer.
 */
function nuevaJornada(
  dni: string, patente: string, lat: number | null, lng: number | null
): { ref: FirebaseFirestore.DocumentReference; data: JornadaDoc } {
  const ahora = Timestamp.now();
  const ts = ahora.toMillis();
  const ref = db().collection(COLECCION).doc(`${dni}_${ts}`);
  const data: JornadaDoc = {
    chofer_dni: dni,
    jornada_inicio_ts: ahora,
    jornada_fin_ts: null,
    bloques_completos: 0,
    bloque_actual_manejo_seg: 0,
    bloque_actual_pausa_seg: 0,
    total_manejo_seg: 0,
    ultima_actualizacion_ts: ahora,
    ultima_patente: patente,
    ultima_lat: lat,
    ultima_lng: lng,
    descanso_inicio_ts: null,
    descanso_inicio_lat: null,
    descanso_inicio_lng: null,
    descanso_segundos: 0,
    estado: "manejando",
    alerta_3_30_enviada: false,
    alerta_3_45_enviada: false,
    alerta_cuota_proxima_enviada: false,
    alerta_cuota_enviada: false,
    alerta_veda_enviada: false,
    bloque_excedido: false,
    cuota_excedida: false,
    veda_excedida: false,
    creado_en: ahora,
  };
  return { ref, data };
}

// ─── Máquina de estados (PURA) ───────────────────────────────────────────────

export type AvisoJornada =
  | "3h30"
  | "bloque_excedido"
  | "cuota_proxima"
  | "cuota"
  | "veda";

export interface EvaluarTickInput {
  /** ignition ON + speed > umbral + poll no stale (lo decide el caller). */
  manejando: boolean;
  /** segundos transcurridos desde el último tick (ya capado a DELTA_MAX). */
  deltaSeg: number;
  /** epoch ms del "ahora" del tick (inyectable para tests). */
  ahoraMs: number;
  lat: number | null;
  lng: number | null;
  /**
   * Para la excepción de veda nocturna: ¿el chofer cumplió 8h de descanso
   * en su jornada anterior? El caller lo precomputa (query a JORNADAS) SOLO
   * cuando hace falta (en veda + manejo < 2h + sin aviso de veda previo).
   * `false` por default = fail-safe (avisar veda ante duda).
   */
  tieneDescansoPrevio: boolean;
  /**
   * Detección de pausa por EVENTOS Sitrack (fix AB493CP 2026-05-29). Cuando
   * el caller pudo analizar eventos, mide la pausa de forma robusta:
   *   - parado: `paroEnMs` = inicio de la detención -> pausa = ahora − paró.
   *   - recién arrancó: `pausaPreviaSeg`/`arrancoMs` -> cierra bloque si ≥15min.
   * `null` (sin eventos del chofer) => fallback a la acumulación por deltaSeg.
   */
  paroEnMs: number | null;
  arrancoMs: number | null;
  pausaPreviaSeg: number | null;
}

export interface EvaluarTickResult {
  /** avisos a encolar este tick (en orden). */
  avisos: AvisoJornada[];
  /** true si la jornada se cerró por descanso de 8h. */
  cerrada: boolean;
}

/**
 * Cierra el bloque de manejo actual por haber completado una pausa ≥15 min.
 * Suma el manejo al acumulado, incrementa el contador y resetea los flags
 * por-bloque (3h30 + infracción de 4h). Idempotente: si no hubo manejo en el
 * bloque (ya cerrado / jornada recién arrancada parada) no hace nada — esto
 * evita recontar bloques mientras el chofer sigue detenido tick tras tick.
 */
function cerrarBloquePorPausa(j: JornadaDoc): void {
  if (j.bloque_actual_manejo_seg <= 0) return;
  j.bloques_completos += 1;
  j.total_manejo_seg += j.bloque_actual_manejo_seg;
  j.bloque_actual_manejo_seg = 0;
  j.alerta_3_30_enviada = false; // reset alerta del bloque
  // Reset de la infracción de 4h POR BLOQUE (auditoría 2026-05-22): sin esto el
  // flag se seteaba 1 vez por JORNADA y un chofer que cruzaba 4h en un 2º
  // bloque de la misma jornada NO recibía el aviso.
  j.bloque_excedido = false;
  j.estado = "descanso_post_bloque";
}

/**
 * Máquina de estados PURA del vigilador de jornada v2. Muta `j` in-place
 * (segundos, flags, estado, timestamps) y devuelve los avisos a encolar
 * + si la jornada se cerró. SIN I/O — testeable sin Firestore.
 *
 * Extraída de `tickVigiladorJornada` (2026-05-19) para lockear con tests
 * la lógica de decisión, especialmente el fix de avisos por MANEJO NETO
 * (cuota_proxima 11h / cuota 12h) en lugar de bloques contados.
 *
 * El único I/O del tick original (el query `descansoPrevioCumplido` para
 * la excepción de veda) se externalizó: el caller lo precomputa y lo pasa
 * en `input.tieneDescansoPrevio`.
 */
export function evaluarTickJornada(
  j: JornadaDoc,
  input: EvaluarTickInput
): EvaluarTickResult {
  const {
    manejando, deltaSeg, ahoraMs, lat, lng, tieneDescansoPrevio,
    paroEnMs, arrancoMs, pausaPreviaSeg,
  } = input;
  const ahora = Timestamp.fromMillis(ahoraMs);
  const avisos: AvisoJornada[] = [];
  let cerrada = false;

  if (manejando) {
    // === Está manejando ===
    // Descanso por GAP DE REPORTES (equipo apagado de noche): si el chofer
    // ARRANCA tras ≥ 8h sin un solo reporte, ese gap fue un descanso de jornada
    // aunque el tracking nunca lo haya "visto" parado (equipo apagado = sin
    // ticks → `descanso_inicio_ts` quedaba null y NINGUNA rama cerraba → la
    // jornada de AYER seguía abierta y arrastraba el manejo). Caso real
    // 2026-06-04: choferes que durmieron con el equipo apagado veían "manejaste
    // 12h". Va DENTRO de `manejando` a propósito: si reaparece PARADO en otra
    // posición es que siguió en ruta (no descansó) y de eso se ocupa la rama
    // "parado" por distancia. Cerramos la jornada vieja en su ÚLTIMO reporte;
    // el próximo tick abre una nueva limpia.
    const gapSinReportesSeg =
      (ahoraMs - j.ultima_actualizacion_ts.toMillis()) / 1000;
    if (gapSinReportesSeg >= DESCANSO_MIN_SEGUNDOS) {
      j.descanso_segundos = gapSinReportesSeg;
      j.estado = "descanso_jornada";
      j.jornada_fin_ts = j.ultima_actualizacion_ts;
      return { avisos, cerrada: true };
    }
    // Robustez ante camión APAGADO de noche (caso Balbiano 2026-06-01): si
    // venía parado en la misma posición desde hace ≥ 8h, el descanso de
    // jornada está CUMPLIDO aunque el tracking incremental no lo haya podido
    // acumular. El equipo apagado deja de transmitir (gap de horas sin
    // reporte) y la ventana de eventos (2h) no llega a ver cuándo paró → el
    // sistema "perdía" el descanso y seguía contando la jornada del día
    // anterior. Acá lo medimos por la DURACIÓN real desde descanso_inicio_ts
    // y cerramos la jornada antes de contar este arranque como manejo viejo
    // (el próximo tick abre la jornada nueva, el chofer ya arrancó).
    if (j.descanso_inicio_ts != null) {
      const descansoRealSeg =
        (ahoraMs - j.descanso_inicio_ts.toMillis()) / 1000;
      if (descansoRealSeg >= DESCANSO_MIN_SEGUNDOS) {
        j.descanso_segundos = descansoRealSeg;
        j.estado = "descanso_jornada";
        j.jornada_fin_ts = ahora;
        j.ultima_actualizacion_ts = ahora;
        return { avisos, cerrada: true };
      }
    }
    // Fix AB493CP: si recién arrancó tras una pausa ≥15 min que terminó
    // DESPUÉS del último tick, cerrar el bloque retroactivamente (la pausa
    // pudo empezar y terminar entre dos ticks de 5 min). El gate
    // `arrancoMs > ultima_actualizacion` impide recontar la misma pausa.
    if (
      pausaPreviaSeg != null &&
      pausaPreviaSeg >= PAUSA_BLOQUE_SEGUNDOS &&
      arrancoMs != null &&
      arrancoMs > j.ultima_actualizacion_ts.toMillis()
    ) {
      cerrarBloquePorPausa(j);
    }
    j.bloque_actual_manejo_seg += deltaSeg;
    j.bloque_actual_pausa_seg = 0;
    j.estado = "manejando";

    // Reset tracking descanso
    j.descanso_inicio_ts = null;
    j.descanso_inicio_lat = null;
    j.descanso_inicio_lng = null;
    j.descanso_segundos = 0;

    // Aviso 3h30 (heads-up del bloque actual de manejo continuo).
    if (
      j.bloque_actual_manejo_seg >= BLOQUE_ALERTA_TEMPRANA_SEGUNDOS &&
      !j.alerta_3_30_enviada
    ) {
      avisos.push("3h30");
      j.alerta_3_30_enviada = true;
    }

    // Aviso 4h (infracción de bloque sin pausar). 1 vez por bloque.
    if (
      j.bloque_actual_manejo_seg >= BLOQUE_EXCEDIDO_SEGUNDOS &&
      !j.bloque_excedido
    ) {
      avisos.push("bloque_excedido");
      j.bloque_excedido = true;
    }

    // Avisos de jornada por MANEJO NETO acumulado (no por bloques contados).
    // Límite = 12h de manejo neto (las paradas de 15 min suceden DENTRO de
    // las 12h). Heads-up a 11h. Jerárquico: si pasamos el límite duro, no
    // mandamos el heads-up (incoherente recibir "11h" después de "12h").
    const totalManejoActual =
      j.total_manejo_seg + j.bloque_actual_manejo_seg;
    if (totalManejoActual >= JORNADA_MANEJO_LIMITE_SEGUNDOS) {
      if (!j.alerta_cuota_enviada) {
        avisos.push("cuota");
        j.alerta_cuota_enviada = true;
        j.cuota_excedida = true;
      }
      j.alerta_cuota_proxima_enviada = true;
    } else if (totalManejoActual >= JORNADA_MANEJO_PROXIMA_SEGUNDOS) {
      if (!j.alerta_cuota_proxima_enviada) {
        avisos.push("cuota_proxima");
        j.alerta_cuota_proxima_enviada = true;
      }
    }

    // Veda nocturna (00:00-06:00 ART). Se levanta si el chofer cumplió 8h
    // descanso previo Y lleva poco manejo en esta jornada (< 2h) — caso del
    // chofer que sale legítimamente 5:30 AM. El query lo hizo el caller.
    const hora = horaArt(ahoraMs);
    const enVeda =
      hora >= VEDA_NOCTURNA_DESDE_HORA && hora < VEDA_NOCTURNA_HASTA_HORA;
    if (enVeda && !j.alerta_veda_enviada) {
      const HORAS2_SEG = 2 * 3600;
      const avisarVeda = !(totalManejoActual < HORAS2_SEG && tieneDescansoPrevio);
      if (avisarVeda) {
        avisos.push("veda");
        j.alerta_veda_enviada = true;
        j.veda_excedida = true;
      }
    }

    if (lat != null) j.ultima_lat = lat;
    if (lng != null) j.ultima_lng = lng;
  } else {
    // === Está parado o speed bajo ===
    // Fix AB493CP: medir la pausa por el INICIO REAL de la detención (de los
    // eventos Sitrack) en vez de acumular `+= deltaSeg` — que se reseteaba a 0
    // con el Volvo congelado y perdía tiempo en los gaps de reporte. Fallback
    // a la acumulación si el caller no tuvo eventos del chofer.
    if (paroEnMs != null) {
      j.bloque_actual_pausa_seg = Math.max(0, (ahoraMs - paroEnMs) / 1000);
    } else {
      j.bloque_actual_pausa_seg += deltaSeg;
    }
    j.estado = "pausa_intra_bloque";

    // Si pausa >= 15 min: cierra el bloque actual (idempotente).
    if (j.bloque_actual_pausa_seg >= PAUSA_BLOQUE_SEGUNDOS) {
      cerrarBloquePorPausa(j);
    }

    // Tracking descanso 8h con misma posición (radio 1000 m).
    if (lat != null && lng != null) {
      if (j.descanso_inicio_ts == null) {
        // Anclaje anti-gap (caso Balbiano 2026-06-01): si el equipo dejó de
        // reportar un buen rato (camión apagado de noche → su doc desaparece
        // de SITRACK_POSICIONES y el tick no lo procesa) y REAPARECE en la
        // misma posición, el descanso NO empezó "ahora": empezó cuando lo
        // vimos por última vez. Anclamos descanso_inicio_ts al pasado y
        // arrancamos descanso_segundos con el gap ya transcurrido, así no se
        // pierde el tiempo de inactividad. La condición de misma posición
        // (vs. la última conocida) evita falsos positivos: un chofer que
        // siguió manejando sin reportar reaparece en OTRO lado → no ancla, y
        // un cron caído no cierra jornadas de quienes estaban en ruta.
        const gapSeg =
          (ahoraMs - j.ultima_actualizacion_ts.toMillis()) / 1000;
        let anclar = false;
        if (
          gapSeg >= DELTA_MAX_SEGUNDOS &&
          j.ultima_lat != null &&
          j.ultima_lng != null
        ) {
          const distGap = distanciaMetros(
            j.ultima_lat, j.ultima_lng, lat, lng
          );
          anclar = distGap <= DESCANSO_RADIO_METROS;
        }
        if (anclar) {
          j.descanso_inicio_ts = j.ultima_actualizacion_ts;
          j.descanso_inicio_lat = j.ultima_lat;
          j.descanso_inicio_lng = j.ultima_lng;
          j.descanso_segundos = gapSeg;
        } else {
          j.descanso_inicio_ts = ahora;
          j.descanso_inicio_lat = lat;
          j.descanso_inicio_lng = lng;
          j.descanso_segundos = 0;
        }
      } else if (
        j.descanso_inicio_lat != null &&
        j.descanso_inicio_lng != null
      ) {
        const dist = distanciaMetros(
          j.descanso_inicio_lat, j.descanso_inicio_lng, lat, lng
        );
        if (dist > DESCANSO_RADIO_METROS) {
          j.descanso_inicio_ts = ahora;
          j.descanso_inicio_lat = lat;
          j.descanso_inicio_lng = lng;
          j.descanso_segundos = 0;
        } else {
          // Duración REAL del descanso (no acumulación tick a tick): robusto
          // ante gaps de reporte. Si el equipo dejó de transmitir un rato y
          // vuelve en la misma posición, el descanso refleja el tiempo real
          // transcurrido desde que paró, no solo los ticks que vimos.
          j.descanso_segundos =
            (ahoraMs - j.descanso_inicio_ts!.toMillis()) / 1000;
        }
      }
    }

    // Si descanso acumulado >= 8h → cierra jornada.
    if (j.descanso_segundos >= DESCANSO_MIN_SEGUNDOS) {
      j.estado = "descanso_jornada";
      j.jornada_fin_ts = ahora;
      cerrada = true;
    }
  }

  j.ultima_actualizacion_ts = ahora;
  return { avisos, cerrada };
}

// ─── Tick principal del vigilador ───────────────────────────────────────────

/**
 * Una corrida del cron — itera todos los SITRACK_POSICIONES y aplica
 * la lógica de bloques a cada chofer con jornada abierta o que arranca
 * una nueva.
 */
export async function tickVigiladorJornada(): Promise<void> {
  logger.info("[jornadas_v2.tick] iniciando");

  const snap = await db().collection("SITRACK_POSICIONES").limit(5000).get();
  const silenciados = await cargarSilenciados();
  // Choferes/patentes de combustibles líquidos NO controlados por
  // Coopertrans Móvil — skipear sus jornadas (ver excluidos.ts).
  const excluidos = await cargarExcluidos(db());
  // Choferes dados de baja — el vigilador NO debe crear jornada ni
  // mandar avisos a sus DNIs. Bug Santiago 2026-05-19: el bot le
  // mandó "Estás cerca de las 12 horas" a Erasmo que estaba dado
  // de baja. El check en `obtenerEmpleadoLite` debería haber
  // filtrado el mensaje, pero arreglamos UPSTREAM también para no
  // depender de un único punto + ahorrar I/O en JORNADAS.
  const inactivos = await cargarChoferesInactivos();

  // VOLVO_ESTADO: fuente PRIMARIA de movimiento (fix #36). Una query (~53
  // docs). Si falla, el Map queda vacío y `decidirManejando` cae a SITRACK
  // — el vigilador sigue operativo aunque Volvo esté caído.
  const volvoPorPatente = new Map<string, {
    speed_kmh: number | null; posicion_ts: string | null;
    lat: number | null; lng: number | null;
  }>();
  try {
    const volSnap = await db().collection("VOLVO_ESTADO").limit(5000).get();
    for (const d of volSnap.docs) {
      const x = d.data();
      volvoPorPatente.set(d.id.toUpperCase(), {
        speed_kmh: typeof x.speed_kmh === "number" ? x.speed_kmh : null,
        posicion_ts: typeof x.posicion_ts === "string" ? x.posicion_ts : null,
        lat: typeof x.lat === "number" ? x.lat : null,
        lng: typeof x.lng === "number" ? x.lng : null,
      });
    }
  } catch (e) {
    logger.warn(
      "[jornadas_v2.tick] no se pudo cargar VOLVO_ESTADO, usando solo SITRACK",
      { error: (e as Error).message }
    );
  }

  // SITRACK_EVENTOS de las últimas 2h, agrupados por DNI (fix AB493CP
  // 2026-05-29). Una query (~800 docs). El tick mide las pausas reales por
  // esta secuencia de eventos — no por el speed del snapshot, que el Volvo
  // congelado (motor apagado) falsea con un último speed>0 "fresco". Si la
  // query falla, el Map queda vacío y `evaluarTickJornada` cae al fallback
  // por deltaSeg (comportamiento previo).
  const eventosPorDni = new Map<string, EventoDetencionLite[]>();
  try {
    const desdeEv = Timestamp.fromMillis(
      Date.now() - VENTANA_EVENTOS_SEGUNDOS * 1000
    );
    const evSnap = await db().collection("SITRACK_EVENTOS")
      .where("report_date", ">=", desdeEv)
      .orderBy("report_date", "desc")
      .limit(20000) // backstop anti-runaway; el pico real en 2h es ~2k docs
      .get();
    for (const d of evSnap.docs) {
      const x = d.data();
      const evDni = (x.driver_dni ?? "").toString().trim();
      if (!evDni) continue;
      const ms = (x.report_date as FsTimestamp | undefined)?.toMillis();
      if (ms == null) continue;
      let arr = eventosPorDni.get(evDni);
      if (!arr) {
        arr = [];
        eventosPorDni.set(evDni, arr);
      }
      arr.push({
        ms,
        speed: typeof x.speed === "number" ? x.speed : null,
        gpsSpeed: typeof x.gps_speed === "number" ? x.gps_speed : null,
        eventId: typeof x.event_id === "number" ? x.event_id : null,
        // asset_id viene CRUDO en SITRACK_EVENTOS (a diferencia del doc id de
        // SITRACK_POSICIONES, ya trim+upper) → normalizamos para poder
        // compararlo con la patente del chofer y no cruzar unidades.
        patente: ((x.asset_id ?? "").toString().trim().toUpperCase()) || null,
      });
    }
  } catch (e) {
    logger.warn(
      "[jornadas_v2.tick] no se pudo cargar SITRACK_EVENTOS, " +
        "pausas por fallback deltaSeg",
      { error: (e as Error).message }
    );
  }

  // Race condition fix (auditoria 2026-05-16): si por drift de
  // CHOFER_DISTINTO un mismo DNI aparece en 2 patentes (chofer logueado
  // con su iButton + otro tractor reportando su nombre legacy), antes
  // procesabamos las 2 iteraciones y el segundo update PISABA el
  // primero. Ahora deduplicamos por DNI antes del loop — nos quedamos
  // con la patente que tiene reporte mas reciente (mejor proxy de
  // "donde realmente esta el chofer ahora").
  const choferesProcesados = new Map<string, {
    docPos: typeof snap.docs[number];
    polledMs: number;
  }>();
  for (const docPos of snap.docs) {
    const data = docPos.data();
    const dni = (data.driver_dni ?? "").toString().trim();
    if (!dni) continue;
    // Skip choferes excluidos (combustibles líquidos).
    if (excluidos.dnis.has(dni)) continue;
    // Skip choferes dados de baja (Santiago 2026-05-19).
    if (inactivos.has(dni)) continue;
    // Skip patentes excluidas (defensivo: chofer Vecchi manejando un
    // tanque por algún motivo — sigue siendo operativa que no controlamos).
    if (excluidos.patentes.has(docPos.id.toUpperCase())) continue;
    const polledMs =
      (data.consultado_en as FsTimestamp | undefined)?.toMillis() ?? 0;
    const previo = choferesProcesados.get(dni);
    if (!previo || polledMs > previo.polledMs) {
      choferesProcesados.set(dni, { docPos, polledMs });
    }
  }

  let evaluados = 0;
  let avisosEnviados = 0;
  let silenciadosCount = 0;
  let nuevasJornadas = 0;
  let cerradas = 0;
  // Observabilidad fix #36: cuántas decisiones de POSICIÓN salieron de cada
  // fuente. `fuenteEventos` = cuántos choferes evaluaron el ESTADO de pausa
  // por eventos Sitrack (fix AB493CP) vs el fallback por snapshot.
  let fuenteVolvo = 0;
  let fuenteSitrack = 0;
  let fuenteEventos = 0;

  for (const [dni, entry] of choferesProcesados.entries()) {
    const docPos = entry.docPos;
    const data = docPos.data();

    const patente = docPos.id;
    // Default ignition=FALSE (fail-closed). Para el fallback SITRACK.
    const sitIgnition =
      typeof data.ignition === "boolean" ? data.ignition : false;
    // report_date = timestamp REAL del último reporte SITRACK. Usamos ESTE
    // (no `consultado_en`, que es cuándo NOSOTROS consultamos y siempre está
    // fresco → enmascaraba el stale = bug #36).
    const sitReportMs =
      (data.report_date as FsTimestamp | undefined)?.toMillis() ?? null;

    // Fix #36: movimiento desde Volvo (primario) con fallback a SITRACK.
    const vol = volvoPorPatente.get(patente.toUpperCase());
    const decision = decidirManejando(
      {
        volvoSpeedKmh: vol?.speed_kmh ?? null,
        volvoPosicionTs: vol?.posicion_ts ?? null,
        volvoLat: vol?.lat ?? null,
        volvoLng: vol?.lng ?? null,
        sitrackSpeed: typeof data.speed === "number" ? data.speed : 0,
        sitrackIgnition: sitIgnition,
        sitrackLat: typeof data.lat === "number" ? data.lat : null,
        sitrackLng: typeof data.lng === "number" ? data.lng : null,
        sitrackReportMs: sitReportMs,
      },
      Date.now()
    );
    // Estado de detención por EVENTOS Sitrack (fix AB493CP): fuente de verdad
    // de las pausas. Si hay eventos del chofer, `manejando` se deriva de ahí
    // (no del snapshot, que el Volvo congelado falsea). Si no hay eventos,
    // fallback a la decisión por speed del snapshot.
    const det = analizarEventosDetencion(
      eventosPorDni.get(dni) ?? [],
      Date.now(),
      patente.toUpperCase(),
    );
    const manejando =
      det.fuente === "eventos" ? !det.parado : decision.manejando;
    if (det.fuente === "eventos") fuenteEventos++;
    const lat = decision.lat;
    const lng = decision.lng;
    if (decision.fuente === "volvo") fuenteVolvo++;
    else if (decision.fuente === "sitrack") fuenteSitrack++;

    evaluados++;

    try {
      // Cargar o crear jornada
      let entrada = await cargarJornadaAbierta(dni);
      if (!entrada) {
        // No hay jornada abierta. Solo creamos una si el chofer está
        // manejando ahora — sino el cron sigue silencioso.
        if (!manejando) continue;
        entrada = nuevaJornada(dni, patente, lat, lng);
        await entrada.ref.set(entrada.data);
        nuevasJornadas++;
      }

      const j = entrada.data;
      const ahora = Timestamp.now();
      const deltaSegBruto =
        (ahora.toMillis() - j.ultima_actualizacion_ts.toMillis()) / 1000;
      const deltaSeg = Math.min(
        Math.max(deltaSegBruto, 0),
        DELTA_MAX_SEGUNDOS
      );

      // Precomputar `tieneDescansoPrevio` para la excepción de veda — solo
      // si va a hacer falta (manejando + en veda + manejo < 2h + sin aviso
      // de veda previo). Evita el query en el caso común. El resto de la
      // lógica vive en `evaluarTickJornada` (pura, testeable).
      let tieneDescansoPrevio = false;
      if (manejando && !j.alerta_veda_enviada) {
        const horaActual = horaArt(ahora.toMillis());
        const enVeda =
          horaActual >= VEDA_NOCTURNA_DESDE_HORA &&
          horaActual < VEDA_NOCTURNA_HASTA_HORA;
        const totalPostDelta =
          j.total_manejo_seg + j.bloque_actual_manejo_seg + deltaSeg;
        if (enVeda && totalPostDelta < 2 * 3600) {
          tieneDescansoPrevio = await descansoPrevioCumplido(dni);
        }
      }

      const { avisos: avisosPendientes, cerrada } = evaluarTickJornada(j, {
        manejando,
        deltaSeg,
        ahoraMs: ahora.toMillis(),
        lat,
        lng,
        tieneDescansoPrevio,
        paroEnMs: det.paroEnMs,
        arrancoMs: det.arrancoMs,
        pausaPreviaSeg: det.pausaPreviaSeg,
      });
      if (cerrada) cerradas++;
      j.ultima_patente = patente;

      await entrada.ref.update(j as unknown as Record<string, unknown>);

      // Encolar avisos (todos los pendientes, no solo el ultimo).
      // Doble-check de silenciado JUST-IN-TIME (auditoria 2026-05-17):
      // el set `silenciados` se cargo al inicio del tick. Si el admin
      // tipea `/silenciar 12345 1h` en el WhatsApp entre el cargado y
      // el momento de encolar, el chofer recibia 1 aviso justo despues
      // del comando. Re-leemos el doc BOT_SILENCIADOS_CHOFER aca por
      // si hubo cambio reciente. Costo: 1 read extra cuando el chofer
      // tiene avisos pendientes (despreciable, los avisos son raros).
      if (avisosPendientes.length > 0 && !silenciados.has(dni)) {
        try {
          const silSnap = await db().collection("BOT_SILENCIADOS_CHOFER").doc(dni).get();
          if (silSnap.exists) {
            const hasta = silSnap.data()?.silenciado_hasta;
            const hastaMs = (hasta as FsTimestamp | undefined)?.toMillis() ?? 0;
            if (hastaMs > Date.now()) {
              silenciados.add(dni);
            }
          }
        } catch {
          // Si falla el lookup, mantenemos el set en memoria (fail-open
          // pero solo si el lookup explicito falla — el set ya fue
          // cargado al inicio del tick).
        }
      }

      for (const avisoTipo of avisosPendientes) {
        if (silenciados.has(dni)) {
          silenciadosCount++;
          logger.info("[jornadas_v2.tick] aviso silenciado", {
            dni, patente, tipo: avisoTipo,
          });
          continue;
        }
        if (avisoTipo === "3h30") await encolarAviso3h30(dni, patente);
        else if (avisoTipo === "bloque_excedido") await encolarAvisoBloqueExcedido(dni, patente);
        else if (avisoTipo === "cuota_proxima") await encolarAvisoCuotaProxima(dni, patente);
        else if (avisoTipo === "cuota") await encolarAvisoCuotaCumplida(dni, patente);
        else if (avisoTipo === "veda") await encolarAvisoVedaNocturna(dni, patente);
        avisosEnviados++;
      }
    } catch (e) {
      logger.warn("[jornadas_v2.tick] falló para chofer", {
        dni, patente, error: (e as Error).message,
      });
    }
  }

  logger.info("[jornadas_v2.tick] OK", {
    evaluados, avisosEnviados, silenciadosCount, nuevasJornadas, cerradas,
    silenciados: silenciados.size,
    fuenteVolvo, fuenteSitrack, fuenteEventos,
  });
}

// ─── Resumen diario a Molina ────────────────────────────────────────────────

const SEG_HIGIENE_DNI = "34730329";

/** Una jornada con incidencias para el resumen a Seg e Higiene. */
export interface ExcesoJornada {
  choferDni: string;
  patente: string;
  inicio: FsTimestamp;
  fin: FsTimestamp | null;
  bloquesCompletos: number;
  totalManejoSeg: number;
  bloqueExcedido: boolean;
  cuotaExcedida: boolean;
  vedaExcedida: boolean;
}

/**
 * Construye el texto del resumen diario de jornadas con incidencias para
 * Molina (Seg e Higiene). PURA — separada de `armarResumenJornadasDiario`
 * para testear el formato sin Firestore. `nombrePorDni` resuelve el
 * nombre del chofer; si falta, cae a "DNI X".
 */
export function construirMensajeResumenJornadas(
  excesos: ExcesoJornada[],
  nombrePorDni: Map<string, string>,
  saludo: string,
  fmtFecha: string,
): string {
  if (excesos.length === 0) {
    return (
      `${saludo},\n\n` +
      `📋 *Resumen jornadas — ${fmtFecha}*\n\n` +
      "✅ Sin incidencias: ninguna jornada cerrada ayer registró " +
      "exceso de bloque, cuota o veda nocturna.\n\n" +
      "_Bot-On — Coopertrans Móvil_"
    );
  }

  const fmtHm = (s: number): string => {
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    return `${h}:${m.toString().padStart(2, "0")}`;
  };

  const lineas = excesos.map((x) => {
    const nombre = nombrePorDni.get(x.choferDni) || `DNI ${x.choferDni}`;
    const flags: string[] = [];
    if (x.bloqueExcedido) flags.push("bloque > 4h sin pausa");
    if (x.cuotaExcedida) flags.push("manejó post-cuota cumplida");
    if (x.vedaExcedida) flags.push("circuló después de 00:00 ART");
    const incioFmt = new Intl.DateTimeFormat("es-AR", {
      timeZone: "America/Argentina/Buenos_Aires",
      day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit",
      hour12: false,
    }).format(x.inicio.toDate());
    return (
      `🚛 *${x.patente || "—"}* — ${nombre} (DNI ${x.choferDni})\n` +
      `   Jornada: arrancó ${incioFmt}, ${x.bloquesCompletos}/3 bloques, ` +
      `${fmtHm(x.totalManejoSeg)} hs manejando\n` +
      `   ⚠️ ${flags.join(", ")}`
    );
  });

  return (
    `${saludo},\n\n` +
    `📋 *Resumen jornadas — ${fmtFecha}*\n\n` +
    `${excesos.length} jornada${excesos.length === 1 ? "" : "s"} con ` +
    "incidencias:\n\n" +
    `${lineas.join("\n\n")}\n\n` +
    "_Modelo de jornada: 3 bloques (3 h 45 manejo + 15 min pausa " +
    "interna, al chofer le pedimos 20 min). Veda nocturna desde las " +
    "00:00 ART. La jornada se cierra después de 8 hs con el camión " +
    "detenido._\n\n" +
    "_Bot-On — Coopertrans Móvil_"
  );
}

/**
 * Cron 8 AM ART. Lee jornadas con flags de exceso (bloque_excedido,
 * cuota_excedida, veda_excedida) que cerraron ayer o están abiertas con
 * alguno de los flags. Manda 1 WhatsApp a Molina.
 */
export async function armarResumenJornadasDiario(): Promise<void> {
  logger.info("[jornadas_v2.resumen] iniciando");

  // Rango: día calendario ART AYER.
  const ahora = new Date();
  const fechaArtAyer = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date(ahora.getTime() - 24 * 60 * 60 * 1000));
  const fechaArtHoy = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).format(ahora);
  const desdeMs = Date.parse(`${fechaArtAyer}T00:00:00-03:00`);
  const hastaMs = Date.parse(`${fechaArtHoy}T00:00:00-03:00`);

  // Query: jornadas que cerraron ayer Y tienen al menos un flag de exceso
  // O jornadas abiertas con flag (raras pero posibles si una jornada lleva
  // varios días por algún problema de datos).
  const snapCerradas = await db()
    .collection(COLECCION)
    .where("jornada_fin_ts", ">=", Timestamp.fromMillis(desdeMs))
    .where("jornada_fin_ts", "<", Timestamp.fromMillis(hastaMs))
    .get();

  const excesos: ExcesoJornada[] = [];

  // Skip excesos de los 3 choferes de combustibles líquidos — no son
  // operativa Vecchi (ver excluidos.ts).
  const excluidos = await cargarExcluidos(db());

  for (const d of snapCerradas.docs) {
    const j = d.data() as JornadaDoc;
    if (!j.bloque_excedido && !j.cuota_excedida && !j.veda_excedida) continue;
    if (excluidos.dnis.has(j.chofer_dni)) continue;
    excesos.push({
      choferDni: j.chofer_dni,
      patente: j.ultima_patente,
      inicio: j.jornada_inicio_ts,
      fin: j.jornada_fin_ts,
      bloquesCompletos: j.bloques_completos,
      totalManejoSeg: j.total_manejo_seg,
      bloqueExcedido: j.bloque_excedido,
      cuotaExcedida: j.cuota_excedida,
      vedaExcedida: j.veda_excedida,
    });
  }

  // Destinatario (Molina)
  const empSnap = await db().collection("EMPLEADOS").doc(SEG_HIGIENE_DNI).get();
  if (!empSnap.exists) {
    logger.error("[jornadas_v2.resumen] destinatario no existe", {
      dni: SEG_HIGIENE_DNI,
    });
    return;
  }
  const empData = empSnap.data() ?? {};
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") {
    logger.error("[jornadas_v2.resumen] destinatario sin TELEFONO");
    return;
  }
  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";
  const fmtFecha = fechaArtAyer.split("-").reverse().join("/");

  // Lookup nombres (fix M2 24/7 2026-05-18: getAll en lugar de loop
  // serial N+1). Solo si hay excesos (sin excesos, el mensaje es fijo).
  const nombrePorDni = new Map<string, string>();
  const dnisUnicos = new Set<string>(excesos.map((x) => x.choferDni));
  if (dnisUnicos.size > 0) {
    try {
      const refs = [...dnisUnicos].map(
        (dni) => db().collection("EMPLEADOS").doc(dni)
      );
      const snaps = await db().getAll(...refs);
      for (const s of snaps) {
        const n = s.exists ?
          (s.data()?.NOMBRE ?? "").toString().trim() :
          "";
        nombrePorDni.set(s.id, n);
      }
    } catch (e) {
      logger.warn("[jornadas_v2.resumen] getAll nombres fallo", {
        error: (e as Error).message,
      });
      for (const dni of dnisUnicos) nombrePorDni.set(dni, "");
    }
  }

  // Construcción del mensaje (PURA, testeable sin Firestore).
  const mensaje = construirMensajeResumenJornadas(
    excesos, nombrePorDni, saludo, fmtFecha
  );

  await db().collection("COLA_WHATSAPP").add({
    telefono: tel, mensaje, estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    expira_en: expiraEnMin(TTL_RESUMEN_DIARIO_MIN),
    enviado_en: null, error: null, intentos: 0,
    origen: "resumen_jornadas_v2", destinatario_coleccion: "EMPLEADOS",
    destinatario_id: SEG_HIGIENE_DNI, campo_base: "JORNADA",
    admin_dni: "BOT", admin_nombre: "Bot resumen jornadas v2",
  });

  logger.info("[jornadas_v2.resumen] OK", {
    excesos: excesos.length, destinatario: SEG_HIGIENE_DNI,
  });
}
