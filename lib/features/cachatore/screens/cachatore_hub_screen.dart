import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/cachatore_chequeo.dart';
import '../models/cachatore_config.dart';
import '../models/cachatore_estado_bot.dart';
import '../models/cachatore_objetivo.dart';
import '../models/cachatore_turno.dart';
import '../models/franja_carga.dart';
import '../services/cachatore_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Panel de control del bot que reserva/reagenda turnos de carga YPF en
/// iTurnos (corre 24/7 en la PC dedicada). Flujo:
///   1. Agregar: elegir chofer → fecha (calendario) → franja → "Vigilados".
///   2. Cuando el bot saca el turno, el chofer pasa solo a "Turnos concretados".
///   3. Tocar un turno concretado → Reagendar (nueva fecha + franja).
/// Todo va por Firestore: la app escribe la selección, el bot la lee y devuelve
/// el estado en vivo.
///
/// REFACTOR NÚCLEO (jun 2026): mismo layout que el hub del Bot WhatsApp
/// (`admin_estado_bot_screen.dart`) — header eyebrow + hero number,
/// `AppKpiStrip` con 4 métricas reales, bloque de estado del servicio con
/// `AppServiceCard` (el interruptor maestro vive dentro), y luego las
/// secciones de vigilados / concretados re-skineadas a tokens. La capa de
/// datos NO cambia: los streams (`streamEstado` / `streamConfig` /
/// `streamObjetivos` / `streamTurnos`), los services y las acciones
/// (agregar / editar / pausar / reagendar / cancelar / chequeo) quedan
/// intactos — sólo cambia el árbol de widgets.
class CachatoreHubScreen extends StatelessWidget {
  const CachatoreHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Cachatore — Turnos YPF',
      // El estado del bot + KPIs + interruptor viven arriba combinando los
      // 3 streams (estado/config/objetivos/turnos) en un solo árbol, así el
      // hero, el KpiStrip y la AppServiceCard leen data consistente. Las
      // secciones de abajo mantienen sus propios StreamBuilder.
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        children: const [
          _CabeceraEstado(),
          SizedBox(height: AppSpacing.lg),
          _SeccionVigilados(),
          SizedBox(height: AppSpacing.xl),
          _SeccionConcretados(),
          SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }
}

String _haceCuanto(DateTime? t) {
  if (t == null) return 'nunca';
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 5) return 'recién';
  if (s < 60) return 'hace ${s}s';
  final m = s ~/ 60;
  if (m < 60) return 'hace $m min';
  final h = m ~/ 60;
  if (h < 24) return 'hace $h h';
  return 'hace ${h ~/ 24} d';
}

// ───────────────────────────────────────────────────────────────────────
// Cabecera: header (eyebrow + hero) + AppKpiStrip + AppServiceCard con el
// interruptor maestro. Combina los streams de estado/config/objetivos/turnos
// para que las métricas sean consistentes entre sí.
// ───────────────────────────────────────────────────────────────────────
class _CabeceraEstado extends StatelessWidget {
  const _CabeceraEstado();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CachatoreEstadoBot>(
      stream: CachatoreService.streamEstado(),
      builder: (ctx, snapEstado) {
        final e = snapEstado.data ?? const CachatoreEstadoBot();
        return StreamBuilder<List<CachatoreObjetivo>>(
          stream: CachatoreService.streamObjetivos(),
          builder: (ctx2, snapObj) {
            final objetivos = snapObj.data ?? const <CachatoreObjetivo>[];
            return StreamBuilder<List<CachatoreTurno>>(
              stream: CachatoreService.streamTurnos(),
              builder: (ctx3, snapTurnos) {
                final turnos = snapTurnos.data ?? const <CachatoreTurno>[];
                final vigilados =
                    objetivos.where((o) => !o.tieneTurno).length;
                // Reagendar pendiente = el flag `reagendar` del objetivo (la app
                // lo prende, el bot lo apaga al mover el turno). NO condicionar
                // por estado: un pedido NUEVO de reagendar sobre un chofer cuyo
                // estado quedó "reagendado" de un movimiento anterior debe
                // contarse igual (si no, el KPI lo oculta — bug AVIT 2026-06-04).
                final reagendando =
                    objetivos.where((o) => o.reagendar).length;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(turnos: turnos.length, estado: e),
                    const SizedBox(height: AppSpacing.md),
                    _KpiStrip(
                      vigilados: vigilados,
                      conTurno: turnos.length,
                      reagendando: reagendando,
                      estado: e,
                    ),
                    const SizedBox(height: AppSpacing.mdDense),
                    _ServicioCard(estado: e),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final int turnos;
  final CachatoreEstadoBot estado;
  const _Header({required this.turnos, required this.estado});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hayEstado = estado.ultimoTickEn != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppEyebrow('Cachatore'),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      hayEstado ? '$turnos' : '—',
                      style: AppType.h2.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        'turnos concretados',
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiStrip extends StatelessWidget {
  final int vigilados;
  final int conTurno;
  final int reagendando;
  final CachatoreEstadoBot estado;

  const _KpiStrip({
    required this.vigilados,
    required this.conTurno,
    required this.reagendando,
    required this.estado,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hayEstado = estado.ultimoTickEn != null;
    return AppKpiStrip(
      stats: [
        AppStat(
          label: 'Vigilados',
          value: hayEstado ? '$vigilados' : '—',
          accent: vigilados > 0 ? c.warning : null,
        ),
        AppStat(
          label: 'Con turno',
          value: hayEstado ? '$conTurno' : '—',
          accent: conTurno > 0 ? c.success : null,
        ),
        AppStat(
          label: 'Reagendar',
          value: hayEstado ? '$reagendando' : '—',
          accent: reagendando > 0 ? c.warning : null,
        ),
        AppStat(
          label: 'Latido',
          value: estado.ultimoTickEn == null
              ? '—'
              : _haceCuanto(estado.ultimoTickEn).replaceFirst('hace ', ''),
          valueStyle: AppType.h4,
          accent: estado.vivo ? c.success : c.error,
        ),
      ],
    );
  }
}

/// Bloque de estado del servicio + interruptor maestro, unificado con
/// `AppServiceCard` (mismo widget que el hub del Bot WhatsApp). El subtítulo
/// mono resume modo / latido / con-turno; el status pasa a ok (glow) cuando
/// el bot late y está prendido, warning cuando late pero está pausado, error
/// cuando no late. El interruptor maestro va como `children`.
class _ServicioCard extends StatelessWidget {
  final CachatoreEstadoBot estado;
  const _ServicioCard({required this.estado});

  @override
  Widget build(BuildContext context) {
    final e = estado;
    final vivo = e.vivo;
    final status = !vivo
        ? AppServiceStatus.error('Sin responder')
        : (e.pausado
            ? AppServiceStatus.warning('Pausado')
            : AppServiceStatus.ok('Activo'));
    final subtitle = !vivo
        ? 'no late · ${_haceCuanto(e.ultimoTickEn)}'
        : 'modo ${e.modo.isEmpty ? '—' : e.modo} · '
            '${e.conTurno}/${e.total} con turno · '
            '${_haceCuanto(e.ultimoTickEn)}';
    return AppServiceCard(
      name: 'Cachatore',
      subtitle: subtitle,
      status: status,
      icon: Icons.event_repeat_outlined,
      glow: vivo && !e.pausado,
      children: [
        if (!vivo) ...[
          _NotaFalla(
            texto: 'El bot no late hace ${_haceCuanto(e.ultimoTickEn)}. '
                'Revisá que esté prendido en la PC dedicada.',
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        const _MasterSwitch(),
      ],
    );
  }
}

class _NotaFalla extends StatelessWidget {
  final String texto;
  const _NotaFalla({required this.texto});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: c.errorSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: c.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined, size: 20, color: c.error),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              texto,
              style: AppType.label.copyWith(color: c.error),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Interruptor maestro (encendido/pausado) — vive dentro de la AppServiceCard.
// ───────────────────────────────────────────────────────────────────────
class _MasterSwitch extends StatelessWidget {
  const _MasterSwitch();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<CachatoreConfig>(
      stream: CachatoreService.streamConfig(),
      builder: (ctx, snap) {
        final cfg = snap.data ?? const CachatoreConfig();
        return Container(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
          decoration: BoxDecoration(
            color: c.surface3,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              Icon(
                cfg.activo
                    ? Icons.power_settings_new
                    : Icons.pause_circle_outline,
                size: 20,
                color: cfg.activo ? c.success : c.textMuted,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bot encendido',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.label.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      cfg.activo
                          ? 'Buscando turnos para los choferes vigilados'
                          : 'Pausado — no reserva ni reagenda nada',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.label.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              Switch(
                value: cfg.activo,
                activeThumbColor: c.success,
                onChanged: (v) => CachatoreService.setActivo(v),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Sección: choferes vigilados (todavía sin turno)
// ───────────────────────────────────────────────────────────────────────
class _SeccionVigilados extends StatelessWidget {
  const _SeccionVigilados();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<List<CachatoreObjetivo>>(
      stream: CachatoreService.streamObjetivos(),
      builder: (ctx, snap) {
        final todos = snap.data ?? const <CachatoreObjetivo>[];
        // Vigilados = los que el bot todavía está intentando conseguir turno.
        final vigilados = todos.where((o) => !o.tieneTurno).toList();
        final yaAgregados = todos.map((e) => e.dni).toSet();
        final cargando = snap.connectionState == ConnectionState.waiting;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: AppEyebrow('Choferes vigilados · ${vigilados.length}'),
                ),
                AppButton.primary(
                  label: 'Agregar',
                  icon: Icons.add,
                  size: AppButtonSize.sm,
                  onPressed: () => _abrirWizard(
                    context,
                    titulo: 'Agregar chofer',
                    yaAgregados: yaAgregados,
                    onConfirm: (dni, nombre, fecha, franja) =>
                        CachatoreService.agregarObjetivo(
                      dni: dni,
                      nombre: nombre,
                      fecha: fecha,
                      franja: franja,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (cargando)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
                child: AppLoadingState(),
              )
            else if (vigilados.isEmpty)
              AppCard(
                tier: 1,
                child: Column(
                  children: [
                    Icon(Icons.person_search_outlined,
                        color: c.textMuted, size: 36),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Sin choferes vigilados',
                      style: AppType.body.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Tocá "Agregar": elegís chofer, fecha y franja, y el bot le '
                      'busca turno.',
                      textAlign: TextAlign.center,
                      style: AppType.label.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              )
            else
              ...vigilados.map((o) => _VigiladoCard(objetivo: o)),
          ],
        );
      },
    );
  }
}

class _VigiladoCard extends StatelessWidget {
  final CachatoreObjetivo objetivo;
  const _VigiladoCard({required this.objetivo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final o = objetivo;
    return AppCard(
      tier: 1,
      child: Opacity(
        opacity: o.activo ? 1.0 : 0.55,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        o.nombre ?? o.dni,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.body.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Row(
                        children: [
                          Icon(Icons.event_outlined,
                              size: 20, color: c.textSecondary),
                          const SizedBox(width: AppSpacing.xs),
                          Expanded(
                            child: Text(
                              o.objetivoLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.label
                                  .copyWith(color: c.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _EstadoBadge(objetivo: o),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AppButton.ghost(
                  label: 'Fecha/franja',
                  icon: Icons.edit_calendar_outlined,
                  size: AppButtonSize.sm,
                  onPressed: () => _editar(context, o),
                ),
                IconButton(
                  tooltip: o.activo ? 'Pausar este chofer' : 'Reanudar',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: Icon(
                    o.activo
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                    color: o.activo ? c.textMuted : c.success,
                  ),
                  onPressed: () =>
                      CachatoreService.setObjetivoActivo(o.dni, !o.activo),
                ),
                IconButton(
                  tooltip: 'Quitar de la lista',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: Icon(Icons.delete_outline, color: c.error),
                  onPressed: () => _confirmarBorrar(context, o),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editar(BuildContext context, CachatoreObjetivo o) {
    return _abrirWizard(
      context,
      titulo: 'Editar ${o.nombre ?? o.dni}',
      dniFijo: o.dni,
      nombreFijo: o.nombre,
      fechaInicial: o.fecha,
      franjaInicial: o.franja,
      onConfirm: (_, __, fecha, franja) =>
          CachatoreService.editarObjetivo(dni: o.dni, fecha: fecha, franja: franja),
    );
  }

  Future<void> _confirmarBorrar(BuildContext context, CachatoreObjetivo o) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Quitar chofer'),
        content: Text('El bot deja de buscarle turno a ${o.nombre ?? o.dni}.'),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.pop(context, false),
          ),
          AppButton.danger(
            label: 'Quitar',
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (ok == true) await CachatoreService.eliminarObjetivo(o.dni);
  }
}

// ───────────────────────────────────────────────────────────────────────
// Sección: turnos concretados (ya tienen turno)
// ───────────────────────────────────────────────────────────────────────
class _SeccionConcretados extends StatelessWidget {
  const _SeccionConcretados();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<List<CachatoreTurno>>(
      stream: CachatoreService.streamTurnos(),
      builder: (ctx, snap) {
        final turnos = snap.data ?? const <CachatoreTurno>[];
        return StreamBuilder<List<CachatoreObjetivo>>(
          stream: CachatoreService.streamObjetivos(),
          builder: (ctx2, snapObj) {
            // Mapa dni -> objetivo: la info de reagendar (flag + fecha/franja
            // objetivo) vive en el objetivo, no en el turno. La cruzamos para
            // que la card del turno muestre si está en reagendar pendiente.
            final objetivos = <String, CachatoreObjetivo>{
              for (final o in (snapObj.data ?? const <CachatoreObjetivo>[]))
                o.dni: o,
            };
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppEyebrow('Turnos concretados · ${turnos.length}'),
                const SizedBox(height: AppSpacing.sm),
                if (turnos.isEmpty)
                  AppCard(
                    tier: 1,
                    child: Text(
                      'No hay turnos sacados.',
                      style: AppType.label.copyWith(color: c.textSecondary),
                    ),
                  )
                else
                  ...turnos.map((t) =>
                      _ConcretadoCard(turno: t, objetivo: objetivos[t.dni])),
              ],
            );
          },
        );
      },
    );
  }
}

class _ConcretadoCard extends StatelessWidget {
  final CachatoreTurno turno;
  final CachatoreObjetivo? objetivo;
  const _ConcretadoCard({required this.turno, this.objetivo});

  /// `true` si el chofer está marcado para reagendar (flag `reagendar` del
  /// objetivo, que el bot apaga al mover el turno). NO se condiciona por estado:
  /// un pedido nuevo sobre un chofer cuyo estado quedó "reagendado" de un
  /// movimiento anterior debe verse igual (bug AVIT 2026-06-04).
  bool get _reagendarPendiente =>
      objetivo != null && objetivo!.reagendar;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = turno;
    final cuando = (t.cuando ?? '').isNotEmpty
        ? t.cuando!
        : 'Turno${t.hora != null ? ' ${t.hora}' : ''}';
    final reag = _reagendarPendiente;
    final acento = reag ? c.warning : c.success;
    return AppCard(
      tier: 1,
      onTap: () => _abrirMenu(context),
      accent: acento,
      child: Row(
        children: [
          Icon(reag ? Icons.event_repeat_outlined : Icons.event_available_outlined,
              color: acento, size: 20),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.nombre ?? t.dni,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  reag ? 'Turno actual: $cuando' : cuando,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.label.copyWith(
                    color: reag ? c.textSecondary : c.success,
                  ),
                ),
                if (reag) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Icon(Icons.sync_outlined, size: 20, color: c.warning),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          'Buscando reagendar a ${objetivo!.objetivoLabel}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.label.copyWith(
                            color: c.warning,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: AppButton.ghost(
                      label: 'Cancelar reagendar',
                      icon: Icons.cancel_outlined,
                      size: AppButtonSize.sm,
                      onPressed: () => _cancelarReagendar(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(Icons.more_vert, color: c.textMuted, size: 18),
        ],
      ),
    );
  }

  Future<void> _reagendar(BuildContext context) {
    return _abrirWizard(
      context,
      titulo: 'Reagendar ${turno.nombre ?? turno.dni}',
      dniFijo: turno.dni,
      nombreFijo: turno.nombre,
      onConfirm: (_, __, fecha, franja) => CachatoreService.reagendarObjetivo(
          dni: turno.dni, fecha: fecha, franja: franja),
    );
  }

  Future<void> _cancelarReagendar(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancelar reagendar'),
        content: Text(
          'El bot deja de buscarle un horario mejor a '
          '${turno.nombre ?? turno.dni} y le mantiene el turno actual.',
        ),
        actions: [
          AppButton.ghost(
            label: 'No',
            onPressed: () => Navigator.pop(context, false),
          ),
          AppButton(
            label: 'Sí, cancelar',
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (ok == true) await CachatoreService.cancelarReagendar(turno.dni);
  }

  /// Menú al tocar la card: Reagendar o Cancelar turno.
  void _abrirMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xs),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(turno.nombre ?? turno.dni, style: AppType.heading),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.event_repeat_outlined,
                  color: AppColors.textSecondary, size: 20),
              title: const Text('Reagendar'),
              subtitle: const Text('Mover el turno a otra fecha/franja', style: AppType.label),
              onTap: () {
                Navigator.pop(context);
                _reagendar(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: AppColors.error, size: 20),
              title: const Text('Cancelar turno',
                  style: TextStyle(color: AppColors.error)),
              subtitle: const Text('Lo cancela también en iTurnos (libera el cupo)',
                  style: AppType.label),
              onTap: () {
                Navigator.pop(context);
                _confirmarCancelarTurno(context);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmarCancelarTurno(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancelar turno'),
        content: Text(
          'Se va a CANCELAR el turno de ${turno.nombre ?? turno.dni}'
          "${(turno.cuando ?? '').isNotEmpty ? ' (${turno.cuando})' : ''} "
          'también en iTurnos. El cupo queda libre y no se puede deshacer.',
        ),
        actions: [
          AppButton.ghost(
            label: 'No',
            onPressed: () => Navigator.pop(context, false),
          ),
          AppButton.danger(
            label: 'Sí, cancelar turno',
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (ok == true) {
      await CachatoreService.cancelarTurno(turno.dni);
      messenger.showSnackBar(const SnackBar(
          content: Text('Cancelando turno en iTurnos…')));
    }
  }
}

class _EstadoBadge extends StatelessWidget {
  final CachatoreObjetivo objetivo;
  const _EstadoBadge({required this.objetivo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final est = objetivo.estado;
    final Color color;
    if (est.esOk) {
      color = c.success;
    } else if (est.esError) {
      color = c.error;
    } else if (est.esWarn) {
      color = c.warning;
    } else {
      color = c.info;
    }
    return AppBadge(
      text: est.etiqueta,
      color: color,
      size: AppBadgeSize.sm,
      dot: true,
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Wizard: chofer (opcional) → fecha (calendario) → franja
// ───────────────────────────────────────────────────────────────────────
Future<void> _abrirWizard(
  BuildContext context, {
  required String titulo,
  required Future<void> Function(
          String dni, String nombre, String? fecha, FranjaCarga franja)
      onConfirm,
  String? dniFijo,
  String? nombreFijo,
  String? fechaInicial,
  FranjaCarga? franjaInicial,
  Set<String> yaAgregados = const {},
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface2,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (_) => _WizardSheet(
      titulo: titulo,
      onConfirm: onConfirm,
      dniFijo: dniFijo,
      nombreFijo: nombreFijo,
      fechaInicial: fechaInicial,
      franjaInicial: franjaInicial,
      yaAgregados: yaAgregados,
    ),
  );
}

class _WizardSheet extends StatefulWidget {
  final String titulo;
  final Future<void> Function(
      String dni, String nombre, String? fecha, FranjaCarga franja) onConfirm;
  final String? dniFijo;
  final String? nombreFijo;
  final String? fechaInicial;
  final FranjaCarga? franjaInicial;
  final Set<String> yaAgregados;

  const _WizardSheet({
    required this.titulo,
    required this.onConfirm,
    this.dniFijo,
    this.nombreFijo,
    this.fechaInicial,
    this.franjaInicial,
    this.yaAgregados = const {},
  });

  @override
  State<_WizardSheet> createState() => _WizardSheetState();
}

class _WizardSheetState extends State<_WizardSheet> {
  // pasos: 0=chofer, 1=fecha, 2=franja
  late int _paso;
  late int _pasoInicial;
  String? _dni;
  String? _nombre;
  String? _fecha; // ISO AAAA-MM-DD o null=cualquiera
  String _filtro = '';
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    _dni = widget.dniFijo;
    _nombre = widget.nombreFijo;
    _fecha = widget.fechaInicial;
    _pasoInicial = widget.dniFijo != null ? 1 : 0;
    _paso = _pasoInicial;
  }

  static final RegExp _reIso = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  String get _fechaLabel {
    final f = (_fecha ?? '').trim();
    if (!_reIso.hasMatch(f)) return 'Cualquier fecha';
    final d = DateTime.tryParse(f);
    if (d == null) return f;
    return '${d.day.toString().padLeft(2, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-${d.year}';
  }

  Future<void> _confirmar(FranjaCarga franja) async {
    if (_dni == null || _guardando) return;
    // Capturar antes del await (no usar context tras async gap).
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _guardando = true);
    try {
      await widget.onConfirm(_dni!, _nombre ?? _dni!, _fecha, franja);
      if (mounted) navigator.pop();
    } catch (e) {
      // Sin esto, si onConfirm (escritura a Firestore) fallaba, _guardando
      // quedaba en true para siempre: spinner infinito + botones
      // deshabilitados, y el operador no sabía qué pasó. Auditoría 2026-05-22.
      if (mounted) setState(() => _guardando = false);
      messenger.showSnackBar(
        SnackBar(content: Text('No se pudo guardar: $e')),
      );
    }
  }

  /// Pide al bot que verifique si el chofer (que NO está en CACHATORE_OBJETIVOS)
  /// tiene un turno preexistente sacado por la web de iTurnos. Muestra dialog
  /// con spinner mientras el bot procesa (~3-10 s típico, hasta 30 s timeout).
  ///
  /// Si tiene turno → cierra el wizard (el chofer va a aparecer solo en
  /// "Turnos concretados" por el StreamBuilder de TURNOS).
  /// Si no tiene → cierra el dialog (queda el wizard abierto para que el
  /// operador siga con el flujo normal de "vigilar" si quiere).
  /// Si error → snackbar con el detalle del bot.
  Future<void> _verificarTurnoExistente(String dni, String nombre) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // 1) Pedir el chequeo (escribe el doc en CACHATORE_CHEQUEOS).
    try {
      await CachatoreService.pedirChequeo(dni: dni, nombre: nombre);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text('No se pudo pedir el chequeo: $e')));
      return;
    }
    if (!mounted) return;

    // 2) Abrir dialog con spinner; suscribe al stream del doc; cuando llega
    //    `resultado`, lo procesa y cierra el dialog devolviendo el resultado.
    final res = await showDialog<CachatoreChequeo>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return _ChequeoDialog(dni: dni, nombre: nombre);
      },
    );

    if (!mounted || res == null) {
      // Operador canceló desde el dialog → borrar el chequeo para no dejar
      // huérfano (el bot lo limpia igual tras 120 s, pero mejor proactivo).
      // Si la cancelación fue por timeout, _ChequeoDialog ya devolvió un
      // resultado de error y NO entra acá.
      unawaited(CachatoreService.borrarChequeo(dni));
      return;
    }

    // 3) Limpiar el doc (el resultado ya lo leímos).
    unawaited(CachatoreService.borrarChequeo(dni));

    // 4) Reaccionar según el resultado.
    switch (res.resultado) {
      case CachatoreChequeoResultado.conTurno:
        // El bot publicó el TURNO en CACHATORE_TURNOS + creó OBJETIVO
        // 'detectado_externo'. Cierra el wizard — el chofer va a aparecer
        // automáticamente en "Turnos concretados" via StreamBuilder.
        navigator.pop();
        final cuando = (res.detalle ?? '').isNotEmpty
            ? res.detalle!
            : 'un turno preexistente';
        messenger.showSnackBar(SnackBar(
          backgroundColor: AppColors.success,
          content: Text('$nombre ya tenía $cuando. '
              'Lo dejé en "Turnos concretados".'),
          duration: const Duration(seconds: 5),
        ));
        break;
      case CachatoreChequeoResultado.sinTurno:
        // Queda el wizard abierto en paso 0: si el operador quiere igual
        // que el bot le busque turno, tappea el chofer y sigue el flujo.
        messenger.showSnackBar(SnackBar(
          content: Text(
              '$nombre no tiene turnos en iTurnos. Si querés que el bot le '
              'busque uno, tappealo y seguí los pasos.'),
          duration: const Duration(seconds: 5),
        ));
        break;
      case CachatoreChequeoResultado.error:
        messenger.showSnackBar(SnackBar(
          backgroundColor: AppColors.error,
          content: Text(
              'No pude verificar a $nombre: ${res.detalle ?? "error desconocido"}'),
          duration: const Duration(seconds: 6),
        ));
        break;
      case null:
        // No debería llegar acá (el dialog espera a resultado != null).
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final alto = MediaQuery.of(context).size.height * 0.78;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox(
        height: alto,
        child: Column(
          children: [
            _header(),
            const AppHairline(),
            Expanded(child: _cuerpo()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final c = context.colors;
    final pasos = ['Chofer', 'Fecha', 'Horario'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.md, AppSpacing.sm, AppSpacing.sm),
      child: Row(
        children: [
          if (_paso > _pasoInicial)
            IconButton(
              icon: Icon(Icons.arrow_back, size: 18, color: c.textMuted),
              onPressed: () => setState(() => _paso -= 1),
            )
          else
            const SizedBox(width: AppSpacing.xxxl),
          Expanded(
            child: Column(
              children: [
                Text(
                  widget.titulo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.heading,
                ),
                Text('Paso ${_paso + 1} de 3 · ${pasos[_paso]}',
                    style: AppType.eyebrow),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: c.textMuted),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    switch (_paso) {
      case 0:
        return _pasoChofer();
      case 1:
        return _pasoFecha();
      default:
        return _pasoFranja();
    }
  }

  // ── Paso 0: elegir chofer ──
  Widget _pasoChofer() {
    final c = context.colors;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: TextField(
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              hintText: 'Buscar chofer por nombre (ej. PEREZ)',
              prefixIcon: Icon(Icons.search, size: 20),
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _filtro = v.trim().toUpperCase()),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection(AppCollections.empleados)
                .where('ROL', isEqualTo: 'CHOFER')
                .snapshots(),
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const AppLoadingState();
              }
              final docs = snap.data!.docs.where((d) {
                final data = d.data();
                if (data['ACTIVO'] == false) return false;
                final n = (data['NOMBRE'] ?? '').toString().toUpperCase();
                return _filtro.isEmpty || n.contains(_filtro);
              }).toList()
                ..sort((a, b) => (a.data()['NOMBRE'] ?? '')
                    .toString()
                    .toUpperCase()
                    .compareTo(
                        (b.data()['NOMBRE'] ?? '').toString().toUpperCase()));
              if (docs.isEmpty) {
                return Center(
                  child: Text('Sin resultados',
                      style: AppType.label.copyWith(color: c.textSecondary)),
                );
              }
              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (ce, i) {
                  final data = docs[i].data();
                  final dni = (data['DNI'] ?? docs[i].id).toString();
                  final nombre = (data['NOMBRE'] ?? dni).toString();
                  final unidad = data['VEHICULO']?.toString();
                  final yaEsta = widget.yaAgregados.contains(dni);
                  return ListTile(
                    dense: true,
                    leading: Icon(Icons.person_outline,
                        size: 20, color: c.textSecondary),
                    title: Text(
                      nombre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body.copyWith(color: c.text),
                    ),
                    subtitle: Text(
                      'DNI $dni'
                      '${unidad != null && unidad.isNotEmpty ? ' · $unidad' : ''}'
                      '${yaEsta ? ' · ya en la lista' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.eyebrow.copyWith(
                        color: yaEsta ? c.warning : c.textMuted,
                      ),
                    ),
                    // Lupa = chequear iTurnos por turno preexistente sacado
                    // por la web (caso: un compañero sacó turno sin pasar por
                    // el bot). Chevron = elegir y seguir el wizard normal
                    // (fecha -> franja -> vigilar).
                    trailing: yaEsta
                        ? Icon(Icons.chevron_right,
                            size: 18, color: c.textMuted)
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip:
                                    'Verificar si ya tiene turno en iTurnos',
                                visualDensity: VisualDensity.compact,
                                splashRadius: 18,
                                iconSize: 18,
                                icon: Icon(Icons.manage_search,
                                    color: c.brand),
                                onPressed: () =>
                                    _verificarTurnoExistente(dni, nombre),
                              ),
                              Icon(Icons.chevron_right,
                                  size: 18, color: c.textMuted),
                            ],
                          ),
                    onTap: () => setState(() {
                      _dni = dni;
                      _nombre = nombre;
                      _paso = 1;
                    }),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Paso 1: elegir fecha ──
  Widget _pasoFecha() {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text(_nombre ?? _dni ?? '', style: AppType.heading),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '¿Para qué fecha buscamos el turno?',
          style: AppType.body.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: AppSpacing.lg),
        ListTile(
          leading: Icon(Icons.all_inclusive, size: 20, color: c.brand),
          title: const Text('Cualquier fecha'),
          subtitle: const Text(
            'Agarra el primero que se libere en el horario elegido',
            style: AppType.label,
          ),
          tileColor: c.surface3,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              side: BorderSide(color: c.border)),
          onTap: () => setState(() {
            _fecha = null;
            _paso = 2;
          }),
        ),
        const SizedBox(height: AppSpacing.md),
        ListTile(
          leading: Icon(Icons.calendar_month_outlined, size: 20, color: c.brand),
          title: Text(
            _reIso.hasMatch((_fecha ?? '').trim())
                ? 'Fecha: $_fechaLabel'
                : 'Elegir una fecha del calendario',
          ),
          subtitle: const Text('Solo turnos de ese día', style: AppType.label),
          tileColor: c.surface3,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              side: BorderSide(color: c.border)),
          onTap: _elegirDelCalendario,
        ),
      ],
    );
  }

  Future<void> _elegirDelCalendario() async {
    final hoy = DateTime.now();
    final base = DateTime(hoy.year, hoy.month, hoy.day);
    final actual = DateTime.tryParse((_fecha ?? '').trim());
    final r = await showDatePicker(
      context: context,
      initialDate: (actual != null && !actual.isBefore(base)) ? actual : base,
      firstDate: base,
      lastDate: base.add(const Duration(days: 90)),
      helpText: 'Fecha del turno a buscar',
    );
    if (r != null) {
      setState(() {
        _fecha = '${r.year}-${r.month.toString().padLeft(2, '0')}-'
            '${r.day.toString().padLeft(2, '0')}';
        _paso = 2;
      });
    }
  }

  // ── Paso 2: elegir franja (con los números) ──
  Widget _pasoFranja() {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text(
          '$_fechaLabel · ${_nombre ?? _dni ?? ''}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppType.body.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: AppSpacing.xs),
        const Text('Elegí el horario', style: AppType.heading),
        const SizedBox(height: AppSpacing.md),
        ...FranjaCarga.values.map((f) {
          final sel = f == widget.franjaInicial;
          final esC = f.esCualquiera;
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: ListTile(
              leading: esC
                  ? Icon(Icons.all_inclusive, size: 20, color: c.brand)
                  : null,
              tileColor: c.surface3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                side: BorderSide(
                    color: sel
                        ? c.brand.withValues(alpha: 0.6)
                        : c.border),
              ),
              // Comodin: mostramos la etiqueta arriba; las 4 franjas
              // muestran el rango horario arriba y la etiqueta abajo.
              title: Text(
                esC ? f.etiqueta : f.rango,
                style: AppType.heading,
              ),
              subtitle: Text(
                esC ? 'El primero que se libere, a cualquier hora' : f.etiqueta,
                style: AppType.label,
              ),
              trailing: _guardando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.chevron_right, size: 18, color: c.textMuted),
              onTap: _guardando ? null : () => _confirmar(f),
            ),
          );
        }),
      ],
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Dialog del chequeo one-shot (¿el chofer ya tiene turno por la web?)
// ───────────────────────────────────────────────────────────────────────
/// Spinner bloqueante mientras el bot procesa el pedido en CACHATORE_CHEQUEOS.
/// Se cierra solo cuando llega el `resultado` (Navigator.pop con el CachatoreChequeo),
/// o se autocierra con resultado de error si pasan 30 s sin respuesta (timeout
/// = bot caído / lento). El operador también puede cancelar con un botón.
class _ChequeoDialog extends StatefulWidget {
  final String dni;
  final String nombre;

  const _ChequeoDialog({required this.dni, required this.nombre});

  @override
  State<_ChequeoDialog> createState() => _ChequeoDialogState();
}

class _ChequeoDialogState extends State<_ChequeoDialog> {
  StreamSubscription<CachatoreChequeo>? _sub;
  Timer? _timeout;

  // Timeout largo (~30 s): el bot procesa cada chequeo en ~3-10 s contra
  // iTurnos, pero si en el ciclo del bot hay otros chequeos delante puede
  // demorar un poco más (MAX_CHEQUEOS_POR_CICLO=3 × ~8 s ≈ 24 s peor caso).
  static const _timeoutSeg = 30;

  @override
  void initState() {
    super.initState();
    _sub = CachatoreService.streamChequeo(widget.dni).listen((ch) {
      if (!mounted || ch.pendiente) return;
      // Resultado llegó: cerrar dialog devolviéndolo.
      Navigator.of(context).pop(ch);
    }, onError: (e) {
      if (!mounted) return;
      Navigator.of(context).pop(CachatoreChequeo(
        resultado: CachatoreChequeoResultado.error,
        detalle: 'error leyendo el resultado: $e',
      ));
    });
    _timeout = Timer(const Duration(seconds: _timeoutSeg), () {
      if (!mounted) return;
      Navigator.of(context).pop(const CachatoreChequeo(
        resultado: CachatoreChequeoResultado.error,
        detalle: 'el bot no respondió en 30 s '
            '(verificá que esté prendido en la PC dedicada)',
      ));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface2,
      title: const Row(
        children: [
          SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text('Verificando…', style: AppType.heading),
          ),
        ],
      ),
      content: Text(
        'Consultando iTurnos para ${widget.nombre} '
        '(si ya tiene turno sacado, lo agarro y lo paso a Concretados).',
        style: AppType.body,
      ),
      actions: [
        AppButton.ghost(
          label: 'Cancelar',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
