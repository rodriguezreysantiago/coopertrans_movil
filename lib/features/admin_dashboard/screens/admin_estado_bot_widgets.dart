// =============================================================================
// COMPONENTES VISUALES del dashboard "Estado del Bot" — extraídos para
// mantener navegable el screen principal. Comparten privacidad via `part of`.
// =============================================================================

part of 'admin_estado_bot_screen.dart';

// =============================================================================
// DASHBOARD
// =============================================================================

class _DashboardBot extends StatelessWidget {
  final Map<String, dynamic> data;
  const _DashboardBot({required this.data});

  @override
  Widget build(BuildContext context) {
    final estadoCliente = (data['estadoCliente'] ?? 'INICIANDO').toString();
    final ultimoHb = _toDate(data['ultimoHeartbeat']);
    final salud = _evaluarSalud(estadoCliente, ultimoHb);

    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      children: [
        _BannerEstado(salud: salud, estadoCliente: estadoCliente, ultimoHb: ultimoHb),
        const SizedBox(height: AppSpacing.lg),
        const _ToggleKillSwitch(),
        const SizedBox(height: AppSpacing.md),
        _CardCola(cola: (data['cola'] as Map?) ?? const {}),
        const SizedBox(height: AppSpacing.md),
        _CardMensajes(mensajes: (data['mensajes'] as Map?) ?? const {}),
        const SizedBox(height: AppSpacing.md),
        const _CardSparklineEnviados(),
        const SizedBox(height: AppSpacing.md),
        _CardCron(cron: (data['cron'] as Map?) ?? const {}),
        const SizedBox(height: AppSpacing.md),
        _CardConfig(config: (data['config'] as Map?) ?? const {}),
        const SizedBox(height: AppSpacing.md),
        _CardReglasNotificacion(
          reglas: (data['reglasNotificacion'] as Map?) ?? const {},
        ),
        const SizedBox(height: AppSpacing.md),
        _CardErroresRecientes(
          errores: (data['erroresRecientes'] as List?) ?? const [],
        ),
        const SizedBox(height: AppSpacing.md),
        _CardBotInfo(bot: (data['bot'] as Map?) ?? const {}),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

// =============================================================================
// BANNER DE ESTADO
// =============================================================================

enum _Salud { ok, advertencia, caido }

_Salud _evaluarSalud(String estadoCliente, DateTime? ultimoHb) {
  if (ultimoHb == null) return _Salud.caido;
  final segs = DateTime.now().difference(ultimoHb).inSeconds;
  // Si hace > 2 min que no hay heartbeat, lo damos por caído sin importar
  // qué dice el campo estadoCliente — el campo es snapshot del último
  // heartbeat, no del momento actual.
  if (segs > 120) return _Salud.caido;
  if (segs > 90) return _Salud.advertencia;
  switch (estadoCliente) {
    case 'LISTO':
      return _Salud.ok;
    case 'INICIANDO':
    case 'AUTH_PENDIENTE':
    case 'AUTENTICADO':
      return _Salud.advertencia;
    case 'DESCONECTADO':
    case 'AUTH_FALLO':
      return _Salud.caido;
  }
  return _Salud.advertencia;
}

class _BannerEstado extends StatelessWidget {
  final _Salud salud;
  final String estadoCliente;
  final DateTime? ultimoHb;
  const _BannerEstado({
    required this.salud,
    required this.estadoCliente,
    required this.ultimoHb,
  });

  @override
  Widget build(BuildContext context) {
    final color = switch (salud) {
      _Salud.ok => AppColors.success,
      _Salud.advertencia => AppColors.warning,
      _Salud.caido => AppColors.error,
    };
    final tituloPrincipal = switch (salud) {
      _Salud.ok => 'BOT OPERATIVO',
      _Salud.advertencia => 'BOT EN TRANSICIÓN',
      _Salud.caido => 'BOT NO RESPONDE',
    };
    final icono = switch (salud) {
      _Salud.ok => Icons.check_circle_outline,
      _Salud.advertencia => Icons.warning_amber_rounded,
      _Salud.caido => Icons.error_outline,
    };

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      borderColor: color.withAlpha(160),
      highlighted: salud != _Salud.ok,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: color, size: 32),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tituloPrincipal,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.heading.copyWith(
                        color: color,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Cliente WhatsApp: ${_etiquetarEstado(estadoCliente)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.label.copyWith(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: AppColors.borderSubtle,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Row(
              children: [
                const Icon(Icons.access_time,
                    color: AppColors.textTertiary, size: 14),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  ultimoHb == null
                      ? 'Sin heartbeat registrado'
                      : 'Último heartbeat: ${_hace(ultimoHb!)}',
                  style: AppType.label.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _etiquetarEstado(String e) {
    switch (e) {
      case 'LISTO':
        return 'Listo para enviar';
      case 'INICIANDO':
        return 'Iniciando…';
      case 'AUTH_PENDIENTE':
        return 'Esperando QR / login';
      case 'AUTENTICADO':
        return 'Autenticado, terminando setup…';
      case 'DESCONECTADO':
        return 'Desconectado';
      case 'AUTH_FALLO':
        return 'Falló la autenticación (escaneá QR de nuevo)';
    }
    return e;
  }
}

// =============================================================================
// CARDS DE DATOS
// =============================================================================

class _CardCola extends StatelessWidget {
  final Map cola;
  const _CardCola({required this.cola});

  @override
  Widget build(BuildContext context) {
    final pendientes = (cola['pendientes'] ?? 0) as int;
    final procesando = (cola['procesando'] ?? 0) as int;
    final error = (cola['error'] ?? 0) as int;
    final reintentando = (cola['reintentando'] ?? 0) as int;
    // Pendientes "frescos" = total pendientes - los que están en
    // espera de retry. Para que la UI no haga doble conteo.
    final pendientesFrescos =
        (pendientes - reintentando).clamp(0, pendientes);

    // Cada fila navega a la cola con el filtro precargado, así desde el
    // dashboard "tap en Con error: 3" llegás directo a esos 3 items.
    // El bot guarda los reintentos como estado PENDIENTE con
    // proximoIntentoEn — la cola hoy no distingue ese subset, así que
    // ambos ("Pendientes" y "Reintentando") deep-linkean a PENDIENTE.
    return _BloqueDatos(
      titulo: 'Cola de envío',
      icono: Icons.queue_outlined,
      mostrarChevron: true,
      filas: [
        _Fila('Pendientes', '$pendientesFrescos',
            color: pendientesFrescos > 0
                ? AppColors.warning
                : AppColors.textSecondary,
            onTap: () => _abrirCola(context, 'PENDIENTE')),
        _Fila('En proceso', '$procesando',
            onTap: () => _abrirCola(context, 'PROCESANDO')),
        _Fila('Reintentando', '$reintentando',
            color: reintentando > 0
                ? AppColors.warning
                : AppColors.textSecondary,
            onTap: () => _abrirCola(context, 'PENDIENTE')),
        _Fila('Con error', '$error',
            color: error > 0 ? AppColors.error : AppColors.textSecondary,
            onTap: () => _abrirCola(context, 'ERROR')),
      ],
    );
  }

  /// Empuja la cola con el estado preseleccionado. Se usa
  /// MaterialPageRoute (push directo) porque AdminWhatsAppColaScreen
  /// no está registrada en `app_router.dart`. Esa decisión fue
  /// deliberada para no obligar a tocar el router por un deep-link
  /// puntual; si más adelante hace falta una entrada formal, sumar
  /// AppRoutes.adminWhatsAppCola y mover esto a Navigator.pushNamed.
  void _abrirCola(BuildContext context, String estado) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AdminWhatsAppColaScreen(initialFilter: estado),
      ),
    );
  }
}

class _CardMensajes extends StatelessWidget {
  final Map mensajes;
  const _CardMensajes({required this.mensajes});

  @override
  Widget build(BuildContext context) {
    final hoy = (mensajes['enviadosHoy'] ?? 0) as int;
    final ultimo = _toDate(mensajes['ultimoEnviado']);
    // Breakdown publicado por el bot desde 2026-05-24 (M1). Si el bot
    // está en una versión vieja sin breakdown el map viene vacío y solo
    // mostramos el total — la pantalla degrada limpio.
    final porCat = (mensajes['enviadosHoyPorCategoria'] as Map?) ??
        const <String, dynamic>{};

    final filas = <_Fila>[
      _Fila('Enviados hoy', '$hoy', color: AppColors.success),
      _Fila('Último envío', ultimo == null ? 'Nunca' : _hace(ultimo)),
    ];
    // Solo mostramos las categorías con > 0 envíos para no llenar de "0".
    // El orden refleja "qué pesa más en la operación" (resúmenes y crons
    // diarios primero porque son los que vacían más cola en horario pico).
    const orden = [
      ('RESUMEN_DIARIO_08', 'Resúmenes 08:00'),
      ('CRON_BOT_60MIN', 'Crons del bot'),
      ('TIEMPO_REAL_CHOFER', 'Tiempo real al chofer'),
      ('CACHATORE', 'Cachatore'),
      ('SISTEMA', 'Sistema'),
      ('OTROS', 'Otros'),
    ];
    final breakdown = <_Fila>[];
    for (final t in orden) {
      final n = (porCat[t.$1] ?? 0) as int;
      if (n > 0) {
        breakdown.add(_Fila('  · ${t.$2}', '$n',
            color: t.$1 == 'OTROS'
                ? AppColors.warning
                : AppColors.textSecondary));
      }
    }
    if (breakdown.isNotEmpty) filas.addAll(breakdown);

    return _BloqueDatos(
      titulo: 'Mensajes',
      icono: Icons.mark_chat_read_outlined,
      filas: filas,
    );
  }
}

class _CardCron extends StatelessWidget {
  final Map cron;
  const _CardCron({required this.cron});

  @override
  Widget build(BuildContext context) {
    final ultimo = _toDate(cron['ultimoCiclo']);
    final proximo = _toDate(cron['proximoCicloAprox']);
    final stats = (cron['ultimoCicloStats'] as Map?) ?? const {};
    final intervalo = (cron['intervaloMinutos'] ?? 60) as int;

    final filas = <_Fila>[
      _Fila('Intervalo', '$intervalo min'),
      _Fila('Último ciclo', ultimo == null ? 'Nunca' : _hace(ultimo)),
      _Fila('Próximo aprox',
          proximo == null ? 'Sin estimar' : _hace(proximo, futuro: true)),
    ];
    if (stats.isNotEmpty) {
      filas.add(_Fila('Encolados', '${stats['encolados'] ?? 0}'));
      filas.add(_Fila('Salteados (idempotencia)', '${stats['salteados'] ?? 0}'));
      final err = (stats['errores'] ?? 0) as int;
      filas.add(_Fila('Errores', '$err',
          color: err > 0 ? AppColors.error : AppColors.textSecondary));
    }

    return _BloqueDatos(
      titulo: 'Cron de avisos automáticos',
      icono: Icons.schedule,
      filas: filas,
    );
  }
}

/// Card "Reglas de notificación" — muestra QUIÉN recibe QUÉ tipo de
/// mensaje. Lee del subdoc `reglasNotificacion` que el bot publica en
/// cada heartbeat (env vars + lógica de cron).
///
/// Para destinatarios DNI, resuelve el nombre vía sub-stream a
/// EMPLEADOS para mostrar "29.820.141 — Santiago Rodríguez" en vez del
/// número crudo. Si el DNI no existe / no tiene registro, cae a "DNI: X".
///
/// Edición: las reglas hoy son hardcoded en el bot (.env vars). Si Vecchi
/// quiere cambiar el destinatario del resumen diario de service, hay que
/// modificar `SERVICE_DESTINATARIO_DNI` en el .env del bot y reiniciar. El
/// "Parte de mantenimiento" diario a Emmanuel lo manda la Cloud Function
/// `resumenMantenimientoVehiculosDiario` con destinatario hardcodeado en
/// `functions/src/comun.ts` (`MANTENIMIENTO_VEHICULOS_DNI`) y por eso no
/// aparece en esta card. Una pantalla de edición desde la app requeriría
/// refactor para que el cron lea de Firestore — postpuesto.
class _CardReglasNotificacion extends StatelessWidget {
  final Map reglas;
  const _CardReglasNotificacion({required this.reglas});

  @override
  Widget build(BuildContext context) {
    if (reglas.isEmpty) {
      return const _BloqueDatos(
        titulo: 'Reglas de notificación',
        icono: Icons.rule_folder_outlined,
        filas: [
          _Fila('Estado',
              'No publicadas. Actualizar el bot a la versión nueva.',
              color: AppColors.warning),
        ],
      );
    }

    // M9 — escucha el doc de pausas en vivo. Si el admin pausa un canal,
    // la card refresca al toque (sin esperar al cache 5min del bot).
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.meta)
          .doc('canales_pausados')
          .snapshots(),
      builder: (ctx, snap) {
        Map<String, dynamic> pausas = const {};
        if (snap.hasData && snap.data!.exists) {
          pausas =
              (snap.data!.data() as Map<String, dynamic>?) ?? const {};
        }
        return _buildContenido(context, pausas);
      },
    );
  }

  Widget _buildContenido(
    BuildContext context,
    Map<String, dynamic> pausas,
  ) {
    // Agrupamos por la nueva categoría que publica el bot (2026-05-24).
    // Compat: reglas viejas sin `categoria` caen en "OTROS".
    final porCategoria = <String, List<MapEntry<String, Map>>>{};
    reglas.forEach((tipoKey, regla) {
      if (regla is! Map) return;
      final cat = (regla['categoria'] ?? 'OTROS').toString();
      porCategoria.putIfAbsent(cat, () => []).add(
            MapEntry(tipoKey.toString(), regla),
          );
    });
    final ordenCategorias = [
      'RESUMEN_DIARIO_08',
      'CRON_BOT_60MIN',
      'TIEMPO_REAL_CHOFER',
      'CACHATORE',
      'SISTEMA',
      'OTROS',
    ];

    final secciones = <Widget>[];
    for (final cat in ordenCategorias) {
      final items = porCategoria[cat];
      if (items == null || items.isEmpty) continue;
      secciones.add(Padding(
        padding: const EdgeInsets.only(top: 6, bottom: AppSpacing.sm, left: 2),
        child: Text(
          _etiquetaCategoria(cat),
          style: AppType.eyebrow.copyWith(color: AppColors.success),
        ),
      ));
      for (final entry in items) {
        final dni = (entry.value['destinatarioDni'] ?? '').toString();
        final desc = (entry.value['descripcion'] ?? '').toString();
        final fuente = (entry.value['fuente'] ?? '').toString();
        final pausaRaw = pausas[entry.key];
        secciones.add(_FilaReglaNotif(
          regKey: entry.key,
          titulo: _etiquetaTipo(entry.key),
          descripcion: desc,
          destinatarioDni: dni,
          fuente: fuente,
          pausaInfo: pausaRaw is Map<String, dynamic> ? pausaRaw : null,
        ));
      }
    }

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.rule_folder_outlined,
                  color: AppColors.success, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Reglas de notificación',
                style: AppType.body.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ...secciones,
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Catálogo completo de mensajes que la app manda por WhatsApp. '
            'Si querés cambiar quién recibe un resumen sin tocar código '
            'ni reiniciar nada, usá el botón de abajo (M5, 2026-05-24): '
            'el cambio se aplica en ≤ 5 min vía Firestore.',
            style: AppType.label.copyWith(color: AppColors.textDisabled),
          ),
          const SizedBox(height: AppSpacing.md - 2),
          Center(
            child: AppButton.secondary(
              label: 'Editar destinatarios',
              icon: Icons.edit_outlined,
              onPressed: () => Navigator.pushNamed(
                  context, AppRoutes.adminDestinatariosNotificacion),
            ),
          ),
        ],
      ),
    );
  }

  String _etiquetaCategoria(String cat) {
    switch (cat) {
      case 'RESUMEN_DIARIO_08':
        return 'RESÚMENES DIARIOS 08:00 ART (CLOUD FUNCTIONS)';
      case 'CRON_BOT_60MIN':
        return 'CRONS DEL BOT (CADA 60 MIN)';
      case 'TIEMPO_REAL_CHOFER':
        return 'TIEMPO REAL AL CHOFER (EVENT-DRIVEN)';
      case 'CACHATORE':
        return 'CACHATORE — TURNOS YPF';
      case 'SISTEMA':
        return 'SISTEMA / ADMIN';
      default:
        return 'OTROS';
    }
  }

  String _etiquetaTipo(String key) {
    switch (key) {
      // Resúmenes 08:00
      case 'mantenimientoBot':
        return 'Salud del bot (caídas / recuperaciones)';
      case 'driftsAsignaciones':
        return 'Drifts iButton vs asignación del sistema';
      case 'parteMantenimientoVolvo':
        return 'Parte de mantenimiento Volvo';
      case 'excesosJornada':
        return 'Excesos de jornada (bloque/cuota/veda)';
      case 'conductaManejo':
        return 'Conducta de manejo (Sitrack + Volvo)';
      // Crons bot 60 min
      case 'serviceDiario':
        return 'Service próximo / vencido';
      case 'vencimientosProximosConsolidado':
        return 'Vencimientos próximos (consolidado)';
      case 'vencimientosChofer':
        return 'Vencimientos del chofer';
      case 'vencimientosVehiculo':
        return 'Vencimientos del vehículo';
      // Tiempo real chofer
      case 'vigiladorJornada':
        return 'Vigilador de jornada v2';
      case 'alertasVolvoHigh':
        return 'Alertas Volvo HIGH';
      case 'iButtonNoIdentificado':
        return 'Pasá el iButton (Sitrack drift)';
      case 'silencioReanudado':
        return 'Silencio reanudado';
      // Cachatore
      case 'cachatoreChofer':
        return 'Turno YPF al chofer';
      case 'cachatoreEncargado':
        return 'Turnos YPF al encargado';
      // Sistema
      case 'colaCreciente':
        return 'Alerta de cola creciente';
      default:
        return key;
    }
  }
}

class _FilaReglaNotif extends StatelessWidget {
  /// Key del canal en META/canales_pausados (ej. "mantenimientoBot").
  /// Vacío si la regla no es pausable.
  final String regKey;
  final String titulo;
  final String descripcion;
  /// Puede ser un DNI numérico, "CHOFER_AFECTADO", "CHOFER_ASIGNADO",
  /// "CHOFER_MANEJANDO", "CHOFER_DEL_TURNO", "CHOFER_SILENCIADO" o
  /// vacío si no está configurado.
  final String destinatarioDni;
  /// Origen técnico (ej. "CF resumenBotDiario", "bot cron_service_diario").
  /// Se muestra chico abajo para que el admin pueda mapear regla → código.
  final String fuente;
  /// Info de pausa M9. `null` = canal activo. Map = pausado (puede tener
  /// `hasta_iso`, `motivo`, `pausado_en`, `pausado_por_dni`).
  final Map<String, dynamic>? pausaInfo;

  const _FilaReglaNotif({
    required this.titulo,
    required this.descripcion,
    required this.destinatarioDni,
    this.fuente = '',
    this.regKey = '',
    this.pausaInfo,
  });

  bool get _esDinamico => destinatarioDni.startsWith('CHOFER_');

  /// `true` cuando pausar este canal silencia algo de seguridad — se pinta
  /// en rojo y el bottom sheet muestra warning fuerte.
  bool get _esCritico => regKey == 'bypassSeguridad';

  /// Info de pausa vigente (descarta si la fecha ya pasó).
  ({DateTime? hasta, String? motivo})? get _pausaVigente {
    final p = pausaInfo;
    if (p == null) return null;
    final hastaRaw = p['hasta_iso'];
    DateTime? hasta;
    if (hastaRaw is String && hastaRaw.isNotEmpty) {
      hasta = DateTime.tryParse(hastaRaw);
      if (hasta != null && DateTime.now().isAfter(hasta)) {
        return null; // ya vencida
      }
    }
    final motivoRaw = p['motivo'];
    final motivo =
        motivoRaw is String && motivoRaw.trim().isNotEmpty
            ? motivoRaw.trim()
            : null;
    return (hasta: hasta, motivo: motivo);
  }

  @override
  Widget build(BuildContext context) {
    final pausa = _pausaVigente;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            titulo,
            style: AppType.label.copyWith(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (descripcion.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                descripcion,
                style: AppType.label.copyWith(color: AppColors.textSecondary),
              ),
            ),
          const SizedBox(height: AppSpacing.xs),
          if (destinatarioDni.isEmpty)
            const _BadgeDestinatario(
              icono: Icons.warning_amber_outlined,
              texto: 'No configurado en .env',
              color: AppColors.warning,
            )
          else if (_esDinamico)
            _BadgeDestinatario(
              icono: Icons.person_outline,
              texto: _etiquetaChoferDinamico(destinatarioDni),
              color: AppColors.info,
            )
          else
            _DniResolver(dni: destinatarioDni),
          if (fuente.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Fuente: $fuente',
                style: const TextStyle(
                  color: AppColors.textHint,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          if (regKey.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: pausa != null
                  ? _BadgePausa(
                      regKey: regKey,
                      hasta: pausa.hasta,
                      motivo: pausa.motivo,
                      critico: _esCritico,
                    )
                  : _BotonPausar(regKey: regKey, critico: _esCritico),
            ),
          // M6 — deep-link al histórico filtrado por origen. Útil para
          // responder "¿qué le mandé la última vez?" sin necesitar
          // dry-run real (que requeriría refactor de cada CF).
          if (_origenParaHistorico != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AdminWhatsappHistoricoScreen(
                          initialOrigen: _origenParaHistorico,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.history,
                      size: 13, color: AppColors.info),
                  label: Text(
                    'Ver último enviado',
                    style: AppType.eyebrow.copyWith(
                      color: AppColors.info,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Mapeo M6: cada `regKey` a su `origen` correspondiente en
  /// COLA_WHATSAPP / WHATSAPP_HISTORICO. Si la regla no tiene un
  /// origen 1:1 (porque emite varios) devolvemos null y el botón no
  /// aparece — el usuario filtra a mano en la pantalla.
  String? get _origenParaHistorico {
    switch (regKey) {
      case 'mantenimientoBot':
        return 'cron_bot_resumen_diario';
      case 'driftsAsignaciones':
        return 'resumen_drifts_asignaciones';
      case 'parteMantenimientoVolvo':
        return 'resumen_mantenimiento_vehiculos';
      case 'excesosJornada':
        return 'resumen_jornadas_v2';
      case 'conductaManejo':
        return 'resumen_conducta_manejo_diario';
      case 'bypassSeguridad':
        return 'bypass_seguridad';
      case 'serviceDiario':
        return 'cron_service_diario';
      case 'vencimientosProximosConsolidado':
        return 'cron_vencimientos_proximos_diario';
      case 'cachatoreEncargado':
        return 'cachatore_resumen';
      case 'colaCreciente':
        return 'health_alert_cola_creciente';
      default:
        return null;
    }
  }

  String _etiquetaChoferDinamico(String tipo) {
    switch (tipo) {
      case 'CHOFER_AFECTADO':
        return 'Al chofer dueño del documento';
      case 'CHOFER_ASIGNADO':
        return 'Al chofer asignado al vehículo';
      case 'CHOFER_MANEJANDO':
        return 'Al chofer que está manejando';
      case 'CHOFER_DEL_TURNO':
        return 'Al chofer titular del turno';
      case 'CHOFER_SILENCIADO':
        return 'Al chofer que fue silenciado';
      default:
        return tipo;
    }
  }
}

/// Resuelve un DNI a "DNI — NOMBRE" leyendo EMPLEADOS/{dni}. Stream
/// chiquito, refresca solo si cambia el nombre del empleado.
class _DniResolver extends StatelessWidget {
  final String dni;
  const _DniResolver({required this.dni});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('EMPLEADOS')
          .doc(dni)
          .snapshots(),
      builder: (ctx, snap) {
        String nombre = '';
        if (snap.hasData && snap.data!.exists) {
          final d = snap.data!.data() as Map<String, dynamic>?;
          nombre = (d?['NOMBRE'] ?? '').toString();
        }
        final dniFmt = AppFormatters.formatearDNI(dni);
        final texto = nombre.isEmpty
            ? 'DNI $dniFmt (no encontrado en EMPLEADOS)'
            : 'DNI $dniFmt · $nombre';
        return _BadgeDestinatario(
          icono: Icons.person,
          texto: texto,
          color: nombre.isEmpty
              ? AppColors.warning
              : AppColors.success,
        );
      },
    );
  }
}

class _BadgeDestinatario extends StatelessWidget {
  final IconData icono;
  final String texto;
  final Color color;

  const _BadgeDestinatario({
    required this.icono,
    required this.texto,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, color: color, size: 14),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              texto,
              style: AppType.eyebrow.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardConfig extends StatelessWidget {
  final Map config;
  const _CardConfig({required this.config});

  @override
  Widget build(BuildContext context) {
    final enHorario = config['enHorarioHabil'] == true;
    final autoAvisos = config['autoAvisos'] == true;
    final autoResp = config['autoRespuestas'] == true;
    final start = config['workingHoursStart'];
    final end = config['workingHoursEnd'];
    final tz = (config['timezone'] ?? '').toString();

    return _BloqueDatos(
      titulo: 'Configuración',
      icono: Icons.tune,
      filas: [
        _Fila('Ahora en horario hábil', enHorario ? 'Sí' : 'No',
            color: enHorario ? AppColors.success : AppColors.warning),
        _Fila('Ventana', start != null && end != null ? '$start a $end hs' : '—'),
        _Fila('Zona horaria', tz),
        _Fila('Avisos automáticos', autoAvisos ? 'Activos' : 'Pausados',
            color: autoAvisos ? AppColors.success : AppColors.textTertiary),
        _Fila('Respuestas automáticas',
            autoResp ? 'Activas' : 'Desactivadas',
            color: autoResp ? AppColors.success : AppColors.textTertiary),
      ],
    );
  }
}

class _CardBotInfo extends StatelessWidget {
  final Map bot;
  const _CardBotInfo({required this.bot});

  @override
  Widget build(BuildContext context) {
    final v = (bot['version'] ?? '?').toString();
    final pid = bot['pid'];
    final node = (bot['nodeVersion'] ?? '?').toString();
    final uptime = (bot['uptimeSegundos'] ?? 0) as int;

    return _BloqueDatos(
      titulo: 'Proceso',
      icono: Icons.memory,
      filas: [
        _Fila('Versión', v),
        _Fila('PID', pid?.toString() ?? '?'),
        _Fila('Node', node),
        _Fila('Uptime', _formatUptime(uptime)),
      ],
    );
  }
}

class _CardErroresRecientes extends StatelessWidget {
  final List errores;
  const _CardErroresRecientes({required this.errores});

  @override
  Widget build(BuildContext context) {
    if (errores.isEmpty) {
      return const _BloqueDatos(
        titulo: 'Errores recientes',
        icono: Icons.bug_report_outlined,
        filas: [
          _Fila('Sin errores en buffer', '✓',
              color: AppColors.success),
        ],
      );
    }
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg - 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bug_report_outlined,
                  color: AppColors.error, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Errores recientes (${errores.length})',
                style: AppType.label.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md - 2),
          ...errores.map((e) => _FilaError(error: e as Map)),
        ],
      ),
    );
  }
}

class _FilaError extends StatelessWidget {
  final Map error;
  const _FilaError({required this.error});

  @override
  Widget build(BuildContext context) {
    final cuando = _toDate(error['en']);
    final ctx = (error['contexto'] ?? '').toString();
    final msg = (error['mensaje'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (ctx.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.error.withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    ctx.toUpperCase(),
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                cuando == null ? '—' : _hace(cuando),
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            msg,
            // Stack-traces y mensajes crudos pueden ser de 200+ chars.
            // 4 líneas + ellipsis para no inundar la card.
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: AppType.label.copyWith(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// HELPERS DE FORMATO
// =============================================================================

DateTime? _toDate(dynamic v) {
  if (v == null) return null;
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  return null;
}

String _hace(DateTime cuando, {bool futuro = false}) {
  final ahora = DateTime.now();
  final diff = futuro ? cuando.difference(ahora) : ahora.difference(cuando);
  final segs = diff.inSeconds.abs();
  if (segs < 60) return futuro ? 'en menos de 1 min' : 'hace ${segs}s';
  final mins = diff.inMinutes.abs();
  if (mins < 60) return futuro ? 'en $mins min' : 'hace $mins min';
  final hs = diff.inHours.abs();
  if (hs < 24) return futuro ? 'en $hs h' : 'hace $hs h';
  final dias = diff.inDays.abs();
  return futuro ? 'en $dias días' : 'hace $dias días';
}

String _formatUptime(int segs) {
  if (segs < 60) return '${segs}s';
  if (segs < 3600) return '${(segs / 60).floor()}m';
  if (segs < 86400) {
    final h = (segs / 3600).floor();
    final m = ((segs % 3600) / 60).floor();
    return '${h}h ${m}m';
  }
  final d = (segs / 86400).floor();
  final h = ((segs % 86400) / 3600).floor();
  return '${d}d ${h}h';
}

// =============================================================================
// WIDGETS REUTILIZABLES PRIVADOS
// =============================================================================

class _BloqueDatos extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final List<_Fila> filas;
  /// Si true, el bloque sugiere visualmente que las filas son
  /// clickeables agregando una pequeña indicación en el header
  /// ("toca para abrir"). No fuerza el comportamiento — cada `_Fila`
  /// decide si es clickeable según tenga `onTap` o no.
  final bool mostrarChevron;
  const _BloqueDatos({
    required this.titulo,
    required this.icono,
    required this.filas,
    this.mostrarChevron = false,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg - 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: AppColors.success, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  titulo,
                  style: AppType.label.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              if (mostrarChevron)
                Text(
                  'TOCAR PARA VER',
                  style: AppType.eyebrow.copyWith(
                    color: AppColors.textDisabled,
                    fontSize: 9,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md - 2),
          ...filas,
        ],
      ),
    );
  }
}

class _Fila extends StatelessWidget {
  final String label;
  final String valor;
  final Color color;
  /// Si está seteado, la fila se renderiza como InkWell y agrega un
  /// chevron sutil a la derecha. Si es null, comportamiento original
  /// (solo lectura).
  final VoidCallback? onTap;

  const _Fila(
    this.label,
    this.valor, {
    this.color = AppColors.textSecondary,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final contenido = Padding(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.sm,
        horizontal: AppSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.label.copyWith(color: AppColors.textTertiary),
            ),
          ),
          Text(
            valor,
            style: AppType.label.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right,
                size: 16, color: AppColors.textDisabled),
          ],
        ],
      ),
    );
    if (onTap == null) return contenido;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: contenido,
      ),
    );
  }
}

class _Mensaje extends StatelessWidget {
  final IconData icono;
  final Color color;
  final String texto;
  const _Mensaje({
    required this.icono,
    required this.color,
    required this.texto,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icono, color: color, size: 48),
            const SizedBox(height: AppSpacing.lg),
            Text(
              texto,
              textAlign: TextAlign.center,
              style: AppType.body.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// KILL-SWITCH (Pausar / Reanudar bot)
// =============================================================================

/// Toggle que permite al admin pausar el envío automático del bot
/// sin tocar la PC donde corre. Escribe `BOT_CONTROL/main.pausado` y el
/// bot lo lee en su próximo polling (cache TTL ~10s, ver
/// `whatsapp-bot/src/control.js`).
///
/// Visible solo a ADMIN — las rules de `BOT_CONTROL` solo permiten
/// write a `isAdmin()`. Si SUPERVISOR llega a tocarlo, falla con
/// permission-denied.
class _ToggleKillSwitch extends StatelessWidget {
  const _ToggleKillSwitch();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('BOT_CONTROL')
          .doc('main')
          .snapshots(),
      builder: (ctx, snap) {
        // Si la lectura falla (rules, network), tratamos como NO pausado
        // para no asustar — la pantalla principal ya muestra heartbeat
        // como fuente de verdad del estado real del bot.
        final data = snap.data?.data() as Map<String, dynamic>?;
        final pausado = data?['pausado'] == true;
        final motivo = (data?['motivo'] ?? '').toString().trim();
        // Mismo formato que el _MasterSwitch del CachatoreHubScreen
        // (2026-05-24): switch ON = bot encendido (verde), switch OFF =
        // bot pausado. Antes el toggle estaba invertido (ON = pausado)
        // y confundía a los operadores. Internamente el doc sigue siendo
        // `pausado: bool` — solo cambia la semántica visual.
        final encendido = !pausado;
        return AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg - 2),
          borderColor: pausado ? AppColors.warning.withAlpha(160) : null,
          highlighted: pausado,
          child: Row(
            children: [
              Icon(
                encendido ? Icons.power_settings_new : Icons.pause_circle_filled,
                color: encendido ? AppColors.success : AppColors.warning,
                size: 28,
              ),
              const SizedBox(width: AppSpacing.lg - 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      encendido ? 'Bot encendido' : 'Bot pausado por admin',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.label.copyWith(
                        color: encendido
                            ? AppColors.textPrimary
                            : AppColors.warning,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      encendido
                          ? 'Enviando mensajes a los choferes.'
                          : (motivo.isEmpty
                              ? 'No envía mensajes hasta reanudar.'
                              : 'Motivo: $motivo'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.label.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: encendido,
                activeThumbColor: AppColors.success,
                // El usuario apaga el switch ⇒ pasamos `nuevoPausado=true`
                // a `_confirmarYTogglear` (que sigue trabajando con la
                // variable `pausado` original del doc Firestore).
                onChanged: (nuevoEncendido) => _confirmarYTogglear(
                    context, pausado, !nuevoEncendido),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Pide confirmación antes de pausar (la acción es operacional —
  /// detiene envíos a choferes). Reanudar también pide confirmación
  /// para evitar toques accidentales.
  Future<void> _confirmarYTogglear(
    BuildContext context,
    bool pausadoActual,
    bool nuevoValor,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final accion = nuevoValor ? 'PAUSAR' : 'REANUDAR';
    final detalle = nuevoValor
        ? 'El bot dejará de enviar mensajes hasta que reanudes. Los avisos pendientes quedan en cola.'
        : 'El bot va a retomar el envío de los mensajes pendientes en su próximo ciclo (~15s).';

    final confirmado = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('$accion bot'),
        content: Text(detalle),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.pop(dCtx, false),
          ),
          AppButton(
            label: accion,
            onPressed: () => Navigator.pop(dCtx, true),
          ),
        ],
      ),
    );
    if (confirmado != true) return;

    try {
      await FirebaseFirestore.instance
          .collection('BOT_CONTROL')
          .doc('main')
          .set(
        {
          'pausado': nuevoValor,
          'pausado_en': nuevoValor ? FieldValue.serverTimestamp() : null,
          'pausado_por': nuevoValor ? PrefsService.dni : null,
          'pausado_por_nombre': nuevoValor ? PrefsService.nombre : null,
          'reanudado_en': nuevoValor ? null : FieldValue.serverTimestamp(),
          'fecha_ultima_actualizacion': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      AppFeedback.successOn(
        messenger,
        nuevoValor ? 'Bot pausado.' : 'Bot reanudado.',
      );
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo actualizar el control del bot. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }
}

// =============================================================================
// M9 — PAUSAR CANAL DE NOTIFICACIÓN
// =============================================================================
// Badge de canal pausado + botón para reanudar (con confirmación) y botón
// para pausar (abre bottom sheet con date picker + motivo opcional).
//
// El doc `META/canales_pausados` lo lee la card en vivo via StreamBuilder,
// así que cualquier cambio acá refresca al toque (sin esperar al cache 5min
// de los CFs / bot). Los crons del lado server hacen el chequeo recién en
// su próxima corrida.

class _BadgePausa extends StatelessWidget {
  final String regKey;
  final DateTime? hasta;
  final String? motivo;
  final bool critico;
  const _BadgePausa({
    required this.regKey,
    required this.hasta,
    required this.motivo,
    required this.critico,
  });

  @override
  Widget build(BuildContext context) {
    final color = critico ? AppColors.error : AppColors.warning;
    final hastaTxt = hasta == null
        ? 'indefinido'
        : 'hasta ${AppFormatters.formatearFechaCorta(hasta!)} '
            '${_hhMm(hasta!)}';
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withAlpha(120)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.pause_circle_outline, color: color, size: 14),
                const SizedBox(width: 6),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'CANAL PAUSADO — $hastaTxt',
                        style: AppType.eyebrow.copyWith(
                          color: color,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (motivo != null && motivo!.isNotEmpty)
                        Text(
                          motivo!,
                          style: TextStyle(
                            color: color.withAlpha(220),
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        TextButton.icon(
          onPressed: () => _confirmarReanudar(context),
          icon: const Icon(Icons.play_arrow,
              size: 16, color: AppColors.success),
          label: Text(
            'Reanudar',
            style: AppType.eyebrow.copyWith(
              color: AppColors.success,
              fontWeight: FontWeight.bold,
            ),
          ),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }

  String _hhMm(DateTime d) {
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Future<void> _confirmarReanudar(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Reanudar canal',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'El canal va a empezar a mandar mensajes de nuevo a partir '
          'del próximo ciclo (≤ 5 min). ¿Confirmar?',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            label: 'Reanudar',
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await FirebaseFirestore.instance
          .collection(AppCollections.meta)
          .doc('canales_pausados')
          .set({regKey: FieldValue.delete()}, SetOptions(merge: true));
      AppFeedback.successOn(messenger, 'Canal reanudado.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo reanudar el canal.',
        tecnico: e,
        stack: s,
      );
    }
  }
}

class _BotonPausar extends StatelessWidget {
  final String regKey;
  final bool critico;
  const _BotonPausar({required this.regKey, required this.critico});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _BottomSheetPausa.abrir(context, regKey, critico),
        icon: Icon(
          Icons.pause_circle_outline,
          size: 14,
          color: critico ? AppColors.error : AppColors.textTertiary,
        ),
        label: Text(
          'Pausar canal…',
          style: AppType.eyebrow.copyWith(
            color: critico ? AppColors.error : AppColors.textTertiary,
            fontWeight: FontWeight.bold,
          ),
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: 2,
          ),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

class _BottomSheetPausa extends StatefulWidget {
  final String regKey;
  final bool critico;
  const _BottomSheetPausa({required this.regKey, required this.critico});

  static Future<void> abrir(
    BuildContext context,
    String regKey,
    bool critico,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) =>
          _BottomSheetPausa(regKey: regKey, critico: critico),
    );
  }

  @override
  State<_BottomSheetPausa> createState() => _BottomSheetPausaState();
}

class _BottomSheetPausaState extends State<_BottomSheetPausa> {
  late DateTime _hasta;
  bool _indefinida = false;
  final _motivoCtrl = TextEditingController();
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    // Default: hasta mañana 03:00 ART (cubre el día actual, en la madru
    // ya está reanudado para el cron de las 08:00 del día siguiente — el
    // admin lo extiende si quiere más).
    final ahora = DateTime.now();
    _hasta = DateTime(ahora.year, ahora.month, ahora.day + 1, 3, 0);
  }

  @override
  void dispose() {
    _motivoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl + bottomInset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.pause_circle_outline,
                color: widget.critico
                    ? AppColors.error
                    : AppColors.warning,
                size: 22,
              ),
              const SizedBox(width: AppSpacing.sm),
              const Text(
                'Pausar canal',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            widget.regKey,
            style: AppType.eyebrow.copyWith(
              color: AppColors.textDisabled,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (widget.critico)
            Container(
              padding: const EdgeInsets.all(AppSpacing.md - 2),
              decoration: BoxDecoration(
                color: AppColors.error.withAlpha(30),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.error.withAlpha(120)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_outlined,
                      color: AppColors.error, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Atención: este canal silencia un aviso de '
                      'seguridad. Pausar SOLO en testing del módulo Volvo.',
                      style: AppType.label.copyWith(
                        color: AppColors.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (widget.critico) const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              const Text('Pausa indefinida',
                  style: TextStyle(color: AppColors.textPrimary)),
              const Spacer(),
              Switch(
                value: _indefinida,
                onChanged: _guardando
                    ? null
                    : (v) => setState(() => _indefinida = v),
                activeThumbColor: AppColors.warning,
              ),
            ],
          ),
          if (!_indefinida) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Hasta:',
              style: AppType.label.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xs),
            InkWell(
              onTap: _guardando ? null : _pickDate,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.md - 2,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.info),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today,
                        color: AppColors.info, size: 16),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      '${AppFormatters.formatearFechaCorta(_hasta)} '
                      '${_hasta.hour.toString().padLeft(2, '0')}:'
                      '${_hasta.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(color: AppColors.textPrimary),
                    ),
                    const Spacer(),
                    AppButton.ghost(
                      label: 'Cambiar hora',
                      onPressed: _guardando ? null : _pickTime,
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _motivoCtrl,
            enabled: !_guardando,
            maxLength: 80,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              labelText: 'Motivo (opcional)',
              hintText: 'Ej. Vacaciones Molina hasta el 01-Jun',
              hintStyle: TextStyle(color: AppColors.textHint),
              labelStyle: TextStyle(color: AppColors.textSecondary),
              border: OutlineInputBorder(),
              counterStyle: TextStyle(color: AppColors.textDisabled),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              AppButton.ghost(
                label: 'Cancelar',
                onPressed: _guardando ? null : () => Navigator.pop(context),
              ),
              const Spacer(),
              AppButton(
                label: 'Pausar',
                icon: Icons.pause_circle,
                isLoading: _guardando,
                variant: widget.critico
                    ? AppButtonVariant.danger
                    : AppButtonVariant.primary,
                onPressed: _guardando ? null : _confirmar,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final ahora = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _hasta,
      firstDate: ahora,
      lastDate: ahora.add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      _hasta = DateTime(
          picked.year, picked.month, picked.day, _hasta.hour, _hasta.minute);
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _hasta.hour, minute: _hasta.minute),
    );
    if (picked == null) return;
    setState(() {
      _hasta = DateTime(_hasta.year, _hasta.month, _hasta.day,
          picked.hour, picked.minute);
    });
  }

  Future<void> _confirmar() async {
    setState(() => _guardando = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final hastaIso = _indefinida ? null : _hasta.toUtc().toIso8601String();
      final motivo = _motivoCtrl.text.trim();
      await FirebaseFirestore.instance
          .collection(AppCollections.meta)
          .doc('canales_pausados')
          .set({
        widget.regKey: {
          'hasta_iso': hastaIso,
          'motivo': motivo.isEmpty ? null : motivo,
          'pausado_en': FieldValue.serverTimestamp(),
          'pausado_por_dni': PrefsService.dni,
        }
      }, SetOptions(merge: true));
      AppFeedback.successOn(messenger, 'Canal pausado.');
      navigator.pop();
    } catch (e, s) {
      setState(() => _guardando = false);
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo pausar el canal.',
        tecnico: e,
        stack: s,
      );
    }
  }
}

// =============================================================================
// M7 — SPARKLINE 7 DÍAS DE MENSAJES ENVIADOS
// =============================================================================
// BarChart chiquito con el conteo de mensajes (ENVIADO + ERROR) por día
// los últimos 7 días. Lee WHATSAPP_HISTORICO con `count()` aggregation
// — 7 reads por carga, eficiente.
//
// Tap a una barra → push a la pantalla "Historial WhatsApp" — el usuario
// puede ajustar el rango ahí si quiere ver detalle. Decisión: no abrir
// con rango pre-seteado porque eso requiere props en el constructor de
// la screen y la pantalla ya tiene su propio picker; mejor mantenerla
// simple.
//
// Caveat: WHATSAPP_HISTORICO se empezó a llenar el 2026-05-24. Los días
// previos al deploy aparecen vacíos — esperado.

class _CardSparklineEnviados extends StatefulWidget {
  const _CardSparklineEnviados();

  @override
  State<_CardSparklineEnviados> createState() => _CardSparklineEnviadosState();
}

class _CardSparklineEnviadosState extends State<_CardSparklineEnviados> {
  final _service = WhatsAppHistoricoService();
  static const int _dias = 7;

  /// null = cargando. Lista de `_dias` enteros = conteo por día.
  List<int>? _conteos;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final r = await _service.contarPorDia(_dias);
      if (!mounted) return;
      setState(() {
        _conteos = r;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg - 2,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.bar_chart,
                  color: AppColors.info, size: 18),
              const SizedBox(width: AppSpacing.sm),
              const Expanded(
                child: Text(
                  'Enviados últimos 7 días',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              if (_conteos != null)
                Text(
                  'Total: ${_conteos!.fold<int>(0, (a, b) => a + b)}',
                  style: AppType.eyebrow.copyWith(color: AppColors.textSecondary),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 110,
            child: _contenido(),
          ),
        ],
      ),
    );
  }

  Widget _contenido() {
    if (_error != null) {
      return Center(
        child: Text(
          'Sin datos del histórico todavía',
          style: AppType.eyebrow.copyWith(color: AppColors.textDisabled),
        ),
      );
    }
    if (_conteos == null) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppColors.textHint),
        ),
      );
    }
    final c = _conteos!;
    final maxValor = c.fold<int>(0, (a, b) => b > a ? b : a);
    if (maxValor == 0) {
      return Center(
        child: Text(
          'Sin mensajes en los últimos 7 días',
          style: AppType.eyebrow.copyWith(color: AppColors.textDisabled),
        ),
      );
    }
    final maxY = (maxValor * 1.15).ceilToDouble();
    final interval = maxY <= 10
        ? 2.0
        : (maxY <= 30 ? 5.0 : (maxY / 4).ceilToDouble());

    final ahora = DateTime.now();
    String labelEjeX(int idx) {
      // idx 0 = más viejo (hace _dias-1), idx _dias-1 = hoy.
      if (idx == _dias - 1) return 'Hoy';
      final d = ahora.subtract(Duration(days: _dias - 1 - idx));
      const dows = ['Lu', 'Ma', 'Mi', 'Ju', 'Vi', 'Sa', 'Do'];
      return dows[(d.weekday - 1).clamp(0, 6)];
    }

    return BarChart(
      BarChartData(
        maxY: maxY,
        minY: 0,
        barGroups: [
          for (var i = 0; i < c.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: c[i].toDouble(),
                  color: c[i] > 0
                      ? AppColors.info
                      : Colors.white12,
                  width: 16,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(3),
                  ),
                ),
              ],
            ),
        ],
        gridData: FlGridData(
          show: true,
          horizontalInterval: interval,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (v) => FlLine(
            color: Colors.white.withValues(alpha: 0.05),
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: interval,
              reservedSize: 26,
              getTitlesWidget: (v, m) => Text(
                v.toInt().toString(),
                style: const TextStyle(
                    color: Colors.white54, fontSize: 9),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 20,
              getTitlesWidget: (v, m) {
                final idx = v.toInt();
                if (idx < 0 || idx >= c.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    labelEjeX(idx),
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 9),
                  ),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border(
            left: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            bottom:
                BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) =>
                Colors.black.withValues(alpha: 0.85),
            getTooltipItem: (group, _, __, ___) {
              final idx = group.x;
              final n = c[idx];
              return BarTooltipItem(
                '${labelEjeX(idx)}: $n msg',
                AppType.eyebrow.copyWith(color: Colors.white),
              );
            },
          ),
          touchCallback: (event, response) {
            if (!event.isInterestedForInteractions) return;
            if (response?.spot == null) return;
            // Tap a una barra → abrir el histórico (el usuario refina
            // el rango ahí). Por ahora navegamos sin pre-seleccionar
            // un día específico para no acoplar la API de la screen.
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AdminWhatsappHistoricoScreen(),
              ),
            );
          },
        ),
      ),
    );
  }
}
