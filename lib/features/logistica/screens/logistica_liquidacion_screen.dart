import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/viaje.dart';
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
                    return _Contenido(
                      viajes: viajes,
                      empleados: empleados,
                      choferDniFiltro: _choferDni,
                      onLiquidarBulk: () => _liquidarBulk(context, viajes),
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
      confirmLabel: 'LIQUIDAR',
    );
    if (confirmar != true) return;
    final dni = PrefsService.dni;
    try {
      final n = await LiquidacionService.marcarLiquidadosBulk(
        viajeIds: aLiquidar.map((v) => v.id).toList(),
        liquidadoPorDni: dni,
      );
      AppFeedback.successOn(messenger, '$n viaje(s) marcado(s) como liquidado(s).');
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error al liquidar: $e');
    }
  }
}

// ============================================================================
// BARRA DE FILTROS (mes + empresa + chofer + liquidado)
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
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fila 1: mes (con flechas) + empresa
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 20),
                tooltip: 'Mes anterior',
                onPressed: () {
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
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                tooltip: 'Mes siguiente',
                onPressed: () {
                  final m = mes.month;
                  final y = mes.year;
                  onMesChanged(
                      m == 12 ? DateTime(y + 1, 1, 1) : DateTime(y, m + 1, 1));
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Fila 2: empresa empleadora dropdown
          DropdownButtonFormField<String?>(
            initialValue: empresaCuit,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Empresa empleadora del chofer',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('TODAS', overflow: TextOverflow.ellipsis),
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
          const SizedBox(height: 8),
          // Fila 3: chofer dropdown (filtrado por empresa si aplica)
          DropdownButtonFormField<String?>(
            initialValue: choferDni,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Chofer',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('TODOS', overflow: TextOverflow.ellipsis),
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
          const SizedBox(height: 8),
          // Fila 4: chips estado liquidación
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _ChipFiltro(
                  label: 'No liquidados',
                  selected: filtroLiquidado == false,
                  onTap: () => onLiquidadoChanged(false),
                ),
                const SizedBox(width: 6),
                _ChipFiltro(
                  label: 'Liquidados',
                  selected: filtroLiquidado == true,
                  onTap: () => onLiquidadoChanged(true),
                ),
                const SizedBox(width: 6),
                _ChipFiltro(
                  label: 'Todos',
                  selected: filtroLiquidado == null,
                  onTap: () => onLiquidadoChanged(null),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipFiltro extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChipFiltro({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      labelStyle: TextStyle(
        color: selected ? Colors.black : Colors.white70,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      selectedColor: AppColors.accentGreen,
      backgroundColor: AppColors.background,
    );
  }
}

// ============================================================================
// CONTENIDO (KPIs + tabla por chofer / lista de viajes)
// ============================================================================

class _Contenido extends StatelessWidget {
  final List<Viaje> viajes;
  final Map<String, EmpleadoLiquidacion> empleados;
  final String? choferDniFiltro;
  final VoidCallback onLiquidarBulk;

  const _Contenido({
    required this.viajes,
    required this.empleados,
    required this.choferDniFiltro,
    required this.onLiquidarBulk,
  });

  @override
  Widget build(BuildContext context) {
    if (viajes.isEmpty) {
      return const AppEmptyState(
        icon: Icons.inbox_outlined,
        title: 'Sin viajes en el período',
        subtitle: 'Probá cambiar mes / empresa / chofer / estado liquidación.',
      );
    }
    // Agregados globales sobre todos los viajes filtrados.
    final totalFacturado =
        viajes.fold<double>(0, (acc, v) => acc + v.montoVecchi);
    final totalChofer =
        viajes.fold<double>(0, (acc, v) => acc + v.montoChoferRedondeado);
    final totalAdelantos =
        viajes.fold<double>(0, (acc, v) => acc + (v.adelantoMonto ?? 0));
    final totalGastos =
        viajes.fold<double>(0, (acc, v) => acc + v.gastosTotal);
    // Neto a pagar al chofer = ganancia chofer - adelantos + gastos.
    // (Adelantos ya se le entregaron, gastos se le devuelven.)
    final netoChofer = totalChofer - totalAdelantos + totalGastos;
    final hayPendientes = viajes.any((v) => !v.liquidado);

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
      children: [
        _SeccionKPIs(
          totalFacturado: totalFacturado,
          totalChofer: totalChofer,
          totalAdelantos: totalAdelantos,
          totalGastos: totalGastos,
          netoChofer: netoChofer,
          cantViajes: viajes.length,
        ),
        const SizedBox(height: 16),
        if (hayPendientes)
          ElevatedButton.icon(
            onPressed: onLiquidarBulk,
            icon: const Icon(Icons.check_circle_outline),
            label: Text(
                'MARCAR ${viajes.where((v) => !v.liquidado).length} VIAJE(S) COMO LIQUIDADOS'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentGreen,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              textStyle: const TextStyle(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ),
        if (hayPendientes) const SizedBox(height: 16),
        // Si no hay chofer filtrado, mostrar tabla agregada por chofer.
        // Si hay chofer filtrado, mostrar lista de viajes individuales.
        if (choferDniFiltro == null)
          _TablaPorChofer(viajes: viajes, empleados: empleados)
        else
          _ListaViajes(viajes: viajes),
      ],
    );
  }
}

// ============================================================================
// KPIs grandes
// ============================================================================

class _SeccionKPIs extends StatelessWidget {
  final double totalFacturado;
  final double totalChofer;
  final double totalAdelantos;
  final double totalGastos;
  final double netoChofer;
  final int cantViajes;

  const _SeccionKPIs({
    required this.totalFacturado,
    required this.totalChofer,
    required this.totalAdelantos,
    required this.totalGastos,
    required this.netoChofer,
    required this.cantViajes,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet,
                  size: 20, color: AppColors.accentGreen),
              const SizedBox(width: 8),
              Text(
                'Resumen — $cantViajes viaje(s)',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _LineaKPI(
            label: 'Facturado a empresa',
            valor: totalFacturado,
            color: AppColors.accentBlue,
          ),
          _LineaKPI(
            label: 'Ganancia chofer (redondeado)',
            valor: totalChofer,
            color: AppColors.accentTeal,
          ),
          _LineaKPI(
            label: 'Adelantos entregados',
            valor: -totalAdelantos,
            color: AppColors.accentOrange,
          ),
          _LineaKPI(
            label: 'Gastos a reembolsar',
            valor: totalGastos,
            color: AppColors.accentAmber,
          ),
          const Divider(color: Colors.white24, height: 24),
          _LineaKPI(
            label: 'NETO a pagar al chofer',
            valor: netoChofer,
            color:
                netoChofer >= 0 ? AppColors.accentGreen : AppColors.accentRed,
            destacado: true,
          ),
        ],
      ),
    );
  }
}

class _LineaKPI extends StatelessWidget {
  final String label;
  final double valor;
  final Color color;
  final bool destacado;
  const _LineaKPI({
    required this.label,
    required this.valor,
    required this.color,
    this.destacado = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: destacado ? Colors.white : Colors.white70,
                fontSize: destacado ? 14 : 13,
                fontWeight: destacado ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Text(
            '\$${AppFormatters.formatearMonto(valor)}',
            style: TextStyle(
              color: color,
              fontSize: destacado ? 18 : 15,
              fontWeight: FontWeight.bold,
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
  final Map<String, EmpleadoLiquidacion> empleados;

  const _TablaPorChofer({required this.viajes, required this.empleados});

  @override
  Widget build(BuildContext context) {
    // Agrupar viajes por chofer DNI.
    final porChofer = <String, List<Viaje>>{};
    for (final v in viajes) {
      porChofer.putIfAbsent(v.choferDni, () => []).add(v);
    }
    // Orden por nombre del chofer.
    final entries = porChofer.entries.toList()
      ..sort((a, b) {
        final na = empleados[a.key]?.nombre ?? a.key;
        final nb = empleados[b.key]?.nombre ?? b.key;
        return na.compareTo(nb);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Text(
            'POR CHOFER',
            style: TextStyle(
              color: Colors.white60,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
        ),
        ...entries.map((e) {
          final dni = e.key;
          final vs = e.value;
          final nombre = empleados[dni]?.nombre ?? 'DNI $dni';
          final facturado = vs.fold<double>(0, (a, v) => a + v.montoVecchi);
          final chofer =
              vs.fold<double>(0, (a, v) => a + v.montoChoferRedondeado);
          final adelantos =
              vs.fold<double>(0, (a, v) => a + (v.adelantoMonto ?? 0));
          final gastos = vs.fold<double>(0, (a, v) => a + v.gastosTotal);
          final neto = chofer - adelantos + gastos;
          final pendientes = vs.where((v) => !v.liquidado).length;
          return AppCard(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            margin: const EdgeInsets.only(bottom: 8),
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      '${vs.length} viaje${vs.length == 1 ? "" : "s"}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                    if (pendientes > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.accentOrange.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: AppColors.accentOrange, width: 0.6),
                        ),
                        child: Text(
                          '$pendientes pend.',
                          style: const TextStyle(
                            color: AppColors.accentOrange,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                _MiniCelda(label: 'Facturado', valor: facturado),
                _MiniCelda(label: 'Ganancia chofer', valor: chofer),
                _MiniCelda(label: 'Adelantos', valor: -adelantos),
                _MiniCelda(label: 'Gastos', valor: gastos),
                const Divider(color: Colors.white12, height: 12),
                _MiniCelda(
                    label: 'Neto a pagar', valor: neto, destacado: true),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _MiniCelda extends StatelessWidget {
  final String label;
  final double valor;
  final bool destacado;
  const _MiniCelda({
    required this.label,
    required this.valor,
    this.destacado = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: destacado ? Colors.white : Colors.white60,
                fontSize: 11,
                fontWeight: destacado ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Text(
            '\$${AppFormatters.formatearMonto(valor)}',
            style: TextStyle(
              color: destacado
                  ? (valor >= 0
                      ? AppColors.accentGreen
                      : AppColors.accentRed)
                  : Colors.white,
              fontSize: destacado ? 13 : 12,
              fontWeight: FontWeight.w600,
            ),
          ),
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
  const _ListaViajes({required this.viajes});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Text(
            'VIAJES DEL CHOFER',
            style: TextStyle(
              color: Colors.white60,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
        ),
        ...viajes.map((v) => _ViajeCardLiquidacion(v: v)),
      ],
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
    final v = widget.v;
    final fecha = v.fechaReferencia != null
        ? AppFormatters.formatearFecha(v.fechaReferencia!)
        : '—';
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      margin: const EdgeInsets.only(bottom: 8),
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
              Expanded(
                child: Text(
                  '$fecha · ${v.rutaEtiqueta}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              if (v.liquidado)
                const Icon(Icons.check_circle,
                    size: 14, color: AppColors.accentGreen)
              else
                const Icon(Icons.schedule,
                    size: 14, color: AppColors.accentOrange),
            ],
          ),
          const SizedBox(height: 4),
          _MiniCelda(label: 'Facturado', valor: v.montoVecchi),
          _MiniCelda(
              label: 'Ganancia chofer', valor: v.montoChoferRedondeado),
          if ((v.adelantoMonto ?? 0) > 0)
            _MiniCelda(label: 'Adelanto', valor: -(v.adelantoMonto ?? 0)),
          if (v.gastosTotal > 0)
            _MiniCelda(label: 'Gastos', valor: v.gastosTotal),
          const Divider(color: Colors.white12, height: 12),
          _MiniCelda(
            label: 'Neto',
            valor: v.liquidacionChofer,
            destacado: true,
          ),
          // Toggle desplegable solo si tiene más de 1 tramo.
          if (v.esMultiTramo) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () => setState(() => _expandido = !_expandido),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _expandido
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _expandido
                        ? 'Ocultar tramos'
                        : 'Ver detalle de ${v.cantidadTramos} tramos',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (_expandido) ...[
              const SizedBox(height: 6),
              ...v.tramos.asMap().entries.map((entry) {
                final i = entry.key;
                final t = entry.value;
                return _DetalleTramoLiquidacion(numero: i + 1, tramo: t);
              }),
            ],
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
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TRAMO $numero · ${ts.origenEtiqueta} → ${ts.destinoEtiqueta}',
            style: const TextStyle(
              color: AppColors.accentBlue,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          if (tramo.producto != null && tramo.producto!.isNotEmpty)
            Text(
              tramo.producto!,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          Text(
            'Carga: $fc${kgC != null ? "  ·  $kgC" : ""}',
            style: const TextStyle(color: Colors.white60, fontSize: 11),
          ),
          Text(
            'Descarga: $fd${kgD != null ? "  ·  $kgD" : ""}',
            style: const TextStyle(color: Colors.white60, fontSize: 11),
          ),
          if (tramo.remitoNumero != null && tramo.remitoNumero!.isNotEmpty)
            Text(
              'Remito Nº ${tramo.remitoNumero}',
              style: const TextStyle(color: Colors.white54, fontSize: 10),
            ),
        ],
      ),
    );
  }
}

