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

/// Panel de control del bot que reserva/reagenda turnos de carga YPF en
/// iTurnos (corre 24/7 en la PC dedicada). Flujo:
///   1. Agregar: elegir chofer → fecha (calendario) → franja → "Vigilados".
///   2. Cuando el bot saca el turno, el chofer pasa solo a "Turnos concretados".
///   3. Tocar un turno concretado → Reagendar (nueva fecha + franja).
/// Todo va por Firestore: la app escribe la selección, el bot la lee y devuelve
/// el estado en vivo.
class CachatoreHubScreen extends StatelessWidget {
  const CachatoreHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Cachatore — Turnos YPF',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _BotStatusCard(),
          SizedBox(height: 12),
          _MasterSwitch(),
          SizedBox(height: 18),
          _SeccionVigilados(),
          SizedBox(height: 22),
          _SeccionConcretados(),
          SizedBox(height: 24),
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
// Estado del bot (latido)
// ───────────────────────────────────────────────────────────────────────
class _BotStatusCard extends StatelessWidget {
  const _BotStatusCard();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CachatoreEstadoBot>(
      stream: CachatoreService.streamEstado(),
      builder: (ctx, snap) {
        final e = snap.data ?? const CachatoreEstadoBot();
        final vivo = e.vivo;
        final color = !vivo
            ? AppColors.accentRed
            : (e.pausado ? AppColors.accentAmber : AppColors.success);
        final titulo = !vivo
            ? 'Bot sin responder'
            : (e.pausado ? 'Bot pausado' : 'Bot activo');
        final detalle = !vivo
            ? 'No late hace ${_haceCuanto(e.ultimoTickEn)} — revisá la PC dedicada'
            : 'Modo ${e.modo.isEmpty ? '—' : e.modo} · '
                '${e.conTurno}/${e.total} con turno · latió ${_haceCuanto(e.ultimoTickEn)}';
        return AppCard(
          borderColor: color.withValues(alpha: 0.5),
          child: Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titulo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: color,
                          fontSize: 14,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detalle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Interruptor maestro (encendido/pausado)
// ───────────────────────────────────────────────────────────────────────
class _MasterSwitch extends StatelessWidget {
  const _MasterSwitch();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CachatoreConfig>(
      stream: CachatoreService.streamConfig(),
      builder: (ctx, snap) {
        final cfg = snap.data ?? const CachatoreConfig();
        return AppCard(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: cfg.activo,
            activeThumbColor: AppColors.success,
            title: const Text('Bot encendido',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15)),
            subtitle: Text(
              cfg.activo
                  ? 'Buscando turnos para los choferes vigilados'
                  : 'Pausado — no reserva ni reagenda nada',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            onChanged: (v) => CachatoreService.setActivo(v),
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
                  child: Text(
                    'CHOFERES VIGILADOS (${vigilados.length})',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                        fontSize: 13),
                  ),
                ),
                FilledButton.icon(
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
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Agregar'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accentCyan,
                    foregroundColor: Colors.black,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (cargando)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (vigilados.isEmpty)
              const AppCard(
                child: Column(
                  children: [
                    Icon(Icons.person_search_outlined,
                        color: Colors.white24, size: 40),
                    SizedBox(height: 8),
                    Text('Sin choferes vigilados',
                        style: TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                    SizedBox(height: 4),
                    Text(
                      'Tocá "Agregar": elegís chofer, fecha y franja, y el bot le '
                      'busca turno.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 12),
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
    final o = objetivo;
    return AppCard(
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
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          const Icon(Icons.event, size: 13, color: Colors.white38),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              o.objetivoLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white60, fontSize: 12),
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
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _editar(context, o),
                  icon: const Icon(Icons.edit_calendar, size: 16),
                  label: const Text('Fecha/franja'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                ),
                IconButton(
                  tooltip: o.activo ? 'Pausar este chofer' : 'Reanudar',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    o.activo
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                    color: o.activo ? Colors.white54 : AppColors.success,
                  ),
                  onPressed: () =>
                      CachatoreService.setObjetivoActivo(o.dni, !o.activo),
                ),
                IconButton(
                  tooltip: 'Quitar de la lista',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline,
                      color: AppColors.accentRed),
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
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.accentRed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Quitar'),
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
                Text(
                  'TURNOS CONCRETADOS (${turnos.length})',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                      fontSize: 13),
                ),
                const SizedBox(height: 8),
                if (turnos.isEmpty)
                  const AppCard(
                    child: Text(
                      'No hay turnos sacados.',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
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

  /// `true` si el chofer está marcado para reagendar y el bot todavía no movió
  /// el turno (estado != reagendado). En ese caso la card se pinta distinta.
  bool get _reagendarPendiente =>
      objetivo != null &&
      objetivo!.reagendar &&
      objetivo!.estado != EstadoObjetivo.reagendado;

  @override
  Widget build(BuildContext context) {
    final t = turno;
    final cuando = (t.cuando ?? '').isNotEmpty
        ? t.cuando!
        : 'Turno${t.hora != null ? ' ${t.hora}' : ''}';
    final reag = _reagendarPendiente;
    final acento = reag ? AppColors.accentAmber : AppColors.success;
    return AppCard(
      onTap: () => _abrirMenu(context),
      borderColor: reag ? AppColors.accentAmber.withValues(alpha: 0.55) : null,
      child: Row(
        children: [
          Icon(reag ? Icons.event_repeat : Icons.event_available,
              color: acento, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.nombre ?? t.dni,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  reag ? 'Turno actual: $cuando' : cuando,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: reag ? Colors.white54 : AppColors.success,
                      fontSize: 12),
                ),
                if (reag) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.sync,
                          size: 13, color: AppColors.accentAmber),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Buscando reagendar a ${objetivo!.objetivoLabel}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.accentAmber,
                              fontSize: 12,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _cancelarReagendar(context),
                      icon: const Icon(Icons.cancel_outlined, size: 15),
                      label: const Text('Cancelar reagendar'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.accentAmber,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Column(
            children: [
              Icon(Icons.more_vert, color: Colors.white54, size: 20),
              SizedBox(height: 2),
              Text('Opciones',
                  style: TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          ),
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
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('No')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sí, cancelar'),
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
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  turno.nombre ?? turno.dni,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16),
                ),
              ),
            ),
            ListTile(
              leading:
                  const Icon(Icons.event_repeat, color: AppColors.accentAmber),
              title:
                  const Text('Reagendar', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Mover el turno a otra fecha/franja',
                  style: TextStyle(color: AppColors.textTertiary)),
              onTap: () {
                Navigator.pop(context);
                _reagendar(context);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: AppColors.accentRed),
              title: const Text('Cancelar turno',
                  style: TextStyle(color: AppColors.accentRed)),
              subtitle: const Text('Lo cancela también en iTurnos (libera el cupo)',
                  style: TextStyle(color: AppColors.textTertiary)),
              onTap: () {
                Navigator.pop(context);
                _confirmarCancelarTurno(context);
              },
            ),
            const SizedBox(height: 8),
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
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('No')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.accentRed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sí, cancelar turno'),
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
    final est = objetivo.estado;
    final Color color;
    if (est.esOk) {
      color = AppColors.success;
    } else if (est.esError) {
      color = AppColors.accentRed;
    } else if (est.esWarn) {
      color = AppColors.accentAmber;
    } else {
      color = Colors.white54;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        est.etiqueta,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
      ),
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
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
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
          backgroundColor: AppColors.accentRed,
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
            const Divider(height: 1, color: Colors.white12),
            Expanded(child: _cuerpo()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final pasos = ['Chofer', 'Fecha', 'Horario'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
      child: Row(
        children: [
          if (_paso > _pasoInicial)
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white70),
              onPressed: () => setState(() => _paso -= 1),
            )
          else
            const SizedBox(width: 48),
          Expanded(
            child: Column(
              children: [
                Text(widget.titulo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
                Text('Paso ${_paso + 1} de 3 · ${pasos[_paso]}',
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Buscar chofer por nombre (ej. PEREZ)',
              prefixIcon: Icon(Icons.search),
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
                return const Center(child: CircularProgressIndicator());
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
                return const Center(
                  child: Text('Sin resultados',
                      style: TextStyle(color: Colors.white38)),
                );
              }
              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (c, i) {
                  final data = docs[i].data();
                  final dni = (data['DNI'] ?? docs[i].id).toString();
                  final nombre = (data['NOMBRE'] ?? dni).toString();
                  final unidad = data['VEHICULO']?.toString();
                  final yaEsta = widget.yaAgregados.contains(dni);
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.person_outline,
                        color: Colors.white38),
                    title: Text(nombre,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: Text(
                      'DNI $dni'
                      '${unidad != null && unidad.isNotEmpty ? ' · $unidad' : ''}'
                      '${yaEsta ? ' · ya en la lista' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color:
                              yaEsta ? AppColors.accentAmber : Colors.white38,
                          fontSize: 11),
                    ),
                    // 🔍 = chequear iTurnos por turno preexistente sacado por
                    // la web (caso: un compañero sacó turno sin pasar por el
                    // bot). Chevron = elegir y seguir el wizard normal
                    // (fecha → franja → vigilar).
                    trailing: yaEsta
                        ? const Icon(Icons.chevron_right,
                            color: Colors.white24)
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip:
                                    'Verificar si ya tiene turno en iTurnos',
                                visualDensity: VisualDensity.compact,
                                splashRadius: 18,
                                icon: const Icon(Icons.manage_search,
                                    color: AppColors.accentCyan, size: 22),
                                onPressed: () =>
                                    _verificarTurnoExistente(dni, nombre),
                              ),
                              const Icon(Icons.chevron_right,
                                  color: Colors.white24),
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          _nombre ?? _dni ?? '',
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
        ),
        const SizedBox(height: 4),
        const Text('¿Para qué fecha buscamos el turno?',
            style: TextStyle(color: Colors.white60, fontSize: 13)),
        const SizedBox(height: 16),
        ListTile(
          leading: const Icon(Icons.all_inclusive, color: AppColors.accentCyan),
          title: const Text('Cualquier fecha',
              style: TextStyle(color: Colors.white)),
          subtitle: const Text('Agarra el primero que se libere en el horario elegido',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          tileColor: Colors.white.withValues(alpha: 0.04),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: Colors.white12)),
          onTap: () => setState(() {
            _fecha = null;
            _paso = 2;
          }),
        ),
        const SizedBox(height: 10),
        ListTile(
          leading:
              const Icon(Icons.calendar_month, color: AppColors.accentCyan),
          title: Text(
            _reIso.hasMatch((_fecha ?? '').trim())
                ? 'Fecha: $_fechaLabel'
                : 'Elegir una fecha del calendario',
            style: const TextStyle(color: Colors.white),
          ),
          subtitle: const Text('Solo turnos de ese día',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          tileColor: Colors.white.withValues(alpha: 0.04),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: Colors.white12)),
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('$_fechaLabel · ${_nombre ?? _dni ?? ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 13)),
        const SizedBox(height: 4),
        const Text('Elegí el horario',
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 12),
        ...FranjaCarga.values.map((f) {
          final sel = f == widget.franjaInicial;
          final esC = f.esCualquiera;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: esC
                  ? const Icon(Icons.all_inclusive, color: AppColors.accentCyan)
                  : null,
              tileColor: Colors.white.withValues(alpha: 0.04),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                    color: sel
                        ? AppColors.accentCyan.withValues(alpha: 0.6)
                        : Colors.white12),
              ),
              // Comodín: mostramos la etiqueta arriba; las 4 franjas muestran el
              // rango horario (los números) arriba y la etiqueta abajo.
              title: Text(esC ? f.etiqueta : f.rango,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 17)),
              subtitle: Text(
                  esC ? 'El primero que se libere, a cualquier hora' : f.etiqueta,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              trailing: _guardando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right, color: Colors.white24),
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
      backgroundColor: AppColors.surface,
      title: const Row(
        children: [
          SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Expanded(
            child: Text('Verificando…',
                style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ],
      ),
      content: Text(
        'Consultando iTurnos para ${widget.nombre} '
        '(si ya tiene turno sacado, lo agarro y lo paso a Concretados).',
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar',
              style: TextStyle(color: Colors.white54)),
        ),
      ],
    );
  }
}
