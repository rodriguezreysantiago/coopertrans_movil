// Calculator del ICM (Índice de Conducta de Manejo) — el mismo modelo
// que YPF usa en su Tablero ICM. Combina los eventos peligrosos de
// SITRACK_EVENTOS con los km recorridos para producir un puntaje 0-100
// por chofer en un rango de fechas.
//
// Fórmula adaptada de la norma YPF NO_0002913 (sec 5.6.2):
//
//   ICM = max(0, 100 - (puntaje_infracciones * 10 / horas_activas))
//
// Como aproximación operativa más estable usamos:
//
//   infracciones_por_100km = total_eventos / (km_recorridos / 100)
//   icm = max(0, min(100, 100 - infracciones_por_100km * FACTOR))
//
// Donde FACTOR es calibrable (default 5). Con FACTOR=5:
//   - 0 infracciones / 100 km → ICM 100 (perfecto)
//   - 4 infracciones / 100 km → ICM 80 (umbral verde)
//   - 8 infracciones / 100 km → ICM 60 (umbral amarillo)
//   - 20 infracciones / 100 km → ICM 0
//
// Nota: el ICM YPF se mide MENSUAL por chofer. Acá lo dejamos
// configurable por rango de fechas porque es más útil para análisis
// (semana, día, mes).

import 'package:cloud_firestore/cloud_firestore.dart';

/// Tipos de evento Sitrack que cuentan como infracción para el ICM.
/// Mismos que el resumen Molina diario (`resumenConductaManejoDiario`):
/// salida de carril, sobrevelocidad in/out, frenada brusca, aceleración
/// brusca, giro brusco, distancia frenado insuficiente, colisiones.
const Set<int> kTiposInfraccionIcm = {
  8, 9, 66, 67, 267, 326, 383, 444, 1006, 1007,
};

/// Categoría de riesgo según el rango de ICM. Alineado con YPF:
/// Verde (bajo) = ≥ 80, Amarillo (medio) = 60-79, Rojo (alto) = < 60.
enum CategoriaIcm { bajo, medio, alto, sinDatos }

/// Resumen del ICM de un chofer en un rango.
class IcmChofer {
  final String choferDni;
  final String choferNombre;
  final int totalEventos;
  final double kmRecorridos;
  final double infraccionesPor100Km;
  final double icm; // 0..100
  final CategoriaIcm categoria;
  /// Distribución por tipo de evento (key = nombre del evento, value = count).
  final Map<String, int> eventosPorTipo;
  /// Patentes que manejó el chofer en el rango (más frecuente primero).
  final List<String> patentes;

  const IcmChofer({
    required this.choferDni,
    required this.choferNombre,
    required this.totalEventos,
    required this.kmRecorridos,
    required this.infraccionesPor100Km,
    required this.icm,
    required this.categoria,
    required this.eventosPorTipo,
    required this.patentes,
  });
}

class IcmCalculator {
  IcmCalculator._();

  /// Multiplicador del puntaje. 5 es el valor inicial calibrado a ojo
  /// — cuando tengamos data real de YPF para comparar contra su Tablero
  /// podemos ajustarlo para que los ICM nuestros se acerquen a los suyos.
  static const double _factor = 5;

  /// Mínimo de km recorridos para reportar ICM. Por debajo de este,
  /// devolvemos `categoria: sinDatos` en lugar de un ICM ruidoso (ej.
  /// 1 sobrevelocidad en 5 km da ratio 20/100km → ICM 0, falso positivo).
  static const double _kmMinimoParaIcm = 50.0;

  /// Calcula el ICM de TODOS los choferes con eventos en el rango.
  /// Devuelve la lista ordenada del peor (ICM más bajo) al mejor.
  ///
  /// `desde` y `hasta` son timestamps en ms epoch (UTC).
  /// `nombrePorDni` es el lookup de EMPLEADOS para resolver nombres.
  static Future<List<IcmChofer>> calcularRanking({
    required FirebaseFirestore db,
    required int desdeMs,
    required int hastaMs,
    required Map<String, String> nombrePorDni,
  }) async {
    // ─── 1. Cargar eventos peligrosos del rango ─────────────────
    final snapEventos = await db
        .collection('SITRACK_EVENTOS')
        .where('report_date',
            isGreaterThanOrEqualTo: Timestamp.fromMillisecondsSinceEpoch(desdeMs))
        .where('report_date',
            isLessThan: Timestamp.fromMillisecondsSinceEpoch(hastaMs))
        .get();

    // Agrupador por chofer — captura eventos + odómetros por patente
    // para calcular km reales recorridos en el rango (max - min del
    // odómetro Sitrack en los eventos del chofer en cada patente).
    final porChofer = <String, _AggChofer>{};
    for (final doc in snapEventos.docs) {
      final d = doc.data();
      final eventId = d['event_id'];
      final dni = (d['driver_dni'] ?? '').toString().trim();
      if (dni.isEmpty) continue; // ICM solo aplica a choferes identificados
      final patente = (d['asset_id'] ?? '').toString().trim().toUpperCase();
      // `odometer` viene del cron `sitrackEventosPoller` (campo top-level
      // en SITRACK_EVENTOS). Si no viene (eventos viejos pre-deploy o
      // unidades sin reportar odómetro), lo ignoramos para el cálculo
      // de km — el evento sigue contando como infracción pero no aporta
      // al numerador del km.
      final odometer = (d['odometer'] as num?)?.toDouble();

      final agg = porChofer.putIfAbsent(dni, () => _AggChofer());

      // Acumular odómetros del chofer en esta patente — incluye TODOS
      // los eventos (no solo las infracciones) para tener la mayor
      // ventana de km posible. Si un chofer manejó muchas patentes
      // diferentes en el rango, cada una aporta sus km.
      if (patente.isNotEmpty && odometer != null && odometer > 0) {
        final tracking = agg.odometroPorPatente.putIfAbsent(
          patente,
          () => _OdometroTracking(),
        );
        if (odometer < tracking.min) tracking.min = odometer;
        if (odometer > tracking.max) tracking.max = odometer;
      }

      // Las infracciones solo cuentan si el evento esta en la lista YPF.
      if (eventId is! int || !kTiposInfraccionIcm.contains(eventId)) continue;
      final nombre = (d['event_name'] ?? 'Evento $eventId').toString();
      agg.totalEventos++;
      agg.eventosPorTipo[nombre] = (agg.eventosPorTipo[nombre] ?? 0) + 1;
      if (patente.isNotEmpty) {
        agg.patentesCount[patente] = (agg.patentesCount[patente] ?? 0) + 1;
      }
    }

    // ─── 2. Construir IcmChofer por chofer ──────────────────────
    // Km reales del chofer en el rango = suma de (max - min) del odómetro
    // Sitrack por cada patente que manejó. Esto es la lectura REAL del
    // odómetro del vehículo en eventos consecutivos, NO una heurística
    // (refactor 2026-05-16 — antes era `totalEventos × 100` que daba
    // ratio = 1 → ICM = 95 para CUALQUIER chofer con eventos, rompiendo
    // la utilidad del ranking).
    //
    // Si no hay datos de odómetro (eventos viejos pre-poller o unidades
    // sin reportar km), fallback al baseline conservador 50 km/evento
    // y marcamos categoría `sinDatos` para que la UI lo refleje en lugar
    // de mentir con un ICM falso.
    final result = <IcmChofer>[];
    for (final entry in porChofer.entries) {
      final dni = entry.key;
      final agg = entry.value;

      // Sumar km reales por patente (max - min del odómetro).
      double kmReales = 0;
      for (final tracking in agg.odometroPorPatente.values) {
        if (tracking.max > tracking.min) {
          kmReales += (tracking.max - tracking.min);
        }
      }

      // Si hay datos reales y superan el umbral, usar km reales. Sino
      // categoría sinDatos (no inventamos un ICM falso).
      final tieneKmReales = kmReales >= _kmMinimoParaIcm;
      final km = tieneKmReales ? kmReales : 0.0;
      final icm = tieneKmReales ? _calcularIcm(agg.totalEventos, km) : 0.0;
      final categoria =
          tieneKmReales ? _categorizar(icm) : CategoriaIcm.sinDatos;
      final ratio =
          km > 0 ? (agg.totalEventos / (km / 100.0)) : 0.0;

      // Patentes más frecuentes primero
      final patentesOrdenadas = agg.patentesCount.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      result.add(IcmChofer(
        choferDni: dni,
        choferNombre: nombrePorDni[dni] ?? 'DNI $dni',
        totalEventos: agg.totalEventos,
        kmRecorridos: km,
        infraccionesPor100Km: ratio,
        icm: icm,
        categoria: categoria,
        eventosPorTipo: Map<String, int>.from(agg.eventosPorTipo),
        patentes: patentesOrdenadas.map((e) => e.key).toList(),
      ));
    }

    // Ordenar: peor ICM primero (queremos que Molina vea los problemáticos
    // arriba). CRITICO (auditoria 2026-05-17): SIN_DATOS al FINAL para no
    // confundir a Molina — antes los choferes sin km suficientes (icm=0)
    // ocupaban las posiciones #1-22 del ranking "peor", enmascarando a
    // los choferes realmente problematicos.
    result.sort((a, b) {
      final aSinDatos = a.categoria == CategoriaIcm.sinDatos;
      final bSinDatos = b.categoria == CategoriaIcm.sinDatos;
      if (aSinDatos && !bSinDatos) return 1; // a al final
      if (!aSinDatos && bSinDatos) return -1; // b al final
      return a.icm.compareTo(b.icm);
    });
    return result;
  }

  static double _calcularIcm(int totalEventos, double km) {
    if (km <= 0) return 0;
    final ratio = totalEventos / (km / 100.0);
    final icm = 100 - ratio * _factor;
    return icm.clamp(0.0, 100.0);
  }

  static CategoriaIcm _categorizar(double icm) {
    if (icm >= 80) return CategoriaIcm.bajo;
    if (icm >= 60) return CategoriaIcm.medio;
    return CategoriaIcm.alto;
  }
}

class _AggChofer {
  int totalEventos = 0;
  final Map<String, int> eventosPorTipo = {};
  final Map<String, int> patentesCount = {};
  /// Tracking del odómetro Sitrack en eventos del chofer por patente.
  /// km en rango = max - min para cada patente.
  final Map<String, _OdometroTracking> odometroPorPatente = {};
}

/// Min/max del odómetro Sitrack de un chofer en una patente para el
/// rango analizado. Permite calcular km recorridos sin necesidad de
/// snapshots históricos (la diferencia max-min en los eventos del rango
/// nos da los km reales recorridos).
class _OdometroTracking {
  double min = double.infinity;
  double max = double.negativeInfinity;
}
