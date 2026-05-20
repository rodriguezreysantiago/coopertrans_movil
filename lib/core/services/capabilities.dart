// Sistema de capabilities (RBAC) del cliente.
//
// Cada `Capability` representa UNA acción concreta que el usuario puede
// querer hacer (ver una pantalla, editar un campo, ejecutar una
// operación). Cada `AppRoles` tiene asignado un set de capabilities.
//
// Lo usamos en 3 lugares:
//   1. `RoleGuard` para proteger rutas/pantallas enteras.
//   2. Panel admin (admin_panel_screen) para ocultar tiles que el rol
//      no puede usar.
//   3. Acciones puntuales (form de personal: el dropdown de ROL solo
//      muestra ADMIN si el usuario logueado puede crear admins).
//
// Diseño: la matriz vive ENTERA acá, hardcoded. Más adelante (cuando
// haya pantalla de Gestión de roles del Hito 4) podríamos pasar las
// reglas a Firestore para que el admin las edite — pero por ahora
// hardcodearlas evita una capa extra y un seek de I/O en cada chequeo.
//
// Sincronización con Firestore rules: los chequeos de seguridad reales
// los hace `firestore.rules` server-side basándose en el custom claim
// `request.auth.token.rol`. Las capabilities del cliente son SOLO para
// UX (ocultar opciones que de todas maneras la regla rechazaría). NO
// confiar en estos chequeos para seguridad.

import '../constants/app_constants.dart';

/// Cada acción concreta que el sistema puede gatear por rol.
enum Capability {
  // ─── Pantallas admin ───
  verPanelAdmin,
  verListaPersonal,
  verListaFlota,
  verVencimientos,
  verRevisiones,
  verReportes,
  verMantenimiento,
  verEstadoBot,
  verSyncDashboard,
  /// Tablero de alertas de Volvo Vehicle Alerts API (eventos de la flota:
  /// IDLING, OVERSPEED, DISTANCE_ALERT, PTO, TELL_TALE, etc.). Tanto admin
  /// como supervisor pueden verlas y marcarlas como atendidas.
  verAlertasVolvo,
  /// Módulo Gomería — gestión de stock de cubiertas, instalación/retiro
  /// por posición de tractor o enganche, recapados. Operado típicamente
  /// desde una tablet pegada en la pared del taller. Tanto ADMIN como
  /// SUPERVISOR pueden entrar (la idea es que el supervisor de gomería,
  /// con AREA=GOMERIA, sea el operador habitual). El gating fino por
  /// AREA lo decidirá Vecchi si más adelante quieren restringir.
  verGomeria,
  /// Módulo Logística — catálogos de empresas, ubicaciones y tarifas
  /// que arman la base del futuro sistema de planeamiento de viajes.
  /// Acceso ADMIN + SUPERVISOR (mismo nivel que personal/flota: son los
  /// que arman la operación). Choferes y otros roles no entran.
  verLogistica,
  /// Módulo ICM (Índice de Conducta de Manejo) — el módulo que YPF
  /// audita en su Tablero ICM. Combina los eventos Sitrack peligrosos
  /// de cada chofer (sobrevelocidad cartográfica, frenadas/aceleraciones
  /// bruscas, salida de carril, etc.) en un puntaje 0-100 + ranking +
  /// mapa de calor de infracciones. Acceso ADMIN + SUPERVISOR + SEG_HIGIENE
  /// (este último es el destinatario natural — Molina es quien dialoga
  /// con los choferes con peor desempeño).
  verIcm,
  /// Vista Ejecutiva — tablero CEO con KPIs grandes (viajes del mes,
  /// ICM flota, choferes activos, alertas críticas), gráficos de
  /// tendencia (ICM 12 semanas, viajes/semana) y top 5 mejores choferes.
  /// Pensada para el panorama rápido de gestión (Diego/Carlos, Santiago,
  /// supervisores). Reusa el módulo ICM y los datos de viajes existentes.
  verVistaEjecutiva,
  /// Módulo Cachatore — control del bot que reserva/reagenda turnos de
  /// carga YPF en iTurnos (corre 24/7 en la PC dedicada). Desde acá se
  /// elige a qué choferes les caza turno, en qué franja, y se ve el
  /// estado en vivo. Acceso ADMIN + SUPERVISOR (operación, como Logística).
  verCachatore,

  // ─── Acciones sobre personal ───
  crearEmpleado,
  editarEmpleado,
  eliminarEmpleado,
  /// Solo ADMIN puede crear o promover a otro empleado a ROL=ADMIN.
  /// SUPERVISOR puede crear hasta SUPERVISOR pero no ADMIN.
  asignarRolAdmin,
  /// Cambiar el rol de un empleado existente. Solo ADMIN.
  cambiarRolEmpleado,

  // ─── Acciones sobre flota ───
  crearVehiculo,
  editarVehiculo,
  eliminarVehiculo,

  // ─── Vencimientos / revisiones ───
  aprobarRevision,
  rechazarRevision,

  // ─── Auditoría ───
  verAuditoria,
}

/// Matriz de capabilities por rol. Cada rol del sistema tiene asignado
/// un Set de capabilities — el orden no importa.
class Capabilities {
  Capabilities._();

  /// Set de capabilities que tiene cada rol. Si un rol no aparece acá
  /// (ej. un rol legacy desconocido), se le asigna el set de CHOFER
  /// como fallback conservador (acceso mínimo).
  static const Map<String, Set<Capability>> _porRol = {
    AppRoles.chofer: {
      // Chofer no tiene acceso al panel admin. Usa el shell de chofer.
    },
    AppRoles.planta: {
      // Igual que chofer: no entra al panel admin.
    },
    AppRoles.gomeria: {
      // Rol especializado: solo opera el módulo Gomería. Entra al panel
      // admin para acceder al hub de gomería; ningún otro tile aparece.
      Capability.verPanelAdmin,
      Capability.verGomeria,
    },
    AppRoles.segHigiene: {
      // Rol especializado de Seguridad e Higiene: monitorea conducta de
      // manejo via el módulo ICM (que YPF audita) + posiciones Sitrack
      // en tiempo real. Las alertas Volvo crudas NO van a este rol — ya
      // las recibe consolidadas vía WhatsApp diario.
      Capability.verPanelAdmin,
      Capability.verIcm,
      Capability.verAlertasVolvo, // mantiene Mapa Flota + Descargas PTO
    },
    AppRoles.supervisor: {
      Capability.verPanelAdmin,
      Capability.verListaPersonal,
      Capability.verListaFlota,
      Capability.verVencimientos,
      Capability.verRevisiones,
      Capability.verReportes,
      Capability.verMantenimiento,
      Capability.verEstadoBot,
      Capability.verAlertasVolvo,
      Capability.verGomeria,
      Capability.verLogistica,
      Capability.verIcm,
      Capability.verVistaEjecutiva,
      Capability.verCachatore,
      // Editar y crear personal/vehículos: sí. Pero NO puede asignar
      // rol ADMIN ni cambiar rol de admins existentes.
      Capability.crearEmpleado,
      Capability.editarEmpleado,
      Capability.crearVehiculo,
      Capability.editarVehiculo,
      Capability.aprobarRevision,
      Capability.rechazarRevision,
    },
    AppRoles.admin: {
      // ADMIN tiene TODAS las capabilities. Lo construimos desde el set
      // de SUPERVISOR + las exclusivas de admin para no duplicar
      // listas. Ver `_buildAdminSet` abajo.
    },
  };

  /// Set efectivo de capabilities de cada rol — aplicado fallbacks y
  /// herencia. Memoizado en frio porque enum sets son inmutables.
  static final Map<String, Set<Capability>> _resolved = _resolverHerencia();

  static Map<String, Set<Capability>> _resolverHerencia() {
    // ADMIN hereda todo de SUPERVISOR + exclusivas.
    final supervisor = _porRol[AppRoles.supervisor] ?? {};
    final adminExtra = <Capability>{
      Capability.eliminarEmpleado,
      Capability.eliminarVehiculo,
      Capability.asignarRolAdmin,
      Capability.cambiarRolEmpleado,
      Capability.verAuditoria,
      Capability.verSyncDashboard,
    };
    return {
      AppRoles.chofer: _porRol[AppRoles.chofer] ?? {},
      AppRoles.planta: _porRol[AppRoles.planta] ?? {},
      AppRoles.gomeria: _porRol[AppRoles.gomeria] ?? {},
      AppRoles.segHigiene: _porRol[AppRoles.segHigiene] ?? {},
      AppRoles.supervisor: supervisor,
      AppRoles.admin: {...supervisor, ...adminExtra},
    };
  }

  /// `true` si el rol tiene la capability indicada.
  ///
  /// Acepta `rol` con cualquier formato (lowercase, legacy USUARIO,
  /// etc) — internamente normaliza con `AppRoles.normalizar`.
  static bool can(String? rol, Capability cap) {
    final normalizado = AppRoles.normalizar(rol);
    final set = _resolved[normalizado] ?? const <Capability>{};
    return set.contains(cap);
  }

  /// `true` si el rol tiene **alguna** de las capabilities (OR).
  static bool canAny(String? rol, Iterable<Capability> caps) {
    return caps.any((c) => can(rol, c));
  }

  /// `true` si el rol tiene **todas** las capabilities (AND).
  static bool canAll(String? rol, Iterable<Capability> caps) {
    return caps.every((c) => can(rol, c));
  }

  /// Devuelve el set completo de capabilities del rol — útil para
  /// debugging, logging o para construir UIs que listan todo lo que
  /// puede hacer un usuario.
  static Set<Capability> ofRol(String? rol) {
    final normalizado = AppRoles.normalizar(rol);
    return _resolved[normalizado] ?? const <Capability>{};
  }
}
