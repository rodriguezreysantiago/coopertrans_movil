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
                _SeccionRuta(v: v),
                const SizedBox(height: 12),
                _SeccionAsignacion(v: v),
                const SizedBox(height: 12),
                _SeccionCargaDescarga(v: v),
                const SizedBox(height: 12),
                _SeccionMontos(v: v),
                const SizedBox(height: 12),
                _SeccionAdelantoYGastos(v: v),
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

class _SeccionRuta extends StatelessWidget {
  final Viaje v;
  const _SeccionRuta({required this.v});

  @override
  Widget build(BuildContext context) {
    final ts = v.tarifaSnapshot;
    return _Seccion(
      titulo: 'RUTA Y TARIFA',
      icono: Icons.alt_route,
      children: [
        _Linea(label: 'Origen',
            valor: '${ts.origenEtiqueta} (${ts.empresaOrigenNombre})'),
        _Linea(label: 'Destino',
            valor: '${ts.destinoEtiqueta} (${ts.empresaDestinoNombre})'),
        if (ts.producto != null && ts.producto!.isNotEmpty)
          _Linea(label: 'Producto', valor: ts.producto!),
        _Linea(
          label: 'Modalidad',
          valor: '${ts.unidadTarifa.etiqueta} · '
              '\$${AppFormatters.formatearMonto(ts.tarifaReal)}'
              '${ts.unidadTarifa.sufijoMonto} (Vecchi) · '
              '\$${AppFormatters.formatearMonto(ts.tarifaChofer)}'
              '${ts.unidadTarifa.sufijoMonto} (chofer)',
        ),
        if (ts.dadorNombre != null)
          _Linea(
            label: 'Dador',
            valor: '${ts.dadorNombre} '
                '${ts.porcentajeComisionDador != null ? "(${ts.porcentajeComisionDador!.toStringAsFixed(1)}%)" : ""}',
          ),
      ],
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

class _SeccionCargaDescarga extends StatelessWidget {
  final Viaje v;
  const _SeccionCargaDescarga({required this.v});

  @override
  Widget build(BuildContext context) {
    return _Seccion(
      titulo: 'CARGA Y DESCARGA',
      icono: Icons.inventory_2_outlined,
      children: [
        _Linea(
          label: 'Fecha carga',
          valor: v.fechaCarga == null
              ? '—'
              : AppFormatters.formatearFechaHoraSinSegundos(v.fechaCarga),
        ),
        if (v.kgCargados != null)
          _Linea(
            label: 'Kg cargados',
            valor: '${AppFormatters.formatearMiles(v.kgCargados!.toInt())} kg',
          ),
        _Linea(
          label: 'Fecha descarga',
          valor: v.fechaDescarga == null
              ? '—'
              : AppFormatters.formatearFechaHoraSinSegundos(v.fechaDescarga),
        ),
        if (v.kgDescargados != null)
          _Linea(
            label: 'Kg descargados',
            valor: '${AppFormatters.formatearMiles(v.kgDescargados!.toInt())} kg',
          ),
        if (v.remitoNumero != null && v.remitoNumero!.isNotEmpty)
          _Linea(label: 'Remito Nº', valor: v.remitoNumero!),
        if (v.remitoUrl != null && v.remitoUrl!.isNotEmpty)
          _LineaLink(
            label: 'Comprobante',
            url: v.remitoUrl!,
            etiqueta: 'Abrir comprobante',
          ),
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
          label: 'Adelanto al chofer',
          valor: v.adelantoMonto == null || v.adelantoMonto == 0
              ? '—'
              : '−\$ ${AppFormatters.formatearMonto(v.adelantoMonto!)}',
        ),
        _Linea(
          label: 'Gastos extraordinarios',
          valor: v.gastosTotal == 0
              ? '—'
              : '+\$ ${AppFormatters.formatearMonto(v.gastosTotal)}',
        ),
        const Divider(height: 16),
        _Linea(
          label: 'LIQUIDACIÓN AL CHOFER',
          valor: '\$ ${AppFormatters.formatearMonto(v.liquidacionChofer)}',
          highlight: true,
        ),
      ],
    );
  }
}

class _SeccionAdelantoYGastos extends StatelessWidget {
  final Viaje v;
  const _SeccionAdelantoYGastos({required this.v});

  @override
  Widget build(BuildContext context) {
    if ((v.adelantoMonto == null || v.adelantoMonto == 0) &&
        v.gastos.isEmpty) {
      return const SizedBox.shrink();
    }
    return _Seccion(
      titulo: 'DETALLE ADELANTO Y GASTOS',
      icono: Icons.receipt_long_outlined,
      children: [
        if (v.adelantoMonto != null && v.adelantoMonto! > 0) ...[
          _Linea(
            label: 'Adelanto monto',
            valor: '\$ ${AppFormatters.formatearMonto(v.adelantoMonto!)}',
          ),
          if (v.adelantoFecha != null)
            _Linea(
              label: 'Adelanto fecha',
              valor: AppFormatters.formatearFecha(v.adelantoFecha),
            ),
          if (v.adelantoObservacion != null &&
              v.adelantoObservacion!.isNotEmpty)
            _Linea(label: 'Observación', valor: v.adelantoObservacion!),
        ],
        if (v.gastos.isNotEmpty) ...[
          if (v.adelantoMonto != null && v.adelantoMonto! > 0)
            const Divider(height: 16),
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'Gastos extraordinarios',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
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
          OutlinedButton.icon(
            onPressed: () => _toggleLiquidado(context, v),
            icon: Icon(
              v.liquidado ? Icons.undo : Icons.check_circle_outline,
              size: 18,
            ),
            label: Text(v.liquidado ? 'DESMARCAR LIQUIDADO' : 'MARCAR LIQUIDADO'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accentGreen,
              side: const BorderSide(color: AppColors.accentGreen),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => _confirmarBorrar(context, v),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('BORRAR'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accentRed,
              side: const BorderSide(color: AppColors.accentRed),
            ),
          ),
        ] else
          OutlinedButton.icon(
            onPressed: () => _reactivar(context, v),
            icon: const Icon(Icons.restore, size: 18),
            label: const Text('REACTIVAR'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accentAmber,
              side: const BorderSide(color: AppColors.accentAmber),
            ),
          ),
      ],
    );
  }

  Future<void> _toggleLiquidado(BuildContext ctx, Viaje v) async {
    final messenger = ScaffoldMessenger.of(ctx);
    final dni = PrefsService.dni;
    try {
      if (v.liquidado) {
        await ViajesService.desmarcarLiquidado(
            viajeId: v.id, actualizadoPorDni: dni);
        AppFeedback.successOn(messenger, 'Marcado como NO liquidado.');
      } else {
        await ViajesService.marcarLiquidado(
            viajeId: v.id, liquidadoPorDni: dni);
        AppFeedback.successOn(messenger, 'Marcado como liquidado.');
      }
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error: $e');
    }
  }

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
      EstadoViaje.completado => AppColors.accentGreen,
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
