// Gráfico de barras: cantidad de viajes por semana, últimas 8.
// Misma altura que el de tendencia ICM para que el layout
// horizontal quede prolijo (en desktop van uno al lado del otro).

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/vista_ejecutiva_service.dart';

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
    final hayDatos = puntos.any((p) => p.valor > 0);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.local_shipping,
                  color: AppColors.brand, size: 18),
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
            child: hayDatos
                ? _buildChart(context)
                : const Center(
                    child: Text(
                      'Sin viajes cargados en el período',
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
    // Calculamos maxY con un margen del 15% para que las barras más
    // altas no toquen el techo del chart.
    final maxValor = puntos.fold<double>(
      0,
      (acc, p) => p.valor > acc ? p.valor : acc,
    );
    // Mínimo 5 para que cuando hay pocos viajes el grid no se vea raro.
    final maxY = maxValor < 5 ? 5.0 : (maxValor * 1.15).ceilToDouble();
    // Interval de la grilla horizontal: divide el rango en ~4-5 líneas
    // para que se vea limpio.
    final interval =
        maxY <= 10 ? 2.0 : (maxY <= 30 ? 5.0 : (maxY / 5).ceilToDouble());

    return BarChart(
      BarChartData(
        maxY: maxY,
        minY: 0,
        barGroups: [
          for (var i = 0; i < puntos.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: puntos[i].valor,
                  color: puntos[i].valor > 0
                      ? AppColors.brand
                      : Colors.white12,
                  width: 14,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(3),
                  ),
                ),
              ],
            ),
        ],
        gridData: FlGridData(
          show: true,
          horizontalInterval: interval,
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
              interval: interval,
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
              reservedSize: 22,
              getTitlesWidget: (v, m) {
                final idx = v.toInt();
                if (idx < 0 || idx >= puntos.length) {
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
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) =>
                Colors.black.withValues(alpha: 0.85),
            getTooltipItem: (group, _, __, ___) {
              final p = puntos[group.x];
              final n = p.valor.toInt();
              return BarTooltipItem(
                '${p.label}\n$n viaje${n == 1 ? '' : 's'}',
                const TextStyle(color: Colors.white, fontSize: 11),
              );
            },
          ),
        ),
      ),
    );
  }
}
