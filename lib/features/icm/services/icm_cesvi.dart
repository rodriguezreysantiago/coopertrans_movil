// =============================================================================
// CESVI — fórmula homologada del ICM (Índice de Conducta de Manejo)
// =============================================================================
//
// Espejo Dart de `functions/src/icm_cesvi.ts`. Misma lógica, mismos
// pesos. Si tocás uno, tocá el otro. Tests duplicados en ambos lados
// para garantizar paridad.
//
// Modelo:
//   - Cada UNIDAD (en CESVI: "viaje"; en Vecchi: "día de manejo del
//     chofer") arranca con 100 puntos.
//   - Cada infracción descuenta puntos según tipo y gravedad.
//   - ICM = max(0, 100 − sumaPuntosDescontados).
//   - Categorías YPF/CESVI: Bajo (verde) 100-91, Medio (amarillo) 90-71,
//     Alto (rojo) 70-0.
//   - ICM del chofer en rango = promedio PONDERADO POR KM de sus días.
//
// **Rediseño 2026-05-22 (Santiago, "estamos haciendo mal los cálculos"):**
// la unidad pasó de "jornada del vigilador" a "(chofer, día)" porque las
// jornadas del vigilador estaban rotas (ventanas de 10-22h con manejo
// de 1.3h, bloques inconsistentes) y dejaban el 41% de las infracciones
// FUERA de toda ventana → ICM espurio ~100. El día ART es un proxy
// robusto del "viaje" de Carsync, no pierde eventos y no depende del
// vigilador. La fatiga (tiempo recorrido) NO se computa hoy: no hay
// señal directa en el feed Sitrack y los bloques del vigilador eran
// basura. `puntajeFatigaPorBloque` se conserva para cuando llegue una
// señal real. Ver header TS para detalles.

/// Categoría de gravedad de un exceso de velocidad CESVI.
enum GravedadExceso { baja, media, alta }

/// Categoría de riesgo según puntaje ICM final.
enum CategoriaCesvi { bajo, medio, alto, sinDatos }

/// Pesos fijos CESVI (puntos descontados por evento).
class PesoCesvi {
  PesoCesvi._();
  static const double aceleracionBrusca = 2.8;
  static const double frenadaBrusca = 5.8;
  static const double giroBrusco = 2.8;
}

/// Event IDs Sitrack mapeados a CESVI.
class EventIdCesvi {
  EventIdCesvi._();
  static const int aceleracionBrusca = 66;
  static const int frenadaBrusca = 67;
  static const int giroBrusco = 383;
  static const int inicioSobrevelocidad = 8;
  static const int finSobrevelocidad = 9;
}

/// Tiempo mínimo (segundos) que debe durar una sobrevelocidad para
/// considerarse INFRACCIÓN según CESVI. Slide 6 de Carsync: "En base
/// a los tiempos de activación se define si es o no una infracción".
///
/// Eventos 8/9 de Sitrack se emiten ante CUALQUIER sobrevelocidad
/// transitoria (incluso <1 segundo). CESVI las descarta como ruido y
/// solo cuenta las que superan el umbral del segmento. Sitrack emite
/// además el evento 861 ya filtrado, pero no llega a nuestra cuenta
/// — replicamos client-side con esta función.
///
/// Como solo tenemos `area_type` (urban/rural) usamos valores medios
/// conservadores:
///   - URBAN   → 6s  (calle principal urbana, mediana de la tabla)
///   - RURAL   → 10s (ruta asfalto rural, mediana conservadora)
///   - UNKNOWN → 10s (rural por default)
double tiempoActivacionSeg(String areaType) {
  if (areaType == 'urban') return 6;
  return 10;
}

/// Clasifica un exceso de velocidad en gravedad CESVI según el % de
/// exceso sobre el límite cartográfico. Sitrack solo nos da `area_type`
/// (urban/rural) — sin sub-tipo de segmento — así que usamos thresholds
/// simplificados:
///
///   - URBANA  → tabla "Calle principal urbana": alta >10%, media =10%, baja =5%
///   - RURAL   → tabla "Ruta asfalto rural":     alta >6%,  media =6%,  baja =3%
///   - UNKNOWN → rural por default (operación Vecchi es mayoría ruta).
///
/// Devuelve null si no superó el límite.
GravedadExceso? gravedadExceso({
  required double velMaxKmh,
  required double velLimiteKmh,
  required String areaType,
}) {
  if (velLimiteKmh <= 0 || velMaxKmh <= velLimiteKmh) return null;
  final pctExceso = ((velMaxKmh - velLimiteKmh) / velLimiteKmh) * 100;
  final esUrban = areaType == 'urban';
  if (esUrban) {
    if (pctExceso > 10) return GravedadExceso.alta;
    if (pctExceso >= 5) return GravedadExceso.media;
    return GravedadExceso.baja;
  }
  if (pctExceso > 6) return GravedadExceso.alta;
  if (pctExceso >= 3) return GravedadExceso.media;
  return GravedadExceso.baja;
}

/// Puntaje a descontar por UNA sobrevelocidad CESVI según gravedad,
/// velocidad y duración. Fórmula slide 11 de Carsync.
double puntajeSobrevelocidad({
  required GravedadExceso? gravedad,
  required double velMaxKmh,
  required double velPromKmh,
  required double duracionSeg,
}) {
  if (gravedad == null) return 0;
  if (gravedad == GravedadExceso.baja) return 1;
  final raw = (velMaxKmh - velPromKmh) * duracionSeg * 0.01;
  if (gravedad == GravedadExceso.media) {
    return raw.clamp(1.1, 1.4).toDouble();
  }
  return raw.clamp(1.5, 5.0).toDouble();
}

/// Penalización por tiempo recorrido (fatiga) CESVI aplicada por bloque
/// del vigilador de jornada v2. Escalera del slide 3:
///   - 0 a 2h    → 0
///   - 2h a 3h   → 5
///   - 3h a 4h   → 10
///   - >4h       → 15
double puntajeFatigaPorBloque(double manejoSegEnBloque) {
  final horas = manejoSegEnBloque / 3600;
  if (horas < 2) return 0;
  if (horas < 3) return 5;
  if (horas < 4) return 10;
  return 15;
}

/// Categoriza un puntaje ICM final en Bajo/Medio/Alto según los umbrales
/// EXACTOS de YPF (Minuta de Revisión ICM VECCHI):
///   - Riesgo Bajo:  100 a 91 puntos (verde)
///   - Riesgo Medio:  90 a 71 puntos (amarillo)
///   - Riesgo Alto:   70 a 0  puntos (rojo)
CategoriaCesvi categorizarCesvi(double icm) {
  if (icm >= 91) return CategoriaCesvi.bajo;
  if (icm >= 71) return CategoriaCesvi.medio;
  return CategoriaCesvi.alto;
}

/// Evento Sitrack relevante al cálculo ICM.
class EventoSitrackICM {
  final int eventId;
  final int reportDateMs;
  final String assetId;
  final String driverDni;
  final double? speed;
  final double? cartographyLimitSpeed;
  final String areaType;
  final double? odometer;
  const EventoSitrackICM({
    required this.eventId,
    required this.reportDateMs,
    required this.assetId,
    required this.driverDni,
    this.speed,
    this.cartographyLimitSpeed,
    required this.areaType,
    this.odometer,
  });
}

/// Par sobrevelocidad inicio+fin con duración calculada.
class ParSobrevelocidad {
  final EventoSitrackICM inicio;
  final EventoSitrackICM fin;
  final double duracionSeg;
  const ParSobrevelocidad({
    required this.inicio,
    required this.fin,
    required this.duracionSeg,
  });
}

/// Parea eventos Sitrack 8 (Inicio sobrevelocidad) + 9 (Fin) por
/// proximidad temporal por mismo (asset_id, driver_dni). Eventos
/// huérfanos (8 sin 9 o viceversa) se descartan.
/// Ventana max default: 30 minutos.
List<ParSobrevelocidad> agruparSobrevelocidades(
  List<EventoSitrackICM> eventos, {
  int ventanaMaxMs = 30 * 60 * 1000,
}) {
  final inicios = <String, List<EventoSitrackICM>>{};
  final fines = <String, List<EventoSitrackICM>>{};
  for (final e in eventos) {
    final key = '${e.assetId}__${e.driverDni}';
    if (e.eventId == EventIdCesvi.inicioSobrevelocidad) {
      inicios.putIfAbsent(key, () => []).add(e);
    } else if (e.eventId == EventIdCesvi.finSobrevelocidad) {
      fines.putIfAbsent(key, () => []).add(e);
    }
  }
  for (final arr in inicios.values) {
    arr.sort((a, b) => a.reportDateMs.compareTo(b.reportDateMs));
  }
  for (final arr in fines.values) {
    arr.sort((a, b) => a.reportDateMs.compareTo(b.reportDateMs));
  }
  final pares = <ParSobrevelocidad>[];
  for (final entry in inicios.entries) {
    final finsArr = fines[entry.key] ?? [];
    for (final ini in entry.value) {
      final idx = finsArr.indexWhere(
        (f) => f.reportDateMs > ini.reportDateMs &&
            f.reportDateMs - ini.reportDateMs <= ventanaMaxMs,
      );
      if (idx == -1) continue;
      final fin = finsArr[idx];
      finsArr.removeAt(idx);
      pares.add(ParSobrevelocidad(
        inicio: ini,
        fin: fin,
        duracionSeg: (fin.reportDateMs - ini.reportDateMs) / 1000.0,
      ));
    }
  }
  return pares;
}

/// Desglose del ICM de una jornada (para drill-down / auditoría).
class DesgloseIcm {
  final double icm;
  final CategoriaCesvi categoria;
  final double puntosTotales;
  final int aceleracionesBruscas;
  final int frenadasBruscas;
  final int girosBruscos;
  final int sobrevelocidades;
  final double puntosAceleracion;
  final double puntosFrenada;
  final double puntosGiro;
  final double puntosSobrevelocidad;
  final double puntosFatiga;

  const DesgloseIcm({
    required this.icm,
    required this.categoria,
    required this.puntosTotales,
    required this.aceleracionesBruscas,
    required this.frenadasBruscas,
    required this.girosBruscos,
    required this.sobrevelocidades,
    required this.puntosAceleracion,
    required this.puntosFrenada,
    required this.puntosGiro,
    required this.puntosSobrevelocidad,
    required this.puntosFatiga,
  });
}

/// Calcula el ICM CESVI de UNA jornada dada sus eventos en ventana y
/// los segundos de manejo por bloque del vigilador.
DesgloseIcm calcularIcmJornada(
  List<EventoSitrackICM> eventosDeJornada,
  List<double> manejoSegPorBloque,
) {
  double puntosAceleracion = 0;
  double puntosFrenada = 0;
  double puntosGiro = 0;
  int countAcel = 0;
  int countFren = 0;
  int countGiro = 0;
  for (final e in eventosDeJornada) {
    if (e.eventId == EventIdCesvi.aceleracionBrusca) {
      puntosAceleracion += PesoCesvi.aceleracionBrusca;
      countAcel++;
    } else if (e.eventId == EventIdCesvi.frenadaBrusca) {
      puntosFrenada += PesoCesvi.frenadaBrusca;
      countFren++;
    } else if (e.eventId == EventIdCesvi.giroBrusco) {
      puntosGiro += PesoCesvi.giroBrusco;
      countGiro++;
    }
  }
  // Sobrevelocidades — agrupar 8+9, aplicar FILTRO DE TIEMPO DE
  // ACTIVACIÓN (slide 6 CESVI) y calcular según gravedad.
  // Pares cuya duración no supera el umbral del segmento NO son
  // infracción CESVI — equivalente client-side al evento 861 que
  // Sitrack emite pre-filtrado pero no llega a nuestra cuenta.
  final pares = agruparSobrevelocidades(eventosDeJornada);
  double puntosSobrevelocidad = 0;
  var sobrevelocidadesContadas = 0;
  for (final par in pares) {
    final tActivacion = tiempoActivacionSeg(par.inicio.areaType);
    if (par.duracionSeg < tActivacion) continue;
    final limiteIni = par.inicio.cartographyLimitSpeed ?? 0;
    final limiteFin = par.fin.cartographyLimitSpeed ?? 0;
    final velLimite =
        limiteIni > limiteFin ? limiteIni : limiteFin;
    final speedIni = par.inicio.speed ?? 0;
    final speedFin = par.fin.speed ?? 0;
    final velMax = speedIni > speedFin ? speedIni : speedFin;
    final velProm = (speedIni + speedFin) / 2;
    final grav = gravedadExceso(
      velMaxKmh: velMax,
      velLimiteKmh: velLimite,
      areaType: par.inicio.areaType,
    );
    if (grav == null) continue;
    puntosSobrevelocidad += puntajeSobrevelocidad(
      gravedad: grav,
      velMaxKmh: velMax,
      velPromKmh: velProm,
      duracionSeg: par.duracionSeg,
    );
    sobrevelocidadesContadas++;
  }
  double puntosFatiga = 0;
  for (final seg in manejoSegPorBloque) {
    puntosFatiga += puntajeFatigaPorBloque(seg);
  }
  final puntosTotales = puntosAceleracion +
      puntosFrenada +
      puntosGiro +
      puntosSobrevelocidad +
      puntosFatiga;
  final icmRaw = 100 - puntosTotales;
  final icm = icmRaw.clamp(0.0, 100.0).toDouble();
  return DesgloseIcm(
    icm: icm,
    categoria: categorizarCesvi(icm),
    puntosTotales: puntosTotales,
    aceleracionesBruscas: countAcel,
    frenadasBruscas: countFren,
    girosBruscos: countGiro,
    sobrevelocidades: sobrevelocidadesContadas,
    puntosAceleracion: puntosAceleracion,
    puntosFrenada: puntosFrenada,
    puntosGiro: puntosGiro,
    puntosSobrevelocidad: puntosSobrevelocidad,
    puntosFatiga: puntosFatiga,
  );
}

/// Una jornada ya calculada — input para combinar.
class JornadaConIcm {
  final double icm;
  final double km;
  final DesgloseIcm desglose;
  const JornadaConIcm({
    required this.icm,
    required this.km,
    required this.desglose,
  });
}

/// Resultado agregado de combinar N jornadas de un chofer.
class IcmAgregado {
  final double icm;
  final CategoriaCesvi categoria;
  final double kmTotales;
  final int jornadas;
  final int totalAceleraciones;
  final int totalFrenadas;
  final int totalGiros;
  final int totalSobrevelocidades;
  const IcmAgregado({
    required this.icm,
    required this.categoria,
    required this.kmTotales,
    required this.jornadas,
    required this.totalAceleraciones,
    required this.totalFrenadas,
    required this.totalGiros,
    required this.totalSobrevelocidades,
  });
}

/// Combina N días (o unidades) en un ICM agregado del chofer.
/// **Promedio ponderado por km** — un día largo pesa más (igual que
/// Carsync pondera viajes por km).
///
/// Peso de cada día = `max(km, 1)`: así un día con infracciones pero SIN
/// odómetro linkeable (km=0) NO se pierde — entra con peso mínimo en vez
/// de descartarse. Si TODOS los días tienen km=0, todos pesan 1 → el
/// resultado es el promedio aritmético simple (en vez del viejo
/// SIN_DATOS, que escondía choferes con infracciones reales pero sin
/// odómetro). `kmTotales` reporta el km REAL (suma de km>0) para el
/// ratio de infracciones/100km. SIN_DATOS sólo si no hay días.
IcmAgregado combinarJornadas(List<JornadaConIcm> jornadas) {
  double kmReales = 0;
  double pesoTotal = 0;
  double icmPonderado = 0;
  int totalAcel = 0;
  int totalFren = 0;
  int totalGiro = 0;
  int totalSv = 0;
  for (final j in jornadas) {
    final peso = j.km > 1.0 ? j.km : 1.0;
    pesoTotal += peso;
    icmPonderado += j.icm * peso;
    if (j.km > 0) kmReales += j.km;
    totalAcel += j.desglose.aceleracionesBruscas;
    totalFren += j.desglose.frenadasBruscas;
    totalGiro += j.desglose.girosBruscos;
    totalSv += j.desglose.sobrevelocidades;
  }
  if (jornadas.isEmpty || pesoTotal == 0) {
    return IcmAgregado(
      icm: 0,
      categoria: CategoriaCesvi.sinDatos,
      kmTotales: 0,
      jornadas: jornadas.length,
      totalAceleraciones: totalAcel,
      totalFrenadas: totalFren,
      totalGiros: totalGiro,
      totalSobrevelocidades: totalSv,
    );
  }
  final icm = icmPonderado / pesoTotal;
  return IcmAgregado(
    icm: icm,
    categoria: categorizarCesvi(icm),
    kmTotales: kmReales,
    jornadas: jornadas.length,
    totalAceleraciones: totalAcel,
    totalFrenadas: totalFren,
    totalGiros: totalGiro,
    totalSobrevelocidades: totalSv,
  );
}
