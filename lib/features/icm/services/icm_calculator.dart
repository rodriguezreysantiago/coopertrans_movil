// =============================================================================
// IcmCalculator — cálculo on-the-fly del ICM CESVI
// =============================================================================
//
// Refactor mayor 2026-05-19 (Santiago): implementación EXACTA CESVI
// homologada (presentación Carsync YPF). Usa las JORNADAS del vigilador
// v2 como unidad de cálculo. Ver `icm_cesvi.dart` para las funciones
// puras y los pesos por tipo.
//
// Uso: lo invoca el ranking ICM en vivo (cuando aún no existe el doc
// pre-calculado en `ICM_SEMANAL/{YYYY-WW}` — típicamente la semana
// actual que el cron `recomputeIcmSemanalScheduled` todavía no cerró
// porque corre lunes 6 AM ART). Mismo cálculo que el servidor para
// garantizar paridad: si la última semana cerrada salió ICM 75 desde
// el cron, esta función también da 75 si la querés recomputar.
//
// **Antes** (factor lineal `100 − ratio×5`): daba "todos en 100" para
// la operación real de Vecchi porque la calibración era muy permisiva
// e incluía eventos no-CESVI (1006, 1007, 444). Reemplazado por la
// fórmula CESVI exacta.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'icm_cesvi.dart';

/// Tipos de evento Sitrack que CESVI/YPF cuenta para el ICM (Índice
/// de Conducta de Manejo, homologado por CESVI Argentina). Set
/// estricto — refactorizado Santiago 2026-05-19 al alinear con la
/// fórmula CESVI exacta del PDF de YPF:
///   - 66  Aceleración Brusca (peso −2.8 por evento)
///   - 67  Frenada Brusca     (peso −5.8 por evento)
///   - 383 Giro Brusco        (peso −2.8 por evento)
///   - 8   Inicio sobrevelocidad ┐ pareados como UN evento de
///   - 9   Fin sobrevelocidad    ┘ sobrevelocidad con duración
///
/// **Antes** (2026-05-16 → 2026-05-19): incluía 267/326/444/1006/1007
/// que son alertas Volvo/Mobileye de seguridad (salida de carril,
/// colisión, distancia frenado insuficiente) — esos NO son parte del
/// ICM CESVI. Hoy viven solo en `TIPOS_PELIGROSOS_SITRACK` para el
/// resumen Molina, no acá.
///
/// ⚠ ESPEJO SERVER-SIDE en `functions/src/index.ts:TIPOS_CESVI_PUROS`.
/// Si tocás uno, tocá el otro.
const Set<int> kTiposInfraccionIcm = {
  8, 9, 66, 67, 383,
};

/// Categoría de riesgo según el rango de ICM. Alineado con CESVI:
/// Verde (bajo) = ≥ 80, Amarillo (medio) = 60-79, Rojo (alto) = < 60.
///
/// IMPORTANTE: los umbrales 80/60 estan REPETIDOS en:
///   - functions/src/icm_cesvi.ts:categorizar
///   - lib/features/icm/services/icm_cesvi.dart:categorizarCesvi
///   - lib/features/vista_ejecutiva/services/vista_ejecutiva_service.dart
///   - lib/features/icm/services/icm_historico_service.dart:_categorizar
/// Si cambias los umbrales aca, CAMBIALOS EN LOS 4 LUGARES (auditoria
/// pendiente: unificar en helper compartido).
enum CategoriaIcm { bajo, medio, alto, sinDatos }

/// Helper publico para categorizar un ICM. Reusado por
/// icm_historico_service. Mantiene la API legacy aunque internamente
/// delegue al módulo CESVI.
CategoriaIcm categorizarIcm(double icm, {bool tieneKmReales = true}) {
  if (!tieneKmReales) return CategoriaIcm.sinDatos;
  final cat = categorizarCesvi(icm);
  switch (cat) {
    case CategoriaCesvi.bajo:
      return CategoriaIcm.bajo;
    case CategoriaCesvi.medio:
      return CategoriaIcm.medio;
    case CategoriaCesvi.alto:
      return CategoriaIcm.alto;
    case CategoriaCesvi.sinDatos:
      return CategoriaIcm.sinDatos;
  }
}

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

  /// Mínimo de km en una jornada para considerarla "con datos".
  /// Debajo de esto el ICM no es estadísticamente útil.
  static const double _kmMinimoJornada = 10;

  /// Cap defensivo: jornada con max-min de odómetro > 2000 km es casi
  /// seguro un reset de odómetro Sitrack — la descartamos.
  static const double _kmMaximoJornada = 2000;

  /// Calcula el ICM de TODOS los choferes con eventos en el rango.
  /// Devuelve la lista ordenada del peor (ICM más bajo) al mejor.
  ///
  /// Implementación CESVI:
  ///   1. Cargar JORNADAS cerradas dentro del rango (vigilador v2).
  ///   2. Cargar SITRACK_EVENTOS del rango.
  ///   3. Por cada jornada, calcular ICM con `calcularIcmJornada`
  ///      (módulo CESVI puro).
  ///   4. Combinar jornadas del chofer con `combinarJornadas`
  ///      (promedio ponderado por km).
  ///
  /// `nombrePorDni` es el lookup de EMPLEADOS para resolver nombres.
  static Future<List<IcmChofer>> calcularRanking({
    required FirebaseFirestore db,
    required int desdeMs,
    required int hastaMs,
    required Map<String, String> nombrePorDni,
  }) async {
    // ─── 1. JORNADAS cerradas en el rango ──────────────────────────
    final jornSnap = await db
        .collection('JORNADAS')
        .where('jornada_fin_ts',
            isGreaterThanOrEqualTo: Timestamp.fromMillisecondsSinceEpoch(desdeMs))
        .where('jornada_fin_ts',
            isLessThan: Timestamp.fromMillisecondsSinceEpoch(hastaMs))
        .limit(5000)
        .get();

    // ─── 2. SITRACK_EVENTOS del rango — paginado por cursor ────────
    // Firestore client SDK limita .limit() a 10000 por query. Para
    // rangos de mes completo (~25-35K eventos) paginamos con cursor
    // sobre `report_date` ordenado. Cada página trae hasta 10000 docs;
    // seguimos hasta que el resultado venga corto (fin del rango) o
    // toque el cap defensivo total.
    //
    // Cap total 100K eventos defensivo — si en el futuro Vecchi crece
    // a >100K eventos/mes, evita freeze del cliente. Hoy el operativo
    // real es ~6-8K/semana = 30K/mes, sobrado.
    const int pageSize = 10000;
    const int capTotal = 100000;
    final eventosPorDni = <String, List<_EvRaw>>{};
    DocumentSnapshot<Map<String, dynamic>>? cursor;
    var totalLeidos = 0;
    while (totalLeidos < capTotal) {
      Query<Map<String, dynamic>> q = db
          .collection('SITRACK_EVENTOS')
          .where('report_date',
              isGreaterThanOrEqualTo:
                  Timestamp.fromMillisecondsSinceEpoch(desdeMs))
          .where('report_date',
              isLessThan: Timestamp.fromMillisecondsSinceEpoch(hastaMs))
          .orderBy('report_date')
          .limit(pageSize);
      if (cursor != null) {
        q = q.startAfterDocument(cursor);
      }
      final pageSnap = await q.get();
      if (pageSnap.docs.isEmpty) break;
      _indexarEventos(pageSnap.docs, eventosPorDni);
      totalLeidos += pageSnap.docs.length;
      if (pageSnap.docs.length < pageSize) break; // última página
      cursor = pageSnap.docs.last;
    }
    if (totalLeidos >= capTotal) {
      debugPrint(
        '[ICM] cap defensivo de $capTotal eventos alcanzado — el '
        'ranking puede estar incompleto. Considerar reducir el rango.',
      );
    }
    // Ordenar cada array por timestamp ascendente (binary search ready).
    for (final arr in eventosPorDni.values) {
      arr.sort((a, b) => a.reportDateMs.compareTo(b.reportDateMs));
    }

    // ─── 3. Por cada jornada, calcular ICM CESVI ───────────────────
    final porChofer = <String, List<JornadaConIcm>>{};
    final patentesPorChofer = <String, Map<String, int>>{};
    final eventosNombrePorChofer = <String, Map<String, int>>{};
    var descartadasPorKm = 0;
    var descartadasPorCap = 0;
    for (final jDoc in jornSnap.docs) {
      final j = jDoc.data();
      final dni = (j['chofer_dni'] ?? '').toString().trim();
      if (dni.isEmpty) continue;
      final iniMs = (j['jornada_inicio_ts'] as Timestamp?)?.millisecondsSinceEpoch;
      final finMs = (j['jornada_fin_ts'] as Timestamp?)?.millisecondsSinceEpoch;
      if (iniMs == null || finMs == null || finMs <= iniMs) continue;
      // Eventos del chofer en la ventana de la jornada
      final todos = eventosPorDni[dni] ?? const <_EvRaw>[];
      final eventosCesvi = <EventoSitrackICM>[];
      var odMin = double.infinity;
      var odMax = double.negativeInfinity;
      for (final e in todos) {
        if (e.reportDateMs < iniMs) continue;
        if (e.reportDateMs > finMs) break;
        if (kTiposInfraccionIcm.contains(e.eventId)) {
          eventosCesvi.add(EventoSitrackICM(
            eventId: e.eventId,
            reportDateMs: e.reportDateMs,
            assetId: e.assetId,
            driverDni: e.driverDni,
            speed: e.speed,
            cartographyLimitSpeed: e.cartLimit,
            areaType: e.areaType,
            odometer: e.odometer,
          ));
          // Trackear nombres y patentes para el detalle del chofer
          final mNom =
              eventosNombrePorChofer.putIfAbsent(dni, () => <String, int>{});
          mNom[e.eventName] = (mNom[e.eventName] ?? 0) + 1;
          if (e.assetId.isNotEmpty) {
            final mPat =
                patentesPorChofer.putIfAbsent(dni, () => <String, int>{});
            mPat[e.assetId] = (mPat[e.assetId] ?? 0) + 1;
          }
        }
        // TODOS los eventos con odómetro válido aportan al km de la
        // jornada (no solo los CESVI).
        final od = e.odometer;
        if (od != null && od > 0) {
          if (od < odMin) odMin = od;
          if (od > odMax) odMax = od;
        }
      }
      // Km de la jornada con cap defensivo contra reset.
      var km = 0.0;
      if (odMax > odMin && odMin != double.infinity) {
        final delta = odMax - odMin;
        if (delta > _kmMaximoJornada) {
          descartadasPorCap++;
          debugPrint(
            '[ICM] jornada descartada por reset odómetro: dni=$dni '
            'deltaKm=${delta.toStringAsFixed(0)}',
          );
          continue;
        }
        km = delta;
      }
      if (km < _kmMinimoJornada) {
        descartadasPorKm++;
        continue;
      }
      // Bloques de manejo del vigilador (para fatiga).
      final bloquesCompletos = (j['bloques_completos'] as num?)?.toInt() ?? 0;
      final bloqueActualSeg =
          (j['bloque_actual_manejo_seg'] as num?)?.toDouble() ?? 0;
      final totalManejoSeg =
          (j['total_manejo_seg'] as num?)?.toDouble() ??
              (bloquesCompletos * 4 * 3600 + bloqueActualSeg);
      final manejoSegPorBloque = <double>[];
      for (var i = 0; i < bloquesCompletos; i++) {
        manejoSegPorBloque.add(4 * 3600);
      }
      if (bloqueActualSeg > 0) manejoSegPorBloque.add(bloqueActualSeg);
      if (manejoSegPorBloque.isEmpty && totalManejoSeg > 0) {
        manejoSegPorBloque.add(totalManejoSeg);
      }
      final res = calcularIcmJornada(eventosCesvi, manejoSegPorBloque);
      porChofer.putIfAbsent(dni, () => []).add(JornadaConIcm(
            icm: res.icm,
            km: km,
            desglose: res,
          ));
    }
    if (descartadasPorCap > 0 || descartadasPorKm > 0) {
      debugPrint(
        '[ICM] jornadas descartadas: cap=$descartadasPorCap, '
        'km<min=$descartadasPorKm',
      );
    }

    // ─── 4. Combinar por chofer y armar IcmChofer ──────────────────
    final result = <IcmChofer>[];
    for (final entry in porChofer.entries) {
      final dni = entry.key;
      final agregado = combinarJornadas(entry.value);
      final totalEventosCesvi = agregado.totalAceleraciones +
          agregado.totalFrenadas +
          agregado.totalGiros +
          agregado.totalSobrevelocidades;
      final ratio = agregado.kmTotales > 0
          ? totalEventosCesvi / (agregado.kmTotales / 100.0)
          : 0.0;
      final patMap = patentesPorChofer[dni] ?? const <String, int>{};
      final patOrd = patMap.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      result.add(IcmChofer(
        choferDni: dni,
        choferNombre: nombrePorDni[dni] ?? 'DNI $dni',
        totalEventos: totalEventosCesvi,
        kmRecorridos: agregado.kmTotales,
        infraccionesPor100Km: ratio,
        icm: agregado.icm,
        categoria: _cesviToLegacy(agregado.categoria),
        eventosPorTipo:
            Map<String, int>.from(eventosNombrePorChofer[dni] ?? {}),
        patentes: patOrd.map((e) => e.key).toList(),
      ));
    }

    // ─── 5. Ordenar: peor ICM primero, SIN_DATOS al final ──────────
    result.sort((a, b) {
      final aSinDatos = a.categoria == CategoriaIcm.sinDatos;
      final bSinDatos = b.categoria == CategoriaIcm.sinDatos;
      if (aSinDatos && !bSinDatos) return 1;
      if (!aSinDatos && bSinDatos) return -1;
      return a.icm.compareTo(b.icm);
    });
    return result;
  }

  /// Categoría helper para tests y consumidores externos (alineada con
  /// el módulo CESVI puro).
  static CategoriaIcm categorizar(double icm) => categorizarIcm(icm);

  /// Indexa una página de docs SITRACK_EVENTOS en el map `eventosPorDni`.
  /// Mutador in-place: no devuelve nada. Filtra docs sin `driver_dni`
  /// o sin `event_id` numérico (datos viejos / corruptos).
  static void _indexarEventos(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    Map<String, List<_EvRaw>> eventosPorDni,
  ) {
    for (final doc in docs) {
      final d = doc.data();
      final dni = (d['driver_dni'] ?? '').toString().trim();
      if (dni.isEmpty) continue;
      final tsMs = (d['report_date'] as Timestamp?)?.millisecondsSinceEpoch;
      if (tsMs == null) continue;
      final eId = d['event_id'];
      if (eId is! int) continue;
      final raw = _EvRaw(
        eventId: eId,
        reportDateMs: tsMs,
        assetId: (d['asset_id'] ?? '').toString().trim().toUpperCase(),
        driverDni: dni,
        eventName: (d['event_name'] ?? 'Evento $eId').toString(),
        speed: (d['speed'] as num?)?.toDouble() ??
            (d['gps_speed'] as num?)?.toDouble(),
        cartLimit: (d['cartography_limit_speed'] as num?)?.toDouble(),
        areaType: (d['area_type'] ?? 'unknown').toString(),
        odometer: (d['odometer'] as num?)?.toDouble() ??
            (d['gps_odometer'] as num?)?.toDouble(),
      );
      eventosPorDni.putIfAbsent(dni, () => []).add(raw);
    }
  }

  static CategoriaIcm _cesviToLegacy(CategoriaCesvi c) {
    switch (c) {
      case CategoriaCesvi.bajo:
        return CategoriaIcm.bajo;
      case CategoriaCesvi.medio:
        return CategoriaIcm.medio;
      case CategoriaCesvi.alto:
        return CategoriaIcm.alto;
      case CategoriaCesvi.sinDatos:
        return CategoriaIcm.sinDatos;
    }
  }
}

/// Evento Sitrack crudo indexado por DNI (interno al calculator).
class _EvRaw {
  final int eventId;
  final int reportDateMs;
  final String assetId;
  final String driverDni;
  final String eventName;
  final double? speed;
  final double? cartLimit;
  final String areaType;
  final double? odometer;
  const _EvRaw({
    required this.eventId,
    required this.reportDateMs,
    required this.assetId,
    required this.driverDni,
    required this.eventName,
    this.speed,
    this.cartLimit,
    required this.areaType,
    this.odometer,
  });
}
