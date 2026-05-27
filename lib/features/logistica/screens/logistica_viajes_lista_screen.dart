import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/keyboard_shortcuts.dart';
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
  // Texto de búsqueda libre (auditoria 2026-05-17). Matcha chofer,
  // patente, empresa origen/destino, ubicación origen/destino, producto.
  // Lo dispara el TextField de la barra superior — siempre lowercase.
  String _busqueda = '';
  late final TextEditingController _busquedaCtrl;

  @override
  void initState() {
    super.initState();
    _busquedaCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  void _abrirNuevoViaje() {
    Navigator.pushNamed(context, AppRoutes.adminLogisticaViajeForm);
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Viajes',
      // Ctrl+N → nuevo viaje (operador desktop tipea mucho —
      // Santiago 2026-05-13). Sin search field acá, así que no
      // mapeamos Ctrl+F.
      body: KeyboardShortcutsScope(
        onNuevo: _abrirNuevoViaje,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                controller: _busquedaCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Buscar por chofer, patente, empresa, producto…',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon:
                      const Icon(Icons.search, color: Colors.white54),
                  suffixIcon: _busqueda.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear,
                              color: Colors.white54),
                          tooltip: 'Limpiar búsqueda',
                          onPressed: () {
                            _busquedaCtrl.clear();
                            setState(() => _busqueda = '');
                          },
                        ),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: Colors.white24),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: Colors.white24),
                  ),
                ),
                onChanged: (v) =>
                    setState(() => _busqueda = v.trim().toLowerCase()),
              ),
            ),
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
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _abrirNuevoViaje,
        backgroundColor: AppColors.warning,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('NUEVO VIAJE'),
      ),
    );
  }

  List<Viaje> _aplicarFiltros(List<Viaje> docs) {
    final q = _busqueda;
    final filtrados = docs.where((v) {
      if (_filtroEstado != null && v.estado != _filtroEstado) return false;
      if (_filtroLiquidado == true && !v.liquidado) return false;
      if (_filtroLiquidado == false && v.liquidado) return false;
      // Búsqueda libre: matchea chofer (DNI+nombre), patente del
      // vehículo/enganche, y por cada tramo: empresa origen/destino,
      // ubicación origen/destino y producto. Si el query es vacio,
      // pasa todo.
      if (q.isNotEmpty) {
        final hayMatch = (v.choferNombre?.toLowerCase() ?? '').contains(q) ||
            v.choferDni.toLowerCase().contains(q) ||
            (v.vehiculoId?.toLowerCase() ?? '').contains(q) ||
            (v.engancheId?.toLowerCase() ?? '').contains(q) ||
            v.tramos.any((t) {
              final s = t.tarifaSnapshot;
              return s.empresaOrigenNombre.toLowerCase().contains(q) ||
                  s.empresaDestinoNombre.toLowerCase().contains(q) ||
                  s.origenEtiqueta.toLowerCase().contains(q) ||
                  s.destinoEtiqueta.toLowerCase().contains(q) ||
                  (t.producto?.toLowerCase() ?? '').contains(q) ||
                  (s.producto?.toLowerCase() ?? '').contains(q);
            });
        if (!hayMatch) return false;
      }
      return true;
    }).toList();
    // Orden: más viejo arriba (ascendente por fecha de referencia,
    // que es la fecha de carga del primer tramo o el creado_en si
    // no hay carga). Pedido Santiago 2026-05-14: facilita ver primero
    // los viajes pendientes más antiguos. El service entrega
    // descendente; lo invertimos solo en esta pantalla.
    filtrados.sort((a, b) {
      final fa = a.fechaReferencia;
      final fb = b.fechaReferencia;
      if (fa == null && fb == null) return 0;
      if (fa == null) return 1; // sin fecha al final
      if (fb == null) return -1;
      return fa.compareTo(fb);
    });
    return filtrados;
  }
}

// Sentinel para el menú "Todos" — permite distinguir "el user eligio
// limpiar el filtro" de "el user dismisseo el menu sin elegir" (showMenu
// devuelve null en ambos por default).
const Object _kTodos = Object();

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
          // Filtro "Mostrar eliminados". Default OFF — los borrados
          // viven solo para auditoría. Mismo patrón visual que el
          // chip de adelantos (Santiago 2026-05-14).
          FilterChip(
            label: const Text('Mostrar eliminados'),
            selected: verBorrados,
            onSelected: onVerBorradosChanged,
            selectedColor: AppColors.accentRed.withValues(alpha: 0.4),
            avatar: Icon(
              verBorrados ? Icons.visibility : Icons.visibility_off,
              size: 16,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _abrirEstadoMenu(BuildContext ctx) async {
    // Usamos `Object` con sentinel `_kTodos` para distinguir "el user
    // eligio Todos (limpiar filtro)" vs "el user dismisseo con back/tap
    // afuera (mantener filtro)". showMenu devuelve null para dismiss —
    // si tambien usamos null para "Todos", no podemos diferenciar.
    // El comentario anterior decia "dismiss = mantiene filtro" pero la
    // logica `res != null || (res == null && ctx.mounted)` SIEMPRE era
    // true cuando el widget esta montado → el filtro se reseteaba al
    // cerrar el menu con back (auditoria 2026-05-16).
    final res = await showMenu<Object>(
      context: ctx,
      position: const RelativeRect.fromLTRB(40, 120, 40, 0),
      items: [
        const PopupMenuItem(value: _kTodos, child: Text('Todos')),
        ...EstadoViaje.values.map(
          (e) => PopupMenuItem<Object>(value: e, child: Text(e.etiqueta)),
        ),
      ],
    );
    if (res == null) return; // dismiss → no toca el filtro actual
    if (res == _kTodos) {
      onEstadoChanged(null);
    } else if (res is EstadoViaje) {
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
          ? AppColors.warning.withValues(alpha: 0.2)
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
    final fechaRef = viaje.fechaReferencia;
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
                  viaje.rutaEtiqueta,
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
                  color: AppColors.success,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              if (viaje.liquidado)
                const _ChipMini(
                  label: 'LIQUIDADO',
                  color: AppColors.success,
                  icono: Icons.check,
                ),
              if (!viaje.activo) ...[
                const _ChipMini(
                  label: 'BORRADO',
                  color: AppColors.accentRed,
                ),
                const SizedBox(width: 4),
                // Botón rápido restaurar — evita abrir el detalle solo
                // para reactivar. Confirmación inline en diálogo corto.
                Builder(
                  builder: (ctx) => IconButton(
                    icon: const Icon(Icons.restore,
                        size: 18, color: AppColors.warning),
                    tooltip: 'Reactivar viaje',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                    onPressed: () => _confirmarReactivar(ctx, viaje),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmarReactivar(BuildContext ctx, Viaje v) async {
    final messenger = ScaffoldMessenger.of(ctx);
    final fecha = v.fechaReferencia;
    final fechaStr = fecha == null
        ? 'sin fecha'
        : AppFormatters.formatearFecha(fecha);
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        title: const Text('Reactivar viaje'),
        content: Text(
          'Vas a reactivar el viaje de ${v.choferNombre ?? "DNI ${v.choferDni}"} '
          '($fechaStr · ${v.rutaEtiqueta}). Vuelve a aparecer en la lista '
          'normal y entra otra vez en LIQUIDACIÓN.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('CANCELAR'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.warning,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('REACTIVAR'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ViajesService.reactivarViaje(
        viajeId: v.id,
        reactivadoPorDni: PrefsService.dni,
      );
      AppFeedback.successOn(messenger, 'Viaje reactivado.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo reactivar el viaje. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  Color _colorEstado(EstadoViaje e) {
    switch (e) {
      case EstadoViaje.planeado:
        return AppColors.accentBlue;
      case EstadoViaje.enCurso:
        return AppColors.warning;
      case EstadoViaje.concluido:
        return AppColors.success;
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
