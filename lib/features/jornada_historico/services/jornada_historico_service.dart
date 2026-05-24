import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../models/jornada_dia.dart';

/// Lectura de `VOLVO_JORNADAS_HISTORICO`. Solo lee: los docs los escribe
/// la CF `reconstruirJornadasDiario` (cron 06:30 ART, procesa AYER).
class JornadaHistoricoService {
  JornadaHistoricoService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AppCollections.volvoJornadasHistorico);

  /// Stream de la jornada de un chofer en una fecha específica.
  /// Devuelve `null` si todavía no se procesó (el cron corre 06:30 ART
  /// — días anteriores siempre tendrán doc; HOY recién al día siguiente).
  static Stream<JornadaDia?> streamDia({
    required String choferDni,
    required DateTime fecha,
  }) {
    final fechaStr = _fmtFecha(fecha);
    final docId = '${choferDni}_$fechaStr';
    return _col.doc(docId).snapshots().map(
        (s) => s.exists ? JornadaDia.fromDoc(s) : null);
  }

  /// Stream de las últimas N jornadas de un chofer (más reciente primero).
  /// Útil para "ver últimos 7 días" — cada doc trae el resumen completo.
  static Stream<List<JornadaDia>> streamUltimasDelChofer({
    required String choferDni,
    int limit = 30,
  }) {
    return _col
        .where('chofer_dni', isEqualTo: choferDni)
        .orderBy('fecha', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(JornadaDia.fromDoc).toList());
  }

  /// Stream de jornadas de un chofer en un rango de fechas (ambos
  /// inclusive), ordenadas por fecha ASCENDENTE para que la UI muestre
  /// el día más viejo primero. Usado por la pantalla Jornada cuando el
  /// operador elige "22 al 24 de mayo" — devuelve hasta 3 docs (uno por
  /// día con jornada; los días sin actividad no aparecen).
  static Stream<List<JornadaDia>> streamPorRango({
    required String choferDni,
    required DateTime desde,
    required DateTime hasta,
  }) {
    final desdeStr = _fmtFecha(desde);
    final hastaStr = _fmtFecha(hasta);
    return _col
        .where('chofer_dni', isEqualTo: choferDni)
        .where('fecha', isGreaterThanOrEqualTo: desdeStr)
        .where('fecha', isLessThanOrEqualTo: hastaStr)
        .orderBy('fecha')
        .snapshots()
        .map((s) => s.docs.map(JornadaDia.fromDoc).toList());
  }

  /// Fechas en las que hay doc procesado para el chofer (para que el
  /// selector de fechas pinte las que tienen data).
  static Future<Set<String>> fechasDisponibles({
    required String choferDni,
    int ultimasN = 60,
  }) async {
    final snap = await _col
        .where('chofer_dni', isEqualTo: choferDni)
        .orderBy('fecha', descending: true)
        .limit(ultimasN)
        .get();
    return snap.docs
        .map((d) => (d.data()['fecha'] as String?) ?? '')
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  static String _fmtFecha(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$y-$m-$dd';
  }
}
