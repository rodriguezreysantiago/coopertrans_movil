import 'package:cloud_firestore/cloud_firestore.dart';

/// Latido/estado del bot (doc `CACHATORE_ESTADO/bot`). Lo escribe SOLO el
/// bot Python (Admin SDK) cada ~30 s; la app lo lee para mostrar si está
/// vivo y qué está haciendo.
class CachatoreEstadoBot {
  /// idle | latente | agresivo | pausado | (vacío si nunca latió)
  final String modo;

  /// Choferes vigilados / sin turno todavía.
  final int total;
  final int pendientes;

  /// Último latido. Si es viejo (> 2 min) consideramos al bot caído.
  final DateTime? ultimoTickEn;

  const CachatoreEstadoBot({
    this.modo = '',
    this.total = 0,
    this.pendientes = 0,
    this.ultimoTickEn,
  });

  /// `true` si el bot latió hace menos de 2 minutos (está vivo). El bot
  /// late cada ~30 s, así que 2 min cubre varios ciclos perdidos.
  bool get vivo {
    final t = ultimoTickEn;
    if (t == null) return false;
    return DateTime.now().difference(t).inSeconds < 120;
  }

  bool get pausado => modo == 'pausado';

  int get conTurno => (total - pendientes).clamp(0, total);

  factory CachatoreEstadoBot.fromMap(Map<String, dynamic>? d) {
    if (d == null) return const CachatoreEstadoBot();
    return CachatoreEstadoBot(
      modo: (d['modo'] ?? '').toString(),
      total: (d['total'] as num?)?.toInt() ?? 0,
      pendientes: (d['pendientes'] as num?)?.toInt() ?? 0,
      ultimoTickEn: (d['ultimo_tick_en'] as Timestamp?)?.toDate(),
    );
  }
}
