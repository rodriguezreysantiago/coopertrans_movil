import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../core/services/capabilities.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/dato_editable.dart';
import '../providers/vehiculo_provider.dart';
import '../services/vehiculo_actions.dart';
import '../services/volvo_api_service.dart';

import 'admin_vehiculo_alta_screen.dart';
import 'admin_vehiculo_form_screen.dart';
import 'diagnostico_volvo_screen.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
// 13 widgets visuales (cards, sheet de detalle, telemetría, badges,
// rows) extraídos para mantener navegable el screen principal.
// Comparten privacidad y los imports via `part of`.
part 'admin_vehiculos_lista_widgets.dart';

/// Pantalla de Gestión de Flota.
///
/// Migrada al sistema de diseño unificado (AppScaffold + AppListPage +
/// AppCard + AppDetailSheet + VencimientoBadge + AppFileThumbnail).
class AdminVehiculosListaScreen extends StatefulWidget {
  const AdminVehiculosListaScreen({super.key});

  @override
  State<AdminVehiculosListaScreen> createState() =>
      _AdminVehiculosListaScreenState();
}

class _AdminVehiculosListaScreenState
    extends State<AdminVehiculosListaScreen> {
  /// Por default solo activos. Toggle del AppBar lo invierte.
  bool _mostrarInactivos = false;

  /// Por default ocultos los tanques de combustibles líquidos y los
  /// tractores asignados a sus choferes. Toggle del AppBar los muestra
  /// para auditoría/mantenimiento.
  bool _mostrarExcluidos = false;

  /// Set de patentes excluidas (cacheado). Null mientras carga.
  ExcluidosSet? _excluidos;

  /// Tipo de unidad seleccionado por los chips de filtro. Default: el
  /// primero de `_tipos` (TRACTOR). Reemplaza al `DefaultTabController`.
  String _tipoSeleccionado = _tipos.first;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<VehiculoProvider>().init();
    });
    ExcluidosService.cargar().then((s) {
      if (mounted) setState(() => _excluidos = s);
    });
  }

  /// Tabs que mostramos: tractor primero (la unidad que tracciona) y
  /// después los enganches. Filtramos `ACOPLADO` porque solo existe por
  /// retrocompatibilidad con docs viejos y no queremos un tab vacío.
  static List<String> get _tipos => [
        AppTiposVehiculo.tractor,
        ...AppTiposVehiculo.enganches.where((t) => t != 'ACOPLADO'),
      ];

  /// ¿La unidad pasa los filtros de visibilidad (activo/excluido)? Es el
  /// MISMO predicado que aplica `_ListaPorTipo`, así el contador del chip
  /// coincide con lo que se ve en la lista.
  bool _visible(Map<String, dynamic> data, String patente) {
    if (!_mostrarInactivos && !AppActivo.esActivo(data)) return false;
    if (!_mostrarExcluidos &&
        ExcluidosService.esExcluido(_excluidos, patente: patente)) {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final tipos = _tipos;
    return AppScaffold(
      title: 'Gestión de Flota',
      actions: [
        // Toggle "mostrar excluidos" (tanques combustibles + tractores
        // de tanqueros). Por default OFF para que la flota operativa
        // no se mezcle con las unidades que no controlamos.
        if ((_excluidos?.patentes.isNotEmpty ?? false))
          IconButton(
            tooltip: _mostrarExcluidos
                ? 'Ocultar tanques de combustibles'
                : 'Mostrar tanques de combustibles',
            icon: Icon(
              _mostrarExcluidos
                  ? Icons.shield_moon_outlined
                  : Icons.shield_outlined,
              color: _mostrarExcluidos
                  ? AppColors.warning
                  : AppColors.textSecondary,
            ),
            onPressed: () =>
                setState(() => _mostrarExcluidos = !_mostrarExcluidos),
          ),
        IconButton(
          tooltip: _mostrarInactivos
              ? 'Ocultar unidades inactivas'
              : 'Mostrar unidades inactivas',
          icon: Icon(
            _mostrarInactivos
                ? Icons.visibility_off_outlined
                : Icons.archive_outlined,
            color: _mostrarInactivos
                ? AppColors.warning
                : AppColors.textSecondary,
          ),
          onPressed: () =>
              setState(() => _mostrarInactivos = !_mostrarInactivos),
        ),
      ],
      // Solo quien puede crear vehículos ve el FAB "Nuevo" (ADMIN/SUPERVISOR).
      floatingActionButton:
          Capabilities.can(PrefsService.rol, Capability.crearVehiculo)
              ? FloatingActionButton.extended(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AdminVehiculoAltaScreen(),
                    ),
                  ),
                  tooltip: 'Agregar nueva unidad',
                  icon: const Icon(Icons.add),
                  label: const Text('Nuevo'),
                )
              : null,
      body: Column(
        children: [
          // Encabezado Núcleo: eyebrow del tipo seleccionado + número hero
          // + AppKpiStrip (libres · asignados · taller · inactivos) de ESE
          // segmento de flota. Se alimenta del MISMO stream por-tipo que
          // consume la lista (cero lecturas extra), así los números nunca
          // divergen de lo que se ve. Debajo, los chips Núcleo siguen siendo
          // el filtro INTERACTIVO entre tipos (lógica intacta).
          _HeroFlota(
            tipo: _tipoSeleccionado,
            tipos: tipos,
            onTipo: (t) => setState(() => _tipoSeleccionado = t),
            visible: _visible,
            mostrarInactivos: _mostrarInactivos,
          ),
          Expanded(
            child: _ListaPorTipo(
              tipo: _tipoSeleccionado,
              mostrarInactivos: _mostrarInactivos,
              mostrarExcluidos: _mostrarExcluidos,
              excluidos: _excluidos,
            ),
          ),
        ],
      ),
    );
  }
}

/// Encabezado Núcleo de Gestión de Flota.
///
/// Replica el gesto del header de Personal: `AppEyebrow` (plural del tipo
/// seleccionado) + número hero (`AppType.h2`) + `AppKpiStrip` con el
/// desglose por estado (libres · asignados · taller · inactivos) de ESE
/// segmento. Debajo van los `AppFilterChip` de filtro por tipo.
///
/// El hero/KPI se derivan del MISMO stream por-tipo que ya consume la lista
/// (`getVehiculosPorTipo`) — cero lecturas extra y números que coinciden con
/// lo que se ve. Los contadores respetan el predicado de visibilidad
/// (`_visible`), salvo el de "inactivos" que se calcula aparte para que el
/// KPI tenga sentido aun con el toggle apagado.
class _HeroFlota extends StatelessWidget {
  final String tipo;
  final List<String> tipos;
  final ValueChanged<String> onTipo;
  final bool Function(Map<String, dynamic> data, String patente) visible;
  final bool mostrarInactivos;

  const _HeroFlota({
    required this.tipo,
    required this.tipos,
    required this.onTipo,
    required this.visible,
    required this.mostrarInactivos,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pluralLabel =
        AppTiposVehiculo.pluralEtiquetas[tipo] ?? tipo.toUpperCase();

    return Consumer<VehiculoProvider>(
      builder: (ctx, provider, _) => StreamBuilder<QuerySnapshot>(
        stream: provider.getVehiculosPorTipo(tipo),
        builder: (ctx, snap) {
          final docs = snap.data?.docs ?? const [];

          // Un solo barrido sobre el segmento del tipo seleccionado. El
          // total visible respeta los toggles; los KPIs de estado se cuentan
          // entre los visibles, e "inactivos" se cuenta sin importar el
          // toggle (es la utilidad del KPI: saber cuántos hay aunque estén
          // ocultos). Todo derivado de la base — cero números hardcodeados.
          var totalVisibles = 0;
          var libres = 0;
          var asignados = 0;
          var taller = 0;
          var inactivos = 0;
          for (final d in docs) {
            final data = d.data() as Map<String, dynamic>;
            if (!AppActivo.esActivo(data)) inactivos++;
            if (!visible(data, d.id)) continue;
            totalVisibles++;
            final estado =
                (data['ESTADO'] ?? 'LIBRE').toString().toUpperCase();
            switch (estado) {
              case 'OCUPADO':
              case 'ASIGNADO':
                asignados++;
              case 'TALLER':
              case 'MANTENIMIENTO':
                taller++;
              case 'LIBRE':
                libres++;
            }
          }

          final tieneDatos = snap.hasData;
          final unidadesTxt = mostrarInactivos
              ? 'unidades (incl. inactivas)'
              : 'unidades';

          return Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppEyebrow(pluralLabel),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      tieneDatos ? '$totalVisibles' : '—',
                      style: AppType.h2.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(unidadesTxt, style: AppType.monoSm),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                AppKpiStrip(
                  stats: [
                    AppStat(label: 'Libres', value: '$libres'),
                    AppStat(label: 'Asignados', value: '$asignados'),
                    AppStat(label: 'Taller', value: '$taller'),
                    AppStat(
                      label: 'Inactivos',
                      value: '$inactivos',
                      accent: inactivos > 0 ? c.warning : null,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                // Chips Núcleo de filtro por tipo. El contador de cada chip
                // refleja las unidades VISIBLES de ese tipo (respeta toggles).
                // Scroll horizontal: con 5 tipos no entran cómodos en mobile.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final t in tipos) ...[
                        _ChipTipo(
                          tipo: t,
                          activo: tipo == t,
                          visible: visible,
                          onTap: () => onTipo(t),
                        ),
                        if (t != tipos.last) const SizedBox(width: 6),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Chip de filtro por tipo de unidad. Envuelve `AppFilterChip` en un
/// `StreamBuilder` sobre el stream cacheado por tipo (`getVehiculosPorTipo`),
/// el MISMO que consume `_ListaPorTipo`, así no genera lecturas extra de
/// Firestore. El contador es la cantidad real de unidades visibles del tipo.
class _ChipTipo extends StatelessWidget {
  final String tipo;
  final bool activo;
  final bool Function(Map<String, dynamic> data, String patente) visible;
  final VoidCallback onTap;

  const _ChipTipo({
    required this.tipo,
    required this.activo,
    required this.visible,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = AppTiposVehiculo.pluralEtiquetas[tipo] ?? tipo;
    return Consumer<VehiculoProvider>(
      builder: (ctx, provider, _) => StreamBuilder<QuerySnapshot>(
        stream: provider.getVehiculosPorTipo(tipo),
        builder: (ctx, snap) {
          var count = 0;
          for (final d in snap.data?.docs ?? const []) {
            final data = d.data() as Map<String, dynamic>;
            if (visible(data, d.id)) count++;
          }
          return AppFilterChip(
            label: label,
            count: count,
            activo: activo,
            onTap: onTap,
          );
        },
      ),
    );
  }
}

