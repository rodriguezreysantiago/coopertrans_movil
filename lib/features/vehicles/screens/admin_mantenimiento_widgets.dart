// =============================================================================
// COMPONENTES Y MODELOS de la pantalla de mantenimiento — extraídos para
// mantener navegable el screen principal. Comparten privacidad via `part of`.
// =============================================================================

part of 'admin_mantenimiento_screen.dart';

// =============================================================================
// RESOLUCIÓN DE serviceDistance: API > MANUAL > NINGUNO
// =============================================================================

enum _FuenteServiceDistance { api, manual, ninguno }

/// Resultado del cálculo de `serviceDistance` para un tractor.
/// `km` puede ser negativo (vencido). Si la fuente es `ninguno`, `km` es null.
class _ResolucionServiceDistance {
  final double? km;
  final _FuenteServiceDistance fuente;
  const _ResolucionServiceDistance(this.km, this.fuente);
}

/// Decide qué `serviceDistance` mostrar para un tractor:
/// 1. Si tiene `ULTIMO_SERVICE_KM` cargado manualmente + `KM_ACTUAL` →
///    calcula `(ULTIMO_SERVICE_KM + 50.000) − KM_ACTUAL`.
/// 2. Si NO hay manual pero el doc tiene `SERVICE_DISTANCE_KM` (del
///    API Volvo) → usa eso como fallback.
/// 3. Si nada → ninguno (la pantalla muestra un hint).
///
/// **Por qué manual gana**: el paquete UPTIME del contrato Volvo
/// Connect actual de Vecchi no está activado, y el campo
/// `uptimeData.serviceDistance` que devuelve el API a veces trae
/// valores absurdos (ej. AG218ZD: 642.069 km al próximo service para
/// un tractor con KM_ACTUAL 357.930 que tenía manual −1.500 km, lo
/// cual indicaba que estaba vencido). El admin carga
/// ULTIMO_SERVICE_KM cada vez que pasa por taller, así que ese dato
/// es la fuente más confiable hoy. Si en el futuro Volvo activa el
/// paquete UPTIME y el API se vuelve confiable, podemos volver a
/// invertir la prioridad.
_ResolucionServiceDistance _resolverServiceDistance(
    Map<String, dynamic> data) {
  final manual = AppMantenimiento.serviceDistanceDesdeManual(
    ultimoServiceKm: (data['ULTIMO_SERVICE_KM'] as num?)?.toDouble(),
    kmActual: (data['KM_ACTUAL'] as num?)?.toDouble(),
  );
  if (manual != null) {
    return _ResolucionServiceDistance(manual, _FuenteServiceDistance.manual);
  }
  final api = (data['SERVICE_DISTANCE_KM'] as num?)?.toDouble();
  if (api != null) {
    return _ResolucionServiceDistance(api, _FuenteServiceDistance.api);
  }
  return const _ResolucionServiceDistance(null,
      _FuenteServiceDistance.ninguno);
}

// =============================================================================
// CARD DE TRACTOR
// =============================================================================

class _TractorCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _TractorCard({required this.doc});

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final patente = doc.id;
    final marca = (data['MARCA'] ?? '').toString();
    final modelo = (data['MODELO'] ?? '').toString();
    final kmActual = (data['KM_ACTUAL'] as num?)?.toDouble();
    final manualUltimoKm =
        (data['ULTIMO_SERVICE_KM'] as num?)?.toDouble();

    // serviceDistance "efectivo": prefiere el del API; si no existe,
    // calcula desde ULTIMO_SERVICE_KM (manual) + 50.000 − KM_ACTUAL.
    // Vecchi cae en el segundo caso porque el plan API no entrega
    // `uptimeData.serviceDistance`.
    final servicio = _resolverServiceDistance(data);
    final serviceDistanceKm = servicio.km;
    final fuenteApi = servicio.fuente == _FuenteServiceDistance.api;
    final estado = AppMantenimiento.clasificar(serviceDistanceKm);

    // ─── Último service y km recorridos ──────────────────────────────
    // Si el admin lo cargó manualmente, eso es la verdad. Si no,
    // calculamos desde KM_ACTUAL + serviceDistance API − intervalo.
    // Si vinimos por path manual ya sabemos el último, no hace falta
    // calcularlo otra vez.
    double? ultimoServiceKm;
    bool ultimoServiceFuenteManual = false;
    if (manualUltimoKm != null) {
      ultimoServiceKm = manualUltimoKm;
      ultimoServiceFuenteManual = true;
    } else if (fuenteApi) {
      ultimoServiceKm = AppMantenimiento.calcularKmUltimoService(
        kmActual: kmActual,
        serviceDistanceKm: serviceDistanceKm,
      );
    }

    double? kmRecorridos;
    if (ultimoServiceKm != null && kmActual != null) {
      kmRecorridos = kmActual - ultimoServiceKm;
    }

    // Fecha del último service (solo si la cargó el admin a mano).
    final ultimoServiceFechaRaw =
        data['ULTIMO_SERVICE_FECHA']?.toString() ?? '';
    final ultimoServiceFecha = ultimoServiceFechaRaw.isNotEmpty
        ? AppFormatters.tryParseFecha(ultimoServiceFechaRaw)
        : null;

    // Si no hay datos suficientes (sin API y sin manual cargado), la
    // card muestra un hint para que el admin cargue el último service.
    final faltaCargaInicial =
        servicio.fuente == _FuenteServiceDistance.ninguno;

    return AppCard(
      onTap: () {
        // Abre el detalle de mantenimiento UNIFICADO de la unidad: service +
        // advertencias del tablero + telemetría + historial de taller completo.
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                AdminMantenimientoDetalleScreen(patente: patente),
          ),
        );
      },
      child: Row(
        children: [
          // Avatar con icono según estado.
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: estado.color.withAlpha(25),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _iconoSegunEstado(estado),
              color: estado.color,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  patente,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$marca $modelo'.trim().isEmpty
                      ? 'Sin marca/modelo'
                      : '$marca $modelo',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  estado.etiqueta,
                  style: TextStyle(
                    color: estado.color,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ),
                if (faltaCargaInicial) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'Cargá el último service desde la ficha para ver KM al próximo',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.accentAmber,
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ] else if (ultimoServiceKm != null ||
                    ultimoServiceFecha != null ||
                    kmRecorridos != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _formatearUltimoService(
                      km: ultimoServiceKm,
                      fecha: ultimoServiceFecha,
                      kmRecorridos: kmRecorridos,
                      fuenteManual: ultimoServiceFuenteManual,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MantenimientoBadge(serviceDistanceKm: serviceDistanceKm),
              const SizedBox(height: 6),
              const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
            ],
          ),
        ],
      ),
    );
  }

  /// Formatea "Último service: ~342.000 km · 38.000 km recorridos".
  ///
  /// El "~" antepuesto indica que el dato se infirió a partir de
  /// `KM_ACTUAL + serviceDistance − 50.000`. Si el admin lo cargó a
  /// mano desde la ficha (`fuenteManual: true`), el "~" se omite porque
  /// es dato verificado.
  static String _formatearUltimoService({
    double? km,
    DateTime? fecha,
    double? kmRecorridos,
    bool fuenteManual = false,
  }) {
    final partes = <String>[];
    if (km != null) {
      final prefijo = fuenteManual ? '' : '~';
      partes.add('$prefijo${km.round()} km');
    }
    if (kmRecorridos != null) {
      partes.add('${kmRecorridos.round()} km recorridos');
    }
    if (fecha != null) {
      partes.add(_tiempoRelativo(fecha));
    }
    return 'Último service: ${partes.join(' · ')}';
  }

  /// Devuelve "hoy", "hace X días", "hace X meses", "hace X años".
  static String _tiempoRelativo(DateTime fecha) {
    final dias = DateTime.now().difference(fecha).inDays;
    if (dias < 0) return 'fecha futura';
    if (dias == 0) return 'hoy';
    if (dias == 1) return 'hace 1 día';
    if (dias < 30) return 'hace $dias días';
    if (dias < 60) return 'hace 1 mes';
    if (dias < 365) {
      final meses = (dias / 30).round();
      return 'hace $meses meses';
    }
    final anios = (dias / 365).round();
    return anios == 1 ? 'hace 1 año' : 'hace $anios años';
  }

  IconData _iconoSegunEstado(MantenimientoEstado estado) {
    switch (estado) {
      case MantenimientoEstado.vencido:
        return Icons.warning_amber_rounded;
      case MantenimientoEstado.urgente:
        return Icons.priority_high;
      case MantenimientoEstado.programar:
        return Icons.event_note;
      case MantenimientoEstado.atencion:
        return Icons.schedule;
      case MantenimientoEstado.ok:
        return Icons.check_circle;
      case MantenimientoEstado.sinDato:
        return Icons.help_outline;
    }
  }
}

// =============================================================================
// RESUMEN AGREGADO (chips arriba de la lista)
// =============================================================================

class _Resumen {
  final int vencidos;
  final int urgentes;
  final int programar;
  final int atencion;
  final int ok;
  final int sinDato;

  const _Resumen({
    required this.vencidos,
    required this.urgentes,
    required this.programar,
    required this.atencion,
    required this.ok,
    required this.sinDato,
  });

  factory _Resumen.from(List<QueryDocumentSnapshot> docs) {
    int vencidos = 0, urgentes = 0, programar = 0, atencion = 0, ok = 0;
    int sinDato = 0;
    for (final d in docs) {
      final data = d.data() as Map<String, dynamic>;
      // Mismo resolver que la card: API > manual > ninguno. Mantiene
      // los chips consistentes con cada tarjeta.
      final servicio = _resolverServiceDistance(data);
      switch (AppMantenimiento.clasificar(servicio.km)) {
        case MantenimientoEstado.vencido:
          vencidos++;
          break;
        case MantenimientoEstado.urgente:
          urgentes++;
          break;
        case MantenimientoEstado.programar:
          programar++;
          break;
        case MantenimientoEstado.atencion:
          atencion++;
          break;
        case MantenimientoEstado.ok:
          ok++;
          break;
        case MantenimientoEstado.sinDato:
          sinDato++;
          break;
      }
    }
    return _Resumen(
      vencidos: vencidos,
      urgentes: urgentes,
      programar: programar,
      atencion: atencion,
      ok: ok,
      sinDato: sinDato,
    );
  }
}

class _BarraResumen extends StatelessWidget {
  final _Resumen resumen;
  final MantenimientoEstado? filtroActivo;
  final ValueChanged<MantenimientoEstado> onSeleccionar;
  const _BarraResumen({
    required this.resumen,
    required this.filtroActivo,
    required this.onSeleccionar,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          _Chip(
            label: 'Vencidos',
            count: resumen.vencidos,
            color: AppColors.accentRed,
            estado: MantenimientoEstado.vencido,
            activo: filtroActivo == MantenimientoEstado.vencido,
            onTap: onSeleccionar,
          ),
          _Chip(
            label: 'Urgentes',
            count: resumen.urgentes,
            color: AppColors.accentOrange,
            estado: MantenimientoEstado.urgente,
            activo: filtroActivo == MantenimientoEstado.urgente,
            onTap: onSeleccionar,
          ),
          _Chip(
            label: 'Programar',
            count: resumen.programar,
            color: AppColors.accentAmber,
            estado: MantenimientoEstado.programar,
            activo: filtroActivo == MantenimientoEstado.programar,
            onTap: onSeleccionar,
          ),
          _Chip(
            label: 'Falta poco',
            count: resumen.atencion,
            color: const Color(0xFFC6FF00),
            estado: MantenimientoEstado.atencion,
            activo: filtroActivo == MantenimientoEstado.atencion,
            onTap: onSeleccionar,
          ),
          _Chip(
            label: 'OK',
            count: resumen.ok,
            color: AppColors.success,
            estado: MantenimientoEstado.ok,
            activo: filtroActivo == MantenimientoEstado.ok,
            onTap: onSeleccionar,
          ),
          if (resumen.sinDato > 0)
            _Chip(
              label: 'Sin datos',
              count: resumen.sinDato,
              color: Colors.white24,
              estado: MantenimientoEstado.sinDato,
              activo: filtroActivo == MantenimientoEstado.sinDato,
              onTap: onSeleccionar,
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final MantenimientoEstado estado;
  final bool activo;
  final ValueChanged<MantenimientoEstado> onTap;

  const _Chip({
    required this.label,
    required this.count,
    required this.color,
    required this.estado,
    required this.activo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Cuando el chip esta activo: fondo mas opaco + borde mas grueso
    // y label en blanco/bold para que se note el filtro vigente.
    final fondoAlpha = activo ? 60 : 20;
    final bordeAlpha = activo ? 200 : 60;
    final bordeWidth = activo ? 1.5 : 1.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => onTap(estado),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withAlpha(fondoAlpha),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: color.withAlpha(bordeAlpha),
              width: bordeWidth,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$count',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: activo ? Colors.white : Colors.white70,
                  fontSize: 11,
                  fontWeight:
                      activo ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
