import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_breakpoints.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/pdf_printer.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/keyboard_shortcuts.dart';
import '../models/adelanto_chofer.dart';
import '../services/adelantos_service.dart';
import '../services/recibos_adelanto_service.dart';
import '../services/report_adelantos.dart';

// REFACTOR NÚCLEO · jun 2026 — lista de adelantos en lenguaje bento.
//
// SOLO PRESENTACIÓN del listado. Se preserva intacto:
//   - los streams (`AdelantosService.streamAdelantos` /
//     `streamAdelantosEnRango`), filtros (vista/fecha/empleado/texto) y
//     orden (más viejo primero),
//   - el modelo `AdelantoChofer` y `AdelantosService` (setPagado,
//     eliminar/restaurar, alta/edición, cuotas, correlativos),
//   - la selección para imprimir + `ReportAdelantosService.generar`,
//   - el form de alta/edición (`_AdelantoFormDialog`), el selector de
//     empleado (`_DialogSeleccionarEmpleado`) y los helpers de impresión
//     (`_ComprobantePrinter`) — son modales Material, fuera de la
//     superficie bento del listado, y NO se tocan para no romper la
//     lógica de plata/impresión.
//
// Layout Núcleo del listado:
//   ┌─ Hero: eyebrow ADELANTOS + total pendiente (hero) + [Nuevo] ──────┐
//   ├─ AppKpiStrip: pendiente · pagado · cantidad (sobre lo visible) ───┤
//   ├─ Buscador Núcleo + rango de fechas + filtro empleado + vista ─────┤
//   ├─ Barra de selección (imprimir resumen) ──────────────────────────┤
//   └─ Filas AppCard + AppHairline · estado (AppBadge) · monto (mono) ──┘

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
  /// Filtros de fecha (desde/hasta, inclusive). Si null, no aplica.
  /// El operador suele querer "los adelantos de este mes" o "del último
  /// pago de sueldo hasta hoy" — el rango lo arma con 2 date pickers.
  DateTime? _fechaDesde;
  DateTime? _fechaHasta;

  /// Vista activa del listado (Santiago 2026-05-19): default
  /// PENDIENTES — el caso operativo diario es "qué falta pagar".
  /// Los otros 3 son consultas puntuales (ver lo pagado en el rango,
  /// auditar eliminados, ver el panorama completo).
  _VistaAdelantos _vista = _VistaAdelantos.pendientes;

  /// Filtro por empleado específico (Santiago 2026-05-19): permite
  /// ver "cuántos adelantos tuvo el empleado X en el rango". Null =
  /// sin filtro (todos los empleados).
  String? _empleadoFiltroDni;
  String? _empleadoFiltroNombre;

  /// Set de excluidos (testers + choferes tanqueros). Se usa en el
  /// dropdown del form de alta y en el filtro de la lista. Los
  /// empleados reales preguntaban "quién es Apple Reviewer?" al ver
  /// el dropdown — Santiago 2026-05-18.
  ExcluidosSet? _excluidos;

  @override
  void initState() {
    super.initState();
    ExcluidosService.cargar().then((s) {
      if (mounted) setState(() => _excluidos = s);
    });
  }

  /// IDs de adelantos PENDIENTES deseleccionados para el resumen.
  /// Default: todos los pendientes visibles están seleccionados (set
  /// vacío). El operador destildea los que NO quiere incluir.
  /// **Los adelantos PAGADOS NUNCA son seleccionables** — ya están
  /// liquidados, no tiene sentido reimprimirlos en el resumen de
  /// pendientes. El operador puede toggle pagado/pendiente por card.
  final Set<String> _deseleccionados = {};

  // Antes (≤2026-05-19): solo los PENDIENTES eran seleccionables — el
  // resumen impreso solo mostraba pendientes. Cambio Santiago 2026-05-19:
  // imprimir cualquier mix (pendientes + pagados + eliminados) con
  // columna ESTADO en el PDF para ver el panorama completo del rango.
  bool _seleccionable(AdelantoChofer a) => true;
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
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo cambiar el estado del adelanto. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Adelantos',
      floatingActionButton: Builder(
        builder: (ctx) => FloatingActionButton.extended(
          backgroundColor: AppColors.brand,
          foregroundColor: AppColors.surface0,
          onPressed: () => _abrirAlta(ctx),
          icon: const Icon(Icons.add),
          label: const Text('NUEVO ADELANTO'),
        ),
      ),
      // Atajo desktop: Ctrl+N nuevo adelanto. (El buscador de texto se sacó
      // 2026-06-11 — el filtro de "Empleado" ya cubre buscar por persona.)
      body: KeyboardShortcutsScope(
        onNuevo: () => _abrirAlta(context),
        child: Column(
        children: [
          // ─── Rango de fechas + filtro de empleado (pills Núcleo) ─
          // El rango abre `showDateRangePicker` (1 calendario, 2 puntas);
          // el chip de empleado abre el dialog con buscador (filtra por
          // persona — reemplaza al buscador de texto que estaba arriba).
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _BotonRangoFechas(
                  desde: _fechaDesde,
                  hasta: _fechaHasta,
                  onChanged: (desde, hasta) {
                    setState(() {
                      _fechaDesde = desde;
                      _fechaHasta = hasta;
                    });
                  },
                  onLimpiar: (_fechaDesde != null || _fechaHasta != null)
                      ? () => setState(() {
                            _fechaDesde = null;
                            _fechaHasta = null;
                          })
                      : null,
                ),
                _ChipFiltroEmpleado(
                  empleadoDni: _empleadoFiltroDni,
                  empleadoNombre: _empleadoFiltroNombre,
                  onSeleccionar: (dni, nombre) {
                    setState(() {
                      _empleadoFiltroDni = dni;
                      _empleadoFiltroNombre = nombre;
                    });
                  },
                  onLimpiar: () => setState(() {
                    _empleadoFiltroDni = null;
                    _empleadoFiltroNombre = null;
                  }),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<AdelantoChofer>>(
              // Si el operador filtro por rango de fechas, usamos el
              // stream con rango server-side (auditoria 2026-05-18).
              // Antes el stream default traia los 300 ultimos y el
              // filtro client-side veria vacio si los 300 mas recientes
              // estaban fuera del rango (acumulado de meses).
              stream: (_fechaDesde != null || _fechaHasta != null)
                  ? AdelantosService.streamAdelantosEnRango(
                      desde: _fechaDesde ?? DateTime(2020),
                      hasta: _fechaHasta != null
                          ? DateTime(_fechaHasta!.year, _fechaHasta!.month,
                              _fechaHasta!.day + 1)
                          : DateTime.now().add(const Duration(days: 1)),
                      // Traemos SIEMPRE los eliminados: la card-filtro
                      // ELIMINADOS muestra su conteo en vivo (no solo cuando
                      // está activa). El volumen de adelantos es chico.
                      incluirEliminados: true,
                    )
                  : AdelantosService.streamAdelantos(),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const AppSkeletonList(count: 8);
                }
                if (snap.hasError) {
                  return AppErrorState(
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
                // Facetas (fecha/empleado/texto/excluidos) → base con TODOS
                // los estados. Las cards-filtro cuentan sobre esta base; la
                // card activa (`_vista`) filtra lo que se muestra. Mismo
                // patrón que el resto de los menús: los KPIs SON el filtro.
                final base = _aplicarFacetas(items);
                final filtrados = base.where(_pasaVista).toList();
                final seleccionables =
                    filtrados.where(_seleccionable).toList();
                final seleccionados =
                    seleccionables.where(_seleccionado).toList();
                return Column(
                  children: [
                    // Cards-filtro (PENDIENTES · PAGADOS · ELIMINADOS · TODOS):
                    // tocar una filtra; los conteos son GLOBALES sobre la base
                    // facetada. Siempre visible, para poder cambiar de card aun
                    // con la vista vacía.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
                      child: _ResumenAdelantos(
                        base: base,
                        vista: _vista,
                        onCard: (v) => setState(() => _vista = v),
                        empleadoNombre: _empleadoFiltroDni == null
                            ? null
                            : (_empleadoFiltroNombre ??
                                'DNI $_empleadoFiltroDni'),
                      ),
                    ),
                    if (filtrados.isEmpty)
                      const Expanded(
                        child: AppEmptyState(
                          icon: Icons.search_off,
                          title: 'Sin adelantos en esta vista',
                          subtitle:
                              'Probá otra card, o cambiá el rango o el empleado.',
                        ),
                      )
                    else ...[
                      _BarraSeleccion(
                        totalPendientes: seleccionables.length,
                        totalSeleccionados: seleccionados.length,
                        onSeleccionarTodos: () =>
                            setState(() => _deseleccionados.clear()),
                        onDeseleccionarTodos: () => setState(() =>
                            _deseleccionados
                                .addAll(seleccionables.map((a) => a.id))),
                        onImprimir: seleccionados.isEmpty
                            ? null
                            : () => _imprimirResumen(seleccionados),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(
                              AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 90),
                          itemCount: filtrados.length,
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

  /// Aplica las FACETAS (texto, fecha desde/hasta, empleado, excluidos) —
  /// todo MENOS el estado/vista. Las cards-filtro cuentan sobre esta base y
  /// `_pasaVista` aplica la card activa encima. El stream viene ordenado por
  /// fecha desc; lo reordenamos ascendente (más viejo primero).
  List<AdelantoChofer> _aplicarFacetas(List<AdelantoChofer> items) {
    Iterable<AdelantoChofer> it = items;
    // Excluir adelantos de testers + tanqueros (Santiago 2026-05-18).
    if (_excluidos != null) {
      it = it.where((a) => !ExcluidosService.esExcluido(
            _excluidos,
            dni: a.choferDni,
          ));
    }
    // Filtro por empleado específico (Santiago 2026-05-19).
    if (_empleadoFiltroDni != null && _empleadoFiltroDni!.isNotEmpty) {
      it = it.where((a) => a.choferDni == _empleadoFiltroDni);
    }
    // Fecha desde (inclusive — comparamos contra inicio del día).
    if (_fechaDesde != null) {
      final desde = DateTime(
          _fechaDesde!.year, _fechaDesde!.month, _fechaDesde!.day);
      it = it.where((a) => !a.fecha.isBefore(desde));
    }
    // Fecha hasta (inclusive — inicio del día siguiente).
    if (_fechaHasta != null) {
      final finDelDia = DateTime(_fechaHasta!.year, _fechaHasta!.month,
          _fechaHasta!.day + 1);
      it = it.where((a) => a.fecha.isBefore(finDelDia));
    }
    // Orden: más viejo primero (Santiago 2026-05-14 — primero los
    // pendientes antiguos que esperan pago).
    final list = it.toList();
    list.sort((a, b) => a.fecha.compareTo(b.fecha));
    return list;
  }

  /// Predicado de la card-filtro activa (`_vista`) sobre la base facetada.
  bool _pasaVista(AdelantoChofer a) {
    switch (_vista) {
      case _VistaAdelantos.pendientes:
        return !a.eliminado && !a.pagado;
      case _VistaAdelantos.pagados:
        return !a.eliminado && a.pagado;
      case _VistaAdelantos.eliminados:
        return a.eliminado;
      case _VistaAdelantos.todos:
        return true;
    }
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
      // Si hay filtro de empleado activo, se imprime arriba del PDF
      // el mismo mini-resumen que ve el operador en pantalla
      // (Santiago 2026-05-19).
      empleadoFiltradoNombre: _empleadoFiltroDni == null
          ? null
          : (_empleadoFiltroNombre?.trim().isNotEmpty == true
              ? _empleadoFiltroNombre!
              : 'DNI $_empleadoFiltroDni'),
    );
    // Antes (≤ 2026-05-19) acá aparecía un dialog "marcar todos
    // como pagados". Santiago lo sacó: el resumen ahora puede
    // contener mix de pendientes/entregados/eliminados (no solo
    // pendientes), y ofrecer marcar todo como pagado en bulk
    // confunde más de lo que ayuda. El operador marca pagado por
    // card (toggle chip) o por bulk desde otra acción si la
    // necesita.
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
/// Chip tappeable para filtrar la lista de adelantos por un empleado
/// específico (Santiago 2026-05-19: "ver cuántos adelantos tuvo en el
/// lapso seleccionado"). Si no hay filtro, muestra "Empleado: TODOS"
/// y al tocar abre dialog con buscador. Si hay filtro, muestra el
/// nombre + botón × para limpiar.
class _ChipFiltroEmpleado extends StatelessWidget {
  final String? empleadoDni;
  final String? empleadoNombre;
  final void Function(String dni, String nombre) onSeleccionar;
  final VoidCallback onLimpiar;

  const _ChipFiltroEmpleado({
    required this.empleadoDni,
    required this.empleadoNombre,
    required this.onSeleccionar,
    required this.onLimpiar,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hayFiltro = empleadoDni != null && empleadoDni!.isNotEmpty;
    final label = hayFiltro
        ? (empleadoNombre?.trim().isNotEmpty == true
            ? empleadoNombre!.toUpperCase()
            : 'DNI $empleadoDni')
        : 'Empleado: todos';
    final accent = c.brand;
    final fg = hayFiltro ? accent : c.textSecondary;
    return InkWell(
      onTap: () async {
        final res = await showDialog<_EmpleadoElegido>(
          context: context,
          builder: (_) => const _DialogSeleccionarEmpleado(),
        );
        if (res != null) {
          if (res.dni.isEmpty) {
            onLimpiar();
          } else {
            onSeleccionar(res.dni, res.nombre);
          }
        }
      },
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: hayFiltro ? accent.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: hayFiltro ? accent.withValues(alpha: 0.5) : c.borderStrong,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(hayFiltro ? Icons.person : Icons.people_outline,
                size: 14, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: AppType.label.copyWith(color: fg, fontWeight: FontWeight.w600),
            ),
            if (hayFiltro) ...[
              const SizedBox(width: 6),
              Icon(Icons.close, size: 13, color: fg),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmpleadoElegido {
  final String dni;
  final String nombre;
  const _EmpleadoElegido({required this.dni, required this.nombre});
}

/// Dialog que lista empleados (no excluidos) ordenados alfabéticamente
/// con buscador en vivo. Opción extra "TODOS" arriba para limpiar el
/// filtro sin tocar la lista.
class _DialogSeleccionarEmpleado extends StatefulWidget {
  /// `true` (default): muestra la opción "TODOS" — para filtrar la lista.
  /// `false`: en el alta de un adelanto hay que elegir un empleado puntual.
  final bool incluirTodos;
  const _DialogSeleccionarEmpleado({this.incluirTodos = true});

  @override
  State<_DialogSeleccionarEmpleado> createState() =>
      _DialogSeleccionarEmpleadoState();
}

class _DialogSeleccionarEmpleadoState
    extends State<_DialogSeleccionarEmpleado> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        width: (MediaQuery.of(context).size.width - 80).clamp(280.0, 420.0),
        height: (MediaQuery.of(context).size.height - 200)
            .clamp(360.0, 560.0),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.person_search, size: 20),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    widget.incluirTodos
                        ? 'Filtrar por empleado'
                        : 'Seleccionar empleado',
                    style: AppType.heading.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: 'Buscar por nombre o DNI…',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _q.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () => setState(() => _q = ''),
                        ),
                ),
                onChanged: (v) => setState(() => _q = v.trim().toUpperCase()),
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection(AppCollections.empleados)
                    .snapshots(),
                builder: (ctx, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final excluidos = ExcluidosService.cacheActual;
                  final docs = (snap.data?.docs ?? const [])
                      .where((d) => !ExcluidosService.esExcluido(
                            excluidos,
                            dni: d.id,
                          ))
                      .toList()
                    ..sort((a, b) {
                      final na =
                          (a.data()['NOMBRE'] ?? '').toString().toUpperCase();
                      final nb =
                          (b.data()['NOMBRE'] ?? '').toString().toUpperCase();
                      return na.compareTo(nb);
                    });
                  final filtrados = _q.isEmpty
                      ? docs
                      : docs.where((d) {
                          final nombre = (d.data()['NOMBRE'] ?? '')
                              .toString()
                              .toUpperCase();
                          return nombre.contains(_q) ||
                              d.id.toUpperCase().contains(_q);
                        }).toList();
                  return ListView(
                    children: [
                      // Opción "TODOS" — limpia el filtro (solo en modo filtro).
                      if (widget.incluirTodos) ...[
                        ListTile(
                          leading: const Icon(Icons.people_outline,
                              color: Colors.white60),
                          title: const Text('TODOS los empleados'),
                          subtitle: const Text('Sin filtro de empleado',
                              style: AppType.eyebrow),
                          onTap: () => Navigator.pop(
                            context,
                            const _EmpleadoElegido(dni: '', nombre: ''),
                          ),
                        ),
                        const Divider(height: 1),
                      ],
                      for (final d in filtrados)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.person,
                              size: 18, color: AppColors.info),
                          title: Text(
                            (d.data()['NOMBRE'] ?? d.id).toString(),
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text('DNI ${d.id}',
                              style: const TextStyle(fontSize: 10)),
                          onTap: () => Navigator.pop(
                            context,
                            _EmpleadoElegido(
                              dni: d.id,
                              nombre:
                                  (d.data()['NOMBRE'] ?? d.id).toString(),
                            ),
                          ),
                        ),
                      if (filtrados.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(AppSpacing.xl),
                          child: Text(
                            'Sin coincidencias.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('CERRAR'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pill Núcleo que abre un selector de RANGO de fechas
/// (`showDateRangePicker`). Si hay rango activo se pinta con la tinta
/// brand y muestra una × para limpiar (también limpia con long-press).
/// La lógica del picker es idéntica a la versión previa.
class _BotonRangoFechas extends StatelessWidget {
  final DateTime? desde;
  final DateTime? hasta;
  final void Function(DateTime? desde, DateTime? hasta) onChanged;
  final VoidCallback? onLimpiar;

  const _BotonRangoFechas({
    required this.desde,
    required this.hasta,
    required this.onChanged,
    this.onLimpiar,
  });

  Future<void> _abrir(BuildContext context) async {
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
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hayRango = desde != null || hasta != null;
    final accent = c.brand;
    final fg = hayRango ? accent : c.textSecondary;
    return InkWell(
      onTap: () => _abrir(context),
      onLongPress: hayRango ? () => onChanged(null, null) : null,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: hayRango ? accent.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: hayRango ? accent.withValues(alpha: 0.5) : c.borderStrong,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.date_range_outlined, size: 14, color: fg),
            const SizedBox(width: 6),
            Text(
              _renderLabel(),
              style: AppType.label.copyWith(color: fg, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
            if (hayRango && onLimpiar != null) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: onLimpiar,
                child: Icon(Icons.close, size: 13, color: fg),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _renderLabel() {
    final d = desde;
    final h = hasta;
    if (d == null && h == null) return 'Rango de fechas';
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

/// Header del listado: eyebrow ("Adelantos · EMPLEADO" si hay filtro) + el
/// strip de CARDS-FILTRO (PENDIENTES · PAGADOS · ELIMINADOS · TODOS).
/// Reemplazó al hero "$ X pendiente" (repetía la card PENDIENTES) + el
/// AppKpiStrip no-interactivo + los pills de vista.
///
/// Conteos GLOBALES sobre la base facetada (fecha/empleado/texto), NO sobre
/// la card activa — así se ve cuántos hay en cada estado. Los eliminados no
/// suman a los montos en plata (no son plata real) pero sí al conteo.
class _ResumenAdelantos extends StatelessWidget {
  /// Base facetada con TODOS los estados (para los conteos de las cards).
  final List<AdelantoChofer> base;
  final _VistaAdelantos vista;
  final ValueChanged<_VistaAdelantos> onCard;
  final String? empleadoNombre;

  const _ResumenAdelantos({
    required this.base,
    required this.vista,
    required this.onCard,
    required this.empleadoNombre,
  });

  @override
  Widget build(BuildContext context) {
    final esDesktop = AppBreakpoints.isDesktopOrLarger(context);
    final eyebrowTxt = empleadoNombre == null
        ? 'Adelantos'
        : 'Adelantos · ${empleadoNombre!.toUpperCase()}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppEyebrow(eyebrowTxt),
        const SizedBox(height: AppSpacing.sm),
        _StripCardsAdelantos(
          esDesktop: esDesktop,
          base: base,
          vista: vista,
          onCard: onCard,
        ),
      ],
    );
  }
}

/// Strip de cards-filtro de Adelantos (estética AppKpiStrip pero tappeable).
/// Cada celda lleva el conteo (h2) + el monto en plata abajo, con el color
/// del estado. La activa se resalta con tinte brand. Desktop: Expanded;
/// mobile: scroll horizontal.
class _StripCardsAdelantos extends StatelessWidget {
  final bool esDesktop;
  final List<AdelantoChofer> base;
  final _VistaAdelantos vista;
  final ValueChanged<_VistaAdelantos> onCard;
  const _StripCardsAdelantos({
    required this.esDesktop,
    required this.base,
    required this.vista,
    required this.onCard,
  });

  static double _suma(Iterable<AdelantoChofer> l) =>
      l.fold<double>(0, (acc, a) => acc + a.monto);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pendientes = base.where((a) => !a.eliminado && !a.pagado).toList();
    final pagados = base.where((a) => !a.eliminado && a.pagado).toList();
    final eliminados = base.where((a) => a.eliminado).toList();
    final activos = base.where((a) => !a.eliminado);
    String money(double v) => '\$ ${AppFormatters.formatearMonto(v)}';

    final celdas = <Widget>[
      _CeldaCardAdelanto(
        label: 'Pendientes',
        valor: pendientes.length,
        delta: money(_suma(pendientes)),
        accent: pendientes.isEmpty ? null : c.warning,
        seleccionado: vista == _VistaAdelantos.pendientes,
        esDesktop: esDesktop,
        onTap: () => onCard(_VistaAdelantos.pendientes),
      ),
      _CeldaCardAdelanto(
        label: 'Pagados',
        valor: pagados.length,
        delta: money(_suma(pagados)),
        accent: pagados.isEmpty ? null : c.success,
        seleccionado: vista == _VistaAdelantos.pagados,
        esDesktop: esDesktop,
        onTap: () => onCard(_VistaAdelantos.pagados),
      ),
      _CeldaCardAdelanto(
        label: 'Eliminados',
        valor: eliminados.length,
        delta: eliminados.isEmpty ? null : money(_suma(eliminados)),
        accent: eliminados.isEmpty ? null : c.error,
        seleccionado: vista == _VistaAdelantos.eliminados,
        esDesktop: esDesktop,
        onTap: () => onCard(_VistaAdelantos.eliminados),
      ),
      _CeldaCardAdelanto(
        label: 'Todos',
        valor: base.length,
        delta: money(_suma(activos)),
        accent: null,
        seleccionado: vista == _VistaAdelantos.todos,
        esDesktop: esDesktop,
        onTap: () => onCard(_VistaAdelantos.todos),
      ),
    ];
    final fila = IntrinsicHeight(
      child: Row(
        children: [
          for (var i = 0; i < celdas.length; i++) ...[
            if (esDesktop) Expanded(child: celdas[i]) else celdas[i],
            if (i < celdas.length - 1) Container(width: 1, color: c.border),
          ],
        ],
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: esDesktop
            ? fila
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal, child: fila),
      ),
    );
  }
}

/// Una celda del strip de Adelantos. Tappeable; resalta con tinte brand
/// cuando es la card activa. El número lleva el color del estado (`accent`)
/// y el monto en plata abajo (mismo color; atenuado si la card está vacía).
class _CeldaCardAdelanto extends StatelessWidget {
  final String label;
  final int valor;
  final String? delta;
  final Color? accent;
  final bool seleccionado;
  final bool esDesktop;
  final VoidCallback onTap;
  const _CeldaCardAdelanto({
    required this.label,
    required this.valor,
    required this.delta,
    required this.accent,
    required this.seleccionado,
    required this.esDesktop,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final contenido = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: esDesktop ? 16 : 14,
        vertical: esDesktop ? 16 : 14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.eyebrow.copyWith(
              color: seleccionado ? c.brand : c.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$valor',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.h2.copyWith(
              color: accent ?? c.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (delta != null) ...[
            const SizedBox(height: 2),
            Text(
              delta!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.monoSm.copyWith(color: accent ?? c.textMuted),
            ),
          ],
        ],
      ),
    );
    final celda = ConstrainedBox(
      constraints: BoxConstraints(minWidth: esDesktop ? 0 : 120),
      child: ColoredBox(
        color: seleccionado
            ? c.brand.withValues(alpha: 0.12)
            : Colors.transparent,
        child: contenido,
      ),
    );
    return InkWell(onTap: onTap, child: celda);
  }
}

class _BarraSeleccion extends StatelessWidget {
  /// Total de adelantos SELECCIONABLES en la lista filtrada. Desde
  /// 2026-05-19 todos lo son (pendientes/pagados/eliminados).
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
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              totalPendientes == 0
                  ? 'Sin adelantos en rango'
                  : '$totalSeleccionados / $totalPendientes seleccionado(s)',
              style: AppType.bodySm.copyWith(color: c.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _AccionTexto(
            label: 'Todos',
            tooltip: 'Marcar TODOS los adelantos visibles para imprimir',
            onTap: totalSeleccionados == totalPendientes
                ? null
                : onSeleccionarTodos,
          ),
          _AccionTexto(
            label: 'Ninguno',
            tooltip: 'Desmarcar todos (no imprimir nada)',
            onTap: totalSeleccionados == 0 ? null : onDeseleccionarTodos,
          ),
          const SizedBox(width: AppSpacing.sm),
          // Label genérico — desde 2026-05-19 el resumen mezcla
          // pendientes/entregados/eliminados según selección.
          AppButton.primary(
            label: 'Imprimir ($totalSeleccionados)',
            icon: Icons.print_outlined,
            size: AppButtonSize.sm,
            onPressed: onImprimir,
          ),
        ],
      ),
    );
  }
}

/// Acción de texto compacta (TODOS / NINGUNO) en tinta brand, deshabilitada
/// cuando [onTap] es null.
class _AccionTexto extends StatelessWidget {
  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  const _AccionTexto({
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(
            label.toUpperCase(),
            style: AppType.eyebrow.copyWith(
              color: enabled ? c.brand : c.textMuted,
            ),
          ),
        ),
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
    final c = context.colors;
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

    // Acento del borde izquierdo de la card según estado.
    final Color accent = eliminado
        ? c.error
        : (pagado ? c.success : (seleccionado ? c.brand : c.textMuted));

    return Opacity(
      opacity: opacidad,
      child: AppCard(
        tier: 1,
        accent: accent,
        // Eliminados NO abren el form de edición — están "congelados".
        onTap: eliminado
            ? null
            : () => showDialog(
                  context: context,
                  builder: (_) => _AdelantoFormDialog(adelanto: adelanto),
                ),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Banner de "ELIMINADO" arriba del todo si aplica. Muestra
            // el motivo si lo hay (Santiago 2026-05-14: queremos saber
            // por qué se quemó cada número de recibo).
            if (eliminado) ...[
              Row(
                children: [
                  AppBadge(
                    text: 'Eliminado',
                    color: c.error,
                    size: AppBadgeSize.sm,
                    icon: Icons.delete_forever,
                  ),
                  if (adelanto.eliminadoEn != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        AppFormatters.formatearFechaHoraSinSegundos(
                            adelanto.eliminadoEn!),
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ] else
                    const Spacer(),
                  AppButton.ghost(
                    label: 'Restaurar',
                    icon: Icons.restore,
                    size: AppButtonSize.compact,
                    onPressed: () => _restaurar(context),
                  ),
                ],
              ),
              if (adelanto.eliminadoMotivo != null &&
                  adelanto.eliminadoMotivo!.trim().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Motivo: ${adelanto.eliminadoMotivo!.trim()}',
                  style: AppType.bodySm.copyWith(
                    color: c.textMuted,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              const AppHairline(),
              const SizedBox(height: AppSpacing.sm),
            ],
            Row(
              children: [
                // Checkbox solo para PENDIENTES no-eliminados. Los pagados
                // muestran un ícono de check fijo. Los eliminados un ícono
                // de basura.
                if (eliminado)
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Icon(Icons.delete_outline, color: c.error, size: 20),
                  )
                else if (pagado)
                  SizedBox(
                    width: 28,
                    height: 28,
                    child:
                        Icon(Icons.check_circle, color: c.success, size: 20),
                  )
                else
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Checkbox(
                      value: seleccionado,
                      onChanged: (_) => onToggleSeleccion(),
                      visualDensity: VisualDensity.compact,
                      activeColor: c.brand,
                    ),
                  ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    chofer,
                    style: AppType.body.copyWith(
                        color: c.text, fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                // Monto en mono tabular, tinta neutra (hero number). El
                // color semántico queda para el badge de estado.
                Text(
                  '\$ $montoFmt',
                  style: AppType.mono.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (!eliminado)
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: c.error, size: 18),
                    tooltip: 'Eliminar adelanto',
                    onPressed: () => _confirmarEliminar(context),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Fecha (mono muted, técnico).
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.calendar_today_outlined,
                        size: 12, color: c.textMuted),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      fechaFmt,
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
                // Medio de pago — efectivo (info) / transferencia (warning).
                _BadgeMedioPago(medio: adelanto.medioPago),
                // Cuota (si es parte de un plan en cuotas).
                if (adelanto.esCuota)
                  AppBadge(
                    text: 'CUOTA ${adelanto.cuotaNumero}/${adelanto.cuotasTotal}',
                    color: c.brand,
                    size: AppBadgeSize.sm,
                    icon: Icons.repeat,
                  ),
                // Estado de pago tappeable. PENDIENTE = warning,
                // PAGADO = success con fecha. Tap → toggle (con feedback
                // del service). Eliminado → NO tappeable.
                InkWell(
                  onTap: eliminado ? null : onTogglePagado,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  child: _BadgeEstadoPago(
                    pagado: pagado,
                    pagadoEn: adelanto.pagadoEn,
                  ),
                ),
                if (yaImpreso)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.receipt_long_outlined,
                          size: 12, color: c.textMuted),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        'Recibo N° ${adelanto.numeroRecibo!.toString().padLeft(6, '0')}',
                        style: AppType.monoSm.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
              ],
            ),
            if (adelanto.observacion != null &&
                adelanto.observacion!.trim().isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                adelanto.observacion!,
                style: AppType.bodySm.copyWith(color: c.textSecondary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            // El botón de imprimir comprobante NO se muestra en
            // adelantos eliminados — si el adelanto está cancelado,
            // imprimirle un comprobante "quema" más papel sin sentido.
            // Las reimpresiones de adelantos válidos sí están OK.
            if (!eliminado) ...[
              const SizedBox(height: AppSpacing.md),
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
            const SizedBox(height: AppSpacing.sm),
            Text(
              adelanto.numeroRecibo != null
                  ? 'El número de recibo ${adelanto.numeroRecibo} queda '
                      'quemado, pero el adelanto va a quedar visible en la '
                      'vista "Eliminados" para ver el motivo.'
                  : 'El adelanto va a quedar visible en la vista '
                      '"Eliminados".',
              style:
                  AppType.label.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: AppSpacing.md),
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
              backgroundColor: AppColors.error,
            ),
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('ELIMINAR'),
          ),
        ],
      ),
    );
    if (confirma != true) {
      motivoCtrl.dispose();
      return;
    }
    final motivoTxt = motivoCtrl.text.trim();
    motivoCtrl.dispose();
    try {
      await AdelantosService.eliminarAdelanto(
        adelantoId: adelanto.id,
        eliminadoPorDni: PrefsService.dni,
        motivo: motivoTxt.isEmpty ? null : motivoTxt,
      );
      AppFeedback.successOn(messenger, 'Adelanto eliminado.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo eliminar el adelanto. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
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
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo restaurar el adelanto. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
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
  // Cuotas mensuales (Santiago 2026-05-19): si está activo, el monto
  // ingresado es el TOTAL a financiar y se divide en N cuotas con
  // fechas escalonadas mes a mes. Default OFF (pago único histórico).
  // Solo disponible en MODO ALTA — editar cuotas individuales no
  // dispara este flujo.
  bool _enCuotas = false;
  int _cuotas = 2;
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
      _montoCtrl.text = AppFormatters.formatearMonto(a.monto);
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
        width: (MediaQuery.of(context).size.width - 80).clamp(240.0, 380.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ─── Empleado ───
              // Antes filtrabamos por ROL=CHOFER, pero los adelantos de
              // sueldo aplican a todo el personal (planta, gomeria, seg
              // e higiene, etc), no solo choferes. Ahora el dropdown
              // muestra todos los empleados ordenados alfabeticamente.
              // La liquidacion de viajes sigue siendo solo de choferes
              // (ver liquidacion_service.dart), entonces los adelantos
              // de empleados no-CHOFER no se asocian a viajes — son
              // adelantos de sueldo puros.
              // Selector de empleado CON buscador (reusa el dialog de
              // búsqueda; en el alta va sin la opción "TODOS"). Antes era un
              // DropdownButtonFormField sin buscador, incómodo con ~60
              // empleados (Santiago 2026-06-01).
              InkWell(
                onTap: () async {
                  final elegido = await showDialog<_EmpleadoElegido>(
                    context: context,
                    builder: (_) =>
                        const _DialogSeleccionarEmpleado(incluirTodos: false),
                  );
                  if (elegido != null && elegido.dni.isNotEmpty) {
                    setState(() {
                      _choferDni = elegido.dni;
                      _choferNombre = elegido.nombre;
                    });
                  }
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Empleado *',
                    border: OutlineInputBorder(),
                    suffixIcon: Icon(Icons.search),
                  ),
                  child: Text(
                    (_choferDni == null || _choferDni!.isEmpty)
                        ? 'Tocá para buscar el empleado…'
                        : (_choferNombre ?? _choferDni!),
                    style: (_choferDni == null || _choferDni!.isEmpty)
                        ? const TextStyle(color: AppColors.textHint)
                        : null,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
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
              const SizedBox(height: AppSpacing.md),
              // ─── Monto ───
              TextField(
                controller: _montoCtrl,
                decoration: InputDecoration(
                  labelText: _enCuotas ? 'Monto TOTAL a financiar *' : 'Monto *',
                  prefixText: '\$ ',
                  border: const OutlineInputBorder(),
                  helperText: _enCuotas
                      ? 'Se dividirá en $_cuotas cuotas mensuales'
                      : null,
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [AppFormatters.inputMilesDecimal],
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.md),
              // ─── Cuotas mensuales (solo en alta) ────────────────
              if (!_esEdicion) ...[
                Row(
                  children: [
                    Checkbox(
                      value: _enCuotas,
                      onChanged: (v) =>
                          setState(() => _enCuotas = v ?? false),
                    ),
                    const Expanded(
                      child: Text(
                        'Descontar en cuotas mensuales',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                  ],
                ),
                if (_enCuotas) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(
                      'Cantidad de cuotas',
                      style: AppType.label.copyWith(color: Colors.white60),
                    ),
                  ),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 2, label: Text('2')),
                      ButtonSegment(value: 3, label: Text('3')),
                      ButtonSegment(value: 4, label: Text('4')),
                      ButtonSegment(value: 5, label: Text('5')),
                      ButtonSegment(value: 6, label: Text('6')),
                    ],
                    selected: {_cuotas},
                    onSelectionChanged: (sel) =>
                        setState(() => _cuotas = sel.first),
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _PreviewCuotas(
                    montoTotalRaw: _montoCtrl.text,
                    cuotas: _cuotas,
                    fechaPrimera: _fecha,
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
              ],
              // ─── Medio de pago ───
              // Toggle entre efectivo (default) y transferencia. Aparece
              // en el comprobante impreso, donde el chofer firma.
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text(
                  'Medio de pago',
                  style: AppType.label.copyWith(color: Colors.white60),
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
              const SizedBox(height: AppSpacing.md),
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
                const SizedBox(height: AppSpacing.md),
                Text(
                  _error!,
                  style: const TextStyle(color: AppColors.error),
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
                      const SizedBox(width: AppSpacing.sm),
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
        AppFormatters.parsearMonto(_montoCtrl.text) ?? 0;
    if (monto <= 0) {
      setState(() => _error = 'El monto debe ser mayor a 0.');
      return;
    }
    // Cap superior defensivo (auditoria 2026-05-17): sin esto un cero
    // de mas accidental (tipico con inputMiles cuando "1.000.000" vs
    // "10.000.000" se confunden) se persistia silenciosamente. Cap a
    // $5M cubre 99.9% de los casos reales de Vecchi.
    const capMaximo = 5000000;
    if (monto > capMaximo) {
      setState(() => _error = 'Monto excesivo (max ${AppFormatters.formatearMonto(capMaximo)}). '
          'Si es correcto, contactá a admin.');
      return;
    }
    // Confirmacion humana para adelantos > $500K (probable typo).
    if (monto > 500000) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirmar adelanto grande'),
          content: Text('Vas a registrar un adelanto de '
              '${AppFormatters.formatearMonto(monto)}. ¿Es correcto?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sí, confirmar'),
            ),
          ],
        ),
      );
      if (ok != true) return;
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
      // Modo CUOTAS: dispara `crearAdelantosEnCuotas` que genera N
      // docs (uno por cuota) con fechas escalonadas. El recibo
      // impreso es UNO solo con la tabla del plan completo.
      if (_enCuotas) {
        final res = await AdelantosService.crearAdelantosEnCuotas(
          choferDni: _choferDni!,
          choferNombre: _choferNombre,
          fechaPrimera: _fecha,
          montoTotal: monto,
          cuotas: _cuotas,
          observacion: obs,
          medioPago: _medioPago,
          creadoPorDni: dniActual,
          creadoPorNombre: PrefsService.nombre,
        );
        if (!mounted) return;
        setState(() => _imprimiendo = true);
        // Imprimir 1 recibo con plan completo de cuotas.
        await _ComprobantePrinter.imprimirPlanCuotas(
          context: context,
          grupoCuotasId: res.grupoCuotasId,
        );
        if (mounted) Navigator.pop(context);
        return;
      }

      // Modo PAGO ÚNICO (flujo histórico).
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
/// reimpresión usa el mismo número. Impresión delegada a `PdfPrinter`
/// (sheet nativo en iOS/Android, impresora default en desktop).
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
    return AppButton.secondary(
      label: esReimpresion ? 'Reimprimir comprobante' : 'Imprimir comprobante',
      icon: esReimpresion ? Icons.refresh : Icons.print_outlined,
      size: AppButtonSize.sm,
      full: true,
      loading: _generando,
      onPressed: _generando ? null : _imprimir,
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
      // 3. Delegar a `PdfPrinter` — sheet nativo en iOS/Android,
      // directo a impresora default en desktop.
      final nroPad = numero.toString().padLeft(6, '0');
      final outcome = await PdfPrinter.imprimir(
        bytes: pdfBytes,
        nombreArchivo: 'Comprobante-Adelanto-Nro-$nroPad.pdf',
        etiquetaCorta: 'Comprobante Nro. $nroPad',
      );
      AppFeedback.successOn(messenger, outcome.mensajeUsuario);
      return outcome.success;
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo generar el comprobante. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
      return false;
    }
  }

  /// Imprime UN solo comprobante con el plan completo de cuotas.
  /// Pedido Santiago 2026-05-19: cuando un adelanto se reparte en N
  /// cuotas, el chofer firma 1 papel donde están detalladas todas
  /// las cuotas (fechas, montos). Cada cuota individual se liquida
  /// después como un AdelantoChofer normal.
  static Future<bool> imprimirPlanCuotas({
    required BuildContext context,
    required String grupoCuotasId,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 1. Traer todas las cuotas del grupo (ordenadas).
      final cuotas =
          await AdelantosService.obtenerCuotasDelGrupo(grupoCuotasId);
      if (cuotas.isEmpty) {
        AppFeedback.warningOn(messenger,
            'No se encontraron cuotas del grupo. Probá reimprimir desde la card.');
        return false;
      }
      // 2. Asignar / reusar correlativo para la PRIMERA cuota
      // (representa al plan — las demás cuotas no necesitan número
      // propio porque van todas en el mismo papel).
      final primera = cuotas.first;
      final resultado = await RecibosAdelantoService.asignarNumeroSiFalta(
        adelantoId: primera.id,
      );
      final numero = resultado.numero;
      // 3. Generar PDF con plan completo.
      final Uint8List pdfBytes =
          await RecibosAdelantoService.generarPdfPlanCuotas(
        cuotas: cuotas,
        numeroRecibo: numero,
        esReimpresion: resultado.esReimpresion,
      );
      final nroPad = numero.toString().padLeft(6, '0');
      final outcome = await PdfPrinter.imprimir(
        bytes: pdfBytes,
        nombreArchivo: 'Plan-Cuotas-Nro-$nroPad.pdf',
        etiquetaCorta:
            'Plan de ${cuotas.length} cuotas Nro. $nroPad',
      );
      AppFeedback.successOn(messenger, outcome.mensajeUsuario);
      return outcome.success;
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo generar el comprobante del plan. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
      return false;
    }
  }
}

/// Preview del reparto de cuotas en el form (tabla con monto y
/// fecha de cada una). Se actualiza al cambiar monto/cuotas/fecha.
class _PreviewCuotas extends StatelessWidget {
  final String montoTotalRaw;
  final int cuotas;
  final DateTime fechaPrimera;

  const _PreviewCuotas({
    required this.montoTotalRaw,
    required this.cuotas,
    required this.fechaPrimera,
  });

  @override
  Widget build(BuildContext context) {
    final monto =
        AppFormatters.parsearMonto(montoTotalRaw) ?? 0;
    if (monto <= 0) {
      return Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'Cargá el monto total para ver el detalle de las cuotas.',
          style: AppType.label.copyWith(color: Colors.white54),
        ),
      );
    }
    final montos = AdelantosService.repartirEnCuotas(
      montoTotal: monto,
      cuotas: cuotas,
    );
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: AppColors.info.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < cuotas; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text(
                    'Cuota ${i + 1}/$cuotas',
                    style: AppType.label.copyWith(color: Colors.white70),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      AppFormatters.formatearFecha(
                          AdelantosService.sumarMesesPreservandoDia(
                              fechaPrimera, i)),
                      style: AppType.eyebrow.copyWith(color: Colors.white54),
                    ),
                  ),
                  Text(
                    '\$ ${AppFormatters.formatearMonto(montos[i])}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Badge del medio de pago del adelanto. Efectivo → info (entrega
/// directa); transferencia → warning (suele requerir comprobante
/// bancario adjunto).
class _BadgeMedioPago extends StatelessWidget {
  final MedioPagoAdelanto medio;
  const _BadgeMedioPago({required this.medio});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final esEfectivo = medio == MedioPagoAdelanto.efectivo;
    return AppBadge(
      text: medio.etiqueta.toUpperCase(),
      color: esEfectivo ? c.info : c.warning,
      size: AppBadgeSize.sm,
      icon: esEfectivo
          ? Icons.payments_outlined
          : Icons.account_balance_outlined,
    );
  }
}

/// Badge del estado de pago al chofer: PENDIENTE (warning) o PAGADO
/// (success, con fecha si la hay). El operador hace tap → toggle.
/// Pagado excluye al adelanto del próximo resumen de pendientes.
class _BadgeEstadoPago extends StatelessWidget {
  final bool pagado;
  final DateTime? pagadoEn;

  const _BadgeEstadoPago({
    required this.pagado,
    required this.pagadoEn,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final texto = pagado && pagadoEn != null
        ? 'PAGADO ${AppFormatters.formatearFecha(pagadoEn!)}'
        : pagado
            ? 'PAGADO'
            : 'PENDIENTE';
    return AppBadge(
      text: texto,
      color: pagado ? c.success : c.warning,
      size: AppBadgeSize.sm,
      icon: pagado ? Icons.check_circle : Icons.schedule,
    );
  }
}

/// Vistas mutuamente exclusivas del listado de adelantos
/// (Santiago 2026-05-19). Reemplaza al toggle "Mostrar eliminados".
/// Default es `pendientes` — el caso operativo diario.
enum _VistaAdelantos { pendientes, pagados, eliminados, todos }
