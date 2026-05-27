import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/volvo_score_diario.dart';
import '../services/eco_driving_service.dart';
import '../widgets/score_drilldown_sheet.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Pantalla "Eco-Driving" del admin/supervisor.
///
/// Muestra los scores de eco-driving que pollea diariamente
/// `volvoScoresPoller` desde la Volvo Group Scores API. Tres bloques:
///
///   1. **Resumen de flota**: card grande con score total + 8 sub-scores
///      principales del último mes + métricas operativas (km, combustible,
///      CO2, utilización).
///   2. **Ranking por vehículo**: lista ordenada por score promedio del
///      período, con badge de color (rojo <60, amarillo 60-80, verde ≥80).
///   3. **Drill-down**: tap en una patente → bottom sheet con evolución
///      diaria + radar de los 8 sub-scores + métricas operativas.
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
        padding: const EdgeInsets.all(AppSpacing.lg),
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
// RESUMEN DE FLOTA
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
          return const _SkeletonCard(altura: 280);
        }
        if (snap.hasError) {
          return _ErrorCard('No pudimos cargar el resumen', snap.error);
        }
        final docs = snap.data ?? const <VolvoScoreDiario>[];
        if (docs.isEmpty) {
          return const _AvisoCard(
            icono: Icons.info_outline,
            color: AppColors.info,
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

        return AppCard(
          borderColor: AppColors.success.withAlpha(50),
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'FLOTA · score promedio últimos $diasRango días',
                style: AppType.eyebrow.copyWith(
                    color: AppColors.success, letterSpacing: 2),
              ),
              const SizedBox(height: AppSpacing.md),
              _ScoreGrande(score: scoreTotal),
              const SizedBox(height: AppSpacing.xl),
              const _DivisorChico(),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'SUB-SCORES PRINCIPALES',
                style: AppType.eyebrow.copyWith(
                    color: AppColors.textTertiary,
                    fontSize: 10,
                    letterSpacing: 1.5),
              ),
              const SizedBox(height: AppSpacing.md),
              GridView.count(
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                crossAxisCount: 2,
                crossAxisSpacing: AppSpacing.md,
                mainAxisSpacing: AppSpacing.sm,
                // 4.2 → 3.5: tile menos plano. En 4.2 el alto era ~39 dp,
                // justo para texto fontSize 11 + número fontSize 16. iOS
                // line-height de Cupertino lo zafaba.
                childAspectRatio: 3.5,
                children: subScoresPrincipales
                    .map((k) => _MiniSubScore(label: VolvoSubScoreLabels.label(k), score: promedios[k]))
                    .toList(),
              ),
              const SizedBox(height: AppSpacing.xl),
              const _DivisorChico(),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'OPERACIÓN ACUMULADA',
                style: AppType.eyebrow.copyWith(
                    color: AppColors.textTertiary,
                    fontSize: 10,
                    letterSpacing: 1.5),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  _MetricaOp(label: 'KM totales', valor: NumberFormat.decimalPattern('es_AR').format(kmTotales.round())),
                  _MetricaOp(label: 'L/100km prom', valor: consumoProm == null ? '—' : consumoProm.toStringAsFixed(1)),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  _MetricaOp(label: 'CO₂ (ton)', valor: co2Total.toStringAsFixed(1)),
                  _MetricaOp(label: 'Utilización', valor: utilProm == null ? '—' : '${utilProm.toStringAsFixed(1)}%'),
                ],
              ),
            ],
          ),
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

// =============================================================================
// RANKING POR VEHÍCULO
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
            color: AppColors.textHint,
            titulo: 'Sin scores por vehículo',
            mensaje: 'El poller diario aún no acumuló data por vehículo en este rango.',
          );
        }

        return AppCard(
          borderColor: AppColors.info.withAlpha(40),
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.leaderboard, color: AppColors.info, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    'RANKING POR VEHÍCULO · $diasRango DÍAS',
                    style: AppType.eyebrow.copyWith(
                        color: AppColors.info, letterSpacing: 1.5),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              ...ranking.map((r) => _FilaRanking(
                    item: r,
                    onTap: () => _abrirDrilldown(context, r.patente),
                  )),
            ],
          ),
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
  final RankingVehiculo item;
  final VoidCallback onTap;

  const _FilaRanking({required this.item, required this.onTap});

  Color get _colorScore {
    final s = item.scorePromedio;
    if (s < 60) return AppColors.error;
    if (s < 80) return AppColors.warning;
    return AppColors.success;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
              decoration: BoxDecoration(
                color: _colorScore.withAlpha(30),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: _colorScore.withAlpha(120)),
              ),
              child: Text(
                item.scorePromedio.toStringAsFixed(0),
                style: AppType.body.copyWith(
                    color: _colorScore, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.patente,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.body.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${item.diasConData} día${item.diasConData == 1 ? '' : 's'} con data'
                    '${item.kmTotalesEnRango != null ? ' · ${NumberFormat.decimalPattern('es_AR').format(item.kmTotalesEnRango!.round())} km' : ''}'
                    '${item.consumoPromedioLPor100Km != null ? ' · ${item.consumoPromedioLPor100Km!.toStringAsFixed(1)} L/100km' : ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.eyebrow
                        .copyWith(color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: AppColors.textHint, size: 22),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// WIDGETS UI INTERNOS
// =============================================================================

class _ScoreGrande extends StatelessWidget {
  final double? score;
  const _ScoreGrande({required this.score});

  @override
  Widget build(BuildContext context) {
    final s = score;
    final colorScore = s == null
        ? AppColors.textHint
        : s < 60
            ? AppColors.error
            : s < 80
                ? AppColors.warning
                : AppColors.success;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colorScore.withAlpha(120), width: 4),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                s == null ? '—' : s.toStringAsFixed(0),
                style: AppType.display.copyWith(
                  color: colorScore,
                  fontSize: 36,
                ),
              ),
              Text(
                '/ 100',
                style: AppType.label
                    .copyWith(color: AppColors.textTertiary, fontSize: 10),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _interpretacion(s),
                style: AppType.heading.copyWith(color: colorScore),
              ),
              const SizedBox(height: 6),
              Text(
                _detalleInterpretacion(s),
                style: AppType.label
                    .copyWith(color: AppColors.textSecondary, height: 1.3),
              ),
            ],
          ),
        ),
      ],
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
    if (s < 60) return 'Hay margen importante de mejora. Mirar sub-scores para detectar focos.';
    if (s < 80) return 'Buen nivel general, pero algunos sub-scores se pueden trabajar.';
    return 'Manejo eficiente. Mantener y observar evolución.';
  }
}

class _MiniSubScore extends StatelessWidget {
  final String label;
  final double? score;
  const _MiniSubScore({required this.label, required this.score});

  @override
  Widget build(BuildContext context) {
    final s = score;
    final color = s == null
        ? AppColors.textHint
        : s < 60
            ? AppColors.error
            : s < 80
                ? AppColors.warning
                : AppColors.success;
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            s == null ? '—' : s.toStringAsFixed(0),
            style: AppType.heading.copyWith(color: color),
          ),
        ),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: AppType.eyebrow.copyWith(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _MetricaOp extends StatelessWidget {
  final String label;
  final String valor;
  const _MetricaOp({required this.label, required this.valor});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: AppType.label
                  .copyWith(color: AppColors.textTertiary, fontSize: 10)),
          const SizedBox(height: 2),
          Text(valor,
              style: AppType.heading.copyWith(color: AppColors.textPrimary)),
        ],
      ),
    );
  }
}

class _DivisorChico extends StatelessWidget {
  const _DivisorChico();

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: AppColors.borderSubtle);
  }
}

class _SkeletonCard extends StatelessWidget {
  final double altura;
  const _SkeletonCard({required this.altura});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: SizedBox(
        height: altura,
        child: const Center(
          child: CircularProgressIndicator(color: AppColors.success),
        ),
      ),
    );
  }
}

class _AvisoCard extends StatelessWidget {
  final IconData icono;
  final Color color;
  final String titulo;
  final String mensaje;

  const _AvisoCard({
    required this.icono,
    required this.color,
    required this.titulo,
    required this.mensaje,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      borderColor: color.withAlpha(50),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, color: color, size: 28),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo,
                    style: AppType.body
                        .copyWith(color: color, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(mensaje,
                    style: AppType.label.copyWith(
                        color: AppColors.textSecondary, height: 1.4)),
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
    return _AvisoCard(
      icono: Icons.error_outline,
      color: AppColors.error,
      titulo: titulo,
      mensaje: error?.toString() ?? 'Error desconocido',
    );
  }
}

