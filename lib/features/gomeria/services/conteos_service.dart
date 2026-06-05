// lib/features/gomeria/services/conteos_service.dart
//
// Conteos de inventario "a ciegas" del depósito de gomería. El operador crea
// un conteo (reporta cantidades por modelo); el admin lo revisa contra el
// stock teórico (con `compararConteoVsStock` del modelo). El servicio NO
// ajusta stock — la corrección la decide el admin a mano.
//
// FirebaseFirestore inyectable (default `.instance`) para testear con
// fake_cloud_firestore. Sin runTransaction (Windows).

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../models/conteo_gomeria.dart';

class ConteosService {
  final FirebaseFirestore _db;
  ConteosService({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AppCollections.gomeriaConteos);

  /// Crea un conteo. Solo guarda las líneas con algo contado (>0) — un modelo
  /// ausente se interpreta como "0" al comparar. Devuelve el id.
  Future<String> crearConteo({
    required List<LineaConteo> lineas,
    required String responsableDni,
    required String responsableNombre,
  }) async {
    final conContenido =
        lineas.where((l) => l.nuevas > 0 || l.recapadas > 0).toList();
    final doc = await _col.add({
      'creado_en': FieldValue.serverTimestamp(),
      'responsable_dni': responsableDni,
      'responsable_nombre': responsableNombre,
      'lineas': conContenido.map((l) => l.toMap()).toList(),
      'total_contado': conContenido.fold<int>(0, (a, l) => a + l.total),
      'revisado': false,
    });
    return doc.id;
  }

  /// Stream de los últimos conteos, más nuevo primero. Base de la pantalla de
  /// revisión del admin.
  Stream<List<ConteoGomeria>> streamConteos({int limit = 50}) {
    return _col
        .orderBy('creado_en', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(ConteoGomeria.fromDoc).toList());
  }

  /// Marca un conteo como revisado por el admin (ya lo controló contra el
  /// stock). No ajusta nada — solo deja constancia de que fue visto.
  Future<void> marcarRevisado(String id, String porDni) async {
    await _col.doc(id).update({
      'revisado': true,
      'revisado_por_dni': porDni,
      'revisado_en': FieldValue.serverTimestamp(),
    });
  }
}
