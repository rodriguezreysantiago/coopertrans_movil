import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/asignacion_vehiculo.dart';
import '../services/asignacion_vehiculo_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
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
            return Center(
              child: Text(
                'Error al cargar el historial:\n${snap.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.error),
              ),
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

          return ListView.builder(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: items.length,
            itemBuilder: (_, i) => _AsignacionCard(
              asignacion: items[i],
            ),
          );
        },
      ),
    );
  }
}

class _AsignacionCard extends StatelessWidget {
  final AsignacionVehiculo asignacion;

  const _AsignacionCard({
    required this.asignacion,
  });

  @override
  Widget build(BuildContext context) {
    final activa = asignacion.esActiva;
    final color = activa ? AppColors.success : AppColors.textHint;
    final dias = asignacion.diasDuracion();

    return AppCard(
      borderColor: color.withAlpha(50),
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                activa ? Icons.directions_car : Icons.history,
                color: color,
                size: 22,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  asignacion.choferNombre?.isNotEmpty == true
                      ? asignacion.choferNombre!
                      : 'DNI ${asignacion.choferDni}',
                  style: AppType.heading.copyWith(fontSize: 15),
                ),
              ),
              if (activa)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.success.withAlpha(30),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(
                        color: AppColors.success.withAlpha(80)),
                  ),
                  child: Text(
                    'ACTUAL',
                    style: AppType.eyebrow.copyWith(
                      color: AppColors.success,
                      fontSize: 10,
                      letterSpacing: 1,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _Linea(
            label: 'Desde',
            valor: AppFormatters.formatearFechaHoraSinSegundos(asignacion.desde),
          ),
          _Linea(
            label: 'Hasta',
            valor: asignacion.hasta != null
                ? AppFormatters.formatearFechaHoraSinSegundos(asignacion.hasta!)
                : '— en curso —',
          ),
          _Linea(
            label: 'Duración',
            valor: dias == 0 ? 'menos de 1 día' : '$dias día${dias == 1 ? "" : "s"}',
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

class _Linea extends StatelessWidget {
  final String label;
  final String valor;
  const _Linea({required this.label, required this.valor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: AppType.label.copyWith(color: AppColors.textTertiary),
            ),
          ),
          Expanded(
            child: Text(
              valor,
              style: AppType.body.copyWith(
                  color: AppColors.textPrimary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
