import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/registro_jornada.dart';
import '../services/registro_jornada_service.dart';
import '../widgets/registro_jornada_card.dart';

/// Vista ADMIN/SUPERVISOR del registro de jornada v3 (Paso 4 — destronar al v2).
///
/// El operador elige un chofer y ve su jornada REAL reconstruida (registro v3):
/// turno, manejo neto, pausas con motivo, recorrido, confianza y flags. Es la
/// fuente OFICIAL para adjudicar disputas (buzón de reclamos) y revisar
/// compliance, en vez del cómputo en vivo del v2 (que queda solo como aviso
/// preventivo). Solo lectura; lee `REGISTRO_JORNADAS` (la regla deja al
/// admin/supervisor/SEG_HIGIENE ver de cualquier chofer).
class AdminRegistroJornadaScreen extends StatefulWidget {
  /// Opcional: pre-seleccionar un chofer (p.ej. al venir desde un reclamo).
  final String? choferDniInicial;

  const AdminRegistroJornadaScreen({super.key, this.choferDniInicial});

  @override
  State<AdminRegistroJornadaScreen> createState() =>
      _AdminRegistroJornadaScreenState();
}

class _AdminRegistroJornadaScreenState
    extends State<AdminRegistroJornadaScreen> {
  String? _choferDni;
  String? _choferNombre;
  List<_ChoferOpt> _choferes = const [];
  bool _cargandoChoferes = true;

  @override
  void initState() {
    super.initState();
    _choferDni = widget.choferDniInicial;
    _cargarChoferes();
  }

  Future<void> _cargarChoferes() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .where('ROL', whereIn: const ['CHOFER', 'USUARIO'])
          .get();
      final lista = snap.docs
          .map((d) {
            final m = d.data();
            return _ChoferOpt(
              dni: d.id,
              nombre: (m['NOMBRE'] as String?)?.trim() ?? d.id,
              activo: m['ACTIVO'] != false,
            );
          })
          .where((c) => c.activo)
          .toList()
        ..sort((a, b) => a.nombre.compareTo(b.nombre));
      if (!mounted) return;
      setState(() {
        _choferes = lista;
        _cargandoChoferes = false;
        if (_choferDni != null) {
          final match = lista.where((c) => c.dni == _choferDni);
          _choferNombre = match.isEmpty ? null : match.first.nombre;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _cargandoChoferes = false);
    }
  }

  Future<void> _elegirChofer() async {
    if (_cargandoChoferes) return;
    final ctrl = TextEditingController();
    final elegido = await showModalBottomSheet<_ChoferOpt>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colors.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (ctx) {
        final c = ctx.colors;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.md),
            child: StatefulBuilder(builder: (ctx, setStateSheet) {
              final q = ctrl.text.trim().toUpperCase();
              final filtrados = q.isEmpty
                  ? _choferes
                  : _choferes
                      .where((c) =>
                          c.nombre.toUpperCase().contains(q) ||
                          c.dni.contains(q))
                      .toList();
              return SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.7,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const AppEyebrow('ELEGIR CHOFER'),
                    const SizedBox(height: AppSpacing.md),
                    AppInput(
                      controller: ctrl,
                      autofocus: true,
                      icon: Icons.search,
                      hint: 'Buscar por nombre o DNI',
                      onChanged: (_) => setStateSheet(() {}),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Expanded(
                      child: filtrados.isEmpty
                          ? const AppEmptyState(
                              icon: Icons.person_search,
                              title: 'Sin coincidencias',
                              subtitle: 'Probá con otro nombre o DNI.',
                            )
                          : ListView.separated(
                              itemCount: filtrados.length,
                              separatorBuilder: (_, __) => const AppHairline(),
                              itemBuilder: (ctx, i) {
                                final opt = filtrados[i];
                                return InkWell(
                                  onTap: () => Navigator.pop(ctx, opt),
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.lg),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: AppSpacing.md,
                                        horizontal: AppSpacing.sm),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            opt.nombre,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppType.body
                                                .copyWith(color: c.text),
                                          ),
                                        ),
                                        const SizedBox(width: AppSpacing.md),
                                        Text(
                                          'DNI ${opt.dni}',
                                          style: AppType.monoSm
                                              .copyWith(color: c.textMuted),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              );
            }),
          ),
        );
      },
    );
    if (elegido != null && mounted) {
      setState(() {
        _choferDni = elegido.dni;
        _choferNombre = elegido.nombre;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Jornada real (registro v3)',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Selector de chofer.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
            child: _SelectorPill(
              icono: _cargandoChoferes
                  ? Icons.hourglass_empty
                  : Icons.person_outline,
              label: _choferNombre ??
                  (_cargandoChoferes ? 'Cargando choferes…' : 'Elegí un chofer'),
              muted: _choferNombre == null,
              onTap: _cargandoChoferes ? null : _elegirChofer,
            ),
          ),
          Expanded(child: _contenido()),
        ],
      ),
    );
  }

  Widget _contenido() {
    if (_choferDni == null) {
      return const AppEmptyState(
        icon: Icons.badge_outlined,
        title: 'Elegí un chofer',
        subtitle: 'Para ver su jornada real reconstruida desde Sitrack.',
      );
    }
    return StreamBuilder<List<RegistroJornada>>(
      stream: RegistroJornadaService.streamUltimasDelChofer(
          choferDni: _choferDni!),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return const AppErrorState(title: 'No se pudo cargar el registro');
        }
        if (!snap.hasData) {
          return const AppLoadingState(message: 'Cargando registro…');
        }
        final jornadas = snap.data!;
        if (jornadas.isEmpty) {
          return AppEmptyState(
            icon: Icons.route_outlined,
            title: 'Sin jornadas registradas',
            subtitle: '${_choferNombre ?? _choferDni} no tiene registros v3 '
                'todavía.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.lg),
          itemCount: jornadas.length,
          separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.md),
          itemBuilder: (ctx, i) => RegistroJornadaCard(j: jornadas[i]),
        );
      },
    );
  }
}

class _ChoferOpt {
  final String dni;
  final String nombre;
  final bool activo;
  const _ChoferOpt(
      {required this.dni, required this.nombre, required this.activo});
}

/// Pill tappable (chofer). Mismo gesto que el selector de la pantalla Jornada.
class _SelectorPill extends StatelessWidget {
  final IconData icono;
  final String label;
  final bool muted;
  final VoidCallback? onTap;

  const _SelectorPill({
    required this.icono,
    required this.label,
    this.muted = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = onTap != null;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              Icon(icono, size: 16, color: enabled ? c.brand : c.textMuted),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                    color: muted ? c.textMuted : c.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
