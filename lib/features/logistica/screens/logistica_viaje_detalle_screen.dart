// lib/features/logistica/screens/logistica_viaje_detalle_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — detalle de viaje en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - el stream del doc (`ViajesService.streamViaje`),
//   - el modelo `Viaje` (tramos, gastos, importes, adelanto, saldo,
//     tarifa snapshot, timeline de auditoría),
//   - TODOS los cálculos de montos (`CalculosViaje`, redondeo múltiplo
//     de 5 por tramo, etc.),
//   - las acciones (editar / borrar / reactivar / eliminar definitivo)
//     con sus diálogos y services,
//   - la lectura del adelanto asociado (`AdelantosService.getPorViaje`),
//     ahora HOISTED al tope para alimentar el KPI strip + la card de
//     detalle con una sola llamada.
//
// Layout Núcleo:
//   ┌─ Hero: eyebrow VIAJE #id · estado (AppBadge) · chofer · unidad ─┐
//   ├─ AppKpiStrip: km · Vecchi · chofer · adelanto · saldo ──────────┤
//   ├─ Acciones (editar/borrar/…) ───────────────────────────────────┤
//   ├─ Asignación (bento, hairlines) ────────────────────────────────┤
//   ├─ Tarifa + tramos (filas separadas por AppHairline) ────────────┤
//   ├─ Gastos extraordinarios por tramo ─────────────────────────────┤
//   ├─ Documentos (AppFileThumbnail) ────────────────────────────────┤
//   ├─ Montos y liquidación ─────────────────────────────────────────┤
//   └─ Timeline de auditoría (mono) + bloques legacy/borrado ─────────┘
//
// Reglas duras: tokens (context.colors), números en AppType.mono,
// embedded (sin fondo full-screen propio), faltante → "—", sin overflow.

import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/adelanto_chofer.dart';
import '../models/viaje.dart';
import '../utils/calculos_viaje.dart';
import '../services/adelantos_service.dart';
import '../services/viajes_service.dart';

/// Detalle read-only de un viaje. Vista resumida para consulta rápida
/// — el operador entra acá desde la lista para revisar antes de
/// liquidar o editar.
///
/// Acciones disponibles:
///   - Editar (navega al form con el viajeId).
///   - Borrar (soft-delete con motivo).
///   - Reactivar (si está borrado).
///   - Eliminar definitivo (hard-delete, solo si ya está soft-deleted).
class LogisticaViajeDetalleScreen extends StatelessWidget {
  final String viajeId;

  const LogisticaViajeDetalleScreen({super.key, required this.viajeId});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
            return const AppEmptyState(
              icon: Icons.local_shipping_outlined,
              title: 'Viaje no encontrado',
              subtitle: 'Puede haber sido eliminado definitivamente.',
            );
          }
          // El adelanto asociado se lee UNA vez y se baja a quien lo
          // necesite (KPI strip + card de detalle). Mismo service call
          // que antes, solo hoisteado al tope.
          return FutureBuilder<AdelantoChofer?>(
            future: AdelantosService.getPorViaje(v.id),
            builder: (fctx, fsnap) {
              final adelanto = fsnap.data;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.xxl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Hero(v: v),
                    const SizedBox(height: AppSpacing.lg),
                    _KpiStripViaje(v: v, adelanto: adelanto),
                    const SizedBox(height: AppSpacing.mdDense),
                    // Acciones ARRIBA — Santiago 2026-05-14: que
                    // EDITAR/BORRAR estén accesibles sin scroll.
                    _BotoneraAcciones(v: v),
                    const SizedBox(height: AppSpacing.mdDense),
                    _SeccionAsignacion(v: v),
                    if (adelanto != null) ...[
                      const SizedBox(height: AppSpacing.mdDense),
                      _SeccionAdelantoAsociado(adelanto: adelanto),
                    ],
                    const SizedBox(height: AppSpacing.mdDense),
                    _SeccionTramos(v: v),
                    const SizedBox(height: AppSpacing.mdDense),
                    _SeccionDocumentos(v: v),
                    const SizedBox(height: AppSpacing.mdDense),
                    _SeccionMontos(v: v),
                    if (v.motivoCancelacion != null ||
                        v.fechaPostergadoA != null) ...[
                      const SizedBox(height: AppSpacing.mdDense),
                      _SeccionMotivo(v: v),
                    ],
                    _SeccionTimeline(v: v),
                    if (!v.activo) ...[
                      const SizedBox(height: AppSpacing.mdDense),
                      _SeccionBorrado(v: v),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    Center(
                      child: Text(
                        'ID ${v.id}',
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// =============================================================================
// HERO · eyebrow + número de viaje + estado + chofer · unidad
// =============================================================================

class _Hero extends StatelessWidget {
  final Viaje v;
  const _Hero({required this.v});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final carga = v.cargaTransportada?.trim();
    final tieneCarga = carga != null && carga.isNotEmpty;
    final unidadPartes = <String>[
      if (v.vehiculoId != null && v.vehiculoId!.isNotEmpty) v.vehiculoId!,
      if (v.engancheId != null && v.engancheId!.isNotEmpty) v.engancheId!,
    ];

    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppEyebrow('VIAJE'),
              const Spacer(),
              _EstadoBadge(estado: v.estado),
              if (v.liquidado) ...[
                const SizedBox(width: AppSpacing.sm),
                AppBadge(
                  text: 'LIQUIDADO',
                  color: c.success,
                  size: AppBadgeSize.sm,
                  icon: Icons.check,
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Número de viaje (hero). El "número" operativo del viaje es
          // su id de Firestore — lo mostramos en mono, que es la tinta
          // técnica del sistema.
          Text(
            tieneCarga ? carga : 'Sin descripción de carga',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppType.h3.copyWith(
              color: tieneCarga ? c.text : c.textMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // Ruta origen → destino del viaje (real, del snapshot).
          Text(
            v.rutaEtiqueta,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppType.body.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          const AppHairline(),
          const SizedBox(height: AppSpacing.md),
          // Chofer · unidad
          Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _HeroMeta(
                icon: Icons.person_outline,
                label: v.choferNombre?.isNotEmpty == true
                    ? v.choferNombre!
                    : 'Chofer',
                value: 'DNI ${v.choferDni}',
              ),
              if (unidadPartes.isNotEmpty)
                _HeroMeta(
                  icon: Icons.local_shipping_outlined,
                  label: 'Unidad',
                  value: unidadPartes.join(' · '),
                ),
              if (v.fechaReferencia != null)
                _HeroMeta(
                  icon: Icons.event_outlined,
                  label: 'Fecha',
                  value: AppFormatters.formatearFecha(v.fechaReferencia),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroMeta extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _HeroMeta({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: c.textMuted),
        const SizedBox(width: AppSpacing.sm),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: AppType.bodySm.copyWith(color: c.text), maxLines: 1),
            Text(value,
                style: AppType.monoSm.copyWith(color: c.textMuted),
                maxLines: 1),
          ],
        ),
      ],
    );
  }
}

/// Badge de estado con color semántico Núcleo.
class _EstadoBadge extends StatelessWidget {
  final EstadoViaje estado;
  const _EstadoBadge({required this.estado});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = switch (estado) {
      EstadoViaje.planeado => c.info,
      EstadoViaje.enCurso => c.brand,
      EstadoViaje.concluido => c.success,
    };
    return AppBadge(
      text: estado.etiqueta.toUpperCase(),
      color: color,
      dot: true,
      size: AppBadgeSize.sm,
    );
  }
}

// =============================================================================
// KPI STRIP · km · Vecchi · chofer · adelanto · saldo
// =============================================================================

class _KpiStripViaje extends StatelessWidget {
  final Viaje v;
  final AdelantoChofer? adelanto;
  const _KpiStripViaje({required this.v, required this.adelanto});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // El modelo de viaje NO trackea km (sí kg por tramo). Honramos el
    // layout pedido con un slot "Km" pero, sin dato real, mostramos "—"
    // (regla: nunca inventar). El peso descargado total sí es real y va
    // como unidad informativa cuando existe.
    final kgTotal = v.tramos.fold<double>(
      0,
      (acc, t) => acc + (t.kgDescargados ?? t.kgCargados ?? 0),
    );

    String monto(double m) => '\$ ${AppFormatters.formatearMonto(m)}';

    return LayoutBuilder(
      builder: (ctx, constraints) {
        // En anchos chicos un strip de 5 columnas se aprieta. Bajo cierto
        // umbral lo partimos en dos strips apilados (3 + 2) para que los
        // hero numbers respiren sin overflow.
        final stats = <AppStat>[
          AppStat(
            label: 'Km',
            value: '—',
            // Sin km en el modelo; si hay peso lo damos como contexto real.
            delta: kgTotal > 0
                ? '${AppFormatters.formatearMiles(kgTotal.round())} kg'
                : null,
            deltaColor: c.textMuted,
          ),
          AppStat(
            label: 'Vecchi',
            value: monto(v.montoVecchi),
            valueStyle: AppType.h4,
          ),
          AppStat(
            label: 'Chofer',
            value: monto(v.montoChoferRedondeado),
            valueStyle: AppType.h4,
            accent: c.text,
          ),
          AppStat(
            label: 'Adelanto',
            value: adelanto == null ? '—' : monto(adelanto!.monto),
            valueStyle: AppType.h4,
            accent: adelanto == null ? c.textMuted : c.warning,
          ),
          AppStat(
            label: 'Saldo',
            value: monto(v.liquidacionChofer),
            valueStyle: AppType.h4,
            accent: c.success,
          ),
        ];

        if (constraints.maxWidth < 560) {
          return Column(
            children: [
              AppKpiStrip(stats: stats.sublist(0, 3)),
              const SizedBox(height: AppSpacing.sm),
              AppKpiStrip(stats: stats.sublist(3)),
            ],
          );
        }
        return AppKpiStrip(stats: stats);
      },
    );
  }
}

// =============================================================================
// SECCIONES (bento)
// =============================================================================

/// Tarjeta de sección Núcleo: eyebrow (+ dot opcional) y contenido.
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
              Expanded(
                child: AppEyebrow(
                  titulo,
                  color: accentDot,
                ),
              ),
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

class _SeccionAsignacion extends StatelessWidget {
  final Viaje v;
  const _SeccionAsignacion({required this.v});

  @override
  Widget build(BuildContext context) {
    return _Seccion(
      titulo: 'ASIGNACIÓN',
      children: [
        _Linea(
          label: 'Chofer',
          valor: v.choferNombre?.isNotEmpty == true
              ? '${v.choferNombre} (DNI ${v.choferDni})'
              : 'DNI ${v.choferDni}',
        ),
        _Linea(
          label: 'Tractor',
          valor: (v.vehiculoId != null && v.vehiculoId!.isNotEmpty)
              ? v.vehiculoId!
              : '—',
          mono: true,
        ),
        _Linea(
          label: 'Enganche',
          valor: (v.engancheId != null && v.engancheId!.isNotEmpty)
              ? v.engancheId!
              : '—',
          mono: true,
        ),
      ],
    );
  }
}

/// Bloque del adelanto asociado al viaje (si hay). El dato lo provee el
/// padre (hoisted future). Si no hay adelanto, el padre no monta este
/// widget.
class _SeccionAdelantoAsociado extends StatelessWidget {
  final AdelantoChofer adelanto;
  const _SeccionAdelantoAsociado({required this.adelanto});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final a = adelanto;
    return _Seccion(
      titulo: 'ADELANTO ASOCIADO',
      accentDot: c.warning,
      children: [
        _Linea(label: 'Fecha', valor: AppFormatters.formatearFecha(a.fecha)),
        _Linea(
          label: 'Monto',
          valor: '\$ ${AppFormatters.formatearMonto(a.monto)}',
          highlight: true,
          mono: true,
        ),
        _Linea(label: 'Medio de pago', valor: a.medioPago.etiqueta),
        if (a.observacion != null && a.observacion!.trim().isNotEmpty)
          _Linea(label: 'Observación', valor: a.observacion!),
        if (a.numeroRecibo != null)
          _Linea(
            label: 'Recibo N°',
            valor: a.numeroRecibo!.toString().padLeft(6, '0'),
            mono: true,
          ),
      ],
    );
  }
}

/// Tramos del viaje. Single-tramo = 1 tramo; multi-tramo lista cada uno
/// separado por un AppHairline.
class _SeccionTramos extends StatelessWidget {
  final Viaje v;
  const _SeccionTramos({required this.v});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = v.tramos.length;
    return _Seccion(
      titulo: v.esMultiTramo ? 'TRAMOS' : 'RUTA Y CARGA',
      trailing: v.esMultiTramo
          ? Text(
              '$n tramos',
              style: AppType.monoSm.copyWith(color: c.textMuted),
            )
          : null,
      children: [
        for (var i = 0; i < n; i++) ...[
          if (i > 0) ...[
            const SizedBox(height: AppSpacing.md),
            const AppHairline(),
            const SizedBox(height: AppSpacing.md),
          ],
          _DetalleTramo(
            numero: v.esMultiTramo ? i + 1 : null,
            tramo: v.tramos[i],
            comisionPct: v.comisionChoferPct,
          ),
        ],
      ],
    );
  }
}

class _DetalleTramo extends StatelessWidget {
  final int? numero;
  final TramoViaje tramo;

  /// Porcentaje de comisión del chofer (típicamente 18) que viene del
  /// viaje. Lo necesitamos para mostrar la comisión del chofer DE ESTE
  /// TRAMO (18 % sobre la base bruta del tramo).
  final double comisionPct;

  const _DetalleTramo({
    required this.numero,
    required this.tramo,
    required this.comisionPct,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
    // Monto chofer del tramo: si la tarifa tiene `montoFijoChofer`, ese
    // monto es lo que cobra el chofer (sin pct). Sino, aplicamos el
    // porcentaje sobre la tarifa chofer base.
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

    final producto = (tramo.producto != null && tramo.producto!.isNotEmpty)
        ? tramo.producto!
        : (ts.producto != null && ts.producto!.isNotEmpty ? ts.producto! : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (numero != null) ...[
          Row(
            children: [
              AppDot(c.brand, size: 6),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'TRAMO $numero',
                style: AppType.eyebrow.copyWith(color: c.brand),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        // Ruta del tramo: origen → destino, prominente.
        _RutaTramo(origen: ts.origenDisplay, destino: ts.destinoDisplay),
        const SizedBox(height: AppSpacing.sm),
        if (producto != null) _Linea(label: 'Producto', valor: producto),
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
          label: 'Carga',
          valor: tramo.fechaCarga == null
              ? '—'
              : AppFormatters.formatearFechaHoraSinSegundos(tramo.fechaCarga),
          mono: true,
        ),
        if (tramo.kgCargados != null)
          _Linea(
            label: 'Kg cargados',
            valor:
                '${AppFormatters.formatearMiles(tramo.kgCargados!.toInt())} kg',
            mono: true,
          ),
        _Linea(
          label: 'Descarga',
          valor: tramo.fechaDescarga == null
              ? '—'
              : AppFormatters.formatearFechaHoraSinSegundos(
                  tramo.fechaDescarga),
          mono: true,
        ),
        if (tramo.kgDescargados != null)
          _Linea(
            label: 'Kg descargados',
            valor:
                '${AppFormatters.formatearMiles(tramo.kgDescargados!.toInt())} kg',
            mono: true,
          ),
        if (tramo.remitoNumero != null && tramo.remitoNumero!.isNotEmpty)
          _Linea(label: 'Remito N°', valor: tramo.remitoNumero!, mono: true),
        // Gastos extraordinarios del tramo + total del tramo.
        if (tramo.gastos.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          const AppEyebrow('GASTOS EXTRAORDINARIOS'),
          const SizedBox(height: AppSpacing.sm),
          for (final g in tramo.gastos)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(Icons.add_circle_outline,
                      size: 15, color: c.brandSoft),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      g.detalle?.isNotEmpty == true
                          ? '${g.detalle} (${AppFormatters.formatearFecha(g.fecha)})'
                          : 'Gasto del ${AppFormatters.formatearFecha(g.fecha)}',
                      style: AppType.bodySm.copyWith(color: c.textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    '\$ ${AppFormatters.formatearMonto(g.monto)}',
                    style: AppType.mono.copyWith(
                      color: c.brandSoft,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          _Linea(
            label: 'Total gastos del tramo',
            valor: '\$ ${AppFormatters.formatearMonto(tramo.gastosTotal)}',
            highlight: true,
            mono: true,
          ),
        ],
        // Montos calculados del tramo. Solo si hay base.
        if (hayMontos) ...[
          const SizedBox(height: AppSpacing.md),
          const AppHairline(),
          const SizedBox(height: AppSpacing.md),
          _Linea(
            label: 'Tarifa Vecchi (factura)',
            valor: '\$ ${AppFormatters.formatearMonto(brutos.montoVecchi)}',
            mono: true,
          ),
          if (esMontoFijo) ...[
            _Linea(
              label: 'Tarifa chofer (base, referencia)',
              valor: '\$ ${AppFormatters.formatearMonto(brutos.montoChofer)}',
              sub: true,
              mono: true,
            ),
            _Linea(
              label: 'Monto chofer del tramo (fijo, redondeado)',
              valor:
                  '\$ ${AppFormatters.formatearMonto(comisionChoferTramoRedondeada)}',
              highlight: true,
              mono: true,
            ),
          ] else ...[
            _Linea(
              label: 'Tarifa chofer (base)',
              valor: '\$ ${AppFormatters.formatearMonto(brutos.montoChofer)}',
              sub: true,
              mono: true,
            ),
            _Linea(
              label:
                  'Comisión chofer (${comisionPct.toStringAsFixed(0)}%, bruto)',
              valor:
                  '\$ ${AppFormatters.formatearMonto(comisionChoferTramo)}',
              sub: true,
              mono: true,
            ),
            _Linea(
              label: 'Comisión chofer redondeada (múltiplo de 5)',
              valor:
                  '\$ ${AppFormatters.formatearMonto(comisionChoferTramoRedondeada)}',
              highlight: true,
              mono: true,
            ),
          ],
        ],
      ],
    );
  }
}

/// Ruta origen → destino del tramo, con la flecha en la tinta muted.
class _RutaTramo extends StatelessWidget {
  final String origen;
  final String destino;
  const _RutaTramo({required this.origen, required this.destino});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return RichText(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: AppType.body.copyWith(color: c.text),
        children: [
          TextSpan(text: origen),
          TextSpan(
            text: '   →   ',
            style: AppType.body.copyWith(color: c.textMuted),
          ),
          TextSpan(text: destino),
        ],
      ),
    );
  }
}

/// Documentos del viaje (comprobantes de remito por tramo) renderizados
/// con AppFileThumbnail — abre el visor in-app al tocar.
class _SeccionDocumentos extends StatelessWidget {
  final Viaje v;
  const _SeccionDocumentos({required this.v});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Juntamos los remitos con URL de todos los tramos.
    final docs = <({int? tramo, String label, String url})>[];
    for (var i = 0; i < v.tramos.length; i++) {
      final t = v.tramos[i];
      if (t.remitoUrl != null && t.remitoUrl!.isNotEmpty) {
        docs.add((
          tramo: v.esMultiTramo ? i + 1 : null,
          label: t.remitoNumero?.isNotEmpty == true
              ? 'Remito ${t.remitoNumero}'
              : 'Comprobante',
          url: t.remitoUrl!,
        ));
      }
    }
    if (docs.isEmpty) return const SizedBox.shrink();

    return _Seccion(
      titulo: 'DOCUMENTOS',
      trailing: Text(
        '${docs.length}',
        style: AppType.monoSm.copyWith(color: c.textMuted),
      ),
      children: [
        for (var i = 0; i < docs.length; i++) ...[
          if (i > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            const AppHairline(),
            const SizedBox(height: AppSpacing.sm),
          ],
          Row(
            children: [
              AppFileThumbnail(
                url: docs[i].url,
                tituloVisor: docs[i].tramo != null
                    ? '${docs[i].label} · tramo ${docs[i].tramo}'
                    : docs[i].label,
                size: 44,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      docs[i].label,
                      style: AppType.body
                          .copyWith(color: c.text, fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (docs[i].tramo != null)
                      Text(
                        'Tramo ${docs[i].tramo}',
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: c.textMuted),
            ],
          ),
        ],
      ],
    );
  }
}

class _SeccionMontos extends StatelessWidget {
  final Viaje v;
  const _SeccionMontos({required this.v});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final diferenciaRedondeo = v.montoChofer - v.montoChoferRedondeado;
    return _Seccion(
      titulo: 'MONTOS Y LIQUIDACIÓN',
      accentDot: c.success,
      children: [
        _Linea(
          label: 'Monto Vecchi (factura)',
          valor: '\$ ${AppFormatters.formatearMonto(v.montoVecchi)}',
          mono: true,
        ),
        _Linea(
          label:
              'Comisión chofer (${v.comisionChoferPct.toStringAsFixed(0)}% s/ tarifa chofer)',
          valor: '\$ ${AppFormatters.formatearMonto(v.montoChofer)}',
          mono: true,
        ),
        _Linea(
          label: 'Comisión chofer redondeada',
          valor: '\$ ${AppFormatters.formatearMonto(v.montoChoferRedondeado)}',
          highlight: true,
          mono: true,
        ),
        if (diferenciaRedondeo > 0.01)
          _Linea(
            label: 'Redondeo aplicado',
            valor: '−\$ ${AppFormatters.formatearMonto(diferenciaRedondeo)}',
            sub: true,
            mono: true,
          ),
        const SizedBox(height: AppSpacing.sm),
        const AppHairline(),
        const SizedBox(height: AppSpacing.sm),
        _Linea(
          label: 'Gastos extraordinarios',
          valor: v.gastosTotal == 0
              ? '—'
              : '+\$ ${AppFormatters.formatearMonto(v.gastosTotal)}',
          mono: true,
        ),
        const SizedBox(height: AppSpacing.sm),
        const AppHairline(),
        const SizedBox(height: AppSpacing.sm),
        _Linea(
          label: 'SUBTOTAL CHOFER (sin adelantos)',
          valor: '\$ ${AppFormatters.formatearMonto(v.liquidacionChofer)}',
          highlight: true,
          mono: true,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Los adelantos se restan en LIQUIDACIÓN sumando los del chofer '
          'en el rango. Acá solo se muestra lo que genera el viaje en sí.',
          style: AppType.bodySm.copyWith(color: c.textMuted),
        ),
      ],
    );
  }
}

/// Timeline de auditoría (creado / actualizado). Mono para lo técnico.
class _SeccionTimeline extends StatelessWidget {
  final Viaje v;
  const _SeccionTimeline({required this.v});

  @override
  Widget build(BuildContext context) {
    final eventos = <({String label, DateTime fecha, String? por})>[];
    if (v.creadoEn != null) {
      eventos.add((
        label: 'Creado',
        fecha: v.creadoEn!,
        por: v.creadoPorNombre?.isNotEmpty == true
            ? v.creadoPorNombre
            : (v.creadoPorDni != null ? 'DNI ${v.creadoPorDni}' : null),
      ));
    }
    if (v.actualizadoEn != null) {
      eventos.add((
        label: 'Última edición',
        fecha: v.actualizadoEn!,
        por: v.actualizadoPorDni != null ? 'DNI ${v.actualizadoPorDni}' : null,
      ));
    }
    if (v.liquidado && v.liquidadoEn != null) {
      eventos.add((
        label: 'Liquidado',
        fecha: v.liquidadoEn!,
        por:
            v.liquidadoPorDni != null ? 'DNI ${v.liquidadoPorDni}' : null,
      ));
    }
    if (eventos.isEmpty) return const SizedBox.shrink();

    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.mdDense),
      child: _Seccion(
        titulo: 'TIMELINE',
        children: [
          for (var i = 0; i < eventos.length; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: AppSpacing.sm),
              const AppHairline(),
              const SizedBox(height: AppSpacing.sm),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: AppDot(c.textMuted, size: 6),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eventos[i].label,
                        style: AppType.body.copyWith(
                            color: c.text, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        eventos[i].por != null
                            ? '${AppFormatters.formatearFechaHoraSinSegundos(eventos[i].fecha)} · ${eventos[i].por}'
                            : AppFormatters.formatearFechaHoraSinSegundos(
                                eventos[i].fecha),
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SeccionMotivo extends StatelessWidget {
  final Viaje v;
  const _SeccionMotivo({required this.v});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Compat retro 2026-05-14: CANCELADO/POSTERGADO se removieron del
    // enum, pero un viaje viejo puede tener motivo o fecha persistidos.
    return _Seccion(
      titulo: 'DATOS LEGACY',
      accentDot: c.warning,
      children: [
        if (v.motivoCancelacion != null && v.motivoCancelacion!.isNotEmpty)
          Text(
            v.motivoCancelacion!,
            style: AppType.body.copyWith(color: c.textSecondary),
          ),
        if (v.fechaPostergadoA != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
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
    final c = context.colors;
    return AppCard(
      tier: 2,
      accent: c.error,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppDot(c.error, size: 7),
              const SizedBox(width: AppSpacing.sm),
              AppEyebrow('VIAJE BORRADO (SOFT-DELETE)', color: c.error),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (v.borradoEn != null)
            _Linea(
              label: 'Borrado el',
              valor: AppFormatters.formatearFechaHoraSinSegundos(v.borradoEn),
              mono: true,
            ),
          if (v.borradoPorDni != null)
            _Linea(label: 'Borrado por', valor: 'DNI ${v.borradoPorDni}'),
          if (v.motivoBorrado != null && v.motivoBorrado!.isNotEmpty)
            _Linea(label: 'Motivo', valor: v.motivoBorrado!),
        ],
      ),
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
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        AppButton.secondary(
          label: 'Editar',
          icon: Icons.edit_outlined,
          size: AppButtonSize.sm,
          onPressed: () => Navigator.pushNamed(
            context,
            AppRoutes.adminLogisticaViajeForm,
            arguments: {'viajeId': v.id},
          ),
        ),
        if (v.activo) ...[
          // Botón "MARCAR/DESMARCAR LIQUIDADO" eliminado 2026-05-11.
          // La liquidación ahora se hace en bulk desde LIQUIDACIÓN.
          AppButton.danger(
            label: 'Borrar',
            icon: Icons.delete_outline,
            size: AppButtonSize.sm,
            onPressed: () => _confirmarBorrar(context, v),
          ),
        ] else ...[
          AppButton.secondary(
            label: 'Reactivar',
            icon: Icons.restore,
            size: AppButtonSize.sm,
            onPressed: () => _reactivar(context, v),
          ),
          AppButton.danger(
            label: 'Eliminar definitivo',
            icon: Icons.delete_forever,
            size: AppButtonSize.sm,
            onPressed: () => _confirmarEliminarDefinitivo(context, v),
          ),
        ],
      ],
    );
  }

  /// Confirmación de hard-delete. Single dialog (sin tipear ELIMINAR).
  Future<void> _confirmarEliminarDefinitivo(BuildContext ctx, Viaje v) async {
    final c = ctx.colors;
    final messenger = ScaffoldMessenger.of(ctx);
    final navigator = Navigator.of(ctx);
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        backgroundColor: c.surface2,
        title: const Text('¿Eliminar definitivamente?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Vas a borrar este viaje POR COMPLETO de la base. No queda '
              'en histórico, no se puede reactivar, los comprobantes de '
              'remito también se borran de Storage.',
              style: AppType.body.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Chofer: ${v.choferNombre ?? v.choferDni}',
              style: AppType.body.copyWith(
                color: c.text,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Ruta: ${v.rutaEtiqueta}',
              style: AppType.label.copyWith(color: c.textSecondary),
            ),
          ],
        ),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.pop(dCtx, false),
          ),
          AppButton.danger(
            label: 'Eliminar definitivo',
            onPressed: () => Navigator.pop(dCtx, true),
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

  Future<void> _confirmarBorrar(BuildContext ctx, Viaje v) async {
    final c = ctx.colors;
    final motivoCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        backgroundColor: c.surface2,
        title: const Text('Borrar viaje'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'El viaje queda como borrado pero la información se mantiene '
              'para auditoría. Podés reactivarlo después.',
              style: AppType.body.copyWith(color: c.textSecondary),
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
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.pop(dCtx, false),
          ),
          AppButton.danger(
            label: 'Borrar',
            onPressed: () => Navigator.pop(dCtx, true),
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
// PRIMITIVA DE LÍNEA · label (izq) / valor (der) — Núcleo
// =============================================================================

class _Linea extends StatelessWidget {
  final String label;
  final String valor;
  final bool highlight;
  final bool sub;
  final bool mono;

  const _Linea({
    required this.label,
    required this.valor,
    this.highlight = false,
    this.sub = false,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final labelStyle = AppType.bodySm.copyWith(
      color: sub ? c.textMuted : c.textSecondary,
    );
    final valBase = mono ? AppType.mono : AppType.body;
    final valStyle = valBase.copyWith(
      color: highlight
          ? c.success
          : (sub ? c.textMuted : c.text),
      fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(label, style: labelStyle),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 6,
            child: Text(
              valor,
              style: valStyle,
              textAlign: TextAlign.right,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
