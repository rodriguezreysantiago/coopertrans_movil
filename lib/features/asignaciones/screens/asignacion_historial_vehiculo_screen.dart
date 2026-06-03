// lib/features/asignaciones/screens/asignacion_historial_vehiculo_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — línea de tiempo de quién manejó la unidad.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - el stream del historial (`AsignacionVehiculoService
//     .streamHistorialPorVehiculo`),
//   - el modelo `AsignacionVehiculo` (desde/hasta/chofer/asignadoPor/motivo),
//   - el cálculo de duración (`asignacion.diasDuracion()`),
//   - la navegación (read-only, sin acciones).
//
// Layout Núcleo: header (eyebrow HISTORIAL + número de registros) + AppKpiStrip
// (registros · choferes distintos · tiempo total) + timeline de AppCard, cada
// uno con AppBadge vigente/cerrado, AppDot en el punto de la línea, fechas mono
// separadas por AppHairline. Embedded en AdminShell: sin fondo propio.

import 'package:flutter/material.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/asignacion_vehiculo.dart';
import '../services/asignacion_vehiculo_service.dart';

/// Línea de tiempo de quién manejó este vehículo.
///
/// Se accede desde la ficha del vehículo (`AdminVehiculoFormScreen`).
/// Muestra todas las asignaciones (más reciente arriba), con duración,
/// quién hizo el cambio y motivo opcional.
class AsignacionHistorialVehiculoScreen extends StatelessWidget {
  final String patente;

  const AsignacionHistorialVehiculoScreen({
    super.key,
    required this.patente,
  });

  @override
  Widget build(BuildContext context) {
    final servicio = AsignacionVehiculoService();

    return AppScaffold(
      title: 'Historial · $patente',
      body: StreamBuilder<List<AsignacionVehiculo>>(
        stream: servicio.streamHistorialPorVehiculo(patente),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const AppSkeletonList(count: 6, conAvatar: false);
          }
          if (snap.hasError) {
            return AppErrorState(
              title: 'Error al cargar el historial',
              subtitle: snap.error.toString(),
            );
          }
          final items = snap.data ?? const <AsignacionVehiculo>[];
          if (items.isEmpty) {
            return const AppEmptyState(
              icon: Icons.history_toggle_off,
              title: 'Sin historial',
              subtitle:
                  'Esta unidad todavía no tiene asignaciones registradas. '
                  'A medida que se asignen choferes, vas a ver el log acá.',
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.xxl,
            ),
            children: [
              _Header(patente: patente, items: items),
              const SizedBox(height: AppSpacing.lg),
              for (var i = 0; i < items.length; i++)
                _AsignacionCard(asignacion: items[i]),
            ],
          );
        },
      ),
    );
  }
}

// =============================================================================
// HEADER · eyebrow HISTORIAL · patente + KPI strip (registros / choferes / días)
// =============================================================================

class _Header extends StatelessWidget {
  final String patente;
  final List<AsignacionVehiculo> items;
  const _Header({required this.patente, required this.items});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final choferesUnicos = items.map((a) => a.choferDni).toSet().length;
    final totalDias = items.fold<int>(0, (acc, a) => acc + a.diasDuracion());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppEyebrow('Historial de asignaciones'),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${items.length}',
              style: AppType.h2.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                items.length == 1 ? 'registro' : 'registros',
                style: AppType.monoSm,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                patente,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: AppType.mono.copyWith(color: c.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        AppKpiStrip(
          stats: [
            AppStat(label: 'Registros', value: '${items.length}'),
            AppStat(label: 'Choferes', value: '$choferesUnicos'),
            AppStat(label: 'Tiempo total', value: _formatDias(totalDias)),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// CARD DE UN PERÍODO · chofer + badge vigente/cerrado + fechas mono
// =============================================================================

class _AsignacionCard extends StatelessWidget {
  final AsignacionVehiculo asignacion;

  const _AsignacionCard({
    required this.asignacion,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final activa = asignacion.esActiva;
    final color = activa ? c.success : c.textMuted;
    final dias = asignacion.diasDuracion();
    final nombre = asignacion.choferNombre?.isNotEmpty == true
        ? asignacion.choferNombre!
        : 'DNI ${asignacion.choferDni}';

    return AppCard(
      tier: 2,
      accent: activa ? c.success : null,
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: AppDot(color, size: 7, glow: activa),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nombre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.h5,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'DNI ${asignacion.choferDni}',
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppBadge(
                text: activa ? 'Vigente' : 'Cerrado',
                color: activa ? c.success : c.textMuted,
                dot: true,
                size: AppBadgeSize.sm,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const AppHairline(),
          const SizedBox(height: AppSpacing.md),
          _Linea(
            label: 'Desde',
            valor: AppFormatters.formatearFechaHoraSinSegundos(
                asignacion.desde),
            mono: true,
          ),
          _Linea(
            label: 'Hasta',
            valor: asignacion.hasta != null
                ? AppFormatters.formatearFechaHoraSinSegundos(
                    asignacion.hasta!)
                : 'En curso',
            mono: true,
            colorValor: activa ? c.success : null,
          ),
          _Linea(
            label: 'Duración',
            valor: dias == 0
                ? 'Menos de 1 día'
                : '$dias día${dias == 1 ? "" : "s"}',
          ),
          _Linea(
            label: 'Asignado por',
            valor: asignacion.asignadoPorNombre?.isNotEmpty == true
                ? asignacion.asignadoPorNombre!
                : 'DNI ${asignacion.asignadoPorDni}',
          ),
          if (asignacion.motivo?.isNotEmpty == true)
            _Linea(label: 'Motivo', valor: asignacion.motivo!),
        ],
      ),
    );
  }
}

// =============================================================================
// PRIMITIVA DE LÍNEA · label (izq) / valor (der) — Núcleo
// =============================================================================

class _Linea extends StatelessWidget {
  final String label;
  final String valor;
  final bool mono;
  final Color? colorValor;
  const _Linea({
    required this.label,
    required this.valor,
    this.mono = false,
    this.colorValor,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final valBase = mono ? AppType.mono : AppType.body;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: AppType.bodySm.copyWith(color: c.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 6,
            child: Text(
              valor,
              textAlign: TextAlign.right,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: valBase.copyWith(color: colorValor ?? c.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// Formato humano de una cantidad de días para el KPI "Tiempo total".
String _formatDias(int totalDias) {
  if (totalDias == 0) return '< 1 día';
  if (totalDias == 1) return '1 día';
  if (totalDias < 30) return '$totalDias días';
  final meses = (totalDias / 30).floor();
  if (meses < 12) return '~$meses meses';
  final anios = (totalDias / 365).floor();
  return anios == 1 ? '~1 año' : '~$anios años';
}
