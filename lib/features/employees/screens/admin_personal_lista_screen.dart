import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
// `flutter/services` exporta los TextInputFormatter usados por
// `_DatoEditableTexto` (DigitOnlyFormatter hereda de ahí).
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/capabilities.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_breakpoints.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/digit_only_formatter.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/phone_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/foto_perfil_avatar.dart';

import '../services/empleado_actions.dart';
import 'admin_personal_form_screen.dart';
import 'chofer_actividad_screen.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
// 10 widgets visuales (card, detalle, header, datos editables, filas
// de vencimiento, asignacion de unidad) extraidos para mantener
// navegable el screen principal. Comparten privacidad via `part of`.
part 'admin_personal_lista_widgets.dart';

/// Pantalla de Gestión de Personal — REFACTOR NÚCLEO (jun 2026).
///
/// Reescrita al layout del prototipo (`screens-desktop-core.jsx :: Personal`):
/// hero con el conteo real de activos + chips de filtro por rol + **tabla**
/// densa en desktop. En mobile se mantienen las cards ricas (`_EmpleadoCard`),
/// que ya son Núcleo por tokens y no conviene degradar a una tabla angosta.
///
/// La fila de tabla abre el MISMO detalle que la card (`_DetalleChofer.abrir`),
/// así que no se pierde ninguna acción. Búsqueda (AppListPage), filtros de
/// inactivos/excluidos, FAB "Nuevo" y navegación quedan intactos.
class AdminPersonalListaScreen extends StatefulWidget {
  const AdminPersonalListaScreen({super.key});

  @override
  State<AdminPersonalListaScreen> createState() =>
      _AdminPersonalListaScreenState();
}

class _AdminPersonalListaScreenState
    extends State<AdminPersonalListaScreen> {
  // Stream cacheado para evitar lecturas duplicadas al buscar/refrescar.
  late final Stream<QuerySnapshot> _empleadosStream;

  /// Por default solo activos. Toggle del AppBar lo invierte.
  bool _mostrarInactivos = false;

  /// Por default los 3 tanqueros + 2 testers están ocultos. Toggle del
  /// AppBar permite verlos para auditoría/mantenimiento de esos perfiles.
  bool _mostrarExcluidos = false;

  /// Filtro por rol activo (null = todos). Lo setean los chips del hero.
  String? _rolFiltro;

  /// Set de DNIs excluidos (cacheado por `ExcluidosService`). Null hasta
  /// que termine la carga inicial — si quedó null cuando el filter corre,
  /// `esExcluido` devuelve `false` (fail-safe).
  ExcluidosSet? _excluidos;

  @override
  void initState() {
    super.initState();
    _empleadosStream = FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .orderBy('NOMBRE')
        .snapshots();
    // Cargar set de excluidos en background. Al terminar, setState para
    // que el StreamBuilder re-renderice aplicando el filtro.
    ExcluidosService.cargar().then((s) {
      if (mounted) setState(() => _excluidos = s);
    });
  }

  /// ¿El empleado pasa los filtros de visibilidad (activo/excluido/rol)?
  /// Compartido entre el conteo del hero y el filtro de la lista para que
  /// los números coincidan con lo que se ve.
  bool _visible(Map<String, dynamic> data, String dni) {
    if (!_mostrarInactivos && !AppActivo.esActivo(data)) return false;
    if (!_mostrarExcluidos &&
        ExcluidosService.esExcluido(_excluidos, dni: dni)) {
      return false;
    }
    if (_rolFiltro != null &&
        AppRoles.normalizar(data['ROL']?.toString()) != _rolFiltro) {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final esDesktop = AppBreakpoints.isDesktopOrLarger(context);
    return AppScaffold(
      title: 'Gestión de Personal',
      actions: [
        if ((_excluidos?.dnis.isNotEmpty ?? false))
          IconButton(
            tooltip: _mostrarExcluidos
                ? 'Ocultar tanqueros y testers'
                : 'Mostrar tanqueros y testers',
            icon: Icon(
              _mostrarExcluidos
                  ? Icons.shield_moon_outlined
                  : Icons.shield_outlined,
              color: _mostrarExcluidos
                  ? AppColors.warning
                  : AppColors.textSecondary,
            ),
            onPressed: () =>
                setState(() => _mostrarExcluidos = !_mostrarExcluidos),
          ),
      ],
      floatingActionButton:
          Capabilities.can(PrefsService.rol, Capability.crearEmpleado)
              ? FloatingActionButton.extended(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AdminPersonalFormScreen(),
                    ),
                  ),
                  tooltip: 'Agregar nuevo chofer',
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Nuevo'),
                )
              : null,
      body: Column(
        children: [
          // Hero (conteo real) + chips de filtro por rol.
          StreamBuilder<QuerySnapshot>(
            stream: _empleadosStream,
            builder: (ctx, snap) => _HeroYChips(
              docs: snap.data?.docs ?? const [],
              excluidos: _excluidos,
              mostrarExcluidos: _mostrarExcluidos,
              rolFiltro: _rolFiltro,
              onRol: (r) => setState(() => _rolFiltro = r),
            ),
          ),
          // Toggle "mostrar inactivos".
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('Mostrar inactivos'),
                  selected: _mostrarInactivos,
                  onSelected: (v) => setState(() => _mostrarInactivos = v),
                  selectedColor: AppColors.warning.withValues(alpha: 0.6),
                  avatar: Icon(
                    _mostrarInactivos
                        ? Icons.visibility
                        : Icons.visibility_off,
                    size: 16,
                    color: _mostrarInactivos
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // Encabezado de tabla (solo desktop).
          if (esDesktop)
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xs),
              child: _FilaHeader(),
            ),
          Expanded(
            child: AppListPage(
              stream: _empleadosStream,
              searchHint: 'Buscar por nombre, tractor o enganche...',
              emptyTitle: 'Sin choferes cargados',
              emptySubtitle: 'Tocá el botón + para agregar uno',
              emptyIcon: Icons.badge_outlined,
              filter: (doc, q) {
                final data = doc.data() as Map<String, dynamic>;
                if (!_visible(data, doc.id)) return false;
                final hay = '${data['NOMBRE'] ?? ''} '
                        '${data['VEHICULO'] ?? ''} ${data['ENGANCHE'] ?? ''} '
                        '${doc.id}'
                    .toUpperCase();
                return hay.contains(q);
              },
              itemBuilder: (ctx, doc) => esDesktop
                  ? _FilaPersona(doc: doc)
                  : _EmpleadoCard(doc: doc),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// HERO + CHIPS DE FILTRO POR ROL
// =============================================================================

class _HeroYChips extends StatelessWidget {
  final List<QueryDocumentSnapshot> docs;
  final ExcluidosSet? excluidos;
  final bool mostrarExcluidos;
  final String? rolFiltro;
  final ValueChanged<String?> onRol;

  const _HeroYChips({
    required this.docs,
    required this.excluidos,
    required this.mostrarExcluidos,
    required this.rolFiltro,
    required this.onRol,
  });

  @override
  Widget build(BuildContext context) {
    // Conteo de activos (no excluidos) total + por rol. El hero refleja la
    // realidad de la base, no datos hardcodeados.
    var activos = 0;
    final porRol = <String, int>{};
    for (final d in docs) {
      final data = d.data() as Map<String, dynamic>;
      if (!AppActivo.esActivo(data)) continue;
      if (!mostrarExcluidos &&
          ExcluidosService.esExcluido(excluidos, dni: d.id)) {
        continue;
      }
      activos++;
      final rol = AppRoles.normalizar(data['ROL']?.toString());
      porRol[rol] = (porRol[rol] ?? 0) + 1;
    }
    final roles = porRol.keys.toList()
      ..sort((a, b) => porRol[b]!.compareTo(porRol[a]!));

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('EQUIPO', style: AppType.eyebrow),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                docs.isEmpty ? '—' : '$activos',
                style: AppType.h2.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('activos', style: AppType.monoSm),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              AppFilterChip(
                label: 'Todos',
                count: activos,
                activo: rolFiltro == null,
                onTap: () => onRol(null),
              ),
              for (final r in roles)
                AppFilterChip(
                  label: _rolLabel(r),
                  count: porRol[r] ?? 0,
                  activo: rolFiltro == r,
                  onTap: () => onRol(r),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// TABLA (desktop): encabezado + fila
// =============================================================================

// Flex de las columnas — el header y las filas comparten estos pesos para
// que queden alineados.
const int _flexPersona = 3;
const int _flexRol = 2;
const int _flexLegajo = 2;
const int _flexUnidad = 2;
const int _flexEstado = 2;

class _FilaHeader extends StatelessWidget {
  const _FilaHeader();

  @override
  Widget build(BuildContext context) {
    Widget h(String t, int flex) => Expanded(
          flex: flex,
          child: Text(t.toUpperCase(), style: AppType.eyebrow),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          h('Persona', _flexPersona),
          h('Rol', _flexRol),
          h('Legajo', _flexLegajo),
          h('Unidad', _flexUnidad),
          h('Estado', _flexEstado),
          const SizedBox(width: 24),
        ],
      ),
    );
  }
}

class _FilaPersona extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _FilaPersona({required this.doc});

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final dni = doc.id;
    final nombre = (data['NOMBRE'] ?? 'Sin nombre').toString();
    final apodo = (data['APODO'] ?? '').toString().trim();
    final rol = AppRoles.normalizar(data['ROL']?.toString());
    final area = (data['AREA'] ?? AppAreas.manejo).toString();
    final mostrarFlota = area == AppAreas.manejo;
    final tractor = (data['VEHICULO'] ?? '-').toString();
    final urlPerfil = data['ARCHIVO_PERFIL']?.toString();
    final activo = AppActivo.esActivo(data);

    return AppCard(
      tier: 1,
      onTap: () => _DetalleChofer.abrir(context, dni),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          // Persona — avatar + nombre (+ apodo).
          Expanded(
            flex: _flexPersona,
            child: Row(
              children: [
                FotoPerfilAvatar(url: urlPerfil, nombre: nombre, radius: 16),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    apodo.isNotEmpty ? '$nombre  ($apodo)' : nombre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          // Rol.
          Expanded(
            flex: _flexRol,
            child: Text(
              _rolLabel(rol),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.bodySm,
            ),
          ),
          // Legajo (DNI).
          Expanded(
            flex: _flexLegajo,
            child: Text(dni, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppType.mono.copyWith(color: AppColors.textSecondary)),
          ),
          // Unidad.
          Expanded(
            flex: _flexUnidad,
            child: Text(
              mostrarFlota ? tractor : '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.mono.copyWith(
                color: mostrarFlota
                    ? AppColors.textPrimary
                    : AppColors.textTertiary,
              ),
            ),
          ),
          // Estado.
          Expanded(
            flex: _flexEstado,
            child: Row(
              children: [
                AppDot(activo ? AppColors.success : AppColors.textTertiary,
                    size: 6),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    activo ? 'Activo' : 'Inactivo',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.monoSm.copyWith(
                      color: activo
                          ? AppColors.textSecondary
                          : AppColors.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right,
              size: 18, color: AppColors.textHint),
        ],
      ),
    );
  }
}

/// Etiqueta legible para un rol normalizado.
String _rolLabel(String rol) {
  switch (rol) {
    case AppRoles.chofer:
      return 'Chofer';
    case AppRoles.admin:
      return 'Admin';
    case AppRoles.supervisor:
      return 'Supervisor';
    case AppRoles.planta:
      return 'Planta';
  }
  if (rol.isEmpty) return '—';
  return rol[0].toUpperCase() + rol.substring(1).toLowerCase();
}
