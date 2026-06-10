// lib/features/logistica/screens/logistica_liquidacion_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — liquidación de choferes en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - los streams (`LiquidacionService.streamEmpleadosCache`,
//     `streamViajesEnRango`, `AdelantosService.streamAdelantosEnRango`),
//   - los filtros (mes / empresa empleadora / chofer),
//   - TODAS las agregaciones financieras (facturado = ∑ montoVecchi,
//     ganancia chofer = ∑ montoChoferRedondeado, adelantos, gastos, neto =
//     chofer − adelantos + gastos), por chofer y por viaje,
//   - la acción `marcarLiquidadosBulk` con su confirm + feedback,
//   - la exportación a Excel (`ReportLiquidacionService.generar`),
//   - la navegación al detalle del viaje.
//
// Layout Núcleo:
//   ┌─ Filtros: hero del mes (◀ MES ▶) + empresa + chofer + pills estado ─┐
//   ├─ AppKpiStrip: facturado · ganancia chofer · adelantos · gastos · neto ┤
//   ├─ Acciones (liquidar bulk / exportar Excel) ────────────────────────┤
//   ├─ POR CHOFER (cards bento, hairlines, montos en mono) ──────────────┤
//   └─ ó VIAJES + ADELANTOS del chofer (si hay chofer filtrado) ─────────┘
//
// Reglas duras: tokens (context.colors), montos en AppType.mono, embedded
// (sin fondo full-screen propio), faltante → "—", sin overflow.

import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/adelanto_chofer.dart';
import '../models/viaje.dart';
import '../services/adelantos_service.dart';
import '../services/report_liquidacion.dart';
import '../services/liquidacion_service.dart';
import '../utils/liquidacion_totales.dart';

/// Pantalla LIQUIDACIÓN — agregaciones financieras de los viajes
/// del mes filtrados por **empresa empleadora del chofer** (no por
/// cliente del flete) + chofer opcional.
///
/// Reemplaza la acción "Marcar liquidado" individual del detalle de
/// viaje (eliminada 2026-05-11). El operador trabaja por mes/empresa:
/// ve los KPIs agregados (facturación, adelantos, gastos, neto), la
/// tabla por chofer con sus números, y puede marcar todo como
/// liquidado en bulk con un botón.
///
/// **Decisiones operativas (Vecchi 2026-05-11)**:
///   - El filtro de empresa va por la empresa empleadora del chofer,
///     NO por la empresa cliente del flete. Cada chofer pertenece a
///     una razón social (Vecchi Ariel SRL o Sucesión Vecchi Carlos)
///     y la liquidación se hace separada por razón social.
///   - El mes se calcula por `fecha_carga` del viaje (la fecha real
///     del evento), no por `creado_en`.
///   - "Facturación a empresa" = ∑ `montoVecchi` (lo que cobra la
///     transportista por la operación, antes de comisión chofer).
///   - "Ganancia chofer" = ∑ `montoChoferRedondeado` (lo que se le
///     paga, después de redondeo a múltiplo de 5 descendente).
///   - "Adelantos" y "Gastos" se restan del total chofer para el
///     neto a cobrar/pagar.
class LogisticaLiquidacionScreen extends StatefulWidget {
  const LogisticaLiquidacionScreen({super.key});

  @override
  State<LogisticaLiquidacionScreen> createState() =>
      _LogisticaLiquidacionScreenState();
}

class _LogisticaLiquidacionScreenState
    extends State<LogisticaLiquidacionScreen> {
  /// Mes filtrado. Default = mes actual (1ro del mes a las 00:00 ART).
  late DateTime _mesSeleccionado;

  /// CUIT de empresa empleadora filtrada. `null` = todas.
  String? _empresaCuit;

  /// DNI de chofer filtrado. `null` = todos los choferes de la empresa.
  String? _choferDni;

  // El filtro liquidado/no-liquidado se removió el 2026-06-10 (Santiago):
  // a fin de mes se liquidan todos igual, así que filtrar por ese estado
  // solo agregaba ruido. La pantalla muestra SIEMPRE todos los viajes del
  // mes, separados por su estado operativo (concluido / en curso / planeado).

  @override
  void initState() {
    super.initState();
    final ahora = DateTime.now();
    _mesSeleccionado = DateTime(ahora.year, ahora.month, 1);
    // Pre-cargar el cache de excluidos para que el filtro en
    // `LiquidacionService.streamEmpleadosCache()` (que usa el cache
    // sincrónico) aplique desde la primera emisión del stream. Sin
    // esto, el dropdown podría mostrar testers/tanqueros la primera
    // vez que se abre la pantalla en una sesión nueva.
    ExcluidosService.cargar();
  }

  /// Inicio del mes seleccionado, hora ART (00:00). Se compara contra
  /// `fecha_carga` del viaje.
  DateTime get _inicioMes => _mesSeleccionado;

  /// Inicio del mes SIGUIENTE (exclusive). Si el viaje tiene
  /// `fecha_carga >= inicioMes && < inicioMesSiguiente`, está en el mes.
  DateTime get _inicioMesSiguiente {
    final m = _mesSeleccionado.month;
    final y = _mesSeleccionado.year;
    if (m == 12) return DateTime(y + 1, 1, 1);
    return DateTime(y, m + 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Liquidación',
      body: StreamBuilder<Map<String, EmpleadoLiquidacion>>(
        stream: LiquidacionService.streamEmpleadosCache(),
        builder: (ctx, empSnap) {
          if (empSnap.hasError) {
            return AppErrorState(
              title: 'No se pudo cargar el padrón de choferes',
              subtitle: empSnap.error.toString(),
            );
          }
          if (!empSnap.hasData) return const AppLoadingState();
          final empleados = empSnap.data!;

          // Choferes que pasan el filtro de empresa (si está aplicado).
          final choferesFiltrados = _empresaCuit == null
              ? empleados
              : Map.fromEntries(
                  empleados.entries.where(
                    (e) => e.value.empresaCuit == _empresaCuit,
                  ),
                );

          // Si hay chofer seleccionado, filtrar viajes solo a ese DNI.
          // Si no, pasar todos los DNIs de la empresa filtrada (o null
          // si tampoco hay empresa seleccionada → todos los choferes).
          final dnisFiltro = _choferDni != null
              ? {_choferDni!}
              : (_empresaCuit != null
                  ? choferesFiltrados.keys.toSet()
                  : null);
          // ADELANTOS: aun SIN filtro de empresa/chofer hay que acotar al
          // padrón de choferes válidos. Desde 2026-05-15 los adelantos son
          // para todo el personal (no solo choferes); si dejáramos
          // `choferDnis: null` se colarían adelantos de administrativos y de
          // tanqueros/testers excluidos → inflaban el neto global y armaban
          // filas fantasma en la tabla por chofer y el Excel (bug audit
          // 2026-06-04). `empleados` ya viene filtrado a ROL=CHOFER + ACTIVO
          // + sin excluidos, así que es el universo correcto.
          final dnisAdelantos = dnisFiltro ?? empleados.keys.toSet();

          return Column(
            children: [
              _BarraFiltros(
                mes: _mesSeleccionado,
                empresaCuit: _empresaCuit,
                choferDni: _choferDni,
                empleados: choferesFiltrados,
                onMesChanged: (m) => setState(() => _mesSeleccionado = m),
                onEmpresaChanged: (cuit) => setState(() {
                  _empresaCuit = cuit;
                  // Si cambia la empresa, resetear chofer (puede no
                  // pertenecer a la nueva empresa).
                  _choferDni = null;
                }),
                onChoferChanged: (dni) => setState(() => _choferDni = dni),
              ),
              Expanded(
                child: StreamBuilder<List<Viaje>>(
                  stream: LiquidacionService.streamViajesEnRango(
                    desde: _inicioMes,
                    hasta: _inicioMesSiguiente,
                    choferDnis: dnisFiltro,
                  ),
                  builder: (ctx, viajesSnap) {
                    if (viajesSnap.hasError) {
                      return AppErrorState(
                        title: 'No se pudieron cargar los viajes',
                        subtitle: viajesSnap.error.toString(),
                      );
                    }
                    if (!viajesSnap.hasData) {
                      return const AppLoadingState();
                    }
                    // Todos los viajes del mes (+ empresa/chofer del
                    // stream). Sin filtro de liquidado: la pantalla y el
                    // export muestran SIEMPRE todo, separado por estado
                    // operativo (concluido / en curso / planeado).
                    final viajes = viajesSnap.data!;
                    // Stream paralelo de adelantos en el mismo rango,
                    // filtrados por los mismos DNIs (empresa+chofer).
                    // Los adelantos NO viven en el viaje desde el
                    // refactor 2026-05-13 — se suman aparte para el
                    // neto del chofer.
                    return StreamBuilder<List<AdelantoChofer>>(
                      stream: AdelantosService.streamAdelantosEnRango(
                        desde: _inicioMes,
                        hasta: _inicioMesSiguiente,
                        choferDnis: dnisAdelantos,
                      ),
                      builder: (ctx, adSnap) {
                        if (adSnap.hasError) {
                          return AppErrorState(
                            title: 'No se pudieron cargar los adelantos',
                            subtitle: adSnap.error.toString(),
                          );
                        }
                        // Si todavía no hay datos de adelantos, mostramos
                        // los KPIs con lista vacía (no bloquea el flujo —
                        // el operador ve la grilla y los adelantos
                        // aparecen apenas llegan).
                        final adelantos = adSnap.data ?? const <AdelantoChofer>[];
                        return _Contenido(
                          viajes: viajes,
                          adelantos: adelantos,
                          empleados: empleados,
                          choferDniFiltro: _choferDni,
                          // Tappear una card de chofer lo selecciona en el
                          // filtro → muestra su "cuaderno".
                          onChoferTap: (dni) =>
                              setState(() => _choferDni = dni),
                          onVolverTodos: () =>
                              setState(() => _choferDni = null),
                          onLiquidarBulk: () => _liquidarBulk(context, viajes),
                          onExportarExcel: () =>
                              ReportLiquidacionService.generar(
                            context: context,
                            // La planilla mensual trae SIEMPRE todos los
                            // viajes del mes. Respeta empresa/chofer.
                            viajes: viajes,
                            adelantos: adelantos,
                            empleados: empleados,
                            mes: _mesSeleccionado,
                            empresaCuit: _empresaCuit,
                            choferDniFiltro: _choferDni,
                            // Padrón = choferes que pasan el filtro actual
                            // (chofer / empresa / o todos). Así aparecen
                            // TODOS, con hoja vacía los sin actividad
                            // (Santiago 2026-06-10). Mismo set que acota
                            // los adelantos.
                            padronDnis: dnisAdelantos,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _liquidarBulk(BuildContext ctx, List<Viaje> viajes) async {
    // Solo CONCLUIDOS pendientes — los en curso/planeados son
    // especulación, no se liquidan hasta que terminen.
    final aLiquidar = viajes
        .where((v) => v.estado == EstadoViaje.concluido && !v.liquidado)
        .toList();
    if (aLiquidar.isEmpty) {
      AppFeedback.info(ctx, 'No hay viajes concluidos pendientes de liquidar.');
      return;
    }
    // Capturar messenger ANTES del await (BuildContext puede dejar de
    // estar montado después del confirm dialog si el user navega).
    final messenger = ScaffoldMessenger.of(ctx);
    final confirmar = await AppConfirmDialog.show(
      ctx,
      title: 'Liquidar ${aLiquidar.length} viaje(s)',
      message:
          'Vas a marcar como LIQUIDADOS ${aLiquidar.length} viaje(s) del '
          'mes ${AppFormatters.formatearMes(_mesSeleccionado)}. Esto significa '
          'que se le pagaron las comisiones a los choferes. ¿Confirmás?',
      confirmLabel: 'Liquidar',
    );
    if (confirmar != true) return;
    final dni = PrefsService.dni;
    try {
      final n = await LiquidacionService.marcarLiquidadosBulk(
        viajeIds: aLiquidar.map((v) => v.id).toList(),
        liquidadoPorDni: dni,
      );
      AppFeedback.successOn(messenger, '$n viaje(s) marcado(s) como liquidado(s).');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudieron liquidar todos los viajes. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }
}

// ============================================================================
// BARRA DE FILTROS (mes + empresa + chofer + liquidado) — Núcleo
// ============================================================================

class _BarraFiltros extends StatelessWidget {
  final DateTime mes;
  final String? empresaCuit;
  final String? choferDni;
  final Map<String, EmpleadoLiquidacion> empleados;
  final ValueChanged<DateTime> onMesChanged;
  final ValueChanged<String?> onEmpresaChanged;
  final ValueChanged<String?> onChoferChanged;

  const _BarraFiltros({
    required this.mes,
    required this.empresaCuit,
    required this.choferDni,
    required this.empleados,
    required this.onMesChanged,
    required this.onEmpresaChanged,
    required this.onChoferChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
      decoration: BoxDecoration(
        color: c.surface1,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hero del mes: eyebrow + (◀ MES ▶). El mes es el dato rector
          // de la pantalla — va prominente arriba.
          const AppEyebrow('Liquidación · período'),
          const SizedBox(height: 6),
          Row(
            children: [
              _FlechaMes(
                icon: Icons.chevron_left,
                tooltip: 'Mes anterior',
                onTap: () {
                  final m = mes.month;
                  final y = mes.year;
                  onMesChanged(
                      m == 1 ? DateTime(y - 1, 12, 1) : DateTime(y, m - 1, 1));
                },
              ),
              Expanded(
                child: Center(
                  child: Text(
                    AppFormatters.formatearMes(mes).toUpperCase(),
                    style: AppType.h4.copyWith(letterSpacing: -0.2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              _FlechaMes(
                icon: Icons.chevron_right,
                tooltip: 'Mes siguiente',
                onTap: () {
                  final m = mes.month;
                  final y = mes.year;
                  onMesChanged(
                      m == 12 ? DateTime(y + 1, 1, 1) : DateTime(y, m + 1, 1));
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Empresa empleadora + chofer (dropdowns Núcleo).
          _DropdownNucleo<String?>(
            label: 'Empresa empleadora',
            value: empresaCuit,
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Todas', overflow: TextOverflow.ellipsis),
              ),
              ...AppEmpresasEmpleadoras.catalogo.map(
                (e) => DropdownMenuItem<String?>(
                  value: e.cuit,
                  child: Text(e.nombre, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
            onChanged: onEmpresaChanged,
          ),
          const SizedBox(height: AppSpacing.sm),
          _DropdownNucleo<String?>(
            label: 'Chofer',
            value: choferDni,
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Todos', overflow: TextOverflow.ellipsis),
              ),
              ...(empleados.values.toList()
                    ..sort((a, b) => a.nombre.compareTo(b.nombre)))
                  .map(
                (e) => DropdownMenuItem<String?>(
                  value: e.dni,
                  child: Text(e.nombre, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
            onChanged: onChoferChanged,
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
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: c.surface3,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: c.borderStrong),
          ),
          child: Icon(icon, size: 20, color: c.textSecondary),
        ),
      ),
    );
  }
}

/// Dropdown estilo Núcleo: surface2 + borde + label uppercase/mono a la
/// izquierda. Reemplaza al DropdownButtonFormField Material (que pinta su
/// propio fondo claro). La lógica (items / onChanged / value) es idéntica.
class _DropdownNucleo<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T> onChanged;

  const _DropdownNucleo({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 64),
            child: Text(
              label.toUpperCase(),
              style: AppType.eyebrow.copyWith(color: c.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                isDense: true,
                dropdownColor: c.surface3,
                iconEnabledColor: c.textMuted,
                style: AppType.body.copyWith(color: c.text),
                items: items,
                // `T` es nullable (`String?`) acá, por eso el `null` de
                // "Todas/Todos" es un valor válido y se reenvía tal cual.
                onChanged: (v) => onChanged(v as T),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// CONTENIDO (KPIs + tabla por chofer / cuaderno del chofer)
// ============================================================================

class _Contenido extends StatelessWidget {
  final List<Viaje> viajes;
  final List<AdelantoChofer> adelantos;
  final Map<String, EmpleadoLiquidacion> empleados;
  final String? choferDniFiltro;
  final ValueChanged<String> onChoferTap;
  final VoidCallback onVolverTodos;
  final VoidCallback onLiquidarBulk;
  final VoidCallback onExportarExcel;

  const _Contenido({
    required this.viajes,
    required this.adelantos,
    required this.empleados,
    required this.choferDniFiltro,
    required this.onChoferTap,
    required this.onVolverTodos,
    required this.onLiquidarBulk,
    required this.onExportarExcel,
  });

  @override
  Widget build(BuildContext context) {
    // El empty-state mira AMBAS fuentes: si no hay viajes pero sí hay
    // adelantos (caso "adelanto de sueldo sin viaje"), igual mostramos
    // la información.
    if (viajes.isEmpty && adelantos.isEmpty) {
      return const AppEmptyState(
        icon: Icons.inbox_outlined,
        title: 'Sin viajes ni adelantos en el período',
        subtitle: 'Probá cambiar mes / empresa / chofer.',
      );
    }
    // Totales separando FIRME (concluidos) de ESPECULACIÓN (en
    // curso/planeados) — la visión de la planilla (Santiago 2026-06-10).
    final tot = LiquidacionTotales.de(viajes, adelantos);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxxl),
      children: [
        _SeccionKPIs(tot: tot),
        const SizedBox(height: AppSpacing.lg),
        if (tot.pendientes > 0) ...[
          AppButton.primary(
            label: 'Marcar ${tot.pendientes} viaje(s) como liquidados',
            icon: Icons.check_circle_outline,
            full: true,
            onPressed: onLiquidarBulk,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        // Exportar la planilla mensual (formato cuaderno) a Excel.
        AppButton.secondary(
          label: 'Exportar a Excel',
          icon: Icons.file_download_outlined,
          full: true,
          onPressed: onExportarExcel,
        ),
        const SizedBox(height: AppSpacing.lg),
        // Sin chofer filtrado → tabla agregada por chofer (tappeable).
        // Con chofer filtrado → su "cuaderno" (concluidos / otros / adel).
        if (choferDniFiltro == null)
          _TablaPorChofer(
            viajes: viajes,
            adelantos: adelantos,
            empleados: empleados,
            onChoferTap: onChoferTap,
          )
        else
          _CuadernoChofer(
            nombre: empleados[choferDniFiltro]?.nombre ?? 'Chofer',
            viajes: viajes,
            adelantos: adelantos,
            onVolverTodos: onVolverTodos,
          ),
      ],
    );
  }
}

// ============================================================================
// SECCIÓN bento reutilizable (eyebrow + dot opcional + contenido)
// ============================================================================

class _Seccion extends StatelessWidget {
  final String titulo;
  final Color? accentDot;
  final Widget? trailing;
  final List<Widget> children;

  const _Seccion({
    required this.titulo,
    this.accentDot,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (accentDot != null) ...[
                AppDot(accentDot!, size: 7),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(child: AppEyebrow(titulo, color: accentDot)),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ...children,
        ],
      ),
    );
  }
}

// ============================================================================
// KPIs — AppKpiStrip (hero numbers) + desglose firma del neto
// ============================================================================

class _SeccionKPIs extends StatelessWidget {
  final LiquidacionTotales tot;

  const _SeccionKPIs({required this.tot});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    String monto(double m) => '\$ ${AppFormatters.formatearMonto(m)}';

    // Hero numbers: lo FIRME. Si hay especulación, el 3er número es el
    // TOTAL ESTIMADO; si no, solo Facturado + Neto.
    final statsTop = <AppStat>[
      AppStat(
        label: 'Facturado',
        value: monto(tot.facturadoFirme),
        valueStyle: AppType.h4,
        accent: c.info,
      ),
      AppStat(
        label: 'Neto a pagar',
        value: monto(tot.netoFirme),
        valueStyle: AppType.h4,
        accent: tot.netoFirme >= 0 ? c.success : c.error,
      ),
      if (tot.hayOtros)
        AppStat(
          label: 'Total estimado',
          value: monto(tot.totalEstimado),
          valueStyle: AppType.h4,
          accent: c.brandSoft,
        ),
    ];

    return _Seccion(
      titulo: 'RESUMEN',
      accentDot: c.success,
      trailing: Text(
        '${tot.nConcluidos} concl. · ${tot.nOtros} otros · '
        '${tot.nAdelantos} adel.',
        style: AppType.monoSm.copyWith(color: c.textMuted),
      ),
      children: [
        LayoutBuilder(
          builder: (ctx, constraints) {
            if (constraints.maxWidth < 420 && statsTop.length == 3) {
              return Column(
                children: [
                  AppKpiStrip(stats: statsTop.sublist(0, 2)),
                  const SizedBox(height: AppSpacing.sm),
                  AppKpiStrip(stats: statsTop.sublist(2)),
                ],
              );
            }
            return AppKpiStrip(stats: statsTop);
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        // ── Liquidación FIRME (viajes concluidos) ──
        _LineaMonto(
            label: 'Ganancia viajes (concluidos)', valor: tot.gananciaFirme),
        _LineaMonto(
            label: 'Adelantos entregados',
            valor: -tot.adelantos,
            color: c.warning),
        _LineaMonto(
            label: 'Gastos a reembolsar',
            valor: tot.gastosFirme,
            color: c.warning),
        const SizedBox(height: AppSpacing.sm),
        const AppHairline(),
        const SizedBox(height: AppSpacing.sm),
        _LineaMonto(
            label: 'Neto a pagar (firme)',
            valor: tot.netoFirme,
            destacado: true),
        // ── ESPECULACIÓN (en curso / planeados) ──
        if (tot.hayOtros) ...[
          const SizedBox(height: AppSpacing.md),
          _LineaMonto(
            label: 'Otros viajes (en curso / planeados)',
            valor: tot.gananciaOtros,
            color: c.info,
          ),
          const SizedBox(height: AppSpacing.sm),
          const AppHairline(),
          const SizedBox(height: AppSpacing.sm),
          _LineaMonto(
              label: 'Total estimado',
              valor: tot.totalEstimado,
              destacado: true),
        ],
      ],
    );
  }
}

/// Fila label (izq) / monto (der) en mono. `destacado` engrosa y resalta;
/// los montos siguen pintándose verde/coral según signo cuando se destacan,
/// o con el color informativo pasado en [color].
class _LineaMonto extends StatelessWidget {
  final String label;
  final double valor;
  final Color? color;
  final bool destacado;
  const _LineaMonto({
    required this.label,
    required this.valor,
    this.color,
    this.destacado = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final valColor = destacado
        ? (valor >= 0 ? c.success : c.error)
        : (color ?? c.text);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: AppType.bodySm.copyWith(
                color: destacado ? c.text : c.textSecondary,
                fontWeight: destacado ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 4,
            child: Text(
              '\$ ${AppFormatters.formatearMonto(valor)}',
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (destacado ? AppType.mono : AppType.monoSm).copyWith(
                color: valColor,
                fontWeight: destacado ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// TABLA POR CHOFER (cuando no hay chofer filtrado)
// ============================================================================

class _TablaPorChofer extends StatelessWidget {
  final List<Viaje> viajes;
  final List<AdelantoChofer> adelantos;
  final Map<String, EmpleadoLiquidacion> empleados;
  final ValueChanged<String> onChoferTap;

  const _TablaPorChofer({
    required this.viajes,
    required this.adelantos,
    required this.empleados,
    required this.onChoferTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Agrupar viajes y adelantos por chofer DNI. Cada chofer puede
    // tener viajes, adelantos, o ambos (caso adelanto de sueldo sin
    // viaje en el mes).
    final viajesPorChofer = <String, List<Viaje>>{};
    for (final v in viajes) {
      viajesPorChofer.putIfAbsent(v.choferDni, () => []).add(v);
    }
    final adelantosPorChofer = <String, List<AdelantoChofer>>{};
    for (final a in adelantos) {
      adelantosPorChofer.putIfAbsent(a.choferDni, () => []).add(a);
    }
    // Union de DNIs (chofer puede aparecer porque tiene viajes, o
    // porque tiene adelantos, o ambos).
    final dnis = <String>{
      ...viajesPorChofer.keys,
      ...adelantosPorChofer.keys,
    }.toList()
      ..sort((a, b) {
        final na = empleados[a]?.nombre ?? a;
        final nb = empleados[b]?.nombre ?? b;
        return na.compareTo(nb);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xs, 0, AppSpacing.xs, AppSpacing.sm),
          child: AppEyebrow('Por chofer · ${dnis.length}'),
        ),
        for (final dni in dnis) ...[
          _CardChofer(
            nombre: empleados[dni]?.nombre ?? 'DNI $dni',
            viajes: viajesPorChofer[dni] ?? const <Viaje>[],
            adelantos: adelantosPorChofer[dni] ?? const <AdelantoChofer>[],
            onTap: () => onChoferTap(dni),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (dnis.isEmpty)
          Text(
            'Sin choferes en el período.',
            style: AppType.bodySm.copyWith(color: c.textMuted),
          ),
      ],
    );
  }
}

/// Card bento de un chofer en la tabla agregada: nombre + badges de
/// conteo, y las filas de montos (facturado / ganancia / adelantos /
/// gastos / neto). Mismos cálculos que la versión previa.
class _CardChofer extends StatelessWidget {
  final String nombre;
  final List<Viaje> viajes;
  final List<AdelantoChofer> adelantos;
  final VoidCallback onTap;

  const _CardChofer({
    required this.nombre,
    required this.viajes,
    required this.adelantos,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tot = LiquidacionTotales.de(viajes, adelantos);

    return AppCard(
      tier: 1,
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  nombre.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (tot.pendientes > 0) ...[
                const SizedBox(width: AppSpacing.sm),
                AppBadge(
                  text: '${tot.pendientes} pend.',
                  color: c.warning,
                  size: AppBadgeSize.sm,
                ),
              ],
              const SizedBox(width: AppSpacing.xs),
              Icon(Icons.chevron_right, size: 18, color: c.textMuted),
            ],
          ),
          const SizedBox(height: 4),
          // Conteos en mono muted (técnico): concluidos / otros / adel.
          Text(
            [
              '${tot.nConcluidos} concl.',
              if (tot.nOtros > 0) '${tot.nOtros} otros',
              if (tot.nAdelantos > 0) '${tot.nAdelantos} adel.',
            ].join('  ·  '),
            style: AppType.monoSm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: AppSpacing.sm),
          const AppHairline(),
          const SizedBox(height: AppSpacing.sm),
          _LineaMonto(label: 'Ganancia (concluidos)', valor: tot.gananciaFirme),
          _LineaMonto(
              label: 'Adelantos', valor: -tot.adelantos, color: c.warning),
          if (tot.gastosFirme > 0)
            _LineaMonto(label: 'Gastos', valor: tot.gastosFirme, color: c.warning),
          const SizedBox(height: AppSpacing.xs),
          const AppHairline(),
          const SizedBox(height: AppSpacing.xs),
          _LineaMonto(
              label: 'Neto a pagar (firme)',
              valor: tot.netoFirme,
              destacado: true),
          // Especulación, solo si hay viajes en curso/planeados.
          if (tot.hayOtros) ...[
            const SizedBox(height: AppSpacing.xs),
            _LineaMonto(
                label: 'Otros viajes', valor: tot.gananciaOtros, color: c.info),
            _LineaMonto(
                label: 'Total estimado',
                valor: tot.totalEstimado,
                destacado: true),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// CUADERNO DEL CHOFER (cuando hay chofer filtrado) — visión planilla
// ============================================================================

/// Vista por chofer estilo cuaderno (Santiago 2026-06-10): CONCLUIDOS
/// arriba (lo firme), OTROS VIAJES (en curso/planeados) abajo (la
/// especulación), y los adelantos. Cada viaje es una FILA compacta
/// (fecha + ruta + ganancia) que se despliega al tocar.
class _CuadernoChofer extends StatelessWidget {
  final String nombre;
  final List<Viaje> viajes;
  final List<AdelantoChofer> adelantos;
  final VoidCallback onVolverTodos;

  const _CuadernoChofer({
    required this.nombre,
    required this.viajes,
    required this.adelantos,
    required this.onVolverTodos,
  });

  int _porFecha(Viaje a, Viaje b) {
    final fa = a.fechaReferencia, fb = b.fechaReferencia;
    if (fa == null && fb == null) return 0;
    if (fa == null) return 1;
    if (fb == null) return -1;
    return fa.compareTo(fb);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final concluidos = viajes
        .where((v) => v.estado == EstadoViaje.concluido)
        .toList()
      ..sort(_porFecha);
    final otros = viajes
        .where((v) => v.estado != EstadoViaje.concluido)
        .toList()
      ..sort(_porFecha);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Volver a la vista de todos los choferes.
        InkWell(
          onTap: onVolverTodos,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.arrow_back, size: 16, color: c.brand),
                const SizedBox(width: AppSpacing.xs),
                Text('Ver todos los choferes',
                    style: AppType.label.copyWith(color: c.brand)),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (concluidos.isNotEmpty) ...[
          _Seccion(
            titulo: 'CONCLUIDOS · ${concluidos.length}',
            accentDot: c.success,
            children: [
              for (final v in concluidos) _ViajeFilaCompacta(v: v),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (otros.isNotEmpty) ...[
          _Seccion(
            titulo: 'OTROS VIAJES · ${otros.length}',
            accentDot: c.info,
            trailing: Text('en curso / planeados',
                style: AppType.monoSm.copyWith(color: c.textMuted)),
            children: [
              for (final v in otros) _ViajeFilaCompacta(v: v),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (adelantos.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xs, 0, AppSpacing.xs, AppSpacing.sm),
            child: AppEyebrow('Adelantos · ${adelantos.length}'),
          ),
          for (final a in adelantos) ...[
            _AdelantoCardLiquidacion(a: a),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
        if (concluidos.isEmpty && otros.isEmpty && adelantos.isEmpty)
          Text('Sin viajes ni adelantos de este chofer en el período.',
              style: AppType.bodySm.copyWith(color: c.textMuted)),
      ],
    );
  }
}

/// Fila compacta de un viaje dentro de una sección del cuaderno: fecha
/// + ruta + ganancia, con un badge de estado/liquidado. Al tocar
/// despliega el detalle (facturado, gastos, tramos) y un acceso al
/// detalle completo del viaje. Patrón "compacto y expandible" pedido
/// por Santiago 2026-06-10.
class _ViajeFilaCompacta extends StatefulWidget {
  final Viaje v;
  const _ViajeFilaCompacta({required this.v});

  @override
  State<_ViajeFilaCompacta> createState() => _ViajeFilaCompactaState();
}

class _ViajeFilaCompactaState extends State<_ViajeFilaCompacta> {
  bool _abierto = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final v = widget.v;
    final fecha = v.fechaReferencia != null
        ? AppFormatters.formatearFecha(v.fechaReferencia!)
        : '—';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Fila compacta tappeable.
        InkWell(
          onTap: () => setState(() => _abierto = !_abierto),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Row(
              children: [
                Icon(
                  _abierto ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: c.textMuted,
                ),
                const SizedBox(width: AppSpacing.xs),
                SizedBox(
                  width: 64,
                  child: Text(
                    fecha,
                    style: AppType.monoSm.copyWith(
                      color: v.fechaReferencia == null ? c.textMuted : c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    v.rutaEtiqueta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.bodySm.copyWith(color: c.textSecondary),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '\$ ${AppFormatters.formatearMonto(v.montoChoferRedondeado)}',
                  style: AppType.monoSm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (v.estado == EstadoViaje.concluido && !v.liquidado) ...[
                  const SizedBox(width: AppSpacing.sm),
                  AppDot(c.warning, size: 6),
                ],
              ],
            ),
          ),
        ),
        // Detalle desplegado.
        if (_abierto)
          Padding(
            padding: const EdgeInsets.only(
                left: 22, bottom: AppSpacing.sm, top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AppBadge(
                      text: v.estado.etiqueta,
                      color: v.estado == EstadoViaje.concluido
                          ? c.success
                          : c.info,
                      size: AppBadgeSize.sm,
                    ),
                    if (v.estado == EstadoViaje.concluido) ...[
                      const SizedBox(width: AppSpacing.xs),
                      AppBadge(
                        text: v.liquidado ? 'Liquidado' : 'Pendiente',
                        color: v.liquidado ? c.success : c.warning,
                        size: AppBadgeSize.sm,
                        dot: !v.liquidado,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                _LineaMonto(label: 'Facturado', valor: v.montoVecchi),
                _LineaMonto(
                    label: 'Ganancia chofer', valor: v.montoChoferRedondeado),
                if (v.gastosTotal > 0)
                  _LineaMonto(
                      label: 'Gastos', valor: v.gastosTotal, color: c.warning),
                if (v.esMultiTramo)
                  for (var i = 0; i < v.tramos.length; i++)
                    _DetalleTramoLiquidacion(
                        numero: i + 1, tramo: v.tramos[i]),
                const SizedBox(height: AppSpacing.xs),
                InkWell(
                  onTap: () => Navigator.pushNamed(
                    context,
                    AppRoutes.adminLogisticaViajeDetalle,
                    arguments: {'viajeId': v.id},
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(Icons.open_in_new, size: 14, color: c.brand),
                        const SizedBox(width: AppSpacing.xs),
                        Text('Ver detalle completo',
                            style: AppType.label.copyWith(color: c.brand)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        const AppHairline(),
      ],
    );
  }
}

/// Card compacta de un adelanto cuando el operador filtra por chofer
/// en LIQUIDACIÓN. Muestra fecha, monto, observación y número de
/// recibo si ya se imprimió. NO permite editar / borrar desde acá —
/// para eso está LOGÍSTICA → ADELANTOS.
class _AdelantoCardLiquidacion extends StatelessWidget {
  final AdelantoChofer a;
  const _AdelantoCardLiquidacion({required this.a});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      accent: c.warning,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          Icon(Icons.payments_outlined, size: 18, color: c.warning),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppFormatters.formatearFecha(a.fecha),
                  style: AppType.mono.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (a.observacion != null && a.observacion!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    a.observacion!,
                    style: AppType.bodySm.copyWith(color: c.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (a.numeroRecibo != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Recibo N° ${a.numeroRecibo.toString().padLeft(6, '0')}',
                    style: AppType.monoSm.copyWith(color: c.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(
            '−\$ ${AppFormatters.formatearMonto(a.monto)}',
            style: AppType.mono.copyWith(
              color: c.warning,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Fila compacta con datos de un tramo dentro del desplegable de
/// LIQUIDACIÓN. Solo muestra lo esencial para entender el detalle
/// (fechas, kg, ruta) — el monto del tramo NO se expone porque la
/// liquidación es por viaje completo, no por tramo.
class _DetalleTramoLiquidacion extends StatelessWidget {
  final int numero;
  final TramoViaje tramo;

  const _DetalleTramoLiquidacion({
    required this.numero,
    required this.tramo,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ts = tramo.tarifaSnapshot;
    final fc = tramo.fechaCarga != null
        ? AppFormatters.formatearFecha(tramo.fechaCarga!)
        : '—';
    final fd = tramo.fechaDescarga != null
        ? AppFormatters.formatearFecha(tramo.fechaDescarga!)
        : '—';
    final kgC = tramo.kgCargados != null
        ? '${AppFormatters.formatearMiles(tramo.kgCargados!.toInt())} kg'
        : null;
    final kgD = tramo.kgDescargados != null
        ? '${AppFormatters.formatearMiles(tramo.kgDescargados!.toInt())} kg'
        : null;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppDot(c.brand, size: 6),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'TRAMO $numero · ${ts.origenEtiqueta} → ${ts.destinoEtiqueta}',
                  style: AppType.eyebrow.copyWith(color: c.brand),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (tramo.producto != null && tramo.producto!.isNotEmpty)
            Text(
              tramo.producto!,
              style: AppType.bodySm.copyWith(color: c.textSecondary),
            ),
          Text(
            'Carga: $fc${kgC != null ? "  ·  $kgC" : ""}',
            style: AppType.monoSm.copyWith(color: c.textSecondary),
          ),
          Text(
            'Descarga: $fd${kgD != null ? "  ·  $kgD" : ""}',
            style: AppType.monoSm.copyWith(color: c.textSecondary),
          ),
          if (tramo.remitoNumero != null && tramo.remitoNumero!.isNotEmpty)
            Text(
              'Remito N° ${tramo.remitoNumero}',
              style: AppType.monoSm.copyWith(color: c.textMuted),
            ),
        ],
      ),
    );
  }
}
