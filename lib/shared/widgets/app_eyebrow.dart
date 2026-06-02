// handoff/lib/shared/widgets/app_eyebrow.dart
//
// REFACTOR NÚCLEO · jun 2026
//
// AppEyebrow — etiqueta uppercase/mono que precede a una sección o card.
// Una por bloque visual. Usar `context.colors.textMuted` (default) o
// pasar `color` para indicar carga semántica (ej rojo para "Urgente").

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../../core/theme/app_typography.dart';

class AppEyebrow extends StatelessWidget {
  final String text;
  final Color? color;
  final TextStyle? styleOverride;

  const AppEyebrow(
    this.text, {
    super.key,
    this.color,
    this.styleOverride,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.colors.textMuted;
    return Text(
      text.toUpperCase(),
      style: (styleOverride ?? AppType.eyebrow).copyWith(color: c),
    );
  }
}

/// AppDot — punto de estado semántico. Con `glow: true` adopta el efecto
/// firma del sistema (sombra del color brand alrededor).
class AppDot extends StatelessWidget {
  final Color color;
  final double size;
  final bool glow;

  const AppDot(this.color, {super.key, this.size = 8, this.glow = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: glow
            ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8, spreadRadius: 0)]
            : null,
      ),
    );
  }
}

/// AppHairline — separador 1px usando `context.colors.border`.
class AppHairline extends StatelessWidget {
  final bool vertical;
  final Color? color;
  const AppHairline({super.key, this.vertical = false, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.colors.border;
    return Container(
      width: vertical ? 1 : double.infinity,
      height: vertical ? double.infinity : 1,
      color: c,
    );
  }
}
