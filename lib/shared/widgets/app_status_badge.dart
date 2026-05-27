import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// Estado semántico de un componente "live" (bot, cron, sync, servicio
/// externo).
enum AppStatusKind {
  /// Operativo — verde lleno, sin badge numérico salvo que [count] > 0.
  ok,

  /// Atención — naranja. Cola con N pendientes pero el servicio anda.
  warning,

  /// Caído / error crítico — rojo con "!".
  critical,

  /// Desconocido / cargando — gris.
  unknown,
}

/// Badge circular pequeño para superponer sobre un icono — REFACTOR
/// 2026-05-24. Generalización del patrón del WhatsApp-bot tile.
///
/// **Cuándo usarlo:** sobre cualquier icono o tile que represente un
/// componente "vivo" (WhatsApp bot, Cachatore, Volvo sync, Sitrack sync).
/// Permite ver el estado a un golpe de vista sin entrar.
///
/// **Reglas:**
/// - Si [kind] == ok y [count] == 0 → no se renderiza nada (no aparece
///   badge). Estado "feliz" es ausencia visual.
/// - Si [kind] == ok y [count] > 0 → punto verde con número (típico
///   contador de "novedades" o "mensajes enviados hoy").
/// - Si [kind] == warning y [count] > 0 → naranja con número.
/// - Si [kind] == critical → siempre se renderiza, aunque count == 0,
///   con "!" o con el número si vino.
///
/// Uso:
/// ```dart
/// Stack(clipBehavior: Clip.none, children: [
///   _miIcono,
///   Positioned(top: -4, right: -4, child: AppStatusBadge(...)),
/// ])
/// ```
class AppStatusBadge extends StatelessWidget {
  final AppStatusKind kind;
  final int count;

  /// Color del borde del badge — usualmente igual al fondo del scaffold
  /// para "recortar" el badge limpio. Default: [AppColors.surface0].
  final Color borderColor;

  const AppStatusBadge({
    super.key,
    required this.kind,
    this.count = 0,
    this.borderColor = AppColors.surface0,
  });

  /// Helper para el caso heartbeat — recibe `lastBeat` y la ventana,
  /// y elige `critical` si el heartbeat está caído.
  factory AppStatusBadge.fromHeartbeat({
    Key? key,
    required DateTime? lastBeat,
    required Duration deadline,
    int queuedErrors = 0,
    Color borderColor = AppColors.surface0,
  }) {
    final caido = lastBeat == null ||
        DateTime.now().difference(lastBeat) > deadline;
    if (caido) {
      return AppStatusBadge(
        key: key,
        kind: AppStatusKind.critical,
        count: 0,
        borderColor: borderColor,
      );
    }
    if (queuedErrors > 0) {
      return AppStatusBadge(
        key: key,
        kind: AppStatusKind.warning,
        count: queuedErrors,
        borderColor: borderColor,
      );
    }
    return AppStatusBadge(
      key: key,
      kind: AppStatusKind.ok,
      count: 0,
      borderColor: borderColor,
    );
  }

  Color _color() {
    switch (kind) {
      case AppStatusKind.ok:
        return AppColors.success;
      case AppStatusKind.warning:
        return AppColors.warning;
      case AppStatusKind.critical:
        return AppColors.error;
      case AppStatusKind.unknown:
        return AppColors.textTertiary;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Estado "feliz silencioso" — no renderiza.
    if (kind == AppStatusKind.ok && count <= 0) {
      return const SizedBox.shrink();
    }
    final color = _color();
    final texto = kind == AppStatusKind.critical && count == 0
        ? '!'
        : (count > 99 ? '99+' : '$count');

    return Container(
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Text(
        texto,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          height: 1.2,
        ),
      ),
    );
  }
}
