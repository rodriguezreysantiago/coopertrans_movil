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
/// hero con eyebrow + selector de mes (◀ MES ▶) + [Nuevo viaje], un strip de
/// KPIs **que son los filtros** (PLANEADOS · EN CURSO · CONCLUIDOS · TOTAL ·
/// GANANCIA CHOFERES, todo del mes), buscador Núcleo, un único toggle de
/// eliminados y una **tabla** densa en desktop. En mobile se mantienen cards
/// ricas (re-skineadas a tokens).
///
/// **Vista mensual (Santiago 2026-06-10)**: la lista + KPIs se acotan al mes
/// elegido (por fecha de referencia). El BUSCADOR es global: al tipear texto,
/// busca en todos los meses (para encontrar un viaje sin saber cuándo fue).
///
/// **KPIs = filtros (Santiago 2026-06-10)**: tocar PLANEADOS/EN CURSO/
/// CONCLUIDOS filtra la lista por ese estado; TOTAL limpia el filtro. El KPI
/// activo queda resaltado. GANANCIA CHOFERES es informativo (no filtra). Se
/// quitaron los chips Estado y Liquidación (redundantes con los KPIs / ya sin
/// uso). Queda solo "Mostrar eliminados", que muestra SOLO los eliminados.
///
/// La fila de tabla y la card abren el MISMO detalle (`adminLogisticaViajeDetalle`).
/// Stream cacheado; sort (más viejo arriba) y navegación quedan intactos.
class LogisticaViajesListaScreen extends StatefulWidget {
  const LogisticaViajesListaScreen({super.key});

  @override
  State<LogisticaViajesListaScreen> createState() =>
      _LogisticaViajesListaScreenState();
}

class _LogisticaViajesListaScreenState
    extends State<LogisticaViajesListaScreen> {
  // Filtro por estado — ahora se maneja desde el strip de KPIs (tocar
  // PLANEADOS/EN CURSO/CONCLUIDOS filtra; TOTAL = null = todos). El chip
  // "Estado" y el menú quedaron obsoletos (Santiago 2026-06-10).
  EstadoViaje? _filtroEstado;
  // Toggle papelera. Cuando está ON, la lista + KPIs muestran SOLO los
  // viajes eliminados del mes (Santiago 2026-06-10). El filtro de
  // liquidación se quitó por completo (ya no se usa).
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
              // Conjunto visible según el modo papelera: normal = activos
              // (el stream ya excluye inactivos); papelera = SOLO los
              // eliminados (Santiago 2026-06-10). Todo lo de abajo —
              // KPIs, lista, búsqueda— opera sobre este conjunto.
              final visibles = _verBorrados
                  ? todos.where((v) => !v.activo).toList()
                  : todos;
              // Viajes del MES en foco (alimentan el strip de KPIs).
              final delMes = visibles
                  .where((v) => _esDelMes(v, _mesSeleccionado))
                  .toList();
              final filtrados = _aplicarFiltros(visibles);
              return Column(
                children: [
                  // Hero: eyebrow + selector de mes + [Nuevo viaje]. El
                  // conteo grande se quitó: vive en el KPI TOTAL de abajo.
                  _Header(
                    mes: _mesSeleccionado,
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
                  // Strip de KPIs = filtros (Santiago 2026-06-10). Tocar
                  // PLANEADOS/EN CURSO/CONCLUIDOS filtra; TOTAL limpia. En
                  // papelera vacía no se muestra (gate sobre `visibles`).
                  if (visibles.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
                      child: _StripFiltros(
                        viajes: delMes,
                        filtroEstado: _filtroEstado,
                        esDesktop: esDesktop,
                        onEstado: (e) => setState(() => _filtroEstado = e),
                      ),
                    ),
                  // Único filtro suelto: toggle papelera.
                  _BarraFiltros(
                    verBorrados: _verBorrados,
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
                      haDatos: visibles.isNotEmpty,
                      modoPapelera: _verBorrados,
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
      // Filtro por estado (lo setea el strip de KPIs; null = TOTAL = todos).
      if (_filtroEstado != null && v.estado != _filtroEstado) return false;
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
  final VoidCallback onMesAnterior;
  final VoidCallback onMesSiguiente;
  final VoidCallback onNuevo;
  const _Header({
    required this.mes,
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
          const SizedBox(height: AppSpacing.sm),
          // Fila 2: acción primaria a la derecha. El conteo grande se
          // quitó (Santiago 2026-06-10): repetía el KPI TOTAL de abajo.
          Align(
            alignment: Alignment.centerRight,
            child: AppButton.primary(
              label: 'Nuevo viaje',
              icon: Icons.add,
              size: AppButtonSize.sm,
              onPressed: onNuevo,
            ),
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
// STRIP DE KPIs = FILTROS — PLANEADOS · EN CURSO · CONCLUIDOS · TOTAL · GANANCIA
// =============================================================================

/// Strip de KPIs del mes que ADEMÁS son el filtro por estado (Santiago
/// 2026-06-10). Orden fijo: PLANEADOS · EN CURSO · CONCLUIDOS · TOTAL ·
/// GANANCIA CHOFERES. Las 4 primeras son tappeables: tocar un estado
/// filtra la lista; TOTAL limpia el filtro. La celda activa se resalta.
/// GANANCIA es informativa (no filtra).
///
/// Estética calcada de `AppKpiStrip` (surface2 + border + hairlines), pero
/// con celdas interactivas. En desktop las 5 celdas se reparten el ancho
/// (Expanded); en mobile el strip scrollea horizontal para no apretar el
/// monto de ganancia.
class _StripFiltros extends StatelessWidget {
  final List<Viaje> viajes;
  final EstadoViaje? filtroEstado;
  final ValueChanged<EstadoViaje?> onEstado;
  final bool esDesktop;
  const _StripFiltros({
    required this.viajes,
    required this.filtroEstado,
    required this.onEstado,
    required this.esDesktop,
  });

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
      // (montoChoferRedondeado), los tres estados.
      ganancia += v.montoChoferRedondeado;
    }

    final celdas = <Widget>[
      _CeldaKpi(
        label: 'Planeados',
        value: '$planeados',
        accent: c.info,
        seleccionado: filtroEstado == EstadoViaje.planeado,
        esDesktop: esDesktop,
        onTap: () => onEstado(EstadoViaje.planeado),
      ),
      _CeldaKpi(
        label: 'En curso',
        value: '$enCurso',
        accent: c.warning,
        seleccionado: filtroEstado == EstadoViaje.enCurso,
        esDesktop: esDesktop,
        onTap: () => onEstado(EstadoViaje.enCurso),
      ),
      _CeldaKpi(
        label: 'Concluidos',
        value: '$concluidos',
        accent: c.success,
        seleccionado: filtroEstado == EstadoViaje.concluido,
        esDesktop: esDesktop,
        onTap: () => onEstado(EstadoViaje.concluido),
      ),
      _CeldaKpi(
        label: 'Total',
        value: '${viajes.length}',
        accent: c.text,
        tintSeleccion: c.brand,
        seleccionado: filtroEstado == null,
        esDesktop: esDesktop,
        onTap: () => onEstado(null),
      ),
      _CeldaKpi(
        label: 'Ganancia choferes',
        value: AppFormatters.formatearMonto(ganancia),
        accent: c.text,
        valueStyle: AppType.h4,
        seleccionado: false,
        esDesktop: esDesktop,
        onTap: null,
      ),
    ];

    Widget fila;
    if (esDesktop) {
      fila = IntrinsicHeight(
        child: Row(
          children: [
            for (var i = 0; i < celdas.length; i++) ...[
              Expanded(child: celdas[i]),
              if (i < celdas.length - 1) Container(width: 1, color: c.border),
            ],
          ],
        ),
      );
    } else {
      fila = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: IntrinsicHeight(
          child: Row(
            children: [
              for (var i = 0; i < celdas.length; i++) ...[
                celdas[i],
                if (i < celdas.length - 1)
                  Container(width: 1, color: c.border),
              ],
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: fila,
      ),
    );
  }
}

/// Una celda del strip. Tappeable si `onTap != null`. Resalta con un tinte
/// suave cuando `seleccionado`. `accent` colorea el número; `tintSeleccion`
/// el fondo activo (default: `accent`).
class _CeldaKpi extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;
  final Color? tintSeleccion;
  final bool seleccionado;
  final bool esDesktop;
  final VoidCallback? onTap;
  final TextStyle? valueStyle;
  const _CeldaKpi({
    required this.label,
    required this.value,
    required this.accent,
    required this.seleccionado,
    required this.esDesktop,
    required this.onTap,
    this.tintSeleccion,
    this.valueStyle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = tintSeleccion ?? accent;
    final contenido = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: esDesktop ? 22 : 14,
        vertical: esDesktop ? 18 : 14,
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
              color: seleccionado ? tint : c.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (valueStyle ?? AppType.h2).copyWith(
              color: accent,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );

    final celda = ConstrainedBox(
      // En mobile (scroll) fijamos un mínimo para que sean tappeables;
      // en desktop el Expanded del strip manda y el min queda en 0.
      constraints: BoxConstraints(
        minWidth: esDesktop ? 0 : (onTap == null ? 132 : 92),
      ),
      child: ColoredBox(
        color: seleccionado
            ? tint.withValues(alpha: 0.12)
            : Colors.transparent,
        child: contenido,
      ),
    );

    if (onTap == null) return celda;
    return InkWell(onTap: onTap, child: celda);
  }
}

// =============================================================================
// FILTRO — único toggle "Mostrar eliminados" (pill Núcleo)
// =============================================================================

/// El filtro por estado vive ahora en el strip de KPIs y el de liquidación
/// se eliminó (Santiago 2026-06-10). Queda solo el toggle papelera: ON =
/// la lista + KPIs muestran SOLO los viajes eliminados del mes (si los hay).
class _BarraFiltros extends StatelessWidget {
  final bool verBorrados;
  final ValueChanged<bool> onVerBorradosChanged;

  const _BarraFiltros({
    required this.verBorrados,
    required this.onVerBorradosChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _ChipFiltro(
          label: 'Mostrar eliminados',
          seleccionado: verBorrados,
          colorActivo: AppColors.error,
          icono: verBorrados ? Icons.visibility : Icons.visibility_off,
          onTap: () => onVerBorradosChanged(!verBorrados),
        ),
      ),
    );
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
  final bool modoPapelera;
  final List<Viaje> filtrados;

  const _Cuerpo({
    required this.cargando,
    required this.error,
    required this.esDesktop,
    required this.haDatos,
    required this.modoPapelera,
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
      // Modo papelera: copy propio (no es "sin coincidencias", es que no
      // hay nada eliminado en el período).
      if (modoPapelera) {
        return const AppEmptyState(
          icon: Icons.delete_outline,
          title: 'Sin viajes eliminados',
          subtitle: 'No hay viajes eliminados en el período seleccionado.',
        );
      }
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
