import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/capabilities.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_breakpoints.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../auth/services/auth_service.dart';
import '../../gomeria/screens/gomeria_v2_hub_screen.dart';
import '../../vehicles/providers/vehiculo_provider.dart';
import '../../vehicles/services/vehiculo_repository.dart';

/// Panel principal — REFACTOR 2026-05-24.
///
/// **Antes:** grid 2×2 con tiles de colores neón (azul / naranja / verde /
/// rojo), saludo "BIENVENIDO" + nombre en 32px, footer "Legajo: X · Rol: Y".
///
/// **Ahora:**
/// - Saludo con hora del día + nombre + línea de estado real
///   ("Todos tus papeles al día" / "ART vence en 23 días" / "Tenés 1
///   trámite en revisión") leída del doc del legajo.
/// - 2 tiles cuadradas (Mi Perfil / Mi Unidad) en sentence case, sin
///   colores de categoría — solo iconos sobre surface3 chip.
/// - "Mis Vencimientos" promovido a tile full-width con preview del
///   próximo vencimiento + countdown ("ART · vence el 14-06 · faltan 23d").
/// - Si admin, una 4ta tile full-width para "Panel de administración".
/// - Sin all-caps gritado, sin letter-spacing exagerado.
class MainPanel extends StatelessWidget {
  final String dni;
  final String nombre;
  final String rol;

  MainPanel({
    super.key,
    required this.dni,
    required this.nombre,
    required this.rol,
  });

  final AuthService _authService = AuthService();

  bool get _isAdmin => rol.trim().toUpperCase() == 'ADMIN';

  /// Puede entrar al Panel de administración (shell). ADMIN, SUPERVISOR y
  /// SEG_HIGIENE. GOMERIA ya NO (2026-05-30): va directo a su módulo. Antes el
  /// tile de acceso se mostraba SOLO a ADMIN (bug: un SUPERVISOR no entraba).
  bool get _puedeVerPanelAdmin =>
      Capabilities.can(rol, Capability.verPanelAdmin);

  /// GOMERIA — rol especializado del taller. En el menú de inicio ve un tile
  /// "Gomería" que abre directo el hub, en vez de "Panel de administración".
  bool get _esGomeria => AppRoles.normalizar(rol) == AppRoles.gomeria;

  /// Tiles personales "Mi unidad" + "Mis vencimientos": las ven los choferes
  /// (CHOFER/PLANTA, que usan el shell de chofer) y el ADMIN. Los roles
  /// especializados (SUPERVISOR/GOMERIA/SEG_HIGIENE) NO conducen → no las
  /// necesitan (pedido Santiago 2026-05-30).
  bool get _mostrarTilesPersonales =>
      _isAdmin || (!_puedeVerPanelAdmin && !_esGomeria);

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      // Sin título: el menú de inicio muestra solo el logo (el título era
      // appName y se duplicaba con el logo, se veía "Coopertrans Móvil" 2 veces).
      actions: [
        IconButton(
          icon: const Icon(Icons.logout_outlined),
          tooltip: 'Cerrar sesión',
          onPressed: () => _logout(context),
        ),
      ],
      body: Center(
        child: ConstrainedBox(
          // Mobile: full width. Tablet/desktop: cap para que el layout
          // no se estire ilegible en monitores grandes.
          constraints: BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth(context),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: AppSpacing.lg),
                _GreetingCard(dni: dni, nombre: nombre),
                const SizedBox(height: AppSpacing.lg),
                if (_mostrarTilesPersonales) ...[
                  Row(
                    children: [
                      Expanded(
                        child: _TileSquare(
                          titulo: 'Mi perfil',
                          icono: Icons.person_outline,
                          onTap: () => Navigator.pushNamed(
                            context,
                            AppRoutes.perfil,
                            arguments: dni,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: _TileSquare(
                          titulo: 'Mi unidad',
                          icono: Icons.local_shipping_outlined,
                          onTap: () => Navigator.pushNamed(
                            context,
                            AppRoutes.equipo,
                            arguments: dni,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _TileVencimientos(dni: dni),
                ] else
                  // Roles admin que no conducen (supervisor / gomería / seg.
                  // higiene): sin "Mi unidad" ni "Mis vencimientos", solo perfil.
                  _TileWide(
                    titulo: 'Mi perfil',
                    subtitulo: 'Tus datos personales',
                    icono: Icons.person_outline,
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.perfil,
                      arguments: dni,
                    ),
                  ),
                if (_esGomeria) ...[
                  const SizedBox(height: AppSpacing.md),
                  _TileWide(
                    titulo: 'Gomería',
                    subtitulo: 'Stock, montar y retirar cubiertas',
                    icono: Icons.tire_repair_outlined,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const GomeriaV2HubScreen(),
                      ),
                    ),
                  ),
                ] else if (_puedeVerPanelAdmin) ...[
                  const SizedBox(height: AppSpacing.md),
                  _TileWide(
                    titulo: 'Panel de administración',
                    subtitulo: 'Personal, flota, vencimientos y más',
                    icono: Icons.admin_panel_settings_outlined,
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.adminPanel,
                    ),
                  ),
                ],
                const Spacer(),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.lg,
                    ),
                    child: Text(
                      'Legajo $dni · ${rol.toLowerCase()}',
                      style: AppType.label.copyWith(
                        color: AppColors.textDisabled,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final navigator = Navigator.of(context);
    try {
      context.read<VehiculoRepository>().clearStreamCache();
      context.read<VehiculoProvider>().clearAll();
    } catch (e) {
      debugPrint('Aviso: no se pudo limpiar estado al logout: $e');
    }
    await _authService.logout();
    if (!context.mounted) return;
    unawaited(navigator.pushNamedAndRemoveUntil('/', (route) => false));
  }
}

// =============================================================================
// GREETING — saludo con hora + estado real
// =============================================================================

class _GreetingCard extends StatefulWidget {
  final String dni;
  final String nombre;
  const _GreetingCard({required this.dni, required this.nombre});

  @override
  State<_GreetingCard> createState() => _GreetingCardState();
}

class _GreetingCardState extends State<_GreetingCard> {
  late String _apodoResuelto = PrefsService.apodo.trim();

  @override
  void initState() {
    super.initState();
    if (_apodoResuelto.isEmpty) {
      _resolverApodoLegacy();
    }
  }

  Future<void> _resolverApodoLegacy() async {
    final dni = widget.dni.trim();
    if (dni.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(dni)
          .get();
      if (!mounted) return;
      final apodo = (snap.data()?['APODO'] ?? '').toString().trim();
      if (apodo.isEmpty) return;
      setState(() => _apodoResuelto = apodo);
      unawaited(PrefsService.setApodo(apodo));
    } catch (_) {}
  }

  String _saludoHora() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Buen día';
    if (h < 19) return 'Buenas tardes';
    return 'Buenas noches';
  }

  String _primerNombre(String full) {
    final partes = full.trim().split(RegExp(r'\s+'));
    if (partes.isEmpty) return '';
    final n = partes.length >= 2 ? partes[1] : partes.first;
    if (n.isEmpty) return '';
    return '${n[0].toUpperCase()}${n.substring(1).toLowerCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final nombre = _apodoResuelto.isNotEmpty
        ? _apodoResuelto
        : _primerNombre(widget.nombre);

    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_saludoHora(), style: AppType.label),
          const SizedBox(height: AppSpacing.xs),
          Text(nombre, style: AppType.display),
          const SizedBox(height: AppSpacing.md),
          _LineaEstado(dni: widget.dni),
        ],
      ),
    );
  }
}

/// Catálogo central de los papeles del chofer que viven en su legajo
/// (`EMPLEADOS/{dni}`). Las keys son los nombres reales de Firestore
/// (convención: `VENCIMIENTO_<sufijo>`). Mantener consistente con
/// `AppDocsEmpleado.etiquetas` en `lib/core/constants/app_constants.dart`.
const Map<String, String> _papelesChofer = {
  'VENCIMIENTO_LICENCIA_DE_CONDUCIR': 'Licencia',
  'VENCIMIENTO_PREOCUPACIONAL': 'Preocupacional',
  'VENCIMIENTO_CURSO_DE_MANEJO_DEFENSIVO': 'Manejo Defensivo',
};

/// Catálogo central de los papeles de la EMPRESA EMPLEADORA del chofer
/// — viven en `EMPRESAS_EMPLEADORAS/{cuit}` y son comunes a todos los
/// empleados de esa razón social (Vecchi Ariel o Sucesión Vecchi Carlos).
/// Migración 2026-05-08. La rule deja al chofer leer SOLO su propia
/// empresa (matchea contra `EMPRESA_CUIT` denormalizado en su legajo).
const Map<String, String> _papelesEmpresa = {
  'VENCIMIENTO_POLIZA_ART': 'ART',
  'VENCIMIENTO_FORMULARIO_931': 'F.931',
  'VENCIMIENTO_SCVO': 'Seguro de Vida',
  'VENCIMIENTO_LIBRE_DE_DEUDA_SINDICAL': 'Sindicato',
};

/// Lee el legajo del chofer + (opcional) los docs de su empresa
/// empleadora y compone una línea humana con el estado:
/// "Todos tus papeles al día" / "ART vence en 23 días" / "Tenés papeles
/// vencidos" / "1 trámite en revisión".
///
/// Hace 2 streams anidados:
///   1. EMPLEADOS/{dni}  → siempre (3 docs del chofer + REVISIONES_PENDIENTES).
///   2. EMPRESAS_EMPLEADORAS/{cuit} → si el legajo tiene `EMPRESA_CUIT`
///      denormalizado (verificado 2026-05-27: 67/67 empleados lo tienen).
class _LineaEstado extends StatelessWidget {
  final String dni;
  const _LineaEstado({required this.dni});

  @override
  Widget build(BuildContext context) {
    final empStream = FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .doc(dni)
        .snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: empStream,
      builder: (ctx, empSnap) {
        if (!empSnap.hasData) {
          return _badge(
            color: AppColors.textTertiary,
            label: 'Cargando estado…',
          );
        }
        final empData = empSnap.data?.data() ?? const <String, dynamic>{};
        final cuit = (empData['EMPRESA_CUIT'] ?? '').toString().trim();

        // Sin EMPRESA_CUIT → solo papeles del chofer (caso edge defensivo).
        if (cuit.isEmpty) {
          final estado = _resolverEstado(empData, const {});
          return _badge(color: estado.color, label: estado.label);
        }

        // Con CUIT → segundo stream para los 4 docs de empresa.
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection(AppCollections.empresasEmpleadoras)
              .doc(cuit)
              .snapshots(),
          builder: (ctx2, empresaSnap) {
            // Si la lectura de empresa falla o todavía no llegó, mostramos
            // estado solo con papeles del chofer — no bloqueamos la UI.
            final empresaData = empresaSnap.hasError || !empresaSnap.hasData
                ? const <String, dynamic>{}
                : (empresaSnap.data?.data() ?? const <String, dynamic>{});
            final estado = _resolverEstado(empData, empresaData);
            return _badge(color: estado.color, label: estado.label);
          },
        );
      },
    );
  }

  Widget _badge({required Color color, required String label}) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            label,
            style: AppType.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }

  /// Combina los docs de empleado y empresa en un (color, mensaje) único.
  ///
  /// **Reglas** (ordenadas por prioridad — la primera que matchea gana):
  /// 1. Algún papel vencido → error rojo.
  /// 2. Algún trámite en revisión pendiente → info azul.
  /// 3. Algún papel vence ≤ 7d → warning con countdown del más cercano.
  /// 4. Algún papel vence ≤ 30d → warning con "Próximo: X en N días".
  /// 5. Todo bien → success verde.
  ({Color color, String label}) _resolverEstado(
    Map<String, dynamic> empleado,
    Map<String, dynamic> empresa,
  ) {
    final hoy = DateTime.now();
    DateTime? proximaFecha;
    String? proximaEtiqueta;
    int vencidos = 0;

    void considerar(Map<String, dynamic> doc, Map<String, String> papeles) {
      papeles.forEach((key, etiqueta) {
        final fecha = _parseFecha(doc[key]);
        if (fecha == null) return;
        final dias = fecha.difference(hoy).inDays;
        if (dias < 0) {
          vencidos++;
        } else if (proximaFecha == null || fecha.isBefore(proximaFecha!)) {
          proximaFecha = fecha;
          proximaEtiqueta = etiqueta;
        }
      });
    }

    considerar(empleado, _papelesChofer);
    considerar(empresa, _papelesEmpresa);

    if (vencidos > 0) {
      return (
        color: AppColors.error,
        label: vencidos == 1
            ? 'Tenés 1 papel vencido — entrá a verlos'
            : 'Tenés $vencidos papeles vencidos',
      );
    }
    final pendientesRev = empleado['REVISIONES_PENDIENTES'];
    if (pendientesRev is num && pendientesRev > 0) {
      return (
        color: AppColors.info,
        label: pendientesRev == 1
            ? '1 trámite en revisión'
            : '$pendientesRev trámites en revisión',
      );
    }
    if (proximaFecha != null && proximaEtiqueta != null) {
      final dias = proximaFecha!.difference(hoy).inDays;
      if (dias <= 7) {
        return (
          color: AppColors.warning,
          label:
              'Vence $proximaEtiqueta en $dias ${dias == 1 ? "día" : "días"}',
        );
      }
      if (dias <= 30) {
        return (
          color: AppColors.warning,
          label: 'Próximo: $proximaEtiqueta en $dias días',
        );
      }
    }
    return (
      color: AppColors.success,
      label: 'Todos tus papeles al día',
    );
  }

  DateTime? _parseFecha(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is String && raw.isNotEmpty) {
      return DateTime.tryParse(raw);
    }
    return null;
  }
}

// =============================================================================
// TILES
// =============================================================================

/// Tile cuadrada — icono grande, label sentence-case. Sin colores de
/// categoría: el icono ya hace la identificación.
class _TileSquare extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final VoidCallback onTap;
  const _TileSquare({
    required this.titulo,
    required this.icono,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tier: 2,
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: SizedBox(
        height: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surface3,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(icono, color: AppColors.textPrimary, size: 22),
            ),
            Text(
              titulo,
              style: AppType.heading,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Tile horizontal — icono a la izquierda, título + subtítulo, flecha.
class _TileWide extends StatelessWidget {
  final String titulo;
  final String? subtitulo;
  final IconData icono;
  final VoidCallback onTap;

  const _TileWide({
    required this.titulo,
    required this.icono,
    required this.onTap,
    this.subtitulo,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tier: 2,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.lg,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.surface3,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(
              icono,
              color: AppColors.textPrimary,
              size: 22,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo, style: AppType.heading),
                if (subtitulo != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitulo!,
                    style: AppType.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const Icon(
            Icons.arrow_forward_ios,
            color: AppColors.textHint,
            size: 14,
          ),
        ],
      ),
    );
  }
}

/// Tile especial de Vencimientos — full-width con preview del próximo.
/// Es la razón por la que la mayoría de choferes abren la app.
///
/// Mismo patrón que [_LineaEstado]: streams anidados de EMPLEADOS +
/// EMPRESAS_EMPLEADORAS para cubrir tanto los 3 papeles propios del
/// chofer como los 4 de su empresa empleadora.
class _TileVencimientos extends StatelessWidget {
  final String dni;
  const _TileVencimientos({required this.dni});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(dni)
          .snapshots(),
      builder: (ctx, empSnap) {
        final empData = empSnap.data?.data() ?? const <String, dynamic>{};
        final cuit = (empData['EMPRESA_CUIT'] ?? '').toString().trim();
        if (cuit.isEmpty) {
          final subtitulo = _resumirProximos(empData, const {});
          return _tile(ctx, subtitulo);
        }
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection(AppCollections.empresasEmpleadoras)
              .doc(cuit)
              .snapshots(),
          builder: (ctx2, empresaSnap) {
            final empresaData = empresaSnap.hasError || !empresaSnap.hasData
                ? const <String, dynamic>{}
                : (empresaSnap.data?.data() ?? const <String, dynamic>{});
            final subtitulo = _resumirProximos(empData, empresaData);
            return _tile(ctx, subtitulo);
          },
        );
      },
    );
  }

  Widget _tile(BuildContext ctx, String subtitulo) => _TileWide(
        titulo: 'Mis vencimientos',
        subtitulo: subtitulo,
        icono: Icons.event_note_outlined,
        onTap: () => Navigator.pushNamed(
          ctx,
          AppRoutes.misVencimientos,
          arguments: dni,
        ),
      );

  String _resumirProximos(
    Map<String, dynamic> empleado,
    Map<String, dynamic> empresa,
  ) {
    final hoy = DateTime.now();
    DateTime? proxFecha;
    String? proxLabel;
    int vencidos = 0;
    int en7 = 0;

    void considerar(Map<String, dynamic> doc, Map<String, String> papeles) {
      papeles.forEach((k, label) {
        final raw = doc[k];
        DateTime? fecha;
        if (raw is Timestamp) fecha = raw.toDate();
        if (raw is String && raw.isNotEmpty) fecha = DateTime.tryParse(raw);
        if (fecha == null) return;
        final dias = fecha.difference(hoy).inDays;
        if (dias < 0) {
          vencidos++;
        } else {
          if (dias <= 7) en7++;
          if (proxFecha == null || fecha.isBefore(proxFecha!)) {
            proxFecha = fecha;
            proxLabel = label;
          }
        }
      });
    }

    considerar(empleado, _papelesChofer);
    considerar(empresa, _papelesEmpresa);

    if (vencidos > 0) {
      return 'Tenés $vencidos vencido${vencidos == 1 ? "" : "s"} — revisá';
    }
    if (en7 > 0) return '$en7 ${en7 == 1 ? "vence" : "vencen"} esta semana';
    if (proxFecha != null && proxLabel != null) {
      final dias = proxFecha!.difference(hoy).inDays;
      return 'Próximo: $proxLabel en $dias días';
    }
    return 'Todo al día';
  }
}
