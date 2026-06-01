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

  @override
  Widget build(BuildContext context) {
    final tipos = _tipos;
    return DefaultTabController(
      length: tipos.length,
      child: AppScaffold(
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
        // isScrollable: con 5 tabs no entran cómodos en una sola fila;
        // esto los hace deslizables horizontalmente.
        bottom: TabBar(
          isScrollable: true,
          tabs: [
            for (final t in tipos)
              Tab(text: AppTiposVehiculo.pluralEtiquetas[t] ?? t),
          ],
        ),
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
        body: TabBarView(
          children: [
            for (final t in tipos)
              _ListaPorTipo(
                tipo: t,
                mostrarInactivos: _mostrarInactivos,
                mostrarExcluidos: _mostrarExcluidos,
                excluidos: _excluidos,
              ),
          ],
        ),
      ),
    );
  }
}

