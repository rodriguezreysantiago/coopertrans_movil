import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import '../models/cubierta.dart';
import '../models/cubierta_control.dart';
import '../models/cubierta_instalada.dart';
import '../models/cubierta_recapado.dart';
import '../services/gomeria_service.dart';

/// Pantalla detalle de UNA cubierta — accede desde el Stock al tappear
/// un tile o desde la búsqueda global por código. Muestra:
///
/// - Identidad: código, modelo, vidas, estado, km totales acumulados.
/// - Historial de instalaciones: todas las que tuvo (activa + cerradas)
///   ordenadas por fecha desc, con km recorridos y duración.
/// - Historial de recapados: todos los envíos al proveedor con
///   fechas, costo y resultado.
///
/// Permite reconciliar con planilla física ("¿dónde estuvo CUB-0042 los
/// últimos 6 meses?", "¿cuántos recapados lleva?", "¿dónde se descartó?").
class GomeriaCubiertaDetalleScreen extends StatelessWidget {
  final String cubiertaId;
  const GomeriaCubiertaDetalleScreen({super.key, required this.cubiertaId});

  @override
  Widget build(BuildContext context) {
    final service = GomeriaService();
    return AppScaffold(
      title: 'Cubierta',
      body: StreamBuilder<Cubierta?>(
        stream: service.streamCubierta(cubiertaId),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AppErrorState(
              title: 'No se pudo cargar la cubierta',
              subtitle: snap.error.toString(),
            );
          }
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final c = snap.data;
          if (c == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No se encontró la cubierta.',
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
                _Identidad(c: c),
                const SizedBox(height: 16),
                const _SeccionTitulo('Historial de instalaciones'),
                StreamBuilder<List<CubiertaInstalada>>(
                  stream: service.streamHistorialInstalacionesPorCubierta(
                      cubiertaId),
                  builder: (ctx, snap) {
                    final hist = snap.data ?? const <CubiertaInstalada>[];
                    if (hist.isEmpty) {
                      return const _Vacio('Nunca se instaló.');
                    }
                    return Column(
                      children: [
                        for (final i in hist) _InstalacionTile(i: i),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                const _SeccionTitulo('Historial de recapados'),
                StreamBuilder<List<CubiertaRecapado>>(
                  stream: service
                      .streamHistorialRecapadosPorCubierta(cubiertaId),
                  builder: (ctx, snap) {
                    final recs = snap.data ?? const <CubiertaRecapado>[];
                    if (recs.isEmpty) {
                      return const _Vacio('Sin recapados registrados.');
                    }
                    return Column(
                      children: [
                        for (final r in recs) _RecapadoTile(r: r),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                const _SeccionTitulo('Histórico de controles'),
                StreamBuilder<List<CubiertaControl>>(
                  stream: service.streamControlesPorCubierta(cubiertaId),
                  builder: (ctx, snap) {
                    final ctrls = snap.data ?? const <CubiertaControl>[];
                    if (ctrls.isEmpty) {
                      return const _Vacio('Sin controles registrados.');
                    }
                    return Column(
                      children: [
                        for (final c in ctrls) _ControlTile(c: c),
                      ],
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// =============================================================================
// IDENTIDAD
// =============================================================================

class _Identidad extends StatelessWidget {
  final Cubierta c;
  const _Identidad({required this.c});

  @override
  Widget build(BuildContext context) {
    final colorEstado = _colorPorEstado(c.estado);
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colorEstado.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colorEstado),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.tire_repair, color: colorEstado, size: 28),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.codigo,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      c.modeloEtiqueta,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Pill(c.estado.codigo, color: colorEstado),
              _Pill(c.tipoUso.etiqueta.toUpperCase(),
                  color: c.tipoUso == TipoUsoCubierta.direccion
                      ? AppColors.warning
                      : AppColors.accentBlue),
              _Pill(c.vidas == 1 ? 'NUEVA' : 'V${c.vidas}',
                  color: AppColors.accentTeal),
              _Pill(
                '${AppFormatters.formatearMiles(c.kmAcumulados)} km totales',
                color: Colors.white54,
              ),
              if (c.precioCompra != null && c.precioCompra! > 0)
                _Pill(
                  'Compra: \$${AppFormatters.formatearMonto(c.precioCompra)}',
                  color: AppColors.accentBlue,
                ),
              if (c.precioCompra != null &&
                  c.precioCompra! > 0 &&
                  c.kmAcumulados > 0)
                _Pill(
                  '\$${AppFormatters.formatearMonto(c.precioCompra! / c.kmAcumulados)} / km',
                  color: AppColors.success,
                ),
            ],
          ),
          if (c.observaciones != null && c.observaciones!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                c.observaciones!,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static Color _colorPorEstado(EstadoCubierta e) {
    switch (e) {
      case EstadoCubierta.enDeposito:
        return AppColors.accentBlue;
      case EstadoCubierta.instalada:
        return AppColors.success;
      case EstadoCubierta.enRecapado:
        return AppColors.accentTeal;
      case EstadoCubierta.descartada:
        return AppColors.error;
    }
  }
}

// =============================================================================
// HISTORIAL — TILES
// =============================================================================

class _InstalacionTile extends StatelessWidget {
  final CubiertaInstalada i;
  const _InstalacionTile({required this.i});

  @override
  Widget build(BuildContext context) {
    final pos = i.posicionTipada;
    final etiquetaPos = pos?.etiqueta ?? i.posicion;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: i.esActiva
              ? AppColors.success
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                i.esActiva ? Icons.bolt : Icons.history,
                size: 16,
                color: i.esActiva
                    ? AppColors.success
                    : Colors.white60,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${i.unidadId} · $etiquetaPos',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (i.esActiva)
                const _Pill('ACTIVA', color: AppColors.success),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            i.hasta == null
                ? 'Desde ${AppFormatters.formatearFecha(i.desde)}'
                : '${AppFormatters.formatearFecha(i.desde)} → ${AppFormatters.formatearFecha(i.hasta!)}',
            style: const TextStyle(color: Colors.white60, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text('${i.diasDuracion()} días',
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 11)),
              if (i.kmRecorridos != null)
                Text(
                  '${AppFormatters.formatearMiles(i.kmRecorridos)} km',
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 11),
                )
              else if (i.unidadTipo == TipoUnidadCubierta.enganche &&
                  !i.esActiva)
                const Text(
                  'km enganche pendiente (Fase 2)',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              Text(
                'Vida ${i.vidaAlInstalar}',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
          if (i.motivo != null && i.motivo!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Motivo: ${i.motivo}',
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecapadoTile extends StatelessWidget {
  final CubiertaRecapado r;
  const _RecapadoTile({required this.r});

  @override
  Widget build(BuildContext context) {
    final cerrado = r.fechaRetorno != null;
    final color = !cerrado
        ? AppColors.accentTeal
        : r.resultado == ResultadoRecapado.recibida
            ? AppColors.success
            : AppColors.error;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.swap_horiz_outlined, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  r.proveedor,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _Pill(
                !cerrado
                    ? 'EN PROCESO'
                    : r.resultado == ResultadoRecapado.recibida
                        ? 'RECIBIDA'
                        : 'DESCARTADA POR PROVEEDOR',
                color: color,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            cerrado
                ? '${AppFormatters.formatearFecha(r.fechaEnvio)} → ${AppFormatters.formatearFecha(r.fechaRetorno!)} (${r.diasEnRecapado()} días)'
                : 'Enviada ${AppFormatters.formatearFecha(r.fechaEnvio)} (${r.diasEnRecapado()} días)',
            style: const TextStyle(color: Colors.white60, fontSize: 11),
          ),
          if (r.costo != null) ...[
            const SizedBox(height: 4),
            Text(
              'Costo: \$${AppFormatters.formatearMonto(r.costo)}',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
          if (r.notas != null && r.notas!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              r.notas!,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ControlTile extends StatelessWidget {
  final CubiertaControl c;
  const _ControlTile({required this.c});

  @override
  Widget build(BuildContext context) {
    final pos = posicionPorCodigo[c.posicion];
    final etiquetaPos = pos?.etiqueta ?? c.posicion;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: AppColors.accentTeal.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.compress, size: 16, color: AppColors.accentTeal),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  AppFormatters.formatearFechaHoraSinSegundos(c.fecha),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${c.unidadId} · $etiquetaPos',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              if (c.presionPsi != null)
                Text(
                  'Presión: ${c.presionPsi} PSI',
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              if (c.profundidadBandaMm != null)
                Text(
                  'Banda: ${c.profundidadBandaMm!.toStringAsFixed(1)} mm',
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12),
                ),
            ],
          ),
          if (c.registradoPorNombre != null &&
              c.registradoPorNombre!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Registrado por ${c.registradoPorNombre}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// HELPERS
// =============================================================================

class _SeccionTitulo extends StatelessWidget {
  final String texto;
  const _SeccionTitulo(this.texto);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        texto.toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

class _Vacio extends StatelessWidget {
  final String texto;
  const _Vacio(this.texto);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        texto,
        style: const TextStyle(color: Colors.white38, fontSize: 12),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String texto;
  final Color color;
  const _Pill(this.texto, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        texto,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
