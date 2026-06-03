import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/volvo_score_diario.dart';
import '../services/eco_driving_service.dart';
import '../widgets/score_drilldown_sheet.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Pantalla "Eco-Driving" del admin/supervisor — REFACTOR NÚCLEO (jun 2026).
///
/// Muestra los scores de eco-driving que pollea diariamente
/// `volvoScoresPoller` desde la Volvo Group Scores API. Reescrita al sistema
/// Núcleo (bento): header `AppEyebrow` + hero number del score de flota,
/// `AppKpiStrip` con métricas operativas reales (km, L/100km, CO₂, utilización),
/// card de sub-scores con hairlines + dots semánticos, y card de ranking por
/// vehículo (badge de score, mono tabular para km/consumo).
///
/// **Semántica del score**: MÁS ALTO = MEJOR (≥80 verde / 60-80 ámbar / <60
/// coral). El consumo (L/100km) se muestra como dato técnico en mono SIN color
/// semántico — la pantalla nunca tuvo un baseline contra el cual decidir si un
/// L/100km es "bueno o malo", así que no se inventa dirección.
///
/// La capa de datos NO cambió: streams `streamFleetEntreFechas` /
/// `streamPorVehiculoEntreFechas`, los promedios en memoria
/// (`_promediar` / `_promConFiltro` / `RankingVehiculo.desdeDocs`), el filtro
/// temporal (7/15/30/60) y la navegación al drill-down quedan intactos.
///
/// Filtro temporal: rango "últimos N días" (default 30, opciones 7/15/30/60).
class AdminEcoDrivingScreen extends StatefulWidget {
  const AdminEcoDrivingScreen({super.key});

  @override
  State<AdminEcoDrivingScreen> createState() => _AdminEcoDrivingScreenState();
}

class _AdminEcoDrivingScreenState extends State<AdminEcoDrivingScreen> {
  final _service = EcoDrivingService();
  int _diasRango = 30;

  // Sub-scores que mostramos en el resumen de flota. Los demás (overrev,
  // gearboxInPowerMode, etc.) quedan ocultos en el resumen pero visibles
  // en el drill-down individual.
  static const _subScoresPrincipales = [
    'anticipation',
    'braking',
    'coasting',
    'engineAndGearUtilization',
    'idling',
    'overspeed',
    'cruiseControl',
    'speedAdaption',
  ];

  DateTime get _desde =>
      DateTime.now().subtract(Duration(days: _diasRango));
  DateTime get _hasta => DateTime.now();

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Eco-Driving',
      actions: [
        PopupMenuButton<int>(
          icon: const Icon(Icons.calendar_today),
          tooltip: 'Rango temporal',
          initialValue: _diasRango,
          onSelected: (v) => setState(() => _diasRango = v),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 7, child: Text('Últimos 7 días')),
            PopupMenuItem(value: 15, child: Text('Últimos 15 días')),
            PopupMenuItem(value: 30, child: Text('Últimos 30 días')),
            PopupMenuItem(value: 60, child: Text('Últimos 60 días')),
          ],
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxl),
        children: [
          _ResumenFleet(
            service: _service,
            desde: _desde,
            hasta: _hasta,
            diasRango: _diasRango,
            subScoresPrincipales: _subScoresPrincipales,
          ),
          const SizedBox(height: AppSpacing.xl),
          _RankingVehiculos(
            service: _service,
            desde: _desde,
            hasta: _hasta,
            diasRango: _diasRango,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// HELPERS DE SEMÁNTICA — color por score (MÁS ALTO = MEJOR).
// =============================================================================

/// Color semántico de un score 0-100: ≥80 verde / 60-80 ámbar / <60 coral.
/// `null` → textMuted (sin data). Centraliza la lógica que antes estaba
/// duplicada en cada widget interno — misma dirección que el original.
Color _colorScore(double? s, AppColorsExt c) {
  if (s == null) return c.textMuted;
  if (s < 60) return c.error;
  if (s < 80) return c.warning;
  return c.success;
}

// =============================================================================
// RESUMEN DE FLOTA — header + hero score + KPI strip + sub-scores.
// =============================================================================

class _ResumenFleet extends StatelessWidget {
  final EcoDrivingService service;
  final DateTime desde;
  final DateTime hasta;
  final int diasRango;
  final List<String> subScoresPrincipales;

  const _ResumenFleet({
    required this.service,
    required this.desde,
    required this.hasta,
    required this.diasRango,
    required this.subScoresPrincipales,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<VolvoScoreDiario>>(
      stream: service.streamFleetEntreFechas(desde: desde, hasta: hasta),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _SkeletonCard(altura: 300);
        }
        if (snap.hasError) {
          return _ErrorCard('No pudimos cargar el resumen', snap.error);
        }
        final docs = snap.data ?? const <VolvoScoreDiario>[];
        if (docs.isEmpty) {
          return const _AvisoCard(
            icono: Icons.eco_outlined,
            titulo: 'Sin data en este rango',
            mensaje: 'El poller diario empezó a correr el día que '
                'se deployó. Si recién se activó, los datos aparecen '
                'en la próxima ventana de las 04:00 ART.',
          );
        }

        // Promediamos en memoria los N días del rango.
        final promedios = _promediar(docs);
        final scoreTotal = promedios['total'];
        final kmTotales = docs.fold<double>(
          0,
          (acc, d) => acc + (d.totalDistanceKm ?? 0),
        );
        final co2Total = docs.fold<double>(
          0,
          (acc, d) => acc + (d.co2Emissions ?? 0),
        );
        final consumoProm = _promConFiltro(
          docs.map((d) => d.fuelLPor100Km).whereType<double>().toList(),
        );
        final utilProm = _promConFiltro(
          docs.map((d) => d.vehicleUtilization).whereType<double>().toList(),
        );
        // Tendencia del score de flota a lo largo del rango (orden cronológico
        // ascendente — el stream viene descendente). Dato real; sólo se dibuja
        // si hay al menos 2 días con score.
        final tendencia = docs.reversed
            .map((d) => d.scoreTotal)
            .whereType<double>()
            .toList(growable: false);

        return _ResumenContenido(
          diasRango: diasRango,
          scoreTotal: scoreTotal,
          tendencia: tendencia,
          kmTotales: kmTotales,
          co2Total: co2Total,
          consumoProm: consumoProm,
          utilProm: utilProm,
          subScores: subScoresPrincipales
              .map((k) => (label: VolvoSubScoreLabels.label(k), score: promedios[k]))
              .toList(growable: false),
        );
      },
    );
  }

  Map<String, double?> _promediar(List<VolvoScoreDiario> docs) {
    final claves = <String>{'total', ...subScoresPrincipales};
    final result = <String, double?>{};
    for (final k in claves) {
      double sum = 0;
      int n = 0;
      for (final d in docs) {
        final v = d.subScores[k];
        if (v != null) {
          sum += v;
          n++;
        }
      }
      result[k] = n > 0 ? sum / n : null;
    }
    return result;
  }

  double? _promConFiltro(List<double> xs) {
    if (xs.isEmpty) return null;
    return xs.reduce((a, b) => a + b) / xs.length;
  }
}

/// Vista pura del resumen de flota (ya con todo calculado). Separada del
/// StreamBuilder para mantener legible la lógica de datos.
class _ResumenContenido extends StatelessWidget {
  final int diasRango;
  final double? scoreTotal;
  final List<double> tendencia;
  final double kmTotales;
  final double co2Total;
  final double? consumoProm;
  final double? utilProm;
  final List<({String label, double? score})> subScores;

  const _ResumenContenido({
    required this.diasRango,
    required this.scoreTotal,
    required this.tendencia,
    required this.kmTotales,
    required this.co2Total,
    required this.consumoProm,
    required this.utilProm,
    required this.subScores,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header: eyebrow + hero number del score de flota.
        AppEyebrow('Flota · eco-driving · $diasRango días'),
        const SizedBox(height: AppSpacing.sm),
        _HeroScore(score: scoreTotal, tendencia: tendencia),
        const SizedBox(height: AppSpacing.lg),

        // ── KPIs operativos at-a-glance: dato real, faltante → '—'.
        AppKpiStrip(
          stats: [
            AppStat(
              label: 'KM totales',
              value: kmTotales > 0
                  ? AppFormatters.formatearMiles(kmTotales.round())
                  : '—',
            ),
            AppStat(
              label: 'Consumo',
              value: consumoProm == null
                  ? '—'
                  : consumoProm!.toStringAsFixed(1),
              unit: consumoProm == null ? null : 'L/100km',
            ),
            AppStat(
              label: 'CO₂',
              value: co2Total > 0 ? co2Total.toStringAsFixed(1) : '—',
              unit: co2Total > 0 ? 'ton' : null,
            ),
            AppStat(
              label: 'Utilización',
              value: utilProm == null ? '—' : utilProm!.toStringAsFixed(0),
              unit: utilProm == null ? null : '%',
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),

        // ── Sub-scores principales.
        _SubScoresCard(subScores: subScores),
      ],
    );
  }
}

/// Hero number del score de flota: número gigante + dot semántico +
/// interpretación, con sparkline de tendencia si hay data. Sobre un AppCard
/// con glow (gesto firma — es el KPI principal de la pantalla).
class _HeroScore extends StatelessWidget {
  final double? score;
  final List<double> tendencia;
  const _HeroScore({required this.score, required this.tendencia});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = score;
    final color = _colorScore(s, c);

    return AppCard(
      glow: true,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Número héroe + "/100" en mono.
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          s == null ? '—' : s.toStringAsFixed(0),
                          maxLines: 1,
                          style: AppType.h2.copyWith(color: color),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Text('/ 100', style: AppType.monoSm),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              // Badge interpretación: bueno / regular / crítico.
              AppBadge(
                text: _interpretacion(s),
                color: color,
                dot: true,
                size: AppBadgeSize.sm,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _detalleInterpretacion(s),
            style: AppType.bodySm.copyWith(height: 1.35),
          ),
          if (tendencia.length >= 2) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Text('TENDENCIA', style: AppType.monoSm.copyWith(color: c.textMuted)),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: AppSparkline(
                      data: tendencia,
                      color: color,
                      width: 140,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _interpretacion(double? s) {
    if (s == null) return 'Sin data';
    if (s < 60) return 'Crítico';
    if (s < 80) return 'Mejorable';
    return 'Bueno';
  }

  String _detalleInterpretacion(double? s) {
    if (s == null) return 'El poller no entregó score para este período.';
    if (s < 60) {
      return 'Hay margen importante de mejora. Mirá los sub-scores para detectar focos.';
    }
    if (s < 80) {
      return 'Buen nivel general, pero algunos sub-scores se pueden trabajar.';
    }
    return 'Manejo eficiente. Mantener y observar evolución.';
  }
}

/// Card de sub-scores principales: dos columnas, cada item con dot semántico +
/// número mono + label. Hairline horizontal entre las dos filas conceptuales.
class _SubScoresCard extends StatelessWidget {
  final List<({String label, double? score})> subScores;
  const _SubScoresCard({required this.subScores});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppEyebrow('Sub-scores principales'),
          const SizedBox(height: AppSpacing.md),
          GridView.count(
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            crossAxisCount: 2,
            crossAxisSpacing: AppSpacing.lg,
            mainAxisSpacing: AppSpacing.sm,
            // ratio < 1.2 (regla anti-overflow): tile ancho y bajo, una línea.
            childAspectRatio: 3.4,
            children: subScores
                .map((e) => _MiniSubScore(label: e.label, score: e.score))
                .toList(),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Escala 0-100 · más alto = mejor',
            style: AppType.monoSm.copyWith(color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _MiniSubScore extends StatelessWidget {
  final String label;
  final double? score;
  const _MiniSubScore({required this.label, required this.score});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = score;
    final color = _colorScore(s, c);
    return Row(
      children: [
        AppDot(color, size: 7),
        const SizedBox(width: AppSpacing.sm),
        SizedBox(
          width: 26,
          child: Text(
            s == null ? '—' : s.toStringAsFixed(0),
            style: AppType.mono.copyWith(
                color: color, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.bodySm,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// RANKING POR VEHÍCULO — AppCard con filas tier:1 (hairline natural).
// =============================================================================

class _RankingVehiculos extends StatelessWidget {
  final EcoDrivingService service;
  final DateTime desde;
  final DateTime hasta;
  final int diasRango;

  const _RankingVehiculos({
    required this.service,
    required this.desde,
    required this.hasta,
    required this.diasRango,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<VolvoScoreDiario>>(
      stream: service.streamPorVehiculoEntreFechas(desde: desde, hasta: hasta),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _SkeletonCard(altura: 200);
        }
        if (snap.hasError) {
          return _ErrorCard('No pudimos cargar el ranking', snap.error);
        }
        final docs = snap.data ?? const <VolvoScoreDiario>[];
        final ranking = RankingVehiculo.desdeDocs(docs);
        if (ranking.isEmpty) {
          return const _AvisoCard(
            icono: Icons.local_shipping_outlined,
            titulo: 'Sin scores por vehículo',
            mensaje:
                'El poller diario aún no acumuló data por vehículo en este rango.',
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: AppEyebrow('Ranking por vehículo')),
                Text(
                  '${ranking.length} ${ranking.length == 1 ? 'unidad' : 'unidades'}',
                  style: AppType.monoSm,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            ...ranking.asMap().entries.map((e) => _FilaRanking(
                  posicion: e.key + 1,
                  item: e.value,
                  onTap: () => _abrirDrilldown(context, e.value.patente),
                )),
          ],
        );
      },
    );
  }

  void _abrirDrilldown(BuildContext context, String patente) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ScoreDrilldownSheet(
        patente: patente,
        desde: desde,
        hasta: hasta,
      ),
    );
  }
}

class _FilaRanking extends StatelessWidget {
  final int posicion;
  final RankingVehiculo item;
  final VoidCallback onTap;

  const _FilaRanking({
    required this.posicion,
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _colorScore(item.scorePromedio, c);

    // Sub-línea técnica: días con data · km · L/100km. Faltantes se omiten
    // (no se inventan). Todo en mono tabular.
    final partes = <String>[
      '${item.diasConData} ${item.diasConData == 1 ? 'día' : 'días'}',
      if (item.kmTotalesEnRango != null)
        '${AppFormatters.formatearMiles(item.kmTotalesEnRango!.round())} km',
      if (item.consumoPromedioLPor100Km != null)
        '${item.consumoPromedioLPor100Km!.toStringAsFixed(1)} L/100km',
    ];

    return AppCard(
      tier: 1,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          // Posición en el ranking (mono, muted).
          SizedBox(
            width: 22,
            child: Text(
              '$posicion',
              style: AppType.monoSm.copyWith(color: c.textMuted),
            ),
          ),
          // Badge del score promedio (semántico).
          _ScoreBadge(score: item.scorePromedio, color: color),
          const SizedBox(width: AppSpacing.md),
          // Patente + sub-línea técnica.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.patente,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                      fontWeight: FontWeight.w600, letterSpacing: 0.5),
                ),
                const SizedBox(height: 2),
                Text(
                  partes.join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(Icons.chevron_right, size: 18, color: c.textMuted),
        ],
      ),
    );
  }
}

/// Badge cuadrado con el score promedio del vehículo. Tinte semántico suave
/// (no usa AppBadge porque queremos el número grande y centrado).
class _ScoreBadge extends StatelessWidget {
  final double score;
  final Color color;
  const _ScoreBadge({required this.score, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      alignment: Alignment.center,
      child: Text(
        score.toStringAsFixed(0),
        style: AppType.mono.copyWith(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// =============================================================================
// WIDGETS UI INTERNOS — estados loading / aviso / error.
// =============================================================================

class _SkeletonCard extends StatelessWidget {
  final double altura;
  const _SkeletonCard({required this.altura});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: SizedBox(
        height: altura,
        child: const Center(child: AppLoadingState()),
      ),
    );
  }
}

/// Card de aviso/empty en estilo Núcleo: icono + título + mensaje, borde
/// brand suave (accent). Neutro: la ausencia de data no es un error.
class _AvisoCard extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final String mensaje;

  const _AvisoCard({
    required this.icono,
    required this.titulo,
    required this.mensaje,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      accent: c.brand,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, color: c.brand, size: 24),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo,
                    style: AppType.body.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(mensaje,
                    style: AppType.bodySm.copyWith(height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String titulo;
  final Object? error;
  const _ErrorCard(this.titulo, this.error);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      accent: c.error,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: c.error, size: 24),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo,
                    style: AppType.body.copyWith(
                        color: c.error, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(
                  error?.toString() ?? 'Error desconocido',
                  style: AppType.monoSm.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
