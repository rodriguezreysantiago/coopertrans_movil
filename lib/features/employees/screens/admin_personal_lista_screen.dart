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
/// encabezado `PERSONAL · n empleados` + `AppKpiStrip` (activos · choferes ·
/// supervisores · gomería · admin) + chips de filtro por rol + lista densa
/// (`_FilaPersona`) en una superficie `AppCard(tier:1)` por fila, con
/// `AppHairline` implícita entre filas (borde de cards adyacentes).
///
/// La fila es responsive (desktop spread en columnas; mobile apila rol/empresa
/// bajo el nombre) y abre el MISMO detalle (`_DetalleChofer.abrir`), así que no
/// se pierde ninguna acción. La capa de datos NO cambia: stream EMPLEADOS,
/// `_visible()` (activo/excluido/rol), filtro de búsqueda de `AppListPage`,
/// toggles de inactivos/excluidos, FAB "Nuevo" y navegación quedan intactos.
///
/// El KpiStrip es el resumen at-a-glance; los `AppFilterChip` siguen siendo el
/// mecanismo INTERACTIVO de filtro por rol (`_rolFiltro` / `onRol`), arreglado
/// recientemente — no tocar esa lógica.
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
          // Encabezado "PERSONAL · n empleados" + AppKpiStrip + chips de
          // filtro por rol. El conteo y los KPIs salen del MISMO stream que
          // alimenta la lista, así nunca divergen de lo que se ve.
          StreamBuilder<QuerySnapshot>(
            stream: _empleadosStream,
            builder: (ctx, snap) => _HeroYChips(
              docs: snap.data?.docs ?? const [],
              excluidos: _excluidos,
              mostrarExcluidos: _mostrarExcluidos,
              mostrarInactivos: _mostrarInactivos,
              rolFiltro: _rolFiltro,
              onRol: (r) => setState(() => _rolFiltro = r),
              onToggleInactivos: () =>
                  setState(() => _mostrarInactivos = !_mostrarInactivos),
            ),
          ),
          Expanded(
            child: AppListPage(
              stream: _empleadosStream,
              searchHint: 'Buscar por nombre, tractor o enganche...',
              emptyTitle: 'Sin choferes cargados',
              emptySubtitle: 'Tocá el botón + para agregar uno',
              emptyIcon: Icons.badge_outlined,
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 96),
              filter: (doc, q) {
                final data = doc.data() as Map<String, dynamic>;
                if (!_visible(data, doc.id)) return false;
                final hay = '${data['NOMBRE'] ?? ''} '
                        '${data['VEHICULO'] ?? ''} ${data['ENGANCHE'] ?? ''} '
                        '${doc.id}'
                    .toUpperCase();
                return hay.contains(q);
              },
              itemBuilder: (ctx, doc) =>
                  _FilaPersona(doc: doc, esDesktop: esDesktop),
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
  final bool mostrarInactivos;
  final String? rolFiltro;
  final ValueChanged<String?> onRol;
  final VoidCallback onToggleInactivos;

  const _HeroYChips({
    required this.docs,
    required this.excluidos,
    required this.mostrarExcluidos,
    required this.mostrarInactivos,
    required this.rolFiltro,
    required this.onRol,
    required this.onToggleInactivos,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    // Un solo barrido sobre los docs aplicando los filtros de VISIBILIDAD
    // (excluidos + inactivos) — los mismos que `_visible`, salvo el rol (el
    // strip y los chips muestran TODOS los roles, sin importar el filtro de
    // rol activo). Todo se deriva de la base: cero números hardcodeados.
    var totalVisibles = 0; // empleados que entran a la lista (sin filtro rol)
    var activos = 0; // de esos, los que están ACTIVO != false
    final porRol = <String, int>{}; // por rol, solo entre los activos
    for (final d in docs) {
      final data = d.data() as Map<String, dynamic>;
      if (!mostrarExcluidos &&
          ExcluidosService.esExcluido(excluidos, dni: d.id)) {
        continue;
      }
      final esActivo = AppActivo.esActivo(data);
      if (!mostrarInactivos && !esActivo) continue;
      totalVisibles++;
      if (!esActivo) continue;
      activos++;
      final rol = AppRoles.normalizar(data['ROL']?.toString());
      porRol[rol] = (porRol[rol] ?? 0) + 1;
    }
    // Chips: orden estable por frecuencia (igual que antes).
    final roles = porRol.keys.toList()
      ..sort((a, b) => porRol[b]!.compareTo(porRol[a]!));

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Encabezado: "PERSONAL · n empleados" + toggle inactivos.
          Row(
            children: [
              const Expanded(child: AppEyebrow('Personal')),
              _ToggleInactivos(
                activo: mostrarInactivos,
                onTap: onToggleInactivos,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                docs.isEmpty ? '—' : '$totalVisibles',
                style: AppType.h2.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  mostrarInactivos ? 'empleados (incl. inactivos)' : 'empleados',
                  style: AppType.monoSm,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // KPIs at-a-glance: activos · choferes · supervisores · gomería ·
          // admin. Resumen no interactivo; el filtro vive en los chips.
          AppKpiStrip(
            stats: [
              AppStat(label: 'Activos', value: '$activos'),
              AppStat(
                label: 'Choferes',
                value: '${porRol[AppRoles.chofer] ?? 0}',
              ),
              AppStat(
                label: 'Supervisores',
                value: '${porRol[AppRoles.supervisor] ?? 0}',
              ),
              AppStat(
                label: 'Gomería',
                value: '${porRol[AppRoles.gomeria] ?? 0}',
              ),
              AppStat(
                label: 'Admin',
                value: '${porRol[AppRoles.admin] ?? 0}',
                accent: c.brand,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Chips INTERACTIVOS de filtro por rol (mecanismo recién arreglado).
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

/// Toggle compacto "Mostrar inactivos" en estilo Núcleo (pill con borde),
/// reemplaza al `FilterChip` Material del header viejo.
class _ToggleInactivos extends StatelessWidget {
  final bool activo;
  final VoidCallback onTap;
  const _ToggleInactivos({required this.activo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = activo ? c.warning : c.textMuted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: activo ? c.warningSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: activo ? color : c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              activo ? Icons.visibility : Icons.visibility_off,
              size: 14,
              color: color,
            ),
            const SizedBox(width: 6),
            Text(
              'Inactivos',
              style: AppType.label.copyWith(
                color: activo ? color : c.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// FILA DE LA LISTA (Núcleo) — AppCard(tier:1) por fila. Las cards adyacentes
// dejan una hairline natural entre filas (su borde). Responsive: en desktop
// se despliega en columnas; en mobile apila rol/empresa bajo el nombre para
// no romper layout en pantallas angostas.
// =============================================================================

class _FilaPersona extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  final bool esDesktop;
  const _FilaPersona({required this.doc, required this.esDesktop});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final data = doc.data() as Map<String, dynamic>;
    final dni = doc.id;
    final nombre = (data['NOMBRE'] ?? 'Sin nombre').toString();
    final apodo = (data['APODO'] ?? '').toString().trim();
    final rol = AppRoles.normalizar(data['ROL']?.toString());
    final empresa = _empresaCorta((data['EMPRESA'] ?? '').toString());
    final activo = AppActivo.esActivo(data);
    final urlPerfil = data['ARCHIVO_PERFIL']?.toString();
    // Peor vencimiento personal (licencia/preocupacional/manejo defensivo) —
    // dato real, no inventado. Solo se muestra cuando hay algo que avisar.
    final venc = _peorVencimiento(data);

    final nombreVisible = apodo.isNotEmpty ? '$nombre  ($apodo)' : nombre;

    final avatar = FotoPerfilAvatar(url: urlPerfil, nombre: nombre, radius: 18);

    // Bloque persona: avatar + nombre + (sub-línea de alerta de vencimiento).
    Widget persona() => Row(
          children: [
            avatar,
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    nombreVisible,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  if (venc != null)
                    Row(
                      children: [
                        AppDot(venc.color, size: 5),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            venc.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.monoSm.copyWith(color: venc.color),
                          ),
                        ),
                      ],
                    )
                  else
                    Text(
                      dni,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                    ),
                ],
              ),
            ),
          ],
        );

    final rolBadge = AppBadge(
      text: AppRoles.etiquetas[rol] ?? _rolLabel(rol),
      color: _colorRol(rol, c),
      size: AppBadgeSize.sm,
    );

    final estadoBadge = AppBadge(
      text: activo ? 'Activo' : 'Inactivo',
      color: activo ? c.success : c.textMuted,
      dot: true,
      size: AppBadgeSize.sm,
    );

    final chevron =
        Icon(Icons.chevron_right, size: 18, color: c.textMuted);

    return AppCard(
      tier: 1,
      onTap: () => _DetalleChofer.abrir(context, dni),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: esDesktop
          // DESKTOP: columnas Persona / Rol / Legajo / Empresa / Estado / →
          ? Row(
              children: [
                Expanded(flex: 4, child: persona()),
                const SizedBox(width: AppSpacing.sm),
                Expanded(flex: 2, child: Align(
                  alignment: Alignment.centerLeft, child: rolBadge)),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 2,
                  child: Text(
                    dni,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.mono.copyWith(color: c.textSecondary),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 3,
                  child: Text(
                    empresa,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.bodySm,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(flex: 2, child: Align(
                  alignment: Alignment.centerLeft, child: estadoBadge)),
                chevron,
              ],
            )
          // MOBILE: persona arriba + (rol · empresa) y estado debajo.
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: persona()),
                    const SizedBox(width: AppSpacing.sm),
                    estadoBadge,
                    const SizedBox(width: 4),
                    chevron,
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    rolBadge,
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        empresa,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

/// Acorta la razón social larga para la columna EMPRESA. Quita el CUIT
/// entre paréntesis y normaliza " S.R.L:" → " SRL". Dato faltante → '—'.
String _empresaCorta(String raw) {
  final t = raw.trim();
  if (t.isEmpty || t == '-') return '—';
  // Cortamos en el primer '(' o ':' (donde suele arrancar el CUIT).
  var s = t;
  final corte = s.indexOf(RegExp(r'[(:]'));
  if (corte > 0) s = s.substring(0, corte);
  return s.trim().isEmpty ? t : s.trim();
}

/// Estado de vencimiento resumido para la sub-línea de la fila.
class _VencResumen {
  final String label;
  final Color color;
  const _VencResumen(this.label, this.color);
}

/// Devuelve el PEOR (más urgente) de los 3 vencimientos personales, o `null`
/// si ninguno amerita alerta (todos OK / sin fecha). Reusa la lógica y umbrales
/// canónicos de `vencimiento_badge.dart` — no inventa nada.
_VencResumen? _peorVencimiento(Map<String, dynamic> data) {
  const items = <(String, String)>[
    ('Licencia', 'VENCIMIENTO_LICENCIA_DE_CONDUCIR'),
    ('Preocupacional', 'VENCIMIENTO_PREOCUPACIONAL'),
    ('Manejo def.', 'VENCIMIENTO_CURSO_DE_MANEJO_DEFENSIVO'),
  ];
  VencimientoEstado? peorEstado;
  String? peorEtiqueta;
  int? peorDias;
  for (final (etiqueta, campo) in items) {
    final fecha = data[campo];
    final tieneFecha = fecha != null && fecha.toString().isNotEmpty;
    if (!tieneFecha) continue;
    final dias = AppFormatters.calcularDiasRestantes(fecha);
    final estado = calcularEstadoVencimiento(dias, tieneFecha: tieneFecha);
    // Solo nos interesan los accionables: vencido/critico/proximo/invalida.
    if (estado == VencimientoEstado.ok ||
        estado == VencimientoEstado.sinFecha) {
      continue;
    }
    // Menor index = más urgente (ver enum VencimientoEstado).
    if (peorEstado == null || estado.index < peorEstado.index) {
      peorEstado = estado;
      peorEtiqueta = etiqueta;
      peorDias = dias;
    }
  }
  if (peorEstado == null) return null;
  final sufijo = switch (peorEstado) {
    VencimientoEstado.vencido => 'vencido',
    VencimientoEstado.invalida => 'fecha inválida',
    _ => peorDias != null ? '${peorDias}d' : '',
  };
  final label = sufijo.isEmpty ? peorEtiqueta! : '$peorEtiqueta · $sufijo';
  return _VencResumen(label, peorEstado.color);
}

/// Color de la pill de rol. CHOFER neutro (caso esperado), ADMIN en brand
/// (atención), supervisor ámbar, el resto info.
Color _colorRol(String rol, AppColorsExt c) {
  switch (rol) {
    case AppRoles.admin:
      return c.brand;
    case AppRoles.supervisor:
      return c.warning;
    case AppRoles.chofer:
      return c.textSecondary;
  }
  return c.info;
}

/// Etiqueta legible para un rol normalizado. Usa `AppRoles.etiquetas` (fuente
/// de verdad de los 6 roles) con fallback capitalizado.
String _rolLabel(String rol) {
  final etiqueta = AppRoles.etiquetas[rol];
  if (etiqueta != null) return etiqueta;
  if (rol.isEmpty) return '—';
  return rol[0].toUpperCase() + rol.substring(1).toLowerCase();
}
