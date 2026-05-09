import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/viaje.dart';
import '../services/viajes_service.dart';

/// Lista de viajes — entry point del módulo. Filtros operativos
/// (estado + liquidado) y FAB para crear viaje nuevo.
///
/// Cada fila muestra los datos clave para identificar el viaje sin
/// abrir el detalle: fecha, chofer, ruta, monto chofer redondeado y
/// chips de estado/liquidación. Tap → detalle.
class LogisticaViajesListaScreen extends StatefulWidget {
  const LogisticaViajesListaScreen({super.key});

  @override
  State<LogisticaViajesListaScreen> createState() =>
      _LogisticaViajesListaScreenState();
}

class _LogisticaViajesListaScreenState
    extends State<LogisticaViajesListaScreen> {
  EstadoViaje? _filtroEstado;
  bool? _filtroLiquidado; // null = todos, true = solo liquidados, false = solo no
  bool _verBorrados = false;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Viajes',
      body: Column(
        children: [
          _BarraFiltros(
            estado: _filtroEstado,
            liquidado: _filtroLiquidado,
            verBorrados: _verBorrados,
            onEstadoChanged: (v) => setState(() => _filtroEstado = v),
            onLiquidadoChanged: (v) => setState(() => _filtroLiquidado = v),
            onVerBorradosChanged: (v) => setState(() => _verBorrados = v),
          ),
          Expanded(
            child: StreamBuilder<List<Viaje>>(
              stream: ViajesService.streamViajes(
                incluirInactivos: _verBorrados,
              ),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Error: ${snap.error}',
                        style: const TextStyle(color: AppColors.accentRed),
                      ),
                    ),
                  );
                }
                final todos = snap.data ?? const <Viaje>[];
                final filtrados = _aplicarFiltros(todos);
                if (filtrados.isEmpty) {
                  return _EstadoVacio(haDatos: todos.isNotEmpty);
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                  itemCount: filtrados.length,
                  itemBuilder: (_, i) => _ViajeTile(viaje: filtrados[i]),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pushNamed(
          context,
          AppRoutes.adminLogisticaViajeForm,
        ),
        backgroundColor: AppColors.accentOrange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('NUEVO VIAJE'),
      ),
    );
  }

  List<Viaje> _aplicarFiltros(List<Viaje> docs) {
    return docs.where((v) {
      if (_filtroEstado != null && v.estado != _filtroEstado) return false;
      if (_filtroLiquidado == true && !v.liquidado) return false;
      if (_filtroLiquidado == false && v.liquidado) return false;
      return true;
    }).toList();
  }
}

class _BarraFiltros extends StatelessWidget {
  final EstadoViaje? estado;
  final bool? liquidado;
  final bool verBorrados;
  final ValueChanged<EstadoViaje?> onEstadoChanged;
  final ValueChanged<bool?> onLiquidadoChanged;
  final ValueChanged<bool> onVerBorradosChanged;

  const _BarraFiltros({
    required this.estado,
    required this.liquidado,
    required this.verBorrados,
    required this.onEstadoChanged,
    required this.onLiquidadoChanged,
    required this.onVerBorradosChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _ChipFiltro<EstadoViaje?>(
            label: estado == null ? 'Estado' : estado!.etiqueta,
            seleccionado: estado != null,
            onSelected: () => _abrirEstadoMenu(context),
          ),
          _ChipFiltro<bool?>(
            label: liquidado == null
                ? 'Liquidación'
                : (liquidado! ? 'Liquidados' : 'Sin liquidar'),
            seleccionado: liquidado != null,
            onSelected: () => _abrirLiquidadoMenu(context),
          ),
          FilterChip(
            label: const Text('Ver borrados'),
            selected: verBorrados,
            onSelected: onVerBorradosChanged,
            selectedColor: AppColors.accentRed.withValues(alpha: 0.2),
            checkmarkColor: AppColors.accentRed,
          ),
        ],
      ),
    );
  }

  Future<void> _abrirEstadoMenu(BuildContext ctx) async {
    final res = await showMenu<EstadoViaje?>(
      context: ctx,
      position: const RelativeRect.fromLTRB(40, 120, 40, 0),
      items: [
        const PopupMenuItem(value: null, child: Text('Todos')),
        ...EstadoViaje.values.map(
          (e) => PopupMenuItem(value: e, child: Text(e.etiqueta)),
        ),
      ],
    );
    // Hack para distinguir "no eligió nada" (dismiss) vs "eligió Todos" (null).
    // showMenu devuelve null en ambos. Lo aceptamos: dismiss = mantiene filtro.
    if (res != null || (res == null && ctx.mounted)) {
      onEstadoChanged(res);
    }
  }

  Future<void> _abrirLiquidadoMenu(BuildContext ctx) async {
    final res = await showMenu<int>(
      context: ctx,
      position: const RelativeRect.fromLTRB(40, 120, 40, 0),
      items: const [
        PopupMenuItem(value: 0, child: Text('Todos')),
        PopupMenuItem(value: 1, child: Text('Liquidados')),
        PopupMenuItem(value: 2, child: Text('Sin liquidar')),
      ],
    );
    if (res == null) return;
    onLiquidadoChanged(res == 0 ? null : res == 1);
  }
}

class _ChipFiltro<T> extends StatelessWidget {
  final String label;
  final bool seleccionado;
  final VoidCallback onSelected;

  const _ChipFiltro({
    required this.label,
    required this.seleccionado,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
      backgroundColor: seleccionado
          ? AppColors.accentOrange.withValues(alpha: 0.2)
          : null,
      onPressed: onSelected,
    );
  }
}

class _ViajeTile extends StatelessWidget {
  final Viaje viaje;
  const _ViajeTile({required this.viaje});

  @override
  Widget build(BuildContext context) {
    final ts = viaje.tarifaSnapshot;
    final fechaRef = viaje.fechaCarga ?? viaje.creadoEn;
    final color = _colorEstado(viaje.estado);

    return AppCard(
      onTap: () => Navigator.pushNamed(
        context,
        AppRoutes.adminLogisticaViajeDetalle,
        arguments: {'viajeId': viaje.id},
      ),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Línea 1: fecha + chofer + estado.
          Row(
            children: [
              Icon(Icons.local_shipping_outlined, size: 18, color: color),
              const SizedBox(width: 6),
              Text(
                fechaRef == null
                    ? 'Sin fecha'
                    : AppFormatters.formatearFecha(fechaRef),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  viaje.choferNombre ?? 'DNI ${viaje.choferDni}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _ChipMini(label: viaje.estado.etiqueta, color: color),
            ],
          ),
          const SizedBox(height: 6),
          // Línea 2: ruta.
          Row(
            children: [
              const Icon(Icons.place_outlined,
                  size: 14, color: Colors.white38),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${ts.origenEtiqueta} → ${ts.destinoEtiqueta}',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Línea 3: monto chofer redondeado + flags.
          Row(
            children: [
              const Icon(Icons.attach_money,
                  size: 14, color: Colors.white38),
              const SizedBox(width: 2),
              Text(
                AppFormatters.formatearMonto(viaje.montoChoferRedondeado),
                style: const TextStyle(
                  color: AppColors.accentGreen,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              if (viaje.liquidado)
                const _ChipMini(
                  label: 'LIQUIDADO',
                  color: AppColors.accentGreen,
                  icono: Icons.check,
                ),
              if (!viaje.activo)
                const _ChipMini(
                  label: 'BORRADO',
                  color: AppColors.accentRed,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Color _colorEstado(EstadoViaje e) {
    switch (e) {
      case EstadoViaje.planeado:
        return AppColors.accentBlue;
      case EstadoViaje.enCurso:
        return AppColors.accentAmber;
      case EstadoViaje.completado:
        return AppColors.accentGreen;
      case EstadoViaje.cancelado:
        return AppColors.accentRed;
      case EstadoViaje.postergado:
        return Colors.purple;
    }
  }
}

class _ChipMini extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icono;
  const _ChipMini({required this.label, required this.color, this.icono});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icono != null) ...[
            Icon(icono, size: 11, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _EstadoVacio extends StatelessWidget {
  final bool haDatos;
  const _EstadoVacio({required this.haDatos});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.route_outlined,
                size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            Text(
              haDatos
                  ? 'Ningún viaje coincide con los filtros aplicados.'
                  : 'Todavía no hay viajes registrados.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }
}
