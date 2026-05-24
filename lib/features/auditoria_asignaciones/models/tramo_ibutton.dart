import 'package:cloud_firestore/cloud_firestore.dart';

/// Un tramo continuo donde el mismo iButton estuvo en la misma patente
/// (sin gaps >30 min), reconstruido por la CF a partir de SITRACK_EVENTOS.
class TramoIButton {
  /// DocId: `{patente}_{chofer_dni}_{desde_ms}`.
  final String id;
  final String patente;
  final String choferDni;
  final String? choferNombre;
  final DateTime desde;
  final DateTime hasta;
  final int duracionMin;
  /// Cantidad de eventos Sitrack que respaldan el tramo (más eventos =
  /// mayor confianza). Tramos con <2 eventos no se persisten.
  final int eventosCount;

  const TramoIButton({
    required this.id,
    required this.patente,
    required this.choferDni,
    this.choferNombre,
    required this.desde,
    required this.hasta,
    required this.duracionMin,
    required this.eventosCount,
  });

  factory TramoIButton.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    return TramoIButton(
      id: doc.id,
      patente: (m['patente'] ?? '').toString(),
      choferDni: (m['chofer_dni'] ?? '').toString(),
      choferNombre: (m['chofer_nombre'])?.toString(),
      desde: (m['desde'] as Timestamp).toDate(),
      hasta: (m['hasta'] as Timestamp).toDate(),
      duracionMin: (m['duracion_min'] as num?)?.toInt() ?? 0,
      eventosCount: (m['eventos_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// Nombre legible: prefiere el del iButton si está, sino "DNI ...".
  String get nombreLegible {
    final n = (choferNombre ?? '').trim();
    return n.isNotEmpty ? n : 'DNI $choferDni';
  }
}
