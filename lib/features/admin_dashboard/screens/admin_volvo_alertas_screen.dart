import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/audit_log_service.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../eco_driving/screens/admin_mapa_volvo_screen.dart';
import '../../eco_driving/utils/etiquetas_alerta_volvo.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Pantalla "Alertas Volvo" del admin/supervisor — REFACTOR NÚCLEO (jun 2026).
///
/// Lista los eventos del Vehicle Alerts API que el `volvoAlertasPoller`
/// (scheduled cada 5 min) guarda en `VOLVO_ALERTAS`.
///
/// **Diseño revisado 2026-05-04 (v2)**: por default muestra SOLO las
/// alertas del día actual con paginación de 30 ítems por página.
/// Filtros: severidad (HIGH/MEDIUM/LOW/Todas) + atendida (Pendientes/Todas).
/// Búsqueda por texto sobre patente/tipo/VIN.
///
/// **Reescritura Núcleo**: el árbol de widgets pasa al sistema (eyebrow +
/// hero number + `AppKpiStrip` + chips de filtro `AppFilterChip` + lista densa
/// `AppCard(tier:1)` con `AppBadge` por severidad). La CAPA DE DATOS no cambia:
/// mismo stream `VOLVO_ALERTAS`, mismo `_filtrar`, misma paginación, mismo
/// `_marcarAtendida` (update + AuditLog) y misma navegación al mapa.
///
/// Por qué NO usamos `AppListPage`: ese widget solo invoca el callback
/// `filter` cuando hay query de búsqueda (cortocircuito si query vacío).
/// Acá necesitamos filtros independientes (severidad, pendientes) que
/// se apliquen siempre, así que armamos el body manualmente.
///
/// Query: `where('creado_en', between [startOfDay, endOfDay))` +
/// `orderBy('creado_en', desc)`. Where + orderBy en el MISMO campo →
/// no requiere índice compuesto.
class AdminVolvoAlertasScreen extends StatefulWidget {
  const AdminVolvoAlertasScreen({super.key});

  @override
  State<AdminVolvoAlertasScreen> createState() =>
      _AdminVolvoAlertasScreenState();
}

class _AdminVolvoAlertasScreenState extends State<AdminVolvoAlertasScreen> {
  /// Rango seleccionado. `start == end` (mismo día) representa una
  /// fecha única — la UI lo etiqueta diferente. Default: hoy/hoy.
  late DateTimeRange _rango;

  /// `true` → solo alertas no atendidas. `false` → todas.
  bool _soloPendientes = true;

  /// Filtro por severidad. `null` = todas.
  String? _severidadFiltro;

  /// Página actual (0-indexed). Reset a 0 cuando cambia algún filtro.
  int _pagina = 0;
  static const int _itemsPorPagina = 30;

  /// Texto de búsqueda libre (patente/tipo/VIN).
  final _searchCtl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    final hoy = _truncarDia(DateTime.now());
    _rango = DateTimeRange(start: hoy, end: hoy);
    _searchCtl.addListener(() {
      final nuevo = _searchCtl.text.trim().toUpperCase();
      if (nuevo != _query) {
        setState(() {
          _query = nuevo;
          _pagina = 0;
        });
      }
    });
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  static DateTime _truncarDia(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day);

  Stream<QuerySnapshot> get _alertasStream {
    // Fin EXCLUSIVO: 00:00 del día siguiente al `end`. Eso incluye
    // todo el día end completo en la query `< _hastaTs`.
    final hasta = _rango.end.add(const Duration(days: 1));
    return FirebaseFirestore.instance
        .collection(AppCollections.volvoAlertas)
        .where('creado_en',
            isGreaterThanOrEqualTo: Timestamp.fromDate(_rango.start))
        .where('creado_en', isLessThan: Timestamp.fromDate(hasta))
        .orderBy('creado_en', descending: true)
        .snapshots();
  }

  bool get _esHoy {
    final hoy = _truncarDia(DateTime.now());
    return _rango.start == hoy && _rango.end == hoy;
  }

  bool get _esUnDia => _rango.start == _rango.end;

  String get _etiquetaFecha {
    String fmt(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-${d.year}';
    if (_esHoy) return 'HOY (${fmt(_rango.start)})';
    if (_esUnDia) return fmt(_rango.start);
    return '${fmt(_rango.start)} al ${fmt(_rango.end)}';
  }

  Future<void> _elegirFecha() async {
    final ahora = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _rango,
      firstDate: DateTime(2024),
      lastDate: _truncarDia(ahora),
      helpText: 'Elegir fecha o rango de alertas',
      cancelText: 'Cancelar',
      confirmText: 'Ver',
      saveText: 'Ver',
      locale: const Locale('es', 'AR'),
    );
    if (picked != null && mounted) {
      setState(() {
        _rango = DateTimeRange(
          start: _truncarDia(picked.start),
          end: _truncarDia(picked.end),
        );
        _pagina = 0;
      });
    }
  }

  void _irAHoy() {
    final hoy = _truncarDia(DateTime.now());
    setState(() {
      _rango = DateTimeRange(start: hoy, end: hoy);
      _pagina = 0;
    });
  }

  /// Aplica los filtros (severidad, pendientes, búsqueda) a la lista
  /// completa del día. Se llama en cada rebuild del StreamBuilder.
  List<QueryDocumentSnapshot> _filtrar(List<QueryDocumentSnapshot> docs) {
    return docs.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      if (_soloPendientes && data['atendida'] == true) return false;
      if (_severidadFiltro != null) {
        final sev = (data['severidad'] ?? '').toString().toUpperCase();
        if (sev != _severidadFiltro) return false;
      }
      if (_query.isEmpty) return true;
      // La etiqueta legible se incluye en el texto buscable para que
      // el admin pueda tipear "cinturón", "ralentí", etc. y encontrar
      // alertas — no solo el código crudo del API ("SEATBELT", "IDLING").
      final etiqueta = etiquetaAlertaVolvoFromDoc(data);
      final hay = '${data['patente'] ?? ''} '
              '${data['tipo'] ?? ''} '
              '$etiqueta '
              '${data['vin'] ?? ''} '
              '${data['severidad'] ?? ''}'
          .toUpperCase();
      return hay.contains(_query);
    }).toList();
  }

  /// Conteo por severidad sobre TODA la ventana del día (antes de aplicar
  /// el filtro de severidad/pendientes/búsqueda), para que el KpiStrip
  /// muestre el panorama completo. Solo respeta `_soloPendientes` para que
  /// los números reflejen lo que importa por defecto (lo no atendido).
  ({int high, int medium, int low, int pendientes}) _resumen(
      List<QueryDocumentSnapshot> docs) {
    var high = 0, medium = 0, low = 0, pendientes = 0;
    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      final atendida = data['atendida'] == true;
      if (!atendida) pendientes++;
      final sev = (data['severidad'] ?? '').toString().toUpperCase();
      switch (sev) {
        case 'HIGH':
          high++;
          break;
        case 'MEDIUM':
          medium++;
          break;
        case 'LOW':
          low++;
          break;
      }
    }
    return (high: high, medium: medium, low: low, pendientes: pendientes);
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Alertas Volvo',
      body: StreamBuilder<QuerySnapshot>(
        stream: _alertasStream,
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AppErrorState(subtitle: snap.error.toString());
          }
          if (!snap.hasData) {
            return const AppLoadingState();
          }
          final docsTodos = snap.data!.docs;
          final resumen = _resumen(docsTodos);
          final docsFiltrados = _filtrar(docsTodos);

          // Header + KpiStrip + filtros van SIEMPRE arriba (aunque la lista
          // filtrada quede vacía) para que el admin pueda ajustar filtros.
          final header = _Header(
            totalVisible: docsFiltrados.length,
            resumen: resumen,
            hayDatos: docsTodos.isNotEmpty,
          );
          final buscador = _Buscador(
            controller: _searchCtl,
            query: _query,
            onClear: () => _searchCtl.clear(),
            onMapa: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AdminMapaVolvoScreen(),
              ),
            ),
          );
          final filtros = _BarraFiltros(
            fechaEtiqueta: _etiquetaFecha,
            esHoy: _esHoy,
            soloPendientes: _soloPendientes,
            severidadFiltro: _severidadFiltro,
            resumen: resumen,
            onElegirFecha: _elegirFecha,
            onIrAHoy: _irAHoy,
            onTogglePendientes: (v) => setState(() {
              _soloPendientes = v;
              _pagina = 0;
            }),
            onSeveridadChange: (s) => setState(() {
              _severidadFiltro = s;
              _pagina = 0;
            }),
          );

          if (docsFiltrados.isEmpty) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header,
                      const SizedBox(height: AppSpacing.md),
                      buscador,
                    ],
                  ),
                ),
                filtros,
                Expanded(
                  child: AppEmptyState(
                    icon: Icons.notifications_off_outlined,
                    title: _emptyTitle(),
                    subtitle: _emptySubtitle(),
                  ),
                ),
              ],
            );
          }

          final totalPaginas =
              (docsFiltrados.length / _itemsPorPagina).ceil();
          if (_pagina >= totalPaginas) {
            // Si la página actual queda fuera de rango (porque se filtró
            // más fuerte), volvemos a la primera.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _pagina = 0);
            });
          }
          // clamp(inicio) además del fin: si _pagina quedó alto tras un filtro
          // agresivo, el reset a 0 es post-frame (un frame después), así que en
          // ESTE build inicio podía superar a fin y sublist tiraba RangeError.
          final inicio =
              (_pagina * _itemsPorPagina).clamp(0, docsFiltrados.length);
          final fin =
              (inicio + _itemsPorPagina).clamp(0, docsFiltrados.length);
          final pagina = docsFiltrados.sublist(inicio, fin);

          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
                  children: [
                    header,
                    const SizedBox(height: AppSpacing.md),
                    buscador,
                    const SizedBox(height: AppSpacing.sm),
                    filtros,
                    const SizedBox(height: AppSpacing.sm),
                    for (final doc in pagina) _AlertaCard(doc: doc),
                  ],
                ),
              ),
              if (totalPaginas > 1)
                _Paginador(
                  pagina: _pagina,
                  totalPaginas: totalPaginas,
                  totalItems: docsFiltrados.length,
                  itemsPorPagina: _itemsPorPagina,
                  onPrev:
                      _pagina > 0 ? () => setState(() => _pagina--) : null,
                  onNext: _pagina < totalPaginas - 1
                      ? () => setState(() => _pagina++)
                      : null,
                ),
            ],
          );
        },
      ),
    );
  }

  String _emptyTitle() {
    final periodo = _esUnDia ? 'ese día' : 'ese período';
    if (_query.isNotEmpty) return 'Sin resultados para "$_query"';
    if (_severidadFiltro != null && _soloPendientes) {
      return 'Sin alertas $_severidadFiltro pendientes $periodo';
    }
    if (_severidadFiltro != null) {
      return 'Sin alertas $_severidadFiltro $periodo';
    }
    if (_soloPendientes) return 'Sin alertas pendientes $periodo';
    return 'Sin alertas registradas $periodo';
  }

  String? _emptySubtitle() {
    if (_query.isNotEmpty) return null;
    if (_soloPendientes) {
      return 'Cambiá a "Mostrar atendidas" para ver el histórico${_esUnDia ? " del día" : " del período"}.';
    }
    return 'Probá con otro ${_esUnDia ? "día" : "rango"} desde el botón de calendario.';
  }
}

// =============================================================================
// HEADER — eyebrow + hero number (alertas visibles) + KpiStrip por severidad
// =============================================================================

class _Header extends StatelessWidget {
  /// Cantidad de alertas que pasan los filtros actuales (lo que se ve).
  final int totalVisible;
  final ({int high, int medium, int low, int pendientes}) resumen;
  final bool hayDatos;

  const _Header({
    required this.totalVisible,
    required this.resumen,
    required this.hayDatos,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppEyebrow('Alertas Volvo'),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              hayDatos ? '$totalVisible' : '—',
              style: AppType.h2.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                totalVisible == 1 ? 'alerta en vista' : 'alertas en vista',
                style: AppType.monoSm.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        // KPIs at-a-glance por severidad + pendientes. Derivados del MISMO
        // stream, sobre toda la ventana del día (sin el filtro de severidad).
        AppKpiStrip(
          stats: [
            AppStat(
              label: 'HIGH',
              value: hayDatos ? '${resumen.high}' : '—',
              accent: resumen.high > 0 ? c.error : null,
            ),
            AppStat(
              label: 'MEDIUM',
              value: hayDatos ? '${resumen.medium}' : '—',
              accent: resumen.medium > 0 ? c.warning : null,
            ),
            AppStat(
              label: 'LOW',
              value: hayDatos ? '${resumen.low}' : '—',
              accent: resumen.low > 0 ? c.info : null,
            ),
            AppStat(
              label: 'Pendientes',
              value: hayDatos ? '${resumen.pendientes}' : '—',
              accent: resumen.pendientes > 0 ? c.brand : null,
            ),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// BUSCADOR + acceso al mapa de eventos
// =============================================================================

class _Buscador extends StatelessWidget {
  final TextEditingController controller;
  final String query;
  final VoidCallback onClear;
  final VoidCallback onMapa;

  const _Buscador({
    required this.controller,
    required this.query,
    required this.onClear,
    required this.onMapa,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // El "Ver en mapa" antes era un tab independiente del shell. Lo movimos
    // acá (2026-05-07) porque conceptualmente es la misma data — el mapa
    // muestra los mismos eventos que el tablero, solo geolocalizados.
    return Row(
      children: [
        Expanded(
          child: AppInput(
            controller: controller,
            hint: 'Buscar por patente, tipo o VIN…',
            icon: Icons.search,
            trailingAction: query.isEmpty ? null : 'Limpiar',
            onTrailingTap: query.isEmpty ? null : onClear,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        // Acceso al mapa con look Núcleo (pill cuadrado surface3 + hairline).
        InkWell(
          onTap: onMapa,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: c.surface3,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: c.borderStrong),
            ),
            child: Icon(Icons.map_outlined, size: 20, color: c.brand),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// BARRA DE FILTROS — fecha + atendidas + severidad (chips Núcleo)
// =============================================================================

class _BarraFiltros extends StatelessWidget {
  final String fechaEtiqueta;
  final bool esHoy;
  final bool soloPendientes;
  final String? severidadFiltro;
  final ({int high, int medium, int low, int pendientes}) resumen;
  final VoidCallback onElegirFecha;
  final VoidCallback onIrAHoy;
  final ValueChanged<bool> onTogglePendientes;
  final ValueChanged<String?> onSeveridadChange;

  const _BarraFiltros({
    required this.fechaEtiqueta,
    required this.esHoy,
    required this.soloPendientes,
    required this.severidadFiltro,
    required this.resumen,
    required this.onElegirFecha,
    required this.onIrAHoy,
    required this.onTogglePendientes,
    required this.onSeveridadChange,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final total = resumen.high + resumen.medium + resumen.low;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fila 1 — rango de fecha (pill) + "Ir a hoy" + toggle pendientes.
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _PillFiltro(
                label: fechaEtiqueta,
                icon: Icons.calendar_month_outlined,
                onTap: onElegirFecha,
              ),
              if (!esHoy)
                _PillFiltro(
                  label: 'Ir a hoy',
                  icon: Icons.today_outlined,
                  onTap: onIrAHoy,
                ),
              _PillToggle(
                label: soloPendientes ? 'Solo pendientes' : 'Mostrar atendidas',
                icon: soloPendientes
                    ? Icons.filter_alt
                    : Icons.filter_alt_off_outlined,
                activo: soloPendientes,
                color: c.warning,
                onTap: () => onTogglePendientes(!soloPendientes),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Fila 2 — severidad como chips de filtro (Núcleo).
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              AppFilterChip(
                label: 'Todas',
                count: total,
                activo: severidadFiltro == null,
                onTap: () => onSeveridadChange(null),
              ),
              _ChipSeveridad(
                label: 'HIGH',
                count: resumen.high,
                color: c.error,
                seleccionado: severidadFiltro == 'HIGH',
                onTap: () => onSeveridadChange('HIGH'),
              ),
              _ChipSeveridad(
                label: 'MEDIUM',
                count: resumen.medium,
                color: c.warning,
                seleccionado: severidadFiltro == 'MEDIUM',
                onTap: () => onSeveridadChange('MEDIUM'),
              ),
              _ChipSeveridad(
                label: 'LOW',
                count: resumen.low,
                color: c.info,
                seleccionado: severidadFiltro == 'LOW',
                onTap: () => onSeveridadChange('LOW'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pill de acción (fecha / ir a hoy). Look Núcleo: surface3 + hairline.
class _PillFiltro extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _PillFiltro(
      {required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.borderStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: c.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: AppType.label.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pill toggle on/off (pendientes/atendidas). Activo = tinte del color.
class _PillToggle extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool activo;
  final Color color;
  final VoidCallback onTap;
  const _PillToggle({
    required this.label,
    required this.icon,
    required this.activo,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = activo ? color : c.textMuted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: activo ? color.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: activo ? fg : c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: AppType.label.copyWith(
                color: activo ? fg : c.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chip de severidad con contador. Seleccionado = relleno sólido del color;
/// inactivo = tinte + borde del color (mantiene la lectura semántica).
class _ChipSeveridad extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final bool seleccionado;
  final VoidCallback onTap;

  const _ChipSeveridad({
    required this.label,
    required this.count,
    required this.color,
    required this.seleccionado,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = seleccionado ? AppColors.surface0 : color;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: seleccionado ? color : color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: seleccionado ? color : color.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppType.label.copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: AppType.monoSm.copyWith(
                color: seleccionado
                    ? AppColors.surface0.withValues(alpha: 0.6)
                    : color.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// PAGINADOR (footer fijo abajo)
// =============================================================================

class _Paginador extends StatelessWidget {
  final int pagina;
  final int totalPaginas;
  final int totalItems;
  final int itemsPorPagina;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const _Paginador({
    required this.pagina,
    required this.totalPaginas,
    required this.totalItems,
    required this.itemsPorPagina,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final desde = pagina * itemsPorPagina + 1;
    final hasta = ((pagina + 1) * itemsPorPagina).clamp(0, totalItems);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: c.surface1,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Text(
            'Mostrando $desde-$hasta de $totalItems',
            style: AppType.monoSm.copyWith(color: c.textMuted),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: onPrev,
            color: onPrev == null ? c.textPlaceholder : c.text,
            tooltip: 'Anterior',
          ),
          Text(
            'Pág. ${pagina + 1} / $totalPaginas',
            style: AppType.mono.copyWith(color: c.text),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: onNext,
            color: onNext == null ? c.textPlaceholder : c.text,
            tooltip: 'Siguiente',
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// CARD DE LA ALERTA (Núcleo) — AppCard(tier:1) con AppBadge por severidad.
// =============================================================================

class _AlertaCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _AlertaCard({required this.doc});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final data = doc.data() as Map<String, dynamic>;
    final severidad = (data['severidad'] ?? 'LOW').toString();
    final patente = (data['patente'] ?? '—').toString();
    final atendida = data['atendida'] == true;
    final creadoEn = data['creado_en'] as Timestamp?;
    final atendidaPor = (data['atendida_por'] ?? '').toString();
    final atendidaEn = data['atendida_en'] as Timestamp?;
    // Etiqueta usa el doc completo para resolver subtipo cuando el tipo
    // principal es GENERIC (SEATBELT, TELL_TALE, etc.). Sin esto todos los
    // GENERIC se mostraban como "Evento genérico" sin info.
    final etiqueta = etiquetaAlertaVolvoFromDoc(data);
    final sevColor = _colorSeveridad(severidad, c);

    return AppCard(
      tier: 1,
      // Borde izquierdo de color = lectura de severidad de un vistazo.
      accent: sevColor,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppBadge(
                text: severidad.toUpperCase(),
                color: sevColor,
                solid: true,
                size: AppBadgeSize.sm,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  etiqueta,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (atendida) ...[
                const SizedBox(width: AppSpacing.sm),
                AppBadge(
                  text: 'Atendida',
                  color: c.success,
                  icon: Icons.check,
                  size: AppBadgeSize.sm,
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Patente + timestamp en mono (datos técnicos).
          Row(
            children: [
              Icon(Icons.local_shipping_outlined, size: 15, color: c.textMuted),
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text(
                  patente,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.mono.copyWith(color: c.textSecondary),
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Icon(Icons.access_time, size: 13, color: c.textMuted),
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text(
                  _formatTimestamp(creadoEn),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
          if (atendida) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Atendida por ${atendidaPor.isEmpty ? '—' : atendidaPor} · '
              '${_formatTimestamp(atendidaEn)}',
              style: AppType.monoSm.copyWith(color: c.textMuted),
            ),
          ] else ...[
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerRight,
              child: AppButton.secondary(
                label: 'Marcar atendida',
                icon: Icons.check,
                size: AppButtonSize.sm,
                onPressed: () => _marcarAtendida(context),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _marcarAtendida(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final dni = PrefsService.dni;
    if (dni.isEmpty) {
      AppFeedback.errorOn(messenger, 'Sin sesión activa.');
      return;
    }
    try {
      await doc.reference.update({
        'atendida': true,
        'atendida_por': dni,
        'atendida_en': FieldValue.serverTimestamp(),
      });
      final data = doc.data() as Map<String, dynamic>;
      unawaited(AuditLog.registrar(
        accion: AuditAccion.marcarAlertaVolvoAtendida,
        entidad: 'VOLVO_ALERTAS',
        entidadId: doc.id,
        detalles: {
          'tipo': (data['tipo'] ?? '').toString(),
          'severidad': (data['severidad'] ?? '').toString(),
          'patente': (data['patente'] ?? '').toString(),
        },
      ));
      AppFeedback.successOn(messenger, 'Alerta marcada como atendida.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo marcar la alerta como atendida. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }
}

/// Color semántico por severidad — tinta del sistema, sin hex.
/// HIGH=error, MEDIUM=warning, LOW=info, desconocida=textMuted.
Color _colorSeveridad(String severidad, AppColorsExt c) {
  switch (severidad.toUpperCase()) {
    case 'HIGH':
      return c.error;
    case 'MEDIUM':
      return c.warning;
    case 'LOW':
      return c.info;
  }
  return c.textMuted;
}

String _formatTimestamp(Timestamp? ts) {
  if (ts == null) return '—';
  final dt = ts.toDate().toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)}-${two(dt.month)}-${dt.year} '
      '${two(dt.hour)}:${two(dt.minute)}';
}
