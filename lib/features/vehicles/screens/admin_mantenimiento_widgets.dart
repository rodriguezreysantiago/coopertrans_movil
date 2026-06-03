// =============================================================================
// COMPONENTES Y MODELOS de la pantalla de mantenimiento — extraídos para
// mantener navegable el screen principal. Comparten privacidad via `part of`.
//
// REFACTOR NÚCLEO · jun 2026 — el tablero pasa a lenguaje bento:
//   ┌─ Header: eyebrow MANTENIMIENTO · hero (flota total) · KpiStrip por ─┐
//   │           urgencia · chips de filtro por estado · buscador          │
//   └─ Lista bento: AppCard por tractor (AppDot estado + patente + km) ────┘
//
// SOLO PRESENTACIÓN. Se preserva intacto el resolver de serviceDistance
// (API > MANUAL > NINGUNO), el modelo `_Resumen`, la clasificación de estado
// (`AppMantenimiento.clasificar`) y la navegación al detalle.
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
// HEADER NÚCLEO · eyebrow + hero + KpiStrip + chips de filtro + buscador
// =============================================================================

/// Encabezado del tablero, estilo Personal/Flota: `AppEyebrow`
/// ("MANTENIMIENTO") + número hero (total de la flota) + `AppKpiStrip`
/// con el desglose por urgencia (vencidos · urgentes · programar · OK) +
/// fila de `AppFilterChip` para filtrar por estado + buscador `AppInput`.
///
/// Los contadores son GLOBALES (sobre toda la flota visible), no sobre el
/// resultado filtrado — así el admin ve cuántos hay en cada estado aunque
/// tenga un filtro activo. La lógica de toggle vive en el State del screen.
class _HeaderMantenimiento extends StatelessWidget {
  final int total;
  final _Resumen resumen;
  final MantenimientoEstado? filtroActivo;
  final ValueChanged<MantenimientoEstado> onSeleccionar;
  final TextEditingController searchCtl;
  final bool tieneTexto;
  final VoidCallback onLimpiar;

  const _HeaderMantenimiento({
    required this.total,
    required this.resumen,
    required this.filtroActivo,
    required this.onSeleccionar,
    required this.searchCtl,
    required this.tieneTexto,
    required this.onLimpiar,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final atencion = resumen.programar + resumen.atencion;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppEyebrow('MANTENIMIENTO'),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$total',
                style: AppType.h2.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('tractores', style: AppType.monoSm),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // KPIs por urgencia. "Vencidos" y "Urgentes" se tintan cuando hay
          // alguno (la señal crítica del tablero). "A programar" agrupa
          // programar + falta-poco. "OK" en verde si todos al día.
          AppKpiStrip(
            stats: [
              AppStat(
                label: 'Vencidos',
                value: '${resumen.vencidos}',
                accent: resumen.vencidos > 0 ? c.error : null,
              ),
              AppStat(
                label: 'Urgentes',
                value: '${resumen.urgentes}',
                accent: resumen.urgentes > 0 ? c.warning : null,
              ),
              AppStat(
                label: 'A programar',
                value: '$atencion',
              ),
              AppStat(
                label: 'Al día',
                value: '${resumen.ok}',
                accent: resumen.ok > 0 ? c.success : null,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Chips de filtro por estado. El contador de cada chip es el
          // conteo global de ese estado. Tap toggle (mismo estado limpia).
          // Scroll horizontal: con 6 estados no entran en mobile.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _ChipEstado(
                  label: 'Vencidos',
                  count: resumen.vencidos,
                  estado: MantenimientoEstado.vencido,
                  activo: filtroActivo == MantenimientoEstado.vencido,
                  onTap: onSeleccionar,
                ),
                const SizedBox(width: 6),
                _ChipEstado(
                  label: 'Urgentes',
                  count: resumen.urgentes,
                  estado: MantenimientoEstado.urgente,
                  activo: filtroActivo == MantenimientoEstado.urgente,
                  onTap: onSeleccionar,
                ),
                const SizedBox(width: 6),
                _ChipEstado(
                  label: 'Programar',
                  count: resumen.programar,
                  estado: MantenimientoEstado.programar,
                  activo: filtroActivo == MantenimientoEstado.programar,
                  onTap: onSeleccionar,
                ),
                const SizedBox(width: 6),
                _ChipEstado(
                  label: 'Falta poco',
                  count: resumen.atencion,
                  estado: MantenimientoEstado.atencion,
                  activo: filtroActivo == MantenimientoEstado.atencion,
                  onTap: onSeleccionar,
                ),
                const SizedBox(width: 6),
                _ChipEstado(
                  label: 'Al día',
                  count: resumen.ok,
                  estado: MantenimientoEstado.ok,
                  activo: filtroActivo == MantenimientoEstado.ok,
                  onTap: onSeleccionar,
                ),
                if (resumen.sinDato > 0) ...[
                  const SizedBox(width: 6),
                  _ChipEstado(
                    label: 'Sin datos',
                    count: resumen.sinDato,
                    estado: MantenimientoEstado.sinDato,
                    activo: filtroActivo == MantenimientoEstado.sinDato,
                    onTap: onSeleccionar,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppInput(
            controller: searchCtl,
            hint: 'Buscar patente, marca o modelo…',
            icon: Icons.search,
            trailingAction: tieneTexto ? 'Limpiar' : null,
            onTrailingTap: tieneTexto ? onLimpiar : null,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

/// Chip de filtro por estado de mantenimiento. Envuelve `AppFilterChip`
/// (look Núcleo) y traduce su `onTap` al estado de este chip.
class _ChipEstado extends StatelessWidget {
  final String label;
  final int count;
  final MantenimientoEstado estado;
  final bool activo;
  final ValueChanged<MantenimientoEstado> onTap;

  const _ChipEstado({
    required this.label,
    required this.count,
    required this.estado,
    required this.activo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppFilterChip(
      label: label,
      count: count,
      activo: activo,
      onTap: () => onTap(estado),
    );
  }
}

// =============================================================================
// CARD DE TRACTOR (bento)
// =============================================================================

class _TractorCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _TractorCard({required this.doc});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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

    // Color semántico del estado (extension MantenimientoEstadoX). El
    // estado `atencion` usa lima/limón fuera de paleta — para "Falta poco"
    // lo dejamos en warning para no romper la regla de tinta única.
    final estadoColor = switch (estado) {
      MantenimientoEstado.vencido => c.error,
      MantenimientoEstado.urgente => c.warning,
      MantenimientoEstado.programar => c.warning,
      MantenimientoEstado.atencion => c.warning,
      MantenimientoEstado.ok => c.success,
      MantenimientoEstado.sinDato => c.textMuted,
    };

    final marcaModelo = '$marca $modelo'.trim();

    return AppCard(
      tier: 1,
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
          // Punto de estado semántico Núcleo (reemplaza el avatar circular).
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: AppDot(estadoColor, size: 8),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(
                        patente,
                        style: AppType.mono.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    MantenimientoBadge(serviceDistanceKm: serviceDistanceKm),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  marcaModelo.isEmpty ? 'Sin marca/modelo' : marcaModelo,
                  style: AppType.bodySm.copyWith(color: c.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  estado.etiqueta.toUpperCase(),
                  style: AppType.eyebrow.copyWith(color: estadoColor),
                ),
                if (faltaCargaInicial) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Cargá el último service desde la ficha para ver KM al próximo',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.bodySm.copyWith(color: c.textMuted),
                  ),
                ] else if (ultimoServiceKm != null ||
                    ultimoServiceFecha != null ||
                    kmRecorridos != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _formatearUltimoService(
                      km: ultimoServiceKm,
                      fecha: ultimoServiceFecha,
                      kmRecorridos: kmRecorridos,
                      fuenteManual: ultimoServiceFuenteManual,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.monoSm.copyWith(color: c.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(Icons.chevron_right, color: c.textMuted, size: 18),
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
      partes.add('$prefijo${AppFormatters.formatearMiles(km)} km');
    }
    if (kmRecorridos != null) {
      partes.add('${AppFormatters.formatearMiles(kmRecorridos)} km recorridos');
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
}

// =============================================================================
// RESUMEN AGREGADO (alimenta el KpiStrip y los chips del header)
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
