import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../models/registro_jornada.dart';

/// Lectura de `REGISTRO_JORNADAS` (registro de jornada v3). Solo lee: los
/// docs los escribe la CF `registrarJornadasV3Diario` (cron 06:45 ART).
///
/// La regla de Firestore deja al chofer leer SOLO sus propios docs
/// (`resource.data.chofer_dni == request.auth.uid`), así que la query por
/// `chofer_dni == miDni` es segura y válida.
class RegistroJornadaService {
  RegistroJornadaService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AppCollections.registroJornadas);

  /// Stream de las últimas N jornadas de un chofer (más reciente primero).
  /// Requiere índice compuesto (chofer_dni ASC, fecha DESC).
  static Stream<List<RegistroJornada>> streamUltimasDelChofer({
    required String choferDni,
    int limit = 30,
  }) {
    return _col
        .where('chofer_dni', isEqualTo: choferDni)
        .orderBy('fecha', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(RegistroJornada.fromDoc).toList());
  }
}
