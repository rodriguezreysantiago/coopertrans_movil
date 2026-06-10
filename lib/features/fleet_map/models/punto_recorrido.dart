import 'package:cloud_firestore/cloud_firestore.dart';

/// Un punto del recorrido histórico de una unidad, derivado de un evento de
/// `SITRACK_EVENTOS`.
///
/// Los eventos son DISCRETOS (no un breadcrumb cada N segundos): cada uno es
/// un reporte de Sitrack (cambio de curso, contacto on/off, movimiento, etc.)
/// con su posición. La trayectoria del mapa une estos puntos en orden
/// cronológico — fiel a dónde reportó, pero no ultra-fina.
class PuntoRecorrido {
  final double lat;
  final double lng;

  /// `report_date` del evento (UTC; se formatea a ART al mostrar).
  final DateTime fecha;

  /// km/h — `gps_speed` si está, si no `speed`. Null si no reportó.
  final double? velocidad;

  /// Rumbo en grados (0 = N, sentido horario). Null si no reportó.
  final double? heading;

  /// `event_name` del catálogo Sitrack (ej. "Cambio de curso").
  final String evento;

  /// Motor encendido en ese punto.
  final bool ignition;

  const PuntoRecorrido({
    required this.lat,
    required this.lng,
    required this.fecha,
    required this.velocidad,
    required this.heading,
    required this.evento,
    required this.ignition,
  });

  /// Mapea un doc de `SITRACK_EVENTOS`. Devuelve `null` si el punto NO sirve
  /// para una trayectoria: sin `latitude`/`longitude`, en (0,0) (GPS sin fix)
  /// o sin `report_date`. Mantener PURO (sin red) — testeable sin emulator.
  static PuntoRecorrido? deDoc(Map<String, dynamic> m) {
    final lat = (m['latitude'] as num?)?.toDouble();
    final lng = (m['longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    // (0,0) = posición inválida típica de un GPS sin fix — la descartamos
    // para que no aparezca una recta hasta el golfo de Guinea.
    if (lat == 0 && lng == 0) return null;
    final fecha = (m['report_date'] as Timestamp?)?.toDate();
    if (fecha == null) return null;
    final spd = (m['gps_speed'] as num?) ?? (m['speed'] as num?);
    final hdg = m['heading'] as num?;
    final ign = m['ignition'];
    return PuntoRecorrido(
      lat: lat,
      lng: lng,
      fecha: fecha,
      velocidad: spd?.toDouble(),
      heading: hdg?.toDouble(),
      evento: (m['event_name'] ?? '').toString(),
      ignition: ign == 1 || ign == true,
    );
  }
}
