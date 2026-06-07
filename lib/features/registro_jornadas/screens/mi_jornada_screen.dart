import 'package:flutter/material.dart';

import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/registro_jornada.dart';
import '../services/registro_jornada_service.dart';

/// "Mi jornada" — el chofer ve su propio registro de jornada (v3): por cada
/// turno, el manejo neto, las pausas con su motivo (motor apagado / detenido),
/// los km recorridos y la confianza del dato. Transparencia: el chofer puede
/// revisar y entender qué registró el sistema (Paso 2 del plan vigilador v3).
///
/// Lee `REGISTRO_JORNADAS` filtrado a su propio DNI (la regla de Firestore se
/// lo permite). Solo lectura.
class MiJornadaScreen extends StatelessWidget {
  const MiJornadaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dni = PrefsService.dni;
    return AppScaffold(
      title: 'Mi jornada',
      body: StreamBuilder<List<RegistroJornada>>(
        stream: RegistroJornadaService.streamUltimasDelChofer(choferDni: dni),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return const AppErrorState(
              title: 'No se pudo cargar tu jornada',
              subtitle: 'Probá de nuevo en un rato.',
            );
          }
          if (!snap.hasData) {
            return const AppLoadingState(message: 'Cargando tu jornada…');
          }
          final jornadas = snap.data!;
          if (jornadas.isEmpty) {
            return const AppEmptyState(
              icon: Icons.route_outlined,
              title: 'Todavía no hay jornadas registradas',
              subtitle: 'Tu jornada del día queda registrada a la mañana '
                  'siguiente.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: jornadas.length + 1,
            separatorBuilder: (_, __) =>
                const SizedBox(height: AppSpacing.md),
            itemBuilder: (ctx, i) {
              if (i == 0) return const _Intro();
              return _JornadaCard(j: jornadas[i - 1]);
            },
          );
        },
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs, left: 2, right: 2),
      child: Text(
        'Acá ves cómo quedó registrada tu jornada cada día: tus horas de '
        'manejo y tus paradas. Si algo no coincide, avisale al encargado.',
        style: AppType.label.copyWith(color: c.textMuted),
      ),
    );
  }
}

class _JornadaCard extends StatelessWidget {
  final RegistroJornada j;
  const _JornadaCard({required this.j});

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
                    text: 'Manejaste +4 h sin parar',
                    color: c.error,
                    size: AppBadgeSize.sm,
                    icon: Icons.error_outline,
                  ),
                if (j.descansoInsuficiente && j.descansoPrevioSeg != null)
                  AppBadge(
                    text: 'Descanso previo ${_hm(j.descansoPrevioSeg!)}',
                    color: c.warning,
                    size: AppBadgeSize.sm,
                  ),
                if (j.driftFiltrado)
                  AppBadge(
                    text: 'Aparecés en 2 unidades',
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
