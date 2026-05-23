// Lee eventos individuales del chofer desde SITRACK_EVENTOS (stream que
// popula `sitrackEventosPoller` cada 5 min con la data del endpoint
// /files/reports de Sitrack — 1 doc por evento, ~30 campos por doc).
//
// El doc oficial `ICM_OFICIAL/{periodo}` solo tiene los COUNTERS de
// infracciones (leves / medias / altas / excesos / agresiva). Acá podemos
// mostrar el detalle individual: qué tipo de evento, cuándo, dónde, a qué
// velocidad y con qué límite de calle.
//
// Esto NO altera el ICM (ese sigue siendo el número oficial Sitrack); solo
// le da color al detalle por chofer para entender qué fue lo que disparó
// las infracciones.

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/app_logger.dart';

/// Un evento individual del chofer en SITRACK_EVENTOS. Subset de los
/// ~30 campos del doc — sólo los que la UI muestra. Si después necesitamos
/// más (heading, gps_satellites, etc.) se agrega acá.
class SitrackEventoChofer {
  final String reportId;
  final DateTime? reportDate; // UTC; la UI lo formatea con AppFormatters

  final String eventName;
  final int? eventId;

  /// Texto legible de la ubicación que ya devuelve Sitrack (calle / barrio).
  final String? location;
  final double? latitude;
  final double? longitude;

  /// Velocidad reportada por el equipo (km/h). Hay dos: `speed` (la del
  /// computador de a bordo si lo tiene) y `gps_speed` (la del GPS); acá
  /// usamos la primera que esté presente.
  final double? speed;

  /// Límite de velocidad de la calle según la cartografía Sitrack (km/h).
  /// Si está + `speed` está + `speed > límite`, es un exceso real.
  final double? cartographyLimitSpeed;

  /// Patente del tractor (cómodo para que el operador vea qué unidad iba
  /// manejando el chofer si hubo reasignación durante el período).
  final String? assetName;

  /// Ignición al momento del evento (0 = apagado, 1 = encendido).
  /// Útil para distinguir eventos en movimiento vs stop & go.
  final int? ignition;

  /// Odómetro al momento del evento, en km (a partir del `odometer` que
  /// viene en metros — convertido al cargar). Null si el equipo no lo
  /// reportó (caso real con varios equipos viejos).
  final double? odometerKm;

  const SitrackEventoChofer({
    required this.reportId,
    required this.reportDate,
    required this.eventName,
    this.eventId,
    this.location,
    this.latitude,
    this.longitude,
    this.speed,
    this.cartographyLimitSpeed,
    this.assetName,
    this.ignition,
    this.odometerKm,
  });

  /// `true` si tenemos speed + limite y la speed supera el limite (con
  /// tolerancia 1 km/h para no marcar 51-en-50 como exceso de manual).
  bool get esExcesoCartografico {
    final s = speed;
    final l = cartographyLimitSpeed;
    if (s == null || l == null || l <= 0) return false;
    return s > l + 1.0;
  }

  factory SitrackEventoChofer.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    double? asDouble(dynamic v) =>
        v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
    int? asInt(dynamic v) =>
        v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
    final odoMetros = asDouble(d['odometer']);
    return SitrackEventoChofer(
      reportId: doc.id,
      reportDate: (d['report_date'] as Timestamp?)?.toDate(),
      eventName: (d['event_name'] ?? '(sin tipo)').toString(),
      eventId: asInt(d['event_id']),
      location: d['location']?.toString(),
      latitude: asDouble(d['latitude']),
      longitude: asDouble(d['longitude']),
      speed: asDouble(d['speed']) ?? asDouble(d['gps_speed']),
      cartographyLimitSpeed: asDouble(d['cartography_limit_speed']),
      assetName: d['asset_name']?.toString(),
      ignition: asInt(d['ignition']),
      odometerKm: odoMetros == null ? null : odoMetros / 1000.0,
    );
  }
}

class SitrackEventosService {
  SitrackEventosService._();

  /// Trae los eventos del chofer `dni` en `[desde, hasta]` (ambos
  /// inclusivos), ordenados por `report_date` descendente (más recientes
  /// primero). Limitado a `limit` (default 500) para no traer miles de
  /// docs en choferes con mucha actividad — la UI muestra "X+ eventos"
  /// si se llega al tope.
  ///
  /// Fail-safe: si la query falla (sin índice, sin permisos), devuelve
  /// lista vacía + loguea WARN. La UI muestra estado vacío.
  static Future<List<SitrackEventoChofer>> cargarEventosChofer({
    required FirebaseFirestore db,
    required String dni,
    required DateTime desde,
    required DateTime hasta,
    int limit = 500,
  }) async {
    if (dni.isEmpty) return const [];
    try {
      final snap = await db
          .collection('SITRACK_EVENTOS')
          .where('driver_dni', isEqualTo: dni)
          .where('report_date',
              isGreaterThanOrEqualTo: Timestamp.fromDate(desde))
          .where('report_date',
              isLessThanOrEqualTo: Timestamp.fromDate(hasta))
          .orderBy('report_date', descending: true)
          .limit(limit)
          .get();
      return snap.docs.map(SitrackEventoChofer.fromDoc).toList();
    } catch (e, st) {
      AppLogger.recordError(
        e,
        st,
        reason: '[SitrackEventosService] cargarEventosChofer fallo',
      );
      return const [];
    }
  }
}
