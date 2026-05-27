import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/capabilities.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';

import '../../employees/screens/admin_personal_lista_screen.dart';
import '../../expirations/screens/admin_vencimientos_menu_screen.dart';
import '../../reports/screens/admin_reports_screen.dart';
import '../../zonas_descarga/screens/admin_descargas_screen.dart';
import '../../auditoria_asignaciones/screens/admin_auditoria_asignaciones_screen.dart';
import '../../fleet_map/screens/admin_mapa_flota_screen.dart';
import '../../icm/screens/icm_hub_screen.dart';
import '../../cachatore/screens/cachatore_hub_screen.dart';
import '../../gomeria/screens/gomeria_hub_screen.dart';
import '../../logistica/screens/logistica_hub_screen.dart';
import '../../vehicles/screens/admin_mantenimiento_screen.dart';
import '../../vehicles/screens/admin_vehiculos_lista_screen.dart';

import 'admin_estado_bot_screen.dart';
import 'admin_panel_screen.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
/// Shell principal del admin con navegación lateral.
///
/// - **Desktop (≥ 800px)**: NavigationRail a la izquierda con labels.
/// - **Mobile (< 800px)**: BottomNavigationBar abajo con iconos.
///
/// Cada sección renderiza la pantalla correspondiente "embebida"
/// (sin AppBar propio — el shell tiene su propio AppBar dinámico).
///
/// El badge de "Revisiones" se actualiza en tiempo real escuchando
/// la colección REVISIONES de Firestore.
class AdminShell extends StatefulWidget {
  const AdminShell({super.key});

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _currentIndex = 0;

  // ============= LISTENER de notificaciones (avisos al admin) =============
  StreamSubscription? _revisionesSubscription;
  bool _esPrimeraCarga = true;

  /// Definición declarativa de las secciones del shell.
  /// Cada una incluye su pantalla, label, icon y un builder opcional
  /// para badges dinámicos.
  // Orden definido por Vecchi 2026-05-07: Personal → Flota →
  // Revisiones → Vencimientos → Logística → Gomería → Service →
  // Alertas → Reportes → Sync → Estado Bot. El bloque Volvo
  // (Eco-Driving / Descargas / Mapa) queda intercalado después de
  // Alertas porque las 4 pantallas comparten capability y fuente de
  // datos — visualmente conviene agruparlas. El panel central
  // (admin_panel_screen.dart) usa el mismo orden para las 11 entradas
  // operativas (sin Inicio ni el bloque Volvo, que ya tiene su propio
  // tile principal en "Alertas").
  late final List<_ShellSection> _sections = [
    _ShellSection(
      label: 'Inicio',
      icon: Icons.dashboard_outlined,
      iconActive: Icons.dashboard,
      build: () => const AdminPanelScreen(),
      requiredCapability: Capability.verPanelAdmin,
    ),
    // Vista Ejecutiva ELIMINADA del shell 2026-05-18 — sus secciones
    // (Panorama del mes, Tendencias, Personas) estan integradas en
    // INICIO arriba. Si el rol tiene capability verVistaEjecutiva,
    // INICIO carga las secciones ricas automaticamente.
    _ShellSection(
      label: 'Personal',
      icon: Icons.badge_outlined,
      iconActive: Icons.badge,
      build: () => const AdminPersonalListaScreen(),
      requiredCapability: Capability.verListaPersonal,
    ),
    _ShellSection(
      label: 'Flota',
      icon: Icons.local_shipping_outlined,
      iconActive: Icons.local_shipping,
      build: () => const AdminVehiculosListaScreen(),
      requiredCapability: Capability.verListaFlota,
    ),
    // Revisiones movido a Vencimientos como sub-item (2026-05-24) — antes
    // era un tab propio. Se sigue accediendo a `/admin_revisiones`, solo
    // cambió la puerta de entrada. El badge de pendientes ahora se muestra
    // sobre el tab "Vencimientos" (que las contiene).
    _ShellSection(
      label: 'Vencimientos',
      icon: Icons.assignment_late_outlined,
      iconActive: Icons.assignment_late,
      build: () => const AdminVencimientosMenuScreen(),
      requiredCapability: Capability.verVencimientos,
      // .limit(100) cap conservador (ver auditoría 2026-05-18): si el
      // stream trae 100 docs sabemos que hay >=100 → mostramos "99+".
      //
      // Filtro explícito `estado == PENDIENTE` (2026-05-27): hoy el flujo
      // BORRA el doc al aprobar/rechazar (revision_service.dart líneas
      // 399/564/578), pero un doc tirado con otro estado por debug o un
      // estado intermedio futuro inflaría el badge sin acción posible.
      // Filtrar explícito empareja con la query del propio service en
      // línea 419 y mantiene el badge fiel al "lo que se ve en la
      // pantalla de Revisiones".
      badgeStream: FirebaseFirestore.instance
          .collection(AppCollections.revisiones)
          .where('estado', isEqualTo: 'PENDIENTE')
          .limit(100)
          .snapshots(),
    ),
    _ShellSection(
      label: 'Logística',
      icon: Icons.route_outlined,
      iconActive: Icons.route,
      requiredCapability: Capability.verLogistica,
      build: () => const LogisticaHubScreen(),
    ),
    _ShellSection(
      label: 'Gomería',
      icon: Icons.tire_repair_outlined,
      iconActive: Icons.tire_repair,
      requiredCapability: Capability.verGomeria,
      build: () => const GomeriaHubScreen(),
    ),
    _ShellSection(
      label: 'Mantenimiento',
      icon: Icons.build_circle_outlined,
      iconActive: Icons.build_circle,
      requiredCapability: Capability.verMantenimiento,
      // Badge: cuenta tractores que cruzaron a VENCIDO. La colección
      // se popula desde VehiculoManager._evaluarMantenimiento; al
      // sumar/sacar un tractor del estado, el badge se actualiza solo.
      // Filtro simple por un solo campo, no necesita índice compuesto.
      badgeStream: FirebaseFirestore.instance
          .collection(AppCollections.mantenimientosAvisados)
          .where('ultimo_estado', isEqualTo: 'VENCIDO')
          .limit(100)
          .snapshots(),
      build: () => const AdminMantenimientoScreen(),
    ),
    // ─── ICM (Indice de Conducta de Manejo) ─────────────────────────
    // Reemplaza a "Alertas" + "Eco-Driving" del menú admin (2026-05-15).
    // Las alertas crudas se reparten consolidadas vía WhatsApp diario
    // (Molina y Emmanuel reciben sus resúmenes); este módulo da la
    // vista unificada para gestionar conducta de manejo a nivel YPF.
    _ShellSection(
      label: 'ICM',
      icon: Icons.leaderboard_outlined,
      iconActive: Icons.leaderboard,
      requiredCapability: Capability.verIcm,
      build: () => const IcmHubScreen(),
    ),
    _ShellSection(
      label: 'Descargas',
      icon: Icons.local_shipping_outlined,
      iconActive: Icons.local_shipping,
      requiredCapability: Capability.verAlertasVolvo,
      // Cola en vivo + recién descargaron + KPIs basado en presencia REAL
      // en geocercas configurables (ZONAS_DESCARGA). Reemplazó al detector
      // PTO Volvo (falsos positivos + solo flota Volvo) el 2026-05-24.
      build: () => const AdminDescargasScreen(),
    ),
    // Auditoría asignaciones: cruce iButton real (SITRACK) vs el asignado
    // en ASIGNACIONES_VEHICULO. Sumado al shell 2026-05-25 para igualar
    // el orden de tiles del panel admin (accesos rápidos).
    _ShellSection(
      label: 'Auditoría',
      icon: Icons.fact_check_outlined,
      iconActive: Icons.fact_check,
      requiredCapability: Capability.verAlertasVolvo,
      build: () => const AdminAuditoriaAsignacionesScreen(),
    ),
    // "Mapa" muestra la posición ACTUAL de toda la flota según Sitrack
    // (tractores Volvo + no-Volvo). Reusa la capability de Volvo porque
    // el acceso es del mismo nivel admin/supervisor.
    //
    // El "Mapa Volvo" anterior (eventos Volvo geo-localizados, heatmap
    // OVERSPEED, ruta del chofer) ya NO es tab del shell. Vive como
    // acción "Ver en mapa" dentro del tablero de Alertas — están
    // conceptualmente ligados (el mapa muestra los mismos eventos del
    // tablero) y antes confundía tener dos accesos paralelos. Reusamos
    // el label "Mapa" (en vez de "Flota") porque es más reconocible:
    // cuando el admin piensa "dónde están mis camiones AHORA" busca
    // "Mapa", no "Flota".
    _ShellSection(
      label: 'Mapa',
      icon: Icons.map_outlined,
      iconActive: Icons.map,
      requiredCapability: Capability.verAlertasVolvo,
      build: () => const AdminMapaFlotaScreen(),
    ),
    // ─── Cierre: reportes + bots ─────────────────────
    _ShellSection(
      label: 'Reportes',
      icon: Icons.analytics_outlined,
      iconActive: Icons.analytics,
      build: () => const AdminReportsScreen(),
      requiredCapability: Capability.verReportes,
    ),
    // Bots al final (Cachatore + Estado Bot juntos, 2026-05-24): son los
    // dos "agentes automáticos" del sistema (turnos YPF + WhatsApp). El
    // panel admin (admin_panel_screen.dart) usa el mismo orden.
    _ShellSection(
      label: 'Cachatore',
      icon: Icons.schedule,
      iconActive: Icons.schedule,
      requiredCapability: Capability.verCachatore,
      build: () => const CachatoreHubScreen(),
    ),
    _ShellSection(
      label: 'WhatsApp Bot',
      icon: Icons.smart_toy_outlined,
      iconActive: Icons.smart_toy,
      build: () => const AdminEstadoBotScreen(),
      requiredCapability: Capability.verEstadoBot,
    ),
  ];

  /// Subset de `_sections` que el usuario logueado puede ver, segun
  /// las capabilities de su rol. Las secciones sin `requiredCapability`
  /// (ej. Inicio, si no la tuviera) se muestran siempre.
  List<_ShellSection> get _seccionesVisibles {
    final rol = PrefsService.rol;
    return _sections.where((s) {
      final cap = s.requiredCapability;
      return cap == null || Capabilities.can(rol, cap);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _activarEscuchaRevisiones();
  }

  @override
  void dispose() {
    _revisionesSubscription?.cancel();
    super.dispose();
  }

  /// Escucha nuevas revisiones para mostrar notificación push al admin.
  /// La primera carga se ignora para no spamear con todo lo que ya estaba.
  void _activarEscuchaRevisiones() {
    _revisionesSubscription = FirebaseFirestore.instance
        .collection(AppCollections.revisiones)
        .snapshots()
        .listen(
      (snapshot) {
        // Ignorar snapshots servidos desde CACHE: con persistencia de
        // Firestore el primer snapshot suele venir de cache (vacío/parcial)
        // y consumía el flag _esPrimeraCarga; al llegar el del SERVER, todos
        // los docs entraban como 'added' y disparaban avisos de revisiones
        // VIEJAS al abrir el shell. Esperamos el 1er snapshot del server.
        // Auditoría 2026-05-22.
        if (snapshot.metadata.isFromCache) return;
        if (_esPrimeraCarga) {
          _esPrimeraCarga = false;
          return;
        }
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final data = change.doc.data();
            if (data != null) {
              NotificationService.mostrarAvisoAdmin(
                chofer: data['nombre_usuario'] ?? 'Un chofer',
                documento: data['etiqueta'] ?? 'documento',
              );
            }
          }
        }
      },
      onError: (e) => debugPrint('Error stream revisiones: $e'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final esDesktop = MediaQuery.of(context).size.width >= 800;
    final visibles = _seccionesVisibles;
    // Clamp defensivo: si el rol cambia mid-session y la seccion
    // actual deja de ser visible (caso raro), volvemos al primer
    // destino disponible.
    if (_currentIndex >= visibles.length) _currentIndex = 0;
    final section = visibles[_currentIndex];

    return Scaffold(
      // El shell tiene su propio AppBar y fondo
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CoopertransLogo(size: CoopertransLogoSize.s),
            const SizedBox(width: 10),
            Container(width: 1, height: 14, color: Colors.white24),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                section.label.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
        centerTitle: false,
        titleSpacing: 12,
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        actions: [
          // Botón visible para abrir el palette desde la AppBar — además
          // de Ctrl+K — para que los admins que no recuerden el atajo
          // puedan acceder igual.
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Búsqueda rápida (Ctrl+K)',
            onPressed: () => CommandPalette.show(context),
          ),
          IconButton(
            icon: const Icon(Icons.exit_to_app),
            tooltip: 'Volver al menú principal',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: CommandPaletteShortcut(
        child: Stack(
          children: [
            // Gradient brand → fondo oscuro (mismo tratamiento que login,
            // splash y AppScaffold). Se ve a través del rail/bottombar.
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.brandDark,
                      AppColors.background,
                      AppColors.background,
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),
            // Layout responsive
            SafeArea(
              child: esDesktop
                  ? _buildDesktopLayout(section)
                  : _buildMobileLayout(section),
            ),
          ],
        ),
      ),
      bottomNavigationBar: esDesktop ? null : _buildBottomBar(),
    );
  }

  // ===========================================================================
  // LAYOUT DESKTOP — Rail + contenido
  // ===========================================================================
  Widget _buildDesktopLayout(_ShellSection section) {
    return Row(
      children: [
        // El rail necesita scroll cuando no entran todas las secciones a lo
        // alto (ej: pantallas chicas o cuando agregamos secciones nuevas).
        // NavigationRail por sí solo no scrollea — hay que envolverlo en
        // SingleChildScrollView + IntrinsicHeight con minHeight del viewport
        // para que se vea normal cuando entra todo y permita scroll cuando
        // no.
        LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: _buildNavigationRail(),
                ),
              ),
            );
          },
        ),
        Container(width: 1, color: Colors.white10),
        Expanded(
          child: AppShellContext(
            isEmbedded: true,
            child: section.build(),
          ),
        ),
      ],
    );
  }

  Widget _buildNavigationRail() {
    return NavigationRail(
      selectedIndex: _currentIndex,
      onDestinationSelected: (i) => setState(() => _currentIndex = i),
      labelType: NavigationRailLabelType.all,
      backgroundColor: Colors.transparent,
      selectedIconTheme:
          const IconThemeData(color: AppColors.success, size: 26),
      unselectedIconTheme:
          const IconThemeData(color: Colors.white54, size: 24),
      selectedLabelTextStyle: const TextStyle(
        color: AppColors.success,
        fontWeight: FontWeight.bold,
        fontSize: 11,
      ),
      unselectedLabelTextStyle: const TextStyle(
        color: Colors.white54,
        fontSize: 11,
      ),
      indicatorColor: AppColors.success.withAlpha(40),
      destinations: _seccionesVisibles
          .asMap()
          .entries
          .map(
            (e) => NavigationRailDestination(
              icon: _buildIconWithBadge(e.value, e.key, esActiva: false),
              selectedIcon:
                  _buildIconWithBadge(e.value, e.key, esActiva: true),
              label: Text(e.value.label),
            ),
          )
          .toList(),
    );
  }

  // ===========================================================================
  // LAYOUT MOBILE — solo contenido, BottomBar abajo
  // ===========================================================================
  Widget _buildMobileLayout(_ShellSection section) {
    return AppShellContext(
      isEmbedded: true,
      child: section.build(),
    );
  }

  /// Bottom bar mobile — máximo 4 destinos principales + ítem "Más" que
  /// abre un BottomSheet con el resto de las secciones.
  ///
  /// Razón: con 11-12 secciones visibles el `NavigationBar` Material 3
  /// daba ~33 dp por item en iPhone (393 dp width) y los labels se
  /// cortaban en "Inici", "Person", "Reporte"... La mejor práctica es
  /// limitar el bar a 5 destinos visuales (≤ 78 dp por item).
  ///
  /// Los 4 fijos son los más usados día a día (Inicio, Personal, Flota,
  /// Revisiones). El resto vive detrás de "Más" — a un tap de distancia,
  /// pero sin saturar la barra.
  static const _seccionesPrincipalesBottomBar = {
    'Inicio',
    'Personal',
    'Flota',
    'Revisiones',
  };

  Widget _buildBottomBar() {
    final visibles = _seccionesVisibles;
    // Filtramos las "principales" en el orden en que aparecen en
    // _sections (no por orden alfabético) — para mantener coherencia
    // visual con el rail desktop.
    final principales = <MapEntry<int, _ShellSection>>[];
    final otras = <MapEntry<int, _ShellSection>>[];
    for (var i = 0; i < visibles.length; i++) {
      final s = visibles[i];
      if (_seccionesPrincipalesBottomBar.contains(s.label)) {
        principales.add(MapEntry(i, s));
      } else {
        otras.add(MapEntry(i, s));
      }
    }

    // Si la sección actual NO está en las principales, marcamos "Más"
    // como activo para que el usuario sepa dónde está parado.
    final indiceActualEntrePrincipales = principales.indexWhere(
      (e) => e.key == _currentIndex,
    );
    final streamsOcultos = otras
        .map((e) => e.value.badgeStream)
        .whereType<Stream<QuerySnapshot>>()
        .toList();

    final selectedBarIndex = indiceActualEntrePrincipales >= 0
        ? indiceActualEntrePrincipales
        : principales.length; // último = "Más"

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Colors.white.withAlpha(15))),
      ),
      child: NavigationBar(
        selectedIndex: selectedBarIndex,
        onDestinationSelected: (i) {
          if (i < principales.length) {
            setState(() => _currentIndex = principales[i].key);
          } else {
            _abrirSheetMas(otras);
          }
        },
        backgroundColor: Colors.transparent,
        height: 70,
        labelBehavior:
            NavigationDestinationLabelBehavior.onlyShowSelected,
        destinations: [
          ...principales.map(
            (e) => NavigationDestination(
              icon: _buildIconWithBadge(e.value, e.key, esActiva: false),
              selectedIcon:
                  _buildIconWithBadge(e.value, e.key, esActiva: true),
              label: e.value.label,
            ),
          ),
          NavigationDestination(
            icon: _IconoMas(streams: streamsOcultos),
            selectedIcon: const Icon(Icons.more_horiz),
            label: 'Más',
          ),
        ],
      ),
    );
  }

  /// Bottom sheet con las secciones que no entran en la barra fija.
  /// Cada item muestra su badge si la sección lo tiene configurado.
  Future<void> _abrirSheetMas(
    List<MapEntry<int, _ShellSection>> otras,
  ) async {
    // Fix 2026-05-18 (bug iOS reportado Santiago): antes el sheet usaba
    // `Column` con `mainAxisSize.min` -> al haber muchas secciones
    // (7+ items en "Mas"), los items que no entraban en el 50% default
    // del sheet quedaban cortados sin scroll posible.
    //
    // Fix: `isScrollControlled: true` permite que el sheet crezca mas
    // del 50%, `ConstrainedBox` lo cappea al 80% (que no tape la barra
    // de status), y `Flexible + ListView` hace scrollable la lista de
    // items cuando excede el alto disponible.
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        final screenH = MediaQuery.of(sheetCtx).size.height;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: screenH * 0.8,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Handle visual del sheet (gesto de cierre intuitivo).
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      'MÁS SECCIONES',
                      style: TextStyle(
                        color: AppColors.success,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  // Lista scrollable de secciones. Flexible la cappea al
                  // alto disponible despues del handle + titulo.
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: otras
                          .map(
                            (e) => ListTile(
                              leading: _buildIconWithBadge(
                                e.value, e.key, esActiva: false,
                              ),
                              title: Text(
                                e.value.label,
                                style: const TextStyle(color: Colors.white),
                              ),
                              onTap: () {
                                Navigator.of(sheetCtx).pop();
                                setState(() => _currentIndex = e.key);
                              },
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // BADGE
  // ===========================================================================

  /// Renderiza el icono de la sección, agregando el badge rojo si tiene
  /// un stream de pendientes con docs > 0.
  Widget _buildIconWithBadge(
    _ShellSection section,
    int index, {
    required bool esActiva,
  }) {
    final icon = Icon(esActiva ? section.iconActive : section.icon);
    if (section.badgeStream == null) return icon;

    return StreamBuilder<QuerySnapshot>(
      stream: section.badgeStream,
      builder: (context, snap) {
        final count = snap.data?.docs.length ?? 0;
        if (count == 0) return icon;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            icon,
            Positioned(
              right: -6,
              top: -4,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                constraints: const BoxConstraints(
                  minWidth: 18,
                  minHeight: 18,
                ),
                decoration: BoxDecoration(
                  color: AppColors.error,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 1.5,
                  ),
                ),
                child: Text(
                  count > 99 ? '99+' : '$count',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Icono "Más" del bottom bar mobile.
///
/// Recibe los streams de badge de las secciones ocultas y muestra un
/// puntito rojo cuando alguno tiene docs pendientes — así el admin no
/// pierde la señal visual de "hay algo que atender allá adentro".
///
/// Sin StreamBuilder por sección sería costoso; combinamos múltiples
/// streams con un solo StreamGroup para hacer un único rebuild cuando
/// cambia cualquiera de los pendientes.
class _IconoMas extends StatelessWidget {
  final List<Stream<QuerySnapshot>> streams;
  const _IconoMas({required this.streams});

  /// Combina los streams en uno solo que emite `true` mientras alguno
  /// tenga docs > 0. Implementación simple: por cada stream, mantiene
  /// su último count en un mapa y emite el OR del conjunto.
  Stream<bool> _hayPendientes() async* {
    if (streams.isEmpty) {
      yield false;
      return;
    }
    final counts = List<int>.filled(streams.length, 0);
    final controller = StreamController<bool>();
    for (var i = 0; i < streams.length; i++) {
      streams[i].listen(
        (snap) {
          counts[i] = snap.docs.length;
          controller.add(counts.any((c) => c > 0));
        },
        onError: (_) {},
      );
    }
    yield* controller.stream;
  }

  @override
  Widget build(BuildContext context) {
    const icon = Icon(Icons.more_horiz_outlined);
    if (streams.isEmpty) return icon;
    return StreamBuilder<bool>(
      stream: _hayPendientes(),
      builder: (ctx, snap) {
        final mostrarPunto = snap.data == true;
        if (!mostrarPunto) return icon;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            icon,
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: AppColors.error,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Estructura interna que define cada sección del shell.
class _ShellSection {
  final String label;
  final IconData icon;
  final IconData iconActive;
  final Widget Function() build;
  final Stream<QuerySnapshot>? badgeStream;

  /// Capability requerida para que la seccion sea visible en el rail/
  /// bottombar. Si `null`, siempre se muestra (ej. 'Inicio').
  final Capability? requiredCapability;

  _ShellSection({
    required this.label,
    required this.icon,
    required this.iconActive,
    required this.build,
    this.badgeStream,
    this.requiredCapability,
  });
}

