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
  segmentos: SegmentoJornada[];
  pausas: PausaJornada[];
  bloques: BloqueJornada[];
  /** cantidad de bloques que superaron 4 h de manejo continuo. */
  bloquesExcedidos: number;
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
function reconstruirUnTurno(eventos: EventoJornadaLite[]): RegistroJornada {
  const evs = [...eventos].sort((a, b) => a.ms - b.ms);
  if (evs.length === 0) return jornadaVacia();
  if (evs.length === 1) {
    // Un solo evento: no hay intervalos que medir.
    return jornadaVacia();
  }

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

    if (tipo === "manejo" && dur >= GAP_GRANDE_SEGUNDOS) {
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

  // Merge de intervalos consecutivos del mismo tipo → segmentos.
  const segmentos = fusionarSegmentos(intervalos);

  // Turno = desde el primer segmento de MANEJO (primer movimiento del día).
  const idxPrimerManejo = segmentos.findIndex((s) => s.tipo === "manejo");
  if (idxPrimerManejo === -1) {
    // Nunca manejó (todo pausa): no hay jornada de manejo que registrar.
    return jornadaVacia();
  }
  const segTurno = segmentos.slice(idxPrimerManejo);
  const inicioTurnoMs = segTurno[0].inicioMs;
  const finTurnoMs = segTurno[segTurno.length - 1].finMs;

  const manejoNetoSeg = sumDur(segTurno, "manejo");
  const pausaTotalSeg = sumDur(segTurno, "pausa");

  const pausas = construirPausas(segTurno);
  const bloques = partirEnBloques(segTurno);
  const bloquesExcedidos = bloques.filter((b) => b.excedido).length;
  const confianza = confianzaGlobal(
    intervalos, evs, inicioTurnoMs, finTurnoMs
  );
  const explicacion = construirExplicacion({
    inicioTurnoMs, finTurnoMs, manejoNetoSeg, pausas, bloques,
    bloquesExcedidos, confianza,
  });

  return {
    inicioTurnoMs, finTurnoMs, manejoNetoSeg, pausaTotalSeg,
    segmentos: segTurno, pausas, bloques, bloquesExcedidos, confianza,
    explicacion,
  };
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
 * Confianza global del registro. Mide la fracción del turno cubierta por TIEMPO
 * DE GAP DUDOSO (no por segmentos enteros: un gap de 51 min adentro de un tramo
 * de 3 h de manejo ensucia solo esos 51 min, no las 3 h). Un solo Bloqueo GPS
 * en el turno ya la baja a "baja" (señal explícita de cobertura perdida).
 */
function confianzaGlobal(
  intervalos: IntervaloCrudo[], evs: EventoJornadaLite[],
  inicioMs: number, finMs: number
): Confianza {
  const hayBloqueoGps = evs.some(
    (e) => e.eventId === EV.BLOQUEO_GPS && e.ms >= inicioMs && e.ms <= finMs
  );
  const turnoSeg = Math.max(1, (finMs - inicioMs) / 1000);
  const bajaSeg = intervalos
    .filter((iv) => iv.confianza === "baja" &&
      iv.inicioMs >= inicioMs && iv.finMs <= finMs)
    .reduce((acc, iv) => acc + (iv.finMs - iv.inicioMs) / 1000, 0);
  const frac = bajaSeg / turnoSeg;
  if (hayBloqueoGps || frac > 0.5) return "baja";
  if (bajaSeg > 0) return "media";
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
  confianza: Confianza;
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
    segmentos: [],
    pausas: [],
    bloques: [],
    bloquesExcedidos: 0,
    confianza: "alta",
    explicacion: [],
  };
}

// ─── API pública ─────────────────────────────────────────────────────────────

/**
 * Parte una secuencia de eventos en turnos: un gap ≥ 8 h entre eventos
 * consecutivos es un descanso de jornada (corte de turno). Robusto para
 * multi-día / turnos que cruzan medianoche (NO se corta por medianoche — solo
 * por descanso real). Asume eventos ordenables por `ms`.
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
 * Reconstruye TODAS las jornadas presentes en los eventos (parte por descanso
 * de 8 h y reconstruye cada turno). Devuelve solo las que tienen manejo real.
 */
export function reconstruirJornadas(
  eventos: EventoJornadaLite[]
): RegistroJornada[] {
  return partirEnTurnos(eventos)
    .map(reconstruirUnTurno)
    .filter((r) => r.inicioTurnoMs != null);
}

/**
 * Reconstruye la PRIMERA jornada de los eventos (el caso típico: el caller pasa
 * los eventos de un turno). Si hay un descanso de 8 h adentro, corta el turno
 * ahí (el resto es otra jornada — usar `reconstruirJornadas`). Devuelve una
 * jornada vacía si no hubo manejo.
 */
export function reconstruirJornada(
  eventos: EventoJornadaLite[]
): RegistroJornada {
  const turnos = partirEnTurnos(eventos);
  for (const t of turnos) {
    const r = reconstruirUnTurno(t);
    if (r.inicioTurnoMs != null) return r;
  }
  return jornadaVacia();
}
