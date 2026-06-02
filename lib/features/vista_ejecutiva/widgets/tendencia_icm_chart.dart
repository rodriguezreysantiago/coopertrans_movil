// features/vista_ejecutiva/widgets/tendencia_icm_chart.dart
//
// REFACTOR NÚCLEO · jun 2026 — re-estilizado SIN cambiar la API pública.
//
// Constructor preservado: TendenciaIcmChart({puntos, titulo}).
//
// CAMBIO INTERNO:
// - Look bento Núcleo (surface2 + border hairline).
// - Línea brand 2px + área degradé brand → transparente.
// - Dots blancos con border brand, solo cada N puntos para no saturar.
// - Grid lines hairline en c.border, mono labels.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/vista_ejecutiva_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

class TendenciaIcmChart extends StatelessWidget {
  final List<PuntoTendencia> puntos;
  final String titulo;

  const TendenciaIcmChart({
    super.key,
    required this.puntos,
    this.titulo = 'ICM oficial · por día',
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mostrarChart = puntos.length >= 2;
    final last = puntos.isNotEmpty ? puntos.last.valor : 0.0;
    final maxV = puntos.fold<double>(0, (a, p) => p.valor > a ? p.valor : a);
    final minV = puntos.fold<double>(
        double.infinity, (a, p) => p.valor < a ? p.valor : a);
    final range = (maxV - minV).abs() < 0.0001 ? 1.0 : (maxV - minV) * 1.2;
    final maxY = (maxV + range * 0.1);
    final minY = (minV - range * 0.1).clamp(0, double.infinity);

    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: AppEyebrow(titulo)),
              if (mostrarChart)
                Text(
                  'min ${minV.toStringAsFixed(1)} · max ${maxV.toStringAsFixed(1)}',
                  style: AppType.monoSm.copyWith(color: c.textMuted, fontSize: 10),
                ),
            ],
          ),
          if (mostrarChart) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              last.toStringAsFixed(1),
              style: AppType.h1.copyWith(
                color: c.text, fontSize: 44,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            height: 150,
            child: mostrarChart
                ? _buildChart(context, minY: minY.toDouble(), maxY: maxY)
                : Center(
                    child: Text(
                      'Datos insuficientes — esperando segundo día',
                      style: AppType.body.copyWith(color: c.textMuted),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildChart(BuildContext context, {required double minY, required double maxY}) {
    final c = context.colors;
    final spots = <FlSpot>[];
    for (var i = 0; i < puntos.length; i++) {
      spots.add(FlSpot(i.toDouble(), puntos[i].valor));
    }
    final labelEvery = (puntos.length / 6).ceil().clamp(1, 999);

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: ((maxY - minY) / 4).abs(),
          getDrawingHorizontalLine: (_) => FlLine(color: c.border, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: ((maxY - minY) / 4).abs(),
              getTitlesWidget: (value, _) => Text(
                value.toStringAsFixed(0),
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
                if (i % labelEvery != 0) return const SizedBox();
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
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            color: c.brand,
            barWidth: 2,
            dotData: FlDotData(
              show: true,
              checkToShowDot: (spot, _) {
                return spot.x.toInt() % labelEvery == 0 ||
                       spot.x.toInt() == puntos.length - 1;
              },
              getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(
                radius: 3,
                color: c.bg,
                strokeWidth: 1.5,
                strokeColor: c.brand,
              ),
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [
                  c.brand.withValues(alpha: 0.25),
                  c.brand.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
