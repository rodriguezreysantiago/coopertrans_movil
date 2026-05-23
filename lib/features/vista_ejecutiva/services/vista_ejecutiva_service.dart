// Servicio que arma los KPIs del módulo Vista Ejecutiva (= panel de inicio
// del admin).
//
// Filosofía: reusar al máximo la data ya pre-calculada por crons
// (STATS/dashboard cada 5 min). Solo lo que no esté pre-agregado se queryea
// on-the-fly (con limit para mantener los reads controlados).
//
// Sin caching propio — el StreamBuilder/FutureBuilder del lado UI
// se encarga del refresh. Si en el futuro abrimos la pantalla muy
// seguido conviene memoizar el último snapshot por unos minutos.
//
// Decisión 2026-05-23 (Santiago): los KPIs/widgets de ICM (icmFlota,
// tendencia diaria, top 5 mejores, top 5 a mejorar) se mudaron al módulo
// ICM (`IcmHubService` + `IcmHubScreen`). El panel de inicio se queda con
// los KPIs operativos rápidos: viajes del mes, alertas críticas, eficiencia
// de combustible y viajes por semana. Las clases compartidas (`KpiIcm`,
// `PuntoTendencia`, `ChoferRankingItem`) siguen viviendo acá porque los
// widgets de gráfico/top que las consumen también, y los reusa el ICM Hub.

import 'package:cloud_firestore/cloud_firestore.dart';

/// Snapshot completo de KPIs para el panel de inicio del admin (antigua
/// Vista Ejecutiva). Se carga 1 vez y se renderiza en pantalla; refresh
/// manual pull-to-refresh.
class KpisVistaEjecutiva {
  final KpiMes viajesDelMes;
  final KpiSimple choferesActivos;
  final KpiSimple alertasCriticas;

  /// Eficiencia combustible últimos 30 días (L/100km promedio flota Volvo +
  /// comparativa al período previo 30d). Calculado desde
  /// `VOLVO_SCORES_DIARIOS` docs `_FLEET_*`. Métrica estándar AR/UE:
  /// más bajo = mejor.
  final KpiEficiencia eficienciaCombustible;

  /// Barras viajes últimas 8 semanas (label + valor).
  /// Orden cronológico ascendente.
  final List<PuntoTendencia> viajesPorSemana;

  const KpisVistaEjecutiva({
    required this.viajesDelMes,
    required this.choferesActivos,
    required this.alertasCriticas,
    required this.eficienciaCombustible,
    required this.viajesPorSemana,
  });
}

/// KPI con valor actual + comparativa al período anterior.
/// La tendencia se calcula como `(actual - anterior) / anterior * 100`,
/// null si `anterior == 0` (evita división por cero — sin punto de
/// comparación visualmente sale como "—").
class KpiMes {
  final int actual;
  final int anterior;
  final double? variacionPct;

  const KpiMes({
    required this.actual,
    required this.anterior,
    required this.variacionPct,
  });

  /// Helper: construye desde dos enteros calculando la variación.
  factory KpiMes.fromActualYAnterior(int actual, int anterior) {
    final pct = anterior == 0 ? null : (actual - anterior) / anterior * 100;
    return KpiMes(actual: actual, anterior: anterior, variacionPct: pct);
  }
}

/// KPI ICM con valor actual + variación semana anterior. Igual que
/// KpiMes pero con doubles.
class KpiIcm {
  final double actual;
  final double anterior;
  final double? variacionAbs; // diferencia absoluta de puntos ICM
  final int choferesEnPromedio;

  const KpiIcm({
    required this.actual,
    required this.anterior,
    required this.variacionAbs,
    required this.choferesEnPromedio,
  });

  factory KpiIcm.fromActualYAnterior(
    double actual,
    double anterior,
    int n,
  ) {
    final variacion = anterior == 0 ? null : actual - anterior;
    return KpiIcm(
      actual: actual,
      anterior: anterior,
      variacionAbs: variacion,
      choferesEnPromedio: n,
    );
  }
}

/// KPI sin comparativa (solo el número del momento).
class KpiSimple {
  final int valor;
  final String? sublabel;

  const KpiSimple({required this.valor, this.sublabel});
}

/// Eficiencia combustible (L/100km) últimos 30 días + comparativa 30 días
/// previos. Computado desde docs `_FLEET_*` de `VOLVO_SCORES_DIARIOS`.
///
/// Unidad: **L/100km** — métrica estándar Argentina/Europa.
/// Más bajo = mejor (menos litros por 100 km recorridos).
///
/// Los KPIs operativos típicos para una flota de tractores semi-remolque
/// cargados rondan 30-40 L/100km. <30 es excelente, >40 es alto.
class KpiEficiencia {
  /// L/100km promedio de los últimos 30 días. 0 si no hay datos Volvo
  /// (flota sin Volvo Connect o cron sin correr).
  final double litrosPor100kmActual;
  final double litrosPor100kmAnterior;
  /// Diferencia absoluta (L/100km). En L/100km **bajar es bueno**, así
  /// que el signo se invierte semánticamente: `variacionAbs < 0` = mejoró
  /// (consumió menos), `> 0` = empeoró (consumió más). La UI lo maneja
  /// con `mejorEsSubir: false`. `null` si no hay base de comparación.
  final double? variacionAbs;
  /// Total km del período actual (para sublabel).
  final double kmTotalesActual;
  /// Cantidad de días con datos en el período actual (para subtitle
  /// honesto: "promedio de N días" no "promedio de 30 días" cuando hay
  /// huecos en el feed Volvo).
  final int diasConDatosActual;

  const KpiEficiencia({
    required this.litrosPor100kmActual,
    required this.litrosPor100kmAnterior,
    required this.variacionAbs,
    required this.kmTotalesActual,
    required this.diasConDatosActual,
  });

  factory KpiEficiencia.fromValores({
    required double actual,
    required double anterior,
    required double kmTotales,
    required int diasConDatos,
  }) {
    final variacion = anterior == 0 ? null : actual - anterior;
    return KpiEficiencia(
      litrosPor100kmActual: actual,
      litrosPor100kmAnterior: anterior,
      variacionAbs: variacion,
      kmTotalesActual: kmTotales,
      diasConDatosActual: diasConDatos,
    );
  }

  static const KpiEficiencia vacia = KpiEficiencia(
    litrosPor100kmActual: 0,
    litrosPor100kmAnterior: 0,
    variacionAbs: null,
    kmTotalesActual: 0,
    diasConDatosActual: 0,
  );
}

/// Un punto en una serie temporal (label visible + valor numérico).
class PuntoTendencia {
  final String label;
  final double valor;
  const PuntoTendencia({required this.label, required this.valor});
}

/// Un chofer en el top 5 (con nombre + ICM + categoría).
class ChoferRankingItem {
  final String dni;
  final String nombre;
  final double icm;
  // Color sugerido en hex sin prefijo para que la UI lo mapee. Si querés
  // cambiar el threshold, ajustar en `_categorizar`.
  final String categoria; // 'verde' | 'amarillo' | 'rojo'

  const ChoferRankingItem({
    required this.dni,
    required this.nombre,
    required this.icm,
    required this.categoria,
  });
}

class VistaEjecutivaService {
  VistaEjecutivaService._();

  /// Carga todos los KPIs del tablero en un solo Future. Las queries
  /// independientes corren en paralelo con `Future.wait`. Los KPIs de ICM
  /// (icm flota, tendencia diaria, top 5) NO se cargan acá — viven en
  /// `IcmHubService.cargarKpis()` y se muestran en el módulo ICM
  /// (decisión Santiago 2026-05-23).
  static Future<KpisVistaEjecutiva> cargar({
    required FirebaseFirestore db,
  }) async {
    final ahora = DateTime.now();

    // Lanzar en paralelo — son queries independientes.
    final results = await Future.wait([
      _viajesDelMes(db, ahora),
      _statsSnapshot(db),
      _viajesPorSemana(db, ahora, semanas: 8),
      _eficienciaCombustible(db, ahora),
    ]);

    final viajesMes = results[0] as KpiMes;
    final stats = results[1] as Map<String, dynamic>;
    final viajesSem = results[2] as List<PuntoTendencia>;
    final eficiencia = results[3] as KpiEficiencia;

    final choferesActivos = (stats['choferes_activos'] as num?)?.toInt() ?? 0;
    final unidadesAsign = (stats['unidades_asignadas'] as num?)?.toInt() ?? 0;
    final vencidos = (stats['vencidos'] as num?)?.toInt() ?? 0;
    final pendientes =
        (stats['revisiones_pendientes'] as num?)?.toInt() ?? 0;
    // "Alertas críticas" = vencidos + revisiones pendientes.
    final alertas = vencidos + pendientes;

    return KpisVistaEjecutiva(
      viajesDelMes: viajesMes,
      choferesActivos: KpiSimple(
        valor: choferesActivos,
        sublabel: '$unidadesAsign con unidad asignada',
      ),
      alertasCriticas: KpiSimple(
        valor: alertas,
        sublabel: alertas == 0
            ? 'Todo al día'
            : '$vencidos vencidos · $pendientes revisiones',
      ),
      eficienciaCombustible: eficiencia,
      viajesPorSemana: viajesSem,
    );
  }

  // ───────────────────────────────────────────────────────────────────
  // KPIs individuales
  // ───────────────────────────────────────────────────────────────────

  /// Cuenta viajes con `fecha_carga` en el mes actual y mes anterior.
  /// Solo cuenta los `activo: true` (excluye soft-deleted).
  /// Cuenta los 2 meses en paralelo.
  static Future<KpiMes> _viajesDelMes(
    FirebaseFirestore db,
    DateTime ahora,
  ) async {
    final inicioMesActual = DateTime(ahora.year, ahora.month, 1);
    final inicioMesAnterior = DateTime(ahora.year, ahora.month - 1, 1);
    final finMesAnterior = inicioMesActual;
    final results = await Future.wait([
      _contarViajesEnRango(db, inicioMesActual, ahora),
      _contarViajesEnRango(db, inicioMesAnterior, finMesAnterior),
    ]);
    return KpiMes.fromActualYAnterior(results[0], results[1]);
  }

  /// Count de viajes con `fecha_carga` en [desde, hasta) y `activo=true`.
  ///
  /// Auditoria 2026-05-17: antes contaba TAMBIEN viajes legacy con
  /// `estado='CANCELADO'` o `'POSTERGADO'` (estados removidos 2026-05-14)
  /// que siguen con `activo=true`. El KPI del tablero CEO mostraba 35
  /// viajes/mes cuando los reales eran 28 + 7 cancelados. Fix: usar `.get()`
  /// (no `.count()`) y filtrar client-side por `estado != CANCELADO/POSTERGADO`.
  /// El extra fetch es aceptable (decenas de docs/mes vs miles).
  static Future<int> _contarViajesEnRango(
    FirebaseFirestore db,
    DateTime desde,
    DateTime hasta,
  ) async {
    try {
      final snap = await db
          .collection('VIAJES_LOGISTICA')
          .where('activo', isEqualTo: true)
          .where('fecha_carga',
              isGreaterThanOrEqualTo: Timestamp.fromDate(desde))
          .where('fecha_carga', isLessThan: Timestamp.fromDate(hasta))
          .get();
      // Filtrar legacy CANCELADO/POSTERGADO (mismo patron que
      // liquidacion_service y viajes_service).
      var count = 0;
      for (final d in snap.docs) {
        final estadoRaw = (d.data()['estado'] ?? '').toString();
        if (estadoRaw != 'CANCELADO' && estadoRaw != 'POSTERGADO') count++;
      }
      return count;
    } catch (_) {
      // Fallback defensivo si el query falla (ej. sin índice): devolver
      // 0 para no romper el tablero. El error queda en consola.
      return 0;
    }
  }

  /// Lee `STATS/dashboard` (poblado por el cron `recomputeDashboardStats`
  /// cada 5 min). Si el doc no existe devuelve {} para que los KPIs
  /// caigan a 0 silenciosamente.
  static Future<Map<String, dynamic>> _statsSnapshot(
    FirebaseFirestore db,
  ) async {
    try {
      final snap = await db.collection('STATS').doc('dashboard').get();
      return snap.data() ?? const {};
    } catch (_) {
      return const {};
    }
  }

  /// Serie de N puntos: cantidad de viajes por semana (count) las
  /// últimas N semanas cerradas + la actual.
  /// Suma viajes con `activo=true` y `fecha_carga` en el rango.
  static Future<List<PuntoTendencia>> _viajesPorSemana(
    FirebaseFirestore db,
    DateTime ahora, {
    required int semanas,
  }) async {
    final diasDesdeLunes = (ahora.weekday - DateTime.monday) % 7;
    final lunesActual = DateTime(ahora.year, ahora.month, ahora.day)
        .subtract(Duration(days: diasDesdeLunes));
    final lunes = <DateTime>[];
    for (int i = semanas - 1; i >= 0; i--) {
      lunes.add(lunesActual.subtract(Duration(days: 7 * i)));
    }
    final counts = await Future.wait(
      lunes.map((l) => _contarViajesEnRango(
            db,
            l,
            l.add(const Duration(days: 7)),
          )),
    );
    final result = <PuntoTendencia>[];
    for (var i = 0; i < lunes.length; i++) {
      result.add(PuntoTendencia(
        label: _labelSemanaCorto(lunes[i]),
        valor: counts[i].toDouble(),
      ));
    }
    return result;
  }

  /// Eficiencia combustible (L/100km) últimos 30 días + comparativa
  /// vs los 30 días previos. Lee docs `_FLEET_*` de `VOLVO_SCORES_DIARIOS`
  /// (1 doc por día, generados por el cron `volvoScoresPoller` 04:00 ART).
  ///
  /// Unidad: **L/100km** (métrica AR/UE — más bajo = mejor).
  ///
  /// Cálculo ponderado por km del día (los días de mucho rodaje pesan
  /// más en el promedio):
  ///   L/100km = (Σ litros del período / Σ km del período) × 100
  ///   litros del día = km × avgFuelConsumption_ml / 100_000
  ///     (km × ml/100km / 100 = ml; /1000 = L)
  ///
  /// Devuelve `KpiEficiencia.vacia` si no hay docs en el rango (cron
  /// no corrió aún o flota sin Volvo Connect).
  static Future<KpiEficiencia> _eficienciaCombustible(
    FirebaseFirestore db,
    DateTime ahora,
  ) async {
    try {
      // Traemos los últimos 60 días para tener ambos períodos en 1 query.
      // El índice (es_fleet + fecha_ts DESC) ya existe en firestore.indexes.json.
      final desdeMs = ahora
          .subtract(const Duration(days: 60))
          .millisecondsSinceEpoch;
      final snap = await db
          .collection('VOLVO_SCORES_DIARIOS')
          .where('es_fleet', isEqualTo: true)
          .where('fecha_ts',
              isGreaterThanOrEqualTo:
                  Timestamp.fromMillisecondsSinceEpoch(desdeMs))
          .orderBy('fecha_ts', descending: true)
          .limit(60)
          .get();

      if (snap.docs.isEmpty) return KpiEficiencia.vacia;

      // Pivote: hace 30 días dividimos en "actual" (últimos 30) vs
      // "previo" (días 31-60). Cada doc tiene `fecha_ts` (Timestamp).
      final pivote = ahora.subtract(const Duration(days: 30));

      double kmActual = 0;
      double litrosActual = 0;
      double kmPrevio = 0;
      double litrosPrevio = 0;
      int diasActual = 0;

      for (final doc in snap.docs) {
        final d = doc.data();
        final fechaTs = (d['fecha_ts'] as Timestamp?)?.toDate();
        if (fechaTs == null) continue;
        final totalDistanceM = (d['totalDistance'] as num?)?.toDouble();
        final avgFuelMlPer100Km =
            (d['avgFuelConsumption'] as num?)?.toDouble();
        // Si falta alguno de los crudos no podemos calcular litros del día.
        if (totalDistanceM == null ||
            avgFuelMlPer100Km == null ||
            totalDistanceM <= 0 ||
            avgFuelMlPer100Km <= 0) {
          continue;
        }
        final kmDelDia = totalDistanceM / 1000;
        // Litros consumidos en el día = km × (ml/100km) / 100_000
        // (km × ml/100km / 100 = ml; /1000 = litros)
        final litrosDelDia = kmDelDia * avgFuelMlPer100Km / 100000;

        if (fechaTs.isAfter(pivote)) {
          kmActual += kmDelDia;
          litrosActual += litrosDelDia;
          diasActual++;
        } else {
          kmPrevio += kmDelDia;
          litrosPrevio += litrosDelDia;
        }
      }

      // L/100km = (litros / km) × 100. Más bajo = mejor.
      final lpor100Actual =
          kmActual > 0 ? (litrosActual / kmActual) * 100 : 0.0;
      final lpor100Previo =
          kmPrevio > 0 ? (litrosPrevio / kmPrevio) * 100 : 0.0;

      return KpiEficiencia.fromValores(
        actual: lpor100Actual,
        anterior: lpor100Previo,
        kmTotales: kmActual,
        diasConDatos: diasActual,
      );
    } catch (_) {
      // Si falla (sin índice, permisos, etc.), devolvemos vacía para
      // no romper todo el tablero. UI lo muestra como "—".
      return KpiEficiencia.vacia;
    }
  }

  // ───────────────────────────────────────────────────────────────────
  // Helpers
  // ───────────────────────────────────────────────────────────────────

  /// Label corto para el eje X de los gráficos: "12 May" (día + mes abrev).
  /// Más legible que "S 12-18 May" para muchos puntos juntos.
  static String _labelSemanaCorto(DateTime lunes) {
    const meses = [
      'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
      'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic',
    ];
    return '${lunes.day} ${meses[lunes.month - 1]}';
  }
}

