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
/// encabezado `PERSONAL · n empleados` + strip de CARDS-FILTRO por grupo de
/// roles (TODOS · CHOFERES · PLANTA · ADMINISTRACIÓN) + lista densa
/// (`_FilaPersona`) en una superficie `AppCard(tier:1)` por fila, con
/// `AppHairline` implícita entre filas (borde de cards adyacentes).
///
/// La fila es responsive (desktop spread en columnas; mobile apila rol/empresa
/// bajo el nombre) y abre el MISMO detalle (`_DetalleChofer.abrir`), así que no
/// se pierde ninguna acción. La capa de datos NO cambia: stream EMPLEADOS,
/// `_visible()` (activo/excluido/rol), filtro de búsqueda de `AppListPage`,
/// toggles de inactivos/excluidos, FAB "Nuevo" y navegación quedan intactos.
///
/// Las CARDS del strip son ahora el filtro INTERACTIVO, agrupando roles
/// (Santiago 2026-06-10): tocar una acota la lista; la activa se resalta.
/// Reemplazaron a los chips por rol y a la card no-interactiva ACTIVOS.
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

  /// Grupo de roles en foco (null = todos). Lo setean las cards-filtro del
  /// hero (Santiago 2026-06-10: reemplazaron los chips por rol).
  _GrupoPersonal? _grupoFiltro;

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
    if (_grupoFiltro != null &&
        !_grupoFiltro!.roles
            .contains(AppRoles.normalizar(data['ROL']?.toString()))) {
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
              grupoFiltro: _grupoFiltro,
              onGrupo: (g) => setState(() => _grupoFiltro = g),
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
// HERO + CARDS-FILTRO POR GRUPO DE ROLES
// =============================================================================

/// Grupos de filtro de Personal (Santiago 2026-06-10): las cards de arriba
/// AGRUPAN roles y SON el filtro (reemplazan los chips por rol). TODOS = sin
/// filtro; CHOFERES = CHOFER; PLANTA = los operativos sin vehículo (planta,
/// taller, gomería, seguridad e higiene); ADMINISTRACIÓN = supervisores +
/// admin. Los 6 roles quedan cubiertos sin solaparse (suma = total).
enum _GrupoPersonal {
  choferes('Choferes', {AppRoles.chofer}),
  planta('Planta', {AppRoles.planta, AppRoles.gomeria, AppRoles.segHigiene}),
  administracion('Administración', {AppRoles.supervisor, AppRoles.admin});

  const _GrupoPersonal(this.label, this.roles);
  final String label;
  final Set<String> roles;
}

class _HeroYChips extends StatelessWidget {
  final List<QueryDocumentSnapshot> docs;
  final ExcluidosSet? excluidos;
  final bool mostrarExcluidos;
  final bool mostrarInactivos;
  final _GrupoPersonal? grupoFiltro;
  final ValueChanged<_GrupoPersonal?> onGrupo;
  final VoidCallback onToggleInactivos;

  const _HeroYChips({
    required this.docs,
    required this.excluidos,
    required this.mostrarExcluidos,
    required this.mostrarInactivos,
    required this.grupoFiltro,
    required this.onGrupo,
    required this.onToggleInactivos,
  });

  @override
  Widget build(BuildContext context) {
    final esDesktop = AppBreakpoints.isDesktopOrLarger(context);

    // Un barrido sobre los docs con los filtros de VISIBILIDAD (excluidos +
    // inactivos) — los mismos que `_visible` salvo el de grupo (las cards
    // muestran el conteo de TODOS los grupos). Cero números hardcodeados.
    var totalVisibles = 0;
    final porRol = <String, int>{};
    for (final d in docs) {
      final data = d.data() as Map<String, dynamic>;
      if (!mostrarExcluidos &&
          ExcluidosService.esExcluido(excluidos, dni: d.id)) {
        continue;
      }
      if (!mostrarInactivos && !AppActivo.esActivo(data)) continue;
      totalVisibles++;
      final rol = AppRoles.normalizar(data['ROL']?.toString());
      porRol[rol] = (porRol[rol] ?? 0) + 1;
    }

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
          // Cards-filtro por GRUPO de roles (Santiago 2026-06-10): TODOS ·
          // CHOFERES · PLANTA · ADMINISTRACIÓN. Tocar una filtra la lista; la
          // activa se resalta. Reemplazan al strip no-interactivo + los chips
          // por rol (y se quitó ACTIVOS, redundante con el conteo del hero).
          _StripGrupos(
            esDesktop: esDesktop,
            grupoFiltro: grupoFiltro,
            onGrupo: onGrupo,
            total: totalVisibles,
            porRol: porRol,
          ),
        ],
      ),
    );
  }
}

/// Strip de cards-filtro por grupo de roles. Estética calcada de `AppKpiStrip`
/// (surface2 + border + hairlines) pero con celdas tappeables. Desktop: las
/// celdas reparten el ancho (Expanded); mobile: scroll horizontal.
class _StripGrupos extends StatelessWidget {
  final bool esDesktop;
  final _GrupoPersonal? grupoFiltro;
  final ValueChanged<_GrupoPersonal?> onGrupo;
  final int total;
  final Map<String, int> porRol;
  const _StripGrupos({
    required this.esDesktop,
    required this.grupoFiltro,
    required this.onGrupo,
    required this.total,
    required this.porRol,
  });

  int _count(_GrupoPersonal g) =>
      g.roles.fold(0, (s, r) => s + (porRol[r] ?? 0));

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final celdas = <Widget>[
      _CeldaGrupo(
        label: 'Todos',
        valor: total,
        seleccionado: grupoFiltro == null,
        esDesktop: esDesktop,
        onTap: () => onGrupo(null),
      ),
      for (final g in _GrupoPersonal.values)
        _CeldaGrupo(
          label: g.label,
          valor: _count(g),
          seleccionado: grupoFiltro == g,
          esDesktop: esDesktop,
          onTap: () => onGrupo(g),
        ),
    ];
    final fila = IntrinsicHeight(
      child: Row(
        children: [
          for (var i = 0; i < celdas.length; i++) ...[
            if (esDesktop) Expanded(child: celdas[i]) else celdas[i],
            if (i < celdas.length - 1) Container(width: 1, color: c.border),
          ],
        ],
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: esDesktop
            ? fila
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal, child: fila),
      ),
    );
  }
}

/// Una celda del strip de grupos. Tappeable; resalta con tinte brand cuando
/// es el grupo en foco. En mobile fija un mínimo para que sea tappeable.
class _CeldaGrupo extends StatelessWidget {
  final String label;
  final int valor;
  final bool seleccionado;
  final bool esDesktop;
  final VoidCallback onTap;
  const _CeldaGrupo({
    required this.label,
    required this.valor,
    required this.seleccionado,
    required this.esDesktop,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final contenido = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: esDesktop ? 22 : 14,
        vertical: esDesktop ? 18 : 14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.eyebrow.copyWith(
              color: seleccionado ? c.brand : c.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$valor',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.h2.copyWith(
              color: c.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    final celda = ConstrainedBox(
      constraints: BoxConstraints(minWidth: esDesktop ? 0 : 118),
      child: ColoredBox(
        color: seleccionado
            ? c.brand.withValues(alpha: 0.12)
            : Colors.transparent,
        child: contenido,
      ),
    );
    return InkWell(onTap: onTap, child: celda);
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
