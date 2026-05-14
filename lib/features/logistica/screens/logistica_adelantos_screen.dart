import 'dart:io' show File, Platform, Process;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/keyboard_shortcuts.dart';
import '../models/adelanto_chofer.dart';
import '../services/adelantos_service.dart';
import '../services/recibos_adelanto_service.dart';
import '../services/report_adelantos.dart';

/// ABM de adelantos a chofer. Lista por fecha desc, alta vía dialog,
/// edición inline al tocar la card, eliminar con confirmación,
/// imprimir comprobante (asigna correlativo server-side la primera vez,
/// reusa el mismo en reimpresiones).
///
/// Decisión Santiago 2026-05-13: los adelantos viven en su propia
/// colección (ADELANTOS_CHOFER) — antes vivían como subcampos del
/// viaje, lo cual obligaba a crear viajes vacíos para registrar
/// adelantos de sueldo. Ahora son independientes.
class LogisticaAdelantosScreen extends StatefulWidget {
  const LogisticaAdelantosScreen({super.key});

  @override
  State<LogisticaAdelantosScreen> createState() =>
      _LogisticaAdelantosScreenState();
}

class _LogisticaAdelantosScreenState extends State<LogisticaAdelantosScreen> {
  String _filtro = '';

  /// FocusNode del campo de búsqueda — Ctrl+F lo enfoca.
  final FocusNode _buscarFocus = FocusNode();

  /// Filtros de fecha (desde/hasta, inclusive). Si null, no aplica.
  /// El operador suele querer "los adelantos de este mes" o "del último
  /// pago de sueldo hasta hoy" — el rango lo arma con 2 date pickers.
  DateTime? _fechaDesde;
  DateTime? _fechaHasta;

  /// Si true, también muestra los adelantos eliminados (soft-delete).
  /// Por default false — el caso operativo es "ver lo activo". Los
  /// eliminados quedan en la base para auditoría (saber por qué se
  /// quemó cada número de recibo) y se ven activando este chip.
  bool _mostrarEliminados = false;

  @override
  void dispose() {
    _buscarFocus.dispose();
    super.dispose();
  }

  /// IDs de adelantos PENDIENTES deseleccionados para el resumen.
  /// Default: todos los pendientes visibles están seleccionados (set
  /// vacío). El operador destildea los que NO quiere incluir.
  /// **Los adelantos PAGADOS NUNCA son seleccionables** — ya están
  /// liquidados, no tiene sentido reimprimirlos en el resumen de
  /// pendientes. El operador puede toggle pagado/pendiente por card.
  final Set<String> _deseleccionados = {};

  bool _seleccionable(AdelantoChofer a) => !a.pagado && !a.eliminado;
  bool _seleccionado(AdelantoChofer a) =>
      _seleccionable(a) && !_deseleccionados.contains(a.id);

  void _toggleSeleccion(AdelantoChofer a) {
    if (!_seleccionable(a)) return;
    setState(() {
      if (_deseleccionados.contains(a.id)) {
        _deseleccionados.remove(a.id);
      } else {
        _deseleccionados.add(a.id);
      }
    });
  }

  Future<void> _togglePagado(AdelantoChofer a) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AdelantosService.setPagado(
        adelantoId: a.id,
        pagado: !a.pagado,
        marcadoPorDni: PrefsService.dni,
      );
      AppFeedback.successOn(
        messenger,
        a.pagado ? 'Adelanto marcado como pendiente.' : 'Adelanto marcado como pagado.',
      );
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Adelantos',
      floatingActionButton: Builder(
        builder: (ctx) => FloatingActionButton.extended(
          backgroundColor: AppColors.accentGreen,
          onPressed: () => _abrirAlta(ctx),
          icon: const Icon(Icons.add),
          label: const Text('NUEVO ADELANTO'),
        ),
      ),
      // Atajos desktop (Santiago 2026-05-13): Ctrl+N nuevo adelanto,
      // Ctrl+F enfoca el buscador. Wrappeamos el body completo así
      // los atajos disparan aún si el operador está scroleando o el
      // foco está en una card.
      body: KeyboardShortcutsScope(
        onNuevo: () => _abrirAlta(context),
        buscarFocusNode: _buscarFocus,
        child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              focusNode: _buscarFocus,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: 'Buscar por chofer, observación…',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _filtro.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(() => _filtro = ''),
                      ),
              ),
              onChanged: (v) => setState(() => _filtro = v),
            ),
          ),
          // ─── Filtro de rango de fechas (1 calendario, 2 puntas) ─
          // Antes había 2 botones separados (DESDE / HASTA) que
          // abrían pickers de fecha individuales. Santiago pidió un
          // solo botón que abra `showDateRangePicker` — el operador
          // marca inicio y fin en el mismo calendario, más natural.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: _BotonRangoFechas(
                    desde: _fechaDesde,
                    hasta: _fechaHasta,
                    onChanged: (desde, hasta) {
                      setState(() {
                        _fechaDesde = desde;
                        _fechaHasta = hasta;
                      });
                    },
                  ),
                ),
                if (_fechaDesde != null || _fechaHasta != null)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    tooltip: 'Limpiar fechas',
                    onPressed: () => setState(() {
                      _fechaDesde = null;
                      _fechaHasta = null;
                    }),
                  ),
              ],
            ),
          ),
          // Filtro "Mostrar eliminados". Default OFF — los eliminados
          // viven solo para auditoría (saber por qué se quemó cada
          // número de recibo). Pedido Santiago 2026-05-14.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('Mostrar eliminados'),
                  selected: _mostrarEliminados,
                  onSelected: (v) =>
                      setState(() => _mostrarEliminados = v),
                  selectedColor:
                      AppColors.accentRed.withValues(alpha: 0.4),
                  avatar: Icon(
                    _mostrarEliminados
                        ? Icons.visibility
                        : Icons.visibility_off,
                    size: 16,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<AdelantoChofer>>(
              stream: AdelantosService.streamAdelantos(),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return AppEmptyState(
                    icon: Icons.error_outline,
                    title: 'Error cargando adelantos',
                    subtitle: snap.error.toString(),
                  );
                }
                final items = snap.data ?? const [];
                if (items.isEmpty) {
                  return const AppEmptyState(
                    icon: Icons.payments_outlined,
                    title: 'Sin adelantos cargados',
                    subtitle: 'Tocá "NUEVO ADELANTO" para registrar el primero.',
                  );
                }
                final filtrados = _aplicarFiltro(items);
                if (filtrados.isEmpty) {
                  return const AppEmptyState(
                    icon: Icons.search_off,
                    title: 'Sin resultados',
                    subtitle:
                        'Ningún adelanto coincide con los filtros actuales. '
                        'Probá cambiar el rango de fechas o el texto.',
                  );
                }
                // Barra de selección + imprimir. La lista muestra
                // todos los adelantos (pagados + pendientes). Solo
                // los PENDIENTES son seleccionables para el resumen.
                final pendientes =
                    filtrados.where(_seleccionable).toList();
                final seleccionados = pendientes
                    .where(_seleccionado)
                    .toList();
                return Column(
                  children: [
                    _BarraSeleccion(
                      totalPendientes: pendientes.length,
                      totalSeleccionados: seleccionados.length,
                      onSeleccionarTodos: () =>
                          setState(() => _deseleccionados.clear()),
                      onDeseleccionarTodos: () => setState(() =>
                          _deseleccionados.addAll(
                              pendientes.map((a) => a.id))),
                      onImprimir: seleccionados.isEmpty
                          ? null
                          : () => _imprimirResumen(seleccionados),
                    ),
                    Expanded(
                      child: ListView.separated(
                        padding:
                            const EdgeInsets.fromLTRB(12, 4, 12, 90),
                        itemCount: filtrados.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final a = filtrados[i];
                          return _CardAdelanto(
                            adelanto: a,
                            seleccionado: _seleccionado(a),
                            onToggleSeleccion: () => _toggleSeleccion(a),
                            onTogglePagado: () => _togglePagado(a),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// Aplica los 3 filtros activos: texto (token-based), fecha desde
  /// y fecha hasta. El stream ya viene ordenado por fecha desc desde
  /// el service.
  List<AdelantoChofer> _aplicarFiltro(List<AdelantoChofer> items) {
    Iterable<AdelantoChofer> it = items;
    // Filtro de soft-delete: por default NO mostrar eliminados.
    // El operador puede activar el chip "Mostrar eliminados" para
    // ver auditoría de adelantos cancelados.
    if (!_mostrarEliminados) {
      it = it.where((a) => !a.eliminado);
    }
    // Fecha desde (inclusive — comparamos contra inicio del día).
    if (_fechaDesde != null) {
      final desde = DateTime(
          _fechaDesde!.year, _fechaDesde!.month, _fechaDesde!.day);
      it = it.where((a) => !a.fecha.isBefore(desde));
    }
    // Fecha hasta (inclusive — comparamos contra el inicio del día
    // siguiente para incluir todo el día "hasta").
    if (_fechaHasta != null) {
      final finDelDia = DateTime(_fechaHasta!.year, _fechaHasta!.month,
          _fechaHasta!.day + 1);
      it = it.where((a) => a.fecha.isBefore(finDelDia));
    }
    // Texto.
    final q = _filtro.trim().toLowerCase();
    if (q.isNotEmpty) {
      final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
      it = it.where((a) {
        final hay = [
          a.choferNombre ?? '',
          a.choferDni,
          a.observacion ?? '',
          if (a.numeroRecibo != null) 'recibo n${a.numeroRecibo}',
        ].join(' ').toLowerCase();
        for (final t in tokens) {
          if (!hay.contains(t)) return false;
        }
        return true;
      });
    }
    // Orden: más viejo primero (ascendente por fecha). Pedido
    // Santiago 2026-05-14: facilita ver primero los pendientes
    // antiguos que esperan pago. El service entrega descendente
    // por convención general; lo invertimos solo para esta pantalla.
    final list = it.toList();
    list.sort((a, b) => a.fecha.compareTo(b.fecha));
    return list;
  }

  Future<void> _abrirAlta(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (_) => const _AdelantoFormDialog(),
    );
  }

  Future<void> _imprimirResumen(List<AdelantoChofer> seleccionados) async {
    await ReportAdelantosService.generar(
      context: context,
      adelantos: seleccionados,
      fechaDesde: _fechaDesde,
      fechaHasta: _fechaHasta,
    );
    // Después de imprimir, ofrecer marcar como pagados en bulk. El
    // flow operativo es: "imprimo el resumen para que la oficina
    // pague → cuando ya pagaron, marco todos como pagados". Si el
    // operador decide hacerlo después manualmente, también puede.
    if (!mounted) return;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(dCtx).colorScheme.surface,
        title: const Text('¿Marcar estos adelantos como pagados?'),
        content: Text(
          'Acabás de imprimir el resumen de ${seleccionados.length} '
          'adelanto(s). Si ya se pagaron, podés marcarlos ahora — '
          'dejarán de aparecer en el próximo resumen de pendientes.\n\n'
          'Si todavía falta efectivamente pagarlos, dale "Más tarde" '
          'y los marcás cuando corresponda.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('MÁS TARDE'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accentGreen,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('MARCAR PAGADOS'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AdelantosService.marcarPagadosBulk(
        adelantoIds: seleccionados.map((a) => a.id).toList(),
        marcadoPorDni: PrefsService.dni,
      );
      AppFeedback.successOn(
        messenger,
        '${seleccionados.length} adelanto(s) marcado(s) como pagado(s).',
      );
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error al marcar pagados: $e');
    }
  }
}

// =============================================================================
// FILTROS / BARRA DE SELECCIÓN
// =============================================================================

/// Botón único que abre un selector de RANGO de fechas
/// (`showDateRangePicker` de Material — un solo calendario donde el
/// operador marca punta de inicio y punta de fin). Reemplaza la
/// versión de 2 botones separados (DESDE / HASTA) por pedido de
/// Santiago 2026-05-13: más natural ver el rango de un vistazo en el
/// mismo calendario.
///
/// El label cambia según el estado:
///   - Sin rango   → "RANGO DE FECHAS"
///   - Solo desde  → "13-05-2026 → ?"      (caso intermedio, raro)
///   - Solo hasta  → "? → 15-05-2026"
///   - Ambos       → "13-05-2026 → 15-05-2026"
///   - Mismo día   → "13-05-2026"
class _BotonRangoFechas extends StatelessWidget {
  final DateTime? desde;
  final DateTime? hasta;
  final void Function(DateTime? desde, DateTime? hasta) onChanged;

  const _BotonRangoFechas({
    required this.desde,
    required this.hasta,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hayRango = desde != null || hasta != null;
    final label = _renderLabel();
    return OutlinedButton.icon(
      onPressed: () async {
        final ahora = DateTime.now();
        final inicial = desde != null && hasta != null
            ? DateTimeRange(start: desde!, end: hasta!)
            : DateTimeRange(start: ahora, end: ahora);
        final rango = await showDateRangePicker(
          context: context,
          initialDateRange: inicial,
          firstDate: DateTime(ahora.year - 2),
          lastDate: DateTime(ahora.year + 1),
          // En Windows desktop el picker se ve mejor como dialog (más
          // chico, sin ocupar toda la pantalla). En mobile queda
          // full-screen por default, que también está OK.
          initialEntryMode: DatePickerEntryMode.calendar,
          helpText: 'Elegí el rango de fechas',
          saveText: 'APLICAR',
          cancelText: 'CANCELAR',
        );
        if (rango != null) onChanged(rango.start, rango.end);
      },
      onLongPress: hayRango ? () => onChanged(null, null) : null,
      icon: const Icon(Icons.date_range_outlined, size: 16),
      label: Text(
        label,
        style: const TextStyle(fontSize: 12),
        overflow: TextOverflow.ellipsis,
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: hayRango ? Colors.white : Colors.white60,
        side: BorderSide(
          color: hayRango ? AppColors.accentGreen : Colors.white24,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  String _renderLabel() {
    final d = desde;
    final h = hasta;
    if (d == null && h == null) return 'RANGO DE FECHAS';
    const fmt = AppFormatters.formatearFecha;
    if (d != null && h != null) {
      // Si ambas puntas son el mismo día, mostramos una sola fecha
      // (el operador querría ver "solo 13-05", no "13-05 → 13-05").
      final mismoDia = d.year == h.year && d.month == h.month && d.day == h.day;
      return mismoDia ? fmt(d) : '${fmt(d)} → ${fmt(h)}';
    }
    if (d != null) return '${fmt(d)} → ?';
    return '? → ${fmt(h!)}';
  }
}

/// Barra que muestra cuántos adelantos están seleccionados +
/// botones para seleccionar/deseleccionar todos + botón EXPORTAR.
/// Aparece arriba de la lista cuando hay al menos 1 adelanto visible.
class _BarraSeleccion extends StatelessWidget {
  /// Total de adelantos PENDIENTES en la lista filtrada (los pagados
  /// no cuentan — no son seleccionables).
  final int totalPendientes;
  final int totalSeleccionados;
  final VoidCallback onSeleccionarTodos;
  final VoidCallback onDeseleccionarTodos;
  final VoidCallback? onImprimir;

  const _BarraSeleccion({
    required this.totalPendientes,
    required this.totalSeleccionados,
    required this.onSeleccionarTodos,
    required this.onDeseleccionarTodos,
    required this.onImprimir,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          Text(
            totalPendientes == 0
                ? 'Sin pendientes'
                : '$totalSeleccionados / $totalPendientes pendiente(s)',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const Spacer(),
          TextButton(
            onPressed: totalSeleccionados == totalPendientes
                ? null
                : onSeleccionarTodos,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('TODOS', style: TextStyle(fontSize: 11)),
          ),
          TextButton(
            onPressed:
                totalSeleccionados == 0 ? null : onDeseleccionarTodos,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('NINGUNO', style: TextStyle(fontSize: 11)),
          ),
          const SizedBox(width: 4),
          ElevatedButton.icon(
            onPressed: onImprimir,
            icon: const Icon(Icons.print_outlined, size: 16),
            label: Text(
              'IMPRIMIR PENDIENTES ($totalSeleccionados)',
              style: const TextStyle(fontSize: 11),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// CARD
// =============================================================================

class _CardAdelanto extends StatelessWidget {
  final AdelantoChofer adelanto;
  /// `true` si va a entrar en el resumen al imprimir. Los adelantos
  /// ya pagados NUNCA están seleccionados — se ven más atenuados
  /// con un chip "PAGADO".
  final bool seleccionado;
  final VoidCallback onToggleSeleccion;
  final VoidCallback onTogglePagado;

  const _CardAdelanto({
    required this.adelanto,
    required this.seleccionado,
    required this.onToggleSeleccion,
    required this.onTogglePagado,
  });

  @override
  Widget build(BuildContext context) {
    final fechaFmt = AppFormatters.formatearFecha(adelanto.fecha);
    final montoFmt = AppFormatters.formatearMonto(adelanto.monto);
    final chofer = adelanto.choferNombre?.trim().isNotEmpty == true
        ? adelanto.choferNombre!.trim()
        : 'DNI ${adelanto.choferDni}';
    final yaImpreso = adelanto.numeroRecibo != null;
    final pagado = adelanto.pagado;
    final eliminado = adelanto.eliminado;

    // Opacidad: pagados se ven más apagados que pendientes
    // deseleccionados. Distingue 4 estados visuales:
    //   pendiente seleccionado    → 1.00 (normal)
    //   pendiente deseleccionado  → 0.55 (atenuado)
    //   pagado                    → 0.40 (más atenuado, fuera de juego)
    //   eliminado                 → 0.35 (casi gris, banner rojo)
    final double opacidad = eliminado
        ? 0.35
        : (pagado ? 0.40 : (seleccionado ? 1.0 : 0.55));

    return Opacity(
      opacity: opacidad,
      child: AppCard(
        // Eliminados NO abren el form de edición — están "congelados".
        onTap: eliminado
            ? null
            : () => showDialog(
                  context: context,
                  builder: (_) => _AdelantoFormDialog(adelanto: adelanto),
                ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Banner de "ELIMINADO" arriba del todo si aplica. Muestra
            // el motivo si lo hay (Santiago 2026-05-14: queremos saber
            // por qué se quemó cada número de recibo).
            if (eliminado) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accentRed.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color:
                          AppColors.accentRed.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.delete_forever,
                        size: 14, color: AppColors.accentRed),
                    const SizedBox(width: 6),
                    const Text(
                      'ELIMINADO',
                      style: TextStyle(
                        color: AppColors.accentRed,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    if (adelanto.eliminadoEn != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        AppFormatters.formatearFechaHoraSinSegundos(
                            adelanto.eliminadoEn!),
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 10,
                        ),
                      ),
                    ],
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => _restaurar(context),
                      icon: const Icon(Icons.restore, size: 14),
                      label: const Text('RESTAURAR'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.accentBlue,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                    ),
                  ],
                ),
              ),
              if (adelanto.eliminadoMotivo != null &&
                  adelanto.eliminadoMotivo!.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Motivo: ${adelanto.eliminadoMotivo!.trim()}',
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                // Checkbox solo para PENDIENTES no-eliminados. Los pagados
                // muestran un ícono de check fijo. Los eliminados un ícono
                // de basura.
                if (eliminado)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: Icon(Icons.delete_outline,
                        color: AppColors.accentRed, size: 20),
                  )
                else if (pagado)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: Icon(Icons.check_circle,
                        color: AppColors.accentGreen, size: 20),
                  )
                else
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Checkbox(
                      value: seleccionado,
                      onChanged: (_) => onToggleSeleccion(),
                      visualDensity: VisualDensity.compact,
                      activeColor: AppColors.accentBlue,
                    ),
                  ),
                const SizedBox(width: 4),
                const Icon(Icons.payments_outlined,
                    size: 20, color: AppColors.accentGreen),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    chofer,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '\$ $montoFmt',
                  style: const TextStyle(
                    color: AppColors.accentGreen,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (!eliminado)
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: AppColors.accentRed),
                    tooltip: 'Eliminar adelanto',
                    onPressed: () => _confirmarEliminar(context),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.calendar_today_outlined,
                      size: 12, color: Colors.white54),
                  const SizedBox(width: 4),
                  Text(
                    fechaFmt,
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
              // Chip de medio de pago. Color: amber para transferencia
              // (porque suele requerir más seguimiento — comprobante
              // bancario, etc.), teal para efectivo (entrega directa).
              _ChipMedioPago(medio: adelanto.medioPago),
              // Chip tappeable de estado de pago. PENDIENTE = naranja,
              // PAGADO = verde con fecha. Tap → toggle (con feedback
              // del service). Si el adelanto está eliminado, NO es
              // tappeable (no tiene sentido marcar pagado algo que
              // ya cancelaste).
              InkWell(
                onTap: eliminado ? null : onTogglePagado,
                child: _ChipEstadoPago(
                  pagado: pagado,
                  pagadoEn: adelanto.pagadoEn,
                ),
              ),
              if (yaImpreso)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.receipt_long_outlined,
                        size: 12, color: AppColors.accentBlue),
                    const SizedBox(width: 4),
                    Text(
                      'Recibo N° ${adelanto.numeroRecibo!.toString().padLeft(6, '0')}',
                      style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (adelanto.observacion != null &&
              adelanto.observacion!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              adelanto.observacion!,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
            // El botón de imprimir comprobante NO se muestra en
            // adelantos eliminados — si el adelanto está cancelado,
            // imprimirle un comprobante "queman" más papel sin sentido.
            // Las reimpresiones de adelantos válidos sí están OK.
            if (!eliminado) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: _BotonImprimirComprobante(adelanto: adelanto),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmarEliminar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    // Dialog con TextField opcional para motivo (Santiago 2026-05-14:
    // "si se cancela un adelanto tendría que poner observación para
    // cancelarlo no obligatorio").
    final motivoCtrl = TextEditingController();
    final confirma = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(dCtx).colorScheme.surface,
        title: const Text('¿Eliminar adelanto?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Adelanto de \$${AppFormatters.formatearMonto(adelanto.monto)} '
              'a ${adelanto.choferNombre ?? "DNI ${adelanto.choferDni}"} '
              'del ${AppFormatters.formatearFecha(adelanto.fecha)}.',
            ),
            const SizedBox(height: 8),
            Text(
              adelanto.numeroRecibo != null
                  ? 'El número de recibo ${adelanto.numeroRecibo} queda '
                      'quemado, pero el adelanto va a quedar visible al '
                      'activar "Mostrar eliminados" para ver el motivo.'
                  : 'El adelanto va a quedar visible al activar '
                      '"Mostrar eliminados".',
              style:
                  const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: motivoCtrl,
              decoration: const InputDecoration(
                labelText: 'Motivo (opcional)',
                hintText: 'Ej: cargado por error, monto equivocado, '
                    'chofer rechazó',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('CANCELAR'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accentRed,
            ),
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('ELIMINAR'),
          ),
        ],
      ),
    );
    if (confirma != true) return;
    try {
      await AdelantosService.eliminarAdelanto(
        adelantoId: adelanto.id,
        eliminadoPorDni: PrefsService.dni,
        motivo: motivoCtrl.text.trim().isEmpty ? null : motivoCtrl.text.trim(),
      );
      AppFeedback.successOn(messenger, 'Adelanto eliminado.');
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error al eliminar: $e');
    }
  }

  /// Restaura un adelanto eliminado (deshace el soft delete). El
  /// operador lo encuentra activando "Mostrar eliminados" en la lista,
  /// y desde la card eliminada puede tocar "RESTAURAR".
  Future<void> _restaurar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AdelantosService.restaurarAdelanto(adelanto.id);
      AppFeedback.successOn(messenger, 'Adelanto restaurado.');
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error al restaurar: $e');
    }
  }
}

// =============================================================================
// FORM DIALOG (alta + edición)
// =============================================================================

class _AdelantoFormDialog extends StatefulWidget {
  /// Si null → modo alta. Si trae uno → modo edición.
  final AdelantoChofer? adelanto;

  const _AdelantoFormDialog({this.adelanto});

  @override
  State<_AdelantoFormDialog> createState() => _AdelantoFormDialogState();
}

class _AdelantoFormDialogState extends State<_AdelantoFormDialog> {
  final _montoCtrl = TextEditingController();
  final _obsCtrl = TextEditingController();
  String? _choferDni;
  String? _choferNombre;
  DateTime _fecha = DateTime.now();
  // Default = efectivo (Santiago 2026-05-13). La mayoría de los
  // adelantos se entregan en mano.
  MedioPagoAdelanto _medioPago = MedioPagoAdelanto.efectivo;
  bool _guardando = false;
  // Si verdadero, ya guardamos el adelanto y estamos esperando que la
  // impresión salga (Cloud Function + PDF + envío a impresora). Lo
  // mostramos como "Imprimiendo…" para que el operador entienda por
  // qué el dialog no se cierra de inmediato.
  bool _imprimiendo = false;
  String? _error;

  bool get _esEdicion => widget.adelanto != null;

  @override
  void initState() {
    super.initState();
    final a = widget.adelanto;
    if (a != null) {
      _choferDni = a.choferDni;
      _choferNombre = a.choferNombre;
      _fecha = a.fecha;
      _montoCtrl.text = AppFormatters.formatearMiles(a.monto.toInt());
      _obsCtrl.text = a.observacion ?? '';
      _medioPago = a.medioPago;
    }
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    _obsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: Text(_esEdicion ? 'Editar adelanto' : 'Nuevo adelanto'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ─── Chofer ───
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection(AppCollections.empleados)
                    .where('ROL', isEqualTo: 'CHOFER')
                    .snapshots(),
                builder: (ctx, snap) {
                  final docs = List<
                          QueryDocumentSnapshot<Map<String, dynamic>>>.from(
                    snap.data?.docs ?? const [],
                  )..sort((a, b) {
                      final na =
                          (a.data()['NOMBRE'] ?? '').toString().toUpperCase();
                      final nb =
                          (b.data()['NOMBRE'] ?? '').toString().toUpperCase();
                      return na.compareTo(nb);
                    });
                  return DropdownButtonFormField<String>(
                    initialValue: _choferDni,
                    decoration: const InputDecoration(
                      labelText: 'Chofer *',
                      border: OutlineInputBorder(),
                    ),
                    isExpanded: true,
                    items: docs.map((d) {
                      final dni = (d.data()['DNI'] ?? d.id).toString();
                      final nom = (d.data()['NOMBRE'] ?? dni).toString();
                      return DropdownMenuItem(
                        value: dni,
                        child: Text(nom, overflow: TextOverflow.ellipsis),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val == null) return;
                      final doc = docs.firstWhere(
                        (d) => (d.data()['DNI'] ?? d.id).toString() == val,
                      );
                      setState(() {
                        _choferDni = val;
                        _choferNombre =
                            (doc.data()['NOMBRE'] ?? val).toString();
                      });
                    },
                  );
                },
              ),
              const SizedBox(height: 12),
              // ─── Fecha ───
              InkWell(
                onTap: _pickFecha,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Fecha *',
                    border: OutlineInputBorder(),
                    suffixIcon:
                        Icon(Icons.calendar_today_outlined, size: 18),
                  ),
                  child: Text(
                    AppFormatters.formatearFecha(_fecha),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // ─── Monto ───
              TextField(
                controller: _montoCtrl,
                decoration: const InputDecoration(
                  labelText: 'Monto *',
                  prefixText: '\$ ',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [AppFormatters.inputMiles],
              ),
              const SizedBox(height: 12),
              // ─── Medio de pago ───
              // Toggle entre efectivo (default) y transferencia. Aparece
              // en el comprobante impreso, donde el chofer firma.
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 4),
                child: Text(
                  'Medio de pago',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
              SegmentedButton<MedioPagoAdelanto>(
                segments: const [
                  ButtonSegment(
                    value: MedioPagoAdelanto.efectivo,
                    label: Text('EFECTIVO'),
                    icon: Icon(Icons.payments_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: MedioPagoAdelanto.transferencia,
                    label: Text('TRANSFERENCIA'),
                    icon: Icon(Icons.account_balance_outlined, size: 16),
                  ),
                ],
                selected: {_medioPago},
                onSelectionChanged: (sel) =>
                    setState(() => _medioPago = sel.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(height: 12),
              // ─── Observación ───
              TextField(
                controller: _obsCtrl,
                decoration: const InputDecoration(
                  labelText: 'Observación / concepto',
                  hintText: 'Ej. combustible, adelanto sueldo, viático…',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: AppColors.accentRed),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('CANCELAR'),
        ),
        FilledButton(
          onPressed: _guardando ? null : _guardar,
          child: _guardando
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    ),
                    if (_imprimiendo) ...[
                      const SizedBox(width: 8),
                      const Text('IMPRIMIENDO…'),
                    ],
                  ],
                )
              : Text(_esEdicion ? 'GUARDAR' : 'CREAR'),
        ),
      ],
    );
  }

  Future<void> _pickFecha() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _fecha,
      firstDate: DateTime(DateTime.now().year - 2),
      lastDate: DateTime(DateTime.now().year + 2),
    );
    if (d != null) setState(() => _fecha = d);
  }

  Future<void> _guardar() async {
    if (_choferDni == null || _choferDni!.isEmpty) {
      setState(() => _error = 'Seleccioná un chofer.');
      return;
    }
    final monto =
        AppFormatters.parsearMiles(_montoCtrl.text)?.toDouble() ?? 0;
    if (monto <= 0) {
      setState(() => _error = 'El monto debe ser mayor a 0.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final dniActual = PrefsService.dni;
      final obs = _obsCtrl.text.trim().isEmpty ? null : _obsCtrl.text.trim();
      if (_esEdicion) {
        // Edición: NO re-imprime — si el operador necesita un nuevo
        // comprobante usa "REIMPRIMIR" en la card. Editar suele ser
        // para corregir un dato menor (observación, fecha, medio de
        // pago) y reimprimir con el mismo correlativo no aporta.
        await AdelantosService.actualizarAdelanto(
          adelantoId: widget.adelanto!.id,
          choferDni: _choferDni!,
          choferNombre: _choferNombre,
          fecha: _fecha,
          monto: monto,
          observacion: obs,
          medioPago: _medioPago,
          viajeId: widget.adelanto!.viajeId,
          actualizadoPorDni: dniActual,
        );
        if (mounted) Navigator.pop(context);
        return;
      }

      // ─── Modo alta ──────────────────────────────────────────────
      final adelantoId = await AdelantosService.crearAdelanto(
        choferDni: _choferDni!,
        choferNombre: _choferNombre,
        fecha: _fecha,
        monto: monto,
        observacion: obs,
        medioPago: _medioPago,
        creadoPorDni: dniActual,
        creadoPorNombre: PrefsService.nombre,
      );

      // Auto-imprimir el comprobante recién creado (Santiago
      // 2026-05-13: el flow físico es entregar la plata, firmar el
      // recibo, así que el operador siempre va a imprimir después de
      // crear — auto-hacerlo ahorra un click). Si la impresión falla
      // (Cloud Function caída, sin impresora, etc.), el adelanto ya
      // está en la base — el operador puede usar "REIMPRIMIR" desde
      // la lista.
      if (!mounted) return;
      setState(() => _imprimiendo = true);
      final adelantoLocal = AdelantoChofer(
        id: adelantoId,
        choferDni: _choferDni!,
        choferNombre: _choferNombre,
        fecha: _fecha,
        monto: monto,
        observacion: obs,
        medioPago: _medioPago,
      );
      await _ComprobantePrinter.imprimir(
        context: context,
        adelanto: adelantoLocal,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _guardando = false;
        _imprimiendo = false;
        _error = e.toString().replaceFirst(RegExp(r'^[A-Z][a-z]+: '), '');
      });
    }
  }
}

// =============================================================================
// IMPRIMIR COMPROBANTE
// =============================================================================

/// Botón "Imprimir comprobante" — replica el flow del detalle de viaje
/// pero apuntando a `AdelantoChofer`. Asigna correlativo server-side la
/// primera vez (Cloud Function `asignarNumeroReciboAdelanto`),
/// reimpresión usa el mismo número. Imprime directo a la impresora
/// default del sistema con `Printing.directPrintPdf`. Si falla, abre el
/// PDF con el viewer del SO como fallback.
class _BotonImprimirComprobante extends StatefulWidget {
  final AdelantoChofer adelanto;
  const _BotonImprimirComprobante({required this.adelanto});

  @override
  State<_BotonImprimirComprobante> createState() =>
      _BotonImprimirComprobanteState();
}

class _BotonImprimirComprobanteState
    extends State<_BotonImprimirComprobante> {
  bool _generando = false;

  @override
  Widget build(BuildContext context) {
    final esReimpresion = widget.adelanto.numeroRecibo != null;
    return OutlinedButton.icon(
      onPressed: _generando ? null : _imprimir,
      icon: _generando
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.accentGreen),
            )
          : Icon(esReimpresion ? Icons.refresh : Icons.print_outlined,
              size: 18),
      label: Text(esReimpresion
          ? 'REIMPRIMIR COMPROBANTE'
          : 'IMPRIMIR COMPROBANTE'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accentGreen,
        side: const BorderSide(color: AppColors.accentGreen),
        padding: const EdgeInsets.symmetric(vertical: 10),
        textStyle:
            const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
      ),
    );
  }

  Future<void> _imprimir() async {
    setState(() => _generando = true);
    try {
      await _ComprobantePrinter.imprimir(
        context: context,
        adelanto: widget.adelanto,
      );
    } finally {
      if (mounted) setState(() => _generando = false);
    }
  }
}

// =============================================================================
// HELPER DE IMPRESIÓN (compartido entre botón manual + auto-imprimir al crear)
// =============================================================================

/// Encapsula el flow completo de imprimir un comprobante de adelanto:
///   1. Pedir / reusar correlativo via Cloud Function (idempotente).
///   2. Generar el PDF (A4 dos mitades).
///   3. Mandar a impresora default; si falla, fallback al viewer del SO.
///   4. Mostrar feedback al usuario via ScaffoldMessenger.
///
/// Se usa desde 2 lugares:
///   - Botón "IMPRIMIR / REIMPRIMIR COMPROBANTE" en la card (manual).
///   - Form de alta `_AdelantoFormDialog._guardar()` (automático al crear).
///
/// Los errores se reportan via SnackBar y NO se re-tiran al caller — para
/// que el form pueda cerrar el dialog igual aunque la impresión haya
/// fallado (el adelanto ya está creado, el operador puede reimprimir
/// manual desde la card). Devuelve `true` si pudo mandar a impresora,
/// `false` si terminó en el viewer o si falló.
class _ComprobantePrinter {
  static Future<bool> imprimir({
    required BuildContext context,
    required AdelantoChofer adelanto,
  }) async {
    // Capturamos el messenger ANTES del await para evitar usar el
    // BuildContext después de un async gap (lint rule).
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 1. Asignar / reusar número correlativo (Cloud Function).
      final resultado = await RecibosAdelantoService.asignarNumeroSiFalta(
        adelantoId: adelanto.id,
      );
      final numero = resultado.numero;
      // 2. Generar PDF en memoria.
      final Uint8List pdfBytes = await RecibosAdelantoService.generarPdf(
        adelanto: adelanto,
        numeroRecibo: numero,
        esReimpresion: resultado.esReimpresion,
      );
      // 3. Imprimir directo o fallback a viewer.
      final nombreArchivo =
          'Comprobante-Adelanto-Nro-${numero.toString().padLeft(6, '0')}.pdf';
      final impresoOk = await _imprimirDirecto(pdfBytes, nombreArchivo);
      if (impresoOk) {
        AppFeedback.successOn(messenger,
            'Comprobante Nro. ${numero.toString().padLeft(6, '0')} '
            'enviado a la impresora.');
      } else {
        AppFeedback.successOn(messenger,
            'Comprobante Nro. ${numero.toString().padLeft(6, '0')} abierto. '
            'Imprimí desde el visor (Ctrl+P).');
      }
      return impresoOk;
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error al generar comprobante: $e');
      return false;
    }
  }

  static Future<bool> _imprimirDirecto(
      Uint8List bytes, String nombreArchivo) async {
    try {
      final printers = await Printing.listPrinters();
      if (printers.isEmpty) {
        await _abrirPdfConViewerSistema(bytes, nombreArchivo: nombreArchivo);
        return false;
      }
      final printer = printers.firstWhere(
        (p) => p.isDefault,
        orElse: () => printers.first,
      );
      final ok = await Printing.directPrintPdf(
        printer: printer,
        onLayout: (_) async => bytes,
        name: nombreArchivo,
      );
      if (!ok) {
        await _abrirPdfConViewerSistema(bytes, nombreArchivo: nombreArchivo);
        return false;
      }
      return true;
    } catch (e, stack) {
      debugPrint('⚠️ Printing.directPrintPdf falló: $e');
      debugPrint(stack.toString());
      await _abrirPdfConViewerSistema(bytes, nombreArchivo: nombreArchivo);
      return false;
    }
  }

  static Future<void> _abrirPdfConViewerSistema(
    List<int> bytes, {
    required String nombreArchivo,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$nombreArchivo');
    await file.writeAsBytes(bytes, flush: true);
    if (!kIsWeb && Platform.isWindows) {
      await Process.start(
        'cmd',
        ['/c', 'start', '', file.path],
        runInShell: true,
      );
    } else {
      await launchUrl(
        Uri.file(file.path),
        mode: LaunchMode.externalApplication,
      );
    }
  }
}

/// Chip compacto para mostrar el medio de pago del adelanto en la
/// card de la lista. Efectivo → teal (entrega directa); transferencia
/// → amber (suele requerir comprobante bancario adjunto).
class _ChipMedioPago extends StatelessWidget {
  final MedioPagoAdelanto medio;
  const _ChipMedioPago({required this.medio});

  @override
  Widget build(BuildContext context) {
    final esEfectivo = medio == MedioPagoAdelanto.efectivo;
    final color = esEfectivo ? AppColors.accentTeal : AppColors.accentAmber;
    final icono = esEfectivo
        ? Icons.payments_outlined
        : Icons.account_balance_outlined;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            medio.etiqueta.toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// Chip que muestra el estado de pago al chofer: PENDIENTE (naranja)
/// o PAGADO (verde con fecha). El operador hace tap → toggle. Pagado
/// excluye al adelanto del próximo resumen de pendientes.
class _ChipEstadoPago extends StatelessWidget {
  final bool pagado;
  final DateTime? pagadoEn;

  const _ChipEstadoPago({
    required this.pagado,
    required this.pagadoEn,
  });

  @override
  Widget build(BuildContext context) {
    final color = pagado ? AppColors.accentGreen : AppColors.accentOrange;
    final icono = pagado ? Icons.check_circle : Icons.schedule;
    final texto = pagado && pagadoEn != null
        ? 'PAGADO ${AppFormatters.formatearFecha(pagadoEn!)}'
        : pagado
            ? 'PAGADO'
            : 'PENDIENTE';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            texto,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}
