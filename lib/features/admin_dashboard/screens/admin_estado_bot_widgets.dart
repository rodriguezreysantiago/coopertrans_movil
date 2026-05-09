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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        _BannerEstado(salud: salud, estadoCliente: estadoCliente, ultimoHb: ultimoHb),
        const SizedBox(height: 16),
        const _ToggleKillSwitch(),
        const SizedBox(height: 12),
        _CardCola(cola: (data['cola'] as Map?) ?? const {}),
        const SizedBox(height: 12),
        _CardMensajes(mensajes: (data['mensajes'] as Map?) ?? const {}),
        const SizedBox(height: 12),
        _CardCron(cron: (data['cron'] as Map?) ?? const {}),
        const SizedBox(height: 12),
        _CardConfig(config: (data['config'] as Map?) ?? const {}),
        const SizedBox(height: 12),
        _CardReglasNotificacion(
          reglas: (data['reglasNotificacion'] as Map?) ?? const {},
        ),
        const SizedBox(height: 12),
        _CardErroresRecientes(
          errores: (data['erroresRecientes'] as List?) ?? const [],
        ),
        const SizedBox(height: 12),
        _CardBotInfo(bot: (data['bot'] as Map?) ?? const {}),
        const SizedBox(height: 24),
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
      padding: const EdgeInsets.all(20),
      borderColor: color.withAlpha(160),
      highlighted: salud != _Salud.ok,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: color, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tituloPrincipal,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
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
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(8),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.access_time,
                    color: Colors.white54, size: 14),
                const SizedBox(width: 8),
                Text(
                  ultimoHb == null
                      ? 'Sin heartbeat registrado'
                      : 'Último heartbeat: ${_hace(ultimoHb!)}',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
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
            color:
                pendientesFrescos > 0 ? AppColors.warning : Colors.white70,
            onTap: () => _abrirCola(context, 'PENDIENTE')),
        _Fila('En proceso', '$procesando',
            onTap: () => _abrirCola(context, 'PROCESANDO')),
        _Fila('Reintentando', '$reintentando',
            color:
                reintentando > 0 ? AppColors.accentAmber : Colors.white70,
            onTap: () => _abrirCola(context, 'PENDIENTE')),
        _Fila('Con error', '$error',
            color: error > 0 ? AppColors.error : Colors.white70,
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
    return _BloqueDatos(
      titulo: 'Mensajes',
      icono: Icons.mark_chat_read_outlined,
      filas: [
        _Fila('Enviados hoy', '$hoy',
            color: AppColors.success),
        _Fila('Último envío',
            ultimo == null ? 'Nunca' : _hace(ultimo)),
      ],
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
          color: err > 0 ? AppColors.error : Colors.white70));
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
/// Edición: las reglas hoy son hardcoded en el bot (.env vars). Si
/// Vecchi quiere cambiar el destinatario del resumen diario, hay que
/// modificar `SERVICE_DESTINATARIO_DNI` o `ALERTAS_RESUMEN_DESTINATARIO_DNI`
/// en el .env del bot y reiniciar. Una pantalla de edición desde la app
/// requeriría refactor para que el cron lea de Firestore — postpuesto.
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

    final items = <Widget>[];
    reglas.forEach((tipoKey, regla) {
      if (regla is! Map) return;
      final dni = (regla['destinatarioDni'] ?? '').toString();
      final desc = (regla['descripcion'] ?? '').toString();
      items.add(_FilaReglaNotif(
        titulo: _etiquetaTipo(tipoKey.toString()),
        descripcion: desc,
        destinatarioDni: dni,
      ));
    });

    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.rule_folder_outlined,
                  color: AppColors.accentGreen, size: 18),
              SizedBox(width: 8),
              Text(
                'Reglas de notificación',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...items,
          const SizedBox(height: 8),
          const Text(
            'Para cambiar destinatarios: editar SERVICE_DESTINATARIO_DNI '
            'y/o ALERTAS_RESUMEN_DESTINATARIO_DNI en el .env del bot y '
            'reiniciar (npm restart). El próximo heartbeat refleja el cambio.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }

  String _etiquetaTipo(String key) {
    switch (key) {
      case 'serviceDiario':
        return 'Resumen diario de service';
      case 'alertasVolvoDiario':
        return 'Resumen diario de alertas Volvo';
      case 'vencimientosChofer':
        return 'Vencimientos del chofer';
      case 'vencimientosVehiculo':
        return 'Vencimientos del vehículo';
      default:
        return key;
    }
  }
}

class _FilaReglaNotif extends StatelessWidget {
  final String titulo;
  final String descripcion;
  /// Puede ser un DNI numérico, "CHOFER_AFECTADO", "CHOFER_ASIGNADO" o
  /// vacío si no está configurado.
  final String destinatarioDni;

  const _FilaReglaNotif({
    required this.titulo,
    required this.descripcion,
    required this.destinatarioDni,
  });

  bool get _esDinamico =>
      destinatarioDni == 'CHOFER_AFECTADO' ||
      destinatarioDni == 'CHOFER_ASIGNADO';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            titulo,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (descripcion.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                descripcion,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ),
          const SizedBox(height: 4),
          if (destinatarioDni.isEmpty)
            const _BadgeDestinatario(
              icono: Icons.warning_amber_outlined,
              texto: 'No configurado en .env',
              color: AppColors.warning,
            )
          else if (_esDinamico)
            _BadgeDestinatario(
              icono: Icons.person_outline,
              texto: destinatarioDni == 'CHOFER_AFECTADO'
                  ? 'Al chofer dueño del documento'
                  : 'Al chofer asignado al vehículo',
              color: AppColors.accentBlue,
            )
          else
            _DniResolver(dni: destinatarioDni),
        ],
      ),
    );
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
              : AppColors.accentGreen,
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              style: TextStyle(
                color: color,
                fontSize: 11,
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
            color: autoAvisos ? AppColors.success : Colors.white54),
        _Fila('Respuestas automáticas',
            autoResp ? 'Activas' : 'Desactivadas',
            color: autoResp ? AppColors.success : Colors.white54),
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
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bug_report_outlined,
                  color: AppColors.error, size: 18),
              const SizedBox(width: 8),
              Text(
                'Errores recientes (${errores.length})',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
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
              const SizedBox(width: 8),
              Text(
                cuando == null ? '—' : _hace(cuando),
                style: const TextStyle(
                  color: Colors.white54,
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
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
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
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: AppColors.accentGreen, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  titulo,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              if (mostrarChevron)
                const Text(
                  'TOCAR PARA VER',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 9,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
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
    this.color = Colors.white70,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final contenido = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Text(
            valor,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right,
                size: 16, color: Colors.white38),
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
            const SizedBox(height: 16),
            Text(
              texto,
              textAlign: TextAlign.center,
              style: TextStyle(color: color, fontSize: 14),
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
        return AppCard(
          padding: const EdgeInsets.all(14),
          borderColor: pausado ? AppColors.warning.withAlpha(160) : null,
          highlighted: pausado,
          child: Row(
            children: [
              Icon(
                pausado ? Icons.pause_circle_filled : Icons.power_settings_new,
                color: pausado ? AppColors.warning : AppColors.success,
                size: 28,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pausado ? 'Bot pausado por admin' : 'Bot operando normal',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: pausado ? AppColors.warning : Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      pausado
                          ? (motivo.isEmpty
                              ? 'No envía mensajes hasta reanudar.'
                              : 'Motivo: $motivo')
                          : 'Tocá el toggle para pausar el envío.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: pausado,
                activeThumbColor: AppColors.warning,
                onChanged: (nuevoValor) =>
                    _confirmarYTogglear(context, pausado, nuevoValor),
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
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('CANCELAR'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor:
                  nuevoValor ? AppColors.warning : AppColors.success,
            ),
            onPressed: () => Navigator.pop(dCtx, true),
            child: Text(accion),
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
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error al actualizar control: $e');
    }
  }
}
