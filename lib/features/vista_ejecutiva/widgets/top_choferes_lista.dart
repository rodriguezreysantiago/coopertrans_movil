// features/vista_ejecutiva/widgets/top_choferes_lista.dart
//
// REFACTOR NÚCLEO · jun 2026 — re-estilizado SIN cambiar la API pública.
//
// Constructor preservado: TopChoferesLista({titulo, icono, colorTitulo,
// items, mensajeVacio}).
//
// CAMBIO INTERNO:
// - Look bento (surface2 + border + radius).
// - Header eyebrow + dot color (no más Icon que distraía).
// - Filas con AppHairline entre cada uno.
// - Rank #1/2/3 en mono tabular, ICM en mono a la derecha con
//   dot semántico según categoria (verde/amarillo/rojo).
// - Sin "más" tile decorativo — sale más limpio.

import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/vista_ejecutiva_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

class TopChoferesLista extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final Color colorTitulo;
  final List<ChoferRankingItem> items;
  final String? mensajeVacio;

  const TopChoferesLista({
    super.key,
    required this.titulo,
    required this.icono,
    required this.colorTitulo,
    required this.items,
    this.mensajeVacio,
  });

  Color _categoriaColor(BuildContext ctx, String cat) {
    final c = ctx.colors;
    switch (cat.toLowerCase()) {
      case 'verde': return c.success;
      case 'amarillo': return c.warning;
      case 'rojo': return c.error;
      default: return c.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ─── Header ───
          Row(
            children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  color: colorTitulo, shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: colorTitulo.withValues(alpha: 0.55), blurRadius: 6),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: AppEyebrow(titulo, color: colorTitulo)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Center(
                child: Text(
                  mensajeVacio ?? 'Sin datos',
                  style: AppType.body.copyWith(color: c.textMuted),
                ),
              ),
            )
          else
            ...List.generate(items.length, (i) {
              final item = items[i];
              return Column(
                children: [
                  if (i > 0) const AppHairline(),
                  _Fila(
                    rank: i + 1,
                    item: item,
                    color: _categoriaColor(context, item.categoria),
                  ),
                ],
              );
            }),
        ],
      ),
    );
  }
}

class _Fila extends StatelessWidget {
  final int rank;
  final ChoferRankingItem item;
  final Color color;
  const _Fila({required this.rank, required this.item, required this.color});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: () => Navigator.pushNamed(
        context,
        AppRoutes.adminIcmDetalleChofer,
        arguments: item.dni,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          children: [
            // Rank
            SizedBox(
              width: 28,
              child: Text(
                '#$rank',
                style: AppType.monoSm.copyWith(
                  color: c.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // Nombre
            Expanded(
              child: Text(
                item.nombre,
                style: AppType.body.copyWith(color: c.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // ICM con dot
            Container(
              width: 6, height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              item.icm.toStringAsFixed(1),
              style: AppType.mono.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
