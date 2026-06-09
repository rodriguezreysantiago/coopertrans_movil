class AppRoutes {
  // âœ… MEJORA PRO: Constructor privado. Evita que la clase sea instanciada por error.
  AppRoutes._();

  static const String login = '/';
  static const String home = '/home';

  /// Splash inicial â€” primer frame visible al abrir la app. Solo cosmÃ©tico:
  /// muestra el logo + indicator durante ~1.5s y redirige a [home] (donde
  /// el AuthGuard decide login vs MainPanel).
  static const String splash = '/splash';

  // Usuario
  static const String perfil = '/perfil';
  static const String equipo = '/equipo';
  static const String misVencimientos = '/mis_vencimientos';

  /// "Mi jornada" â€” el chofer ve su propio registro de jornada v3
  /// (REGISTRO_JORNADAS): turno, manejo neto, pausas explicadas, recorrido y
  /// confianza. Transparencia (Paso 2 del plan vigilador v3).
  static const String miJornada = '/mi_jornada';

  // Admin
  static const String adminPanel = '/admin_panel';
  // Vista Ejecutiva â€” tablero CEO con KPIs grandes + grÃ¡ficos de tendencia
  // + top 5 choferes. Pensado como "homepage" para directivos / panorama
  // operativo rÃ¡pido. ReÃºne data ya capturada en otros mÃ³dulos
  // (VIAJES_LOGISTICA + ICM_OFICIAL + STATS/dashboard).
  static const String adminVistaEjecutiva = '/admin_vista_ejecutiva';
  static const String adminPersonalLista = '/admin_personal_lista';
  static const String adminVehiculosLista = '/admin_vehiculos_lista';
  static const String adminVencimientosMenu = '/admin_vencimientos_menu';
  static const String adminRevisiones = '/admin_revisiones';
  static const String adminReportes = '/admin_reportes';
  static const String adminMantenimiento = '/admin_mantenimiento';
  // ICM (Ãndice de Conducta de Manejo) â€” mÃ³dulo que YPF audita en su
  // Tablero ICM. Reemplaza a las pantallas legacy de "ALERTAS VOLVO"
  // y "ECO-DRIVING" en el menÃº admin (deshabilitadas 2026-05-15 ya que
  // las alertas crudas se reparten consolidadas vÃ­a WhatsApp diario
  // entre Molina y Emmanuel â€” lo Ãºnico que faltaba era un tablero
  // unificado para gestiÃ³n proactiva).
  static const String adminIcmHub = '/admin_icm';
  static const String adminIcmRanking = '/admin_icm_ranking';
  static const String adminIcmReporteSemanal = '/admin_icm_reporte_semanal';
  static const String adminIcmMapaCalor = '/admin_icm_mapa_calor';

  /// Detalle individual de un chofer en ICM (ICM mes + comparativa vs mes
  /// anterior + urbano/no-urbano + infracciones). El tile directo del hub
  /// quedÃ³ eliminado 2026-05-23 (baja utilidad como entry point general),
  /// pero la pantalla se mantiene como destino de los tap â†’ detalle desde
  /// el ranking + top 5 mejores/peores del hub + top 5 del reporte mensual.
  static const String adminIcmDetalleChofer = '/admin_icm_detalle_chofer';

  /// Jornada por chofer y dÃ­a â€” inicio/fin, tramos de manejo y paradas
  /// reconstruidos desde SITRACK_EVENTOS por la CF
  /// `reconstruirJornadasDiario`. Marca descansos suficientes (â‰¥15 min
  /// para corte de bloque, â‰¥8h para fin de jornada segÃºn polÃ­tica Vecchi v2).
  static const String adminIcmJornadaDia = '/admin_icm_jornada_dia';

  /// Registro de jornada v3 (vista admin/supervisor) â€” la jornada REAL
  /// reconstruida por seÃ±ales Sitrack (REGISTRO_JORNADAS). Fuente oficial para
  /// adjudicar disputas y revisar compliance (Paso 4 del plan vigilador v3).
  static const String adminRegistroJornada = '/admin_registro_jornada';
  // Pantallas Volvo restantes (mantienen `verAlertasVolvo` por ahora):
  /// AuditorÃ­a de asignaciones â€” cruza el histÃ³rico REAL del iButton
  /// (SITRACK_IBUTTONS_HISTORICO) contra ASIGNACIONES_VEHICULO. Util
  /// para multas tardÃ­as + investigaciones + reconciliaciÃ³n.
  static const String adminAuditoriaAsignaciones =
      '/admin_auditoria_asignaciones';

  /// MÃ³dulo "Descargas" â€” cola en vivo + reciÃ©n + KPIs basado en
  /// presencia REAL en geocercas configurables. ReemplazÃ³ al detector
  /// PTO Volvo (eliminado 2026-05-24) que solo cubrÃ­a flota Volvo y
  /// daba falsos positivos.
  static const String adminDescargas = '/admin_descargas';

  /// Pantalla admin para CRUD de zonas de descarga (las geocercas que
  /// alimentan al mÃ³dulo Descargas).
  static const String adminZonasDescarga = '/admin_zonas_descarga';

  static const String adminMapaVolvo = '/admin_mapa_volvo';
  static const String adminMapaFlota = '/admin_mapa_flota';
  // Rutas legacy (en deprecaciÃ³n â€” quitadas del menÃº principal pero el
  // case del router se mantiene unos releases por si alguien tiene un
  // shortcut/bookmark, hasta limpieza definitiva):
  static const String adminVolvoAlertas = '/admin_volvo_alertas';
  static const String adminEcoDriving = '/admin_eco_driving';
  static const String adminEstadoBot = '/admin_estado_bot';

  /// CRUD de destinatarios de notificaciÃ³n (M5, 2026-05-24). Override
  /// editable desde la app de los DNIs hardcoded en CF y bot.
  static const String adminDestinatariosNotificacion =
      '/admin_destinatarios_notificacion';

  // GomerÃ­a (V2 montaje por posiciÃ³n; el sistema viejo CUB-XXXX se dio de baja).
  static const String adminGomeriaMarcasModelos =
      '/admin_gomeria_marcas_modelos';

  // LogÃ­stica â€” preparaciÃ³n del mÃ³dulo de planeamiento de viajes.
  // Por ahora son catÃ¡logos (empresas, ubicaciones, tarifas) que en el
  // futuro alimentan la planificaciÃ³n de viajes y reportes de margen.
  static const String adminLogisticaHub = '/admin_logistica';
  static const String adminLogisticaEmpresas = '/admin_logistica_empresas';
  static const String adminLogisticaUbicaciones =
      '/admin_logistica_ubicaciones';
  static const String adminLogisticaTarifas = '/admin_logistica_tarifas';
  static const String adminLogisticaTarifaForm = '/admin_logistica_tarifa_form';
  static const String adminLogisticaMapaTarifas =
      '/admin_logistica_mapa_tarifas';
  // Viajes â€” ejecuciÃ³n y liquidaciÃ³n (2026-05-09).
  static const String adminLogisticaViajes = '/admin_logistica_viajes';
  static const String adminLogisticaViajeForm = '/admin_logistica_viaje_form';
  static const String adminLogisticaViajeDetalle =
      '/admin_logistica_viaje_detalle';
  static const String adminLogisticaLiquidacion =
      '/admin_logistica_liquidacion';
  // Adelantos â€” independientes de viajes (2026-05-13). Por sueldo o
  // por viaje especÃ­fico, con comprobante imprimible (mismo counter
  // que tenÃ­a el adelanto del viaje en la versiÃ³n vieja).
  static const String adminLogisticaAdelantos = '/admin_logistica_adelantos';

  /// ABM de docs por empresa empleadora (PÃ³liza ART + Formulario 931).
  /// Admin/Supervisor: una sola pantalla con tarjeta por empresa, cada
  /// una con sus 2 documentos editables. Los empleados ven los archivos
  /// y vencimientos en su MIS VENCIMIENTOS, read-only.
  static const String adminEmpresasEmpleadoras = '/admin_empresas_empleadoras';

  // Cachatore â€” control del bot que reserva/reagenda turnos de carga YPF
  // en iTurnos (corre 24/7 en la PC dedicada). La app escribe la selecciÃ³n
  // (quÃ© choferes, quÃ© franja) en Firestore y el bot la lee en vivo.
  static const String adminCachatoreHub = '/admin_cachatore';

  // AuditorÃ­as
  static const String vencimientosChoferes = '/vencimientos_choferes';
  static const String vencimientosChasis = '/vencimientos_chasis';
  static const String vencimientosAcoplados = '/vencimientos_acoplados';
  static const String vencimientosCalendario = '/vencimientos_calendario';
}

class AppTexts {
  AppTexts._();

  /// Nombre comercial de la app â€” visible al usuario en AppBars,
  /// splash, login, dialogs. Si Vecchi cambia el branding, este es
  /// el Ãºnico string a tocar para todo el cliente Flutter (los strings
  /// duplicados en UI especÃ­fica deberÃ­an referirse a `AppTexts.appName`).
  static const String appName = 'Coopertrans MÃ³vil';

  /// SubtÃ­tulo bajo el logo en login/splash.
  static const String tagline = 'GESTIÃ“N DE FLOTA Â· COOPERTRANS';

  static const String rutaNoEncontrada = 'Ruta no encontrada';
  // PodÃ©s mantener un registro visual de tu versiÃ³n acÃ¡
  static const String appVersion = 'v 1.2.15';
}

// ===========================================================================
// âœ… MEJORA PRO: CENTRALIZACIÃ“N DE COLECCIONES Y ROLES (Sin "Magic Strings")
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
  /// scheduled function `volvoAlertasPoller` cada 5 min â€” el admin
  /// los marca como atendidos desde el tablero.
  static const String volvoAlertas = 'VOLVO_ALERTAS';

  /// Ãšltima posiciÃ³n conocida de cada unidad de la flota segÃºn Sitrack.
  /// Doc id = patente. Se reemplaza completo en cada poll (no es
  /// histÃ³rico, es un snapshot). La popula `sitrackPosicionPoller`
  /// cada 5 min llamando al endpoint `/v2/report` de Sitrack.
  /// Toda la flota (55 tractores hoy) estÃ¡ en Sitrack â€” incluye
  /// tambiÃ©n unidades sin Volvo Connect, asÃ­ que es la mejor fuente
  /// para "dÃ³nde estÃ¡ cada tractor ahora".
  static const String sitrackPosiciones = 'SITRACK_POSICIONES';

  /// Registro temporal inmutable de asignaciones choferâ†”vehÃ­culo.
  /// Cada doc: `{vehiculo_id, chofer_dni, desde, hasta, ...}`. La
  /// asignaciÃ³n activa tiene `hasta == null`. Permite responder
  /// "Â¿quiÃ©n manejaba la patente X el dÃ­a Y?" sin importar cuÃ¡ntas
  /// veces rotÃ³ despuÃ©s. Ãšnico punto de escritura:
  /// `AsignacionVehiculoService`.
  static const String asignacionesVehiculo = 'ASIGNACIONES_VEHICULO';

  /// Registro temporal inmutable de asignaciones tractorâ†”enganche.
  /// Cada doc: `{enganche_id, tractor_id, desde, hasta, ...}`. La
  /// asignaciÃ³n activa tiene `hasta == null`. Permite calcular cuÃ¡ntos
  /// km recorriÃ³ una cubierta de enganche cruzando con
  /// `TELEMETRIA_HISTORICO` los km de cada tractor durante su perÃ­odo.
  /// Ãšnico punto de escritura: `AsignacionEngancheService`.
  static const String asignacionesEnganche = 'ASIGNACIONES_ENGANCHE';

  /// Mutex de OPERACIÃ“N para los cambios de asignaciÃ³n (NO es estado: existe
  /// solo MIENTRAS corre `cambiarAsignacion`). Doc id `vehiculo_<id>` /
  /// `chofer_<dni>` / `enganche_<id>` / `tractor_<id>`. Create-only (rule
  /// `update: if false`): si dos cambios concurrentes tocan el mismo recurso,
  /// el 2do rebota â†’ no quedan 2 asignaciones activas (auditorÃ­a 2026-06). Se
  /// borra al terminar; `expira_en` (~2 min) limpia el huÃ©rfano si el proceso
  /// crashea entremedio.
  static const String asignacionesLocks = 'ASIGNACIONES_LOCKS';

  // â”€â”€â”€ MÃ³dulo GomerÃ­a (2026-05-04) â”€â”€â”€
  /// Marcas de cubiertas. Doc: `{nombre, activo}`. ABM desde la app
  /// por ADMIN. Soft-delete (campo `activo`) para no romper referencias
  /// histÃ³ricas si se "borra" una marca que ya tiene cubiertas asociadas.
  static const String cubiertasMarcas = 'CUBIERTAS_MARCAS';

  /// Modelos de cubiertas (combinaciÃ³n marca + modelo + medida + tipo_uso).
  /// Doc: `{marca_id, marca_nombre (snapshot), modelo, medida, tipo_uso,
  /// km_vida_estimada_nueva, km_vida_estimada_recapada, recapable, activo}`.
  /// El `tipo_uso` (DIRECCION | TRACCION) determina en quÃ© posiciones
  /// se puede instalar la cubierta.
  static const String cubiertasModelos = 'CUBIERTAS_MODELOS';

  // El sistema VIEJO serializado (CUBIERTAS / CUBIERTAS_INSTALADAS /
  // CUBIERTAS_RECAPADOS / CUBIERTAS_CONTROLES / CUBIERTAS_KM_PENDIENTES / los
  // locks CUBIERTAS_POSICIONES_ACTIVAS + CUBIERTAS_ACTIVAS / CUBIERTAS_PROVEEDORES)
  // se BORRÃ“ el 2026-06-05 (cÃ³digo + datos). El catÃ¡logo CUBIERTAS_MARCAS /
  // CUBIERTAS_MODELOS (arriba) lo sigue usando el sistema nuevo (V2).

  // â”€â”€â”€ RediseÃ±o gomerÃ­a 2026-05-29 (modelo por posiciÃ³n+km+marca) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Sistema NUEVO, coexiste con el viejo hasta migrar. No serializa cubiertas.

  /// Montaje de una cubierta (modelo+vida) en una posiciÃ³n durante un
  /// perÃ­odo. Reemplaza CUBIERTAS_INSTALADAS sin serializar la cubierta.
  /// Activo: `hasta == null`. Ver modelo `Montaje`.
  static const String gomeriaMontajes = 'GOMERIA_MONTAJES';

  /// Log de movimientos de stock del depÃ³sito (compra/montaje/retiro/
  /// recapado/descarte/ajuste). Stock actual = suma de `delta` por SKU
  /// (modelo+vida). Ver modelo `StockMovimiento`.
  static const String gomeriaStockMovimientos = 'GOMERIA_STOCK_MOVIMIENTOS';

  /// Conteos de inventario "a ciegas" de gomerÃ­a: el operador (rol GOMERIA)
  /// reporta cuÃ¡ntas cubiertas ve por modelo (nuevas/recapadas) SIN ver el
  /// stock teÃ³rico; el admin compara contra el sistema. NO ajusta solo. Ver
  /// modelo `ConteoGomeria` (pedido Santiago 2026-06-05).
  static const String gomeriaConteos = 'GOMERIA_CONTEOS';

  /// Lock de unicidad de posiciÃ³n (1 montaje activo por posiciÃ³n). DocId
  /// `{unidad}__{posicion}`. Rule `allow update: if false` da la unicidad
  /// sin runTransaction (prohibido en Windows). Existe sii la posiciÃ³n
  /// estÃ¡ ocupada por un montaje activo.
  static const String gomeriaPosicionesActivas = 'GOMERIA_POSICIONES_ACTIVAS';

  /// Lock de idempotencia del RETIRO de un montaje. DocId = `{montajeId}`.
  /// Mismo patrÃ³n que el lock de posiciÃ³n (rule `allow update: if false`): el
  /// primer retiro crea el doc y emite el movimiento de stock; un segundo
  /// retiro concurrente (doble-tap / 2 tablets) choca con el lock y NO vuelve
  /// a sumar al stock â€” evita el +1 fantasma sin runTransaction (prohibido en
  /// Windows). Se crea una sola vez por montaje y no se borra (queda como
  /// traza de que ese montaje ya fue cerrado).
  static const String gomeriaRetirosLock = 'GOMERIA_RETIROS_LOCK';

  /// ColecciÃ³n de configs / cursores internos del backend (Volvo poller
  /// cursor, contadores como `cubiertas_counter`, etc.). Acceso
  /// restringido â€” la mayorÃ­a de docs solo los toca el server vÃ­a Admin
  /// SDK; algunos (como `cubiertas_counter`) los actualiza el cliente
  /// dentro de transactions de servicios especÃ­ficos.
  static const String meta = 'META';

  /// Scores diarios de eco-driving (Volvo Group Scores API v2.0.2).
  /// La popula la scheduled function `volvoScoresPoller` (1x por dÃ­a
  /// a las 04:00 ART). DocId: `{patente}_{YYYY-MM-DD}` para vehÃ­culos,
  /// `_FLEET_{YYYY-MM-DD}` para el agregado de flota. Cada doc tiene
  /// score total 0-100 + 17+ sub-scores (anticipation, braking, idling,
  /// etc.) + mÃ©tricas operativas crudas (km, combustible, CO2).
  static const String volvoScoresDiarios = 'VOLVO_SCORES_DIARIOS';

  // â”€â”€â”€ MÃ³dulo LogÃ­stica (2026-05-07) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // CatÃ¡logos para preparar el futuro planeamiento de viajes. Hoy son
  // ABMs simples; maÃ±ana van a ser el backbone de:
  //   - AsignaciÃ³n chofer + vehÃ­culo + tarifa
  //   - CÃ¡lculo de margen (tarifa_real âˆ’ tarifa_chofer âˆ’ combustible)
  //   - Reportes por dador / cliente / ruta
  //   - HistÃ³rico de quÃ© cargas hizo Vecchi para predecir capacidad
  //
  // Todas las colecciones usan soft-delete (campo `activa: bool`) â€” se
  // requiere mantener visibles las histÃ³ricas para reportes pasados.

  /// Empresas con las que Vecchi opera. Doc:
  /// `{nombre, tipo (CLIENTE | DADOR_TRANSPORTE), cuit, contacto, activa,
  /// creado_en, creado_por}`. Las empresas pueden ser:
  ///   - CLIENTE: empresa origen o destino del viaje (silo, planta,
  ///     puerto, fÃ¡brica) que paga el flete o lo recibe.
  ///   - DADOR_TRANSPORTE: otra empresa de transporte que tenÃ­a la carga
  ///     asignada y nos la cede; ellos cobran un % del flete (variable
  ///     por carga, se carga en TARIFAS_LOGISTICA).
  static const String empresasLogistica = 'EMPRESAS_LOGISTICA';

  /// Ubicaciones fÃ­sicas (puntos de carga / descarga). Doc:
  /// `{nombre, localidad, provincia, direccion, lat, lng, activa,
  /// creado_en, creado_por}`. Reusable: una misma ubicaciÃ³n puede ser
  /// origen de una tarifa y destino de otra. `lat/lng` opcionales para
  /// el futuro mapa de planeamiento.
  static const String ubicacionesLogistica = 'UBICACIONES_LOGISTICA';

  /// Tarifas de viaje â€” el corazÃ³n del mÃ³dulo. Cada doc es una "ruta
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
  /// (`activa=false`) y se crea una nueva con `vigente_desde=now`. AsÃ­
  /// los reportes histÃ³ricos siguen mostrando el precio que aplicaba.
  static const String tarifasLogistica = 'TARIFAS_LOGISTICA';

  /// Viajes â€” ejecuciÃ³n y liquidaciÃ³n. 1 doc por viaje real (carga â†’
  /// descarga). Refiere a `tarifasLogistica` (con snapshot de los
  /// precios al momento del viaje, para que cambios futuros no
  /// rompan reportes histÃ³ricos). Incluye:
  ///   - Datos de la operaciÃ³n: chofer, vehÃ­culo, fechas carga/descarga.
  ///   - CÃ¡lculos: monto Vecchi, monto chofer (sin redondeo y
  ///     redondeado a mÃºltiplo de 5), comisiÃ³n chofer (18% default).
  ///   - Adelanto al chofer (monto + fecha + observaciÃ³n).
  ///   - Gastos extraordinarios reembolsables al chofer (peajes,
  ///     combustible, comida) â€” suman a la liquidaciÃ³n final.
  ///   - Estado: PROGRAMADO / EN_CURSO / COMPLETADO / CANCELADO /
  ///     POSTERGADO. Soft-delete con `activo: false`.
  ///   - Comprobante de remito firmado en Storage (al cargar descarga).
  /// RBAC: admin + supervisor. NO se expone al chofer (decisiÃ³n
  /// Santiago 2026-05-09 â€” info delicada como tarifas, comisiones,
  /// liquidaciones).
  static const String viajesLogistica = 'VIAJES_LOGISTICA';

  /// Adelantos al chofer â€” montos entregados en mano para cubrir gastos
  /// del viaje O adelantos de sueldo (decisiÃ³n Santiago 2026-05-13:
  /// muchos adelantos NO estÃ¡n atados a un viaje especÃ­fico). Cada doc
  /// tiene chofer + fecha + monto + observaciÃ³n + correlativo del
  /// comprobante impreso. Campo opcional `viaje_id` por si el operador
  /// quiere vincularlo a un viaje (no obligatorio).
  ///
  /// Antes vivÃ­an como subcampos del viaje (adelanto_monto, adelanto_fecha,
  /// adelanto_observacion, numero_recibo_adelanto). Migrados a colecciÃ³n
  /// propia para soportar adelantos sin viaje. La pantalla LIQUIDACIÃ“N
  /// suma los adelantos del chofer en el rango (no del viaje especÃ­fico).
  ///
  /// La numeraciÃ³n del comprobante sigue compartiendo el counter
  /// `COUNTERS/recibos_adelanto.next` (misma serie fÃ­sica). Se asigna al
  /// PRIMER imprimir, no al crear, para no quemar correlativos en
  /// adelantos borrados sin imprimir.
  static const String adelantosChofer = 'ADELANTOS_CHOFER';

  /// Vacaciones del personal (mÃ³dulo AdministraciÃ³n). Un doc por empleado/aÃ±o
  /// devengado, id determinÃ­stico `<anio>_<dni>` (ej. `2025_31584396`).
  /// Guarda los dÃ­as que corresponden (autocalculados por antigÃ¼edad LCT,
  /// con override) + los perÃ­odos de goce (inicio/fin). `tomados` y `restan`
  /// se derivan. Referencia al legajo por DNI; identidad vive en EMPLEADOS.
  static const String vacaciones = 'VACACIONES';

  /// Reclamos de choferes (mÃ³dulo AdministraciÃ³n). Los crea SOLO el bot de
  /// WhatsApp (tool `reportar_discrepancia`) cuando un chofer insiste en que un
  /// dato no le coincide. La app los LEE y marca revisado (cierto/no_cierto);
  /// NO modifica el dato reclamado â€” la verdad la define la telemetrÃ­a/GPS.
  static const String reportesDiscrepancia = 'REPORTES_DISCREPANCIA';

  /// Contadores atÃ³micos para correlativos que requieren orden estricto
  /// (sin gaps, sin duplicados). Cada doc representa un correlativo
  /// independiente â€” `COUNTERS/recibos_adelanto.next` para el nÃºmero
  /// del comprobante de adelanto que se imprime al chofer.
  ///
  /// Se incrementa en transacciÃ³n Firestore (lectura + escritura
  /// atÃ³mica) â€” garantiza que dos impresiones simultÃ¡neas no obtengan
  /// el mismo nÃºmero. El nÃºmero se asigna al momento del PRIMER
  /// imprimir, no al crear el viaje, para no quemar correlativos en
  /// viajes que se borran sin imprimir comprobante.
  static const String counters = 'COUNTERS';

  // â”€â”€â”€ Empresas empleadoras (2026-05-08) â”€â”€â”€
  /// Empresas que figuran como empleador del personal (Vecchi Ariel y
  /// Vecchi Graciela S.R.L. + SucesiÃ³n de Vecchi Carlos Luis + El Mundo
  /// del Repuesto). Doc id:
  /// CUIT (formato `XX-XXXXXXXX-X`). Cada doc guarda los documentos
  /// laborales que son COMUNES a todos los empleados de esa empresa
  /// (PÃ³liza ART + Formulario 931). El empleado los ve read-only desde
  /// MIS VENCIMIENTOS; el admin los actualiza una vez por empresa y
  /// queda reflejado en todos los empleados que figuran ahÃ­.
  ///
  /// Por quÃ© docId = CUIT (y no slug del nombre): es estable, Ãºnico, y
  /// sale parseable directo del campo `EMPRESA` que ya guardamos en
  /// EMPLEADOS (formato `'NOMBRE: (CUIT)'`).
  static const String empresasEmpleadoras = 'EMPRESAS_EMPLEADORAS';

  // â”€â”€â”€ MÃ³dulo Cachatore (2026-05-20) â”€â”€â”€
  // Control del bot que reserva/reagenda turnos de carga YPF en iTurnos
  // (vive 24/7 en la PC dedicada â€” proyecto `cachatore/`). La app escribe
  // la selecciÃ³n; el bot (Python, Admin SDK) la lee y devuelve el estado.

  /// Config global del bot. Doc Ãºnico `global`:
  /// `{activo (interruptor maestro), fecha (null|'hoy'|'manana'|'AAAA-MM-DD'),
  /// hora_inicio ('HH:MM' = hora del drop), duracion_min, poll_latente_seg,
  /// actualizado_en, actualizado_por_dni}`.
  static const String cachatoreConfig = 'CACHATORE_CONFIG';

  /// Choferes que el bot debe vigilar. DocId = DNI. La app escribe
  /// `{dni, nombre, franja (madrugada|manana|tarde|noche), reagendar (bool),
  /// activo (bool), creado_*/actualizado_*}`. El bot escribe de vuelta el
  /// estado en vivo: `{estado (buscando|reservado|reagendado|login_fallo|...),
  /// estado_hora (HH:MM del turno), estado_detalle, estado_en}`.
  static const String cachatoreObjetivos = 'CACHATORE_OBJETIVOS';

  /// Latido/estado del bot. Doc Ãºnico `bot`: `{modo (idle|latente|agresivo|
  /// pausado), total, pendientes, ultimo_tick_en}`. Lo escribe SOLO el bot
  /// (Admin SDK) â€” la app lo lee para mostrar si estÃ¡ vivo y quÃ© hace.
  static const String cachatoreEstado = 'CACHATORE_ESTADO';

  /// Turnos REALES que tiene cada chofer en iTurnos (los saque o no el bot,
  /// incluso si se cargaron por fuera). DocId = DNI. Lo popula el bot
  /// escaneando `mis_turnos` de TODOS los choferes (no solo los vigilados):
  /// `{dni, nombre, cuando (texto legible), hora, uuid, actualizado_en}`.
  /// La pantalla "Turnos concretados" lee de acÃ¡. Si un chofer no tiene turno,
  /// el bot borra su doc. Solo lo escribe el bot (Admin SDK).
  static const String cachatoreTurnos = 'CACHATORE_TURNOS';

  // â”€â”€â”€ HistÃ³rico real de iButtons (2026-05-23) â”€â”€â”€
  /// Tramos continuos de iButton por patente, reconstruidos desde
  /// SITRACK_EVENTOS por la CF `reconstruirHistoricoIButtonsDiario` (cron
  /// 06:00 ART procesando el dÃ­a anterior). DocId determinÃ­stico:
  /// `{patente}_{chofer_dni}_{desde_ms}`. Cada doc representa un tramo
  /// donde el MISMO iButton estuvo en la MISMA patente sin gaps >30 min.
  ///
  /// Schema: `{patente, chofer_dni, chofer_nombre, desde (Timestamp),
  /// hasta (Timestamp), duracion_min, eventos_count, procesado_en}`.
  ///
  /// Uso: pantalla "AuditorÃ­a asignaciones" cruza estos tramos REALES
  /// (lo que fÃ­sicamente reportÃ³ Sitrack vÃ­a iButton) contra
  /// ASIGNACIONES_VEHICULO (lo que el sistema dice que pasÃ³). Las
  /// discrepancias se marcan en la UI â€” Ãºtil para multas tardÃ­as,
  /// investigaciones y reconciliaciÃ³n de asignaciones cargadas mal.
  static const String sitrackIButtonsHistorico = 'SITRACK_IBUTTONS_HISTORICO';

  /// HistÃ³rico de jornadas reconstruidas desde SITRACK_EVENTOS.
  /// DocId determinÃ­stico `{dni}_{YYYY-MM-DD}`. La produce la CF
  /// `reconstruirJornadasDiario` (cron 06:30 ART) y la consume la
  /// pantalla "Jornada" del hub ICM con grÃ¡fico velocidad/tiempo,
  /// tramos de manejo y paradas clasificadas (â‰¥15 min para corte de
  /// bloque, â‰¥8h para fin de jornada).
  static const String volvoJornadasHistorico = 'VOLVO_JORNADAS_HISTORICO';

  /// Registro de jornada v3 (a posteriori, por SEÃ‘ALES Sitrack). Lo escribe
  /// la CF `registrarJornadasV3Diario` (cron 06:45 ART). DocId
  /// `{dni}_{YYYY-MM-DD}_{HHMM}` (Ãºnico por turno). Lo lee la pantalla
  /// "Mi jornada" del chofer (su propio registro: turno, manejo neto, pausas
  /// con motivo, recorrido, confianza, descanso insuficiente). Distinto del
  /// histÃ³rico de arriba (speed-based, hub ICM): este usa Contacto OFF/ON +
  /// detenido + corroboraciÃ³n por distancia. Ver functions/src/jornadas_v3*.
  static const String registroJornadas = 'REGISTRO_JORNADAS';

  /// Doc dentro de `META` con map { key: dni } editable desde la app
  /// (pantalla "Destinatarios de notificaciÃ³n") para cambiar a quiÃ©n le
  /// llegan los 9 resÃºmenes/avisos sin redeploy. Cambio M5 2026-05-24.
  static const String metaDestinatariosNotificacion =
      'destinatarios_notificacion';

  // â”€â”€â”€ MÃ³dulo Zonas de Descarga (2026-05-23) â”€â”€â”€
  /// Zonas geogrÃ¡ficas configurables (polÃ­gono o cÃ­rculo) que marcan
  /// lugares de descarga relevantes (YPF AÃ±elo, plantas cliente, etc).
  /// DocId = slug derivado del nombre. El operador admin las crea/edita
  /// desde la pantalla "Zonas de descarga". La CF `zonaDescargaPoller`
  /// las lee cada 5 min y, cruzando con `SITRACK_POSICIONES`, mantiene
  /// la cola en vivo (`zonaDescargaCola`) y el histÃ³rico de descargas
  /// completadas (`zonaDescargaHistorico`). Reemplaza la detecciÃ³n por
  /// PTO de Volvo (que cubrÃ­a solo flota Volvo y daba falsos positivos).
  static const String zonasDescarga = 'ZONAS_DESCARGA';

  /// Cola en vivo de unidades dentro de una zona. DocId compuesto:
  /// `{patente}_{slug_zona}`. Existe MIENTRAS la unidad estÃ© dentro y
  /// cumpla la estadÃ­a mÃ­nima. Al salir, el doc se mueve a
  /// `zonaDescargaHistorico` y se borra de acÃ¡.
  /// Schema: `{patente, slug_zona, chofer_dni, chofer_nombre,
  /// entrada_ts, ultima_pos_ts, ultimo_lat, ultimo_lng}`.
  /// Solo lo escribe la CF (Admin SDK). Lectura: admin/supervisor.
  static const String zonaDescargaCola = 'ZONA_DESCARGA_COLA';

  /// HistÃ³rico inmutable de descargas completadas. DocId:
  /// `{slug_zona}_{patente}_{entrada_ts_ms}`. Cada doc representa una
  /// estadÃ­a completa en la zona: entrada, salida, duraciÃ³n. Base para
  /// KPIs (tiempo promedio de descarga, ranking choferes) y reporte
  /// Excel mensual. Append-only. Solo escribe la CF.
  static const String zonaDescargaHistorico = 'ZONA_DESCARGA_HISTORICO';

  /// Pedidos one-shot del operador para verificar si un chofer (que NO estÃ¡
  /// en CACHATORE_OBJETIVOS) tiene un turno preexistente sacado por la web
  /// de iTurnos. DocId = DNI. Caso real: un compaÃ±ero del chofer saca turno
  /// sin pasar por el bot â€” sin esto, el operador no podÃ­a reagendar/cancelar
  /// ese turno desde la app porque no aparecÃ­a en ningÃºn lado.
  ///
  /// La app escribe `{dni, nombre, pedido_en, pedido_por_dni}` al tappear
  /// "Verificar" en el wizard Agregar. El bot (vigia.py) procesa cada doc
  /// en su loop principal: hace login + mis_turnos one-shot a iTurnos y
  /// escribe el resultado de vuelta:
  ///   - `con_turno` + detalle (texto del turno): el bot publicÃ³ el TURNO
  ///     en CACHATORE_TURNOS y creÃ³ el OBJETIVO marcÃ¡ndolo como
  ///     `origen='detectado_externo'` para que los botones Reagendar/
  ///     Cancelar funcionen.
  ///   - `sin_turno`: el chofer no tiene turnos preexistentes.
  ///   - `error` + detalle (motivo): no pudo loguear, sin mail/clave, etc.
  ///
  /// Vida corta: tras leer el resultado la app borra el doc; si no llega a
  /// borrarlo, el bot lo limpia tras 120 s (CHEQUEO_TTL_SEG en vigia.py).
  static const String cachatoreChequeos = 'CACHATORE_CHEQUEOS';
}

/// Documentos laborales que viven a NIVEL EMPRESA (no por empleado).
/// Estos son comunes a todos los empleados de la misma empresa:
/// PÃ³liza ART, Formulario 931, Seguro Colectivo de Vida Obligatorio y
/// el comprobante de pago de cuota sindical los emite/paga la empresa,
/// no cada empleado.
///
/// Guardados en `EMPRESAS_EMPLEADORAS/{cuit}` con la misma convenciÃ³n
/// de campos que los docs de empleado: `VENCIMIENTO_<sufijo>` para la
/// fecha y `ARCHIVO_<sufijo>` para la URL del PDF en Storage.
///
/// Nota sobre `etiqueta...Admin` vs `etiqueta...Chofer`: SCVO se
/// muestra al admin con el nombre tÃ©cnico (lo identifica el RR.HH. /
/// estudio contable) pero al chofer con el nombre coloquial ("Seguro
/// de Vida", que es como lo conocen). Para los demÃ¡s docs ambas
/// etiquetas coinciden.
class AppDocsEmpresa {
  AppDocsEmpresa._();

  static const String etiquetaPolizaArt = 'PÃ³liza ART';
  static const String sufijoPolizaArt = 'POLIZA_ART';
  static const String campoFechaPolizaArt = 'VENCIMIENTO_POLIZA_ART';
  static const String campoArchivoPolizaArt = 'ARCHIVO_POLIZA_ART';

  static const String etiquetaForm931 = 'Formulario 931';
  static const String sufijoForm931 = 'FORMULARIO_931';
  static const String campoFechaForm931 = 'VENCIMIENTO_FORMULARIO_931';
  static const String campoArchivoForm931 = 'ARCHIVO_FORMULARIO_931';

  /// Seguro Colectivo de Vida Obligatorio (mismo doc, distinto label
  /// segÃºn el contexto â€” admin lo ve "SCVO", chofer "Seguro de Vida").
  static const String etiquetaScvoAdmin = 'SCVO';
  static const String etiquetaScvoChofer = 'Seguro de Vida';
  static const String sufijoScvo = 'SCVO';
  static const String campoFechaScvo = 'VENCIMIENTO_SCVO';
  static const String campoArchivoScvo = 'ARCHIVO_SCVO';

  /// Certificado de libre deuda sindical (sindicato Camioneros u otro)
  /// â€” emitido a la empresa, mismo papel para todos los empleados de
  /// esa razÃ³n social. Mismo label en ambos contextos. Reusamos el
  /// sufijo legacy `LIBRE_DE_DEUDA_SINDICAL` que ya estaba en
  /// `AppDocsEmpleado.etiquetas` antes de la migraciÃ³n a empresa.
  static const String etiquetaLibreDeudaSindical = 'Libre de deuda sindical';
  static const String sufijoLibreDeudaSindical = 'LIBRE_DE_DEUDA_SINDICAL';
  static const String campoFechaLibreDeudaSindical =
      'VENCIMIENTO_LIBRE_DE_DEUDA_SINDICAL';
  static const String campoArchivoLibreDeudaSindical =
      'ARCHIVO_LIBRE_DE_DEUDA_SINDICAL';
}

/// CatÃ¡logo hardcoded de las 3 empresas empleadoras de Vecchi (2026-05-08;
/// +El Mundo del Repuesto el 2026-05-30).
///
/// El campo `EMPRESA` en EMPLEADOS guarda el string "completo"
/// (`'NOMBRE: (CUIT)'`) para mantener la UX del dropdown como estaba.
/// Para resolver de empleado a doc de empresa usamos el CUIT extraÃ­do
/// con [cuitDeStringEmpresa] como docId en EMPRESAS_EMPLEADORAS.
///
/// Si Vecchi suma otra empresa empleadora, agregar acÃ¡ +
/// seedear el doc desde la pantalla admin.
class AppEmpresasEmpleadoras {
  AppEmpresasEmpleadoras._();

  /// Vecchi Ariel y Vecchi Graciela S.R.L.
  static const String cuitVecchiAriel = '30-70910015-3';

  /// SucesiÃ³n de Vecchi Carlos Luis.
  static const String cuitVecchiCarlos = '20-08569424-4';

  /// El Mundo del Repuesto (alta 2026-05-30).
  static const String cuitMundoRepuesto = '30-70862998-3';

  /// CatÃ¡logo (orden estable: el dropdown del form de personal usa
  /// estos mismos labels). Si cambiÃ¡s un label acÃ¡, no afecta la
  /// resoluciÃ³n a doc de empresa porque va por CUIT.
  static const List<EmpresaEmpleadoraInfo> catalogo = [
    EmpresaEmpleadoraInfo(
      cuit: cuitVecchiAriel,
      label: 'VECCHI ARIEL Y VECCHI GRACIELA S.R.L: ($cuitVecchiAriel)',
      nombre: 'Vecchi Ariel y Vecchi Graciela S.R.L.',
    ),
    EmpresaEmpleadoraInfo(
      cuit: cuitVecchiCarlos,
      label: 'SUCESION DE VECCHI CARLOS LUIS: ($cuitVecchiCarlos)',
      nombre: 'SucesiÃ³n de Vecchi Carlos Luis',
    ),
    EmpresaEmpleadoraInfo(
      cuit: cuitMundoRepuesto,
      label: 'EL MUNDO DEL REPUESTO: ($cuitMundoRepuesto)',
      nombre: 'El Mundo del Repuesto',
    ),
  ];

  /// Extrae el CUIT del string `EMPRESA` que se guarda en cada doc de
  /// EMPLEADOS â€” formato esperado: `'NOMBRE: (XX-XXXXXXXX-X)'`.
  /// Devuelve `null` si no matchea (empleado sin empresa, o empresa
  /// vieja sin CUIT). Robusto a parÃ©ntesis sobrantes y a acentos.
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

/// Info estÃ¡tica de una empresa empleadora (CUIT + label visible).
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

  // â”€â”€â”€ Roles del sistema (definen QUÃ‰ puede hacer cada usuario) â”€â”€â”€
  // 6 roles. Los 4 base + 2 especializados:
  //
  //   CHOFER       â€” empleado de manejo con vehÃ­culo asignado.
  //                  Ve sus vencimientos personales + su unidad.
  //   PLANTA       â€” empleado sin vehÃ­culo (planta, taller, gomerÃ­a,
  //                  administraciÃ³n). Solo ve sus vencimientos
  //                  personales. NO ve "Mi unidad".
  //   GOMERIA      â€” gomero/encargado de cubiertas. Ve y opera SOLO
  //                  el mÃ³dulo GomerÃ­a (stock, instalaciÃ³n, recapados).
  //                  No accede al resto del panel admin.
  //   SEG_HIGIENE  â€” Seguridad e Higiene. Ve los tableros Volvo
  //                  (alertas, eco-driving, descargas PTO, mapa) para
  //                  monitorear conducta y eventos de la flota. No
  //                  edita personal, flota ni opera el bot.
  //   SUPERVISOR   â€” mando medio. Gestiona personal + flota +
  //                  vencimientos + revisiones + bot. NO puede
  //                  crear/borrar admins ni cambiar roles de otros.
  //   ADMIN        â€” control total. Crea admins, cambia roles, audita.
  //
  // Compatibilidad: 'USUARIO' es el rol legacy que tenÃ­an los choferes
  // antes de la migraciÃ³n a 4 roles. Se mantiene como alias hasta que
  // el script de migraciÃ³n los pase todos a CHOFER.
  static const String chofer = 'CHOFER';
  static const String planta = 'PLANTA';
  static const String gomeria = 'GOMERIA';
  static const String segHigiene = 'SEG_HIGIENE';
  static const String supervisor = 'SUPERVISOR';
  static const String admin = 'ADMIN';

  /// Rol legacy. Tratar como CHOFER hasta que los datos viejos migren.
  static const String usuarioLegacy = 'USUARIO';

  /// Lista de todos los roles vÃ¡lidos (para validar entradas).
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
    gomeria: 'GomerÃ­a',
    segHigiene: 'Seguridad e Higiene',
    supervisor: 'Supervisor',
    admin: 'Admin',
  };

  /// `true` si este rol tiene vehÃ­culo/enganche asignable. Usado por
  /// el form para mostrar/ocultar los campos VEHICULO y ENGANCHE.
  static bool tieneVehiculo(String rol) =>
      rol == chofer || rol == usuarioLegacy;

  /// Normaliza el rol legacy (USUARIO â†’ CHOFER) para que el resto del
  /// cÃ³digo pueda asumir solo los 4 valores nuevos.
  static String normalizar(String? rol) {
    final r = (rol ?? '').toUpperCase();
    if (r == usuarioLegacy) return chofer;
    if (todos.contains(r)) return r;
    return chofer; // fallback conservador
  }
}

// ===========================================================================
// ÃREAS â€” DÃ³nde trabaja el empleado (info organizacional, no permisos)
// ===========================================================================
//
// Independiente del ROL. Un empleado puede ser SUPERVISOR + TALLER (jefe
// de taller) o PLANTA + GOMERIA (gomero) o ADMIN + ADMINISTRACION (vos).
//
// Esta lista la lee el dropdown del form de personal y los filtros de
// la lista. Si Vecchi suma un sector nuevo, se agrega acÃ¡ Ãºnicamente.

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
    administracion: 'AdministraciÃ³n',
    planta: 'Planta',
    taller: 'Taller',
    gomeria: 'GomerÃ­a',
  };

  /// Devuelve el Ã¡rea default sugerido segÃºn el rol elegido.
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
      case AppRoles.gomeria:
        return gomeria;
      case AppRoles.segHigiene:
        return administracion;
    }
    return manejo;
  }
}

// ===========================================================================
// TIPOS DE UNIDAD DE LA FLOTA
// ===========================================================================
//
// Centralizar acÃ¡ la lista evita el problema de "agreguÃ© un tipo nuevo
// pero me olvidÃ© de actualizarlo en el formulario / la lista / el filtro
// del chofer / el reporte de vencimientos". Cuando aparezca un tipo
// nuevo, sumalo solamente acÃ¡ y la app lo va a mostrar en todos lados.
class AppTiposVehiculo {
  AppTiposVehiculo._();

  /// Tractor / chasis (la unidad con motor que arrastra los enganches).
  static const String tractor = 'TRACTOR';

  /// Lista de tipos de enganche soportados por la app.
  ///
  /// `ACOPLADO` se mantiene al final por **retrocompatibilidad**: hay
  /// documentos viejos en Firestore con ese TIPO. No aparece como opciÃ³n
  /// en el formulario de alta para que no se carguen unidades nuevas con
  /// ese tipo, pero sÃ­ se incluye en filtros y queries para que las
  /// unidades histÃ³ricas se vean correctamente.
  static const List<String> enganches = [
    'BATEA',
    'TOLVA',
    'BIVUELCO',
    'TANQUE',
    'ACOPLADO',
  ];

  /// Tipos que se ofrecen como opciÃ³n en el formulario de alta de
  /// vehÃ­culos. Es la lista oficial de los que un admin puede crear.
  static const List<String> seleccionables = [
    'TRACTOR',
    'BATEA',
    'TOLVA',
    'BIVUELCO',
    'TANQUE',
  ];

  /// Etiqueta legible para mostrar en UI (plural). Usar para tÃ­tulos de
  /// secciones/listas que agrupan unidades por tipo.
  static const Map<String, String> pluralEtiquetas = {
    'TRACTOR': 'TRACTORES',
    'BATEA': 'BATEAS',
    'TOLVA': 'TOLVAS',
    'BIVUELCO': 'BIVUELCOS',
    'TANQUE': 'TANQUES',
    'ACOPLADO': 'ACOPLADOS',
  };

  /// Etiqueta singular en minÃºsculas para mensajes ("sin tractores
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
// prÃ³ximo service programado. Negativo = vencido.
//
// Para que el admin pueda anticipar turnos de taller, definimos 4
// umbrales en KM (NO metros):
//
//   > 5000 km  â†’  OK (verde)
//   â‰¤ 5000 km  â†’  Falta poco (amarillo claro / lime)
//   â‰¤ 2500 km  â†’  Programar (amarillo)
//   â‰¤ 1000 km  â†’  Urgente (naranja)
//   â‰¤ 0    km  â†’  Vencido (rojo)
//
// Cualquier ajuste a la curva de alarma se hace acÃ¡ â€” pantalla y badge
// leen estas constantes.
class AppMantenimiento {
  AppMantenimiento._();

  /// KM al prÃ³ximo service desde el cual el badge pasa a "Falta poco"
  /// (amarillo claro).
  static const double atencionKm = 5000;

  /// KM desde el cual ya hay que pedir turno al taller ("Programar").
  static const double programarKm = 2500;

  /// KM desde el cual la situaciÃ³n es urgente ("Servicio urgente").
  static const double urgenteKm = 1000;

  /// Intervalo entre services programados, en KM. Volvo aplica el plan
  /// estÃ¡ndar de 50.000 km a la flota Vecchi. Si en el futuro hay
  /// tractores con plan distinto, podrÃ­amos agregar un campo
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

  /// Calcula el KM al que se hizo el Ãºltimo service de un tractor.
  ///
  /// FÃ³rmula: `KM_ACTUAL + serviceDistance âˆ’ intervaloServiceKm`.
  ///
  /// Ejemplo: si un tractor tiene 380.000 km y `serviceDistance: 12.000`,
  /// el prÃ³ximo service es a 392.000 km y el Ãºltimo fue a 342.000 km.
  ///
  /// Devuelve null si falta alguno de los dos inputs (no hay manera de
  /// estimar sin ambos).
  static double? calcularKmUltimoService({
    required double? kmActual,
    required double? serviceDistanceKm,
  }) {
    if (kmActual == null || serviceDistanceKm == null) return null;
    final resultado = kmActual + serviceDistanceKm - intervaloServiceKm;
    // Si el cÃ¡lculo da negativo (tractor con menos de 50k km) significa
    // que todavÃ­a estÃ¡ en su primer ciclo de service, no tuvo "anterior".
    if (resultado < 0) return null;
    return resultado;
  }

  /// KM recorridos desde el Ãºltimo service. Ãštil para mostrar en la card
  /// "X km recorridos desde el Ãºltimo service".
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

  /// Calcula `serviceDistance` (KM al prÃ³ximo service) a partir del
  /// Ãºltimo service cargado manualmente y el odÃ³metro actual.
  ///
  /// FÃ³rmula: `(ULTIMO_SERVICE_KM + intervaloServiceKm) âˆ’ KM_ACTUAL`.
  ///
  /// Ãštil cuando la API de Volvo NO entrega `serviceDistance` para la
  /// cuenta (paquete API limitado). Caso real de Vecchi: el response
  /// `vehiclestatuses` no incluye el bloque `uptimeData` que contiene
  /// ese campo, asÃ­ que dependemos del dato manual + KM en vivo.
  ///
  /// Devuelve null si falta alguno de los inputs **o si los datos son
  /// inconsistentes** (ULTIMO_SERVICE_KM > KM_ACTUAL + tolerancia: el
  /// admin cargÃ³ algo claramente mal, ej. invirtiÃ³ dÃ­gitos). Puede ser
  /// **negativo** si el tractor ya pasÃ³ el momento del prÃ³ximo service
  /// (vencido).
  ///
  /// **Tolerancia 1 km**: el operador suele cargar el ULTIMO_SERVICE_KM
  /// redondeando hacia arriba (ej. cargÃ¡ "1.012.375" cuando el odÃ³metro
  /// real Volvo es "1.012.374,89"). Si no tolerÃ¡ramos ese redondeo, el
  /// helper retorna null y la card de mantenimiento aparece como
  /// "SIN DATOS" â€” caso real AD614JS auditoria 2026-05-18.
  static double? serviceDistanceDesdeManual({
    required double? ultimoServiceKm,
    required double? kmActual,
  }) {
    if (ultimoServiceKm == null || kmActual == null) return null;
    // Defensa contra typo del admin: el Ãºltimo service no puede haber
    // sido a mÃ¡s kilÃ³metros de los que tiene el tractor ahora. Tolerancia
    // de 1 km para absorber el redondeo natural del operador.
    if (ultimoServiceKm > kmActual + 1.0) return null;
    // Si el last_service estÃ¡ hasta 1 km por encima (redondeo), tratarlo
    // como "service reciÃ©n hecho" â†’ faltan exactamente intervaloServiceKm.
    // Sin esto, el delta darÃ­a negativo y la card cambiarÃ­a a "VENCIDO".
    if (ultimoServiceKm > kmActual) return intervaloServiceKm.toDouble();
    return (ultimoServiceKm + intervaloServiceKm) - kmActual;
  }
}

// =============================================================================
// SOFT-DELETE (alta/baja de empleados y vehÃ­culos)
// =============================================================================
//
// Sistema unificado para "dar de baja" sin borrar el doc de Firestore.
// Permite reactivar el registro mÃ¡s tarde si fue baja por error o si
// el chofer/vehÃ­culo vuelve. Aplica a EMPLEADOS y VEHICULOS.
//
// Convenciones:
//   - Campo `ACTIVO: bool` (mayÃºsculas, igual que el resto de campos
//     directos del doc). Default true: docs viejos sin el campo se
//     consideran activos por compat.
//   - Al dar de baja: ACTIVO=false + metadata + se desafectan todas
//     las asignaciones (vehÃ­culo, enganche) + se vacÃ­an los campos
//     de vencimientos y archivos (decisiÃ³n Santiago 2026-05-04: el
//     reactivar implica re-cargar desde cero, no preservar).
//   - Al reactivar: ACTIVO=true + metadata. Los vencimientos quedan
//     vacÃ­os hasta que el admin los cargue. La unidad NO se restaura
//     automÃ¡ticamente â€” se asume que pudo haber pasado a otro chofer.

class AppActivo {
  AppActivo._();

  /// Campo principal del flag de baja en EMPLEADOS y VEHICULOS.
  static const String campo = 'ACTIVO';

  /// Metadata de baja.
  static const String campoBajaEn = 'BAJA_EN';
  static const String campoBajaPorDni = 'BAJA_POR_DNI';
  static const String campoBajaMotivo = 'BAJA_MOTIVO';

  /// Metadata de reactivaciÃ³n.
  static const String campoReactivadoEn = 'REACTIVADO_EN';
  static const String campoReactivadoPorDni = 'REACTIVADO_POR_DNI';

  /// `true` si el doc NO estÃ¡ dado de baja. Acepta:
  ///   - ACTIVO=true â†’ true (alta explÃ­cita).
  ///   - ACTIVO=null/ausente â†’ true (default; doc viejo pre-soft-delete).
  ///   - ACTIVO=false â†’ false (baja).
  /// Aplicar a TODA query de EMPLEADOS/VEHICULOS que NO sea para gestiÃ³n
  /// especÃ­fica de bajas (ej. listas, reportes, KPIs, alertas, cron del
  /// bot, lookups del Cloud Functions).
  static bool esActivo(Map<String, dynamic> data) {
    final v = data[campo];
    return v != false; // null o true â†’ activo
  }
}

/// Estados del mantenimiento preventivo, ordenados por severidad.
/// El `index` se usa para sortear (menor Ã­ndice = mÃ¡s urgente).
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
