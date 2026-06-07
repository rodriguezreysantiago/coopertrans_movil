import 'package:flutter/material.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/registro_jornada.dart';

/// Card de un turno del registro de jornada v3. Compartida por la pantalla
/// "Mi jornada" (chofer) y la vista admin del registro (Paso 4). Muestra:
/// fecha + confianza, turno inicio→fin + patente, métricas (manejo/recorrido/
/// pausas/bloques), flags (>12h, bloque >4h, descanso <8h, drift) y las pausas
/// con su motivo.
class RegistroJornadaCard extends StatelessWidget {
  final RegistroJornada j;
  const RegistroJornadaCard({super.key, required this.j});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cabecera: fecha + confianza.
          Row(
            children: [
              Expanded(
                child: Text(
                  _fechaLabel(j.fecha, j.inicioTurno),
                  style: AppType.heading,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppBadge(
                text: 'Datos ${j.confianza}',
                color: _confColor(c, j.confianza),
                size: AppBadgeSize.sm,
                dot: true,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${_hora(j.inicioTurno)} → ${_hora(j.finTurno)}'
            '${j.patente != null ? ' · ${j.patente}' : ''}',
            style: AppType.label.copyWith(color: c.textMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.md),

          // Métricas.
          Row(
            children: [
              _metric(c, 'Manejo', _hm(j.manejoNetoSeg)),
              _metric(c, 'Recorrido', '${j.recorridoKm} km'),
              _metric(c, 'Pausas', '${j.pausas.length}'),
              _metric(c, 'Bloques', '${j.bloquesCount}'),
            ],
          ),

          // Flags (solo si hay algo que marcar).
          if (_tieneFlags) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (j.jornadaExcedida)
                  AppBadge(
                    text: 'Más de 12 h de manejo',
                    color: c.warning,
                    size: AppBadgeSize.sm,
                    icon: Icons.warning_amber_rounded,
                  ),
                if (j.bloquesExcedidos > 0)
                  AppBadge(
                    text: 'Manejó +4 h sin parar',
                    color: c.error,
                    size: AppBadgeSize.sm,
                    icon: Icons.error_outline,
                  ),
                if (j.vedaExcedida)
                  AppBadge(
                    text: 'Manejó de noche (00–06)',
                    color: c.warning,
                    size: AppBadgeSize.sm,
                    icon: Icons.nightlight_outlined,
                  ),
                if (j.descansoInsuficiente && j.descansoPrevioSeg != null)
                  AppBadge(
                    text: 'Descanso previo ${_hm(j.descansoPrevioSeg!)}',
                    color: c.warning,
                    size: AppBadgeSize.sm,
                  ),
                if (j.driftFiltrado)
                  AppBadge(
                    text: 'Aparece en 2 unidades',
                    color: c.info,
                    size: AppBadgeSize.sm,
                  ),
              ],
            ),
          ],

          // Pausas.
          if (j.pausas.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text('Paradas',
                style: AppType.eyebrow.copyWith(color: c.textMuted)),
            const SizedBox(height: AppSpacing.sm),
            for (final p in j.pausas) _pausaRow(c, p),
          ],
        ],
      ),
    );
  }

  bool get _tieneFlags =>
      j.jornadaExcedida ||
      j.bloquesExcedidos > 0 ||
      j.descansoInsuficiente ||
      j.vedaExcedida ||
      j.driftFiltrado;

  Widget _metric(AppColorsExt c, String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: AppType.eyebrow.copyWith(color: c.textMuted)),
          const SizedBox(height: 4),
          Text(value,
              style: AppType.heading,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _pausaRow(AppColorsExt c, PausaJornada p) {
    final cierra = p.cierraBloque;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: cierra ? c.success : c.textMuted,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '${_hora(p.inicio)}–${_hora(p.fin)} · ${_hm(p.durSeg)} · '
              '${p.motivo}',
              style: AppType.label.copyWith(color: c.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (cierra) ...[
            const SizedBox(width: AppSpacing.sm),
            Text('descanso OK',
                style: AppType.monoSm.copyWith(color: c.success)),
          ],
        ],
      ),
    );
  }

  // ── Formato ──────────────────────────────────────────────────────────
  Color _confColor(AppColorsExt c, String conf) {
    switch (conf) {
      case 'alta':
        return c.success;
      case 'media':
        return c.warning;
      default:
        return c.error;
    }
  }

  String _hora(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  String _hm(int seg) {
    final h = seg ~/ 3600;
    final m = (seg % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '$m min';
  }

  static const _dias = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];

  String _fechaLabel(String ymd, DateTime inicio) {
    DateTime? d = DateTime.tryParse(ymd);
    d ??= inicio;
    final dia = _dias[(d.weekday - 1).clamp(0, 6)];
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dia $dd-$mm';
  }
}
