import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';
import '../constants/app_colors.dart';

/// Skeleton placeholders — REFACTOR 2026-05-27.
///
/// Para usar mientras carga un stream o future, en lugar del
/// `CircularProgressIndicator` centrado que el ojo lee como "trabado".
/// Un skeleton con la forma de lo que va a llegar se siente 2× más
/// rápido aunque tarde lo mismo.
///
/// **Tres primitivos:**
///
/// - [AppSkeleton.box] — un rectángulo pulsante para una zona de bloque
///   (KPI card, hero image, banner).
/// - [AppSkeleton.line] — una línea para texto. [widthFactor] del 100%
///   al 30% para simular líneas de párrafo.
/// - [AppSkeleton.circle] — círculo pulsante (avatar, badge).
///
/// **Composición** — para imitar una lista o card, combinás varios:
///
/// ```dart
/// Column(children: [
///   for (int i = 0; i < 6; i++)
///     Padding(
///       padding: const EdgeInsets.symmetric(vertical: 6),
///       child: Row(children: [
///         const AppSkeleton.circle(diameter: 40),
///         const SizedBox(width: 12),
///         Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
///           AppSkeleton.line(widthFactor: 0.6),
///           const SizedBox(height: 6),
///           AppSkeleton.line(widthFactor: 0.4, height: 10),
///         ])),
///       ]),
///     ),
/// ])
/// ```
///
/// **Animación.** Una pulsación suave de opacity 1.0 → 0.5 → 1.0 cada
/// 1.4s. Sin shimmer porque shimmer + flutter web es lento; el pulso
/// se comporta consistente en las 5 plataformas.
///
/// **Nota técnica.** [AppSkeleton.line] es `static Widget` (no factory)
/// porque tiene que envolver en un [LayoutBuilder] para resolver el
/// ancho según el espacio disponible — eso es un widget diferente
/// ([_SkeletonLine]) que internamente usa [AppSkeleton.box].
class AppSkeleton extends StatefulWidget {
  final double width;
  final double height;
  final BoxShape shape;
  final BorderRadius? borderRadius;

  const AppSkeleton._({
    super.key,
    required this.width,
    required this.height,
    this.shape = BoxShape.rectangle,
    this.borderRadius,
  });

  /// Rectángulo redondeado. Default: 16×100% con radius 12.
  const AppSkeleton.box({
    Key? key,
    double width = double.infinity,
    double height = 16,
    double radius = 12,
  }) : this._(
          key: key,
          width: width,
          height: height,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
        );

  /// Línea de texto que resuelve su ancho con LayoutBuilder.
  /// [widthFactor] = fracción del ancho disponible (default 100%).
  /// Es un static, no factory, porque devuelve un widget envoltorio
  /// distinto de [AppSkeleton] (ver doc de la clase).
  static Widget line({
    Key? key,
    double widthFactor = 1.0,
    double height = 12,
  }) {
    return _SkeletonLine(
      key: key,
      widthFactor: widthFactor,
      height: height,
    );
  }

  /// Círculo (avatar). [diameter] = ancho = alto.
  const AppSkeleton.circle({Key? key, double diameter = 40})
      : this._(
          key: key,
          width: diameter,
          height: diameter,
          shape: BoxShape.circle,
        );

  @override
  State<AppSkeleton> createState() => _AppSkeletonState();
}

class _AppSkeletonState extends State<AppSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: AppColors.surface3,
          shape: widget.shape,
          borderRadius:
              widget.shape == BoxShape.rectangle ? widget.borderRadius : null,
        ),
      ),
    );
  }
}

/// Línea con widthFactor — necesita un LayoutBuilder, no es const.
class _SkeletonLine extends StatelessWidget {
  final double widthFactor;
  final double height;
  const _SkeletonLine({
    super.key,
    required this.widthFactor,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final w = constraints.maxWidth.isFinite
            ? constraints.maxWidth * widthFactor.clamp(0.0, 1.0)
            : 120 * widthFactor.clamp(0.0, 1.0);
        return AppSkeleton.box(
          width: w,
          height: height,
          radius: 4,
        );
      },
    );
  }
}

/// Helper para listas: N filas idénticas con avatar + 2 líneas.
class AppSkeletonList extends StatelessWidget {
  final int count;
  final double itemHeight;
  final bool conAvatar;

  const AppSkeletonList({
    super.key,
    this.count = 6,
    this.itemHeight = 64,
    this.conAvatar = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(count, (i) {
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              if (conAvatar) ...[
                const AppSkeleton.circle(diameter: 40),
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppSkeleton.line(widthFactor: 0.55, height: 14),
                    const SizedBox(height: 6),
                    AppSkeleton.line(widthFactor: 0.35, height: 11),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}
