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

/// Cards-filtro del tablero de Mantenimiento (Santiago 2026-06-10). Cada una
/// agrupa 0+ estados de urgencia (`estados == null` = TODOS). A PROGRAMAR
/// junta `programar` + `atencion` (falta poco), igual que la card del tablero
/// viejo. Reemplazan al KpiStrip no-interactivo + los chips por estado.
enum _CardMant {
  todos('Todos', null),
  vencidos('Vencidos', {MantenimientoEstado.vencido}),
  urgentes('Urgentes', {MantenimientoEstado.urgente}),
  aProgramar('A programar',
      {MantenimientoEstado.programar, MantenimientoEstado.atencion}),
  alDia('Al día', {MantenimientoEstado.ok}),
  sinDatos('Sin datos', {MantenimientoEstado.sinDato});

  const _CardMant(this.label, this.estados);
  final String label;
  final Set<MantenimientoEstado>? estados;
}

/// Encabezado del tablero: `AppEyebrow` ("MANTENIMIENTO") + strip de CARDS-
/// FILTRO por estado + buscador. Los conteos son GLOBALES (sobre toda la flota
/// visible), no sobre el resultado filtrado. Se quitó el número del hero, que
/// repetía la card TODOS.
class _HeaderMantenimiento extends StatelessWidget {
  final int total;
  final _Resumen resumen;
  final _CardMant cardActiva;
  final ValueChanged<_CardMant> onCard;
  final TextEditingController searchCtl;
  final bool tieneTexto;
  final VoidCallback onLimpiar;

  const _HeaderMantenimiento({
    required this.total,
    required this.resumen,
    required this.cardActiva,
    required this.onCard,
    required this.searchCtl,
    required this.tieneTexto,
    required this.onLimpiar,
  });

  @override
  Widget build(BuildContext context) {
    final esDesktop = AppBreakpoints.isDesktopOrLarger(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppEyebrow('MANTENIMIENTO'),
          const SizedBox(height: AppSpacing.md),
          // Cards-filtro por estado: TODOS · VENCIDOS · URGENTES · A PROGRAMAR
          // (programar + falta poco) · AL DÍA · SIN DATOS. Tocar una filtra; la
          // activa se resalta. Default TODOS (ves toda la flota).
          _StripCardsMant(
            esDesktop: esDesktop,
            total: total,
            resumen: resumen,
            cardActiva: cardActiva,
            onCard: onCard,
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

/// Strip de cards-filtro de Mantenimiento (estética AppKpiStrip pero
/// tappeable). El número de cada card lleva el color de su urgencia
/// (vencidos rojo, urgentes ámbar, al día verde). Desktop: Expanded; mobile:
/// scroll horizontal.
class _StripCardsMant extends StatelessWidget {
  final bool esDesktop;
  final int total;
  final _Resumen resumen;
  final _CardMant cardActiva;
  final ValueChanged<_CardMant> onCard;
  const _StripCardsMant({
    required this.esDesktop,
    required this.total,
    required this.resumen,
    required this.cardActiva,
    required this.onCard,
  });

  int _count(_CardMant card) {
    switch (card) {
      case _CardMant.todos:
        return total;
      case _CardMant.vencidos:
        return resumen.vencidos;
      case _CardMant.urgentes:
        return resumen.urgentes;
      case _CardMant.aProgramar:
        return resumen.programar + resumen.atencion;
      case _CardMant.alDia:
        return resumen.ok;
      case _CardMant.sinDatos:
        return resumen.sinDato;
    }
  }

  /// Color del número según la urgencia (solo si hay alguno). El resto neutro.
  Color? _accent(_CardMant card, AppColorsExt c) {
    if (_count(card) == 0) return null;
    switch (card) {
      case _CardMant.vencidos:
        return c.error;
      case _CardMant.urgentes:
        return c.warning;
      case _CardMant.alDia:
        return c.success;
      case _CardMant.todos:
      case _CardMant.aProgramar:
      case _CardMant.sinDatos:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final celdas = [
      for (final card in _CardMant.values)
        _CeldaCardMant(
          label: card.label,
          valor: _count(card),
          accent: _accent(card, c),
          seleccionado: cardActiva == card,
          esDesktop: esDesktop,
          onTap: () => onCard(card),
        ),
    ];
    final fila = IntrinsicHeight(
      child: Row(
        children: [
          for (var i = 0; i < celdas.length; i++) ...[
            if (esDesktop) Expanded(child: celdas[i]) else celdas[i],
            if (i < celdas.length - 1) Container(width: 1, color: c.border),
          ],
        ],
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: esDesktop
            ? fila
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal, child: fila),
      ),
    );
  }
}

/// Una celda del strip de Mantenimiento. Tappeable; resalta con tinte brand
/// cuando es la card en foco. El número lleva el color de urgencia (`accent`).
class _CeldaCardMant extends StatelessWidget {
  final String label;
  final int valor;
  final Color? accent;
  final bool seleccionado;
  final bool esDesktop;
  final VoidCallback onTap;
  const _CeldaCardMant({
    required this.label,
    required this.valor,
    required this.accent,
    required this.seleccionado,
    required this.esDesktop,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final contenido = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: esDesktop ? 18 : 14,
        vertical: esDesktop ? 18 : 14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.eyebrow.copyWith(
              color: seleccionado ? c.brand : c.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$valor',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.h2.copyWith(
              color: accent ?? c.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    final celda = ConstrainedBox(
      constraints: BoxConstraints(minWidth: esDesktop ? 0 : 110),
      child: ColoredBox(
        color: seleccionado
            ? c.brand.withValues(alpha: 0.12)
            : Colors.transparent,
        child: contenido,
      ),
    );
    return InkWell(onTap: onTap, child: celda);
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
