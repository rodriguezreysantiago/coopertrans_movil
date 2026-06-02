// lib/shared/widgets/app_service_card.dart
//
// REFACTOR NÚCLEO · jun 2026 — widget compartido para servicios externos.
//
// Pensado para el ESTADO de cualquier servicio externo que la app
// orquesta (Bot WhatsApp, Cachatore, Sitrack, Volvo API, iTurnos). Antes
// cada pantalla pintaba su propia card → tamaños y íconos distintos →
// quejas del cliente ("se ven como features sueltas").
//
// Composable: el header + status badge + subtitle vienen "gratis"; el
// resto del contenido (KPIs internos, controles, logs) va en `children`.
//
// USO:
//   AppServiceCard(
//     name: 'Bot WhatsApp',
//     subtitle: 'pulso · 12s · 6 destinos',
//     status: AppServiceStatus.ok('OK'),
//     icon: Icons.smart_toy_outlined,
//     onTap: () => Navigator.pushNamed(ctx, AppRoutes.adminEstadoBot),
//     children: [
//       AppKpiStrip(stats: [...]),
//       // ... cualquier otra cosa
//     ],
//   );

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import 'app_card.dart';

/// Estado discreto de un servicio externo. Construir con los factory
/// `ok` / `warning` / `error` / `idle` para forzar consistencia visual.
class AppServiceStatus {
  final String label;
  final Color color;
  final bool glow;

  const AppServiceStatus._(this.label, this.color, this.glow);

  static AppServiceStatus ok(String label, {Color? color}) =>
      AppServiceStatus._(label, color ?? const Color(0xFF4ADE80), true);

  static AppServiceStatus warning(String label, {Color? color}) =>
      AppServiceStatus._(label, color ?? const Color(0xFFFBBF24), false);

  static AppServiceStatus error(String label, {Color? color}) =>
      AppServiceStatus._(label, color ?? const Color(0xFFFB7185), false);

  static AppServiceStatus idle(String label, {Color? color}) =>
      AppServiceStatus._(label, color ?? const Color(0x66FAFAFA), false);
}

class AppServiceCard extends StatelessWidget {
  /// Nombre visible del servicio.
  final String name;

  /// Subtítulo corto (pulso · 12s, lag · 6 min, etc.). Estilo mono.
  final String subtitle;

  /// Status visible a la derecha del header. Para servicios que no
  /// reportan estado en vivo, pasar `AppServiceStatus.idle('SIN DATO')`.
  final AppServiceStatus status;

  /// Ícono del servicio. Para mantener consistencia visual, **siempre
  /// pasar la variante `_outlined`** (el toggle a sólido lo hace el
  /// shell al navegar, no esta card).
  final IconData icon;

  /// Si el card es navegable, callback al tap.
  final VoidCallback? onTap;

  /// Contenido extra debajo del header. Una `Column`/`Row` con los KPIs
  /// del servicio, botones de control, logs, etc.
  final List<Widget> children;

  /// Si `true`, agrega un AppAmbient glow del color de status detrás de
  /// la card. Reservado para vista hero (1 sola por pantalla).
  final bool glow;

  const AppServiceCard({
    super.key,
    required this.name,
    required this.subtitle,
    required this.status,
    required this.icon,
    this.onTap,
    this.children = const [],
    this.glow = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 2,
      onTap: onTap,
      glow: glow,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ───────────── Header ─────────────
          Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: c.surface3,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(icon, size: 18, color: c.brand),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: AppType.h5.copyWith(color: c.text),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _StatusPill(status: status),
            ],
          ),
          if (children.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            ...children,
          ],
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final AppServiceStatus status;
  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              color: status.color,
              shape: BoxShape.circle,
              boxShadow: status.glow
                  ? [BoxShadow(color: status.color.withValues(alpha: 0.55), blurRadius: 6)]
                  : null,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            status.label.toUpperCase(),
            style: AppType.monoSm.copyWith(
              color: status.color,
              fontWeight: FontWeight.w600,
              fontSize: 10,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// Atajo: fila densa de varios AppServiceCard. Lo usual: usar este en
/// el bloque "Servicios externos" del admin dashboard.
class AppServiceGrid extends StatelessWidget {
  final List<AppServiceCard> services;
  final int columnsDesktop;
  final int columnsMobile;

  const AppServiceGrid({
    super.key,
    required this.services,
    this.columnsDesktop = 2,
    this.columnsMobile = 1,
  });

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final cols = w >= 800 ? columnsDesktop : columnsMobile;
    return LayoutBuilder(builder: (_, box) {
      const gap = AppSpacing.mdDense;
      final itemW = (box.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: services
            .map((s) => SizedBox(width: itemW, child: s))
            .toList(),
      );
    });
  }
}
