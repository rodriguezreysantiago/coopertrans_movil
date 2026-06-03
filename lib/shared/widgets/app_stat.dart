// REFACTOR NÚCLEO · jun 2026
//
// AppStat + AppKpiStrip + AppSparkline — los gestos data-first del sistema.
//
// AppStat:        un KPI individual (label + número grande + delta + sparkline opcional)
// AppKpiStrip:    una fila de N AppStat con separadores entre ellos
// AppSparkline:   mini línea de tendencia (CustomPainter, sin fl_chart)
//
// Para gráficos grandes (area, barras, donut) seguir usando fl_chart envuelto
// en un AppCard. Estos son los mini-elementos in-line.

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../../core/theme/app_typography.dart';

class AppStat extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final String? delta;
  final Color? deltaColor;
  final List<double>? spark;
  final Color? sparkColor;
  final TextStyle? valueStyle;
  final Color? accent;

  const AppStat({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.delta,
    this.deltaColor,
    this.spark,
    this.sparkColor,
    this.valueStyle,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final vStyle = (valueStyle ?? AppType.h2).copyWith(
      color: accent ?? c.text,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label.toUpperCase(), style: AppType.eyebrow.copyWith(color: c.textMuted)),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value, style: vStyle),
            if (unit != null) ...[
              const SizedBox(width: 4),
              Text(unit!, style: AppType.monoSm.copyWith(color: c.textMuted)),
            ],
          ],
        ),
        if (delta != null || spark != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              if (delta != null)
                Text(delta!, style: AppType.mono.copyWith(
                  fontSize: 11, color: deltaColor ?? c.textMuted, fontWeight: FontWeight.w500,
                )),
              const Spacer(),
              if (spark != null)
                Opacity(
                  opacity: 0.7,
                  child: AppSparkline(data: spark!, color: sparkColor ?? deltaColor ?? c.brand),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Strip horizontal de N AppStat separados por hairlines verticales,
/// envuelto en una superficie surface2 + border. Usar para dashboards
/// y headers de detail page.
class AppKpiStrip extends StatelessWidget {
  final List<AppStat> stats;
  const AppKpiStrip({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            for (var i = 0; i < stats.length; i++) ...[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
                  child: stats[i],
                ),
              ),
              if (i < stats.length - 1)
                Container(width: 1, color: c.border),
            ],
          ],
        ),
      ),
    );
  }
}

/// Mini sparkline. Sin ejes, sin labels — solo la línea. Usar dentro de
/// AppStat o de cualquier card chica.
class AppSparkline extends StatelessWidget {
  final List<double> data;
  final Color color;
  final double width;
  final double height;
  final double strokeWidth;
  final bool filled;

  const AppSparkline({
    super.key,
    required this.data,
    required this.color,
    this.width = 90,
    this.height = 22,
    this.strokeWidth = 1.4,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _SparkPainter(data: data, color: color, strokeWidth: strokeWidth, filled: filled),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> data;
  final Color color;
  final double strokeWidth;
  final bool filled;
  _SparkPainter({required this.data, required this.color, required this.strokeWidth, required this.filled});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final max = data.reduce((a, b) => a > b ? a : b);
    final min = data.reduce((a, b) => a < b ? a : b);
    final range = (max - min).abs() < 0.0001 ? 1.0 : max - min;
    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - ((data[i] - min) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    if (filled) {
      final fillPath = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      final fill = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.32), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size);
      canvas.drawPath(fillPath, fill);
    }
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.data != data || old.color != color;
}
