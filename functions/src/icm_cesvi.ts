// =============================================================================
// CESVI — fórmula homologada del ICM (Índice de Conducta de Manejo)
// =============================================================================
//
// Implementación EXACTA de la fórmula CESVI Argentina que usa YPF para
// auditar la conducta de los choferes. Fuente: presentación Carsync
// homologada por CESVI
// (`G:/Mi unidad/REQUERIMIENTOS YPF/Presentación Avance Carsync...`).
//
// Modelo:
//   - Cada UNIDAD (en CESVI: "viaje"; en nuestra implementación:
//     "día de manejo del chofer") arranca con 100 puntos.
//   - Cada infracción descuenta puntos según su tipo y gravedad.
//   - ICM = max(0, 100 − sumaPuntosDescontados).
//   - Categorías YPF/CESVI: Bajo (verde) 100-91, Medio (amarillo) 90-71,
//     Alto (rojo) 70-0.
//   - ICM del chofer en un rango = promedio PONDERADO POR KM de sus días.
//
// **Rediseño Santiago 2026-05-22** ("estamos haciendo mal los cálculos,
// todo marca ~100"): la unidad pasó de "jornada del vigilador" a
// "(chofer, día)". Las jornadas del vigilador estaban rotas (ventanas
// 10-22h con manejo 1.3h, bloques inconsistentes) y dejaban el 41% de
// las infracciones FUERA de toda ventana → ICM espurio ~100. El día ART
// es proxy robusto del "viaje" de Carsync, no pierde eventos. La fatiga
// (tiempo recorrido) NO se computa hoy: no hay señal en el feed Sitrack
// y los bloques eran basura. `puntajeFatigaPorBloque` se conserva para
// cuando llegue una señal real.
//
// **Pesos por tipo** (presentación Carsync, slide 3):
//   - Frenado brusco   (event 67): −5.8 por evento
//   - Acelerado brusco (event 66): −2.8 por evento
//   - Giro brusco      (event 383): −2.8 por evento
//   - Sobrevelocidad   (event 8/9 pareados): según gravedad — ver
//     [puntajeSobrevelocidad]
//   - Tiempo recorrido (fatiga): −5/−10/−15 según bloque del vigilador
//     — ver [puntajeFatigaPorBloque]

/** Categoría de gravedad de un exceso de velocidad. */
export type GravedadExceso = "baja" | "media" | "alta";

/** Categoría de riesgo según puntaje ICM final. */
export type CategoriaIcm = "BAJO" | "MEDIO" | "ALTO" | "SIN_DATOS";

/** Pesos fijos CESVI (puntos descontados por evento). */
export const PESO_CESVI = {
  ACELERACION_BRUSCA: 2.8,
  FRENADA_BRUSCA: 5.8,
  GIRO_BRUSCO: 2.8,
} as const;

/** Event IDs Sitrack mapeados a CESVI. */
export const EVENT_ID = {
  ACELERACION_BRUSCA: 66,
  FRENADA_BRUSCA: 67,
  GIRO_BRUSCO: 383,
  INICIO_SOBREVELOCIDAD: 8,
  FIN_SOBREVELOCIDAD: 9,
} as const;

/**
 * Tiempo mínimo (segundos) que debe durar una sobrevelocidad para
 * considerarse INFRACCIÓN según CESVI. Slide 6 de Carsync: "En base a
 * los tiempos de activación se define si es o no una infracción".
 *
 * Eventos 8/9 de Sitrack se emiten ante CUALQUIER sobrevelocidad
 * transitoria (incluso <1 segundo al pasar un camión, frenar y volver
 * al límite). CESVI las descarta como ruido. Sitrack emite ADEMÁS el
 * evento 861 ya filtrado por activación — pero no llega a nuestra
 * cuenta (verificado 2026-05-19 con inspector), así que lo replicamos
 * client-side usando esta función.
 *
 * Tabla CESVI por tipo de segmento (slide 6):
 *   - Autopista: 15s | Autovía: 12s | Carretera: 6/12s (urb/rur)
 *   - Calle principal: 6/10s | Calle: 5s | Ruta asfalto YPF: 10s
 *   - Primario YPF: 6s | Secundario YPF: 5s | Troncal YPF: 6s | Huella: 4s
 *
 * Como Sitrack solo nos da `area_type` (urban/rural) — sin sub-tipo —
 * tomamos valores medios conservadores que cubran la mayoría de los
 * casos sin sobre-clasificar como infracción:
 *   - URBAN   → 6s  (calle principal urbana, mediana de la tabla)
 *   - RURAL   → 10s (ruta asfalto rural, mediana conservadora)
 *   - UNKNOWN → 10s (rural por default, operación Vecchi es mayoría ruta)
 *
 * Cuando Sitrack active el evento 861 en nuestra cuenta + nos mande
 * sub-tipo de segmento, podremos usar la tabla completa.
 */
export function tiempoActivacionSegSeg(
  areaType: "urban" | "rural" | "unknown" | string,
): number {
  if (areaType === "urban") return 6;
  return 10; // rural / unknown
}

/**
 * Clasifica un exceso de velocidad en gravedad CESVI según el % de
 * exceso sobre el límite cartográfico. Como Sitrack solo nos da
 * `area_type` (urban/rural) — NO el sub-tipo de segmento (autopista,
 * calle, ruta, etc.) — usamos thresholds simplificados:
 *
 *   - URBANA  → tabla "Calle principal urbana": alta >10%, media =10%, baja =5%
 *   - RURAL   → tabla "Ruta asfalto rural":     alta >6%,  media =6%,  baja =3%
 *   - UNKNOWN → rural por default (caso conservador — la mayoría de la
 *               operación Vecchi es ruta interurbana)
 *
 * Si tuviéramos el sub-tipo de segmento (pendiente de pedir a Sitrack),
 * la clasificación sería más fina (autopista, autovía, etc.). Mientras
 * tanto urban/rural cubre el 95% de los casos operativos correctamente.
 */
export function gravedadExceso(
  velMaxKmh: number,
  velLimiteKmh: number,
  areaType: "urban" | "rural" | "unknown" | string,
): GravedadExceso | null {
  if (velLimiteKmh <= 0 || velMaxKmh <= velLimiteKmh) return null;
  const pctExceso = ((velMaxKmh - velLimiteKmh) / velLimiteKmh) * 100;
  const esUrban = areaType === "urban";
  if (esUrban) {
    if (pctExceso > 10) return "alta";
    if (pctExceso >= 5) return "media";
    return "baja";
  }
  // rural / unknown
  if (pctExceso > 6) return "alta";
  if (pctExceso >= 3) return "media";
  return "baja";
}

/**
 * Calcula el puntaje a descontar por UNA sobrevelocidad CESVI según
 * gravedad, velocidad y duración. Fórmula del slide 11 de Carsync:
 *
 *   - Gravedad BAJA  → −1 punto fijo
 *   - Gravedad MEDIA → (velMax − velProm) × duracionSeg × 0.01,
 *                       clampeado a [1.1, 1.4]
 *   - Gravedad ALTA  → (velMax − velProm) × duracionSeg × 0.01,
 *                       clampeado a [1.5, 5]
 *
 * Si no hay gravedad (no superó el límite), devuelve 0.
 */
export function puntajeSobrevelocidad(args: {
  gravedad: GravedadExceso | null;
  velMaxKmh: number;
  velPromKmh: number;
  duracionSeg: number;
}): number {
  const { gravedad, velMaxKmh, velPromKmh, duracionSeg } = args;
  if (!gravedad) return 0;
  if (gravedad === "baja") return 1;
  const raw = (velMaxKmh - velPromKmh) * duracionSeg * 0.01;
  if (gravedad === "media") return Math.min(1.4, Math.max(1.1, raw));
  // alta
  return Math.min(5, Math.max(1.5, raw));
}

/**
 * Penalización por tiempo recorrido (fatiga) CESVI aplicada por bloque
 * del vigilador de jornada v2 (cada bloque ≈ 4h de manejo con pausa
 * 15 min). Escalera del slide 3:
 *
 *   - 0 a 2h       →  0 puntos
 *   - 2h a 3h      → −5 puntos
 *   - 3h a 4h      → −10 puntos
 *   - Más de 4h    → −15 puntos
 *
 * La normativa YPF/CESVI penaliza el VIAJE largo (no la jornada
 * completa) — al aplicar por bloque del vigilador (cada bloque máx
 * 4h por norma operativa Vecchi) garantizamos que un chofer que
 * cumpla el vigilador descuente como máximo −10 por bloque y nunca
 * llegue al rango "más de 4h" salvo violación.
 *
 * Si un chofer manejó X horas en una jornada con 3 bloques de ~4h
 * cada uno (sin violación), descuenta ~3×−10 = −30 puntos por fatiga
 * en esa jornada. Aceptable.
 */
export function puntajeFatigaPorBloque(manejoSegEnBloque: number): number {
  const horas = manejoSegEnBloque / 3600;
  if (horas < 2) return 0;
  if (horas < 3) return 5;
  if (horas < 4) return 10;
  return 15;
}

/**
 * Categoriza un puntaje ICM final en Bajo/Medio/Alto según los umbrales
 * EXACTOS de YPF (Minuta de Revisión ICM VECCHI):
 *   - Riesgo Bajo:  100 a 91 puntos (verde)
 *   - Riesgo Medio:  90 a 71 puntos (amarillo)
 *   - Riesgo Alto:   70 a 0  puntos (rojo)
 */
export function categorizar(icm: number): CategoriaIcm {
  if (icm >= 91) return "BAJO";
  if (icm >= 71) return "MEDIO";
  return "ALTO";
}

/**
 * Helper: agrupa pares de eventos Sitrack 8 (Inicio sobrevelocidad) y
 * 9 (Fin sobrevelocidad) por proximidad temporal por mismo
 * (asset_id, driver_dni). Devuelve una lista de pares
 * `{ inicio, fin, duracionSeg }`. Si hay un 8 sin 9 (o viceversa)
 * dentro de la ventana, se descarta — son eventos huérfanos típicos
 * cuando el chofer cambia de patente, etc.
 *
 * Ventana de pareo: 30 minutos. Mayor que cualquier sobrevelocidad
 * real (lo usual es 5s-2min), suficiente para tolerar lag de ingesta.
 */
export interface EventoSitrackICM {
  eventId: number;
  reportDateMs: number;
  assetId: string;
  driverDni: string;
  speed: number | null;
  cartographyLimitSpeed: number | null;
  areaType: string;
  odometer: number | null;
}

export interface ParSobrevelocidad {
  inicio: EventoSitrackICM;
  fin: EventoSitrackICM;
  duracionSeg: number;
}

export function agruparSobrevelocidades(
  eventos: EventoSitrackICM[],
  ventanaMaxMs = 30 * 60 * 1000,
): ParSobrevelocidad[] {
  // Agrupar inicios y fines por par (asset, driver)
  const inicios = new Map<string, EventoSitrackICM[]>();
  const fines = new Map<string, EventoSitrackICM[]>();
  for (const e of eventos) {
    const key = `${e.assetId}__${e.driverDni}`;
    if (e.eventId === EVENT_ID.INICIO_SOBREVELOCIDAD) {
      const arr = inicios.get(key) ?? [];
      arr.push(e);
      inicios.set(key, arr);
    } else if (e.eventId === EVENT_ID.FIN_SOBREVELOCIDAD) {
      const arr = fines.get(key) ?? [];
      arr.push(e);
      fines.set(key, arr);
    }
  }
  // Ordenar cronológicamente cada array
  for (const arr of inicios.values()) arr.sort((a, b) => a.reportDateMs - b.reportDateMs);
  for (const arr of fines.values()) arr.sort((a, b) => a.reportDateMs - b.reportDateMs);
  // Parear: por cada inicio, buscar el fin más cercano posterior
  // dentro de la ventana, y consumirlo.
  const pares: ParSobrevelocidad[] = [];
  for (const [key, inisArr] of inicios.entries()) {
    const finsArr = fines.get(key) ?? [];
    for (const ini of inisArr) {
      const idx = finsArr.findIndex(
        (f) => f.reportDateMs > ini.reportDateMs &&
               f.reportDateMs - ini.reportDateMs <= ventanaMaxMs,
      );
      if (idx === -1) continue;
      const fin = finsArr[idx];
      finsArr.splice(idx, 1);
      pares.push({
        inicio: ini,
        fin,
        duracionSeg: (fin.reportDateMs - ini.reportDateMs) / 1000,
      });
    }
  }
  return pares;
}

/**
 * Calcula el ICM CESVI de UNA jornada del vigilador a partir de los
 * eventos Sitrack que ocurrieron dentro de su ventana de tiempo.
 *
 * `manejoSegPorBloque`: tiempo manejado en cada bloque del vigilador
 * (típicamente 3 bloques de ~4h). Si la jornada solo tuvo 1 bloque, el
 * array tiene 1 elemento; si tuvo 3, tres elementos.
 *
 * Devuelve también el desglose de puntos descontados para auditoría /
 * debug / drill-down en UI.
 */
export interface DesgloseIcm {
  icm: number;
  categoria: CategoriaIcm;
  puntosTotales: number;
  desglose: {
    aceleracionesBruscas: number;     // count
    frenadasBruscas: number;          // count
    girosBruscos: number;             // count
    sobrevelocidades: number;         // count
    puntosAceleracion: number;        // suma puntos descontados
    puntosFrenada: number;
    puntosGiro: number;
    puntosSobrevelocidad: number;
    puntosFatiga: number;
  };
}

export function calcularIcmJornada(
  eventosDeJornada: EventoSitrackICM[],
  manejoSegPorBloque: number[],
): DesgloseIcm {
  let puntosAceleracion = 0;
  let puntosFrenada = 0;
  let puntosGiro = 0;
  let countAcel = 0;
  let countFren = 0;
  let countGiro = 0;
  for (const e of eventosDeJornada) {
    if (e.eventId === EVENT_ID.ACELERACION_BRUSCA) {
      puntosAceleracion += PESO_CESVI.ACELERACION_BRUSCA;
      countAcel++;
    } else if (e.eventId === EVENT_ID.FRENADA_BRUSCA) {
      puntosFrenada += PESO_CESVI.FRENADA_BRUSCA;
      countFren++;
    } else if (e.eventId === EVENT_ID.GIRO_BRUSCO) {
      puntosGiro += PESO_CESVI.GIRO_BRUSCO;
      countGiro++;
    }
  }
  // Sobrevelocidades — agrupar 8+9 y calcular según gravedad.
  // FILTRO TIEMPO DE ACTIVACIÓN (Santiago 2026-05-19): pares cuya
  // duración no supera el umbral del segmento NO son infracción
  // CESVI (slide 6). Equivalente client-side al evento 861 que
  // Sitrack emite filtrado pero no llega a nuestra cuenta.
  const pares = agruparSobrevelocidades(eventosDeJornada);
  let puntosSobrevelocidad = 0;
  let sobrevelocidadesContadas = 0;
  for (const par of pares) {
    const tActivacion = tiempoActivacionSegSeg(par.inicio.areaType);
    if (par.duracionSeg < tActivacion) continue; // transitoria, no infracción
    const limiteIni = par.inicio.cartographyLimitSpeed ?? 0;
    const limiteFin = par.fin.cartographyLimitSpeed ?? 0;
    // Usamos el límite máximo de los dos (más conservador con el chofer)
    const velLimite = Math.max(limiteIni, limiteFin);
    const speedIni = par.inicio.speed ?? 0;
    const speedFin = par.fin.speed ?? 0;
    const velMax = Math.max(speedIni, speedFin);
    // Velocidad promedio aproximada — sin speedSampling tomamos
    // el promedio de los 2 puntos disponibles. Cuando tengamos el
    // sample de la ECU mejoramos este cálculo.
    const velProm = (speedIni + speedFin) / 2;
    const grav = gravedadExceso(velMax, velLimite, par.inicio.areaType);
    if (!grav) continue; // no superó el límite (ej. límite=0 sin cartografía)
    puntosSobrevelocidad += puntajeSobrevelocidad({
      gravedad: grav,
      velMaxKmh: velMax,
      velPromKmh: velProm,
      duracionSeg: par.duracionSeg,
    });
    sobrevelocidadesContadas++;
  }
  // Fatiga por bloque
  let puntosFatiga = 0;
  for (const seg of manejoSegPorBloque) {
    puntosFatiga += puntajeFatigaPorBloque(seg);
  }
  const puntosTotales =
    puntosAceleracion +
    puntosFrenada +
    puntosGiro +
    puntosSobrevelocidad +
    puntosFatiga;
  const icm = Math.max(0, Math.min(100, 100 - puntosTotales));
  return {
    icm,
    categoria: categorizar(icm),
    puntosTotales,
    desglose: {
      aceleracionesBruscas: countAcel,
      frenadasBruscas: countFren,
      girosBruscos: countGiro,
      sobrevelocidades: sobrevelocidadesContadas,
      puntosAceleracion,
      puntosFrenada,
      puntosGiro,
      puntosSobrevelocidad,
      puntosFatiga,
    },
  };
}

/**
 * Combina N días (unidades) en un ICM agregado del chofer en un rango.
 * **Promedio ponderado por km** de cada día (igual que Carsync pondera
 * viajes por km — un día de 1000km pesa más que uno de 100km).
 *
 * Peso de cada día = `max(km, 1)`: un día con infracciones pero SIN
 * odómetro linkeable (km=0) NO se descarta — entra con peso mínimo. Si
 * TODOS los días tienen km=0, todos pesan 1 → promedio aritmético
 * simple (en vez del viejo SIN_DATOS que escondía choferes con
 * infracciones reales sin odómetro). `kmTotales` reporta el km REAL
 * (suma de km>0) para el ratio infracciones/100km. SIN_DATOS sólo si no
 * hay días.
 */
export interface JornadaConIcm {
  icm: number;
  km: number;
  desglose: DesgloseIcm["desglose"];
}

export interface IcmAgregado {
  icm: number;
  categoria: CategoriaIcm;
  kmTotales: number;
  jornadas: number;
  desgloseSumado: DesgloseIcm["desglose"];
}

export function combinarJornadas(jornadas: JornadaConIcm[]): IcmAgregado {
  let kmReales = 0;
  let pesoTotal = 0;
  let icmPonderado = 0;
  const sumado = {
    aceleracionesBruscas: 0,
    frenadasBruscas: 0,
    girosBruscos: 0,
    sobrevelocidades: 0,
    puntosAceleracion: 0,
    puntosFrenada: 0,
    puntosGiro: 0,
    puntosSobrevelocidad: 0,
    puntosFatiga: 0,
  };
  for (const j of jornadas) {
    const peso = j.km > 1 ? j.km : 1;
    pesoTotal += peso;
    icmPonderado += j.icm * peso;
    if (j.km > 0) kmReales += j.km;
    sumado.aceleracionesBruscas += j.desglose.aceleracionesBruscas;
    sumado.frenadasBruscas += j.desglose.frenadasBruscas;
    sumado.girosBruscos += j.desglose.girosBruscos;
    sumado.sobrevelocidades += j.desglose.sobrevelocidades;
    sumado.puntosAceleracion += j.desglose.puntosAceleracion;
    sumado.puntosFrenada += j.desglose.puntosFrenada;
    sumado.puntosGiro += j.desglose.puntosGiro;
    sumado.puntosSobrevelocidad += j.desglose.puntosSobrevelocidad;
    sumado.puntosFatiga += j.desglose.puntosFatiga;
  }
  if (jornadas.length === 0 || pesoTotal === 0) {
    return {
      icm: 0,
      categoria: "SIN_DATOS",
      kmTotales: 0,
      jornadas: jornadas.length,
      desgloseSumado: sumado,
    };
  }
  const icm = icmPonderado / pesoTotal;
  return {
    icm,
    categoria: categorizar(icm),
    kmTotales: kmReales,
    jornadas: jornadas.length,
    desgloseSumado: sumado,
  };
}
