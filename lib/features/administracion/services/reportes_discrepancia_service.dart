import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../models/reporte_discrepancia.dart';

/// Lectura + revisión de los reclamos de choferes (`REPORTES_DISCREPANCIA`).
///
/// Los docs los crea SOLO el bot (tool `reportar_discrepancia`, Admin SDK). La
/// app no crea ni borra: lee y marca revisado (con veredicto cierto/no_cierto).
/// NO toca el dato reclamado — es feedback para validar contra la telemetría.
class ReportesDiscrepanciaService {
  final FirebaseFirestore _db;

  ReportesDiscrepanciaService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AppCollections.reportesDiscrepancia);

  /// Todos los reportes, más nuevos primero.
  Stream<List<ReporteDiscrepancia>> stream() {
    return _col.orderBy('creado_en', descending: true).snapshots().map(
        (s) => s.docs.map(ReporteDiscrepancia.fromDoc).toList());
  }

  /// Marca un reporte como revisado con su veredicto (`cierto` | `no_cierto`).
  Future<void> marcarRevisado({
    required String id,
    required String veredicto,
    String? nota,
    required String revisorDni,
    String? revisorNombre,
  }) async {
    final data = <String, dynamic>{
      'estado': 'revisado',
      'veredicto': veredicto,
      'revisado_por_dni': revisorDni,
      'revisado_en': FieldValue.serverTimestamp(),
    };
    if (nota != null && nota.trim().isNotEmpty) {
      data['nota_revision'] = nota.trim();
    }
    if (revisorNombre != null && revisorNombre.isNotEmpty) {
      data['revisado_por_nombre'] = revisorNombre;
    }
    await _col.doc(id).update(data);
  }

  /// Reabre un reporte marcado por error (vuelve a pendiente).
  Future<void> reabrir(String id) async {
    await _col.doc(id).update({
      'estado': 'pendiente',
      'veredicto': FieldValue.delete(),
      'nota_revision': FieldValue.delete(),
      'revisado_por_dni': FieldValue.delete(),
      'revisado_por_nombre': FieldValue.delete(),
      'revisado_en': FieldValue.delete(),
    });
  }
}
