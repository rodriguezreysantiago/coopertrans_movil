import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/adelanto_chofer.dart';
import '../models/viaje.dart';
import '../utils/calculos_viaje.dart';
import '../services/adelantos_service.dart';
import '../services/viajes_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Detalle read-only de un viaje. Vista resumida para consulta rápida
/// — el operador entra acá desde la lista para revisar antes de
/// liquidar o editar.
///
/// Acciones disponibles:
///   - Editar (navega al form con el viajeId).
///   - Marcar/desmarcar liquidado (toggle).
///   - Borrar (soft-delete con motivo).
///   - Reactivar (si está borrado).
class LogisticaViajeDetalleScreen extends StatelessWidget {
  final String viajeId;

  const LogisticaViajeDetalleScreen({super.key, required this.viajeId});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Detalle del viaje',
      body: StreamBuilder<Viaje?>(
        stream: ViajesService.streamViaje(viajeId),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AppErrorState(
              title: 'No se pudo cargar el viaje',
              subtitle: snap.error.toString(),
            );
          }
          if (snap.connectionState == ConnectionState.waiting) {
            return const AppSkeletonList(count: 5, conAvatar: false);
          }
          final v = snap.data;
          if (v == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.xxl),
                child: Text(
                  'Viaje no encontrado.',
                  style: TextStyle(color: Colors.white60),
                ),
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Cabecera(v: v),
                const SizedBox(height: AppSpacing.sm),
                // Botonera ARRIBA — Santiago 2026-05-14: que las
                // acciones EDITAR/BORRAR estén accesibles sin scroll.
                // Antes vivían al final de la columna, después de
                // tramos+gastos+montos = el operador tenía que bajar
                // toda la pantalla para borrar/editar.
                _BotoneraAcciones(v: v),
                const SizedBox(height: AppSpacing.md),
                _SeccionAsignacion(v: v),
                const SizedBox(height: AppSpacing.md),
                _SeccionAdelantoAsociado(viajeId: v.id),
                const SizedBox(height: AppSpacing.md),
                _SeccionTramos(v: v),
                const SizedBox(height: AppSpacing.md),
                _SeccionMontos(v: v),
                // Sección "GASTOS EXTRAORDINARIOS" viaje-level
                // eliminada el 2026-05-13. Los gastos ahora se muestran
                // DENTRO de cada tramo (en `_DetalleTramo`) con su
                // propio total. El gran total sigue apareciendo en
                // `_SeccionMontos` (línea "Gastos extraordinarios").
                if (v.motivoCancelacion != null ||
                    v.fechaPostergadoA != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _SeccionMotivo(v: v),
                ],
                if (!v.activo) ...[
                  const SizedBox(height: AppSpacing.md),
                  _SeccionBorrado(v: v),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

// =============================================================================
// SECCIONES
// =============================================================================

class _Cabecera extends StatelessWidget {
  final Viaje v;
  const _Cabecera({required this.v});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'VIAJE',
                style: AppType.eyebrow.copyWith(color: Colors.white60, letterSpacing: 1.4, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              _ChipEstado(estado: v.estado),
              if (v.liquidado) ...[
                const SizedBox(width: 6),
                const _Chip(
                  label: 'LIQUIDADO',
                  color: AppColors.success,
                  icono: Icons.check,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            v.cargaTransportada?.isNotEmpty == true
                ? v.cargaTransportada!
                : 'Sin descripción de carga',
            style: AppType.heading.copyWith(color: v.cargaTransportada?.isNotEmpty == true
                  ? Colors.white
                  : Colors.white38, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          Text(
            'ID: ${v.id}',
            style: AppType.eyebrow.copyWith(color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

/// Sección que muestra los tramos del viaje en formato lista. Si el
/// viaje es single-tramo, muestra 1 tramo (igual de claro que antes).
/// Si es multi-tramo, lista cada uno con su tarifa, fechas, kg y
/// remito propios.
class _SeccionTramos extends StatelessWidget {
  final Viaje v;
  const _SeccionTramos({required this.v});

  @override
  Widget build(BuildContext context) {
    return _Seccion(
      titulo: v.esMultiTramo
          ? 'TRAMOS (${v.cantidadTramos})'
          : 'RUTA Y CARGA',
      icono: Icons.alt_route,
      children: [
        ...v.tramos.asMap().entries.map((entry) {
          final i = entry.key;
          final t = entry.value;
          return Padding(
            padding: EdgeInsets.only(
              top: i == 0 ? 0 : 12,
              bottom: i == v.tramos.length - 1 ? 0 : 0,
            ),
            child: _DetalleTramo(
              numero: v.esMultiTramo ? i + 1 : null,
              tramo: t,
              comisionPct: v.comisionChoferPct,
            ),
          );
        }),
      ],
    );
  }
}

class _DetalleTramo extends StatelessWidget {
  final int? numero;
  final TramoViaje tramo;
  /// Porcentaje de comisión del chofer (típicamente 18) que viene del
  /// viaje. Lo necesitamos para mostrar la comisión del chofer DE ESTE
  /// TRAMO (18 % sobre la base bruta del tramo). Antes el detalle solo
  /// mostraba la tarifa $/TN; ahora pidió Santiago ver Vecchi total +
  /// chofer base + comisión chofer por tramo (la suma de todos los
  /// tramos queda en MONTOS Y LIQUIDACIÓN abajo).
  final double comisionPct;

  const _DetalleTramo({
    required this.numero,
    required this.tramo,
    required this.comisionPct,
  });

  @override
  Widget build(BuildContext context) {
    final ts = tramo.tarifaSnapshot;
    // Cálculos del tramo. Reusamos el mismo helper que la pantalla
    // LIQUIDACIÓN para garantizar consistencia (POR_VIAJE devuelve la
    // tarifa fija; POR_TONELADA aplica `tarifa × TN` con prioridad a
    // kg DESCARGADOS, fallback a kg cargados).
    final brutos = CalculosViaje.calcularMontosBrutos(
      unidadTarifa: ts.unidadTarifa,
      tarifaReal: ts.tarifaReal,
      tarifaChofer: ts.tarifaChofer,
      kgCargados: tramo.kgCargados,
      kgDescargados: tramo.kgDescargados,
    );
    // Monto chofer del tramo: si la tarifa tiene `montoFijoChofer`,
    // ese monto es lo que cobra el chofer (sin pct). Sino, aplicamos
    // el porcentaje sobre la tarifa chofer base.
    final montoFijoChofer = ts.montoFijoChofer;
    final double comisionChoferTramo;
    final bool esMontoFijo;
    if (montoFijoChofer != null) {
      comisionChoferTramo = montoFijoChofer;
      esMontoFijo = true;
    } else {
      comisionChoferTramo = brutos.montoChofer * (comisionPct / 100.0);
      esMontoFijo = false;
    }
    // Redondeo POR TRAMO al múltiplo de 5 descendente (Santiago
    // 2026-05-19). La suma de redondeados es el monto del chofer del
    // viaje (mismo número que `montoChoferRedondeado` en LIQUIDACION).
    final comisionChoferTramoRedondeada =
        CalculosViaje.redondearMultiploDe5Descendente(comisionChoferTramo);
    final hayMontos =
        brutos.montoVecchi > 0 || brutos.montoChofer > 0 || esMontoFijo;
    return Container(
      decoration: numero == null
          ? null
          : BoxDecoration(
              border: Border.all(color: Colors.white12),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
      padding: numero == null ? EdgeInsets.zero : const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (numero != null) ...[
            Text(
              'TRAMO $numero',
              style: AppType.body.copyWith(color: AppColors.info, fontWeight: FontWeight.bold, letterSpacing: 1.2),
            ),
            const SizedBox(height: 6),
          ],
          _Linea(label: 'Origen', valor: ts.origenDisplay),
          _Linea(label: 'Destino', valor: ts.destinoDisplay),
          if (tramo.producto != null && tramo.producto!.isNotEmpty)
            _Linea(label: 'Producto', valor: tramo.producto!)
          else if (ts.producto != null && ts.producto!.isNotEmpty)
            _Linea(label: 'Producto', valor: ts.producto!),
          if (tramo.descripcionCarga != null &&
              tramo.descripcionCarga!.isNotEmpty)
            _Linea(label: 'Observación', valor: tramo.descripcionCarga!),
          _Linea(
            label: 'Modalidad',
            valor: '${ts.unidadTarifa.etiqueta} · '
                '\$${AppFormatters.formatearMonto(ts.tarifaReal)}'
                '${ts.unidadTarifa.sufijoMonto} (Vecchi) · '
                '\$${AppFormatters.formatearMonto(ts.tarifaChofer)}'
                '${ts.unidadTarifa.sufijoMonto} (chofer)',
          ),
          _Linea(
            label: 'Fecha carga',
            valor: tramo.fechaCarga == null
                ? '—'
                : AppFormatters.formatearFechaHoraSinSegundos(
                    tramo.fechaCarga),
          ),
          if (tramo.kgCargados != null)
            _Linea(
              label: 'Kg cargados',
              valor:
                  '${AppFormatters.formatearMiles(tramo.kgCargados!.toInt())} kg',
            ),
          _Linea(
            label: 'Fecha descarga',
            valor: tramo.fechaDescarga == null
                ? '—'
                : AppFormatters.formatearFechaHoraSinSegundos(
                    tramo.fechaDescarga),
          ),
          if (tramo.kgDescargados != null)
            _Linea(
              label: 'Kg descargados',
              valor:
                  '${AppFormatters.formatearMiles(tramo.kgDescargados!.toInt())} kg',
            ),
          if (tramo.remitoNumero != null && tramo.remitoNumero!.isNotEmpty)
            _Linea(label: 'Remito Nº', valor: tramo.remitoNumero!),
          if (tramo.remitoUrl != null && tramo.remitoUrl!.isNotEmpty)
            _LineaLink(
              label: 'Comprobante',
              url: tramo.remitoUrl!,
              etiqueta: 'Abrir comprobante',
            ),
          // Gastos extraordinarios del tramo + total del tramo
          // (refactor 2026-05-13 — antes vivían al nivel viaje).
          if (tramo.gastos.isNotEmpty) ...[
            const Divider(color: Colors.white12, height: 16),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'GASTOS EXTRAORDINARIOS',
                style: AppType.label.copyWith(color: Colors.white60, fontWeight: FontWeight.bold, letterSpacing: 1.2),
              ),
            ),
            for (final g in tramo.gastos)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    const Icon(Icons.add_circle_outline,
                        size: 16, color: AppColors.brandSoft),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        g.detalle?.isNotEmpty == true
                            ? '${g.detalle} (${AppFormatters.formatearFecha(g.fecha)})'
                            : 'Gasto del ${AppFormatters.formatearFecha(g.fecha)}',
                        style: AppType.body.copyWith(color: Colors.white70),
                      ),
                    ),
                    Text(
                      '\$ ${AppFormatters.formatearMonto(g.monto)}',
                      style: AppType.body.copyWith(color: AppColors.brandSoft, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 2),
            _Linea(
              label: 'Total gastos del tramo',
              valor: '\$ ${AppFormatters.formatearMonto(tramo.gastosTotal)}',
              highlight: true,
            ),
          ],
          // Montos calculados del tramo. Solo aparecen si hay base —
          // tramo sin kg ni en POR_VIAJE definido devuelve 0 y no
          // tiene sentido mostrar líneas de $ 0.
          if (hayMontos) ...[
            const Divider(color: Colors.white12, height: 16),
            _Linea(
              label: 'Tarifa Vecchi (factura)',
              valor: '\$ ${AppFormatters.formatearMonto(brutos.montoVecchi)}',
            ),
            if (esMontoFijo) ...[
              // Tramo con monto fijo del chofer (no aplica 18%).
              _Linea(
                label: 'Tarifa chofer (base, referencia)',
                valor:
                    '\$ ${AppFormatters.formatearMonto(brutos.montoChofer)}',
                sub: true,
              ),
              _Linea(
                label: 'Monto chofer del tramo (fijo, redondeado)',
                valor:
                    '\$ ${AppFormatters.formatearMonto(comisionChoferTramoRedondeada)}',
                highlight: true,
              ),
            ] else ...[
              _Linea(
                label: 'Tarifa chofer (base)',
                valor:
                    '\$ ${AppFormatters.formatearMonto(brutos.montoChofer)}',
                sub: true,
              ),
              // Bruto sin redondear (informativo, sub-línea).
              _Linea(
                label:
                    'Comisión chofer (${comisionPct.toStringAsFixed(0)}%, bruto)',
                valor:
                    '\$ ${AppFormatters.formatearMonto(comisionChoferTramo)}',
                sub: true,
              ),
              // ESTE es el monto que efectivamente cobra el chofer
              // por el tramo — múltiplo de 5 descendente. La suma de
              // estos por tramo = `monto_chofer_redondeado` del viaje.
              _Linea(
                label: 'Comisión chofer redondeada (múltiplo de 5)',
                valor:
                    '\$ ${AppFormatters.formatearMonto(comisionChoferTramoRedondeada)}',
                highlight: true,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Bloque que muestra el adelanto asociado al viaje (si hay uno).
/// Lectura via `AdelantosService.getPorViaje` — una vez al construir,
/// no es stream porque la asociación cambia poco. Si no hay adelanto
/// asociado, el bloque se colapsa (`SizedBox.shrink`).
class _SeccionAdelantoAsociado extends StatelessWidget {
  final String viajeId;
  const _SeccionAdelantoAsociado({required this.viajeId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AdelantoChofer?>(
      future: AdelantosService.getPorViaje(viajeId),
      builder: (ctx, snap) {
        final a = snap.data;
        if (a == null) return const SizedBox.shrink();
        final fechaFmt = AppFormatters.formatearFecha(a.fecha);
        final montoFmt = AppFormatters.formatearMonto(a.monto);
        final medio = a.medioPago.etiqueta;
        return _Seccion(
          titulo: 'ADELANTO ASOCIADO',
          icono: Icons.payments_outlined,
          iconColor: AppColors.info,
          children: [
            _Linea(label: 'Fecha', valor: fechaFmt),
            _Linea(label: 'Monto', valor: '\$ $montoFmt'),
            _Linea(label: 'Medio de pago', valor: medio),
            if (a.observacion != null && a.observacion!.trim().isNotEmpty)
              _Linea(label: 'Observación', valor: a.observacion!),
            if (a.numeroRecibo != null)
              _Linea(
                label: 'Recibo N°',
                valor: a.numeroRecibo!.toString().padLeft(6, '0'),
              ),
          ],
        );
      },
    );
  }
}

class _SeccionAsignacion extends StatelessWidget {
  final Viaje v;
  const _SeccionAsignacion({required this.v});

  @override
  Widget build(BuildContext context) {
    return _Seccion(
      titulo: 'ASIGNACIÓN',
      icono: Icons.person_outline,
      children: [
        _Linea(
          label: 'Chofer',
          valor: v.choferNombre?.isNotEmpty == true
              ? '${v.choferNombre} (DNI ${v.choferDni})'
              : 'DNI ${v.choferDni}',
        ),
        if (v.vehiculoId != null && v.vehiculoId!.isNotEmpty)
          _Linea(label: 'Tractor', valor: v.vehiculoId!),
        if (v.engancheId != null && v.engancheId!.isNotEmpty)
          _Linea(label: 'Enganche', valor: v.engancheId!),
      ],
    );
  }
}

class _SeccionMontos extends StatelessWidget {
  final Viaje v;
  const _SeccionMontos({required this.v});

  @override
  Widget build(BuildContext context) {
    final diferenciaRedondeo = v.montoChofer - v.montoChoferRedondeado;
    return _Seccion(
      titulo: 'MONTOS Y LIQUIDACIÓN',
      icono: Icons.calculate_outlined,
      iconColor: AppColors.success,
      children: [
        _Linea(
          label: 'Monto Vecchi (factura)',
          valor: '\$ ${AppFormatters.formatearMonto(v.montoVecchi)}',
        ),
        _Linea(
          label:
              'Comisión chofer (${v.comisionChoferPct.toStringAsFixed(0)}% s/ tarifa chofer)',
          valor: '\$ ${AppFormatters.formatearMonto(v.montoChofer)}',
        ),
        _Linea(
          label: 'Comisión chofer redondeada',
          valor: '\$ ${AppFormatters.formatearMonto(v.montoChoferRedondeado)}',
          highlight: true,
        ),
        if (diferenciaRedondeo > 0.01)
          _Linea(
            label: '  Redondeo aplicado',
            valor: '−\$ ${AppFormatters.formatearMonto(diferenciaRedondeo)}',
            sub: true,
          ),
        const Divider(height: 16),
        _Linea(
          label: 'Gastos extraordinarios',
          valor: v.gastosTotal == 0
              ? '—'
              : '+\$ ${AppFormatters.formatearMonto(v.gastosTotal)}',
        ),
        const Divider(height: 16),
        _Linea(
          label: 'SUBTOTAL CHOFER (sin adelantos)',
          valor: '\$ ${AppFormatters.formatearMonto(v.liquidacionChofer)}',
          highlight: true,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Los adelantos se restan en LIQUIDACIÓN sumando los '
            'del chofer en el rango. Acá solo se muestra lo que '
            'genera el viaje en sí.',
            style: AppType.eyebrow.copyWith(color: Colors.white38),
          ),
        ),
      ],
    );
  }
}

// `_SeccionGastos` viaje-level removida el 2026-05-13 — los gastos
// se muestran por tramo dentro de `_DetalleTramo`. Mantener el gran
// total en `_SeccionMontos` (línea "Gastos extraordinarios"). Si
// algún flow futuro quiere una vista consolidada, podemos reagregar
// la sección leyendo `v.gastos` (que ahora es la concat de tramos).

class _SeccionMotivo extends StatelessWidget {
  final Viaje v;
  const _SeccionMotivo({required this.v});

  @override
  Widget build(BuildContext context) {
    // Compat retro 2026-05-14: los estados CANCELADO y POSTERGADO se
    // removieron del enum, pero un viaje viejo puede tener motivo o
    // fecha de postergación persistidos. Si están, los mostramos
    // bajo "DATOS DE ESTADOS LEGACY" (no inferimos del estado actual,
    // que ahora siempre es planeado/enCurso/concluido).
    return _Seccion(
      titulo: 'DATOS LEGACY',
      icono: Icons.warning_amber_outlined,
      iconColor: AppColors.warning,
      children: [
        if (v.motivoCancelacion != null && v.motivoCancelacion!.isNotEmpty)
          Text(
            v.motivoCancelacion!,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        if (v.fechaPostergadoA != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _Linea(
              label: 'Reprogramado a',
              valor: AppFormatters.formatearFecha(v.fechaPostergadoA),
            ),
          ),
      ],
    );
  }
}

class _SeccionBorrado extends StatelessWidget {
  final Viaje v;
  const _SeccionBorrado({required this.v});

  @override
  Widget build(BuildContext context) {
    return _Seccion(
      titulo: 'VIAJE BORRADO (SOFT-DELETE)',
      icono: Icons.delete_outline,
      iconColor: AppColors.error,
      children: [
        if (v.borradoEn != null)
          _Linea(
            label: 'Borrado el',
            valor: AppFormatters.formatearFechaHoraSinSegundos(v.borradoEn),
          ),
        if (v.borradoPorDni != null)
          _Linea(label: 'Borrado por', valor: 'DNI ${v.borradoPorDni}'),
        if (v.motivoBorrado != null && v.motivoBorrado!.isNotEmpty)
          _Linea(label: 'Motivo', valor: v.motivoBorrado!),
      ],
    );
  }
}

// =============================================================================
// BOTONERA DE ACCIONES
// =============================================================================

class _BotoneraAcciones extends StatelessWidget {
  final Viaje v;
  const _BotoneraAcciones({required this.v});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        ElevatedButton.icon(
          onPressed: () => Navigator.pushNamed(
            context,
            AppRoutes.adminLogisticaViajeForm,
            arguments: {'viajeId': v.id},
          ),
          icon: const Icon(Icons.edit, size: 18),
          label: const Text('EDITAR'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.info,
            foregroundColor: Colors.white,
          ),
        ),
        if (v.activo) ...[
          // Botón "MARCAR/DESMARCAR LIQUIDADO" eliminado 2026-05-11.
          // La liquidación ahora se hace en bulk desde la pantalla
          // LIQUIDACIÓN (filtros mes + empresa empleadora del chofer).
          // El flag `liquidado` del viaje SE MANTIENE en el modelo y
          // se sigue mostrando en el chip de cabecera — solo cambió
          // el lugar donde se setea (de individual aquí a masivo allá).
          OutlinedButton.icon(
            onPressed: () => _confirmarBorrar(context, v),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('BORRAR'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              side: const BorderSide(color: AppColors.error),
            ),
          ),
        ] else ...[
          OutlinedButton.icon(
            onPressed: () => _reactivar(context, v),
            icon: const Icon(Icons.restore, size: 18),
            label: const Text('REACTIVAR'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.warning,
              side: const BorderSide(color: AppColors.warning),
            ),
          ),
          // Eliminar DEFINITIVO: solo aparece cuando el viaje ya está
          // soft-deleted (activo=false). Etapa de testing: limpia
          // viajes de prueba sin dejar rastro. Doble confirmación
          // (soft primero, hard después) previene borrados
          // accidentales.
          OutlinedButton.icon(
            onPressed: () => _confirmarEliminarDefinitivo(context, v),
            icon: const Icon(Icons.delete_forever, size: 18),
            label: const Text('ELIMINAR DEFINITIVO'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              side: const BorderSide(color: AppColors.error),
            ),
          ),
        ],
      ],
    );
  }

  /// Confirmación de hard-delete. Single dialog (sin tipear ELIMINAR).
  /// Decisión Santiago 2026-05-14: bastaba con UN clic de
  /// confirmación, el tipeo de "ELIMINAR" era fricción de etapa
  /// testing que ya no aporta.
  Future<void> _confirmarEliminarDefinitivo(BuildContext ctx, Viaje v) async {
    final messenger = ScaffoldMessenger.of(ctx);
    final navigator = Navigator.of(ctx);
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(dCtx).colorScheme.surface,
        title: const Text('¿Eliminar definitivamente?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Vas a borrar este viaje POR COMPLETO de la base. No '
              'queda en histórico, no se puede reactivar, los '
              'comprobantes de remito también se borran de Storage.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Chofer: ${v.choferNombre ?? v.choferDni}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Ruta: ${v.rutaEtiqueta}',
              style: const TextStyle(color: Colors.white60),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('CANCELAR'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dCtx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            child: const Text('ELIMINAR DEFINITIVO'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!ctx.mounted) return;
    try {
      await ViajesService.eliminarViajeDefinitivo(v.id);
      AppFeedback.successOn(messenger, 'Viaje eliminado definitivamente.');
      navigator.pop();
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo eliminar el viaje. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  // _toggleLiquidado() eliminado 2026-05-11 junto con el botón
  // individual de liquidar. La acción ahora se hace en bulk desde
  // la pantalla LIQUIDACIÓN. Los métodos
  // `ViajesService.marcarLiquidado` y `desmarcarLiquidado` siguen
  // existiendo (los usa la pantalla nueva) — solo se removió el
  // call site individual de acá.

  Future<void> _confirmarBorrar(BuildContext ctx, Viaje v) async {
    final motivoCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        title: const Text('Borrar viaje'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'El viaje queda como borrado pero la información se '
              'mantiene para auditoría. Podés reactivarlo después.',
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: motivoCtrl,
              decoration: const InputDecoration(
                labelText: 'Motivo (opcional)',
                hintText: 'Ej. cancelado por cliente',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dCtx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('BORRAR'),
          ),
        ],
      ),
    );
    if (ok != true) {
      motivoCtrl.dispose();
      return;
    }
    final motivoTxt = motivoCtrl.text.trim();
    motivoCtrl.dispose();
    if (!ctx.mounted) return;
    final messenger = ScaffoldMessenger.of(ctx);
    final navigator = Navigator.of(ctx);
    try {
      await ViajesService.borrarViaje(
        viajeId: v.id,
        borradoPorDni: PrefsService.dni,
        motivo: motivoTxt.isEmpty ? null : motivoTxt,
      );
      AppFeedback.successOn(messenger, 'Viaje borrado.');
      navigator.pop();
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo borrar el viaje. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  Future<void> _reactivar(BuildContext ctx, Viaje v) async {
    final messenger = ScaffoldMessenger.of(ctx);
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

// =============================================================================
// PRIMITIVAS DE UI
// =============================================================================

class _Seccion extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final Color? iconColor;
  final List<Widget> children;

  const _Seccion({
    required this.titulo,
    required this.icono,
    this.iconColor,
    required this.children,
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
              Icon(icono, size: 18, color: iconColor ?? Colors.white60),
              const SizedBox(width: 6),
              Text(
                titulo,
                style: AppType.label.copyWith(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.2),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ...children,
        ],
      ),
    );
  }
}

class _Linea extends StatelessWidget {
  final String label;
  final String valor;
  final bool highlight;
  final bool sub;

  const _Linea({
    required this.label,
    required this.valor,
    this.highlight = false,
    this.sub = false,
  });

  @override
  Widget build(BuildContext context) {
    // Tamaños subidos 2026-05-19 (Santiago): "la letra queda muy chica
    // cuando el viaje es muy largo". Pasamos 11→13, 12→14, 14→16 para
    // mejor legibilidad sin romper el layout.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: TextStyle(
                color: sub ? Colors.white38 : Colors.white60,
                fontSize: sub ? 13 : 14,
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: Text(
              valor,
              style: TextStyle(
                color: highlight
                    ? AppColors.success
                    : (sub ? Colors.white54 : Colors.white),
                fontSize: highlight ? 16 : (sub ? 13 : 14),
                fontWeight:
                    highlight ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LineaLink extends StatelessWidget {
  final String label;
  final String url;
  final String etiqueta;

  const _LineaLink({
    required this.label,
    required this.url,
    required this.etiqueta,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: AppType.label.copyWith(color: Colors.white60),
            ),
          ),
          Expanded(
            flex: 6,
            child: InkWell(
              onTap: () async {
                final uri = Uri.tryParse(url);
                if (uri != null) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              child: Row(
                children: [
                  const Icon(Icons.open_in_new,
                      size: 14, color: AppColors.info),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(
                    child: Text(
                      etiqueta,
                      style: AppType.label.copyWith(color: AppColors.info, decoration: TextDecoration.underline),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipEstado extends StatelessWidget {
  final EstadoViaje estado;
  const _ChipEstado({required this.estado});

  @override
  Widget build(BuildContext context) {
    final color = switch (estado) {
      EstadoViaje.planeado => AppColors.info,
      EstadoViaje.enCurso => AppColors.warning,
      EstadoViaje.concluido => AppColors.success,
    };
    return _Chip(label: estado.etiqueta.toUpperCase(), color: color);
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icono;
  const _Chip({required this.label, required this.color, this.icono});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icono != null) ...[
            Icon(icono, size: 12, color: color),
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

// `_BotonImprimirComprobante` removido del detalle de viaje el
// 2026-05-13. Los adelantos pasaron a ser entidad propia
// (`ADELANTOS_CHOFER`) y la impresión del comprobante ahora vive
// en `LogisticaAdelantosScreen`, donde cada adelanto tiene su
// propio botón "IMPRIMIR".
