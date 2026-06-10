import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_breakpoints.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/keyboard_shortcuts.dart';
import '../models/viaje.dart';
import '../services/viajes_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Lista de viajes — entry point del módulo. REFACTOR NÚCLEO (jun 2026).
///
/// Reescrita al layout del prototipo (`screens-desktop-modules.jsx :: Logistica`):
/// hero con el conteo de viajes del MES en foco + selector de mes (◀ MES ▶)
/// + [Nuevo viaje], AppKpiStrip con los counts por estado + total + ganancia
/// choferes (todo del mes), buscador Núcleo, chips de filtro (estado /
/// liquidación / borrados) y una **tabla** densa en desktop. En mobile se
/// mantienen cards ricas (re-skineadas a tokens).
///
/// **Vista mensual (Santiago 2026-06-10)**: la lista + KPIs se acotan al mes
/// elegido (por fecha de referencia), así el conteo de arriba coincide con el
/// total de abajo. El BUSCADOR es global: al tipear texto, busca en todos los
/// meses (para encontrar un viaje sin saber cuándo fue).
///
/// La fila de tabla y la card abren el MISMO detalle (`adminLogisticaViajeDetalle`).
/// Stream cacheado, filtros (estado / liquidado / búsqueda libre / borrados),
/// sort (más viejo arriba), KPIs y navegación quedan INTACTOS — solo cambió
/// la presentación.
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
  // Mes en foco. La lista + KPIs se acotan a este mes por fecha de
  // referencia (Santiago 2026-06-10: que el conteo de arriba coincida
  // con el de abajo). El BUSCADOR sigue global — al tipear texto, busca
  // en todos los meses. Default: mes corriente (1ro a las 00:00 ART).
  DateTime _mesSeleccionado = _primerDiaDeMesActual();

  static DateTime _primerDiaDeMesActual() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, 1);
  }

  /// `true` si la fecha de referencia del viaje (fecha de carga del 1er
  /// tramo, o `creado_en` de fallback) cae en [mes].
  static bool _esDelMes(Viaje v, DateTime mes) {
    final f = v.fechaReferencia;
    return f != null && f.year == mes.year && f.month == mes.month;
  }
  // Texto de búsqueda libre (auditoria 2026-05-17). Matcha chofer,
  // patente, empresa origen/destino, ubicación origen/destino, producto.
  // Lo dispara el TextField de la barra superior — siempre lowercase.
  String _busqueda = '';
  late final TextEditingController _busquedaCtrl;
  // Stream cacheado (auditoría 2026-05-30): antes se creaba inline en build(),
  // así que CADA tecla del buscador (setState _busqueda) re-suscribía el
  // .snapshots() de VIAJES_LOGISTICA (hasta 200 docs). La búsqueda/estado/
  // liquidado filtran client-side; solo `_verBorrados` cambia la query real,
  // así que recreamos el stream únicamente ahí.
  late Stream<List<Viaje>> _streamViajes;

  @override
  void initState() {
    super.initState();
    _busquedaCtrl = TextEditingController();
    _streamViajes = ViajesService.streamViajes(incluirInactivos: _verBorrados);
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
    final esDesktop = AppBreakpoints.isDesktopOrLarger(context);
    return AppScaffold(
      title: 'Viajes',
      // Ctrl+N → nuevo viaje (operador desktop tipea mucho —
      // Santiago 2026-05-13). Sin search field acá, así que no
      // mapeamos Ctrl+F.
      body: KeyboardShortcutsScope(
        onNuevo: _abrirNuevoViaje,
        child: AppOfflineBanner<List<Viaje>>(
          stream: _streamViajes,
          child: StreamBuilder<List<Viaje>>(
            stream: _streamViajes,
            builder: (ctx, snap) {
              final todos = snap.data ?? const <Viaje>[];
              final cargando =
                  snap.connectionState == ConnectionState.waiting;
              // Viajes del mes en foco (para hero + KPIs). La lista usa
              // `_aplicarFiltros`, que acota al mes salvo que haya búsqueda.
              final delMes = todos
                  .where((v) => _esDelMes(v, _mesSeleccionado))
                  .toList();
              final filtrados = _aplicarFiltros(todos);
              return Column(
                children: [
                  // Hero: VIAJES · conteo del mes + selector de mes +
                  // [Nuevo viaje].
                  _Header(
                    mes: _mesSeleccionado,
                    cantMes: delMes.length,
                    hayDatos: todos.isNotEmpty,
                    onMesAnterior: () => setState(() {
                      final m = _mesSeleccionado.month, y = _mesSeleccionado.year;
                      _mesSeleccionado =
                          m == 1 ? DateTime(y - 1, 12, 1) : DateTime(y, m - 1, 1);
                    }),
                    onMesSiguiente: () => setState(() {
                      final m = _mesSeleccionado.month, y = _mesSeleccionado.year;
                      _mesSeleccionado =
                          m == 12 ? DateTime(y + 1, 1, 1) : DateTime(y, m + 1, 1);
                    }),
                    onNuevo: _abrirNuevoViaje,
                  ),
                  // Buscador Núcleo. OJO: la búsqueda es GLOBAL (todos los
                  // meses) — al tipear, `_aplicarFiltros` ignora el mes.
                  _Buscador(
                    controller: _busquedaCtrl,
                    tieneTexto: _busqueda.isNotEmpty,
                    onChanged: (v) =>
                        setState(() => _busqueda = v.trim().toLowerCase()),
                    onLimpiar: () {
                      _busquedaCtrl.clear();
                      setState(() => _busqueda = '');
                    },
                  ),
                  // KPI strip por estado + total + ganancia choferes, sobre
                  // los viajes DEL MES (coinciden con el conteo del hero).
                  if (todos.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
                      child: _ResumenViajes(viajes: delMes),
                    ),
                  // Filtros (estado / liquidación / borrados).
                  _BarraFiltros(
                    estado: _filtroEstado,
                    liquidado: _filtroLiquidado,
                    verBorrados: _verBorrados,
                    onEstadoChanged: (v) => setState(() => _filtroEstado = v),
                    onLiquidadoChanged: (v) =>
                        setState(() => _filtroLiquidado = v),
                    onVerBorradosChanged: (v) => setState(() {
                      _verBorrados = v;
                      _streamViajes =
                          ViajesService.streamViajes(incluirInactivos: v);
                    }),
                  ),
                  // Encabezado de tabla (solo desktop).
                  if (esDesktop && !cargando && filtrados.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(
                          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 0),
                      child: _FilaHeader(),
                    ),
                  Expanded(
                    child: _Cuerpo(
                      cargando: cargando,
                      error: snap.hasError ? snap.error : null,
                      esDesktop: esDesktop,
                      haDatos: todos.isNotEmpty,
                      filtrados: filtrados,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _abrirNuevoViaje,
        backgroundColor: AppColors.brand,
        foregroundColor: AppColors.surface0,
        icon: const Icon(Icons.add),
        label: const Text('NUEVO VIAJE'),
      ),
    );
  }

  List<Viaje> _aplicarFiltros(List<Viaje> docs) {
    final q = _busqueda;
    final filtrados = docs.where((v) {
      // Acotar al mes en foco — SALVO que haya búsqueda (que es global,
      // para encontrar un viaje sin saber el mes).
      if (q.isEmpty && !_esDelMes(v, _mesSeleccionado)) return false;
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

// =============================================================================
// HEADER — eyebrow + selector de mes + hero (conteo del mes) + Nuevo viaje
// =============================================================================

class _Header extends StatelessWidget {
  final DateTime mes;
  final int cantMes;
  final bool hayDatos;
  final VoidCallback onMesAnterior;
  final VoidCallback onMesSiguiente;
  final VoidCallback onNuevo;
  const _Header({
    required this.mes,
    required this.cantMes,
    required this.hayDatos,
    required this.onMesAnterior,
    required this.onMesSiguiente,
    required this.onNuevo,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fila 1: eyebrow + selector de mes (◀ MES ▶).
          Row(
            children: [
              const Expanded(child: AppEyebrow('Viajes · período')),
              _FlechaMes(
                icon: Icons.chevron_left,
                tooltip: 'Mes anterior',
                onTap: onMesAnterior,
              ),
              const SizedBox(width: AppSpacing.sm),
              SizedBox(
                width: 118,
                child: Text(
                  AppFormatters.formatearMes(mes).toUpperCase(),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.label.copyWith(
                      color: c.text, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _FlechaMes(
                icon: Icons.chevron_right,
                tooltip: 'Mes siguiente',
                onTap: onMesSiguiente,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Fila 2: conteo del mes + botón Nuevo viaje.
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      hayDatos ? '$cantMes' : '—',
                      style: AppType.h2.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        'viajes',
                        style: AppType.monoSm
                            .copyWith(color: context.colors.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: AppButton.primary(
                  label: 'Nuevo viaje',
                  icon: Icons.add,
                  size: AppButtonSize.sm,
                  onPressed: onNuevo,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Botón de flecha para navegar mes a mes — superficie tier-3 con borde.
class _FlechaMes extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _FlechaMes({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: c.surface3,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: c.border),
          ),
          child: Icon(icon, size: 18, color: c.textSecondary),
        ),
      ),
    );
  }
}

// =============================================================================
// BUSCADOR — input Núcleo (misma lógica de búsqueda libre)
// =============================================================================

class _Buscador extends StatelessWidget {
  final TextEditingController controller;
  final bool tieneTexto;
  final ValueChanged<String> onChanged;
  final VoidCallback onLimpiar;

  const _Buscador({
    required this.controller,
    required this.tieneTexto,
    required this.onChanged,
    required this.onLimpiar,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.md),
      child: AppInput(
        controller: controller,
        hint: 'Buscar por chofer, patente, empresa, producto…',
        icon: Icons.search,
        onChanged: onChanged,
        trailingAction: tieneTexto ? 'Limpiar' : null,
        onTrailingTap: tieneTexto ? onLimpiar : null,
      ),
    );
  }
}

// =============================================================================
// RESUMEN — AppKpiStrip por estado + total + pagado choferes
// =============================================================================

/// KPIs del mes en foco: counts por estado + total + ganancia choferes.
/// Recibe ya los viajes DEL MES (coinciden con el conteo del hero).
/// En anchos chicos el AppKpiStrip puede apretarse, así que lo dejamos
/// scrolleable horizontal: 5 stats en una fila densa.
class _ResumenViajes extends StatelessWidget {
  final List<Viaje> viajes;
  const _ResumenViajes({required this.viajes});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    var enCurso = 0, concluidos = 0, planeados = 0;
    var ganancia = 0.0;
    for (final v in viajes) {
      switch (v.estado) {
        case EstadoViaje.enCurso:
          enCurso++;
        case EstadoViaje.concluido:
          concluidos++;
        case EstadoViaje.planeado:
          planeados++;
      }
      // "Ganancia choferes" = lo que se les paga por los viajes del mes
      // (montoChoferRedondeado), sin depender del flag liquidado — que
      // se quitó de Liquidación (Santiago 2026-06-10). Incluye los tres
      // estados: es la ganancia total del mes.
      ganancia += v.montoChoferRedondeado;
    }

    return AppKpiStrip(
      stats: [
        AppStat(label: 'Total', value: '${viajes.length}'),
        AppStat(label: 'En curso', value: '$enCurso', accent: c.warning),
        AppStat(label: 'Concluidos', value: '$concluidos', accent: c.success),
        AppStat(label: 'Planeados', value: '$planeados', accent: c.info),
        AppStat(
          label: 'Ganancia choferes',
          value: AppFormatters.formatearMonto(ganancia),
          valueStyle: AppType.h4,
        ),
      ],
    );
  }
}

// =============================================================================
// FILTROS — estado / liquidación / mostrar eliminados (pills Núcleo)
// =============================================================================

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
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _ChipFiltro(
            label: estado == null ? 'Estado' : estado!.etiqueta,
            seleccionado: estado != null,
            onTap: () => _abrirEstadoMenu(context),
          ),
          _ChipFiltro(
            label: liquidado == null
                ? 'Liquidación'
                : (liquidado! ? 'Liquidados' : 'Sin liquidar'),
            seleccionado: liquidado != null,
            onTap: () => _abrirLiquidadoMenu(context),
          ),
          // Filtro "Mostrar eliminados". Default OFF — los borrados
          // viven solo para auditoría. Mismo patrón visual que los otros
          // chips, pero con tinte error cuando está activo.
          _ChipFiltro(
            label: 'Mostrar eliminados',
            seleccionado: verBorrados,
            colorActivo: AppColors.error,
            icono: verBorrados ? Icons.visibility : Icons.visibility_off,
            onTap: () => onVerBorradosChanged(!verBorrados),
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

/// Pill de filtro estilo Núcleo. Inactivo: transparente con borde. Activo:
/// tinte del color (brand por default) con borde del mismo color. Soporta
/// un ícono opcional (toggle de borrados) y un caret cuando abre un menú.
class _ChipFiltro extends StatelessWidget {
  final String label;
  final bool seleccionado;
  final VoidCallback onTap;
  final Color? colorActivo;
  final IconData? icono;

  const _ChipFiltro({
    required this.label,
    required this.seleccionado,
    required this.onTap,
    this.colorActivo,
    this.icono,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accent = colorActivo ?? c.brand;
    final fg = seleccionado ? accent : c.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: seleccionado
              ? accent.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: seleccionado ? accent.withValues(alpha: 0.5) : c.borderStrong,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icono != null) ...[
              Icon(icono, size: 14, color: fg),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: AppType.label.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (icono == null) ...[
              const SizedBox(width: 4),
              Icon(Icons.arrow_drop_down, size: 18, color: fg),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// CUERPO — loading / error / vacío / tabla(desktop) / cards(mobile)
// =============================================================================

class _Cuerpo extends StatelessWidget {
  final bool cargando;
  final Object? error;
  final bool esDesktop;
  final bool haDatos;
  final List<Viaje> filtrados;

  const _Cuerpo({
    required this.cargando,
    required this.error,
    required this.esDesktop,
    required this.haDatos,
    required this.filtrados,
  });

  @override
  Widget build(BuildContext context) {
    if (cargando) {
      return const AppSkeletonList(count: 6, conAvatar: false);
    }
    if (error != null) {
      return AppErrorState(
        title: 'No se pudieron cargar los viajes',
        subtitle: '$error',
      );
    }
    if (filtrados.isEmpty) {
      return AppEmptyState(
        icon: Icons.route_outlined,
        title: haDatos
            ? 'Sin coincidencias'
            : 'Todavía no hay viajes registrados',
        subtitle: haDatos
            ? 'Ningún viaje coincide con los filtros aplicados.'
            : 'Tocá NUEVO VIAJE para registrar el primero.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 88),
      itemCount: filtrados.length,
      itemBuilder: (_, i) => esDesktop
          ? _FilaViaje(viaje: filtrados[i])
          : _ViajeCard(viaje: filtrados[i]),
    );
  }
}

// =============================================================================
// TABLA (desktop): encabezado + fila
// =============================================================================

// Flex de las columnas — el header y las filas comparten estos pesos para
// que queden alineados. FECHA · CHOFER · UNIDAD · RUTA · MONTO · ESTADO · →
const int _flexFecha = 3;
const int _flexChofer = 4;
const int _flexUnidad = 3;
const int _flexRuta = 6;
const int _flexMonto = 3;
const int _flexEstado = 4;

class _FilaHeader extends StatelessWidget {
  const _FilaHeader();

  @override
  Widget build(BuildContext context) {
    Widget h(String t, int flex, {TextAlign align = TextAlign.left}) =>
        Expanded(
          flex: flex,
          child: Text(t.toUpperCase(), style: AppType.eyebrow, textAlign: align),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          h('Fecha', _flexFecha),
          h('Chofer', _flexChofer),
          h('Unidad', _flexUnidad),
          h('Origen → Destino', _flexRuta),
          h('Monto', _flexMonto, align: TextAlign.right),
          h('Estado', _flexEstado),
          const SizedBox(width: 24),
        ],
      ),
    );
  }
}

class _FilaViaje extends StatelessWidget {
  final Viaje viaje;
  const _FilaViaje({required this.viaje});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fechaRef = viaje.fechaReferencia;
    final estadoColor = _colorEstado(context, viaje.estado);

    return AppCard(
      tier: 1,
      onTap: () => Navigator.pushNamed(
        context,
        AppRoutes.adminLogisticaViajeDetalle,
        arguments: {'viajeId': viaje.id},
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          // Fecha (mono tabular).
          Expanded(
            flex: _flexFecha,
            child: Text(
              fechaRef == null
                  ? '—'
                  : AppFormatters.formatearFecha(fechaRef),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.mono.copyWith(
                color: fechaRef == null ? c.textMuted : c.text,
              ),
            ),
          ),
          // Chofer.
          Expanded(
            flex: _flexChofer,
            child: Text(
              viaje.choferNombre ?? 'DNI ${viaje.choferDni}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          // Unidad (patente del tractor — mono tabular).
          Expanded(
            flex: _flexUnidad,
            child: Text(
              _unidad(viaje),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.mono.copyWith(
                color: viaje.vehiculoId == null ? c.textMuted : c.text,
              ),
            ),
          ),
          // Origen → Destino.
          Expanded(
            flex: _flexRuta,
            child: _RutaInline(viaje: viaje),
          ),
          // Monto chofer redondeado (mono tabular, alineado a la derecha).
          Expanded(
            flex: _flexMonto,
            child: Text(
              AppFormatters.formatearMonto(viaje.montoChoferRedondeado),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: AppType.mono.copyWith(color: c.text),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // Estado (+ liquidado / borrado).
          Expanded(
            flex: _flexEstado,
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AppBadge(
                  text: viaje.estado.etiqueta,
                  color: estadoColor,
                  size: AppBadgeSize.sm,
                  dot: true,
                ),
                if (viaje.liquidado)
                  AppBadge(
                    text: 'Liquidado',
                    color: c.success,
                    size: AppBadgeSize.sm,
                    icon: Icons.check,
                  ),
                if (!viaje.activo)
                  AppBadge(
                    text: 'Borrado',
                    color: c.error,
                    size: AppBadgeSize.sm,
                  ),
              ],
            ),
          ),
          // Acción: restaurar (si borrado) o chevron.
          if (!viaje.activo)
            _BotonRestaurar(viaje: viaje)
          else
            Icon(Icons.chevron_right, size: 18, color: c.textMuted),
        ],
      ),
    );
  }
}

// =============================================================================
// CARD (mobile): card rica re-skineada a tokens Núcleo
// =============================================================================

class _ViajeCard extends StatelessWidget {
  final Viaje viaje;
  const _ViajeCard({required this.viaje});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fechaRef = viaje.fechaReferencia;
    final estadoColor = _colorEstado(context, viaje.estado);

    return AppCard(
      tier: 1,
      accent: estadoColor,
      onTap: () => Navigator.pushNamed(
        context,
        AppRoutes.adminLogisticaViajeDetalle,
        arguments: {'viajeId': viaje.id},
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Línea 1: fecha + chofer + estado.
          Row(
            children: [
              Text(
                fechaRef == null
                    ? '—'
                    : AppFormatters.formatearFecha(fechaRef),
                style: AppType.mono.copyWith(
                  color: fechaRef == null ? c.textMuted : c.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  viaje.choferNombre ?? 'DNI ${viaje.choferDni}',
                  style: AppType.bodySm,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              AppBadge(
                text: viaje.estado.etiqueta,
                color: estadoColor,
                size: AppBadgeSize.sm,
                dot: true,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Línea 2: ruta.
          _RutaInline(viaje: viaje),
          const SizedBox(height: 8),
          // Línea 3: unidad + monto chofer + flags.
          Row(
            children: [
              Icon(Icons.local_shipping_outlined, size: 14, color: c.textMuted),
              const SizedBox(width: 4),
              Text(
                _unidad(viaje),
                style: AppType.monoSm.copyWith(
                  color: viaje.vehiculoId == null ? c.textMuted : c.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                AppFormatters.formatearMonto(viaje.montoChoferRedondeado),
                style: AppType.mono.copyWith(
                  color: c.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (viaje.liquidado || !viaje.activo) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (viaje.liquidado)
                  AppBadge(
                    text: 'Liquidado',
                    color: c.success,
                    size: AppBadgeSize.sm,
                    icon: Icons.check,
                  ),
                if (viaje.liquidado && !viaje.activo)
                  const SizedBox(width: 6),
                if (!viaje.activo)
                  AppBadge(
                    text: 'Borrado',
                    color: c.error,
                    size: AppBadgeSize.sm,
                  ),
                const Spacer(),
                if (!viaje.activo) _BotonRestaurar(viaje: viaje),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// HELPERS COMPARTIDOS
// =============================================================================

/// Origen → Destino con la flecha en tinte muted, estilo prototipo.
/// El texto se trunca con ellipsis para no desbordar la columna.
class _RutaInline extends StatelessWidget {
  final Viaje viaje;
  const _RutaInline({required this.viaje});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final origen = viaje.tramoPrincipal.tarifaSnapshot.origenEtiqueta;
    final destino = viaje.tramoFinal.tarifaSnapshot.destinoEtiqueta;
    final multi = viaje.esMultiTramo;
    return Row(
      children: [
        Flexible(
          child: Text(
            origen.isEmpty ? '—' : origen,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.bodySm.copyWith(color: c.text),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('→', style: AppType.bodySm.copyWith(color: c.textMuted)),
        ),
        Flexible(
          child: Text(
            destino.isEmpty ? '—' : destino,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.bodySm.copyWith(color: c.text),
          ),
        ),
        if (multi) ...[
          const SizedBox(width: 6),
          Text(
            '· ${viaje.cantidadTramos} tramos',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.monoSm.copyWith(color: c.textMuted),
          ),
        ],
      ],
    );
  }
}

/// Botón rápido restaurar — evita abrir el detalle solo para reactivar.
/// Confirmación inline en diálogo corto. Misma lógica que la versión previa.
class _BotonRestaurar extends StatelessWidget {
  final Viaje viaje;
  const _BotonRestaurar({required this.viaje});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.restore, size: 18, color: context.colors.brand),
      tooltip: 'Reactivar viaje',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(),
      padding: const EdgeInsets.all(AppSpacing.xs),
      onPressed: () => _confirmarReactivar(context, viaje),
    );
  }

  Future<void> _confirmarReactivar(BuildContext ctx, Viaje v) async {
    final messenger = ScaffoldMessenger.of(ctx);
    final fecha = v.fechaReferencia;
    final fechaStr =
        fecha == null ? 'sin fecha' : AppFormatters.formatearFecha(fecha);
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
              backgroundColor: AppColors.brand,
              foregroundColor: AppColors.surface0,
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
}

/// Patente del tractor del viaje. Si no hay vehículo asignado → `—`.
String _unidad(Viaje v) {
  final u = v.vehiculoId?.trim();
  return (u == null || u.isEmpty) ? '—' : u;
}

/// Color semántico por estado (resuelto contra el theme activo).
Color _colorEstado(BuildContext context, EstadoViaje e) {
  final c = context.colors;
  switch (e) {
    case EstadoViaje.planeado:
      return c.info;
    case EstadoViaje.enCurso:
      return c.warning;
    case EstadoViaje.concluido:
      return c.success;
  }
}
