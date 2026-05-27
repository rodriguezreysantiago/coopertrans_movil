// =============================================================================
// COMPONENTES VISUALES de "Mi Equipo" (chofer) — extraídos para mantener
// navegable el screen principal. Comparten privacidad via `part of`.
// =============================================================================

part of 'user_mi_equipo_screen.dart';

// =============================================================================
// SECCIÓN DE UNA UNIDAD (TRACTOR o ENGANCHE)
// =============================================================================

class _SeccionUnidad extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final String patente;
  final List<QueryDocumentSnapshot> solicitudes;
  final String claveSolicitud;
  final String nombreChofer;
  final String dni;

  const _SeccionUnidad({
    required this.titulo,
    required this.icono,
    required this.patente,
    required this.solicitudes,
    required this.claveSolicitud,
    required this.nombreChofer,
    required this.dni,
  });

  @override
  Widget build(BuildContext context) {
    // Filtro por campo + estado=PENDIENTE. El admin BORRA el doc al
    // aprobar/rechazar (revision_service.dart:399), así que en teoría
    // todos están pendientes — defensa explícita por si en el futuro
    // se conserva histórico. Cast defensivo: si shape inválido,
    // descartar en silencio en lugar de crashear.
    final solicitudPendiente = solicitudes.where((s) {
      final data = s.data();
      if (data is! Map<String, dynamic>) return false;
      final estado = (data['estado'] ?? 'PENDIENTE').toString();
      return data['campo'] == claveSolicitud && estado == 'PENDIENTE';
    }).toList();

    final tienePendiente = solicitudPendiente.isNotEmpty;
    final estaVacia =
        patente.isEmpty || patente == '-' || patente == 'SIN ASIGNAR';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header de la sección
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                titulo,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.success,
                  letterSpacing: 2,
                ),
              ),
              if (!estaVacia && !tienePendiente)
                // Santiago 2026-05-21: el chofer YA NO elige la unidad (antes
                // abría una lista de unidades libres y la gente la usaba para
                // pedir cambios viendo qué había libre). Ahora solo REPORTA
                // "esta no es mi unidad" → flag a Revisiones; el admin asigna
                // la unidad correcta en el momento.
                TextButton.icon(
                  onPressed: () => _ReporteUnidad.reportar(
                    context,
                    titulo: titulo,
                    patenteActual: patente,
                    nombreChofer: nombreChofer,
                    dni: dni,
                  ),
                  icon: const Icon(Icons.report_problem_outlined,
                      size: 16, color: AppColors.accentOrange),
                  label: const Text(
                    'ESTA NO ES MI UNIDAD',
                    style: TextStyle(
                      color: AppColors.accentOrange,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Contenido según estado
        if (tienePendiente)
          _CardEnRevision(solicitud: solicitudPendiente.first)
        else if (estaVacia)
          const _CardSinAsignacion()
        else
          _CardUnidad(patente: patente, icono: icono),
      ],
    );
  }
}

// =============================================================================
// CARDS DE LAS DISTINTAS SITUACIONES
// =============================================================================

/// Card que muestra cuando hay una solicitud de cambio en revisión.
class _CardEnRevision extends StatelessWidget {
  final QueryDocumentSnapshot solicitud;
  const _CardEnRevision({required this.solicitud});

  @override
  Widget build(BuildContext context) {
    // Cast defensivo (consistente con _SeccionUnidad). Si por algún
    // motivo el doc está corrupto, mostramos un placeholder en lugar
    // de crashear.
    final raw = solicitud.data();
    if (raw is! Map<String, dynamic>) {
      return const AppCard(
        child: Text('Solicitud con formato inválido. Avisá a la oficina.',
            style: TextStyle(color: Colors.white70)),
      );
    }
    final data = raw;
    final patenteSolicitada = (data['patente'] ?? '').toString().trim();
    // Flujo nuevo (2026-05-21): el chofer reporta sin elegir unidad → patente
    // vacío. Mostramos el aviso de "la oficina asignará". Si por compat hay una
    // patente (solicitudes viejas), seguimos mostrando "CAMBIO A X".
    final titulo = patenteSolicitada.isEmpty
        ? 'REPORTASTE QUE NO ES TU UNIDAD'
        : 'CAMBIO A $patenteSolicitada';
    final subtitulo = patenteSolicitada.isEmpty
        ? 'La oficina va a asignarte la unidad correcta.'
        : 'VALIDACIÓN PENDIENTE...';

    return AppCard(
      highlighted: true,
      borderColor: AppColors.accentOrange.withAlpha(150),
      child: Row(
        children: [
          const Icon(Icons.history_toggle_off,
              color: AppColors.accentOrange, size: 30),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitulo,
                  style: const TextStyle(
                    color: AppColors.accentOrange,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CardSinAsignacion extends StatelessWidget {
  const _CardSinAsignacion();

  @override
  Widget build(BuildContext context) {
    return const AppCard(
      child: Row(
        children: [
          Icon(Icons.info_outline, color: Colors.white24),
          SizedBox(width: 12),
          Text(
            'Sin unidad asignada',
            style: TextStyle(color: Colors.white38, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// Card de la unidad asignada con sus datos y vencimientos.
class _CardUnidad extends StatelessWidget {
  final String patente;
  final IconData icono;

  const _CardUnidad({required this.patente, required this.icono});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .doc(patente)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return AppCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Error cargando $patente: ${snap.error}',
                style: const TextStyle(color: AppColors.accentRed),
              ),
            ),
          );
        }
        if (!snap.hasData || !snap.data!.exists) {
          return const _CardSinAsignacion();
        }
        // Cast defensivo (consistente con el resto de la app).
        final raw = snap.data!.data();
        if (raw is! Map<String, dynamic>) {
          return const _CardSinAsignacion();
        }
        final v = raw;

        return AppCard(
          padding: EdgeInsets.zero,
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              // Header con patente grande + telemetría JUSTO ABAJO.
              // Antes la telemetría iba debajo de marca/modelo y se
              // perdía. Pedido Santiago 2026-05-14: el chofer va a
              // querer ver primero combustible/autonomía/odómetro,
              // que es la info viva del día. Marca/modelo es contexto
              // de menor prioridad — lo movemos abajo.
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  children: [
                    Icon(icono, color: Colors.white70, size: 32),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        patente.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 24,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white10, height: 1),
              // Telemetría arriba — info más útil del día a día. Si la
              // unidad no reporta (no-Volvo / sin sync), no se renderiza.
              _BloqueTelemetria(data: v),
              // Marca + modelo como subtítulo discreto (contexto, no
              // info principal).
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${(v['MARCA'] ?? 'S/D')} · ${(v['MODELO'] ?? 'S/D')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Resumen de vencimientos (sustituye la lista completa).
              // Antes se duplicaba contra MIS VENCIMIENTOS — pedido
              // Santiago 2026-05-14: en MI EQUIPO solo el resumen
              // (cuántos OK / cuántos próximos / cuántos vencidos),
              // y un link a MIS VENCIMIENTOS para ver el detalle.
              const Divider(color: Colors.white10, height: 1),
              _ResumenVencimientosEquipo(data: v),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

/// Resumen compacto de los vencimientos del equipo: contadores por
/// estado (vencido, crítico, próximo, OK) en una sola fila + texto
/// que invita a ir a MIS VENCIMIENTOS para el detalle. Reemplaza la
/// lista completa de _FilaVencimiento que se duplicaba con la otra
/// pantalla (Santiago 2026-05-14).
class _ResumenVencimientosEquipo extends StatelessWidget {
  final Map<String, dynamic> data;
  const _ResumenVencimientosEquipo({required this.data});

  @override
  Widget build(BuildContext context) {
    final tipo = (data['TIPO'] ?? '').toString();
    final specs = AppVencimientos.forTipo(tipo);

    int vencidos = 0;
    int criticos = 0;
    int proximos = 0;
    int ok = 0;
    int sinFecha = 0;

    for (final spec in specs) {
      final fecha = data[spec.campoFecha]?.toString();
      final tieneFecha = fecha != null && fecha.isNotEmpty;
      final dias = tieneFecha
          ? AppFormatters.calcularDiasRestantes(fecha)
          : null;
      final estado = calcularEstadoVencimiento(dias, tieneFecha: tieneFecha);
      switch (estado) {
        case VencimientoEstado.vencido:
        case VencimientoEstado.invalida:
          vencidos++;
          break;
        case VencimientoEstado.critico:
          criticos++;
          break;
        case VencimientoEstado.proximo:
          proximos++;
          break;
        case VencimientoEstado.ok:
          ok++;
          break;
        case VencimientoEstado.sinFecha:
          sinFecha++;
          break;
      }
    }

    final total = specs.length;
    if (total == 0) return const SizedBox.shrink();

    // Un mini chip por categoría que tenga > 0.
    final chips = <Widget>[
      if (vencidos > 0)
        _ChipResumen(
          texto: '$vencidos vencido${vencidos == 1 ? "" : "s"}',
          color: AppColors.accentRed,
        ),
      if (criticos > 0)
        _ChipResumen(
          texto: '$criticos por vencer',
          color: AppColors.accentOrange,
        ),
      if (proximos > 0)
        _ChipResumen(
          texto: '$proximos próximo${proximos == 1 ? "" : "s"}',
          color: AppColors.accentAmber,
        ),
      if (ok > 0)
        _ChipResumen(
          texto: '$ok OK',
          color: AppColors.success,
        ),
      if (sinFecha > 0)
        _ChipResumen(
          texto: '$sinFecha sin fecha',
          color: Colors.white38,
        ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'PAPELES DEL EQUIPO',
                style: TextStyle(
                  color: AppColors.success,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '($total)',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: chips),
          const SizedBox(height: 8),
          const Text(
            'Mirá el detalle en "Mis Vencimientos".',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipResumen extends StatelessWidget {
  final String texto;
  final Color color;
  const _ChipResumen({required this.texto, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        texto,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Bloque de telemetría en vivo del vehículo: nivel de combustible y
/// autonomía estimada. Lee los campos `NIVEL_COMBUSTIBLE` y `AUTONOMIA_KM`
/// que la CF `estadoVolvoPoller` (cada 5 min) mergea a VEHICULOS desde
/// VOLVO_ESTADO (que es la fuente fresca de Volvo Connect API).
///
/// Si la unidad no reporta esos datos (marca no-Volvo, telemetría
/// desconectada, sincronización vieja), el bloque entero no se muestra
/// para no llenar la UI con "—" sin sentido.
class _BloqueTelemetria extends StatelessWidget {
  final Map<String, dynamic> data;

  const _BloqueTelemetria({required this.data});

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  @override
  Widget build(BuildContext context) {
    // La telemetría aplica SOLO a tractores: los enganches (bateas,
    // tolvas, bivuelcos, tanques) no tienen motor ni computadora a
    // bordo, así que no reportan odómetro, combustible ni autonomía.
    final tipo = (data['TIPO'] ?? '').toString().toUpperCase();
    if (tipo != 'TRACTOR' && tipo != 'CHASIS') {
      return const SizedBox.shrink();
    }

    final fuel = _toDouble(data['NIVEL_COMBUSTIBLE']);
    final auton = _toDouble(data['AUTONOMIA_KM']);
    final km = _toDouble(data['KM_ACTUAL']);

    // Tratamos el odómetro 0 como "no hay lectura todavía" (cualquier
    // tractor en operación tiene km > 0; el 0 viene del valor inicial
    // que se setea al crear el vehículo).
    final mostrarKm = km != null && km > 0;

    // Si no tenemos NINGÚN dato útil, no renderizamos nada.
    if (fuel == null && auton == null && !mostrarKm) {
      return const SizedBox.shrink();
    }

    // Staleness check — si la última lectura tiene más de 60 min, los
    // datos pueden estar desactualizados. Mostramos un texto chico
    // debajo para que el chofer no confíe ciegamente en una autonomía
    // calculada hace 8 horas. Pedido Santiago 2026-05-14.
    final ultimaLectura =
        (data['ULTIMA_LECTURA_COMBUSTIBLE'] as Timestamp?)?.toDate();
    String? hintStaleness;
    if (ultimaLectura != null) {
      final dur = DateTime.now().difference(ultimaLectura);
      if (dur.inMinutes < 5) {
        hintStaleness = 'Actualizado hace un momento';
      } else if (dur.inMinutes < 60) {
        hintStaleness = 'Actualizado hace ${dur.inMinutes} min';
      } else if (dur.inHours < 24) {
        hintStaleness = '⚠ Última actualización hace ${dur.inHours} h';
      } else {
        hintStaleness = '⚠ Sin datos hace ${dur.inDays} día(s)';
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Column(
        children: [
          Row(
            children: [
              // Números con separador de miles AR (1.205.073 km) — sin
              // formato eran ilegibles a partir de 6 dígitos. Pedido
              // Santiago 2026-05-14.
              if (mostrarKm)
                Expanded(
                  child: _DatoTelemetria(
                    icono: Icons.speed,
                    color: Colors.white70,
                    valor: '${AppFormatters.formatearMiles(km.toInt())} km',
                    etiqueta: 'ODÓMETRO',
                  ),
                ),
              if (fuel != null)
                Expanded(
                  child: _DatoCombustible(porcentaje: fuel),
                ),
              if (auton != null)
                Expanded(
                  child: _DatoTelemetria(
                    icono: Icons.route,
                    color: AppColors.accentCyan,
                    valor: '${AppFormatters.formatearMiles(auton.toInt())} km',
                    etiqueta: 'AUTONOMÍA',
                  ),
                ),
            ],
          ),
          if (hintStaleness != null) ...[
            const SizedBox(height: 8),
            Text(
              hintStaleness,
              style: TextStyle(
                color: hintStaleness.startsWith('⚠')
                    ? AppColors.accentAmber
                    : Colors.white38,
                fontSize: 10,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DatoTelemetria extends StatelessWidget {
  final IconData icono;
  final Color color;
  final String valor;
  final String etiqueta;

  const _DatoTelemetria({
    required this.icono,
    required this.color,
    required this.valor,
    required this.etiqueta,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icono, color: color, size: 22),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            valor,
            maxLines: 1,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          etiqueta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}

/// Muestra el % de combustible con una barra horizontal. Cambia de color
/// según el nivel: verde > 50%, naranja 20-50%, rojo < 20%.
class _DatoCombustible extends StatelessWidget {
  final double porcentaje;

  const _DatoCombustible({required this.porcentaje});

  Color get _color {
    if (porcentaje >= 50) return AppColors.success;
    if (porcentaje >= 20) return AppColors.accentOrange;
    return AppColors.accentRed;
  }

  @override
  Widget build(BuildContext context) {
    final pct = porcentaje.clamp(0.0, 100.0);
    return Column(
      children: [
        Icon(Icons.local_gas_station, color: _color, size: 22),
        const SizedBox(height: 6),
        Text(
          '${pct.toStringAsFixed(0)}%',
          style: TextStyle(
            color: _color,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 4),
        // Barra horizontal mini que refuerza visualmente el nivel.
        SizedBox(
          width: 60,
          height: 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: pct / 100,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(_color),
            ),
          ),
        ),
      ],
    );
  }
}

// `_FilaVencimiento` removido el 2026-05-14. La lista completa de
// vencimientos del equipo se reemplazó por `_ResumenVencimientosEquipo`
// para evitar duplicación contra la pantalla MIS VENCIMIENTOS.

// =============================================================================
// REPORTE "ESTA NO ES MI UNIDAD" — el chofer NO elige unidad: solo flaguea a
// Revisiones y el admin le asigna la unidad correcta (Santiago 2026-05-21).
// Antes abría una lista de unidades LIBRES y la gente la usaba para "pedir"
// cambios mirando qué había disponible.
// =============================================================================

class _ReporteUnidad {
  _ReporteUnidad._();

  static Future<void> reportar(
    BuildContext context, {
    required String titulo,
    required String patenteActual,
    required String nombreChofer,
    required String dni,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final esTractor = titulo.contains('TRACTOR');

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('¿Esta no es tu unidad?'),
        content: Text(
          'Le vas a avisar a la oficina que el '
          '${esTractor ? "tractor" : "enganche"} $patenteActual NO es el que '
          'manejás. La oficina lo revisa y te asigna la unidad correcta — '
          'vos no la elegís.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.accentOrange),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sí, avisar a la oficina'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final cleanDni = dni.trim();
    if (cleanDni.isEmpty) {
      AppFeedback.errorOn(messenger,
          'No se pudo enviar el aviso (faltan datos del chofer). Cerrá la app y volvé a iniciar sesión.');
      return;
    }

    try {
      // `patente` VACÍO a propósito: el chofer no elige. El admin asigna la
      // unidad al aprobar la revisión (ver admin_revisiones_screen).
      await FirebaseFirestore.instance
          .collection(AppCollections.revisiones)
          .add({
        'dni': cleanDni,
        'nombre_usuario': nombreChofer,
        'etiqueta': 'NO ES MI ${esTractor ? "UNIDAD" : "ENGANCHE"}',
        'campo': esTractor ? 'SOLICITUD_VEHICULO' : 'SOLICITUD_ENGANCHE',
        'patente': '',
        'unidad_actual': patenteActual.trim(),
        'fecha_vencimiento': '2026-12-31',
        'tipo_solicitud': 'CAMBIO_EQUIPO',
        'coleccion_destino': 'EMPLEADOS',
        'url_archivo': '',
        'estado': 'PENDIENTE',
        'fecha_solicitud': FieldValue.serverTimestamp(),
      });

      if (!context.mounted) return;
      AppFeedback.warningOn(messenger,
          'Aviso enviado. La oficina te va a asignar la unidad correcta.');
    } catch (e, s) {
      if (!context.mounted) return;
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo enviar el aviso. Probá de nuevo en un momento.',
        tecnico: e,
        stack: s,
      );
    }
  }
}
