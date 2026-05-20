import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/capabilities.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../vista_ejecutiva/services/vista_ejecutiva_service.dart';
import '../../vista_ejecutiva/widgets/kpi_grande_card.dart';
import '../../vista_ejecutiva/widgets/tendencia_icm_chart.dart';
import '../../vista_ejecutiva/widgets/top_choferes_lista.dart';
import '../../vista_ejecutiva/widgets/viajes_semanales_chart.dart';

/// Panel de administración — pantalla "Inicio" del shell admin.
///
/// REFACTOR 2026-05-18 (decisión Santiago): unificada con la antigua
/// "Vista Ejecutiva" que duplicaba choferes activos + alertas. Ahora
/// INICIO es UNA sola vista superadora con todo el dashboard:
///
///   - Saludo
///   - HOY (alarmas operativas urgentes — rojo si críticas)
///   - PANORAMA DEL MES (KPIs grandes con tendencia vs mes anterior)
///   - FLOTA (estado general de unidades y vencimientos no urgentes)
///   - TENDENCIAS (gráficos ICM 12 semanas + viajes 8 semanas)
///   - PERSONAS (top 5 mejores + top 5 a mejorar)
///   - ACCESOS RÁPIDOS (navegación a módulos)
///   - Footer versión
///
/// Pantalla `vista_ejecutiva_screen.dart` eliminada en el mismo
/// commit. Service + widgets reusados desde acá.
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _statsStream;
  late final Stream<QuerySnapshot<Map<String, dynamic>>>
      _revisionesPendientesStream;

  /// KPIs ricos del mes (viajes, ICM, eficiencia, tendencias, top choferes).
  /// Lazy: solo se carga si el rol tiene capability + 1 sola vez por entrada
  /// a la pantalla. Pull-to-refresh lo recarga.
  Future<KpisVistaEjecutiva>? _futureKpisRicos;
  bool get _verKpisRicos =>
      Capabilities.can(PrefsService.rol, Capability.verVistaEjecutiva);

  @override
  void initState() {
    super.initState();
    // STATS/dashboard lo mantiene la Cloud Function `recomputeDashboardStats`
    // (cada 5 min). Antes traíamos las 3 colecciones enteras (EMPLEADOS,
    // VEHICULOS, REVISIONES) y calculábamos KPIs O(N×M) client-side. Ahora
    // leemos UN solo doc — escala constante con el tamaño de la flota.
    _statsStream = FirebaseFirestore.instance
        .collection('STATS')
        .doc('dashboard')
        .snapshots();
    // EXCEPCIÓN: "Trámites pendientes" se lee EN VIVO (no del stats
    // stale). Cuando un chofer envía una revisión nueva, el admin
    // necesita verlo al toque, no esperar hasta 5 min al próximo
    // ciclo del cron. Bug reportado por Santiago 2026-05-12.
    _revisionesPendientesStream = FirebaseFirestore.instance
        .collection('REVISIONES')
        .where('estado', isEqualTo: 'PENDIENTE')
        .snapshots();

    if (_verKpisRicos) {
      _cargarKpisRicos();
    }
  }

  void _cargarKpisRicos() {
    setState(() {
      _futureKpisRicos = VistaEjecutivaService.cargar(
        db: FirebaseFirestore.instance,
      );
    });
  }

  Future<void> _refrescar() async {
    if (_verKpisRicos) {
      _cargarKpisRicos();
      // Esperamos a que termine la carga para que el RefreshIndicator se
      // mantenga visible mientras dura el fetch.
      await _futureKpisRicos;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: AppTexts.appName,
      body: RefreshIndicator(
        onRefresh: _refrescar,
        color: AppColors.accentGreen,
        backgroundColor: AppColors.surface,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            const _Saludo(),
            const SizedBox(height: 16),
            // ------- SECCIÓN 1: HOY (operativo urgente) -------
            // Stats genérico desde STATS/dashboard (cron 5 min) +
            // override en vivo de "trámites pendientes" desde
            // REVISIONES directo.
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _statsStream,
              builder: (ctx, statsSnap) {
                final stats = _Stats.fromDoc(statsSnap.data?.data());
                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _revisionesPendientesStream,
                  builder: (ctx2, revSnap) {
                    final statsFinal = revSnap.hasData
                        ? stats.conRevisionesPendientes(revSnap.data!.docs.length)
                        : stats;
                    return _SeccionHoyFlota(stats: statsFinal);
                  },
                );
              },
            ),
            // ------- SECCIONES 2-5: KPIs ricos (mes, tendencias, personas) -------
            if (_verKpisRicos) ...[
              const SizedBox(height: 24),
              _SeccionesEjecutivas(
                future: _futureKpisRicos!,
                onReintentar: _cargarKpisRicos,
              ),
            ],
            const SizedBox(height: 24),
            // ------- SECCIÓN 6: ACCESOS RÁPIDOS -------
            const _SeccionLabel('Accesos rápidos'),
            const SizedBox(height: 8),
            // Cada tile aparece solo si el rol logueado tiene la
            // capability correspondiente. Orden alineado con el sidebar
            // del shell (decisión Vecchi 2026-05-07).
            //
            // Tile "VISTA EJECUTIVA" ELIMINADO 2026-05-18 — sus secciones
            // están integradas en este mismo INICIO arriba.
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
                subtitulo: 'Calendario, personal, flota y empresas',
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
            if (Capabilities.can(PrefsService.rol, Capability.verCachatore))
              const _AdminTile(
                titulo: 'CACHATORE',
                subtitulo: '',
                icono: Icons.schedule,
                color: AppColors.accentCyan,
                ruta: AppRoutes.adminCachatoreHub,
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
                color: AppColors.accentDeepOrange,
                ruta: AppRoutes.adminMantenimiento,
              ),
            if (Capabilities.can(PrefsService.rol, Capability.verIcm))
              const _AdminTile(
                titulo: 'ICM',
                subtitulo: 'Conducta de Manejo: ranking, mapa de calor, drill-down',
                icono: Icons.leaderboard_outlined,
                color: AppColors.accentRed,
                ruta: AppRoutes.adminIcmHub,
              ),
            if (Capabilities.can(PrefsService.rol, Capability.verAlertasVolvo))
              const _AdminTile(
                titulo: 'DESCARGAS',
                subtitulo: 'Eventos PTO de la flota Volvo',
                icono: Icons.local_shipping_outlined,
                color: AppColors.accentDeepOrange,
                ruta: AppRoutes.adminDescargasPto,
              ),
            if (Capabilities.can(PrefsService.rol, Capability.verAlertasVolvo))
              const _AdminTile(
                titulo: 'MAPA',
                subtitulo: 'Posición actual de la flota en tiempo real',
                icono: Icons.map_outlined,
                color: AppColors.accentLightBlue,
                ruta: AppRoutes.adminMapaFlota,
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
                color: AppColors.accentLightGreen,
                ruta: AppRoutes.adminEstadoBot,
              ),
            const SizedBox(height: 28),
            // Footer con versión.
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
      ),
    );
  }
}

// =============================================================================
// SECCIONES EJECUTIVAS (KPIs ricos del mes — antigua Vista Ejecutiva)
// =============================================================================

/// Envoltorio del FutureBuilder de los KPIs ricos. Si el future falla,
/// muestra error con botón reintentar. Si está cargando, placeholder
/// compacto (no bloquea las secciones de arriba que ya cargaron).
class _SeccionesEjecutivas extends StatelessWidget {
  final Future<KpisVistaEjecutiva> future;
  final VoidCallback onReintentar;

  const _SeccionesEjecutivas({
    required this.future,
    required this.onReintentar,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<KpisVistaEjecutiva>(
      future: future,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: CircularProgressIndicator(
                color: AppColors.accentGreen,
              ),
            ),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              children: [
                const Icon(Icons.error_outline,
                    color: AppColors.accentRed, size: 36),
                const SizedBox(height: 8),
                const Text(
                  'No se pudieron cargar los KPIs del mes',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    snap.error.toString(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: onReintentar,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                ),
              ],
            ),
          );
        }
        final kpis = snap.data!;
        return _SeccionesPanorama(kpis: kpis);
      },
    );
  }
}

/// Renderiza las 4 secciones ricas:
///   1. PANORAMA DEL MES (4 KPIs grandes + eficiencia)
///   2. TENDENCIAS (2 gráficos)
///   3. PERSONAS (top 5 mejores + top 5 a mejorar)
class _SeccionesPanorama extends StatelessWidget {
  final KpisVistaEjecutiva kpis;
  const _SeccionesPanorama({required this.kpis});

  @override
  Widget build(BuildContext context) {
    final esDesktop = MediaQuery.of(context).size.width >= 800;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SeccionLabel('Panorama del mes'),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: esDesktop ? 4 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: esDesktop ? 1.0 : 0.85,
          children: [
            KpiGrandeCard.mes(
              label: 'Viajes del mes',
              kpi: kpis.viajesDelMes,
              icono: Icons.local_shipping,
              color: AppColors.accentPurple,
              mejorEsSubir: true,
              onTap: () => Navigator.pushNamed(
                  context, AppRoutes.adminLogisticaViajes),
            ),
            KpiGrandeCard.icm(
              label: 'ICM flota',
              kpi: kpis.icmFlota,
              icono: Icons.leaderboard,
              onTap: () => Navigator.pushNamed(
                  context, AppRoutes.adminIcmReporteSemanal),
            ),
            KpiGrandeCard.simple(
              label: 'Alertas críticas',
              kpi: kpis.alertasCriticas,
              icono: Icons.warning_amber_rounded,
              color: kpis.alertasCriticas.valor > 0
                  ? AppColors.accentRed
                  : AppColors.accentGreen,
              onTap: () => Navigator.pushNamed(
                  context, AppRoutes.vencimientosCalendario),
            ),
            KpiGrandeCard.eficiencia(
              label: 'Eficiencia 30d',
              kpi: kpis.eficienciaCombustible,
              icono: Icons.local_gas_station,
              onTap: () => Navigator.pushNamed(
                  context, AppRoutes.adminEcoDriving),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const _SeccionLabel('Tendencias'),
        const SizedBox(height: 10),
        if (esDesktop)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TendenciaIcmChart(
                  puntos: kpis.tendenciaIcm,
                  titulo: 'ICM promedio · últimas 12 semanas',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ViajesSemanalesChart(
                  puntos: kpis.viajesPorSemana,
                  titulo: 'Viajes por semana · últimas 8',
                ),
              ),
            ],
          )
        else ...[
          TendenciaIcmChart(
            puntos: kpis.tendenciaIcm,
            titulo: 'ICM promedio · últimas 12 semanas',
          ),
          const SizedBox(height: 10),
          ViajesSemanalesChart(
            puntos: kpis.viajesPorSemana,
            titulo: 'Viajes por semana · últimas 8',
          ),
        ],
        const SizedBox(height: 24),
        const _SeccionLabel('Personas'),
        const SizedBox(height: 10),
        if (esDesktop)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TopChoferesLista(
                  titulo: 'TOP 5 — MEJORES CHOFERES',
                  icono: Icons.emoji_events,
                  colorTitulo: AppColors.accentGreen,
                  items: kpis.top5Mejores,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TopChoferesLista(
                  titulo: 'TOP 5 — A MEJORAR',
                  icono: Icons.priority_high,
                  colorTitulo: AppColors.accentRed,
                  items: kpis.top5Peores,
                ),
              ),
            ],
          )
        else ...[
          TopChoferesLista(
            titulo: 'TOP 5 — MEJORES CHOFERES',
            icono: Icons.emoji_events,
            colorTitulo: AppColors.accentGreen,
            items: kpis.top5Mejores,
          ),
          const SizedBox(height: 10),
          TopChoferesLista(
            titulo: 'TOP 5 — A MEJORAR',
            icono: Icons.priority_high,
            colorTitulo: AppColors.accentRed,
            items: kpis.top5Peores,
          ),
        ],
      ],
    );
  }
}

// =============================================================================
// SECCIÓN HOY + FLOTA (KPIs operativos rápidos)
// =============================================================================

/// 2 sub-secciones combinadas:
///   - HOY: 3 KPIs urgentes (pendientes, vencidos, vencen ≤ 7d).
///     Bordes rojos si críticos.
///   - FLOTA: 3 KPIs estado general (choferes, unidades, vencen ≤ 30d).
class _SeccionHoyFlota extends StatelessWidget {
  final _Stats stats;
  const _SeccionHoyFlota({required this.stats});

  @override
  Widget build(BuildContext context) {
    final esDesktop = MediaQuery.of(context).size.width >= 600;
    final cols = esDesktop ? 3 : 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SeccionLabel('Hoy'),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: esDesktop ? 1.6 : 1.1,
          children: [
            _KpiCard(
              label: 'Trámites pendientes',
              valor:
                  stats.cargando ? '…' : '${stats.revisionesPendientes}',
              icon: Icons.fact_check_outlined,
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
              color: stats.vencidos > 0
                  ? AppColors.accentRed
                  : AppColors.accentGreen,
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
          ],
        ),
        const SizedBox(height: 24),
        const _SeccionLabel('Flota'),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: esDesktop ? 1.6 : 1.1,
          children: [
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
              label: 'Vencen ≤ 30 días',
              valor: stats.cargando ? '…' : '${stats.proximos30}',
              icon: Icons.event_note,
              color: AppColors.accentTeal,
              ruta: '/vencimientos_calendario',
            ),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// SALUDO
// =============================================================================

/// Encabezado con saludo según hora del día + apodo o primer nombre del admin.
class _Saludo extends StatefulWidget {
  const _Saludo();

  @override
  State<_Saludo> createState() => _SaludoState();
}

class _SaludoState extends State<_Saludo> {
  /// Inicializado SÍNCRONO desde `PrefsService.apodo` (cacheado al login)
  /// para evitar el flicker "Buen día, Santiago" → "Buen día, Santi".
  late String _apodoResuelto = PrefsService.apodo.trim();

  @override
  void initState() {
    super.initState();
    if (_apodoResuelto.isEmpty) {
      _resolverApodoLegacy();
    }
  }

  /// Solo se invoca para admins que iniciaron sesión antes de que
  /// PrefsService cacheara el APODO.
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
      if (apodo.isEmpty) return;
      setState(() => _apodoResuelto = apodo);
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
    final nombre = _apodoResuelto.isNotEmpty
        ? _apodoResuelto
        : _primerNombre(nombreFull);
    final saludo =
        nombre != null ? '${_saludoHora()}, $nombre' : _saludoHora();
    final fechaHoy = AppFormatters.formatearFecha(DateTime.now());

    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            saludo,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
// CÁLCULO DE MÉTRICAS (KPIs operativos rápidos desde STATS/dashboard)
// =============================================================================

/// Estadísticas agregadas que pinta la sección "Hoy" + "Flota". Inmutable;
/// se hidrata desde el doc `STATS/dashboard` que mantiene la Cloud Function
/// `recomputeDashboardStats` (cada 5 min).
class _Stats {
  final int choferesActivos;
  final int unidadesTotal;
  final int unidadesAsignadas;
  final int revisionesPendientes;
  final int vencidos;
  final int proximos7;
  final int proximos30;

  /// `true` mientras el snapshot de `STATS/dashboard` no llegó todavía.
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

  factory _Stats.fromDoc(Map<String, dynamic>? data) {
    if (data == null) {
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
    int asInt(dynamic v) =>
        v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);
    return _Stats(
      choferesActivos: asInt(data['choferes_activos']),
      unidadesTotal: asInt(data['unidades_total']),
      unidadesAsignadas: asInt(data['unidades_asignadas']),
      revisionesPendientes: asInt(data['revisiones_pendientes']),
      vencidos: asInt(data['vencidos']),
      proximos7: asInt(data['proximos_7']),
      proximos30: asInt(data['proximos_30']),
      cargando: false,
    );
  }

  /// Override `revisionesPendientes` con el count en vivo del stream
  /// de REVISIONES.
  _Stats conRevisionesPendientes(int cantidad) {
    return _Stats(
      choferesActivos: choferesActivos,
      unidadesTotal: unidadesTotal,
      unidadesAsignadas: unidadesAsignadas,
      revisionesPendientes: cantidad,
      vencidos: vencidos,
      proximos7: proximos7,
      proximos30: proximos30,
      cargando: cargando,
    );
  }
}

// =============================================================================
// KPI CARD (sección Hoy / Flota)
// =============================================================================

class _KpiCard extends StatelessWidget {
  final String label;
  final String valor;
  final String? sublabel;
  final IconData icon;
  final Color color;
  final String? ruta;

  /// Si es `true`, agrega un borde visible del color para destacar.
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
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
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
              ),
            ),
          ),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// TILE DE ACCESO DIRECTO (sección Accesos rápidos)
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
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
