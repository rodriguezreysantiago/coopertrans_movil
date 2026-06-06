// lib/features/administracion/screens/reportes_discrepancia_screen.dart
//
// Reportes de choferes (módulo Administración). Lista los reclamos que los
// choferes dejaron por el bot ("esto que me mostrás no coincide") para
// trabajarlos: el revisor cruza con la telemetría/sistema y marca cada uno
// CIERTO (era un bug real) o NO COINCIDE (el dato estaba bien / el chofer infló).
//
// NO modifica el dato reclamado: es solo feedback. La verdad la define la
// telemetría. Los docs los crea el bot (tool reportar_discrepancia, Admin SDK);
// acá solo se leen y se marcan revisados.

import 'package:flutter/material.dart';

import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/reporte_discrepancia.dart';
import '../services/reportes_discrepancia_service.dart';

class ReportesDiscrepanciaScreen extends StatefulWidget {
  const ReportesDiscrepanciaScreen({super.key});

  @override
  State<ReportesDiscrepanciaScreen> createState() =>
      _ReportesDiscrepanciaScreenState();
}

class _ReportesDiscrepanciaScreenState
    extends State<ReportesDiscrepanciaScreen> {
  final _svc = ReportesDiscrepanciaService();
  bool _soloPendientes = true;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Reportes de choferes',
      body: StreamBuilder<List<ReporteDiscrepancia>>(
        stream: _svc.stream(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const AppErrorState(
                title: 'No se pudieron cargar los reportes');
          }
          if (!snap.hasData) return const AppLoadingState();
          final todos = snap.data!;
          final pendientes = todos.where((r) => r.pendiente).length;
          final lista =
              _soloPendientes ? todos.where((r) => r.pendiente).toList() : todos;
          return _contenido(todos.length, pendientes, lista);
        },
      ),
    );
  }

  Widget _contenido(int total, int pendientes, List<ReporteDiscrepancia> lista) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppEyebrow('Feedback de choferes · validar contra el sistema'),
          const SizedBox(height: AppSpacing.md),
          AppKpiStrip(stats: [
            AppStat(label: 'Pendientes', value: '$pendientes'),
            AppStat(label: 'Total', value: '$total'),
          ]),
          const SizedBox(height: AppSpacing.md),
          Row(children: [
            AppFilterChip(
              label: 'Pendientes',
              count: pendientes,
              activo: _soloPendientes,
              onTap: () => setState(() => _soloPendientes = true),
            ),
            const SizedBox(width: AppSpacing.xs),
            AppFilterChip(
              label: 'Todos',
              count: total,
              activo: !_soloPendientes,
              onTap: () => setState(() => _soloPendientes = false),
            ),
          ]),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: lista.isEmpty
                ? AppEmptyState(
                    icon: Icons.inbox_outlined,
                    title: _soloPendientes
                        ? 'Sin reportes pendientes'
                        : 'Sin reportes',
                    subtitle: _soloPendientes
                        ? 'Cuando un chofer reclame algo por el bot, aparece acá.'
                        : 'Todavía no hay reclamos cargados.',
                  )
                : ListView.separated(
                    itemCount: lista.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (_, i) => _Fila(
                      reporte: lista[i],
                      onRevisar: () => _revisar(lista[i]),
                      onReabrir: () => _reabrir(lista[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _revisar(ReporteDiscrepancia r) async {
    final notaCtrl = TextEditingController();
    final veredicto = await showDialog<String>(
      context: context,
      builder: (dCtx) {
        final c = dCtx.colors;
        return AlertDialog(
          backgroundColor: c.surface2,
          title: Text('Revisar reclamo de ${r.choferNombre}',
              style: AppType.h5.copyWith(color: c.text),
              maxLines: 2, overflow: TextOverflow.ellipsis),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('"${r.detalle}"',
                  style: AppType.bodySm.copyWith(color: c.textSecondary)),
              const SizedBox(height: AppSpacing.md),
              Text('¿Qué encontraste al cruzarlo con el sistema?',
                  style: AppType.label.copyWith(color: c.textSecondary)),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: notaCtrl,
                style: AppType.bodySm.copyWith(color: c.text),
                maxLines: 2,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Nota (opcional)',
                  hintStyle: AppType.bodySm.copyWith(color: c.textMuted),
                  filled: true,
                  fillColor: c.surface3,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            AppButton.ghost(
                label: 'Cancelar', onPressed: () => Navigator.pop(dCtx)),
            AppButton.ghost(
                label: 'No coincide',
                onPressed: () => Navigator.pop(dCtx, 'no_cierto')),
            AppButton.primary(
                label: 'Era cierto',
                onPressed: () => Navigator.pop(dCtx, 'cierto')),
          ],
        );
      },
    );
    if (veredicto == null || !mounted) return;
    try {
      await _svc.marcarRevisado(
        id: r.id,
        veredicto: veredicto,
        nota: notaCtrl.text,
        revisorDni: PrefsService.dni,
        revisorNombre: PrefsService.nombre,
      );
      if (mounted) {
        AppFeedback.success(
            context,
            veredicto == 'cierto'
                ? 'Marcado como cierto (a corregir en el sistema).'
                : 'Marcado como no coincide.');
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, 'No se pudo guardar: $e');
    }
  }

  Future<void> _reabrir(ReporteDiscrepancia r) async {
    try {
      await _svc.reabrir(r.id);
      if (mounted) AppFeedback.success(context, 'Reabierto como pendiente.');
    } catch (e) {
      if (mounted) AppFeedback.error(context, 'No se pudo reabrir: $e');
    }
  }
}

/// Fila de un reporte: chofer + tema + detalle + estado/veredicto.
class _Fila extends StatelessWidget {
  final ReporteDiscrepancia reporte;
  final VoidCallback onRevisar;
  final VoidCallback onReabrir;
  const _Fila(
      {required this.reporte, required this.onRevisar, required this.onReabrir});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = reporte;
    return AppCard(
      tier: 1,
      onTap: r.pendiente ? onRevisar : null,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  r.choferNombre.isEmpty ? 'DNI ${r.choferDni}' : r.choferNombre,
                  style: AppType.h5.copyWith(color: c.text),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppBadge(text: r.temaLegible, color: c.textMuted, size: AppBadgeSize.sm),
            ],
          ),
          const SizedBox(height: 4),
          Text('"${r.detalle}"',
              style: AppType.bodySm.copyWith(color: c.textSecondary)),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              // Con año: un reclamo de hace meses se distinguía de uno de hoy.
              Text(AppFormatters.formatearFechaHoraSinSegundos(r.creadoEn),
                  style: AppType.monoSm.copyWith(color: c.textMuted)),
              const Spacer(),
              if (r.pendiente)
                const AppBadge(text: 'Pendiente', color: AppColors.warning, dot: true, size: AppBadgeSize.sm)
              else
                AppBadge(
                  text: r.esCierto ? 'Cierto' : 'No coincide',
                  color: r.esCierto ? AppColors.error : AppColors.success,
                  dot: true,
                  size: AppBadgeSize.sm,
                ),
            ],
          ),
          if (!r.pendiente) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    [
                      if ((r.revisadoPorNombre ?? '').isNotEmpty)
                        'Revisó ${r.revisadoPorNombre}',
                      if ((r.notaRevision ?? '').isNotEmpty) '· ${r.notaRevision}',
                    ].join(' '),
                    style: AppType.monoSm.copyWith(color: c.textMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: onReabrir,
                  child: Text('Reabrir',
                      style: AppType.monoSm.copyWith(color: c.brand)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
