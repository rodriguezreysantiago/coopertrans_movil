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
        // Header de la sección — eyebrow neutra (mono uppercase del
        // sistema). Antes era verde+bold+tracking 2; el verde es
        // semántico (estado OK), no identidad de sección.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: AppEyebrow(titulo)),
              if (!estaVacia && !tienePendiente)
                // Santiago 2026-05-21: el chofer YA NO elige la unidad (antes
                // abría una lista de unidades libres y la gente la usaba para
                // pedir cambios viendo qué había libre). Ahora solo REPORTA
                // "esta no es mi unidad" → flag a Revisiones; el admin asigna
                // la unidad correcta en el momento.
                AppButton.ghost(
                  label: 'No es mi unidad',
                  icon: Icons.report_problem_outlined,
                  size: AppButtonSize.sm,
                  onPressed: () => _ReporteUnidad.reportar(
                    context,
                    titulo: titulo,
                    patenteActual: patente,
                    nombreChofer: nombreChofer,
                    dni: dni,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),

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
      return AppCard(
        child: Text('Solicitud con formato inválido. Avisá a la oficina.',
            style: AppType.body.copyWith(color: AppColors.textSecondary)),
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
      borderColor: AppColors.warning.withAlpha(150),
      child: Row(
        children: [
          const Icon(Icons.history_toggle_off,
              color: AppColors.warning, size: 30),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo, style: AppType.heading),
                const SizedBox(height: AppSpacing.xs),
                AppEyebrow(subtitulo, color: AppColors.warning),
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
    return AppCard(
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppColors.textTertiary),
          const SizedBox(width: AppSpacing.md),
          Text(
            'Sin unidad asignada',
            style: AppType.body.copyWith(color: AppColors.textTertiary),
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
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(
                'Error cargando $patente: ${snap.error}',
                style: AppType.body.copyWith(color: AppColors.error),
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
              // Hero de la unidad — layout Núcleo (proto "Unidad"):
              // eyebrow "Asignada" + patente grande (display) + marca/
              // modelo como subtítulo mono discreto. La telemetría va
              // JUSTO ABAJO (pedido Santiago 2026-05-14): el chofer
              // quiere ver primero combustible/autonomía/odómetro, la
              // info viva del día. Marca/modelo es contexto secundario.
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(icono, color: AppColors.textTertiary, size: 32),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AppEyebrow('Asignada'),
                          const SizedBox(height: AppSpacing.xs),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              patente.toUpperCase(),
                              maxLines: 1,
                              style: AppType.h3.copyWith(
                                color: AppColors.brandSoft,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            '${(v['MARCA'] ?? 'S/D')} · ${(v['MODELO'] ?? 'S/D')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.monoSm,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const AppHairline(color: AppColors.borderSubtle),
              // Telemetría arriba — info más útil del día a día. Si la
              // unidad no reporta (no-Volvo / sin sync), no se renderiza.
              _BloqueTelemetria(data: v),
              // Resumen de vencimientos (sustituye la lista completa).
              // Antes se duplicaba contra MIS VENCIMIENTOS — pedido
              // Santiago 2026-05-14: en MI EQUIPO solo el resumen
              // (cuántos OK / cuántos próximos / cuántos vencidos),
              // y un link a MIS VENCIMIENTOS para ver el detalle.
              const AppHairline(color: AppColors.borderSubtle),
              _ResumenVencimientosEquipo(data: v),
              const SizedBox(height: AppSpacing.sm),
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
          color: AppColors.error,
        ),
      if (criticos > 0)
        _ChipResumen(
          texto: '$criticos por vencer',
          color: AppColors.warning,
        ),
      if (proximos > 0)
        _ChipResumen(
          texto: '$proximos próximo${proximos == 1 ? "" : "s"}',
          color: AppColors.warning,
        ),
      if (ok > 0)
        _ChipResumen(
          texto: '$ok OK',
          color: AppColors.success,
        ),
      if (sinFecha > 0)
        _ChipResumen(
          texto: '$sinFecha sin fecha',
          color: AppColors.textTertiary,
        ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppEyebrow('Vencimientos de la unidad'),
              const SizedBox(width: AppSpacing.xs),
              Text('($total)', style: AppType.monoSm),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(spacing: 6, runSpacing: 6, children: chips),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Mirá el detalle en "Mis Vencimientos".',
            style: AppType.monoSm.copyWith(fontStyle: FontStyle.italic),
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
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        texto,
        style: AppType.monoSm.copyWith(color: color, fontWeight: FontWeight.w600),
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
                    color: AppColors.textSecondary,
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
                    color: AppColors.brand,
                    valor: '${AppFormatters.formatearMiles(auton.toInt())} km',
                    etiqueta: 'AUTONOMÍA',
                  ),
                ),
            ],
          ),
          if (hintStaleness != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              hintStaleness,
              style: AppType.monoSm.copyWith(
                color: hintStaleness.startsWith('⚠')
                    ? AppColors.warning
                    : AppColors.textTertiary,
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
            style: AppType.heading.copyWith(letterSpacing: 0),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          etiqueta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.eyebrow,
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
    if (porcentaje >= 20) return AppColors.warning;
    return AppColors.error;
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
          style: AppType.heading.copyWith(color: _color, letterSpacing: 0),
        ),
        const SizedBox(height: AppSpacing.xs),
        // Barra horizontal mini que refuerza visualmente el nivel.
        SizedBox(
          width: 60,
          height: 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: pct / 100,
              backgroundColor: AppColors.surface3,
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
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.pop(context, false),
          ),
          AppButton(
            label: 'Sí, avisar a la oficina',
            onPressed: () => Navigator.pop(context, true),
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
