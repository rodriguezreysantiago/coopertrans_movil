import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';
import '../constants/app_colors.dart';

/// Card unificada — REFACTOR 2026-05-24.
///
/// **Cambios vs. la versión anterior:**
/// - Radius unificado a [AppRadius.lg] (16). Antes: 16 default + algunos
///   sitios pasaban 22 o 25 a mano.
/// - Acepta [tier] para elegir surface (1/2/3) en lugar de hardcodear
///   `colorScheme.surface`. Permite jerarquía visual (card sobre card).
/// - `highlighted` ahora hace un borde **semántico** (brand por default,
///   o se puede pasar otro color). Antes usaba primary del theme.
/// - Padding y margin defaults migrados a [AppSpacing].
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final VoidCallback? onTap;
  final Color? borderColor;
  final double? borderRadius;
  final bool highlighted;

  /// Surface tier (1 = lista, 2 = card default, 3 = elevada sobre card).
  /// Default = 2.
  final int tier;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.margin = const EdgeInsets.symmetric(vertical: AppSpacing.xs),
    this.onTap,
    this.borderColor,
    this.borderRadius,
    this.highlighted = false,
    this.tier = 2,
  });

  Color _surfaceForTier(int t) {
    switch (t) {
      case 1:
        return AppColors.surface1;
      case 3:
        return AppColors.surface3;
      case 2:
      default:
        return AppColors.surface2;
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? AppRadius.lg;
    final surface = _surfaceForTier(tier);
    final defaultBorder = highlighted
        ? (borderColor ?? AppColors.brand)
        : AppColors.borderSubtle;

    final card = Container(
      margin: margin,
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: borderColor ?? defaultBorder,
          width: highlighted ? 1.5 : 1,
        ),
      ),
      child: onTap == null
          ? Padding(padding: padding, child: child)
          : Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(radius),
                onTap: onTap,
                child: Padding(padding: padding, child: child),
              ),
            ),
    );

    return card;
  }
}
