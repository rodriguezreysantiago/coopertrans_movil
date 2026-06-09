import 'package:cloud_firestore/cloud_firestore.dart';

/// Una conversación del agente (subset del doc en AGENTE_CONVERSACIONES).
/// Lo que persiste el bot está en `whatsapp-bot/src/agente.js:_loggear`.
class AgenteChat {
  final String id;
  final DateTime? creadoEn;
  final String rol;
  final String? dni;
  final String? nombre;
  final String? telefono;
  final String pregunta;
  final String respuesta;
  final List<String> toolsUsadas;
  final String? proveedor;
  final String? modelo;
  final String? error;
  final bool esFallback;

  const AgenteChat({
    required this.id,
    required this.creadoEn,
    required this.rol,
    required this.dni,
    required this.nombre,
    required this.telefono,
    required this.pregunta,
    required this.respuesta,
    required this.toolsUsadas,
    required this.proveedor,
    required this.modelo,
    required this.error,
    required this.esFallback,
  });

  factory AgenteChat.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    return AgenteChat(
      id: doc.id,
      creadoEn: (m['creado_en'] as Timestamp?)?.toDate(),
      rol: (m['rol'] as String?) ?? '?',
      dni: m['dni'] as String?,
      nombre: m['nombre'] as String?,
      telefono: m['telefono'] as String?,
      pregunta: (m['pregunta'] as String?) ?? '',
      respuesta: (m['respuesta'] as String?) ?? '',
      toolsUsadas: ((m['tools_usadas'] as List?) ?? const []).cast<String>(),
      proveedor: m['proveedor'] as String?,
      modelo: m['modelo'] as String?,
      error: m['error'] as String?,
      esFallback: m['es_fallback'] as bool? ?? false,
    );
  }

  bool get tieneProblema => esFallback || (error != null && error!.isNotEmpty);
}

/// Agregados del dashboard del agente. Calculados client-side sobre la lista
/// que devuelve `streamUltimos` — para 7 días son ~100-200 docs, perf trivial.
class AgenteKpis {
  final int total;
  final int fallbacks;
  final int errores;
  final Map<String, int> porRol;
  final Map<String, int> porTool;
  final Map<String, int> porError; // top N errores agrupados (HTTP code)
  final double tasaExitoPct; // 0-100

  const AgenteKpis({
    required this.total,
    required this.fallbacks,
    required this.errores,
    required this.porRol,
    required this.porTool,
    required this.porError,
    required this.tasaExitoPct,
  });

  static const vacio = AgenteKpis(
    total: 0,
    fallbacks: 0,
    errores: 0,
    porRol: {},
    porTool: {},
    porError: {},
    tasaExitoPct: 100,
  );

  factory AgenteKpis.calcular(List<AgenteChat> chats) {
    if (chats.isEmpty) return vacio;
    final porRol = <String, int>{};
    final porTool = <String, int>{};
    final porError = <String, int>{};
    int fb = 0;
    int err = 0;
    for (final c in chats) {
      porRol.update(c.rol, (v) => v + 1, ifAbsent: () => 1);
      for (final t in c.toolsUsadas) {
        porTool.update(t, (v) => v + 1, ifAbsent: () => 1);
      }
      if (c.esFallback) fb++;
      if (c.error != null && c.error!.isNotEmpty) {
        err++;
        // Agrupa errores por marca (HTTP code o keyword), no por mensaje
        // completo: si no, casi todos son únicos por el detail del error.
        final marca = _marcaDeError(c.error!);
        porError.update(marca, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    final probl = chats.where((c) => c.tieneProblema).length;
    final tasa = chats.isEmpty ? 100.0 : (chats.length - probl) * 100.0 / chats.length;
    return AgenteKpis(
      total: chats.length,
      fallbacks: fb,
      errores: err,
      porRol: porRol,
      porTool: porTool,
      porError: porError,
      tasaExitoPct: tasa,
    );
  }

  static String _marcaDeError(String err) {
    final lower = err.toLowerCase();
    if (lower.startsWith('http 429') || lower.contains('rate') ||
        lower.contains('quota') || lower.contains('exhausted')) {
      return 'rate_limit_429';
    }
    if (lower.startsWith('http 5')) return 'http_5xx';
    if (lower.startsWith('http 4')) return 'http_4xx';
    if (lower.contains('safety') || lower.contains('blocklist') ||
        lower.contains('prohibited') || lower.contains('recitation')) {
      return 'safety_block';
    }
    if (lower == 'sin_texto' || lower.contains('sin_texto')) return 'sin_texto';
    if (lower.contains('max_tokens') || lower.contains('max_tool_iters')) {
      return 'max_iters';
    }
    return 'otro';
  }
}

/// Lectura de AGENTE_CONVERSACIONES para el dashboard.
class AgenteConversacionesService {
  AgenteConversacionesService._();

  static const String _col = 'AGENTE_CONVERSACIONES';

  /// Stream de los últimos N chats (orden desc por creado_en).
  /// Requiere índice único sobre `creado_en DESC` (single-field auto).
  static Stream<List<AgenteChat>> streamUltimos({int limit = 200}) {
    return FirebaseFirestore.instance
        .collection(_col)
        .orderBy('creado_en', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(AgenteChat.fromDoc).toList());
  }

  /// Filtra una lista ya cargada al rango temporal pedido.
  static List<AgenteChat> filtrarPorDias(
      List<AgenteChat> todos, int dias) {
    final corte = DateTime.now().subtract(Duration(days: dias));
    return todos
        .where((c) => c.creadoEn != null && c.creadoEn!.isAfter(corte))
        .toList();
  }
}
