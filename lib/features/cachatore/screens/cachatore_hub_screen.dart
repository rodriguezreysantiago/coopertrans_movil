import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/cachatore_config.dart';
import '../models/cachatore_estado_bot.dart';
import '../models/cachatore_objetivo.dart';
import '../models/franja_carga.dart';
import '../services/cachatore_service.dart';

/// Panel de control del bot que reserva/reagenda turnos de carga YPF en
/// iTurnos (corre 24/7 en la PC dedicada). Desde acá se elige a qué
/// choferes les caza turno, en qué franja, se prende/pausa el bot y se ve
/// el estado en vivo. Todo va por Firestore: la app escribe la selección,
/// el bot la lee y devuelve el estado.
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
          _ConfigCard(),
          SizedBox(height: 12),
          _ObjetivosSection(),
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
            : (e.pausado ? AppColors.accentAmber : AppColors.accentGreen);
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
                        fontWeight: FontWeight.bold,
                      ),
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
// Config global: interruptor maestro + hora del drop + fecha objetivo
// ───────────────────────────────────────────────────────────────────────
class _ConfigCard extends StatelessWidget {
  const _ConfigCard();

  Future<void> _editarHora(BuildContext context, String actual) async {
    final partes = actual.split(':');
    final inicial = TimeOfDay(
      hour: int.tryParse(partes.isNotEmpty ? partes[0] : '') ?? 10,
      minute: int.tryParse(partes.length > 1 ? partes[1] : '') ?? 29,
    );
    final r = await showTimePicker(
      context: context,
      initialTime: inicial,
      helpText: 'Hora del drop (cuándo libera iTurnos)',
    );
    if (r != null) {
      final hhmm =
          '${r.hour.toString().padLeft(2, '0')}:${r.minute.toString().padLeft(2, '0')}';
      await CachatoreService.setHoraInicio(hhmm);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CachatoreConfig>(
      stream: CachatoreService.streamConfig(),
      builder: (ctx, snap) {
        final cfg = snap.data ?? const CachatoreConfig();
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: cfg.activo,
                activeThumbColor: AppColors.accentGreen,
                title: const Text(
                  'Bot encendido',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15),
                ),
                subtitle: Text(
                  cfg.activo
                      ? 'Cazando turnos para los choferes de abajo'
                      : 'Pausado — no reserva ni reagenda nada',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onChanged: (v) => CachatoreService.setActivo(v),
              ),
              const Divider(height: 18, color: Colors.white12),
              // Hora del drop
              InkWell(
                onTap: () => _editarHora(context, cfg.horaInicio),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.alarm,
                          size: 20, color: Colors.white54),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Hora del drop',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ),
                      Text(
                        cfg.horaInicio,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14),
                      ),
                      const Icon(Icons.edit, size: 16, color: Colors.white38),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Fecha objetivo',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  _FechaChip(
                    etiqueta: 'Cualquiera',
                    seleccionada: (cfg.fecha ?? '').isEmpty,
                    onTap: () => CachatoreService.setFecha(null),
                  ),
                  _FechaChip(
                    etiqueta: 'Hoy',
                    seleccionada: cfg.fecha == 'hoy',
                    onTap: () => CachatoreService.setFecha('hoy'),
                  ),
                  _FechaChip(
                    etiqueta: 'Mañana',
                    seleccionada: cfg.fecha == 'manana',
                    onTap: () => CachatoreService.setFecha('manana'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FechaChip extends StatelessWidget {
  final String etiqueta;
  final bool seleccionada;
  final VoidCallback onTap;
  const _FechaChip({
    required this.etiqueta,
    required this.seleccionada,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(etiqueta),
      selected: seleccionada,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.accentCyan.withValues(alpha: 0.3),
      labelStyle: TextStyle(
        color: seleccionada ? AppColors.accentCyan : Colors.white70,
        fontWeight: seleccionada ? FontWeight.bold : FontWeight.normal,
        fontSize: 12,
      ),
      backgroundColor: Colors.white.withValues(alpha: 0.05),
      side: BorderSide(
        color: seleccionada
            ? AppColors.accentCyan.withValues(alpha: 0.6)
            : Colors.white24,
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Lista de choferes vigilados
// ───────────────────────────────────────────────────────────────────────
class _ObjetivosSection extends StatelessWidget {
  const _ObjetivosSection();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<CachatoreObjetivo>>(
      stream: CachatoreService.streamObjetivos(),
      builder: (ctx, snap) {
        final objetivos = snap.data ?? const <CachatoreObjetivo>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'CHOFERES VIGILADOS (${objetivos.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                      fontSize: 13,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => _mostrarAgregar(context, objetivos),
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
            if (snap.connectionState == ConnectionState.waiting)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (objetivos.isEmpty)
              _vacio()
            else
              ...objetivos.map((o) => _ObjetivoCard(objetivo: o)),
          ],
        );
      },
    );
  }

  Widget _vacio() {
    return const AppCard(
      child: Column(
        children: [
          Icon(Icons.person_off_outlined, color: Colors.white24, size: 40),
          SizedBox(height: 8),
          Text(
            'Sin choferes',
            style: TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.bold,
                fontSize: 14),
          ),
          SizedBox(height: 4),
          Text(
            'Tocá "Agregar" para que el bot empiece a cazarle turno a un chofer.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _mostrarAgregar(
      BuildContext context, List<CachatoreObjetivo> existentes) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _AgregarChoferSheet(
        yaAgregados: existentes.map((e) => e.dni).toSet(),
      ),
    );
  }
}

class _ObjetivoCard extends StatelessWidget {
  final CachatoreObjetivo objetivo;
  const _ObjetivoCard({required this.objetivo});

  @override
  Widget build(BuildContext context) {
    final o = objetivo;
    final atenuado = !o.activo;
    return AppCard(
      child: Opacity(
        opacity: atenuado ? 0.55 : 1.0,
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
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'DNI ${o.dni}',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                _EstadoBadge(objetivo: o),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                // Franja (tappable)
                Expanded(
                  child: InkWell(
                    onTap: () => _elegirFranja(context, o),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.schedule,
                              size: 16, color: Colors.white54),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  o.franja.etiqueta,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  o.franja.rango,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 10),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.edit, size: 14, color: Colors.white38),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: o.activo ? 'Pausar este chofer' : 'Reanudar',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    o.activo
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                    color: o.activo ? Colors.white54 : AppColors.accentGreen,
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
            const SizedBox(height: 4),
            // Reagendar
            Row(
              children: [
                Switch(
                  value: o.reagendar,
                  activeThumbColor: AppColors.accentCyan,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => CachatoreService.setReagendar(o.dni, v),
                ),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text(
                    'Reagendar (mover el turno a su franja si se libera uno)',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white60, fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _elegirFranja(BuildContext context, CachatoreObjetivo o) async {
    final elegida = await mostrarSelectorFranja(context, actual: o.franja);
    if (elegida != null && elegida != o.franja) {
      await CachatoreService.setFranja(o.dni, elegida);
    }
  }

  Future<void> _confirmarBorrar(
      BuildContext context, CachatoreObjetivo o) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Quitar chofer'),
        content: Text(
            'El bot deja de cazarle turno a ${o.nombre ?? o.dni}. '
            'Los turnos ya reservados NO se cancelan.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.accentRed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await CachatoreService.eliminarObjetivo(o.dni);
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
      color = AppColors.accentGreen;
    } else if (est.esError) {
      color = AppColors.accentRed;
    } else if (est.esWarn) {
      color = AppColors.accentAmber;
    } else {
      color = Colors.white54;
    }
    final hora = objetivo.estadoHora;
    final texto = (objetivo.tieneTurno && hora != null && hora.isNotEmpty)
        ? '${est.etiqueta} $hora'
        : est.etiqueta;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        texto,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Selector de franja (bottom sheet reutilizable)
// ───────────────────────────────────────────────────────────────────────
Future<FranjaCarga?> mostrarSelectorFranja(
  BuildContext context, {
  FranjaCarga? actual,
}) {
  return showModalBottomSheet<FranjaCarga>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Elegí la franja',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
          ),
          ...FranjaCarga.values.map(
            (f) => ListTile(
              leading: Icon(
                f == actual
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: f == actual ? AppColors.accentCyan : Colors.white38,
              ),
              title: Text(f.etiqueta,
                  style: const TextStyle(color: Colors.white)),
              subtitle: Text(f.rango,
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
              onTap: () => Navigator.pop(context, f),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

// ───────────────────────────────────────────────────────────────────────
// Bottom sheet: agregar chofer (buscador EMPLEADOS ROL=CHOFER)
// ───────────────────────────────────────────────────────────────────────
class _AgregarChoferSheet extends StatefulWidget {
  final Set<String> yaAgregados;
  const _AgregarChoferSheet({required this.yaAgregados});

  @override
  State<_AgregarChoferSheet> createState() => _AgregarChoferSheetState();
}

class _AgregarChoferSheetState extends State<_AgregarChoferSheet> {
  String _filtro = '';
  String? _dni;
  String? _nombre;
  FranjaCarga _franja = FranjaCarga.manana;
  bool _reagendar = false;
  bool _guardando = false;

  Future<void> _guardar() async {
    if (_dni == null) return;
    setState(() => _guardando = true);
    await CachatoreService.agregarObjetivo(
      dni: _dni!,
      nombre: _nombre ?? _dni!,
      franja: _franja,
      reagendar: _reagendar,
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.5,
        builder: (ctx, scrollCtrl) {
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('Agregar chofer',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'Buscar por nombre (ej. PEREZ)',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _filtro = v.trim().toUpperCase()),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(child: _listaChoferes(scrollCtrl)),
              if (_dni != null) _panelSeleccion(),
            ],
          );
        },
      ),
    );
  }

  Widget _listaChoferes(ScrollController scrollCtrl) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
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
          if (data['ACTIVO'] == false) return false; // baja
          final n = (data['NOMBRE'] ?? '').toString().toUpperCase();
          return _filtro.isEmpty || n.contains(_filtro);
        }).toList()
          ..sort((a, b) => (a.data()['NOMBRE'] ?? '')
              .toString()
              .toUpperCase()
              .compareTo((b.data()['NOMBRE'] ?? '').toString().toUpperCase()));

        if (docs.isEmpty) {
          return const Center(
            child: Text('Sin resultados',
                style: TextStyle(color: Colors.white38)),
          );
        }
        return ListView.builder(
          controller: scrollCtrl,
          itemCount: docs.length,
          itemBuilder: (c, i) {
            final data = docs[i].data();
            final dni = (data['DNI'] ?? docs[i].id).toString();
            final nombre = (data['NOMBRE'] ?? dni).toString();
            final unidad = data['VEHICULO']?.toString();
            final yaEsta = widget.yaAgregados.contains(dni);
            final sel = _dni == dni;
            return ListTile(
              dense: true,
              selected: sel,
              selectedTileColor: AppColors.accentCyan.withValues(alpha: 0.12),
              leading: Icon(
                sel ? Icons.check_circle : Icons.person_outline,
                color: sel ? AppColors.accentCyan : Colors.white38,
              ),
              title: Text(nombre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(
                'DNI $dni${unidad != null && unidad.isNotEmpty ? ' · $unidad' : ''}'
                '${yaEsta ? ' · ya en la lista' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: yaEsta ? AppColors.accentAmber : Colors.white38,
                    fontSize: 11),
              ),
              onTap: () => setState(() {
                _dni = dni;
                _nombre = nombre;
              }),
            );
          },
        );
      },
    );
  }

  Widget _panelSeleccion() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _nombre ?? _dni!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: FranjaCarga.values.map((f) {
              final sel = f == _franja;
              return ChoiceChip(
                label: Text(f.etiqueta),
                selected: sel,
                onSelected: (_) => setState(() => _franja = f),
                selectedColor: AppColors.accentCyan.withValues(alpha: 0.3),
                backgroundColor: Colors.white.withValues(alpha: 0.05),
                labelStyle: TextStyle(
                  color: sel ? AppColors.accentCyan : Colors.white70,
                  fontSize: 12,
                  fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                ),
                side: BorderSide(
                    color: sel
                        ? AppColors.accentCyan.withValues(alpha: 0.6)
                        : Colors.white24),
              );
            }).toList(),
          ),
          Row(
            children: [
              Checkbox(
                value: _reagendar,
                activeColor: AppColors.accentCyan,
                onChanged: (v) => setState(() => _reagendar = v ?? false),
              ),
              const Expanded(
                child: Text(
                  'Reagendar si se libera un turno mejor',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _guardando ? null : _guardar,
              icon: _guardando
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: const Text('Agregar a la lista'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accentCyan,
                foregroundColor: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
