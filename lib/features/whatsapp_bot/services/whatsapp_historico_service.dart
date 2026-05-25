import 'package:cloud_firestore/cloud_firestore.dart';

/// M8 — Cliente para la colección de mensajes ENVIADOS / ERROR históricos
/// del bot. Doc 1:1 con COLA_WHATSAPP (mismo docId) pero con TTL 30 días.
///
/// Sirve para auditar "¿se mandó tal mensaje?" cuando alguien reclama
/// — COLA_WHATSAPP tiene TTL muy corto (horas) porque su rol es "cola
/// de trabajo", no archivo.
///
/// El bot escribe; la app SOLO lee. La pantalla "Historial WhatsApp"
/// consume `consultar()` con filtros y paginación.
class WhatsAppHistoricoService {
  WhatsAppHistoricoService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// Nombre de la colección — mantener en sync con
  /// `whatsapp-bot/src/firestore.js → COLECCION_HISTORICO`.
  static const String coleccion = 'WHATSAPP_HISTORICO';

  /// TTL en días — mantener en sync con `TTL_HISTORICO_DIAS` del bot
  /// y con la TTL policy configurada en Firestore Console sobre el
  /// campo `expira_en`.
  static const int ttlDias = 30;

  /// M7 — Cuenta mensajes registrados en cada uno de los últimos `dias`
  /// (ART local). Devuelve lista cronológica: índice 0 = hace `dias-1`,
  /// índice `dias-1` = hoy. Usa `count()` aggregation server-side → cobra
  /// 1 read por día sin importar cuántos mensajes haya en cada uno.
  Future<List<int>> contarPorDia(int dias) async {
    final ahora = DateTime.now();
    final resultados = <int>[];
    for (int i = dias - 1; i >= 0; i--) {
      final inicio = DateTime(ahora.year, ahora.month, ahora.day - i);
      final fin = inicio.add(const Duration(days: 1));
      final agg = await _db
          .collection(coleccion)
          .where('registrado_en',
              isGreaterThanOrEqualTo: Timestamp.fromDate(inicio))
          .where('registrado_en', isLessThan: Timestamp.fromDate(fin))
          .count()
          .get();
      resultados.add(agg.count ?? 0);
    }
    return resultados;
  }

  /// Consulta el histórico con filtros opcionales + paginación.
  ///
  /// IMPORTANTE: solo se puede combinar UN filtro de igualdad
  /// (`destinatarioId` / `origen` / `estado`) con el rango de fechas
  /// — agregar más require índices compuestos que no tenemos.
  /// Caller responsabilidad: pasar solo uno. El UI presenta como
  /// tabs / dropdown único.
  Future<QuerySnapshot<Map<String, dynamic>>> consultar({
    String? destinatarioId,
    String? origen,
    String? estado,
    DateTime? desde,
    DateTime? hasta,
    int limit = 50,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    Query<Map<String, dynamic>> q = _db
        .collection(coleccion)
        .orderBy('registrado_en', descending: true);
    if (destinatarioId != null && destinatarioId.isNotEmpty) {
      q = q.where('destinatario_id', isEqualTo: destinatarioId);
    }
    if (origen != null && origen.isNotEmpty) {
      q = q.where('origen', isEqualTo: origen);
    }
    if (estado != null && estado.isNotEmpty) {
      q = q.where('estado', isEqualTo: estado);
    }
    if (desde != null) {
      q = q.where('registrado_en',
          isGreaterThanOrEqualTo: Timestamp.fromDate(desde));
    }
    if (hasta != null) {
      q = q.where('registrado_en',
          isLessThanOrEqualTo: Timestamp.fromDate(hasta));
    }
    if (startAfter != null) {
      q = q.startAfterDocument(startAfter);
    }
    return q.limit(limit).get();
  }
}
