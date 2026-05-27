import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../vehicles/services/volvo_api_service.dart';
import '../services/report_checklist.dart';
import '../services/report_consumo.dart';
import '../services/report_flota.dart';
import '../services/report_gomeria.dart';
import '../services/report_icm.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
/// Centro de Reportes (admin).
///
/// Lista los informes que el admin puede generar y exportar a Excel/PDF.
/// El reporte de Flota dispara una sincronización con Volvo Connect antes
/// de generar el archivo.
class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  bool _generando = false;

  // ---------------------------------------------------------------------------
  // ACCIONES
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

  Future<void> _ejecutarReporteGomeria() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ReportGomeriaService.mostrarOpcionesYGenerar(context);
    } catch (e) {
      if (mounted) {
        _mostrarSnack(messenger,
            'No se pudo generar el reporte de gomería. Probá de nuevo.',
            esError: true);
        debugPrint('admin_reports gomeria error: $e');
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
    return Stack(
      children: [
        AppScaffold(
          title: 'Centro de Reportes',
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 5, bottom: 14),
                child: Text(
                  'INFORMES ESTRATÉGICOS',
                  style: TextStyle(
                    color: AppColors.success,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                    letterSpacing: 2,
                  ),
                ),
              ),
              _ReportCard(
                titulo: 'Checklists Mensuales',
                descripcion:
                    'Reporte de novedades y roturas cargadas por choferes.',
                icono: Icons.fact_check_rounded,
                color: AppColors.success,
                onTap: _generando ? null : _ejecutarReporteChecklist,
              ),
              const SizedBox(height: AppSpacing.md),
              _ReportCard(
                titulo: 'Estado de Flota (Volvo)',
                descripcion:
                    'Sincroniza consumo, KMs y posición con Volvo Connect.',
                icono: Icons.cloud_sync_rounded,
                color: AppColors.info,
                onTap: _generando ? null : _ejecutarReporteFlota,
              ),
              const SizedBox(height: AppSpacing.md),
              _ReportCard(
                titulo: 'Consumo de Combustible',
                descripcion:
                    'Litros, KM y promedio L/100km por unidad, con ranking visual de top consumidores.',
                icono: Icons.local_gas_station_rounded,
                color: AppColors.warning,
                onTap: _generando ? null : _ejecutarReporteConsumo,
              ),
              const SizedBox(height: AppSpacing.md),
              _ReportCard(
                titulo: 'Gomería',
                descripcion:
                    'Estado actual de la flota, histórico de recapados y '
                    'costo por km por modelo (cohort 2 cuando haya datos).',
                icono: Icons.tire_repair_rounded,
                color: AppColors.brandSoft,
                onTap: _generando ? null : _ejecutarReporteGomeria,
              ),
              const SizedBox(height: AppSpacing.md),
              _ReportCard(
                titulo: 'ICM Semanal (Conducta de Manejo)',
                descripcion:
                    'Resumen flota + detalle por chofer + top 5 mejores y '
                    'peores. Basado en los mismos eventos Sitrack que YPF '
                    'audita en su Tablero ICM.',
                icono: Icons.leaderboard_rounded,
                color: AppColors.error,
                onTap: _generando ? null : _ejecutarReporteIcm,
              ),
            ],
          ),
        ),

        // Overlay de carga durante la sincronización con Volvo
        if (_generando) const _CargandoOverlay(),
      ],
    );
  }
}

// =============================================================================
// CARD DE UN REPORTE
// =============================================================================

class _ReportCard extends StatelessWidget {
  final String titulo;
  final String descripcion;
  final IconData icono;
  final Color color;
  final VoidCallback? onTap;

  const _ReportCard({
    required this.titulo,
    required this.descripcion,
    required this.icono,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      margin: EdgeInsets.zero,
      borderColor: color.withAlpha(50),
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              shape: BoxShape.circle,
            ),
            child: Icon(icono, color: color, size: 28),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  descripcion,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right_rounded,
            color: Colors.white38,
            size: 24,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// OVERLAY DE CARGA (cristal esmerilado durante sync con Volvo)
// =============================================================================

class _CargandoOverlay extends StatelessWidget {
  const _CargandoOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Container(
          color: Colors.black.withAlpha(150),
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.info.withAlpha(50)),
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppColors.info),
                  SizedBox(height: 25),
                  Text(
                    'CONECTANDO CON VOLVO',
                    style: TextStyle(
                      color: AppColors.info,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
                    'Descargando telemetría de flota...',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
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
