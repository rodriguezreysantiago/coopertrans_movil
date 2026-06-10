import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../models/punto_recorrido.dart';

/// Recorrido histórico de una unidad, leído de `SITRACK_EVENTOS`.
///
/// Esa colección es append-only (un doc por evento), con histórico desde el
/// 2026-05-13 y TTL de 90 días. Filtra por `asset_id == patente` +
/// `report_date` en `[desde, hasta)`, ordenado cronológico. **Requiere** el
/// índice compuesto `(asset_id ASC, report_date ASC)` (firestore.indexes.json).
///
/// La patente se normaliza a MAYÚSCULAS porque así la guarda el poller en
/// `asset_id` (`historico_descargas`/`historico_ibuttons` la leen con
/// `.trim().toUpperCase()`).
class RecorridoService {
  RecorridoService._();

  /// Tope defensivo de puntos por consulta (evita traer miles en rangos muy
  /// largos). Si se alcanza, el recorrido queda recortado (se pierden los
  /// puntos MÁS NUEVOS del rango, por el `orderBy` ascendente).
  static const int limiteDefault = 5000;

  static Future<List<PuntoRecorrido>> obtener({
    required String patente,
    required DateTime desde,
    required DateTime hasta,
    int limite = limiteDefault,
  }) async {
    final assetId = patente.trim().toUpperCase();
    final snap = await FirebaseFirestore.instance
        .collection(AppCollections.sitrackEventos)
        .where('asset_id', isEqualTo: assetId)
        .where('report_date',
            isGreaterThanOrEqualTo: Timestamp.fromDate(desde))
        .where('report_date', isLessThan: Timestamp.fromDate(hasta))
        .orderBy('report_date')
        .limit(limite)
        .get();
    final puntos = <PuntoRecorrido>[];
    for (final d in snap.docs) {
      final p = PuntoRecorrido.deDoc(d.data());
      if (p != null) puntos.add(p);
    }
    return puntos;
  }
}
