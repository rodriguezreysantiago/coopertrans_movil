import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Pantalla "Destinatarios de notificación" — admin edita a quién le
/// llega cada uno de los 9 resúmenes/avisos sin tocar código (M5,
/// 2026-05-24). REFACTOR NÚCLEO (jun 2026).
///
/// Lee y escribe `META/destinatarios_notificacion`. Los valores conviven
/// con los hardcoded de `functions/src/comun.ts` y `.env` del bot: si la
/// key no tiene override en Firestore, los callers usan el hardcoded.
/// Editar acá NO puede romper nada — el peor caso es que no haya doc o
/// el doc esté vacío → se usa el hardcoded de siempre.
///
/// Cambios efectivos en ≤ 5 min (cache TTL del helper en CF y en bot).
///
/// **Reescritura Núcleo**: solo el árbol de widgets cambia (eyebrow + hero
/// number con la cantidad de overrides activos + secciones por grupo + filas
/// `AppCard(tier:1)` con `AppBadge` de destinatario). La capa de datos es
/// idéntica: mismo `_cargar` (FutureBuilder), mismo `_guardar` (set/merge +
/// FieldValue.delete), mismo catálogo `_reglas`, mismo bottom sheet de picker.
class AdminDestinatariosNotificacionScreen extends StatefulWidget {
  const AdminDestinatariosNotificacionScreen({super.key});

  @override
  State<AdminDestinatariosNotificacionScreen> createState() =>
      _AdminDestinatariosNotificacionScreenState();
}

class _AdminDestinatariosNotificacionScreenState
    extends State<AdminDestinatariosNotificacionScreen> {
  late Future<_DatosPantalla> _future;

  @override
  void initState() {
    super.initState();
    _future = _cargar();
  }

  Future<_DatosPantalla> _cargar() async {
    final db = FirebaseFirestore.instance;
    // 1) Doc de overrides (puede no existir).
    final docFut = db
        .collection(AppCollections.meta)
        .doc(AppCollections.metaDestinatariosNotificacion)
        .get();
    // 2) Empleados activos para el dropdown (admins/supervisores típicos).
    final empFut =
        db.collection(AppCollections.empleados).get();
    final results = await Future.wait([docFut, empFut]);
    final docSnap = results[0] as DocumentSnapshot<Map<String, dynamic>>;
    final empSnap = results[1] as QuerySnapshot<Map<String, dynamic>>;
    final overrides = (docSnap.data() ?? <String, dynamic>{});
    final empleados = empSnap.docs.map((d) {
      final m = d.data();
      return _Empleado(
        dni: d.id,
        nombre: (m['NOMBRE'] as String?)?.trim() ?? d.id,
        activo: m['ACTIVO'] != false,
      );
    }).where((e) => e.activo).toList()
      ..sort((a, b) => a.nombre.compareTo(b.nombre));
    return _DatosPantalla(overrides: overrides, empleados: empleados);
  }

  Future<void> _guardar(String key, String? dni) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ref = FirebaseFirestore.instance
          .collection(AppCollections.meta)
          .doc(AppCollections.metaDestinatariosNotificacion);
      if (dni == null || dni.isEmpty) {
        // Quitar override → vuelve al hardcoded.
        await ref.set(
            {key: FieldValue.delete(),
             'actualizado_en': FieldValue.serverTimestamp()},
            SetOptions(merge: true));
      } else {
        await ref.set({
          key: dni,
          'actualizado_en': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      AppFeedback.successOn(messenger,
          'Destinatario actualizado. Efectivo en ≤ 5 min.');
      setState(() => _future = _cargar());
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(messenger,
          usuario: 'No se pudo guardar el cambio.',
          tecnico: e, stack: s);
    }
  }

  /// Cuántas reglas del catálogo tienen un override activo en Firestore.
  /// Solo cuenta keys conocidas (las del catálogo `_reglas`), ignorando
  /// metadata como `actualizado_en`.
  int _contarOverrides(Map<String, dynamic> overrides) {
    var n = 0;
    for (final grupo in _reglas) {
      for (final regla in grupo.reglas) {
        final v = overrides[regla.key];
        if (v is String && v.isNotEmpty) n++;
      }
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppScaffold(
      title: 'Destinatarios de notificación',
      body: FutureBuilder<_DatosPantalla>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const AppLoadingState();
          }
          if (snap.hasError) {
            return AppErrorState(subtitle: snap.error.toString());
          }
          final data = snap.data!;
          final totalReglas = _reglas.fold<int>(
              0, (acc, g) => acc + g.reglas.length);
          final overrides = _contarOverrides(data.overrides);

          return ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxxl),
            children: [
              // Header: eyebrow + hero number (overrides activos).
              const AppEyebrow('Destinatarios'),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '$overrides',
                    style: AppType.h2.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      overrides == 1
                          ? 'override · de $totalReglas reglas'
                          : 'overrides · de $totalReglas reglas',
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              // Card de contexto — explica el mecanismo override vs hardcoded.
              AppCard(
                tier: 1,
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: c.textMuted),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        'Cambiá el destinatario de un resumen / aviso. Los '
                        'valores override viven en '
                        'META/destinatarios_notificacion y se sobreponen a los '
                        'hardcoded. Si dejás "Por defecto", vuelve al original. '
                        'Cambios efectivos en ≤ 5 min (cache de las Cloud '
                        'Functions y del bot).',
                        style:
                            AppType.bodySm.copyWith(color: c.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              for (final grupo in _reglas) ...[
                _SeccionLabel(grupo.label, color: _colorGrupo(grupo.tono, c)),
                const SizedBox(height: AppSpacing.sm),
                for (final regla in grupo.reglas)
                  _FilaEditable(
                    regla: regla,
                    overrideDni:
                        (data.overrides[regla.key] as String?) ?? '',
                    empleados: data.empleados,
                    onChange: (dni) => _guardar(regla.key, dni),
                  ),
                const SizedBox(height: AppSpacing.lg),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _DatosPantalla {
  final Map<String, dynamic> overrides;
  final List<_Empleado> empleados;
  const _DatosPantalla({required this.overrides, required this.empleados});
}

class _Empleado {
  final String dni;
  final String nombre;
  final bool activo;
  const _Empleado(
      {required this.dni, required this.nombre, required this.activo});
}

/// Tono semántico de cada grupo, resuelto a `context.colors` en build (no hex).
enum _GrupoTono { success, brandSoft, error, brand, warning }

Color _colorGrupo(_GrupoTono tono, AppColorsExt c) {
  switch (tono) {
    case _GrupoTono.success:
      return c.success;
    case _GrupoTono.brandSoft:
      return c.brandSoft;
    case _GrupoTono.error:
      return c.error;
    case _GrupoTono.brand:
      return c.brand;
    case _GrupoTono.warning:
      return c.warning;
  }
}

/// Definición de las reglas editables. Mantener en sync con
/// `health.js _construirReglasNotificacion` (mismas keys + textos).
class _Regla {
  final String key;
  final String label;
  final String fallbackHardcoded;
  final String descripcion;
  const _Regla({
    required this.key,
    required this.label,
    required this.fallbackHardcoded,
    required this.descripcion,
  });
}

class _GrupoReglas {
  final String label;
  final _GrupoTono tono;
  final List<_Regla> reglas;
  const _GrupoReglas(
      {required this.label, required this.tono, required this.reglas});
}

const _reglas = <_GrupoReglas>[
  _GrupoReglas(
    label: 'RESÚMENES DIARIOS 08:00 ART (CLOUD FUNCTIONS)',
    tono: _GrupoTono.success,
    reglas: [
      _Regla(
        key: 'mantenimientoBot',
        label: 'Salud del bot (caídas / recuperaciones)',
        fallbackHardcoded: '35244439',
        descripcion: 'Bot WhatsApp: caídas, recuperaciones, salud (24h).',
      ),
      _Regla(
        key: 'driftsAsignaciones',
        label: 'Drifts iButton vs asignación del sistema',
        fallbackHardcoded: '35244439',
        descripcion: 'Drifts iButton vs ASIGNACIONES_VEHICULO (24h).',
      ),
      _Regla(
        key: 'parteMantenimientoVolvo',
        label: 'Parte de mantenimiento Volvo',
        fallbackHardcoded: '29820141',
        descripcion: 'Tell-tales Volvo + TPM/TTM/tacógrafo (24h).',
      ),
      _Regla(
        key: 'excesosJornada',
        label: 'Excesos de jornada (bloque/cuota/veda)',
        fallbackHardcoded: '34730329',
        descripcion: 'Jornadas con bloque > 4h, cuota > 12h, veda nocturna.',
      ),
      _Regla(
        key: 'conductaManejo',
        label: 'Conducta de manejo (Sitrack + Volvo)',
        fallbackHardcoded: '34730329',
        descripcion: 'Sitrack peligrosos + Volvo AEBS/ESP + peor sobrevelocidad.',
      ),
    ],
  ),
  _GrupoReglas(
    label: 'CRONS DEL BOT (CADA 60 MIN)',
    tono: _GrupoTono.brandSoft,
    reglas: [
      _Regla(
        key: 'serviceDiario',
        label: 'Service próximo / vencido',
        fallbackHardcoded: '(env SERVICE_DESTINATARIO_DNI)',
        descripcion: 'Tractores con service próximo o vencido (≤ 50 000 km).',
      ),
      _Regla(
        key: 'vencimientosProximosConsolidado',
        label: 'Vencimientos próximos (consolidado)',
        fallbackHardcoded: '(env DOCUMENTACION_DESTINATARIO_DNI)',
        descripcion: 'Personal 15 d + vehículos 15 d + empresas 30 d.',
      ),
    ],
  ),
  _GrupoReglas(
    label: 'BYPASS SEGURIDAD VOLVO (V5)',
    tono: _GrupoTono.error,
    reglas: [
      _Regla(
        key: 'bypassSeguridad',
        label: 'DAS / LKS / LCS / AEBS desactivado',
        fallbackHardcoded: '34730329',
        descripcion:
            'Avisa cuando un chofer desactiva un sistema de asistencia.',
      ),
    ],
  ),
  _GrupoReglas(
    label: 'CACHATORE — TURNOS YPF',
    tono: _GrupoTono.brand,
    reglas: [
      _Regla(
        key: 'cachatoreEncargado',
        label: 'Encargado de turnos YPF',
        fallbackHardcoded: '25022800',
        descripcion: 'Cada movimiento de turno + resumen diario.',
      ),
    ],
  ),
  _GrupoReglas(
    label: 'SISTEMA / ADMIN',
    tono: _GrupoTono.warning,
    reglas: [
      _Regla(
        key: 'colaCreciente',
        label: 'Alerta de cola creciente',
        fallbackHardcoded: '(env COLA_CRECIENTE_ALERT_DNI)',
        descripcion: 'Cola pendiente > umbral por X min sostenidos.',
      ),
    ],
  ),
];

class _FilaEditable extends StatelessWidget {
  final _Regla regla;
  final String overrideDni;
  final List<_Empleado> empleados;
  final ValueChanged<String?> onChange;

  const _FilaEditable({
    required this.regla,
    required this.overrideDni,
    required this.empleados,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tieneOverride = overrideDni.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        tier: 1,
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              regla.label,
              style: AppType.body.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: AppSpacing.sm),
              child: Text(
                regla.descripcion,
                style: AppType.monoSm.copyWith(color: c.textMuted),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _elegir(context),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: tieneOverride
                            ? c.brand.withValues(alpha: 0.10)
                            : c.surface3,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(
                          color: tieneOverride
                              ? c.brand.withValues(alpha: 0.45)
                              : c.border,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            tieneOverride
                                ? Icons.swap_horiz
                                : Icons.settings_outlined,
                            color: tieneOverride ? c.brand : c.textMuted,
                            size: 16,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              tieneOverride
                                  ? _nombreDe(overrideDni)
                                  : 'Por defecto: ${regla.fallbackHardcoded}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tieneOverride
                                  ? AppType.label.copyWith(
                                      color: c.text,
                                      fontWeight: FontWeight.w600)
                                  : AppType.monoSm.copyWith(color: c.textMuted),
                            ),
                          ),
                          Icon(Icons.unfold_more,
                              color: c.textMuted, size: 16),
                        ],
                      ),
                    ),
                  ),
                ),
                if (tieneOverride) ...[
                  const SizedBox(width: AppSpacing.sm),
                  IconButton(
                    icon: Icon(Icons.restore,
                        color: c.textSecondary, size: 18),
                    tooltip: 'Volver al por defecto',
                    onPressed: () => onChange(null),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _nombreDe(String dni) {
    final hit = empleados.firstWhere(
      (e) => e.dni == dni,
      orElse: () =>
          _Empleado(dni: dni, nombre: 'DNI $dni', activo: true),
    );
    return '${hit.nombre} · DNI ${AppFormatters.formatearDNI(dni)}';
  }

  Future<void> _elegir(BuildContext context) async {
    final c = context.colors;
    final ctrl = TextEditingController();
    final elegido = await showModalBottomSheet<_Empleado>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.md),
            child: StatefulBuilder(builder: (ctx, setStateSheet) {
              final q = ctrl.text.trim().toUpperCase();
              final filtrados = q.isEmpty
                  ? empleados
                  : empleados
                      .where((e) =>
                          e.nombre.toUpperCase().contains(q) ||
                          e.dni.contains(q))
                      .toList();
              return SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.7,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const AppEyebrow('Elegir destinatario'),
                    const SizedBox(height: 6),
                    Text(
                      regla.label,
                      style: AppType.h5.copyWith(color: c.text),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppInput(
                      controller: ctrl,
                      autofocus: true,
                      hint: 'Buscar por nombre o DNI',
                      icon: Icons.search,
                      onChanged: (_) => setStateSheet(() {}),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtrados.length,
                        itemBuilder: (ctx, i) {
                          final e = filtrados[i];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(e.nombre,
                                style: AppType.body.copyWith(color: c.text)),
                            subtitle: Text(
                                'DNI ${AppFormatters.formatearDNI(e.dni)}',
                                style: AppType.monoSm
                                    .copyWith(color: c.textMuted)),
                            trailing: Icon(Icons.chevron_right,
                                size: 18, color: c.textMuted),
                            onTap: () => Navigator.pop(ctx, e),
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
    // Controller local del bottom sheet: soltarlo acá (sin esto, cada
    // apertura del buscador dejaba un TextEditingController sin dispose).
    ctrl.dispose();
    if (elegido == null) return;
    onChange(elegido.dni);
  }
}

class _SeccionLabel extends StatelessWidget {
  final String texto;
  final Color color;
  const _SeccionLabel(this.texto, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, top: AppSpacing.xs),
      child: AppEyebrow(texto, color: color),
    );
  }
}
