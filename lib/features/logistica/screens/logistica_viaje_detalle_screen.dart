import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/viaje.dart';
import '../services/viajes_service.dart';

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
            return const Center(child: CircularProgressIndicator());
          }
          final v = snap.data;
          if (v == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
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
                const SizedBox(height: 12),
                _SeccionAsignacion(v: v),
                const SizedBox(height: 12),
                _SeccionTramos(v: v),
                const SizedBox(height: 12),
                _SeccionMontos(v: v),
                const SizedBox(height: 12),
                _SeccionGastos(v: v),
                if (v.motivoCancelacion != null ||
                    v.fechaPostergadoA != null) ...[
                  const SizedBox(height: 12),
                  _SeccionMotivo(v: v),
                ],
                if (!v.activo) ...[
                  const SizedBox(height: 12),
                  _SeccionBorrado(v: v),
                ],
                const SizedBox(height: 24),
                _BotoneraAcciones(v: v),
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
              const Text(
                'VIAJE',
                style: TextStyle(
                  color: Colors.white60,
                  fontSize: 11,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              _ChipEstado(estado: v.estado),
              if (v.liquidado) ...[
                const SizedBox(width: 6),
                const _Chip(
                  label: 'LIQUIDADO',
                  color: AppColors.accentGreen,
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
            style: TextStyle(
              color: v.cargaTransportada?.isNotEmpty == true
                  ? Colors.white
                  : Colors.white38,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'ID: ${v.id}',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
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
  const _DetalleTramo({required this.numero, required this.tramo});

  @override
  Widget build(BuildContext context) {
    final ts = tramo.tarifaSnapshot;
    return Container(
      decoration: numero == null
          ? null
          : BoxDecoration(
              border: Border.all(color: Colors.white12),
              borderRadius: BorderRadius.circular(8),
            ),
      padding: numero == null ? EdgeInsets.zero : const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (numero != null) ...[
            Text(
              'TRAMO $numero',
              style: const TextStyle(
                color: AppColors.accentBlue,
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 6),
          ],
          _Linea(
            label: 'Origen',
            valor: '${ts.origenEtiqueta} (${ts.empresaOrigenNombre})',
          ),
          _Linea(
            label: 'Destino',
            valor: '${ts.destinoEtiqueta} (${ts.empresaDestinoNombre})',
          ),
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
        ],
      ),
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
      iconColor: AppColors.accentGreen,
      children: [
        _Linea(
          label: 'Monto Vecchi (factura)',
          valor: '\$ ${AppFormatters.formatearMonto(v.montoVecchi)}',
        ),
        _Linea(
          label: 'Monto chofer (sin redondear)',
          valor: '\$ ${AppFormatters.formatearMonto(v.montoChofer)}',
        ),
        _Linea(
          label: 'Monto chofer redondeado',
          valor: '\$ ${AppFormatters.formatearMonto(v.montoChoferRedondeado)}',
          highlight: true,
        ),
        if (diferenciaRedondeo > 0.01)
          _Linea(
            label: '  Redondeo aplicado',
            valor: '−\$ ${AppFormatters.formatearMonto(diferenciaRedondeo)}',
            sub: true,
          ),
        _Linea(
          label: 'Comisión chofer',
          valor: '${v.comisionChoferPct.toStringAsFixed(0)}% sobre tarifa',
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
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Los adelantos se restan en LIQUIDACIÓN sumando los '
            'del chofer en el rango. Acá solo se muestra lo que '
            'genera el viaje en sí.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

/// Sección de gastos extraordinarios del viaje (peajes, lavado,
/// reparaciones menores, etc.). Hasta 2026-05-13 esto se mostraba
/// junto con el adelanto, pero los adelantos pasaron a ser una
/// entidad propia (`ADELANTOS_CHOFER`). Ahora la sección solo
/// muestra los gastos.
class _SeccionGastos extends StatelessWidget {
  final Viaje v;
  const _SeccionGastos({required this.v});

  @override
  Widget build(BuildContext context) {
    if (v.gastos.isEmpty) {
      return const SizedBox.shrink();
    }
    return _Seccion(
      titulo: 'GASTOS EXTRAORDINARIOS',
      icono: Icons.receipt_long_outlined,
      children: [
        for (final g in v.gastos)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                const Icon(Icons.add_circle_outline,
                    size: 14, color: AppColors.accentTeal),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    g.detalle?.isNotEmpty == true
                        ? '${g.detalle} (${AppFormatters.formatearFecha(g.fecha)})'
                        : 'Gasto del ${AppFormatters.formatearFecha(g.fecha)}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                  ),
                ),
                Text(
                  '\$ ${AppFormatters.formatearMonto(g.monto)}',
                  style: const TextStyle(
                    color: AppColors.accentTeal,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SeccionMotivo extends StatelessWidget {
  final Viaje v;
  const _SeccionMotivo({required this.v});

  @override
  Widget build(BuildContext context) {
    return _Seccion(
      titulo: v.estado == EstadoViaje.cancelado
          ? 'MOTIVO DE CANCELACIÓN'
          : 'POSTERGACIÓN',
      icono: Icons.warning_amber_outlined,
      iconColor: AppColors.accentAmber,
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
      iconColor: AppColors.accentRed,
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
            backgroundColor: AppColors.accentBlue,
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
              foregroundColor: AppColors.accentRed,
              side: const BorderSide(color: AppColors.accentRed),
            ),
          ),
        ] else ...[
          OutlinedButton.icon(
            onPressed: () => _reactivar(context, v),
            icon: const Icon(Icons.restore, size: 18),
            label: const Text('REACTIVAR'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accentAmber,
              side: const BorderSide(color: AppColors.accentAmber),
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
              foregroundColor: AppColors.accentRed,
              side: const BorderSide(color: AppColors.accentRed),
            ),
          ),
        ],
      ],
    );
  }

  /// Confirmación REDUNDANTE para hard-delete. Pide al operador
  /// tipear "ELIMINAR" para liberar el botón final, así no se
  /// pierde un viaje real por un click distraído. Etapa de testing.
  Future<void> _confirmarEliminarDefinitivo(BuildContext ctx, Viaje v) async {
    final messenger = ScaffoldMessenger.of(ctx);
    final navigator = Navigator.of(ctx);
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) {
        final tipeoCtrl = TextEditingController();
        var habilitado = false;
        return StatefulBuilder(builder: (sCtx, setStateDialog) {
          return AlertDialog(
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
                const SizedBox(height: 8),
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
                const SizedBox(height: 12),
                const Text(
                  'Para confirmar, escribí ELIMINAR (en mayúscula):',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: tipeoCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (val) {
                    final h = val.trim() == 'ELIMINAR';
                    if (h != habilitado) {
                      setStateDialog(() => habilitado = h);
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dCtx, false),
                child: const Text('CANCELAR'),
              ),
              FilledButton(
                onPressed: habilitado
                    ? () => Navigator.pop(dCtx, true)
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accentRed,
                ),
                child: const Text('ELIMINAR DEFINITIVO'),
              ),
            ],
          );
        });
      },
    );
    if (ok != true) return;
    if (!ctx.mounted) return;
    try {
      await ViajesService.eliminarViajeDefinitivo(v.id);
      AppFeedback.successOn(messenger, 'Viaje eliminado definitivamente.');
      navigator.pop();
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error: $e');
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
            const SizedBox(height: 12),
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
              backgroundColor: AppColors.accentRed,
              foregroundColor: Colors.white,
            ),
            child: const Text('BORRAR'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!ctx.mounted) return;
    final messenger = ScaffoldMessenger.of(ctx);
    final navigator = Navigator.of(ctx);
    try {
      await ViajesService.borrarViaje(
        viajeId: v.id,
        borradoPorDni: PrefsService.dni,
        motivo: motivoCtrl.text.trim().isEmpty ? null : motivoCtrl.text.trim(),
      );
      AppFeedback.successOn(messenger, 'Viaje borrado.');
      navigator.pop();
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error: $e');
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
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error: $e');
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
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: TextStyle(
                color: sub ? Colors.white38 : Colors.white60,
                fontSize: sub ? 11 : 12,
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: Text(
              valor,
              style: TextStyle(
                color: highlight
                    ? AppColors.accentGreen
                    : (sub ? Colors.white54 : Colors.white),
                fontSize: highlight ? 14 : (sub ? 11 : 12),
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
              style: const TextStyle(color: Colors.white60, fontSize: 12),
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
                      size: 14, color: AppColors.accentBlue),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      etiqueta,
                      style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 12,
                        decoration: TextDecoration.underline,
                      ),
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
      EstadoViaje.planeado => AppColors.accentBlue,
      EstadoViaje.enCurso => AppColors.accentAmber,
      EstadoViaje.concluido => AppColors.accentGreen,
      EstadoViaje.cancelado => AppColors.accentRed,
      EstadoViaje.postergado => Colors.purple,
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
