import 'package:flutter/material.dart';

import '../features/sync_dashboard/screens/sync_dashboard_screen.dart'; // ✅ OK (ahora se usa)

import '../core/services/prefs_service.dart';
import '../core/services/capabilities.dart';
import '../core/constants/app_constants.dart';

import '../shared/widgets/guards/auth_guard.dart';
import '../shared/widgets/guards/role_guard.dart';

import '../features/home/screens/main_panel.dart';

import '../features/vehicles/screens/user_mi_equipo_screen.dart';
import '../features/employees/screens/user_mi_perfil_screen.dart';
import '../features/expirations/screens/user_mis_vencimientos_screen.dart';

import '../features/admin_dashboard/screens/admin_shell.dart';
import '../features/admin_dashboard/screens/admin_panel_screen.dart';
import '../features/admin_dashboard/screens/admin_estado_bot_screen.dart';
import '../features/admin_dashboard/screens/admin_volvo_alertas_screen.dart';
import '../features/gomeria/constants/posiciones.dart';
import '../features/gomeria/screens/admin_gomeria_marcas_modelos_screen.dart';
import '../features/gomeria/screens/gomeria_cubierta_detalle_screen.dart';
import '../features/gomeria/screens/gomeria_hub_screen.dart';
import '../features/gomeria/screens/gomeria_recapados_screen.dart';
import '../features/gomeria/screens/gomeria_stock_screen.dart';
import '../features/gomeria/screens/gomeria_unidad_detalle_screen.dart';
import '../features/gomeria/screens/gomeria_unidades_lista_screen.dart';
import '../features/logistica/screens/logistica_empresas_screen.dart';
import '../features/logistica/screens/logistica_hub_screen.dart';
import '../features/logistica/screens/logistica_adelantos_screen.dart';
import '../features/logistica/screens/logistica_liquidacion_screen.dart';
import '../features/logistica/screens/logistica_mapa_tarifas_screen.dart';
import '../features/logistica/screens/logistica_tarifa_form_screen.dart';
import '../features/logistica/screens/logistica_tarifas_screen.dart';
import '../features/logistica/screens/logistica_ubicaciones_screen.dart';
import '../features/logistica/screens/logistica_viaje_detalle_screen.dart';
import '../features/logistica/screens/logistica_viaje_form_screen.dart';
import '../features/logistica/screens/logistica_viajes_lista_screen.dart';
import '../features/eco_driving/screens/admin_descargas_pto_screen.dart';
import '../features/eco_driving/screens/admin_eco_driving_screen.dart';
import '../features/eco_driving/screens/admin_mapa_volvo_screen.dart';
import '../features/fleet_map/screens/admin_mapa_flota_screen.dart';
import '../features/employees/screens/admin_personal_lista_screen.dart';
import '../features/vehicles/screens/admin_vehiculos_lista_screen.dart';
import '../features/vehicles/screens/admin_mantenimiento_screen.dart';
import '../features/expirations/screens/admin_vencimientos_menu_screen.dart';
import '../features/revisions/screens/admin_revisiones_screen.dart';
import '../features/reports/screens/admin_reports_screen.dart';

import '../features/expirations/screens/admin_vencimientos_choferes_screen.dart';
import '../features/expirations/screens/admin_vencimientos_chasis_screen.dart';
import '../features/expirations/screens/admin_vencimientos_acoplados_screen.dart';
import '../features/expirations/screens/admin_vencimientos_calendario_screen.dart';

import '../features/empresas_empleadoras/screens/admin_empresas_empleadoras_screen.dart';

import '../features/icm/screens/icm_hub_screen.dart';
import '../features/icm/screens/icm_ranking_screen.dart';
import '../features/icm/screens/icm_reporte_semanal_screen.dart';
import '../features/icm/screens/icm_mapa_calor_screen.dart';
import '../features/icm/screens/icm_detalle_chofer_screen.dart';

import '../features/cachatore/screens/cachatore_hub_screen.dart';


class AppRouter {
  AppRouter._();

  static Widget _proteger(Widget child) {
    return AuthGuard(child: child);
  }

  static Widget _protegerAdmin(Widget child) {
    // Cambio: antes pedíamos rol literal ADMIN. Ahora pedimos la
    // capability `verPanelAdmin` — la tienen ADMIN y SUPERVISOR. Cada
    // pantalla del panel oculta los tiles que el rol no puede usar
    // (ver admin_panel_screen).
    return AuthGuard(
      child: RoleGuard(
        requiredCapability: Capability.verPanelAdmin,
        child: child,
      ),
    );
  }

  /// Para pantallas reservadas EXCLUSIVAMENTE a ADMIN (ej. Sync
  /// Dashboard, Gestión de roles). Usá esta en vez de `_protegerAdmin`
  /// cuando ni siquiera SUPERVISOR debe entrar.
  static Widget _protegerSoloAdmin(Widget child) {
    return AuthGuard(
      child: RoleGuard(
        requiredRole: AppRoles.admin,
        child: child,
      ),
    );
  }

  static MaterialPageRoute _buildRoute(
    Widget screen,
    RouteSettings settings,
  ) {
    return MaterialPageRoute(
      builder: (_) => screen,
      settings: settings,
    );
  }

  static Route<dynamic>? generateRoute(RouteSettings settings) {
    switch (settings.name) {

      // ================= HOME =================
      case AppRoutes.home:
        final args = settings.arguments as Map<String, dynamic>?;

        return _buildRoute(
          _proteger(
            MainPanel(
              dni: args?['dni'] ?? PrefsService.dni,
              nombre: args?['nombre'] ?? PrefsService.nombre,
              rol: args?['rol'] ?? PrefsService.rol,
            ),
          ),
          settings,
        );

      // ================= USER =================
      case AppRoutes.perfil:
        return _buildRoute(
          _proteger(
            UserMiPerfilScreen(
              dni: settings.arguments as String? ?? PrefsService.dni,
            ),
          ),
          settings,
        );

      case AppRoutes.equipo:
        return _buildRoute(
          _proteger(
            UserMiEquipoScreen(
              dniUser: settings.arguments as String? ?? PrefsService.dni,
            ),
          ),
          settings,
        );

      case AppRoutes.misVencimientos:
        return _buildRoute(
          _proteger(
            UserMisVencimientosScreen(
              dniUser: settings.arguments as String? ?? PrefsService.dni,
            ),
          ),
          settings,
        );

      // ================= ADMIN =================
      // Shell con NavigationRail/BottomNav que contiene todas las secciones admin.
      // La AdminPanelScreen original se renderiza como sección "Inicio" del shell.
      case AppRoutes.adminPanel:
        return _buildRoute(
          _protegerAdmin(const AdminShell()),
          settings,
        );

      case AppRoutes.adminPersonalLista:
        return _buildRoute(
          _protegerAdmin(const AdminPersonalListaScreen()),
          settings,
        );

      case AppRoutes.adminVehiculosLista:
        return _buildRoute(
          _protegerAdmin(const AdminVehiculosListaScreen()),
          settings,
        );

      case AppRoutes.adminVencimientosMenu:
        return _buildRoute(
          _protegerAdmin(const AdminVencimientosMenuScreen()),
          settings,
        );

      case AppRoutes.adminEmpresasEmpleadoras:
        return _buildRoute(
          _protegerAdmin(const AdminEmpresasEmpleadorasScreen()),
          settings,
        );

      case AppRoutes.adminRevisiones:
        return _buildRoute(
          _protegerAdmin(const AdminRevisionesScreen()),
          settings,
        );

      case AppRoutes.adminReportes:
        return _buildRoute(
          _protegerAdmin(const AdminReportsScreen()),
          settings,
        );

      case AppRoutes.vencimientosChoferes:
        return _buildRoute(
          _protegerAdmin(const AdminVencimientosChoferesScreen()),
          settings,
        );

      case AppRoutes.vencimientosChasis:
        return _buildRoute(
          _protegerAdmin(const AdminVencimientosChasisScreen()),
          settings,
        );

      case AppRoutes.vencimientosAcoplados:
        return _buildRoute(
          _protegerAdmin(const AdminVencimientosAcopladosScreen()),
          settings,
        );

      case AppRoutes.vencimientosCalendario:
        return _buildRoute(
          _protegerAdmin(const AdminVencimientosCalendarioScreen()),
          settings,
        );

      // ================= 🔥 NUEVO: SYNC DASHBOARD =================
      // Restringido a ADMIN (no SUPERVISOR): muestra info técnica de
      // sincronización y operaciones potencialmente disruptivas. Los
      // supervisores no la necesitan para su día a día.
      case AppRoutes.syncDashboard:
        return _buildRoute(
          _protegerSoloAdmin(const SyncDashboardScreen()),
          settings,
        );

      // ================= MANTENIMIENTO PREVENTIVO =================
      // Lista de tractores ordenados por urgencia de service
      // (basado en `serviceDistance` que viene del API Volvo).
      case AppRoutes.adminMantenimiento:
        return _buildRoute(
          _protegerAdmin(const AdminMantenimientoScreen()),
          settings,
        );

      // ================= VISTA EJECUTIVA (DEPRECATED) =================
      // Eliminada 2026-05-18 (decisión Santiago): unificada con INICIO.
      // Las secciones ricas (Panorama del mes, Tendencias, Personas)
      // ahora viven directamente en AdminPanelScreen si el rol tiene
      // verVistaEjecutiva. La ruta queda como redirect a INICIO para
      // cubrir bookmarks viejos y deep-links de notificaciones que
      // apunten a /admin_vista_ejecutiva.
      case AppRoutes.adminVistaEjecutiva:
        return _buildRoute(
          _protegerAdmin(const AdminPanelScreen()),
          settings,
        );

      // ================= ICM (Indice de Conducta de Manejo) =================
      // Hub + ranking + mapa de calor + drill-down. Reemplaza a las
      // pantallas legacy "ALERTAS VOLVO" y "ECO-DRIVING" del menú admin
      // (deshabilitadas 2026-05-15: las alertas crudas se reparten
      // consolidadas vía WhatsApp diario entre Molina y Emmanuel).
      case AppRoutes.adminIcmHub:
        return _buildRoute(
          _protegerAdmin(const IcmHubScreen()),
          settings,
        );
      case AppRoutes.adminIcmRanking:
        return _buildRoute(
          _protegerAdmin(const IcmRankingScreen()),
          settings,
        );
      case AppRoutes.adminIcmReporteSemanal:
        return _buildRoute(
          _protegerAdmin(const IcmReporteSemanalScreen()),
          settings,
        );
      case AppRoutes.adminIcmMapaCalor:
        return _buildRoute(
          _protegerAdmin(const IcmMapaCalorScreen()),
          settings,
        );
      case AppRoutes.adminIcmDetalleChofer:
        return _buildRoute(
          _protegerAdmin(const IcmDetalleChoferScreen()),
          settings,
        );

      // ================= ALERTAS VOLVO (LEGACY) =================
      // Mantenido por compat para shortcuts viejos. NO está en el menú
      // admin desde 2026-05-15. Quitar en limpieza posterior.
      case AppRoutes.adminVolvoAlertas:
        return _buildRoute(
          _protegerAdmin(const AdminVolvoAlertasScreen()),
          settings,
        );

      // ================= ECO-DRIVING (LEGACY) =================
      // Mantenido por compat para shortcuts viejos. NO está en el menú
      // admin desde 2026-05-15. Quitar en limpieza posterior.
      case AppRoutes.adminEcoDriving:
        return _buildRoute(
          _protegerAdmin(const AdminEcoDrivingScreen()),
          settings,
        );

      // ================= DESCARGAS (PTO) =================
      // Lista de eventos PTO (toma de fuerza) del Vehicle Alerts API. En
      // la flota Coopertrans = batea levantada para descargar carga.
      // Útil para anti-fraude, productividad por chofer y planeamiento
      // de viajes futuro.
      case AppRoutes.adminDescargasPto:
        return _buildRoute(
          _protegerAdmin(const AdminDescargasPtoScreen()),
          settings,
        );

      // ================= MAPA VOLVO =================
      // Visualización geográfica de TODOS los eventos del Vehicle Alerts
      // API sobre OpenStreetMap. Para detectar patrones geográficos:
      // tramos donde se concentran OVERSPEED, accesos a clientes con
      // DISTANCE_ALERT recurrentes, descargas PTO en lugares raros.
      case AppRoutes.adminMapaVolvo:
        return _buildRoute(
          _protegerAdmin(const AdminMapaVolvoScreen()),
          settings,
        );

      // ================= MAPA FLOTA EN VIVO =================
      // Posición actual de TODA la flota según Sitrack (toda la flota
      // tiene Sitrack — incluye también unidades sin Volvo Connect).
      // Lee de SITRACK_POSICIONES que la Cloud Function
      // `sitrackPosicionPoller` actualiza cada 5 min.
      case AppRoutes.adminMapaFlota:
        return _buildRoute(
          _protegerAdmin(const AdminMapaFlotaScreen()),
          settings,
        );

      // ================= ESTADO DEL BOT =================
      // Dashboard en vivo del bot Node.js de WhatsApp. Lee de
      // BOT_HEALTH/main que el bot escribe cada 60s.
      case AppRoutes.adminEstadoBot:
        return _buildRoute(
          _protegerAdmin(const AdminEstadoBotScreen()),
          settings,
        );

      // ================= GOMERÍA =================
      // Hub + sub-pantallas del módulo Gomería. Tablet pegada en pared
      // del taller; ADMIN o SUPERVISOR (típicamente con AREA=GOMERIA).
      // Capability: verGomeria. Las reglas Firestore restringen además
      // qué colecciones puede tocar cada rol (CUBIERTAS_MARCAS solo
      // ADMIN, CUBIERTAS y CUBIERTAS_INSTALADAS supervisor también, etc).
      case AppRoutes.adminGomeriaHub:
        return _buildRoute(
          _protegerAdmin(const GomeriaHubScreen()),
          settings,
        );
      case AppRoutes.adminGomeriaUnidades:
        return _buildRoute(
          _protegerAdmin(const GomeriaUnidadesListaScreen()),
          settings,
        );
      case AppRoutes.adminGomeriaUnidad:
        final args = settings.arguments as Map<String, dynamic>?;
        final unidadId = (args?['unidadId'] ?? '').toString();
        final unidadTipo = args?['unidadTipo'] as TipoUnidadCubierta? ??
            TipoUnidadCubierta.tractor;
        final tipoVehiculo = (args?['tipoVehiculo'] ?? '').toString();
        final modelo = (args?['modelo'] ?? '').toString();
        return _buildRoute(
          _protegerAdmin(GomeriaUnidadDetalleScreen(
            unidadId: unidadId,
            unidadTipo: unidadTipo,
            tipoVehiculo: tipoVehiculo,
            modelo: modelo,
          )),
          settings,
        );
      case AppRoutes.adminGomeriaStock:
        return _buildRoute(
          _protegerAdmin(const GomeriaStockScreen()),
          settings,
        );
      case AppRoutes.adminGomeriaRecapados:
        return _buildRoute(
          _protegerAdmin(const GomeriaRecapadosScreen()),
          settings,
        );
      case AppRoutes.adminGomeriaCubierta:
        final args = settings.arguments as Map<String, dynamic>?;
        final cubiertaId = (args?['cubiertaId'] ?? '').toString();
        return _buildRoute(
          _protegerAdmin(GomeriaCubiertaDetalleScreen(cubiertaId: cubiertaId)),
          settings,
        );
      case AppRoutes.adminGomeriaMarcasModelos:
        return _buildRoute(
          _protegerSoloAdmin(const AdminGomeriaMarcasModelosScreen()),
          settings,
        );

      // ================= CACHATORE =================
      // Control del bot que reserva/reagenda turnos de carga YPF en
      // iTurnos (corre 24/7 en la PC dedicada). Acceso ADMIN + SUPERVISOR
      // (cap verCachatore). La app escribe la selección en Firestore.
      case AppRoutes.adminCachatoreHub:
        return _buildRoute(
          _protegerAdmin(const CachatoreHubScreen()),
          settings,
        );

      // ================= LOGÍSTICA =================
      // Catálogos para preparar el futuro planeamiento de viajes.
      // Acceso ADMIN + SUPERVISOR (cap verLogistica).
      case AppRoutes.adminLogisticaHub:
        return _buildRoute(
          _protegerAdmin(const LogisticaHubScreen()),
          settings,
        );
      case AppRoutes.adminLogisticaEmpresas:
        return _buildRoute(
          _protegerAdmin(const LogisticaEmpresasScreen()),
          settings,
        );
      case AppRoutes.adminLogisticaUbicaciones:
        return _buildRoute(
          _protegerAdmin(const LogisticaUbicacionesScreen()),
          settings,
        );
      case AppRoutes.adminLogisticaTarifas:
        return _buildRoute(
          _protegerAdmin(const LogisticaTarifasScreen()),
          settings,
        );
      case AppRoutes.adminLogisticaTarifaForm:
        final args = settings.arguments as Map<String, dynamic>?;
        final tarifaId = args?['tarifaId'] as String?;
        return _buildRoute(
          _protegerAdmin(LogisticaTarifaFormScreen(tarifaId: tarifaId)),
          settings,
        );
      case AppRoutes.adminLogisticaMapaTarifas:
        return _buildRoute(
          _protegerAdmin(const LogisticaMapaTarifasScreen()),
          settings,
        );
      case AppRoutes.adminLogisticaViajes:
        return _buildRoute(
          _protegerAdmin(const LogisticaViajesListaScreen()),
          settings,
        );
      case AppRoutes.adminLogisticaViajeForm:
        final args = settings.arguments as Map<String, dynamic>?;
        final viajeId = args?['viajeId'] as String?;
        return _buildRoute(
          _protegerAdmin(LogisticaViajeFormScreen(viajeId: viajeId)),
          settings,
        );
      case AppRoutes.adminLogisticaViajeDetalle:
        final args = settings.arguments as Map<String, dynamic>?;
        final viajeId = args?['viajeId'] as String? ?? '';
        return _buildRoute(
          _protegerAdmin(LogisticaViajeDetalleScreen(viajeId: viajeId)),
          settings,
        );
      case AppRoutes.adminLogisticaLiquidacion:
        return _buildRoute(
          _protegerAdmin(const LogisticaLiquidacionScreen()),
          settings,
        );
      case AppRoutes.adminLogisticaAdelantos:
        return _buildRoute(
          _protegerAdmin(const LogisticaAdelantosScreen()),
          settings,
        );

      default:
        return null;
    }
  }

  static Route<dynamic> unknownRoute(RouteSettings settings) {
    return MaterialPageRoute(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const Text(AppTexts.rutaNoEncontrada),
        ),
        body: Center(
          child: ElevatedButton(
            onPressed: () {
              Navigator.of(context).pushNamedAndRemoveUntil(
                AppRoutes.login,
                (_) => false,
              );
            },
            child: const Text("VOLVER AL INICIO"),
          ),
        ),
      ),
    );
  }
}