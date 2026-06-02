// handoff/lib/shared/widgets/app_card.dart
//
// REFACTOR NÚCLEO · jun 2026
//
// AppCard — superficie bento del sistema. Tres variantes:
//   1. AppCard()              — neutra, border subtle
//   2. AppCard(accent: ...)   — borde izquierdo de color semántico (3px)
//   3. AppCard(glow: true)    — ambient glow del brand en la esquina (signature)
//
// El radius es xl (12) por convención. Para modales/sheets usar xxl (16).

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';

class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? accent;
  final bool glow;
  final double radius;
  final VoidCallback? onTap;
  final bool clip;

  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.accent,
    this.glow = false,
    this.radius = AppRadius.xl,
    this.onTap,
    this.clip = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final br = BorderRadius.circular(radius);

    Widget inner = Container(
      padding: padding ?? const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: br,
        border: Border(
          top:    BorderSide(color: c.border),
          right:  BorderSide(color: c.border),
          bottom: BorderSide(color: c.border),
          left:   accent != null
              ? BorderSide(color: accent!, width: 3)
              : BorderSide(color: c.border),
        ),
      ),
      child: child,
    );

    if (glow) {
      inner = Stack(
        children: [
          // ambient glow esquina sup-derecha
          Positioned(
            top: -50, right: -50,
            child: IgnorePointer(
              child: Container(
                width: 220, height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [c.brandGlow, c.brandGlow.withOpacity(0)],
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
          highlightColor: c.surfaceHover.withOpacity(0.5),
          child: inner,
        ),
      );
    }
    return inner;
  }
}
