class AppRoutes {
  // ✅ MEJORA PRO: Constructor privado. Evita que la clase sea instanciada por error.
  AppRoutes._();

  static const String login = '/';
  static const String home = '/home';

  /// Splash inicial — primer frame visible al abrir la app. Solo cosmético:
  /// muestra el logo + indicator durante ~1.5s y redirige a [home] (donde
  /// el AuthGuard decide login vs MainPanel).
  static const String splash = '/splash';

  // Usuario
  static const String perfil = '/perfil';
  static const String equipo = '/equipo';
  static const String misVencimientos = '/mis_vencimientos';

  // Admin
  static const String adminPanel = '/admin_panel';
  static const String adminPersonalLista = '/admin_personal_lista';
  static const String adminVehiculosLista = '/admin_vehiculos_lista';
  static const String adminVencimientosMenu = '/admin_vencimientos_menu';
  static const String adminRevisiones = '/admin_revisiones';
  static const String adminReportes = '/admin_reportes';
  static const String adminMantenimiento = '/admin_mantenimiento';
  static const String adminVolvoAlertas = '/admin_volvo_alertas';
  static const String adminEcoDriving = '/admin_eco_driving';
  static const String adminDescargasPto = '/admin_descargas_pto';
  static const String adminMapaVolvo = '/admin_mapa_volvo';
  static const String adminMapaFlota = '/admin_mapa_flota';
  static const String syncDashboard = '/sync_dashboard';
  static const String adminEstadoBot = '/admin_estado_bot';

  // Gomería
  static const String adminGomeriaHub = '/admin_gomeria';
  static const String adminGomeriaUnidades = '/admin_gomeria_unidades';
  static const String adminGomeriaUnidad = '/admin_gomeria_unidad';
  static const String adminGomeriaStock = '/admin_gomeria_stock';
  static const String adminGomeriaRecapados = '/admin_gomeria_recapados';
  static const String adminGomeriaCubierta = '/admin_gomeria_cubierta';
  static const String adminGomeriaMarcasModelos = '/admin_gomeria_marcas_modelos';

  // Logística — preparación del módulo de planeamiento de viajes.
  // Por ahora son catálogos (empresas, ubicaciones, tarifas) que en el
  // futuro alimentan la planificación de viajes y reportes de margen.
  static const String adminLogisticaHub = '/admin_logistica';
  static const String adminLogisticaEmpresas = '/admin_logistica_empresas';
  static const String adminLogisticaUbicaciones = '/admin_logistica_ubicaciones';
  static const String adminLogisticaTarifas = '/admin_logistica_tarifas';
  static const String adminLogisticaTarifaForm = '/admin_logistica_tarifa_form';
  static const String adminLogisticaMapaTarifas = '/admin_logistica_mapa_tarifas';
  // Viajes — ejecución y liquidación (2026-05-09).
  static const String adminLogisticaViajes = '/admin_logistica_viajes';
  static const String adminLogisticaViajeForm = '/admin_logistica_viaje_form';
  static const String adminLogisticaViajeDetalle = '/admin_logistica_viaje_detalle';

  /// ABM de docs por empresa empleadora (Póliza ART + Formulario 931).
  /// Admin/Supervisor: una sola pantalla con tarjeta por empresa, cada
  /// una con sus 2 documentos editables. Los empleados ven los archivos
  /// y vencimientos en su MIS VENCIMIENTOS, read-only.
  static const String adminEmpresasEmpleadoras = '/admin_empresas_empleadoras';


  // Auditorías
  static const String vencimientosChoferes = '/vencimientos_choferes';
  static const String vencimientosChasis = '/vencimientos_chasis';
  static const String vencimientosAcoplados = '/vencimientos_acoplados';
  static const String vencimientosCalendario = '/vencimientos_calendario';
}

class AppTexts {
  AppTexts._();

  /// Nombre comercial de la app — visible al usuario en AppBars,
  /// splash, login, dialogs. Si Vecchi cambia el branding, este es
  /// el único string a tocar para todo el cliente Flutter (los strings
  /// duplicados en UI específica deberían referirse a `AppTexts.appName`).
  static const String appName = 'Coopertrans Móvil';

  /// Subtítulo bajo el logo en login/splash.
  static const String tagline = 'GESTIÓN DE FLOTA · COOPERTRANS';

  static const String rutaNoEncontrada = 'Ruta no encontrada';
  // Podés mantener un registro visual de tu versión acá
  static const String appVersion = 'v 1.0.38';
}

// ===========================================================================
// ✅ MEJORA PRO: CENTRALIZACIÓN DE COLECCIONES Y ROLES (Sin "Magic Strings")
// ===========================================================================

class AppCollections {
  AppCollections._();

  static const String empleados = 'EMPLEADOS';
  static const String vehiculos = 'VEHICULOS';
  static const String revisiones = 'REVISIONES';
  static const String checklists = 'CHECKLISTS';
  static const String telemetriaHistorico = 'TELEMETRIA_HISTORICO';
  /// Idempotencia para notificaciones de mantenimiento: cada vez que un
  /// tractor cruza un umbral, escribimos un doc para no notificar dos
  /// veces el mismo evento en el mismo "ciclo".
  static const String mantenimientosAvisados = 'MANTENIMIENTOS_AVISADOS';
  /// Eventos del Volvo Vehicle Alerts API (IDLING, OVERSPEED,
  /// DISTANCE_ALERT, PTO, TELL_TALE, ALARM, etc.). La popula la
  /// scheduled function `volvoAlertasPoller` cada 5 min — el admin
  /// los marca como atendidos desde el tablero.
  static const String volvoAlertas = 'VOLVO_ALERTAS';

  /// Última posición conocida de cada unidad de la flota según Sitrack.
  /// Doc id = patente. Se reemplaza completo en cada poll (no es
  /// histórico, es un snapshot). La popula `sitrackPosicionPoller`
  /// cada 5 min llamando al endpoint `/v2/report` de Sitrack.
  /// Toda la flota (55 tractores hoy) está en Sitrack — incluye
  /// también unidades sin Volvo Connect, así que es la mejor fuente
  /// para "dónde está cada tractor ahora".
  static const String sitrackPosiciones = 'SITRACK_POSICIONES';

  /// Registro temporal inmutable de asignaciones chofer↔vehículo.
  /// Cada doc: `{vehiculo_id, chofer_dni, desde, hasta, ...}`. La
  /// asignación activa tiene `hasta == null`. Permite responder
  /// "¿quién manejaba la patente X el día Y?" sin importar cuántas
  /// veces rotó después. Único punto de escritura:
  /// `AsignacionVehiculoService`.
  static const String asignacionesVehiculo = 'ASIGNACIONES_VEHICULO';

  /// Registro temporal inmutable de asignaciones tractor↔enganche.
  /// Cada doc: `{enganche_id, tractor_id, desde, hasta, ...}`. La
  /// asignación activa tiene `hasta == null`. Permite calcular cuántos
  /// km recorrió una cubierta de enganche cruzando con
  /// `TELEMETRIA_HISTORICO` los km de cada tractor durante su período.
  /// Único punto de escritura: `AsignacionEngancheService`.
  static const String asignacionesEnganche = 'ASIGNACIONES_ENGANCHE';

  // ─── Módulo Gomería (2026-05-04) ───
  /// Marcas de cubiertas. Doc: `{nombre, activo}`. ABM desde la app
  /// por ADMIN. Soft-delete (campo `activo`) para no romper referencias
  /// históricas si se "borra" una marca que ya tiene cubiertas asociadas.
  static const String cubiertasMarcas = 'CUBIERTAS_MARCAS';

  /// Modelos de cubiertas (combinación marca + modelo + medida + tipo_uso).
  /// Doc: `{marca_id, marca_nombre (snapshot), modelo, medida, tipo_uso,
  /// km_vida_estimada_nueva, km_vida_estimada_recapada, recapable, activo}`.
  /// El `tipo_uso` (DIRECCION | TRACCION) determina en qué posiciones
  /// se puede instalar la cubierta.
  static const String cubiertasModelos = 'CUBIERTAS_MODELOS';

  /// Cubiertas individuales (1 doc por cubierta física). Doc:
  /// `{codigo (CUB-XXXX legible), modelo_id, modelo_snapshot, estado,
  /// vidas, km_acumulados, observaciones}`.
  /// Estado: `EN_DEPOSITO` | `INSTALADA` | `EN_RECAPADO` | `DESCARTADA`.
  /// `vidas` arranca en 1 (nueva), incrementa con cada recapado exitoso.
  static const String cubiertas = 'CUBIERTAS';

  /// Registro temporal inmutable de instalaciones cubierta↔posición.
  /// Espejo conceptual de ASIGNACIONES_VEHICULO pero para cubiertas.
  /// Doc: `{cubierta_id, codigo (snapshot), unidad_id, unidad_tipo
  /// (TRACTOR|ENGANCHE), posicion, vida (al instalar), desde, hasta,
  /// km_unidad_al_instalar, km_unidad_al_retirar, km_recorridos}`.
  /// La instalación activa tiene `hasta == null`. Único punto de
  /// escritura: `GomeriaService`.
  static const String cubiertasInstaladas = 'CUBIERTAS_INSTALADAS';

  /// Eventos de recapado (1 doc por cada vez que se manda a recapar).
  /// Doc: `{cubierta_id, codigo (snapshot), vida_recapado, proveedor,
  /// fecha_envio, fecha_retorno, costo, resultado (RECIBIDA |
  /// DESCARTADA_POR_PROVEEDOR), notas}`.
  static const String cubiertasRecapados = 'CUBIERTAS_RECAPADOS';

  /// Histórico inmutable de controles de presión y profundidad de banda
  /// realizados sobre cubiertas instaladas. 1 doc por lectura — la
  /// "última" en `CUBIERTAS_INSTALADAS` se mantiene como atajo para
  /// la grilla, pero la verdad histórica vive acá. Doc:
  /// `{cubierta_id, cubierta_codigo, instalacion_id, unidad_id,
  /// posicion, presion_psi, profundidad_banda_mm, fecha,
  /// registrado_por_dni, registrado_por_nombre}`.
  static const String cubiertasControles = 'CUBIERTAS_CONTROLES';

  /// Docs de control transaccional para garantizar unicidad de
  /// instalación. DocId: `{patente}__{POSICION}` (ej.
  /// `AB123CD__DIR_IZQ`). El doc EXISTE si y solo si esa posición está
  /// ocupada.
  ///
  /// Existe porque las queries `where().get()` dentro de una transaction
  /// del client SDK NO son transaccionales (solo `tx.get(DocRef)` lo
  /// es). Con 2 supervisores instalando en simultáneo en la misma
  /// posición las queries no detectaban la colisión y Firestore
  /// permitía crear 2 instalaciones activas. Este doc se lee con
  /// `tx.get` antes de crear → garantiza atomicidad.
  static const String cubiertasPosicionesActivas =
      'CUBIERTAS_POSICIONES_ACTIVAS';

  /// Espejo del anterior pero indexado por cubierta — garantiza que
  /// una misma cubierta no figure activa en 2 posiciones distintas.
  /// DocId: `{cubierta_id}`. Existe si y solo si la cubierta está
  /// instalada actualmente.
  static const String cubiertasActivas = 'CUBIERTAS_ACTIVAS';

  /// Catálogo de proveedores de recapado. Doc: `{nombre, activo}`.
  /// Existe para evitar typos en `CUBIERTAS_RECAPADOS.proveedor` que
  /// rompen reportes ("Recauchutados Sur" vs "RECAUCHUTADOS SUR" vs
  /// "Rec. Sur"). Soft-delete con `activo` para mantener proveedores
  /// históricos visibles en reportes viejos sin que aparezcan al
  /// elegir uno nuevo.
  static const String cubiertasProveedores = 'CUBIERTAS_PROVEEDORES';

  /// Colección de configs / cursores internos del backend (Volvo poller
  /// cursor, contadores como `cubiertas_counter`, etc.). Acceso
  /// restringido — la mayoría de docs solo los toca el server vía Admin
  /// SDK; algunos (como `cubiertas_counter`) los actualiza el cliente
  /// dentro de transactions de servicios específicos.
  static const String meta = 'META';

  /// Scores diarios de eco-driving (Volvo Group Scores API v2.0.2).
  /// La popula la scheduled function `volvoScoresPoller` (1x por día
  /// a las 04:00 ART). DocId: `{patente}_{YYYY-MM-DD}` para vehículos,
  /// `_FLEET_{YYYY-MM-DD}` para el agregado de flota. Cada doc tiene
  /// score total 0-100 + 17+ sub-scores (anticipation, braking, idling,
  /// etc.) + métricas operativas crudas (km, combustible, CO2).
  static const String volvoScoresDiarios = 'VOLVO_SCORES_DIARIOS';

  // ─── Módulo Logística (2026-05-07) ────────────────────────────────────
  // Catálogos para preparar el futuro planeamiento de viajes. Hoy son
  // ABMs simples; mañana van a ser el backbone de:
  //   - Asignación chofer + vehículo + tarifa
  //   - Cálculo de margen (tarifa_real − tarifa_chofer − combustible)
  //   - Reportes por dador / cliente / ruta
  //   - Histórico de qué cargas hizo Vecchi para predecir capacidad
  //
  // Todas las colecciones usan soft-delete (campo `activa: bool`) — se
  // requiere mantener visibles las históricas para reportes pasados.

  /// Empresas con las que Vecchi opera. Doc:
  /// `{nombre, tipo (CLIENTE | DADOR_TRANSPORTE), cuit, contacto, activa,
  /// creado_en, creado_por}`. Las empresas pueden ser:
  ///   - CLIENTE: empresa origen o destino del viaje (silo, planta,
  ///     puerto, fábrica) que paga el flete o lo recibe.
  ///   - DADOR_TRANSPORTE: otra empresa de transporte que tenía la carga
  ///     asignada y nos la cede; ellos cobran un % del flete (variable
  ///     por carga, se carga en TARIFAS_LOGISTICA).
  static const String empresasLogistica = 'EMPRESAS_LOGISTICA';

  /// Ubicaciones físicas (puntos de carga / descarga). Doc:
  /// `{nombre, localidad, provincia, direccion, lat, lng, activa,
  /// creado_en, creado_por}`. Reusable: una misma ubicación puede ser
  /// origen de una tarifa y destino de otra. `lat/lng` opcionales para
  /// el futuro mapa de planeamiento.
  static const String ubicacionesLogistica = 'UBICACIONES_LOGISTICA';

  /// Tarifas de viaje — el corazón del módulo. Cada doc es una "ruta
  /// con precio" para un caso operativo concreto. Doc:
  /// `{tipo_carga (PROPIA | TERCEROS), dador_id, porcentaje_comision_dador,
  /// empresa_origen_id, ubicacion_origen_id, empresa_destino_id,
  /// ubicacion_destino_id, flete (ORIGEN | DESTINO), unidad_tarifa
  /// (TN | VIAJE), tarifa_real, tarifa_chofer, vigente_desde, activa,
  /// notas, creado_en, creado_por}`.
  ///
  /// Doble tarifa: `tarifa_real` (lo que cobra Vecchi al cliente) y
  /// `tarifa_chofer` (lo que se le paga al chofer). La diferencia menos
  /// gastos = margen.
  ///
  /// Versionado: cuando cambia un precio se desactiva la vieja
  /// (`activa=false`) y se crea una nueva con `vigente_desde=now`. Así
  /// los reportes históricos siguen mostrando el precio que aplicaba.
  static const String tarifasLogistica = 'TARIFAS_LOGISTICA';

  /// Viajes — ejecución y liquidación. 1 doc por viaje real (carga →
  /// descarga). Refiere a `tarifasLogistica` (con snapshot de los
  /// precios al momento del viaje, para que cambios futuros no
  /// rompan reportes históricos). Incluye:
  ///   - Datos de la operación: chofer, vehículo, fechas carga/descarga.
  ///   - Cálculos: monto Vecchi, monto chofer (sin redondeo y
  ///     redondeado a múltiplo de 5), comisión chofer (18% default).
  ///   - Adelanto al chofer (monto + fecha + observación).
  ///   - Gastos extraordinarios reembolsables al chofer (peajes,
  ///     combustible, comida) — suman a la liquidación final.
  ///   - Estado: PROGRAMADO / EN_CURSO / COMPLETADO / CANCELADO /
  ///     POSTERGADO. Soft-delete con `activo: false`.
  ///   - Comprobante de remito firmado en Storage (al cargar descarga).
  /// RBAC: admin + supervisor. NO se expone al chofer (decisión
  /// Santiago 2026-05-09 — info delicada como tarifas, comisiones,
  /// liquidaciones).
  static const String viajesLogistica = 'VIAJES_LOGISTICA';

  // ─── Empresas empleadoras (2026-05-08) ───
  /// Empresas que figuran como empleador del personal (Vecchi Ariel y
  /// Vecchi Graciela S.R.L. + Sucesión de Vecchi Carlos Luis). Doc id:
  /// CUIT (formato `XX-XXXXXXXX-X`). Cada doc guarda los documentos
  /// laborales que son COMUNES a todos los empleados de esa empresa
  /// (Póliza ART + Formulario 931). El empleado los ve read-only desde
  /// MIS VENCIMIENTOS; el admin los actualiza una vez por empresa y
  /// queda reflejado en todos los empleados que figuran ahí.
  ///
  /// Por qué docId = CUIT (y no slug del nombre): es estable, único, y
  /// sale parseable directo del campo `EMPRESA` que ya guardamos en
  /// EMPLEADOS (formato `'NOMBRE: (CUIT)'`).
  static const String empresasEmpleadoras = 'EMPRESAS_EMPLEADORAS';
}

/// Documentos laborales que viven a NIVEL EMPRESA (no por empleado).
/// Estos son comunes a todos los empleados de la misma empresa:
/// Póliza ART, Formulario 931, Seguro Colectivo de Vida Obligatorio y
/// el comprobante de pago de cuota sindical los emite/paga la empresa,
/// no cada empleado.
///
/// Guardados en `EMPRESAS_EMPLEADORAS/{cuit}` con la misma convención
/// de campos que los docs de empleado: `VENCIMIENTO_<sufijo>` para la
/// fecha y `ARCHIVO_<sufijo>` para la URL del PDF en Storage.
///
/// Nota sobre `etiqueta...Admin` vs `etiqueta...Chofer`: SCVO se
/// muestra al admin con el nombre técnico (lo identifica el RR.HH. /
/// estudio contable) pero al chofer con el nombre coloquial ("Seguro
/// de Vida", que es como lo conocen). Para los demás docs ambas
/// etiquetas coinciden.
class AppDocsEmpresa {
  AppDocsEmpresa._();

  static const String etiquetaPolizaArt = 'Póliza ART';
  static const String sufijoPolizaArt = 'POLIZA_ART';
  static const String campoFechaPolizaArt = 'VENCIMIENTO_POLIZA_ART';
  static const String campoArchivoPolizaArt = 'ARCHIVO_POLIZA_ART';

  static const String etiquetaForm931 = 'Formulario 931';
  static const String sufijoForm931 = 'FORMULARIO_931';
  static const String campoFechaForm931 = 'VENCIMIENTO_FORMULARIO_931';
  static const String campoArchivoForm931 = 'ARCHIVO_FORMULARIO_931';

  /// Seguro Colectivo de Vida Obligatorio (mismo doc, distinto label
  /// según el contexto — admin lo ve "SCVO", chofer "Seguro de Vida").
  static const String etiquetaScvoAdmin = 'SCVO';
  static const String etiquetaScvoChofer = 'Seguro de Vida';
  static const String sufijoScvo = 'SCVO';
  static const String campoFechaScvo = 'VENCIMIENTO_SCVO';
  static const String campoArchivoScvo = 'ARCHIVO_SCVO';

  /// Certificado de libre deuda sindical (sindicato Camioneros u otro)
  /// — emitido a la empresa, mismo papel para todos los empleados de
  /// esa razón social. Mismo label en ambos contextos. Reusamos el
  /// sufijo legacy `LIBRE_DE_DEUDA_SINDICAL` que ya estaba en
  /// `AppDocsEmpleado.etiquetas` antes de la migración a empresa.
  static const String etiquetaLibreDeudaSindical = 'Libre de deuda sindical';
  static const String sufijoLibreDeudaSindical = 'LIBRE_DE_DEUDA_SINDICAL';
  static const String campoFechaLibreDeudaSindical =
      'VENCIMIENTO_LIBRE_DE_DEUDA_SINDICAL';
  static const String campoArchivoLibreDeudaSindical =
      'ARCHIVO_LIBRE_DE_DEUDA_SINDICAL';
}

/// Catálogo hardcoded de las 2 empresas empleadoras de Vecchi (2026-05-08).
///
/// El campo `EMPRESA` en EMPLEADOS guarda el string "completo"
/// (`'NOMBRE: (CUIT)'`) para mantener la UX del dropdown como estaba.
/// Para resolver de empleado a doc de empresa usamos el CUIT extraído
/// con [cuitDeStringEmpresa] como docId en EMPRESAS_EMPLEADORAS.
///
/// Si Vecchi suma una tercera empresa empleadora, agregar acá +
/// seedear el doc desde la pantalla admin.
class AppEmpresasEmpleadoras {
  AppEmpresasEmpleadoras._();

  /// Vecchi Ariel y Vecchi Graciela S.R.L.
  static const String cuitVecchiAriel = '30-70910015-3';

  /// Sucesión de Vecchi Carlos Luis.
  static const String cuitVecchiCarlos = '20-08569424-4';

  /// Catálogo (orden estable: el dropdown del form de personal usa
  /// estos mismos labels). Si cambiás un label acá, no afecta la
  /// resolución a doc de empresa porque va por CUIT.
  static const List<EmpresaEmpleadoraInfo> catalogo = [
    EmpresaEmpleadoraInfo(
      cuit: cuitVecchiAriel,
      label: 'VECCHI ARIEL Y VECCHI GRACIELA S.R.L: ($cuitVecchiAriel)',
      nombre: 'Vecchi Ariel y Vecchi Graciela S.R.L.',
    ),
    EmpresaEmpleadoraInfo(
      cuit: cuitVecchiCarlos,
      label: 'SUCESION DE VECCHI CARLOS LUIS: ($cuitVecchiCarlos)',
      nombre: 'Sucesión de Vecchi Carlos Luis',
    ),
  ];

  /// Extrae el CUIT del string `EMPRESA` que se guarda en cada doc de
  /// EMPLEADOS — formato esperado: `'NOMBRE: (XX-XXXXXXXX-X)'`.
  /// Devuelve `null` si no matchea (empleado sin empresa, o empresa
  /// vieja sin CUIT). Robusto a paréntesis sobrantes y a acentos.
  static String? cuitDeStringEmpresa(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'(\d{2}-\d{8}-\d)').firstMatch(raw);
    return m?.group(1);
  }

  /// Devuelve el `EmpresaEmpleadoraInfo` cuyo CUIT matchea.
  static EmpresaEmpleadoraInfo? infoPorCuit(String? cuit) {
    if (cuit == null) return null;
    for (final e in catalogo) {
      if (e.cuit == cuit) return e;
    }
    return null;
  }
}

/// Info estática de una empresa empleadora (CUIT + label visible).
class EmpresaEmpleadoraInfo {
  final String cuit;
  final String label;
  final String nombre;

  const EmpresaEmpleadoraInfo({
    required this.cuit,
    required this.label,
    required this.nombre,
  });
}

class AppRoles {
  AppRoles._();

  // ─── Roles del sistema (definen QUÉ puede hacer cada usuario) ───
  // 6 roles. Los 4 base + 2 especializados:
  //
  //   CHOFER       — empleado de manejo con vehículo asignado.
  //                  Ve sus vencimientos personales + su unidad.
  //   PLANTA       — empleado sin vehículo (planta, taller, gomería,
  //                  administración). Solo ve sus vencimientos
  //                  personales. NO ve "Mi unidad".
  //   GOMERIA      — gomero/encargado de cubiertas. Ve y opera SOLO
  //                  el módulo Gomería (stock, instalación, recapados).
  //                  No accede al resto del panel admin.
  //   SEG_HIGIENE  — Seguridad e Higiene. Ve los tableros Volvo
  //                  (alertas, eco-driving, descargas PTO, mapa) para
  //                  monitorear conducta y eventos de la flota. No
  //                  edita personal, flota ni opera el bot.
  //   SUPERVISOR   — mando medio. Gestiona personal + flota +
  //                  vencimientos + revisiones + bot. NO puede
  //                  crear/borrar admins ni cambiar roles de otros.
  //   ADMIN        — control total. Crea admins, cambia roles, audita.
  //
  // Compatibilidad: 'USUARIO' es el rol legacy que tenían los choferes
  // antes de la migración a 4 roles. Se mantiene como alias hasta que
  // el script de migración los pase todos a CHOFER.
  static const String chofer = 'CHOFER';
  static const String planta = 'PLANTA';
  static const String gomeria = 'GOMERIA';
  static const String segHigiene = 'SEG_HIGIENE';
  static const String supervisor = 'SUPERVISOR';
  static const String admin = 'ADMIN';

  /// Rol legacy. Tratar como CHOFER hasta que los datos viejos migren.
  static const String usuarioLegacy = 'USUARIO';

  /// Lista de todos los roles válidos (para validar entradas).
  static const List<String> todos = [
    chofer,
    planta,
    gomeria,
    segHigiene,
    supervisor,
    admin,
  ];

  /// Etiqueta legible para mostrar en UI.
  static const Map<String, String> etiquetas = {
    chofer: 'Chofer',
    planta: 'Planta',
    gomeria: 'Gomería',
    segHigiene: 'Seguridad e Higiene',
    supervisor: 'Supervisor',
    admin: 'Admin',
  };

  /// `true` si este rol tiene vehículo/enganche asignable. Usado por
  /// el form para mostrar/ocultar los campos VEHICULO y ENGANCHE.
  static bool tieneVehiculo(String rol) =>
      rol == chofer || rol == usuarioLegacy;

  /// Normaliza el rol legacy (USUARIO → CHOFER) para que el resto del
  /// código pueda asumir solo los 4 valores nuevos.
  static String normalizar(String? rol) {
    final r = (rol ?? '').toUpperCase();
    if (r == usuarioLegacy) return chofer;
    if (todos.contains(r)) return r;
    return chofer; // fallback conservador
  }
}

// ===========================================================================
// ÁREAS — Dónde trabaja el empleado (info organizacional, no permisos)
// ===========================================================================
//
// Independiente del ROL. Un empleado puede ser SUPERVISOR + TALLER (jefe
// de taller) o PLANTA + GOMERIA (gomero) o ADMIN + ADMINISTRACION (vos).
//
// Esta lista la lee el dropdown del form de personal y los filtros de
// la lista. Si Vecchi suma un sector nuevo, se agrega acá únicamente.

class AppAreas {
  AppAreas._();

  static const String manejo = 'MANEJO';
  static const String administracion = 'ADMINISTRACION';
  static const String planta = 'PLANTA';
  static const String taller = 'TALLER';
  static const String gomeria = 'GOMERIA';

  static const List<String> todas = [
    manejo,
    administracion,
    planta,
    taller,
    gomeria,
  ];

  /// Etiqueta legible (capitalizada) para mostrar en UI.
  static const Map<String, String> etiquetas = {
    manejo: 'Manejo',
    administracion: 'Administración',
    planta: 'Planta',
    taller: 'Taller',
    gomeria: 'Gomería',
  };

  /// Devuelve el área default sugerido según el rol elegido.
  /// Optimiza el flow del form: al elegir CHOFER, sugerimos MANEJO.
  static String defaultParaRol(String rol) {
    switch (rol) {
      case AppRoles.chofer:
      case AppRoles.usuarioLegacy:
        return manejo;
      case AppRoles.admin:
      case AppRoles.supervisor:
        return administracion;
      case AppRoles.planta:
        return planta;
    }
    return manejo;
  }
}

// ===========================================================================
// TIPOS DE UNIDAD DE LA FLOTA
// ===========================================================================
//
// Centralizar acá la lista evita el problema de "agregué un tipo nuevo
// pero me olvidé de actualizarlo en el formulario / la lista / el filtro
// del chofer / el reporte de vencimientos". Cuando aparezca un tipo
// nuevo, sumalo solamente acá y la app lo va a mostrar en todos lados.
class AppTiposVehiculo {
  AppTiposVehiculo._();

  /// Tractor / chasis (la unidad con motor que arrastra los enganches).
  static const String tractor = 'TRACTOR';

  /// Lista de tipos de enganche soportados por la app.
  ///
  /// `ACOPLADO` se mantiene al final por **retrocompatibilidad**: hay
  /// documentos viejos en Firestore con ese TIPO. No aparece como opción
  /// en el formulario de alta para que no se carguen unidades nuevas con
  /// ese tipo, pero sí se incluye en filtros y queries para que las
  /// unidades históricas se vean correctamente.
  static const List<String> enganches = [
    'BATEA',
    'TOLVA',
    'BIVUELCO',
    'TANQUE',
    'ACOPLADO',
  ];

  /// Tipos que se ofrecen como opción en el formulario de alta de
  /// vehículos. Es la lista oficial de los que un admin puede crear.
  static const List<String> seleccionables = [
    'TRACTOR',
    'BATEA',
    'TOLVA',
    'BIVUELCO',
    'TANQUE',
  ];

  /// Etiqueta legible para mostrar en UI (plural). Usar para títulos de
  /// secciones/listas que agrupan unidades por tipo.
  static const Map<String, String> pluralEtiquetas = {
    'TRACTOR': 'TRACTORES',
    'BATEA': 'BATEAS',
    'TOLVA': 'TOLVAS',
    'BIVUELCO': 'BIVUELCOS',
    'TANQUE': 'TANQUES',
    'ACOPLADO': 'ACOPLADOS',
  };

  /// Etiqueta singular en minúsculas para mensajes ("sin tractores
  /// cargados").
  static const Map<String, String> pluralMinusculas = {
    'TRACTOR': 'tractores',
    'BATEA': 'bateas',
    'TOLVA': 'tolvas',
    'BIVUELCO': 'bivuelcos',
    'TANQUE': 'tanques',
    'ACOPLADO': 'acoplados',
  };
}

// ===========================================================================
// MANTENIMIENTO PREVENTIVO (Volvo serviceDistance)
// ===========================================================================
//
// `serviceDistance` que entrega Volvo en metros = distancia restante al
// próximo service programado. Negativo = vencido.
//
// Para que el admin pueda anticipar turnos de taller, definimos 4
// umbrales en KM (NO metros):
//
//   > 5000 km  →  OK (verde)
//   ≤ 5000 km  →  Falta poco (amarillo claro / lime)
//   ≤ 2500 km  →  Programar (amarillo)
//   ≤ 1000 km  →  Urgente (naranja)
//   ≤ 0    km  →  Vencido (rojo)
//
// Cualquier ajuste a la curva de alarma se hace acá — pantalla y badge
// leen estas constantes.
class AppMantenimiento {
  AppMantenimiento._();

  /// KM al próximo service desde el cual el badge pasa a "Falta poco"
  /// (amarillo claro).
  static const double atencionKm = 5000;

  /// KM desde el cual ya hay que pedir turno al taller ("Programar").
  static const double programarKm = 2500;

  /// KM desde el cual la situación es urgente ("Servicio urgente").
  static const double urgenteKm = 1000;

  /// Intervalo entre services programados, en KM. Volvo aplica el plan
  /// estándar de 50.000 km a la flota Vecchi. Si en el futuro hay
  /// tractores con plan distinto, podríamos agregar un campo
  /// `INTERVALO_SERVICE_KM` en VEHICULOS y caer a esta constante como
  /// default.
  static const double intervaloServiceKm = 50000;

  /// Niveles de urgencia ordenados de menor a mayor severidad.
  /// Usados por el badge y la lista de mantenimiento para sortear.
  static MantenimientoEstado clasificar(double? serviceDistanceKm) {
    if (serviceDistanceKm == null) return MantenimientoEstado.sinDato;
    if (serviceDistanceKm <= 0) return MantenimientoEstado.vencido;
    if (serviceDistanceKm <= urgenteKm) return MantenimientoEstado.urgente;
    if (serviceDistanceKm <= programarKm) return MantenimientoEstado.programar;
    if (serviceDistanceKm <= atencionKm) return MantenimientoEstado.atencion;
    return MantenimientoEstado.ok;
  }

  /// Calcula el KM al que se hizo el último service de un tractor.
  ///
  /// Fórmula: `KM_ACTUAL + serviceDistance − intervaloServiceKm`.
  ///
  /// Ejemplo: si un tractor tiene 380.000 km y `serviceDistance: 12.000`,
  /// el próximo service es a 392.000 km y el último fue a 342.000 km.
  ///
  /// Devuelve null si falta alguno de los dos inputs (no hay manera de
  /// estimar sin ambos).
  static double? calcularKmUltimoService({
    required double? kmActual,
    required double? serviceDistanceKm,
  }) {
    if (kmActual == null || serviceDistanceKm == null) return null;
    final resultado = kmActual + serviceDistanceKm - intervaloServiceKm;
    // Si el cálculo da negativo (tractor con menos de 50k km) significa
    // que todavía está en su primer ciclo de service, no tuvo "anterior".
    if (resultado < 0) return null;
    return resultado;
  }

  /// KM recorridos desde el último service. Útil para mostrar en la card
  /// "X km recorridos desde el último service".
  static double? kmDesdeUltimoService({
    required double? kmActual,
    required double? serviceDistanceKm,
  }) {
    final kmUltimo = calcularKmUltimoService(
      kmActual: kmActual,
      serviceDistanceKm: serviceDistanceKm,
    );
    if (kmUltimo == null || kmActual == null) return null;
    return kmActual - kmUltimo;
  }

  /// Calcula `serviceDistance` (KM al próximo service) a partir del
  /// último service cargado manualmente y el odómetro actual.
  ///
  /// Fórmula: `(ULTIMO_SERVICE_KM + intervaloServiceKm) − KM_ACTUAL`.
  ///
  /// Útil cuando la API de Volvo NO entrega `serviceDistance` para la
  /// cuenta (paquete API limitado). Caso real de Vecchi: el response
  /// `vehiclestatuses` no incluye el bloque `uptimeData` que contiene
  /// ese campo, así que dependemos del dato manual + KM en vivo.
  ///
  /// Devuelve null si falta alguno de los inputs **o si los datos son
  /// inconsistentes** (ULTIMO_SERVICE_KM > KM_ACTUAL: el admin cargó
  /// algo mal, ej. invirtió dígitos). Puede ser **negativo** si el
  /// tractor ya pasó el momento del próximo service (vencido).
  static double? serviceDistanceDesdeManual({
    required double? ultimoServiceKm,
    required double? kmActual,
  }) {
    if (ultimoServiceKm == null || kmActual == null) return null;
    // Defensa contra typo del admin: el último service no puede haber
    // sido a más kilómetros de los que tiene el tractor ahora.
    if (ultimoServiceKm > kmActual) return null;
    return (ultimoServiceKm + intervaloServiceKm) - kmActual;
  }
}

// =============================================================================
// SOFT-DELETE (alta/baja de empleados y vehículos)
// =============================================================================
//
// Sistema unificado para "dar de baja" sin borrar el doc de Firestore.
// Permite reactivar el registro más tarde si fue baja por error o si
// el chofer/vehículo vuelve. Aplica a EMPLEADOS y VEHICULOS.
//
// Convenciones:
//   - Campo `ACTIVO: bool` (mayúsculas, igual que el resto de campos
//     directos del doc). Default true: docs viejos sin el campo se
//     consideran activos por compat.
//   - Al dar de baja: ACTIVO=false + metadata + se desafectan todas
//     las asignaciones (vehículo, enganche) + se vacían los campos
//     de vencimientos y archivos (decisión Santiago 2026-05-04: el
//     reactivar implica re-cargar desde cero, no preservar).
//   - Al reactivar: ACTIVO=true + metadata. Los vencimientos quedan
//     vacíos hasta que el admin los cargue. La unidad NO se restaura
//     automáticamente — se asume que pudo haber pasado a otro chofer.

class AppActivo {
  AppActivo._();

  /// Campo principal del flag de baja en EMPLEADOS y VEHICULOS.
  static const String campo = 'ACTIVO';

  /// Metadata de baja.
  static const String campoBajaEn = 'BAJA_EN';
  static const String campoBajaPorDni = 'BAJA_POR_DNI';
  static const String campoBajaMotivo = 'BAJA_MOTIVO';

  /// Metadata de reactivación.
  static const String campoReactivadoEn = 'REACTIVADO_EN';
  static const String campoReactivadoPorDni = 'REACTIVADO_POR_DNI';

  /// `true` si el doc NO está dado de baja. Acepta:
  ///   - ACTIVO=true → true (alta explícita).
  ///   - ACTIVO=null/ausente → true (default; doc viejo pre-soft-delete).
  ///   - ACTIVO=false → false (baja).
  /// Aplicar a TODA query de EMPLEADOS/VEHICULOS que NO sea para gestión
  /// específica de bajas (ej. listas, reportes, KPIs, alertas, cron del
  /// bot, lookups del Cloud Functions).
  static bool esActivo(Map<String, dynamic> data) {
    final v = data[campo];
    return v != false; // null o true → activo
  }
}

/// Estados del mantenimiento preventivo, ordenados por severidad.
/// El `index` se usa para sortear (menor índice = más urgente).
enum MantenimientoEstado {
  vencido('Servicio vencido'),
  urgente('Servicio urgente'),
  programar('Programar servicio'),
  atencion('Falta poco'),
  ok('OK'),
  sinDato('Sin datos');

  final String etiqueta;
  const MantenimientoEstado(this.etiqueta);
}
