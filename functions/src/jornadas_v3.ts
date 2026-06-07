// ============================================================================
// Vigilador de jornada — v3 · Registro a posteriori (Paso 1, Camino B)
// ============================================================================
//
// Ver docs/PLAN_vigilador_jornada_v3.md (diseño acordado con Santiago 2026-06-07).
//
// FILOSOFÍA: separar el AVISO EN VIVO (preventivo, blando, solo con dato fresco —
// eso sigue siendo el v2) del REGISTRO DE JORNADA (la VERDAD, calculada A
// POSTERIORI con TODOS los eventos Sitrack ya llegados). Este módulo es el
// REGISTRO: determinístico, auditable, transparente al chofer.
//
// Raíz del problema que ataca (3 reportes reales del 06-jun, buzón
// REPORTES_DISCREPANCIA): el v2 intenta saber la verdad EN TIEMPO REAL con datos
// que llegan tarde y con huecos (gaps de cobertura GSM). En vivo el evento de la
// parada todavía no llegó → cuenta "manejo continuo" → avisa "4h" injusto. A
// POSTERIORI los eventos ya están: la parada que en vivo no se veía, acá SÍ.
//
// FUENTE: solo SITRACK_EVENTOS (lo más completo). Exprime las señales DIRECTAS
// que el v2 casi no usa — eventos de contacto/ignición y detenido/fin-detenido —
// más confiables que inferir de la velocidad de un snapshot.
//
// SEÑALES (event_id confirmados, Paso 0 — verificadas contra data real Vecchi):
//   Paró   : 164 Contacto OFF · 6 Inicio de detenido · 331/332 Detenido.
//   Arrancó: 7 Fin de detenido · 333/334 Movimiento  (Contacto ON 163 NO alcanza:
//            el motor enciende pero el chofer puede seguir en pausa — caso LOPEZ,
//            163 a las 13:13 y recién arranca de verdad 13:28).
//   Marcha : 283 Cambio de curso (el más frecuente) + cualquier evento speed>15.
//   Baja confianza: 386 Bloqueo celular y GPS · gaps sin posición · gaps largos
//                   con desplazamiento (no se puede ver si hubo parada adentro).
//
// HALLAZGO CLÍNICO de la data real: hay eventos `283` con `ignition==0` pero
// `speed==75` (FERNANDEZ 11:56) → el campo ignition es POCO confiable en marcha.
// Por eso el "paró" se decide por EVENT_ID (164/6/331/332), NUNCA por ignition==0
// a secas. ignition queda en el input para futuro, pero NO se usa como gatillo.
//
// LÓGICA PURA, sin I/O — testeable sin emulador (patrón ganador del repo, igual
// que `evaluarTickJornada` / `analizarEventosDetencion` del v2). El caller (Paso
// 2, no ahora) lee SITRACK_EVENTOS del turno, mapea a EventoJornadaLite y persiste
// el RegistroJornada que devuelve esta función.
//
// NO toca el v2: corre al lado. El v2 sigue siendo el aviso en vivo; este es el
// registro de la verdad. "Destronar" al v2 es el Paso 4, con OK de Santiago.

// Reusar constantes + helpers del v2 (single source of truth — el plan pide
// "reusá las constantes del v2"). distanciaMetros es la Haversine ya testeada.
import {
  distanciaMetros,
  PAUSA_BLOQUE_SEGUNDOS, // 15 min — pausa que cierra un bloque
  RADIO_PAUSA_GAP_METROS, // 500 m — "no se movió" entre dos reportes
  DESCANSO_MIN_SEGUNDOS, // 8 h — descanso mínimo entre jornadas (corte de turno)
  UMBRAL_MOVIMIENTO_KMH, // 15 km/h — umbral manejo/parado
  BLOQUE_EXCEDIDO_SEGUNDOS, // 4 h — manejo continuo sin pausar = infracción
  JORNADA_MANEJO_LIMITE_SEGUNDOS, // 12 h — tope de manejo neto por jornada
} from "./jornadas_v2";
// Nota: el corte de turno usa el GAP de 8 h entre eventos (el caso real: el
// equipo se apaga de noche y deja de transmitir), igual que la ruta robusta del
// v2 (gap-descanso, fix 2026-06-04). No usamos DESCANSO_RADIO_METROS: un gap de
// 8 h ya es un descanso de jornada, sin importar dónde reaparezca el camión.

// ─── Constantes propias del v3 ───────────────────────────────────────────────

/** event_id Sitrack (Paso 0). */
export const EV = {
  INICIO_DETENIDO: 6,
  FIN_DETENIDO: 7,
  CONTACTO_ON: 163,
  CONTACTO_OFF: 164,
  CAMBIO_CURSO: 283,
  BLOQUEO_GPS: 386,
  DETENIDO_SIN_CONTACTO: 331,
  DETENIDO_CON_CONTACTO: 332,
  MOVIMIENTO_A: 333,
  MOVIMIENTO_B: 334,
} as const;

const EVENTOS_PARO = new Set<number>([
  EV.INICIO_DETENIDO, EV.CONTACTO_OFF,
  EV.DETENIDO_SIN_CONTACTO, EV.DETENIDO_CON_CONTACTO,
]);
const EVENTOS_ARRANQUE = new Set<number>([
  EV.FIN_DETENIDO, EV.MOVIMIENTO_A, EV.MOVIMIENTO_B,
]);

/** Un gap (intervalo sin eventos) de al menos esto se examina: si la posición no
 * cambió es una pausa encubierta; si no hay posición es un tramo ciego. Reusa el
 * umbral de pausa de bloque: 15 min es justo lo que importa para la jornada. */
export const GAP_GRANDE_SEGUNDOS = PAUSA_BLOQUE_SEGUNDOS;

/** Umbral para marcar BAJA CONFIANZA un gap en el que el camión SÍ se movió
 * (> 500 m). Más alto que GAP_GRANDE a propósito: un tramo recto de autopista no
 * dispara eventos `283` por 15-25 min — es manejo normal, no sospechoso. Recién
 * a partir de ~30 min el gap es lo bastante largo como para que adentro quepa una
 * parada ≥ 15 min que no vemos (caso del reclamo de FERNANDEZ: gap de 51 min). Si
 * marcáramos baja todo gap ≥ 15 min, casi toda jornada saldría "baja" y la señal
 * sería inútil. (Un gap SIN posición es ciego desde los 15 min — ver abajo.) */
export const GAP_BAJA_CONFIANZA_SEGUNDOS = 30 * 60;

/** Pausas de al menos esto se listan en `pausas[]` y en la explicación al chofer
 * (las más cortas son ruido — semáforos, maniobras). Las que cierran bloque son
 * las ≥ PAUSA_BLOQUE_SEGUNDOS; estas se muestran igual para transparencia. */
export const PAUSA_REPORTABLE_SEGUNDOS = 5 * 60;

/**
 * Umbral para considerar que una parada es un DESCANSO que CORTA el turno (no un
 * break dentro de la jornada). MÁS BAJO que el descanso legal de 8 h a propósito:
 * un descanso real a menudo se MIDE algo corto por el slop de la telemetría
 * (cuándo dispara "detenido"/"fin de detenido") — caso real GASTON DIETRICH:
 * descansó 21:48→05:32 = 7h44 y, con corte estricto a 8 h, su turno encadenaba
 * día+noche+día → manejo neto inflado y falsos "jornada excedida".
 *
 * Elegido con datos (histograma de pausas, 8 días / ~270 chofer-días): los
 * breaks decrecen hasta un VALLE en 5-7 h (~33 c/u) y los descansos REPUNTAN en
 * 7-8 h (60) con pico en 8-9 h (80). 7 h cae en el borde del valle: separa break
 * de descanso y tolera el slop. El descanso < 8 h legal NO se pierde: se marca
 * aparte con `descansoInsuficiente` (ver RegistroJornada). */
export const DESCANSO_TURNO_SEGUNDOS = 7 * 3600;

/** Solapamiento temporal mínimo entre dos patentes de un MISMO DNI para tratarlo
 * como DRIFT (CHOFER_DISTINTO: el iButton del chofer en una unidad + otra unidad
 * reportando su nombre legacy) y no como un cambio de unidad secuencial. Los
 * drifts reales solapan 60 min+; un cambio de camión legítimo solapa ~0. */
export const DRIFT_SOLAPE_SEGUNDOS = 15 * 60;

/** Velocidad implícita (km recorridos ÷ horas de manejo) por encima de la cual
 * la DISTANCIA corrobora que el manejo fue real, aunque la telemetría tuviera
 * gaps. Validado con datos: los días de manejo real dan ~65 km/h implícitos; si
 * el manejo estuviera inflado (idle/paradas contadas como manejo) daría 25-40.
 * Por encima de esto, un gap con desplazamiento NO baja la confianza a "baja"
 * (la distancia ya prueba que estuvo manejando). */
export const VEL_CORROBORA_KMH = 45;

/** Veda nocturna Vecchi: prohibido manejar 00:00–06:00 ART. El registro mide
 * cuánto manejo cayó en esa franja; si supera VEDA_MIN_SEGUNDOS lo marca como
 * `vedaExcedida` (un blip de borde, p.ej. parar 00:02, no cuenta). Paridad con
 * el flag `veda_excedida` del v2, pero medido a posteriori sobre los segmentos. */
export const VEDA_FIN_HORA = 6; // 06:00 ART
export const VEDA_MIN_SEGUNDOS = 5 * 60;

// ─── Tipos ───────────────────────────────────────────────────────────────────

/** Evento Sitrack mínimo que consume el batch. Se mapea de SITRACK_EVENTOS
 * (campos confirmados en el poller `sitrack.ts:691`): ms ← report_date,
 * eventId ← event_id, speed/gpsSpeed, ignition (0/1/null), lat/lng ←
 * latitude/longitude, gpsValidity ← gps_validity. */
export interface EventoJornadaLite {
  ms: number;
  eventId: number | null;
  eventName?: string;
  speed: number | null;
  gpsSpeed: number | null;
  /** 0 | 1 | null. NO se usa como gatillo de paro (poco confiable en marcha);
   * queda para diagnóstico / futuro. */
  ignition: number | null;
  lat: number | null;
  lng: number | null;
  gpsValidity?: number | null;
  /** Patente (asset_id) del evento, normalizada. Opcional: si se provee, permite
   * detectar y filtrar el drift CHOFER_DISTINTO (un DNI con eventos de 2 unidades
   * solapadas en el tiempo → se reconstruiría una mezcla de 2 camiones). */
  patente?: string | null;
}

export type TipoSegmento = "manejo" | "pausa";
export type Confianza = "alta" | "media" | "baja";
export type OrigenPausa =
  | "contacto_off" // motor apagado (164)
  | "detenido" // inicio de detenido / detenido (6/331/332)
  | "gap_misma_pos" // gap sin reportes pero no se movió (parada encubierta)
  | "parado"; // velocidad baja sostenida sin evento explícito

export interface SegmentoJornada {
  tipo: TipoSegmento;
  inicioMs: number;
  finMs: number;
  durSeg: number;
  confianza: Confianza;
  /** solo en pausas: cómo se detectó. */
  origen?: OrigenPausa;
  /** posición representativa (del evento que abrió el segmento). */
  lat: number | null;
  lng: number | null;
  /** si confianza baja: por qué (gap con desplazamiento, sin posición, etc.). */
  motivoBaja?: string;
}

export interface PausaJornada {
  inicioMs: number;
  finMs: number;
  durSeg: number;
  origen: OrigenPausa;
  confianza: Confianza;
  lat: number | null;
  lng: number | null;
  /** true si dura ≥ 15 min → cierra el bloque de manejo. */
  cierraBloque: boolean;
}

export interface BloqueJornada {
  indice: number; // 1..N
  manejoNetoSeg: number;
  inicioMs: number;
  finMs: number;
  /** true si el manejo continuo del bloque cruzó las 4 h sin pausa de 15 min. */
  excedido: boolean;
}

export interface RegistroJornada {
  inicioTurnoMs: number | null;
  finTurnoMs: number | null;
  manejoNetoSeg: number;
  pausaTotalSeg: number;
  /** km recorridos en el turno (suma de tramos entre eventos con posición).
   * Corrobora el manejo: recorridoKm ÷ (manejoNetoSeg/3600) ≈ crucero ⇒ real. */
  recorridoKm: number;
  segmentos: SegmentoJornada[];
  pausas: PausaJornada[];
  bloques: BloqueJornada[];
  /** cantidad de bloques que superaron 4 h de manejo continuo. */
  bloquesExcedidos: number;
  /** duración (seg) del descanso INMEDIATAMENTE ANTERIOR a este turno, si se
   * pudo ver en los datos. null = no se ve (es el primer turno del rango). */
  descansoPrevioSeg: number | null;
  /** true si el descanso previo existió pero fue < 8 h (el mínimo legal Vecchi).
   * El turno se corta igual (fue claramente un descanso) pero queda señalado:
   * el chofer no completó las 8 h de descanso entre jornadas. */
  descansoInsuficiente: boolean;
  /** true si se descartaron eventos de OTRA patente (drift CHOFER_DISTINTO): un
   * 2º camión reportaba el nombre de este chofer solapado en el tiempo. El
   * registro se reconstruyó solo con la patente dominante; queda señalado porque
   * la atribución de unidad pudo quedar ambigua (confianza se baja a ≤ media). */
  driftFiltrado: boolean;
  /** true si el manejo NETO de la jornada superó el tope de 12 h (paridad con
   * el aviso `cuota` del v2). Distinto de `bloquesExcedidos` (4 h por bloque):
   * un chofer puede no exceder ningún bloque y aun así pasar las 12 h netas
   * sumando bloques (caso real FERNANDEZ 06-jun: 12h30 en 5 bloques < 4 h). */
  jornadaExcedida: boolean;
  /** manejo (seg) dentro de la veda 00:00–06:00 ART. */
  manejoNocturnoSeg: number;
  /** true si manejó de noche por encima del umbral (veda Vecchi). */
  vedaExcedida: boolean;
  confianza: Confianza;
  /** líneas legibles para el chofer / supervisor (Paso 2 las muestra). */
  explicacion: string[];
}

// ─── Clasificación de eventos (PURA) ─────────────────────────────────────────

/** Velocidad efectiva: la mayor entre speed y gpsSpeed (cualquiera puede venir
 * null o quedar rezagada; tomamos la que indica movimiento). */
function velEf(ev: EventoJornadaLite): number {
  return Math.max(ev.speed ?? -1, ev.gpsSpeed ?? -1);
}

/** Evento que marca que el camión PARÓ (motor apagado / inicio de detenido). */
export function esParoEvento(ev: EventoJornadaLite): boolean {
  return ev.eventId != null && EVENTOS_PARO.has(ev.eventId);
}

/** Evento que marca que el camión ARRANCÓ (fin de detenido / movimiento).
 * Contacto ON (163) NO cuenta: encender el motor no es arrancar (el chofer
 * puede seguir en pausa con el motor en marcha). */
export function esArranqueEvento(ev: EventoJornadaLite): boolean {
  return ev.eventId != null && EVENTOS_ARRANQUE.has(ev.eventId);
}

/** El camión está EN MARCHA en este evento: velocidad sobre el umbral o un
 * evento explícito de arranque/movimiento. */
export function esMovimientoEvento(ev: EventoJornadaLite): boolean {
  return velEf(ev) > UMBRAL_MOVIMIENTO_KMH || esArranqueEvento(ev);
}

/** Estado físico que deja un evento, dado el estado previo. Un blip de velocidad
 * baja SIN evento de paro NO tumba a un camión que venía manejando (curva,
 * semáforo, GPS jitter) — solo un evento de paro explícito o velocidad>umbral
 * cambian el estado. Esto evita pausas fantasma de un solo punto. */
function siguienteEstado(
  ev: EventoJornadaLite, previo: TipoSegmento
): TipoSegmento {
  if (esParoEvento(ev)) return "pausa";
  if (esMovimientoEvento(ev)) return "manejo";
  return previo;
}

/** Origen de pausa a partir del primer evento de paro del tramo. */
function origenDePausa(ev: EventoJornadaLite): OrigenPausa {
  if (ev.eventId === EV.CONTACTO_OFF) return "contacto_off";
  if (
    ev.eventId === EV.INICIO_DETENIDO ||
    ev.eventId === EV.DETENIDO_SIN_CONTACTO ||
    ev.eventId === EV.DETENIDO_CON_CONTACTO
  ) {
    return "detenido";
  }
  return "parado";
}

// ─── Núcleo: reconstrucción de UN turno (PURA) ───────────────────────────────

interface IntervaloCrudo {
  tipo: TipoSegmento;
  inicioMs: number;
  finMs: number;
  confianza: Confianza;
  origen?: OrigenPausa;
  lat: number | null;
  lng: number | null;
  motivoBaja?: string;
}

/**
 * Reconstruye la línea de tiempo manejo/pausa de UN turno (sin gaps ≥ 8 h
 * adentro — `partirEnTurnos` ya cortó por descanso). Asume eventos ordenados.
 *
 * Algoritmo (determinístico, auditable):
 *  1. Estado físico por evento (paró/arrancó/marcha; blips lentos no tumban).
 *  2. Cada INTERVALO [ev[i], ev[i+1]] hereda el estado dejado por ev[i].
 *  3. Override de pausa encubierta: intervalo "manejo" con gap ≥ 15 min y
 *     desplazamiento ≤ 500 m → fue PAUSA (paró sin cobertura — fix d7b751f en
 *     versión batch). Si el gap ≥ 15 min PERO se movió (> 500 m) o falta
 *     posición → sigue siendo manejo, marcado BAJA CONFIANZA (adentro pudo
 *     esconderse una parada que no vemos).
 *  4. Eventos 386 (Bloqueo GPS) bajan la confianza del intervalo que tocan.
 */
/** Construye la línea de tiempo (segmentos + intervalos crudos) de una secuencia
 * de eventos YA ordenados-able. NO parte en turnos — eso lo hace el caller. */
function construirSegmentos(
  eventos: EventoJornadaLite[]
): { segmentos: SegmentoJornada[]; intervalos: IntervaloCrudo[] } {
  const evs = [...eventos].sort((a, b) => a.ms - b.ms);
  if (evs.length < 2) return { segmentos: [], intervalos: [] };

  // 1) Estado físico dejado por cada evento.
  const estados: TipoSegmento[] = new Array(evs.length);
  estados[0] = esMovimientoEvento(evs[0]) ? "manejo" : "pausa";
  for (let i = 1; i < evs.length; i++) {
    estados[i] = siguienteEstado(evs[i], estados[i - 1]);
  }

  // 2-4) Intervalos.
  const intervalos: IntervaloCrudo[] = [];
  for (let i = 0; i < evs.length - 1; i++) {
    const a = evs[i];
    const b = evs[i + 1];
    const dur = (b.ms - a.ms) / 1000;
    if (dur <= 0) continue;
    let tipo = estados[i];
    let confianza: Confianza = "alta";
    let origen: OrigenPausa | undefined;
    let motivoBaja: string | undefined;

    if (dur >= DESCANSO_TURNO_SEGUNDOS) {
      // ≥ 7 h sin un solo reporte es un DESCANSO, no manejo: nadie maneja 7 h
      // sin que el equipo emita un `283` (el camión estuvo parado, con el equipo
      // apagado o no). Forzamos pausa → `partirSegmentosEnTurnos` corta el turno
      // acá. Cubre tanto el gap (equipo apagado) como, tras el merge, el descanso
      // en el lugar con heartbeats.
      tipo = "pausa";
      origen = esParoEvento(a) ? origenDePausa(a) : "parado";
    } else if (tipo === "manejo" && dur >= GAP_GRANDE_SEGUNDOS) {
      const hayPos =
        a.lat != null && a.lng != null && b.lat != null && b.lng != null;
      if (!hayPos) {
        // Gap sin posición: ciego desde los 15 min (no sabemos si paró).
        confianza = "baja";
        motivoBaja = "gap sin reportes ni posición";
      } else if (
        distanciaMetros(a.lat!, a.lng!, b.lat!, b.lng!) <=
          RADIO_PAUSA_GAP_METROS
      ) {
        // No se movió durante el gap → pausa encubierta (paró sin cobertura).
        tipo = "pausa";
        origen = "gap_misma_pos";
      } else if (dur >= GAP_BAJA_CONFIANZA_SEGUNDOS) {
        // Se movió, pero el gap es largo: adentro pudo esconderse una parada.
        confianza = "baja";
        motivoBaja = "gap sin reportes con desplazamiento";
      }
      // Gap 15–30 min moviéndose = manejo normal de ruta (alta confianza).
    }

    // Bloqueo GPS en cualquiera de los bordes → baja la confianza del tramo.
    if (a.eventId === EV.BLOQUEO_GPS || b.eventId === EV.BLOQUEO_GPS) {
      confianza = "baja";
      motivoBaja = motivoBaja ?? "bloqueo celular/GPS";
    }

    if (tipo === "pausa" && origen == null) {
      origen = esParoEvento(a) ? origenDePausa(a) : "parado";
    }

    intervalos.push({
      tipo, inicioMs: a.ms, finMs: b.ms, confianza, origen,
      lat: a.lat, lng: a.lng, motivoBaja,
    });
  }

  return { segmentos: fusionarSegmentos(intervalos), intervalos };
}

/**
 * Parte una lista de segmentos en TURNOS en cada PAUSA de descanso (≥ 8 h). Esa
 * pausa es la frontera (descanso entre jornadas) y NO pertenece a ningún turno.
 *
 * Por qué hace falta (hallazgo de la auditoría 07-jun sobre la flota real): el
 * descanso nocturno casi nunca es un GAP sin reportes — el equipo sigue mandando
 * heartbeats con el camión parado, así que `partirEnTurnos` (que corta por gap
 * ≥ 8 h) no lo veía y el turno encadenaba día+noche+día → manejo neto inflado
 * (11-16 h) y falsos "jornada excedida". Un descanso en el lugar de ≥ 8 h ES una
 * frontera de jornada por la regla Vecchi, aunque el equipo no se haya apagado.
 */
interface GrupoTurno {
  segmentos: SegmentoJornada[];
  /** descanso (seg) que precede a este grupo; null para el primero del rango. */
  descansoPrevioSeg: number | null;
}

function partirSegmentosEnTurnos(
  segmentos: SegmentoJornada[]
): GrupoTurno[] {
  const grupos: GrupoTurno[] = [];
  let actual: SegmentoJornada[] = [];
  let descansoPrevio: number | null = null;
  for (const seg of segmentos) {
    if (seg.tipo === "pausa" && seg.durSeg >= DESCANSO_TURNO_SEGUNDOS) {
      if (actual.length) {
        grupos.push({ segmentos: actual, descansoPrevioSeg: descansoPrevio });
      }
      actual = [];
      descansoPrevio = seg.durSeg; // este descanso precede al PRÓXIMO turno
    } else {
      actual.push(seg);
    }
  }
  if (actual.length) {
    grupos.push({ segmentos: actual, descansoPrevioSeg: descansoPrevio });
  }
  return grupos;
}

/** Arma el RegistroJornada de UN turno a partir de sus segmentos (ya sin
 * descansos ≥ 8 h adentro). `intervalos` es la lista completa del chunk — sirve
 * para la confianza global, que se acota sola a [inicioTurno, finTurno]. */
function registroDeSegmentos(
  segmentos: SegmentoJornada[], intervalos: IntervaloCrudo[],
  evs: EventoJornadaLite[], descansoPrevioSeg: number | null,
  driftFiltrado: boolean
): RegistroJornada {
  // Turno = desde el primer segmento de MANEJO (primer movimiento del día).
  const idxPrimerManejo = segmentos.findIndex((s) => s.tipo === "manejo");
  if (idxPrimerManejo === -1) return jornadaVacia();
  const segTurno = segmentos.slice(idxPrimerManejo);
  const inicioTurnoMs = segTurno[0].inicioMs;
  const finTurnoMs = segTurno[segTurno.length - 1].finMs;

  const manejoNetoSeg = sumDur(segTurno, "manejo");
  const pausaTotalSeg = sumDur(segTurno, "pausa");
  const recorridoKm = distanciaRecorridaKm(evs, inicioTurnoMs, finTurnoMs);
  const impliedKmh = manejoNetoSeg > 0 ?
    recorridoKm / (manejoNetoSeg / 3600) : 0;

  const pausas = construirPausas(segTurno);
  const bloques = partirEnBloques(segTurno);
  const bloquesExcedidos = bloques.filter((b) => b.excedido).length;
  const jornadaExcedida = manejoNetoSeg >= JORNADA_MANEJO_LIMITE_SEGUNDOS;
  const manejoNoctSeg = manejoNocturnoSeg(segTurno);
  const vedaExcedida = manejoNoctSeg >= VEDA_MIN_SEGUNDOS;
  const descansoInsuficiente =
    descansoPrevioSeg != null && descansoPrevioSeg < DESCANSO_MIN_SEGUNDOS;
  let confianza = confianzaGlobal(
    intervalos, evs, inicioTurnoMs, finTurnoMs, impliedKmh
  );
  // El drift descartó eventos de otra patente → la atribución pudo quedar
  // ambigua: la confianza no puede ser "alta".
  if (driftFiltrado && confianza === "alta") confianza = "media";
  const explicacion = construirExplicacion({
    inicioTurnoMs, finTurnoMs, manejoNetoSeg, pausas, bloques,
    bloquesExcedidos, jornadaExcedida, descansoPrevioSeg, descansoInsuficiente,
    manejoNocturnoSeg: manejoNoctSeg, vedaExcedida, driftFiltrado, confianza,
  });

  return {
    inicioTurnoMs, finTurnoMs, manejoNetoSeg, pausaTotalSeg, recorridoKm,
    segmentos: segTurno, pausas, bloques, bloquesExcedidos,
    descansoPrevioSeg, descansoInsuficiente, jornadaExcedida,
    manejoNocturnoSeg: manejoNoctSeg, vedaExcedida, driftFiltrado,
    confianza, explicacion,
  };
}

/** Línea de tiempo completa (segmentos manejo/pausa) SIN partir en turnos.
 * Útil para diagnóstico/calibración (p.ej. histograma de duraciones de pausa). */
export function lineaDeTiempo(
  eventos: EventoJornadaLite[]
): SegmentoJornada[] {
  return construirSegmentos(eventos).segmentos;
}

/**
 * Filtra el DRIFT CHOFER_DISTINTO: si los eventos de un DNI vienen de 2+ patentes
 * SOLAPADAS en el tiempo (≥ DRIFT_SOLAPE_SEGUNDOS), se queda con la patente
 * DOMINANTE (más eventos) + los eventos sin patente. Sin esto, reconstruir la
 * mezcla de 2 camiones (uno parado, otro en ruta) da una línea de tiempo basura
 * (saltos de posición → pausas/manejo fantasma). Es el equivalente batch del
 * filtro `patenteEsperada` del v2. Si no hay patente o es una sola, no toca nada;
 * si las patentes son secuenciales (cambio de unidad, sin solape) tampoco. PURA.
 */
export function filtrarDriftPatente(
  eventos: EventoJornadaLite[]
): { eventos: EventoJornadaLite[]; driftFiltrado: boolean } {
  const rangos = new Map<string, { min: number; max: number; n: number }>();
  for (const e of eventos) {
    const p = e.patente;
    if (p == null || p === "") continue;
    const r = rangos.get(p);
    if (!r) rangos.set(p, { min: e.ms, max: e.ms, n: 1 });
    else {
      r.min = Math.min(r.min, e.ms);
      r.max = Math.max(r.max, e.ms);
      r.n++;
    }
  }
  if (rangos.size < 2) return { eventos, driftFiltrado: false };
  const pats = [...rangos.entries()];
  let solapeMs = 0;
  for (let i = 0; i < pats.length; i++) {
    for (let j = i + 1; j < pats.length; j++) {
      const a = pats[i][1];
      const b = pats[j][1];
      const ov = Math.min(a.max, b.max) - Math.max(a.min, b.min);
      if (ov > solapeMs) solapeMs = ov;
    }
  }
  if (solapeMs < DRIFT_SOLAPE_SEGUNDOS * 1000) {
    return { eventos, driftFiltrado: false }; // cambio de unidad secuencial: OK
  }
  let dom = pats[0][0];
  let domN = pats[0][1].n;
  for (const [p, r] of pats) if (r.n > domN) { dom = p; domN = r.n; }
  const filtrados = eventos.filter(
    (e) => e.patente == null || e.patente === "" || e.patente === dom
  );
  return { eventos: filtrados, driftFiltrado: true };
}

function fusionarSegmentos(intervalos: IntervaloCrudo[]): SegmentoJornada[] {
  const out: SegmentoJornada[] = [];
  for (const iv of intervalos) {
    const ult = out[out.length - 1];
    if (ult && ult.tipo === iv.tipo) {
      ult.finMs = iv.finMs;
      ult.durSeg = (ult.finMs - ult.inicioMs) / 1000;
      // Confianza del segmento: baja si CUALQUIER intervalo es bajo.
      if (iv.confianza === "baja") {
        ult.confianza = "baja";
        ult.motivoBaja = ult.motivoBaja ?? iv.motivoBaja;
      }
      // Origen de pausa: preferir una señal explícita por sobre la encubierta.
      if (iv.tipo === "pausa" && ult.origen === "gap_misma_pos" &&
          iv.origen && iv.origen !== "gap_misma_pos") {
        ult.origen = iv.origen;
      }
    } else {
      out.push({
        tipo: iv.tipo,
        inicioMs: iv.inicioMs,
        finMs: iv.finMs,
        durSeg: (iv.finMs - iv.inicioMs) / 1000,
        confianza: iv.confianza,
        origen: iv.origen,
        lat: iv.lat,
        lng: iv.lng,
        motivoBaja: iv.motivoBaja,
      });
    }
  }
  return out;
}

function sumDur(segs: SegmentoJornada[], tipo: TipoSegmento): number {
  return segs.filter((s) => s.tipo === tipo)
    .reduce((acc, s) => acc + s.durSeg, 0);
}

/** Distancia recorrida (km) sumando tramos entre eventos consecutivos con
 * posición dentro de [inicioMs, finMs]. Sirve para corroborar el manejo: si
 * km/horas-de-manejo ≈ velocidad de crucero, el manejo fue real. */
function distanciaRecorridaKm(
  evs: EventoJornadaLite[], inicioMs: number, finMs: number
): number {
  const e2 = evs
    .filter((e) => e.ms >= inicioMs && e.ms <= finMs &&
      e.lat != null && e.lng != null)
    .sort((a, b) => a.ms - b.ms);
  let km = 0;
  for (let i = 1; i < e2.length; i++) {
    km += distanciaMetros(
      e2[i - 1].lat!, e2[i - 1].lng!, e2[i].lat!, e2[i].lng!
    ) / 1000;
  }
  return km;
}

/** 00:00 ART (en epoch ms) del día ART al que pertenece `ms`. ART = UTC-3 fijo
 * (sin DST), así que 00:00 ART = 03:00 UTC del mismo día calendario ART. */
function medianocheArtMs(ms: number): number {
  const f = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date(ms));
  return Date.parse(`${f}T03:00:00Z`);
}

/** Manejo nocturno (segundos) en la veda 00:00–06:00 ART: suma la porción de
 * cada segmento de MANEJO que cae en esa franja. Robusto a segmentos que cruzan
 * medianoche (recorre día por día). */
function manejoNocturnoSeg(segs: SegmentoJornada[]): number {
  let total = 0;
  for (const s of segs) {
    if (s.tipo !== "manejo") continue;
    let dia = medianocheArtMs(s.inicioMs);
    while (dia < s.finMs) {
      const nocheFin = dia + VEDA_FIN_HORA * 3600 * 1000;
      const ov = Math.min(s.finMs, nocheFin) - Math.max(s.inicioMs, dia);
      if (ov > 0) total += ov / 1000;
      dia += 24 * 3600 * 1000;
    }
  }
  return total;
}

function construirPausas(segs: SegmentoJornada[]): PausaJornada[] {
  return segs
    .filter((s) => s.tipo === "pausa" && s.durSeg >= PAUSA_REPORTABLE_SEGUNDOS)
    .map((s) => ({
      inicioMs: s.inicioMs,
      finMs: s.finMs,
      durSeg: s.durSeg,
      origen: s.origen ?? "parado",
      confianza: s.confianza,
      lat: s.lat,
      lng: s.lng,
      cierraBloque: s.durSeg >= PAUSA_BLOQUE_SEGUNDOS,
    }));
}

/**
 * Parte el manejo en bloques con el modelo del v2: una pausa ≥ 15 min cierra el
 * bloque (resetea el manejo continuo). Una pausa corta NO resetea (el manejo
 * continuo sigue acumulando a través de ella). Si el manejo continuo cruza 4 h
 * sin una pausa ≥ 15 min, el bloque queda marcado como excedido (infracción).
 */
function partirEnBloques(segs: SegmentoJornada[]): BloqueJornada[] {
  const bloques: BloqueJornada[] = [];
  let manejoCont = 0;
  let inicioMs: number | null = null;
  let finMs = 0;
  let excedido = false;

  const cerrar = () => {
    if (manejoCont > 0 && inicioMs != null) {
      bloques.push({
        indice: bloques.length + 1,
        manejoNetoSeg: manejoCont,
        inicioMs, finMs, excedido,
      });
    }
    manejoCont = 0;
    inicioMs = null;
    excedido = false;
  };

  for (const s of segs) {
    if (s.tipo === "manejo") {
      if (inicioMs == null) inicioMs = s.inicioMs;
      manejoCont += s.durSeg;
      finMs = s.finMs;
      if (manejoCont >= BLOQUE_EXCEDIDO_SEGUNDOS) excedido = true;
    } else if (s.durSeg >= PAUSA_BLOQUE_SEGUNDOS) {
      cerrar();
    }
    // pausa corta (< 15 min): no cierra, el manejo continuo sigue.
  }
  cerrar();
  return bloques;
}

/**
 * Confianza global del registro. Distingue dos tipos de tiempo dudoso (por TIEMPO
 * de gap, no por segmentos enteros):
 *   - CIEGO: gap sin posición o Bloqueo GPS → no se puede corroborar nada.
 *   - GAP con desplazamiento: el camión se movió pero sin reportes intermedios.
 *     Acá la DISTANCIA corrobora: si km/horas-de-manejo ≈ crucero, el manejo fue
 *     real (validado con datos: ~65 km/h en días reales; 25-40 si fuera inflado).
 * Reglas: Bloqueo GPS o mucho tiempo ciego → baja. Gaps con desplazamiento
 * grandes pero corroborados por distancia → media (no baja). Sin dudas → alta.
 */
function confianzaGlobal(
  intervalos: IntervaloCrudo[], evs: EventoJornadaLite[],
  inicioMs: number, finMs: number, impliedKmh: number
): Confianza {
  const hayBloqueoGps = evs.some(
    (e) => e.eventId === EV.BLOQUEO_GPS && e.ms >= inicioMs && e.ms <= finMs
  );
  if (hayBloqueoGps) return "baja";
  const turnoSeg = Math.max(1, (finMs - inicioMs) / 1000);
  let ciegoSeg = 0; // gap sin posición (no corroborable)
  let gapSeg = 0; // gap con desplazamiento (corroborable por distancia)
  for (const iv of intervalos) {
    if (iv.confianza !== "baja") continue;
    if (iv.inicioMs < inicioMs || iv.finMs > finMs) continue;
    const dur = (iv.finMs - iv.inicioMs) / 1000;
    if (iv.motivoBaja && iv.motivoBaja.includes("posición")) ciegoSeg += dur;
    else gapSeg += dur;
  }
  // Tiempo ciego significativo → baja (no hay forma de saber qué pasó).
  if (ciegoSeg / turnoSeg > 0.33) return "baja";
  // Gaps con desplazamiento dominantes: la distancia decide.
  if (gapSeg / turnoSeg > 0.5) {
    return impliedKmh >= VEL_CORROBORA_KMH ? "media" : "baja";
  }
  if (ciegoSeg > 0 || gapSeg > 0) return "media";
  return "alta";
}

// ─── Formato ART (para la explicación al chofer) ─────────────────────────────

/** HH:MM en hora Argentina (UTC-3). Igual criterio que el resto de la app. */
export function horaMinArt(ms: number): string {
  return new Intl.DateTimeFormat("es-AR", {
    timeZone: "America/Argentina/Buenos_Aires",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(ms)).replace(/^24:/, "00:");
}

function hhmm(seg: number): string {
  const h = Math.floor(seg / 3600);
  const m = Math.floor((seg % 3600) / 60);
  return h > 0 ? `${h}h ${String(m).padStart(2, "0")}m` : `${m} min`;
}

function descOrigen(o: OrigenPausa): string {
  switch (o) {
  case "contacto_off": return "motor apagado";
  case "detenido": return "detenido";
  case "gap_misma_pos": return "parado (sin cobertura, misma posición)";
  default: return "parado";
  }
}

function construirExplicacion(r: {
  inicioTurnoMs: number; finTurnoMs: number; manejoNetoSeg: number;
  pausas: PausaJornada[]; bloques: BloqueJornada[]; bloquesExcedidos: number;
  jornadaExcedida: boolean; descansoPrevioSeg: number | null;
  descansoInsuficiente: boolean; manejoNocturnoSeg: number;
  vedaExcedida: boolean; driftFiltrado: boolean; confianza: Confianza;
}): string[] {
  const lineas: string[] = [];
  lineas.push(
    `Turno ${horaMinArt(r.inicioTurnoMs)}–${horaMinArt(r.finTurnoMs)} (ART)`
  );
  for (const p of r.pausas) {
    const dudosa = p.confianza === "baja" ? " (a confirmar)" : "";
    lineas.push(
      `Pausa ${horaMinArt(p.inicioMs)}–${horaMinArt(p.finMs)} ` +
      `(${hhmm(p.durSeg)}) — ${descOrigen(p.origen)}${dudosa}`
    );
  }
  lineas.push(
    `Manejo neto: ${hhmm(r.manejoNetoSeg)} en ${r.bloques.length} bloque(s)`
  );
  if (r.bloquesExcedidos > 0) {
    lineas.push(
      `⚠ ${r.bloquesExcedidos} bloque(s) superaron 4 h de manejo continuo`
    );
  }
  if (r.jornadaExcedida) {
    lineas.push(
      `⚠ Jornada: ${hhmm(r.manejoNetoSeg)} de manejo neto — supera el ` +
      "tope de 12 h"
    );
  }
  if (r.descansoInsuficiente && r.descansoPrevioSeg != null) {
    lineas.push(
      `⚠ Descanso previo ${hhmm(r.descansoPrevioSeg)} — menor a las 8 h ` +
      "mínimas entre jornadas"
    );
  }
  if (r.vedaExcedida) {
    lineas.push(
      `⚠ Manejó ${hhmm(r.manejoNocturnoSeg)} en veda nocturna (00:00–06:00 ART)`
    );
  }
  if (r.driftFiltrado) {
    lineas.push(
      "⚠ Se descartaron eventos de otra patente (posible chofer distinto) — " +
      "revisar a qué unidad corresponde la jornada"
    );
  }
  if (r.confianza !== "alta") {
    lineas.push(
      `⚠ Confianza ${r.confianza}: hay tramos sin reporte confiable — ` +
      "revisar antes de usar para liquidación/disputa"
    );
  }
  return lineas;
}

function jornadaVacia(): RegistroJornada {
  return {
    inicioTurnoMs: null,
    finTurnoMs: null,
    manejoNetoSeg: 0,
    pausaTotalSeg: 0,
    recorridoKm: 0,
    segmentos: [],
    pausas: [],
    bloques: [],
    bloquesExcedidos: 0,
    descansoPrevioSeg: null,
    descansoInsuficiente: false,
    driftFiltrado: false,
    jornadaExcedida: false,
    manejoNocturnoSeg: 0,
    vedaExcedida: false,
    confianza: "alta",
    explicacion: [],
  };
}

// ─── API pública ─────────────────────────────────────────────────────────────

/**
 * Utilidad: parte una secuencia de eventos en chunks por GAP ≥ 8 h entre eventos
 * consecutivos (equipo apagado por completo). `reconstruirJornadas` YA NO la usa
 * (el corte de turno se hace a nivel de segmento, que cubre gap + pausa en el
 * lugar de forma unificada); se mantiene exportada como utilidad/diagnóstico.
 * NO corta por medianoche. Asume eventos ordenables por `ms`.
 */
export function partirEnTurnos(
  eventos: EventoJornadaLite[]
): EventoJornadaLite[][] {
  const evs = [...eventos].sort((a, b) => a.ms - b.ms);
  if (evs.length === 0) return [];
  const turnos: EventoJornadaLite[][] = [];
  let actual: EventoJornadaLite[] = [evs[0]];
  for (let i = 1; i < evs.length; i++) {
    const gapSeg = (evs[i].ms - evs[i - 1].ms) / 1000;
    if (gapSeg >= DESCANSO_MIN_SEGUNDOS) {
      turnos.push(actual);
      actual = [];
    }
    actual.push(evs[i]);
  }
  if (actual.length) turnos.push(actual);
  return turnos;
}

/**
 * Reconstruye TODAS las jornadas presentes en los eventos. Corte UNIFICADO a
 * nivel de segmento: arma la línea de tiempo y la parte en cada DESCANSO ≥ 7 h
 * (`partirSegmentosEnTurnos`), que cubre por igual el descanso con equipo
 * apagado (gap, forzado a pausa en `construirSegmentos`) y el descanso en el
 * lugar con heartbeats (pausa mergeada). Devuelve solo jornadas con manejo real.
 */
export function reconstruirJornadas(
  eventos: EventoJornadaLite[]
): RegistroJornada[] {
  // Filtrar drift CHOFER_DISTINTO ANTES de armar la línea de tiempo (si no, la
  // mezcla de 2 patentes da segmentos basura).
  const { eventos: limpios, driftFiltrado } = filtrarDriftPatente(eventos);
  const { segmentos, intervalos } = construirSegmentos(limpios);
  if (segmentos.length === 0) return [];
  const out: RegistroJornada[] = [];
  for (const g of partirSegmentosEnTurnos(segmentos)) {
    const r = registroDeSegmentos(
      g.segmentos, intervalos, limpios, g.descansoPrevioSeg, driftFiltrado
    );
    if (r.inicioTurnoMs != null) out.push(r);
  }
  return out;
}

/**
 * Reconstruye la PRIMERA jornada de los eventos. Devuelve una jornada vacía si
 * no hubo manejo. (Para todas las jornadas del rango, usar `reconstruirJornadas`.)
 */
export function reconstruirJornada(
  eventos: EventoJornadaLite[]
): RegistroJornada {
  return reconstruirJornadas(eventos)[0] ?? jornadaVacia();
}
