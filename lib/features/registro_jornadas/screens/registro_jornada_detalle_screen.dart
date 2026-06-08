import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/registro_jornada.dart';

/// Detalle visual de un turno del registro v3. Muestra hero, KPIs, gráfico
/// velocidad/tiempo, tramos de manejo (con km/vel) y paradas con motivo +
/// duración + chip de "cierra bloque" cuando aplica.
///
/// Se entra desde la lista de `AdminRegistroJornadaScreen` (tap en una
/// `RegistroJornadaCard`). Solo lectura — toda la métrica está precomputada
/// por la CF `registrarJornadasV3Diario`; esta pantalla NO calcula nada.
class RegistroJornadaDetalleScreen extends StatelessWidget {
  final RegistroJornada jornada;
  final String? choferNombre;

  const RegistroJornadaDetalleScreen({
    super.key,
    required this.jornada,
    this.choferNombre,
  });

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Jornada — ${choferNombre ?? jornada.choferDni}',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        children: [
          _Hero(j: jornada),
          const SizedBox(height: AppSpacing.mdDense),
          _KpiStrip(j: jornada),
          const SizedBox(height: AppSpacing.mdDense),
          _GraficoVelocidad(j: jornada),
          const SizedBox(height: AppSpacing.mdDense),
          _SeccionTramos(j: jornada),
          const SizedBox(height: AppSpacing.mdDense),
          _SeccionParadas(j: jornada),
          if (jornada.explicacion.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.mdDense),
            _SeccionExplicacion(lineas: jornada.explicacion),
          ],
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// HERO · eyebrow JORNADA · fecha · patente · turno · confianza
// ────────────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final RegistroJornada j;
  const _Hero({required this.j});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppEyebrow('JORNADA · REGISTRO V3'),
              const Spacer(),
              AppBadge(
                text: 'Datos ${j.confianza}',
                color: _confColor(c, j.confianza),
                size: AppBadgeSize.sm,
                dot: true,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            _fmtFechaLarga(j.fecha, j.inicioTurno),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppType.heading,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                '${_hm(j.inicioTurno)} → ${_hm(j.finTurno)}',
                style: AppType.mono.copyWith(color: c.text),
              ),
              if (j.patente != null) ...[
                const SizedBox(width: AppSpacing.md),
                Text('· ${j.patente}',
                    style: AppType.label.copyWith(color: c.textMuted)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// KPI STRIP · manejo / km / pausas / bloques
// ────────────────────────────────────────────────────────────────────────

class _KpiStrip extends StatelessWidget {
  final RegistroJornada j;
  const _KpiStrip({required this.j});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    int velMaxTurno = 0;
    for (final s in j.tramosManejo) {
      if ((s.velMax ?? 0) > velMaxTurno) velMaxTurno = s.velMax!;
    }
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          _kpi(c, 'Manejo', _hmDur(j.manejoNetoSeg)),
          _kpi(c, 'Km', AppFormatters.formatearMiles(j.recorridoKm)),
          _kpi(c, 'Vel máx', '$velMaxTurno km/h'),
          _kpi(c, 'Pausas', '${j.pausas.length}'),
          _kpi(c, 'Bloques', '${j.bloquesCount}'),
        ],
      ),
    );
  }

  Widget _kpi(AppColorsExt c, String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: AppType.eyebrow.copyWith(color: c.textMuted)),
          const SizedBox(height: 4),
          Text(value,
              style: AppType.heading,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// GRÁFICO VELOCIDAD · fl_chart envuelto en AppCard
// ────────────────────────────────────────────────────────────────────────

class _GraficoVelocidad extends StatelessWidget {
  final RegistroJornada j;
  const _GraficoVelocidad({required this.j});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (j.serieVelocidad.length < 2) {
      return AppCard(
        tier: 2,
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppEyebrow('VELOCIDAD'),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Sin serie de velocidad suficiente para graficar.',
              style: AppType.bodySm.copyWith(color: c.textMuted),
            ),
          ],
        ),
      );
    }

    final minTs = j.serieVelocidad.first.tsMs.toDouble();
    final maxTs = j.serieVelocidad.last.tsMs.toDouble();
    final spots = j.serieVelocidad
        .map((p) => FlSpot(p.tsMs.toDouble(), p.speed.toDouble()))
        .toList();
    int velMaxTurno = 0;
    for (final p in j.serieVelocidad) {
      if (p.speed > velMaxTurno) velMaxTurno = p.speed;
    }
    final maxY = (velMaxTurno <= 0 ? 100.0 : (velMaxTurno + 10).ceilToDouble());
    final intervaloX = (maxTs - minTs) / 5;

    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppDot(c.brand, size: 7),
              const SizedBox(width: AppSpacing.sm),
              AppEyebrow('VELOCIDAD', color: c.brand),
              const Spacer(),
              Text('km/h',
                  style: AppType.monoSm.copyWith(color: c.textMuted)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: 200,
            child: LineChart(
              LineChartData(
                minX: minTs,
                maxX: maxTs,
                minY: 0,
                maxY: maxY,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 25,
                  getDrawingHorizontalLine: (v) => FlLine(
                    color: c.border,
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 25,
                      reservedSize: 30,
                      getTitlesWidget: (v, m) => Text(
                        v.toInt().toString(),
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: intervaloX,
                      reservedSize: 22,
                      getTitlesWidget: (v, m) {
                        final d =
                            DateTime.fromMillisecondsSinceEpoch(v.toInt());
                        return Text(
                          _hm(d),
                          style: AppType.monoSm.copyWith(color: c.textMuted),
                        );
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (touchedSpots) => touchedSpots.map((s) {
                      final d =
                          DateTime.fromMillisecondsSinceEpoch(s.x.toInt());
                      return LineTooltipItem(
                        '${_hm(d)}\n${s.y.toStringAsFixed(1)} km/h',
                        AppType.monoSm.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    }).toList(),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: false,
                    color: c.brand,
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          c.brand.withValues(alpha: 0.22),
                          c.brand.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// SECCIÓN · primitiva bento (eyebrow + dot opcional + contenido)
// ────────────────────────────────────────────────────────────────────────

class _Seccion extends StatelessWidget {
  final String titulo;
  final Color? accentDot;
  final Widget? trailing;
  final List<Widget> children;

  const _Seccion({
    required this.titulo,
    this.accentDot,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (accentDot != null) ...[
                AppDot(accentDot!, size: 7),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(child: AppEyebrow(titulo, color: accentDot)),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ...children,
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// TRAMOS DE MANEJO · filas separadas por hairline
// ────────────────────────────────────────────────────────────────────────

class _SeccionTramos extends StatelessWidget {
  final RegistroJornada j;
  const _SeccionTramos({required this.j});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tramos = j.tramosManejo;
    final n = tramos.length;
    return _Seccion(
      titulo: 'TRAMOS DE MANEJO',
      accentDot: c.info,
      trailing: Text('$n',
          style: AppType.monoSm.copyWith(color: c.textMuted)),
      children: [
        if (n == 0)
          Text(
            'Sin tramos de manejo detectados.',
            style: AppType.bodySm.copyWith(color: c.textMuted),
          )
        else
          for (var i = 0; i < n; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: AppSpacing.md),
              const AppHairline(),
              const SizedBox(height: AppSpacing.md),
            ],
            _FilaTramo(t: tramos[i]),
          ],
      ],
    );
  }
}

class _FilaTramo extends StatelessWidget {
  final SegmentoJornada t;
  const _FilaTramo({required this.t});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final km = t.kmAprox ?? 0;
    final velMax = t.velMax ?? 0;
    final velProm = t.velProm ?? 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: AppDot(c.info, size: 6),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_hm(t.inicio)} → ${_hm(t.fin)}',
                      style: AppType.mono.copyWith(color: c.text),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (t.confianza != 'alta')
                    AppBadge(
                      text: t.confianza,
                      color: t.confianza == 'media' ? c.warning : c.error,
                      size: AppBadgeSize.sm,
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${_hmDur(t.durSeg)} · '
                '${km > 0 ? "${AppFormatters.formatearMiles(km)} km · " : ""}'
                'máx $velMax · prom $velProm km/h',
                style: AppType.bodySm.copyWith(color: c.textSecondary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// PARADAS · color semántico (cierra bloque vs corta)
// ────────────────────────────────────────────────────────────────────────

class _SeccionParadas extends StatelessWidget {
  final RegistroJornada j;
  const _SeccionParadas({required this.j});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = j.pausas.length;
    return _Seccion(
      titulo: 'PARADAS',
      accentDot: c.warning,
      trailing: Text('$n',
          style: AppType.monoSm.copyWith(color: c.textMuted)),
      children: [
        if (n == 0)
          Text(
            'Sin paradas reportables entre tramos.',
            style: AppType.bodySm.copyWith(color: c.textMuted),
          )
        else
          for (var i = 0; i < n; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: AppSpacing.md),
              const AppHairline(),
              const SizedBox(height: AppSpacing.md),
            ],
            _FilaParada(p: j.pausas[i]),
          ],
      ],
    );
  }
}

class _FilaParada extends StatelessWidget {
  final PausaJornada p;
  const _FilaParada({required this.p});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Verde si cierra bloque (≥ 15 min); ámbar si es corta. La política
    // de "descanso entre jornadas" se chequea a nivel jornada
    // (descansoInsuficiente) — acá no aplica.
    final color = p.cierraBloque ? c.success : c.warning;
    final hint = p.cierraBloque
        ? 'Corte de bloque (≥ 15 min)'
        : 'Pausa corta (< 15 min)';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: AppDot(color, size: 6),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_hm(p.inicio)} → ${_hm(p.fin)}',
                      style: AppType.mono.copyWith(color: c.text),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (p.confianza != 'alta')
                    AppBadge(
                      text: p.confianza,
                      color: p.confianza == 'media' ? c.warning : c.error,
                      size: AppBadgeSize.sm,
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${_hmDur(p.durSeg)} · ${p.motivo}',
                style: AppType.bodySm.copyWith(color: c.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                hint,
                style: AppType.monoSm.copyWith(color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// EXPLICACIÓN del backend (líneas legibles del registro)
// ────────────────────────────────────────────────────────────────────────

class _SeccionExplicacion extends StatelessWidget {
  final List<String> lineas;
  const _SeccionExplicacion({required this.lineas});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _Seccion(
      titulo: 'NOTAS DEL REGISTRO',
      accentDot: c.textMuted,
      children: [
        for (final l in lineas)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(l,
                style: AppType.bodySm.copyWith(color: c.textSecondary)),
          ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// Helpers de formato locales
// ────────────────────────────────────────────────────────────────────────

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';

String _hmDur(int seg) {
  final h = seg ~/ 3600;
  final m = (seg % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
  return '${m}m';
}

const _dias = [
  'Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo',
];
const _meses = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

String _fmtFechaLarga(String ymd, DateTime fallback) {
  // Caso combinado multi-turno: `ymd` viene como "YYYY-MM-DD → YYYY-MM-DD".
  // No la parseamos — formateamos cada extremo a "dd de mes" y unimos con la
  // flecha, para que el hero diga "6 de junio → 8 de junio".
  if (ymd.contains('→')) {
    final partes = ymd.split('→').map((s) => s.trim()).toList();
    if (partes.length == 2) {
      final a = DateTime.tryParse(partes[0]);
      final b = DateTime.tryParse(partes[1]);
      if (a != null && b != null) {
        final mesA = _meses[(a.month - 1).clamp(0, 11)];
        final mesB = _meses[(b.month - 1).clamp(0, 11)];
        // Si ambos extremos caen en el mismo mes, una sola mención del mes:
        // "6 → 8 de junio". Si no, "6 de junio → 3 de julio".
        if (a.year == b.year && a.month == b.month) {
          return '${a.day} → ${b.day} de $mesA';
        }
        return '${a.day} de $mesA → ${b.day} de $mesB';
      }
    }
    // Si por algún motivo no parsea, devolvemos el rango crudo.
    return ymd;
  }
  DateTime? d = DateTime.tryParse(ymd);
  d ??= fallback;
  final dia = _dias[(d.weekday - 1).clamp(0, 6)];
  final mes = _meses[(d.month - 1).clamp(0, 11)];
  return '$dia ${d.day} de $mes';
}

Color _confColor(AppColorsExt c, String conf) {
  switch (conf) {
    case 'alta':
      return c.success;
    case 'media':
      return c.warning;
    default:
      return c.error;
  }
}
