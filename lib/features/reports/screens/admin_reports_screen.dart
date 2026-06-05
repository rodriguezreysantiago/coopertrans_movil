import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../vehicles/services/volvo_api_service.dart';
import '../services/report_checklist.dart';
import '../services/report_consumo.dart';
import '../services/report_flota.dart';
import '../services/report_icm.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Centro de Reportes (admin) — REFACTOR NÚCLEO (jun 2026).
///
/// Lista los informes que el admin puede generar y exportar a Excel/PDF.
/// El reporte de Flota (y el de Consumo) disparan una sincronización con
/// Volvo Connect antes de abrir el diálogo de exportación.
///
/// REFACTOR NÚCLEO: re-estilizado SIN tocar la capa de datos/lógica.
/// El State (`_generando`), los 5 disparadores `_ejecutarReporte*`, la
/// bajada del cache de Volvo (`traerDatosFlota` / `traerEstadosFlota`),
/// los servicios `Report*.mostrarOpcionesYGenerar` y el snack quedan
/// intactos — sólo se reescribió el árbol de widgets:
///   • header `AppEyebrow` + título h3 + bajada en mono;
///   • los disparadores ahora son tiles bento (`_ReportTile`): icon chip
///     indigo (única tinta de chrome), eyebrow con el formato de salida,
///     título h5 y subtítulo mono, en grid responsivo;
///   • el overlay de carga de Volvo re-tokenizado a superficies Núcleo
///     (scrim near-black + card surface2 + spinner brand).
///
/// NOTA de altitud: esta pantalla NO tiene fuente de KPIs propia (no hay
/// stream/read que la alimente). Por eso NO se inventan KpiGrandeCard ni
/// charts sin datos — sería violar "faltantes → —, no inventar". El valor
/// de la pantalla es el hub de generadores, presentado en bento.
class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  bool _generando = false;

  // ---------------------------------------------------------------------------
  // ACCIONES  (lógica intacta — sólo el árbol de widgets cambió)
  // ---------------------------------------------------------------------------

  Future<void> _ejecutarReporteChecklist() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ReportChecklistService.mostrarOpcionesYGenerar(context);
    } catch (e) {
      if (mounted) {
        _mostrarSnack(messenger,
            'No se pudo generar el reporte de checklists. Probá de nuevo.',
            esError: true);
        debugPrint('admin_reports checklist error: $e');
      }
    }
  }

  Future<void> _ejecutarReporteIcm() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ReportIcmService.mostrarOpcionesYGenerar(context);
    } catch (e) {
      if (mounted) {
        _mostrarSnack(messenger,
            'No se pudo generar el reporte de ICM. Probá de nuevo.',
            esError: true);
        debugPrint('admin_reports icm error: $e');
      }
    }
  }

  Future<void> _ejecutarReporteFlota() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _generando = true);

    try {
      // 1) Bajamos los datos de Volvo (puede tardar varios segundos)
      final volvoService = VolvoApiService();
      final cacheVolvo = await volvoService.traerDatosFlota();

      if (!mounted) return;
      setState(() => _generando = false);

      // 2) Abrimos el diálogo de opciones de exportación
      await ReportFlotaService.mostrarOpcionesYGenerar(context, cacheVolvo);
    } catch (e) {
      if (mounted) {
        setState(() => _generando = false);
        _mostrarSnack(
          messenger,
          'Error al conectar con Volvo: $e',
          esError: true,
        );
      }
    }
  }

  /// Reporte de consumo: misma estrategia que el reporte de flota —
  /// bajamos el cache de Volvo (que ya trae `accumulatedData` con
  /// litros) y se lo pasamos al servicio. Si Volvo está caído, igual
  /// dejamos abrir el dialog (el reporte queda sin litros pero con la
  /// info de Firestore disponible).
  Future<void> _ejecutarReporteConsumo() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _generando = true);
    try {
      final volvoService = VolvoApiService();
      List<dynamic> cacheVolvo = const [];
      try {
        // Usar `traerEstadosFlota` (endpoint /vehiclestatuses) y NO
        // `traerDatosFlota` (endpoint /vehicles que solo trae metadata).
        // El reporte de consumo necesita `accumulatedData.totalFuelConsumption`
        // como fallback cuando no se puede calcular el período (vehículo
        // parado, fin de semana, sin snapshots suficientes). Ese campo
        // viene SOLO en /vehiclestatuses.
        cacheVolvo = await volvoService.traerEstadosFlota();
      } catch (e) {
        debugPrint('Volvo no respondió, sigo sin telemetría: $e');
      }

      if (!mounted) return;
      setState(() => _generando = false);

      await ReportConsumoService.mostrarOpcionesYGenerar(
          context, cacheVolvo);
    } catch (e) {
      if (mounted) {
        setState(() => _generando = false);
        _mostrarSnack(
          messenger,
          'Error al generar reporte de consumo: $e',
          esError: true,
        );
      }
    }
  }

  void _mostrarSnack(
    ScaffoldMessengerState messenger,
    String mensaje, {
    bool esError = false,
  }) {
    if (esError) {
      AppFeedback.errorOn(messenger, mensaje);
    } else {
      AppFeedback.successOn(messenger, mensaje);
    }
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    // Catálogo de reportes. `requiereVolvo` solo cambia el copy ("sincroniza
    // con Volvo") y el badge — NO la lógica: el gating por `_generando` se
    // aplica igual a todos los tiles.
    final reportes = <_ReporteDef>[
      _ReporteDef(
        titulo: 'Checklists mensuales',
        descripcion:
            'Novedades y roturas cargadas por choferes en el período.',
        icono: Icons.fact_check_outlined,
        formato: 'Excel',
        onTap: _ejecutarReporteChecklist,
      ),
      _ReporteDef(
        titulo: 'Estado de flota',
        descripcion:
            'Sincroniza consumo, KMs y posición con Volvo Connect.',
        icono: Icons.cloud_sync_outlined,
        formato: 'Excel',
        requiereVolvo: true,
        onTap: _ejecutarReporteFlota,
      ),
      _ReporteDef(
        titulo: 'Consumo de combustible',
        descripcion:
            'Litros, KM y L/100km por unidad, con ranking de top consumidores.',
        icono: Icons.local_gas_station_outlined,
        formato: 'Excel',
        requiereVolvo: true,
        onTap: _ejecutarReporteConsumo,
      ),
      _ReporteDef(
        titulo: 'ICM semanal',
        descripcion:
            'Flota + detalle por chofer + top 5 mejores y peores. Mismos '
            'eventos Sitrack que YPF audita.',
        icono: Icons.leaderboard_outlined,
        formato: 'Excel',
        onTap: _ejecutarReporteIcm,
      ),
    ];

    return Stack(
      children: [
        AppScaffold(
          title: 'Centro de Reportes',
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxl),
            children: [
              // ─── Header bento: eyebrow + título + bajada ───
              const AppEyebrow('Informes estratégicos'),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Centro de reportes',
                style: AppType.h3.copyWith(color: c.text),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Generá y exportá los informes de la operación. '
                'Cada reporte abre sus opciones de período al tocarlo.',
                style: AppType.bodySm.copyWith(color: c.textSecondary, height: 1.4),
              ),
              const SizedBox(height: AppSpacing.xl),

              // ─── Grid bento de generadores ───
              _GridReportes(reportes: reportes, deshabilitado: _generando),
            ],
          ),
        ),

        // Overlay de carga durante la sincronización con Volvo.
        if (_generando) const _CargandoOverlay(),
      ],
    );
  }
}

// =============================================================================
// DEFINICIÓN DE UN REPORTE (data del tile — no toca lógica)
// =============================================================================

class _ReporteDef {
  final String titulo;
  final String descripcion;
  final IconData icono;

  /// Formato de salida del archivo (metadata real del servicio, no inventada).
  final String formato;

  /// Si el reporte baja telemetría de Volvo antes de abrir el diálogo (solo
  /// afecta el copy/badge — el gating por `_generando` es igual para todos).
  final bool requiereVolvo;

  final VoidCallback onTap;

  const _ReporteDef({
    required this.titulo,
    required this.descripcion,
    required this.icono,
    required this.formato,
    required this.onTap,
    this.requiereVolvo = false,
  });
}

// =============================================================================
// GRID RESPONSIVO DE TILES
// =============================================================================

class _GridReportes extends StatelessWidget {
  final List<_ReporteDef> reportes;
  final bool deshabilitado;

  const _GridReportes({required this.reportes, required this.deshabilitado});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final w = constraints.maxWidth;
        // Desktop 3 col, tablet 2 col, mobile 1 col (apilado).
        final cols = w >= 900 ? 3 : (w >= 560 ? 2 : 1);
        // ratio < 1.2 (regla anti-overflow). En 1 col el tile es ancho y bajo.
        final ratio = cols == 1 ? 3.0 : 1.15;
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: AppSpacing.mdDense,
          mainAxisSpacing: AppSpacing.mdDense,
          childAspectRatio: ratio,
          children: [
            for (final r in reportes)
              _ReportTile(def: r, deshabilitado: deshabilitado),
          ],
        );
      },
    );
  }
}

// =============================================================================
// TILE DE UN REPORTE (bento Núcleo)
// =============================================================================

/// Tile de acción bento: icon chip indigo (única tinta de chrome) + eyebrow
/// con el formato de salida + título h5 + subtítulo mono. Replica el patrón
/// de tile de hub del sistema (ICM hub), pero al tocarlo dispara el servicio
/// de reporte en lugar de navegar. Cuando `deshabilitado` (sync de Volvo en
/// curso) se atenúa y deja de responder.
class _ReportTile extends StatelessWidget {
  final _ReporteDef def;
  final bool deshabilitado;

  const _ReportTile({required this.def, required this.deshabilitado});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Opacity(
      opacity: deshabilitado ? 0.45 : 1,
      child: AppCard(
        tier: 1,
        onTap: deshabilitado ? null : def.onTap,
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // Icon chip surface3 + brand 16px.
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c.surface3,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(def.icono, size: 16, color: c.brand),
                ),
                const Spacer(),
                // Eyebrow del formato de salida (metadata real).
                AppEyebrow(def.formato),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              def.titulo,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.h5.copyWith(color: c.text),
            ),
            const SizedBox(height: AppSpacing.xs),
            // Flexible para que el subtítulo no desborde en tiles bajos.
            Flexible(
              child: Text(
                def.descripcion,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppType.monoSm.copyWith(color: c.textMuted, height: 1.45),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            // Pie: hint de Volvo (si aplica) + affordance de acción.
            Row(
              children: [
                if (def.requiereVolvo) ...[
                  Icon(Icons.bolt_outlined, size: 13, color: c.textMuted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'Sincroniza Volvo',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                    ),
                  ),
                ] else
                  const Spacer(),
                const SizedBox(width: AppSpacing.sm),
                Icon(Icons.arrow_outward, size: 14, color: c.textMuted),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// OVERLAY DE CARGA (cristal esmerilado durante sync con Volvo) — tokens Núcleo
// =============================================================================

class _CargandoOverlay extends StatelessWidget {
  const _CargandoOverlay();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Positioned.fill(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: ColoredBox(
          color: c.bg.withValues(alpha: 0.6),
          child: Center(
            child: AppCard(
              tier: 3,
              glow: true,
              padding: const EdgeInsets.all(AppSpacing.xxxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: c.brand),
                  const SizedBox(height: AppSpacing.xl),
                  const AppEyebrow('Conectando con Volvo'),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Descargando telemetría de flota…',
                    style: AppType.bodySm.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
