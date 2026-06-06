import 'package:cloud_firestore/cloud_firestore.dart';

/// Un reclamo que un chofer dejó por el bot de WhatsApp cuando insistió en que
/// un dato del sistema NO le coincidía (su jornada/horas, su unidad, un
/// adelanto, un vencimiento...).
///
/// Lo ESCRIBE el bot (tool `reportar_discrepancia`, vía Admin SDK) — la app
/// solo lo LEE y permite marcarlo revisado. **No modifica el dato reclamado**:
/// la verdad la define la telemetría/GPS; esto es feedback para revisar caso
/// por caso (puede ser un bug real del sistema o el chofer mintiendo).
class ReporteDiscrepancia {
  final String id;
  final String choferDni;
  final String choferNombre;

  /// jornada | unidad | adelantos | vencimientos | otro
  final String tema;

  /// Lo que dijo el chofer, en sus palabras (lo arma el agente).
  final String detalle;

  /// pendiente | revisado
  final String estado;
  final DateTime? creadoEn;

  /// Veredicto del que revisa: `cierto` (el reclamo era válido / bug real) o
  /// `no_cierto` (el dato del sistema estaba bien). `null` mientras pendiente.
  final String? veredicto;
  final String? notaRevision;
  final String? revisadoPorNombre;
  final DateTime? revisadoEn;

  const ReporteDiscrepancia({
    required this.id,
    required this.choferDni,
    required this.choferNombre,
    required this.tema,
    required this.detalle,
    required this.estado,
    required this.creadoEn,
    required this.veredicto,
    required this.notaRevision,
    required this.revisadoPorNombre,
    required this.revisadoEn,
  });

  bool get pendiente => estado != 'revisado';
  bool get esCierto => veredicto == 'cierto';

  static const Map<String, String> temasLegibles = {
    'jornada': 'Jornada / horas',
    'unidad': 'Unidad',
    'adelantos': 'Adelantos',
    'vencimientos': 'Vencimientos',
    'otro': 'Otro',
  };
  String get temaLegible => temasLegibles[tema] ?? 'Otro';

  factory ReporteDiscrepancia.fromDoc(
          DocumentSnapshot<Map<String, dynamic>> doc) =>
      ReporteDiscrepancia.fromMap(doc.id, doc.data());

  factory ReporteDiscrepancia.fromMap(String id, Map<String, dynamic>? data) {
    final m = data ?? const <String, dynamic>{};
    DateTime? ts(dynamic v) => v is Timestamp ? v.toDate() : null;
    return ReporteDiscrepancia(
      id: id,
      choferDni: (m['chofer_dni'] ?? '').toString(),
      choferNombre: (m['chofer_nombre'] ?? '').toString(),
      tema: (m['tema'] ?? 'otro').toString(),
      detalle: (m['detalle'] ?? '').toString(),
      estado: (m['estado'] ?? 'pendiente').toString(),
      creadoEn: ts(m['creado_en']),
      veredicto: m['veredicto']?.toString(),
      notaRevision: m['nota_revision']?.toString(),
      revisadoPorNombre: m['revisado_por_nombre']?.toString(),
      revisadoEn: ts(m['revisado_en']),
    );
  }
}
