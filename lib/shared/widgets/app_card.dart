// lib/shared/widgets/app_card.dart
//
// REFACTOR NÚCLEO · jun 2026 — superficie bento.
//   1. AppCard()              — neutra, border subtle
//   2. AppCard(accent: ...)   — borde izquierdo de color semántico (3px)
//   3. AppCard(glow: true)    — ambient glow del brand en la esquina (signature)
//
// SHIM RETROCOMPAT: acepta también la API 2026-05-24 (`margin`, `borderColor`,
// `highlighted`, `tier` 1/2/3, `borderRadius`) para no romper los call-sites.

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../../core/theme/app_radius.dart';

class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? accent;
  final bool glow;
  final double radius;
  final VoidCallback? onTap;
  final bool clip;

  // Compat 2026-05-24
  final EdgeInsetsGeometry margin;
  final Color? borderColor;
  final bool highlighted;
  final int tier; // 1 = lista, 2 = card default, 3 = elevada
  final double? borderRadius;

  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.accent,
    this.glow = false,
    this.radius = AppRadius.xl,
    this.onTap,
    this.clip = true,
    this.margin = const EdgeInsets.symmetric(vertical: 4),
    this.borderColor,
    this.highlighted = false,
    this.tier = 2,
    this.borderRadius,
  });

  Color _surface(AppColorsExt c) {
    switch (tier) {
      case 1:
        return c.surface1;
      case 3:
        return c.surface3;
      default:
        return c.surface2;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = borderRadius ?? radius;
    final br = BorderRadius.circular(r);
    final baseBorder = borderColor ?? (highlighted ? c.brand : c.border);

    Widget inner = Container(
      padding: padding ?? const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _surface(c),
        borderRadius: br,
        border: Border(
          top: BorderSide(color: baseBorder),
          right: BorderSide(color: baseBorder),
          bottom: BorderSide(color: baseBorder),
          left: accent != null
              ? BorderSide(color: accent!, width: 3)
              : BorderSide(color: baseBorder),
        ),
      ),
      // Material(transparency) entre el fondo (este DecoratedBox con color) y
      // el child: sin él, cualquier ListTile/InkWell dentro de un AppCard
      // dispara el assert de Flutter 3.44 "background color or ink splashes may
      // be invisible" (Sentry FLUTTER-27). Es debug-only (no afecta release)
      // pero ensucia consola/Sentry. Material transparente no pinta ni cambia
      // layout — solo provee el canvas de ink correcto.
      child: Material(type: MaterialType.transparency, child: child),
    );

    if (glow) {
      inner = Stack(
        children: [
          Positioned(
            top: -50,
            right: -50,
            child: IgnorePointer(
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [c.brandGlow, c.brandGlow.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
          ),
          inner,
        ],
      );
    }

    if (clip) inner = ClipRRect(borderRadius: br, child: inner);
    if (onTap != null) {
      inner = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: br,
          highlightColor: c.surfaceHover.withValues(alpha: 0.5),
          child: inner,
        ),
      );
    }

    return Container(margin: margin, child: inner);
  }
}
