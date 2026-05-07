import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../core/services/capabilities.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';

/// Panel de administración — pantalla "Inicio" del shell admin.
///
/// Muestra un **dashboard de operación** con métricas en tiempo real:
/// choferes activos, unidades en flota, revisiones pendientes y
/// vencimientos por urgencia (vencidos / próximos 7d / próximos 30d).
/// Cada KPI es tappable y lleva a la sección correspondiente.
///
/// Debajo del dashboard, accesos directos compactos a las secciones
/// principales (legacy del menú anterior — siguen siendo útiles para
/// usuarios que ya tienen el flujo memorizado).
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  late final Stream<QuerySnapshot> _empleadosStream;
  late final Stream<QuerySnapshot> _vehiculosStream;
  late final Stream<QuerySnapshot> _revisionesStream;

  @override
  void initState() {
    super.initState();
    final db = FirebaseFirestore.instance;
    _empleadosStream = db.collection(AppCollections.empleados).snapshots();
    _vehiculosStream = db.collection(AppCollections.vehiculos).snapshots();
    // REVISIONES: las aprobadas/rechazadas se BORRAN del collection
    // (no soft-delete), asi que en condiciones normales solo hay
    // pendientes. Igual sumamos limit(50) como defensa: si en el
    // futuro se decide guardar historico, el contador no se infla
    // ni el snapshot push baja miles de docs en cada cambio.
    //
    // DEUDA TECNICA (escalabilidad a 1000+ empleados/vehiculos):
    // _empleadosStream y _vehiculosStream traen la coleccion entera.
    // Los KPIs recalculan O(N x M) en cada snapshot push. Hasta ~500
    // docs es aceptable; arriba conviene migrar a aggregate stats
    // server-side: una collection STATS/dashboard con contadores
    // mantenidos por trigger Cloud Function en cambios de
    // EMPLEADOS/VEHICULOS/REVISIONES. La app lee 1 doc en lugar
    // de N+M+R. Postergado hasta que el dimensionamiento lo amerite.
    _revisionesStream = db.collection(AppCollections.revisiones).limit(50).snapshots();
    // El listener de notificaciones push para revisiones nuevas vive
    // en AdminShell (durante toda la sesion admin), no aca. Si lo
    // duplicaramos en este State, el admin recibiria 2 push identicas
    // por cada revision mientras este en "Inicio".
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: AppTexts.appName,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          const _Saludo(),
          const SizedBox(height: 16),
          // ------- KPIs en vivo -------
          StreamBuilder<QuerySnapshot>(
            stream: _empleadosStream,
            builder: (ctx, snapEmp) => StreamBuilder<QuerySnapshot>(
              stream: _vehiculosStream,
              builder: (ctx, snapVeh) => StreamBuilder<QuerySnapshot>(
                stream: _revisionesStream,
                builder: (ctx, snapRev) {
                  final stats = _Stats.from(
                    empleados: snapEmp.data,
                    vehiculos: snapVeh.data,
                    revisiones: snapRev.data,
                    docsEmpleado: AppDocsEmpleado.etiquetas,
                  );
                  return _GridKPIs(stats: stats);
                },
              ),
            ),
          ),
          const SizedBox(height: 24),
          // ------- Accesos directos (legacy) -------
          const _SeccionLabel('Accesos rápidos'),
          const SizedBox(height: 8),
          // Cada tile aparece solo si el rol logueado tiene la
          // capability correspondiente. SUPERVISOR ve la mayoría.
          // SYNC OBSERVABILITY queda solo para ADMIN.
          // Los tiles de Accesos rapidos replican el ORDEN y los NOMBRES
          // del sidebar (NavigationRail / BottomBar) para mantener
          // coherencia visual: el admin reconoce cada item por el mismo
          // label en cualquier parte de la app.
          // Orden alineado con el sidebar del shell (decisión Vecchi
          // 2026-05-07): Personal → Flota → Revisiones → Vencimientos →
          // Logística → Gomería → Service → Alertas → Reportes → Sync →
          // Estado Bot. El mismo orden tiene que verse en cualquier
          // entrada del admin (rail/bottombar y panel central).
          if (Capabilities.can(PrefsService.rol, Capability.verListaPersonal))
            const _AdminTile(
              titulo: 'PERSONAL',
              subtitulo: 'Lista de legajos y choferes',
              icono: Icons.badge_outlined,
              color: AppColors.accentBlue,
              ruta: '/admin_personal_lista',
            ),
          if (Capabilities.can(PrefsService.rol, Capability.verListaFlota))
            const _AdminTile(
              titulo: 'FLOTA',
              subtitulo: 'Control de camiones y acoplados',
              icono: Icons.local_shipping_outlined,
              color: AppColors.accentPurple,
              ruta: '/admin_vehiculos_lista',
            ),
          if (Capabilities.can(PrefsService.rol, Capability.verRevisiones))
            const _AdminTile(
              titulo: 'REVISIONES',
              subtitulo: 'Aprobar/rechazar trámites cargados por choferes',
              icono: Icons.fact_check_outlined,
              color: AppColors.accentTeal,
              ruta: '/admin_revisiones',
            ),
          if (Capabilities.can(PrefsService.rol, Capability.verVencimientos))
            const _AdminTile(
              titulo: 'VENCIMIENTOS',
              subtitulo: 'Calendario y listas por categoría',
              icono: Icons.event_note,
              color: AppColors.accentGreen,
              ruta: '/admin_vencimientos_menu',
            ),
          if (Capabilities.can(PrefsService.rol, Capability.verLogistica))
            const _AdminTile(
              titulo: 'LOGÍSTICA',
              subtitulo: 'Empresas, ubicaciones y tarifas',
              icono: Icons.route_outlined,
              color: AppColors.accentGreen,
              ruta: AppRoutes.adminLogisticaHub,
            ),
          if (Capabilities.can(PrefsService.rol, Capability.verGomeria))
            const _AdminTile(
              titulo: 'GOMERÍA',
              subtitulo: 'Stock, instalación y recapados de cubiertas',
              icono: Icons.tire_repair,
              color: AppColors.accentOrange,
              ruta: AppRoutes.adminGomeriaHub,
            ),
          if (Capabilities.can(PrefsService.rol, Capability.verMantenimiento))
            const _AdminTile(
              titulo: 'SERVICE',
              subtitulo: 'Próximos services de la flota Volvo',
              icono: Icons.build_circle_outlined,
              color: Colors.deepOrangeAccent,
              ruta: AppRoutes.adminMantenimiento,
            ),
          if (Capabilities.can(PrefsService.rol, Capability.verAlertasVolvo))
            const _AdminTile(
              titulo: 'ALERTAS',
              subtitulo: 'Eventos en vivo de la flota Volvo (IDLING, OVERSPEED, ...)',
              icono: Icons.notifications_active_outlined,
              color: AppColors.accentRed,
              ruta: AppRoutes.adminVolvoAlertas,
            ),
          if (Capabilities.can(PrefsService.rol, Capability.verReportes))
            const _AdminTile(
              titulo: 'REPORTES',
              subtitulo: 'Exportar Excel y analítica de flota',
              icono: Icons.analytics_outlined,
              color: AppColors.accentAmber,
              ruta: '/admin_reportes',
            ),
          if (Capabilities.can(PrefsService.rol, Capability.verSyncDashboard))
            const _AdminTile(
              titulo: 'SYNC',
              subtitulo: 'Monitoreo en tiempo real de sincronización',
              icono: Icons.monitor_heart_outlined,
              color: AppColors.accentCyan,
              ruta: AppRoutes.syncDashboard,
            ),
          if (Capabilities.can(PrefsService.rol, Capability.verEstadoBot))
            const _AdminTile(
              titulo: 'ESTADO BOT',
              subtitulo: 'Bot WhatsApp: cola, cron, errores y heartbeat',
              icono: Icons.smart_toy_outlined,
              color: Colors.lightGreenAccent,
              ruta: AppRoutes.adminEstadoBot,
            ),
          const SizedBox(height: 28),
          // Lee del único string fuente de versión (AppTexts.appVersion).
          // Antes estaba hardcodeada como "v 1.0.7" y nunca se
          // actualizaba con los bumps de pubspec — confundía al admin
          // que no podía saber qué binario estaba corriendo.
          // Como `appVersion` es const, la interpolación califica como
          // const expression — el widget queda const también.
          const Center(
            child: Text(
              '${AppTexts.appVersion} — Base Operativa',
              style: TextStyle(
                color: Colors.white24,
                fontSize: 11,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// =============================================================================
// SALUDO
// =============================================================================

/// Encabezado con saludo según hora del día + apodo o primer nombre del admin.
///
/// Resolución del nombre a saludar:
///   1. Lee `EMPLEADOS/{dni}.APODO` (lectura única, cacheada en memoria
///      para que no parpadee al volver al panel).
///   2. Si no hay apodo cargado, fallback al algoritmo "segundo token"
///      del `NOMBRE` (ej. "PEREZ JUAN" → "Juan"). Limitación conocida:
///      con dos apellidos elige el segundo apellido en lugar del primer
///      nombre — para esos casos hay que cargar el APODO desde el form.
class _Saludo extends StatefulWidget {
  const _Saludo();

  @override
  State<_Saludo> createState() => _SaludoState();
}

class _SaludoState extends State<_Saludo> {
  /// Inicializado SÍNCRONO desde `PrefsService.apodo` (cacheado al login)
  /// para evitar el flicker "Buen día, Santiago" → "Buen día, Santi"
  /// que pasaba cuando esto era un Future a Firestore. Si la cache está
  /// vacía (admins legacy logueados pre-fix 2026-05-07), el lookup
  /// async corre una vez y cachea el resultado para próximas sesiones.
  late String _apodoResuelto = PrefsService.apodo.trim();

  @override
  void initState() {
    super.initState();
    if (_apodoResuelto.isEmpty) {
      _resolverApodoLegacy();
    }
  }

  /// Solo se invoca para admins que iniciaron sesión antes de que
  /// PrefsService cacheara el APODO. Una vez resuelto, queda guardado
  /// y la próxima sesión arranca síncrona.
  Future<void> _resolverApodoLegacy() async {
    final dni = PrefsService.dni;
    if (dni.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(dni)
          .get();
      if (!mounted) return;
      final apodo = (snap.data()?['APODO'] ?? '').toString().trim();
      if (apodo.isEmpty) return; // sin apodo cargado, mantenemos fallback
      setState(() => _apodoResuelto = apodo);
      // Cacheamos para próximas sesiones (fire-and-forget, no bloquea UI).
      unawaited(PrefsService.setApodo(apodo));
    } catch (_) {
      // Si Firestore falla o el doc no existe, dejamos el fallback.
    }
  }

  String _saludoHora() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Buen día';
    if (h < 19) return 'Buenas tardes';
    return 'Buenas noches';
  }

  /// Para nombres "APELLIDO NOMBRE …", devuelve "Nombre" capitalizado.
  /// Solo se usa como fallback cuando el APODO no está cargado.
  String? _primerNombre(String full) {
    final partes = full.trim().split(RegExp(r'\s+'));
    if (partes.length < 2) return null;
    final n = partes[1];
    if (n.isEmpty) return null;
    return '${n[0].toUpperCase()}${n.substring(1).toLowerCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final nombreFull = PrefsService.nombre;
    // Prioridad: APODO si está cargado → fallback al segundo token.
    final nombre = _apodoResuelto.isNotEmpty
        ? _apodoResuelto
        : _primerNombre(nombreFull);
    final saludo =
        nombre != null ? '${_saludoHora()}, $nombre' : _saludoHora();
    // Pasamos DateTime directo (no toIso8601String que es UTC y rompe
    // entre 21:00 y 23:59 ART). formatearFecha ya acepta DateTime.
    final fechaHoy = AppFormatters.formatearFecha(DateTime.now());

    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            saludo,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            fechaHoy,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _SeccionLabel extends StatelessWidget {
  final String texto;
  const _SeccionLabel(this.texto);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6, top: 4),
      child: Text(
        texto.toUpperCase(),
        style: const TextStyle(
          color: AppColors.accentGreen,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

// =============================================================================
// CÁLCULO DE MÉTRICAS
// =============================================================================

/// Estadísticas agregadas que pinta el dashboard. Inmutable; se calcula
/// una vez por frame combinando los 3 snapshots.
class _Stats {
  final int choferesActivos;
  final int unidadesTotal;
  final int unidadesAsignadas;
  final int revisionesPendientes;
  final int vencidos;
  final int proximos7;
  final int proximos30;

  /// `true` mientras alguno de los streams todavía no tiene su primer
  /// snapshot — sirve para mostrar placeholders en lugar de "0" mentiroso.
  final bool cargando;

  const _Stats({
    required this.choferesActivos,
    required this.unidadesTotal,
    required this.unidadesAsignadas,
    required this.revisionesPendientes,
    required this.vencidos,
    required this.proximos7,
    required this.proximos30,
    required this.cargando,
  });

  factory _Stats.from({
    required QuerySnapshot? empleados,
    required QuerySnapshot? vehiculos,
    required QuerySnapshot? revisiones,
    required Map<String, String> docsEmpleado,
  }) {
    final cargando =
        empleados == null || vehiculos == null || revisiones == null;
    if (cargando) {
      return const _Stats(
        choferesActivos: 0,
        unidadesTotal: 0,
        unidadesAsignadas: 0,
        revisionesPendientes: 0,
        vencidos: 0,
        proximos7: 0,
        proximos30: 0,
        cargando: true,
      );
    }

    int activos = 0;
    int vencidos = 0;
    int prox7 = 0;
    int prox30 = 0;

    void contarFecha(String? fechaStr) {
      if (fechaStr == null || fechaStr.isEmpty) return;
      final dias = AppFormatters.calcularDiasRestantes(fechaStr);
      // Fecha cargada pero no parseable -> contamos como vencido (peor
      // caso). Hasta hace poco devolvia sentinel 999 y se silenciaba
      // en el dashboard; ahora se ve y el admin la encuentra abriendo
      // la pantalla de auditoria correspondiente.
      if (dias == null || dias < 0) {
        vencidos++;
      } else if (dias <= 7) {
        prox7++;
      } else if (dias <= 30) {
        prox30++;
      }
    }

    // Empleados — KPI "choferes activos" y vencimientos personales son
    // ambas métricas DE MANEJO. Admins/supervisores/planta no manejan
    // ni tienen vencimientos profesionales (licencia, ART, psicofísico),
    // así que los filtramos para no contaminar el dashboard.
    for (final doc in empleados.docs) {
      final data = doc.data() as Map<String, dynamic>;
      // Soft-delete: empleados dados de baja no cuentan en KPIs.
      if (!AppActivo.esActivo(data)) continue;
      final rol = AppRoles.normalizar(data['ROL']?.toString());
      if (!AppRoles.tieneVehiculo(rol)) continue;
      final estado = (data['estado_cuenta'] ?? 'ACTIVO').toString();
      if (estado.toUpperCase() == 'ACTIVO') activos++;
      for (final campoBase in docsEmpleado.values) {
        contarFecha(data['VENCIMIENTO_$campoBase']?.toString());
      }
    }

    // Vehículos
    int unidadesAsignadas = 0;
    for (final doc in vehiculos.docs) {
      final data = doc.data() as Map<String, dynamic>;
      // Soft-delete: vehiculos dados de baja no cuentan en KPIs.
      if (!AppActivo.esActivo(data)) continue;
      final estado = (data['ESTADO'] ?? '').toString().toUpperCase();
      if (estado == 'OCUPADO' || estado == 'ASIGNADO') {
        unidadesAsignadas++;
      }
      final tipo = (data['TIPO'] ?? '').toString();
      for (final spec in AppVencimientos.forTipo(tipo)) {
        contarFecha(data[spec.campoFecha]?.toString());
      }
    }

    return _Stats(
      choferesActivos: activos,
      unidadesTotal: vehiculos.docs.length,
      unidadesAsignadas: unidadesAsignadas,
      revisionesPendientes: revisiones.docs.length,
      vencidos: vencidos,
      proximos7: prox7,
      proximos30: prox30,
      cargando: false,
    );
  }
}

// =============================================================================
// GRID DE KPIs
// =============================================================================

class _GridKPIs extends StatelessWidget {
  final _Stats stats;
  const _GridKPIs({required this.stats});

  @override
  Widget build(BuildContext context) {
    final esDesktop = MediaQuery.of(context).size.width >= 600;
    final cols = esDesktop ? 3 : 2;

    final tarjetas = <Widget>[
      _KpiCard(
        label: 'Choferes activos',
        valor: stats.cargando ? '…' : '${stats.choferesActivos}',
        icon: Icons.badge,
        color: AppColors.accentBlue,
        ruta: '/admin_personal_lista',
      ),
      _KpiCard(
        label: 'Unidades en flota',
        valor: stats.cargando ? '…' : '${stats.unidadesTotal}',
        sublabel: stats.cargando
            ? null
            : '${stats.unidadesAsignadas} asignadas',
        icon: Icons.local_shipping,
        color: AppColors.accentPurple,
        ruta: '/admin_vehiculos_lista',
      ),
      _KpiCard(
        label: 'Trámites pendientes',
        valor:
            stats.cargando ? '…' : '${stats.revisionesPendientes}',
        icon: Icons.fact_check_outlined,
        // Naranja si hay pendientes — no es error, pero requiere atención.
        color: stats.revisionesPendientes > 0
            ? AppColors.accentOrange
            : AppColors.accentGreen,
        urgente: stats.revisionesPendientes > 0,
        ruta: '/admin_revisiones',
      ),
      _KpiCard(
        label: 'Vencidos',
        valor: stats.cargando ? '…' : '${stats.vencidos}',
        sublabel: 'sin renovar',
        icon: Icons.error_outline,
        // Rojo si hay vencidos — esto sí es crítico.
        color:
            stats.vencidos > 0 ? AppColors.accentRed : AppColors.accentGreen,
        urgente: stats.vencidos > 0,
        ruta: '/vencimientos_calendario',
      ),
      _KpiCard(
        label: 'Vencen ≤ 7 días',
        valor: stats.cargando ? '…' : '${stats.proximos7}',
        icon: Icons.warning_amber_rounded,
        color: stats.proximos7 > 0
            ? AppColors.accentOrange
            : AppColors.accentGreen,
        urgente: stats.proximos7 > 0,
        ruta: '/vencimientos_calendario',
      ),
      _KpiCard(
        label: 'Vencen ≤ 30 días',
        valor: stats.cargando ? '…' : '${stats.proximos30}',
        icon: Icons.event_note,
        color: AppColors.accentTeal,
        ruta: '/vencimientos_calendario',
      ),
    ];

    return GridView.count(
      crossAxisCount: cols,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      // Cards más anchas que altas; ratio ajustado para que el número
      // grande tenga aire sin que la card crezca demasiado en alto.
      childAspectRatio: esDesktop ? 1.6 : 1.4,
      children: tarjetas,
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String label;
  final String valor;
  final String? sublabel;
  final IconData icon;
  final Color color;
  final String? ruta;

  /// Si es `true`, agrega un borde visible del color para que la card
  /// destaque entre las que están en estado normal.
  final bool urgente;

  const _KpiCard({
    required this.label,
    required this.valor,
    required this.icon,
    required this.color,
    this.sublabel,
    this.ruta,
    this.urgente = false,
  });

  @override
  Widget build(BuildContext context) {
    final tap = ruta != null
        ? () => Navigator.pushNamed(context, ruta!)
        : null;

    return AppCard(
      onTap: tap,
      padding: const EdgeInsets.all(14),
      highlighted: urgente,
      borderColor: urgente ? color.withAlpha(160) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              if (urgente)
                const Icon(Icons.priority_high,
                    color: Colors.white54, size: 14),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                valor,
                style: TextStyle(
                  color: color,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  height: 1,
                ),
              ),
              if (sublabel != null) ...[
                const SizedBox(height: 2),
                Text(
                  sublabel!,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                  ),
                ),
              ],
            ],
          ),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// TILE DE ACCESO DIRECTO (legacy — secciones grandes del menú)
// =============================================================================

class _AdminTile extends StatelessWidget {
  final String titulo;
  final String subtitulo;
  final IconData icono;
  final Color color;
  final String ruta;

  const _AdminTile({
    required this.titulo,
    required this.subtitulo,
    required this.icono,
    required this.color,
    required this.ruta,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () => Navigator.pushNamed(context, ruta),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withAlpha(25),
              shape: BoxShape.circle,
            ),
            child: Icon(icono, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitulo,
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward_ios,
              color: Colors.white24, size: 14),
        ],
      ),
    );
  }
}
