// lib/features/logistica/screens/logistica_liquidacion_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — liquidación de choferes en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - los streams (`LiquidacionService.streamEmpleadosCache`,
//     `streamViajesEnRango`, `AdelantosService.streamAdelantosEnRango`),
//   - los filtros (mes / empresa empleadora / chofer / estado liquidación),
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

  /// Filtro adicional: mostrar solo viajes liquidados / no liquidados / todos.
  /// Default `false` = solo no liquidados (los que el operador tiene que
  /// procesar). El operador puede toggle a "todos" o "solo liquidados"
  /// para revisar histórico.
  bool? _filtroLiquidado = false;

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
          // para TODO el personal (no solo choferes); si dejáramos
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
                filtroLiquidado: _filtroLiquidado,
                empleados: choferesFiltrados,
                onMesChanged: (m) => setState(() => _mesSeleccionado = m),
                onEmpresaChanged: (cuit) => setState(() {
                  _empresaCuit = cuit;
                  // Si cambia la empresa, resetear chofer (puede no
                  // pertenecer a la nueva empresa).
                  _choferDni = null;
                }),
                onChoferChanged: (dni) => setState(() => _choferDni = dni),
                onLiquidadoChanged: (v) =>
                    setState(() => _filtroLiquidado = v),
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
                    var viajes = viajesSnap.data!;
                    if (_filtroLiquidado != null) {
                      viajes = viajes
                          .where((v) => v.liquidado == _filtroLiquidado)
                          .toList();
                    }
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
                          onLiquidarBulk: () => _liquidarBulk(context, viajes),
                          onExportarExcel: () =>
                              ReportLiquidacionService.generar(
                            context: context,
                            viajes: viajes,
                            adelantos: adelantos,
                            empleados: empleados,
                            mes: _mesSeleccionado,
                            empresaCuit: _empresaCuit,
                            choferDniFiltro: _choferDni,
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
    // Filtrar solo los que NO están liquidados (defensivo — la query
    // ya los filtra si _filtroLiquidado == false, pero por las dudas).
    final aLiquidar = viajes.where((v) => !v.liquidado).toList();
    if (aLiquidar.isEmpty) {
      AppFeedback.info(ctx, 'No hay viajes pendientes de liquidar.');
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
  final bool? filtroLiquidado;
  final Map<String, EmpleadoLiquidacion> empleados;
  final ValueChanged<DateTime> onMesChanged;
  final ValueChanged<String?> onEmpresaChanged;
  final ValueChanged<String?> onChoferChanged;
  final ValueChanged<bool?> onLiquidadoChanged;

  const _BarraFiltros({
    required this.mes,
    required this.empresaCuit,
    required this.choferDni,
    required this.filtroLiquidado,
    required this.empleados,
    required this.onMesChanged,
    required this.onEmpresaChanged,
    required this.onChoferChanged,
    required this.onLiquidadoChanged,
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
          const SizedBox(height: AppSpacing.md),
          // Pills de estado de liquidación (mismo look que viajes lista).
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PillEstado(
                label: 'Sin liquidar',
                seleccionado: filtroLiquidado == false,
                onTap: () => onLiquidadoChanged(false),
              ),
              _PillEstado(
                label: 'Liquidados',
                seleccionado: filtroLiquidado == true,
                onTap: () => onLiquidadoChanged(true),
              ),
              _PillEstado(
                label: 'Todos',
                seleccionado: filtroLiquidado == null,
                onTap: () => onLiquidadoChanged(null),
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

/// Pill seleccionable de estado de liquidación (look del prototipo
/// Núcleo, igual que en viajes lista). Activo = tinte brand.
class _PillEstado extends StatelessWidget {
  final String label;
  final bool seleccionado;
  final VoidCallback onTap;
  const _PillEstado({
    required this.label,
    required this.seleccionado,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = seleccionado ? c.brand : c.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: seleccionado
              ? c.brand.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: seleccionado
                ? c.brand.withValues(alpha: 0.5)
                : c.borderStrong,
          ),
        ),
        child: Text(
          label,
          style: AppType.label.copyWith(color: fg, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

// ============================================================================
// CONTENIDO (KPIs + tabla por chofer / lista de viajes)
// ============================================================================

class _Contenido extends StatelessWidget {
  final List<Viaje> viajes;
  final List<AdelantoChofer> adelantos;
  final Map<String, EmpleadoLiquidacion> empleados;
  final String? choferDniFiltro;
  final VoidCallback onLiquidarBulk;
  final VoidCallback onExportarExcel;

  const _Contenido({
    required this.viajes,
    required this.adelantos,
    required this.empleados,
    required this.choferDniFiltro,
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
        subtitle: 'Probá cambiar mes / empresa / chofer / estado liquidación.',
      );
    }
    // Agregados globales sobre todos los viajes filtrados.
    final totalFacturado =
        viajes.fold<double>(0, (acc, v) => acc + v.montoVecchi);
    final totalChofer =
        viajes.fold<double>(0, (acc, v) => acc + v.montoChoferRedondeado);
    // Adelantos: solo los de la nueva colección ADELANTOS_CHOFER
    // (refactor 2026-05-13). Los adelantos legacy embedidos en el
    // viaje pre-refactor son data de testeo y NO se contabilizan
    // — Santiago decidió no migrarlos (etapa de testing).
    final totalAdelantos =
        adelantos.fold<double>(0, (acc, a) => acc + a.monto);
    final totalGastos =
        viajes.fold<double>(0, (acc, v) => acc + v.gastosTotal);
    // Neto a pagar al chofer = ganancia chofer - adelantos + gastos.
    // (Adelantos ya se le entregaron, gastos se le devuelven.)
    final netoChofer = totalChofer - totalAdelantos + totalGastos;
    final hayPendientes = viajes.any((v) => !v.liquidado);
    final cantPendientes = viajes.where((v) => !v.liquidado).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxxl),
      children: [
        _SeccionKPIs(
          totalFacturado: totalFacturado,
          totalChofer: totalChofer,
          totalAdelantos: totalAdelantos,
          totalGastos: totalGastos,
          netoChofer: netoChofer,
          cantViajes: viajes.length,
          cantAdelantos: adelantos.length,
        ),
        const SizedBox(height: AppSpacing.lg),
        if (hayPendientes) ...[
          AppButton.primary(
            label: 'Marcar $cantPendientes viaje(s) como liquidados',
            icon: Icons.check_circle_outline,
            full: true,
            onPressed: onLiquidarBulk,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        // Exportar a Excel — siempre disponible si hay datos. Útil para
        // mandar al contador, imprimir o auditar offline. 3 hojas:
        // RESUMEN por chofer, VIAJES uno por uno, ADELANTOS uno por uno.
        AppButton.secondary(
          label: 'Exportar a Excel',
          icon: Icons.file_download_outlined,
          full: true,
          onPressed: onExportarExcel,
        ),
        const SizedBox(height: AppSpacing.lg),
        // Si no hay chofer filtrado, mostrar tabla agregada por chofer.
        // Si hay chofer filtrado, mostrar lista de viajes individuales.
        if (choferDniFiltro == null)
          _TablaPorChofer(
            viajes: viajes,
            adelantos: adelantos,
            empleados: empleados,
          )
        else
          _ListaViajes(viajes: viajes, adelantos: adelantos),
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
  final double totalFacturado;
  final double totalChofer;
  final double totalAdelantos;
  final double totalGastos;
  final double netoChofer;
  final int cantViajes;
  final int cantAdelantos;

  const _SeccionKPIs({
    required this.totalFacturado,
    required this.totalChofer,
    required this.totalAdelantos,
    required this.totalGastos,
    required this.netoChofer,
    required this.cantViajes,
    required this.cantAdelantos,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    String monto(double m) => '\$ ${AppFormatters.formatearMonto(m)}';

    // Strip principal con los 3 números héroe. En ancho chico se aprieta,
    // así que partimos a 2 strips apilados bajo cierto umbral.
    final statsTop = <AppStat>[
      AppStat(
        label: 'Facturado',
        value: monto(totalFacturado),
        valueStyle: AppType.h4,
        accent: c.info,
      ),
      AppStat(
        label: 'Ganancia chofer',
        value: monto(totalChofer),
        valueStyle: AppType.h4,
        accent: c.brandSoft,
      ),
      AppStat(
        label: 'Neto a pagar',
        value: monto(netoChofer),
        valueStyle: AppType.h4,
        accent: netoChofer >= 0 ? c.success : c.error,
      ),
    ];

    return _Seccion(
      titulo: 'RESUMEN',
      accentDot: c.success,
      trailing: Text(
        '$cantViajes viaje(s) · $cantAdelantos adel.',
        style: AppType.monoSm.copyWith(color: c.textMuted),
      ),
      children: [
        LayoutBuilder(
          builder: (ctx, constraints) {
            if (constraints.maxWidth < 420) {
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
        // Desglose del neto en filas label/valor (mono). Es el detalle
        // que arma el neto — mismo orden y signo que antes.
        _LineaMonto(label: 'Facturado a empresa', valor: totalFacturado),
        _LineaMonto(
            label: 'Ganancia chofer (redondeado)', valor: totalChofer),
        _LineaMonto(
          label: 'Adelantos entregados',
          valor: -totalAdelantos,
          color: c.warning,
        ),
        _LineaMonto(
          label: 'Gastos a reembolsar',
          valor: totalGastos,
          color: c.warning,
        ),
        const SizedBox(height: AppSpacing.sm),
        const AppHairline(),
        const SizedBox(height: AppSpacing.sm),
        _LineaMonto(
          label: 'Neto a pagar al chofer',
          valor: netoChofer,
          destacado: true,
        ),
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

  const _TablaPorChofer({
    required this.viajes,
    required this.adelantos,
    required this.empleados,
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

  const _CardChofer({
    required this.nombre,
    required this.viajes,
    required this.adelantos,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final facturado = viajes.fold<double>(0, (a, v) => a + v.montoVecchi);
    final chofer =
        viajes.fold<double>(0, (a, v) => a + v.montoChoferRedondeado);
    // Solo adelantos NUEVOS (colección) — los legacy del viaje
    // son data de testeo y no se contabilizan (Santiago decidió
    // no migrar 2026-05-13).
    final adelantosTotal = adelantos.fold<double>(0, (a, ad) => a + ad.monto);
    final gastos = viajes.fold<double>(0, (a, v) => a + v.gastosTotal);
    final neto = chofer - adelantosTotal + gastos;
    final pendientes = viajes.where((v) => !v.liquidado).length;

    return AppCard(
      tier: 1,
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
              if (pendientes > 0) ...[
                const SizedBox(width: AppSpacing.sm),
                AppBadge(
                  text: '$pendientes pend.',
                  color: c.warning,
                  size: AppBadgeSize.sm,
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          // Conteos en mono muted (técnico).
          Text(
            [
              viajes.isEmpty
                  ? 'sin viajes'
                  : '${viajes.length} viaje${viajes.length == 1 ? "" : "s"}',
              if (adelantos.isNotEmpty) '${adelantos.length} adel.',
            ].join('  ·  '),
            style: AppType.monoSm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: AppSpacing.sm),
          const AppHairline(),
          const SizedBox(height: AppSpacing.sm),
          _LineaMonto(label: 'Facturado', valor: facturado),
          _LineaMonto(label: 'Ganancia chofer', valor: chofer),
          _LineaMonto(
              label: 'Adelantos', valor: -adelantosTotal, color: c.warning),
          _LineaMonto(label: 'Gastos', valor: gastos, color: c.warning),
          const SizedBox(height: AppSpacing.xs),
          const AppHairline(),
          const SizedBox(height: AppSpacing.xs),
          _LineaMonto(label: 'Neto a pagar', valor: neto, destacado: true),
        ],
      ),
    );
  }
}

// ============================================================================
// LISTA DE VIAJES (cuando hay chofer filtrado)
// ============================================================================

class _ListaViajes extends StatelessWidget {
  final List<Viaje> viajes;
  final List<AdelantoChofer> adelantos;
  const _ListaViajes({required this.viajes, required this.adelantos});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (viajes.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xs, 0, AppSpacing.xs, AppSpacing.sm),
            child: AppEyebrow('Viajes del chofer · ${viajes.length}'),
          ),
          for (final v in viajes) ...[
            _ViajeCardLiquidacion(v: v),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
        if (adelantos.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xs, 0, AppSpacing.xs, AppSpacing.sm),
            child: AppEyebrow('Adelantos del chofer · ${adelantos.length}'),
          ),
          for (final a in adelantos) ...[
            _AdelantoCardLiquidacion(a: a),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
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

/// Card de viaje en la pantalla LIQUIDACIÓN. Si el viaje es
/// multi-tramo, despliega un panel expandible con el detalle de cada
/// tramo (fecha carga, fecha descarga, kg cargados/descargados,
/// origen → destino). Si es single-tramo, se ve igual que antes.
class _ViajeCardLiquidacion extends StatefulWidget {
  final Viaje v;
  const _ViajeCardLiquidacion({required this.v});

  @override
  State<_ViajeCardLiquidacion> createState() =>
      _ViajeCardLiquidacionState();
}

class _ViajeCardLiquidacionState extends State<_ViajeCardLiquidacion> {
  bool _expandido = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final v = widget.v;
    final fecha = v.fechaReferencia != null
        ? AppFormatters.formatearFecha(v.fechaReferencia!)
        : '—';
    return AppCard(
      tier: 1,
      accent: v.liquidado ? c.success : c.warning,
      padding: const EdgeInsets.all(AppSpacing.lg),
      onTap: () => Navigator.pushNamed(
        context,
        AppRoutes.adminLogisticaViajeDetalle,
        arguments: {'viajeId': v.id},
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                fecha,
                style: AppType.mono.copyWith(
                  color: v.fechaReferencia == null ? c.textMuted : c.text,
                  fontWeight: FontWeight.w600,
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
              AppBadge(
                text: v.liquidado ? 'Liquidado' : 'Pendiente',
                color: v.liquidado ? c.success : c.warning,
                size: AppBadgeSize.sm,
                dot: !v.liquidado,
                icon: v.liquidado ? Icons.check : null,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          const AppHairline(),
          const SizedBox(height: AppSpacing.sm),
          _LineaMonto(label: 'Facturado', valor: v.montoVecchi),
          _LineaMonto(label: 'Ganancia chofer', valor: v.montoChoferRedondeado),
          // Adelantos: NO se muestran por-viaje en liquidación. Desde el
          // refactor 2026-05-13 viven en ADELANTOS_CHOFER y se restan a nivel
          // chofer/período (no por viaje). El `adelanto_monto` legacy embebido
          // era data de testing que el agregado ya ignora; mostrarlo acá
          // descuadraba la card contra los KPIs (audit 2026-06-04).
          if (v.gastosTotal > 0)
            _LineaMonto(label: 'Gastos', valor: v.gastosTotal, color: c.warning),
          const SizedBox(height: AppSpacing.xs),
          const AppHairline(),
          const SizedBox(height: AppSpacing.xs),
          // Neto del viaje = ganancia chofer (redondeada) + gastos. Para viajes
          // nuevos es idéntico a liquidacionChofer (adelanto=0); para legacy con
          // adelanto embebido evita el descuadre con el desglose visible y con
          // el neto agregado (que suma montoChoferRedondeado + gastos por viaje).
          _LineaMonto(
              label: 'Neto',
              valor: v.montoChoferRedondeado + v.gastosTotal,
              destacado: true),
          // Toggle desplegable solo si tiene más de 1 tramo.
          if (v.esMultiTramo) ...[
            const SizedBox(height: AppSpacing.sm),
            InkWell(
              onTap: () => setState(() => _expandido = !_expandido),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _expandido
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: c.textMuted,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      _expandido
                          ? 'Ocultar tramos'
                          : 'Ver detalle de ${v.cantidadTramos} tramos',
                      style: AppType.eyebrow.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ),
            if (_expandido)
              for (var i = 0; i < v.tramos.length; i++)
                _DetalleTramoLiquidacion(numero: i + 1, tramo: v.tramos[i]),
          ],
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
