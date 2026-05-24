import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../models/tramo_ibutton.dart';

/// Service de lectura de SITRACK_IBUTTONS_HISTORICO. Solo lee — los
/// docs los escribe la CF `reconstruirHistoricoIButtonsDiario` cada
/// 06:00 ART procesando el día anterior.
class HistoricoIButtonService {
  HistoricoIButtonService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AppCollections.sitrackIButtonsHistorico);

  /// Tramos del rango [desde, hasta] ordenados por desde DESC (más
  /// reciente primero). Sin filtro de patente o chofer = toda la flota.
  static Stream<List<TramoIButton>> streamPorRango({
    required DateTime desde,
    required DateTime hasta,
    String? patente,
    String? choferDni,
    int limit = 1000,
  }) {
    Query<Map<String, dynamic>> q = _col
        .where('desde', isGreaterThanOrEqualTo: Timestamp.fromDate(desde))
        .where('desde', isLessThanOrEqualTo: Timestamp.fromDate(hasta));
    if (patente != null && patente.isNotEmpty) {
      q = q.where('patente', isEqualTo: patente.toUpperCase());
    }
    if (choferDni != null && choferDni.isNotEmpty) {
      q = q.where('chofer_dni', isEqualTo: choferDni);
    }
    q = q.orderBy('desde', descending: true).limit(limit);
    return q.snapshots().map(
        (s) => s.docs.map(TramoIButton.fromDoc).toList());
  }
}
