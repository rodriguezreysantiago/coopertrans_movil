// features/vista_ejecutiva/widgets/viajes_semanales_chart.dart
//
// REFACTOR NÚCLEO · jun 2026 — re-estilizado SIN cambiar la API pública.
//
// Constructor preservado: ViajesSemanalesChart({puntos, titulo}).
//
// CAMBIO INTERNO:
// - Look bento Núcleo: surface2 + border hairline + eyebrow uppercase.
// - Header: eyebrow + valor hero (último punto) + variación inline.
// - Barras: brand opaco para la última semana, brand soft para las
//   anteriores. Grid lines hairline en c.border.
// - Sin Icon arriba del título — el icono distraía del contenido.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/vista_ejecutiva_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

class ViajesSemanalesChart extends StatelessWidget {
  final List<PuntoTendencia> puntos;
  final String titulo;

  const ViajesSemanalesChart({
    super.key,
    required this.puntos,
    this.titulo = 'Viajes por semana',
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hayDatos = puntos.any((p) => p.valor > 0);
    final last = puntos.isNotEmpty ? puntos.last.valor : 0.0;
    final prev = puntos.length >= 2 ? puntos[puntos.length - 2].valor : 0.0;
    final delta = prev == 0 ? null : ((last - prev) / prev * 100);
    final deltaTexto = delta == null
        ? null
        : (delta >= 0
            ? '+${delta.toStringAsFixed(0)}%'
            : '${delta.toStringAsFixed(0)}%');
    final maxValor = puntos.fold<double>(
      0,
      (acc, p) => p.valor > acc ? p.valor : acc,
    );
    final avg = puntos.isEmpty
        ? 0
        : puntos.fold<double>(0, (acc, p) => acc + p.valor) / puntos.length;

    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ─── Header ───
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: AppEyebrow(titulo)),
              if (puntos.isNotEmpty)
                Text(
                  'min ${maxValor == 0 ? "—" : _minVal(puntos).toStringAsFixed(0)} · '
                  'avg ${avg.toStringAsFixed(0)} · '
                  'max ${maxValor.toStringAsFixed(0)}',
                  style: AppType.monoSm.copyWith(
                    color: c.textMuted, fontSize: 10,
                  ),
                ),
            ],
          ),
          if (hayDatos) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  last.toStringAsFixed(0),
                  style: AppType.h1.copyWith(
                    color: c.text,
                    fontSize: 44,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (deltaTexto != null) ...[
                  const SizedBox(width: AppSpacing.md),
                  Text(
                    deltaTexto,
                    style: AppType.mono.copyWith(
                      color: (delta ?? 0) >= 0 ? c.success : c.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            height: 150,
            child: hayDatos
                ? _buildChart(context)
                : Center(
                    child: Text(
                      'Sin viajes cargados en el período',
                      style: AppType.body.copyWith(color: c.textMuted),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  double _minVal(List<PuntoTendencia> ps) =>
      ps.fold<double>(double.infinity, (acc, p) => p.valor < acc ? p.valor : acc);

  Widget _buildChart(BuildContext context) {
    final c = context.colors;
    final maxValor = puntos.fold<double>(
      0,
      (acc, p) => p.valor > acc ? p.valor : acc,
    );
    final maxY = maxValor < 5 ? 5.0 : (maxValor * 1.15).ceilToDouble();
    final interval = (maxY / 4).ceilToDouble();

    return BarChart(
      BarChartData(
        maxY: maxY,
        minY: 0,
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          horizontalInterval: interval,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(
            color: c.border, strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: interval,
              getTitlesWidget: (value, _) => Text(
                value.toInt().toString(),
                style: AppType.monoSm.copyWith(color: c.textMuted, fontSize: 9),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (value, _) {
                final i = value.toInt();
                if (i < 0 || i >= puntos.length) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    puntos[i].label,
                    style: AppType.monoSm.copyWith(color: c.textMuted, fontSize: 9),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < puntos.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: puntos[i].valor,
                  // último punto destacado en brand, el resto soft
                  color: i == puntos.length - 1 ? c.brand : c.brand.withValues(alpha: 0.4),
                  width: 14,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
