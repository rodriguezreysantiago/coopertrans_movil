import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../asignaciones/models/asignacion_vehiculo.dart';
import '../../asignaciones/services/asignacion_vehiculo_service.dart';
import '../models/volvo_score_diario.dart';
import '../services/eco_driving_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Bottom sheet de drill-down de un vehículo específico.
///
/// Muestra:
///   - Header con patente + score promedio del rango.
///   - Lista de días con score diario y atribución al chofer (cruce con
///     `AsignacionVehiculoService.streamHistorialPorVehiculo`).
///   - Sub-scores promediados.
class ScoreDrilldownSheet extends StatelessWidget {
  final String patente;
  final DateTime desde;
  final DateTime hasta;

  const ScoreDrilldownSheet({
    super.key,
    required this.patente,
    required this.desde,
    required this.hasta,
  });

  @override
  Widget build(BuildContext context) {
    final scoreService = EcoDrivingService();
    final asigService = AsignacionVehiculoService();

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: AppColors.success.withAlpha(40)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: StreamBuilder<List<VolvoScoreDiario>>(
          stream: scoreService.streamHistorialPorPatente(
            patente,
            desde: desde,
            hasta: hasta,
          ),
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.success),
              );
            }
            final docs = snap.data ?? const <VolvoScoreDiario>[];
            if (docs.isEmpty) {
              return _ListaSinData(
                patente: patente,
                scrollCtrl: scrollCtrl,
                desde: desde,
                hasta: hasta,
              );
            }

            return StreamBuilder<List<AsignacionVehiculo>>(
              stream: asigService.streamHistorialPorVehiculo(patente, limit: 50),
              builder: (_, asigSnap) {
                final asignaciones = asigSnap.data ?? const <AsignacionVehiculo>[];
                return _ContenidoDrilldown(
                  patente: patente,
                  desde: desde,
                  hasta: hasta,
                  scrollCtrl: scrollCtrl,
                  docs: docs,
                  asignaciones: asignaciones,
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ListaSinData extends StatelessWidget {
  final String patente;
  final ScrollController scrollCtrl;
  final DateTime desde;
  final DateTime hasta;

  const _ListaSinData({
    required this.patente,
    required this.scrollCtrl,
    required this.desde,
    required this.hasta,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollCtrl,
      children: [
        const _DragHandle(),
        const SizedBox(height: AppSpacing.sm),
        _Header(patente: patente, scorePromedio: null),
        const SizedBox(height: AppSpacing.xl),
        const Center(
          child: Text(
            'Sin scores en este rango.\n'
            'Probá con un rango más amplio o esperá al próximo poll diario.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _ContenidoDrilldown extends StatelessWidget {
  final String patente;
  final DateTime desde;
  final DateTime hasta;
  final ScrollController scrollCtrl;
  final List<VolvoScoreDiario> docs;
  final List<AsignacionVehiculo> asignaciones;

  const _ContenidoDrilldown({
    required this.patente,
    required this.desde,
    required this.hasta,
    required this.scrollCtrl,
    required this.docs,
    required this.asignaciones,
  });

  @override
  Widget build(BuildContext context) {
    final docsConScore = docs
        .where((d) => d.scoreTotal != null)
        .toList(growable: false);
    final scorePromedio = docsConScore.isEmpty
        ? null
        : docsConScore.fold<double>(0, (a, d) => a + d.scoreTotal!) /
            docsConScore.length;

    final subScoresProm = _promediarSubscores(docs);

    return ListView(
      controller: scrollCtrl,
      children: [
        const _DragHandle(),
        const SizedBox(height: AppSpacing.sm),
        _Header(patente: patente, scorePromedio: scorePromedio),
        const SizedBox(height: AppSpacing.lg),
        const _Seccion('EVOLUCIÓN DIARIA'),
        const SizedBox(height: AppSpacing.sm),
        ...docs.map((d) {
          final asig = _asignacionEnFecha(d.fechaTs);
          return _FilaDia(
            doc: d,
            asignacion: asig,
          );
        }),
        const SizedBox(height: 20),
        const _Seccion('SUB-SCORES PROMEDIO'),
        const SizedBox(height: AppSpacing.sm),
        ...VolvoSubScoreLabels.etiquetas.entries.map((e) {
          final v = subScoresProm[e.key];
          return _BarraSubscore(label: e.value, score: v);
        }),
      ],
    );
  }

  AsignacionVehiculo? _asignacionEnFecha(DateTime fecha) {
    for (final a in asignaciones) {
      final desdeA = a.desde;
      final hastaA = a.hasta;
      final cubreInicio = !desdeA.isAfter(fecha);
      final cubreFin = hastaA == null || hastaA.isAfter(fecha);
      if (cubreInicio && cubreFin) return a;
    }
    return null;
  }

  Map<String, double?> _promediarSubscores(List<VolvoScoreDiario> docs) {
    final keys = VolvoSubScoreLabels.etiquetas.keys;
    final out = <String, double?>{};
    for (final k in keys) {
      double sum = 0;
      int n = 0;
      for (final d in docs) {
        final v = d.subScores[k];
        if (v != null) {
          sum += v;
          n++;
        }
      }
      out[k] = n > 0 ? sum / n : null;
    }
    return out;
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String patente;
  final double? scorePromedio;
  const _Header({required this.patente, required this.scorePromedio});

  @override
  Widget build(BuildContext context) {
    final s = scorePromedio;
    final color = s == null
        ? Colors.white38
        : s < 60
            ? AppColors.error
            : s < 80
                ? AppColors.warning
                : AppColors.success;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                patente,
                style: AppType.title.copyWith(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
              const SizedBox(height: 2),
              Text(
                'Detalle eco-driving',
                style: AppType.label.copyWith(color: Colors.white54),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: color.withAlpha(30),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withAlpha(120)),
          ),
          child: Column(
            children: [
              Text(
                s == null ? '—' : s.toStringAsFixed(0),
                style: AppType.title.copyWith(color: color, fontWeight: FontWeight.bold),
              ),
              const Text(
                'PROM',
                style: TextStyle(color: Colors.white54, fontSize: 9, letterSpacing: 1),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Seccion extends StatelessWidget {
  final String titulo;
  const _Seccion(this.titulo);

  @override
  Widget build(BuildContext context) {
    return Text(
      titulo,
      style: const TextStyle(
        color: Colors.white54,
        fontWeight: FontWeight.bold,
        fontSize: 10,
        letterSpacing: 1.5,
      ),
    );
  }
}

class _FilaDia extends StatelessWidget {
  final VolvoScoreDiario doc;
  final AsignacionVehiculo? asignacion;

  const _FilaDia({
    required this.doc,
    required this.asignacion,
  });

  @override
  Widget build(BuildContext context) {
    final s = doc.scoreTotal;
    final color = s == null
        ? Colors.white38
        : s < 60
            ? AppColors.error
            : s < 80
                ? AppColors.warning
                : AppColors.success;
    final chofer = asignacion?.choferNombre?.isNotEmpty == true
        ? asignacion!.choferNombre!
        : asignacion != null
            ? 'DNI ${asignacion!.choferDni}'
            : '—';
    final km = doc.totalDistanceKm;
    final consumo = doc.fuelLPor100Km;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(
              AppFormatters.formatearFechaCorta(doc.fechaTs),
              style: AppType.label.copyWith(color: Colors.white70),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: color.withAlpha(80)),
            ),
            child: Text(
              s == null ? '—' : s.toStringAsFixed(0),
              style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chofer,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.label.copyWith(color: Colors.white),
                ),
                if (km != null || consumo != null)
                  Text(
                    [
                      if (km != null) '${km.toStringAsFixed(0)} km',
                      if (consumo != null) '${consumo.toStringAsFixed(1)} L/100km',
                    ].join(' · '),
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BarraSubscore extends StatelessWidget {
  final String label;
  final double? score;
  const _BarraSubscore({required this.label, required this.score});

  @override
  Widget build(BuildContext context) {
    final s = score;
    final color = s == null
        ? Colors.white24
        : s < 60
            ? AppColors.error
            : s < 80
                ? AppColors.warning
                : AppColors.success;
    final pct = (s ?? 0) / 100;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: AppType.eyebrow.copyWith(color: Colors.white70),
            ),
          ),
          Expanded(
            child: Container(
              height: 8,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: pct.clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 30,
            child: Text(
              s == null ? '—' : s.toStringAsFixed(0),
              textAlign: TextAlign.end,
              style: AppType.label.copyWith(color: color, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
