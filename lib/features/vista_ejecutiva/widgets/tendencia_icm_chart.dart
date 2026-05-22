// Gráfico de línea para la tendencia del ICM promedio de la flota.
// Misma estética que el del módulo ICM (icm_reporte_semanal_screen)
// para coherencia visual — diferencia: aquí mostramos 12 puntos
// (vs 12 también allá), pero más compacto porque va al lado de otros
// elementos del tablero.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/vista_ejecutiva_service.dart';

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
    // ICM oficial de la flota día por día (más bajo = mejor). Necesitamos ≥ 2
    // días con dato para que la línea tenga sentido (al arrancar el mes puede
    // haber 0-1). Nota: un día perfecto da ICM 0 legítimamente, así que
    // contamos puntos, no valor > 0.
    final mostrarChart = puntos.length >= 2;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.trending_up,
                  color: AppColors.accentTeal, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  titulo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: mostrarChart
                ? _buildChart(context)
                : const Center(
                    child: Text(
                      'Tendencia diaria en construcción\n'
                      '(aún no hay días con actividad este mes)',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildChart(BuildContext context) {
    final spots = <FlSpot>[];
    var maxVal = 0.0;
    for (var i = 0; i < puntos.length; i++) {
      spots.add(FlSpot(i.toDouble(), puntos[i].valor));
      if (puntos[i].valor > maxVal) maxVal = puntos[i].valor;
    }
    // Escala dinámica: el ICM oficial de la flota es bajo (~20), no 0-100.
    final maxY = maxVal <= 0 ? 40.0 : (maxVal * 1.3).ceilToDouble();
    final intervalo = maxY <= 50 ? 10.0 : 20.0;
    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          horizontalInterval: intervalo,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (v) => FlLine(
            color: Colors.white.withValues(alpha: 0.05),
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: intervalo,
              reservedSize: 28,
              getTitlesWidget: (v, m) => Text(
                v.toInt().toString(),
                style:
                    const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              reservedSize: 22,
              getTitlesWidget: (v, m) {
                final idx = v.toInt();
                if (idx < 0 || idx >= puntos.length) {
                  return const SizedBox.shrink();
                }
                // Con muchos puntos (días del mes) no saturar el eje: ~6
                // labels máximo + siempre el último.
                final cada = (puntos.length / 6).ceil();
                if (cada > 1 &&
                    idx % cada != 0 &&
                    idx != puntos.length - 1) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    puntos[idx].label,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 9),
                  ),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border(
            left: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            bottom:
                BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            color: AppColors.accentTeal,
            barWidth: 3,
            isCurved: true,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
                radius: 3.5,
                // Color neutro: la flota no tiene banda de color oficial,
                // así que no inventamos umbrales (igual que la card).
                color: AppColors.accentTeal,
                strokeColor: Colors.white,
                strokeWidth: 1,
              ),
            ),
            belowBarData: BarAreaData(
              show: true,
              color: AppColors.accentTeal.withValues(alpha: 0.12),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) =>
                Colors.black.withValues(alpha: 0.85),
            getTooltipItems: (touches) => touches.map((s) {
              final p = puntos[s.x.toInt()];
              return LineTooltipItem(
                'Día ${p.label}\nICM ${p.valor.toStringAsFixed(1)}',
                const TextStyle(color: Colors.white, fontSize: 11),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}
