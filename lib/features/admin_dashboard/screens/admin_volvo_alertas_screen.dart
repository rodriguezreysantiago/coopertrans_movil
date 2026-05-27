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
/// Pantalla "Alertas Volvo" del admin/supervisor.
///
/// Lista los eventos del Vehicle Alerts API que el `volvoAlertasPoller`
/// (scheduled cada 5 min) guarda en `VOLVO_ALERTAS`.
///
/// **Diseño revisado 2026-05-04 (v2)**: por default muestra SOLO las
/// alertas del día actual con paginación de 30 ítems por página.
/// Filtros: severidad (HIGH/MEDIUM/LOW/Todas) + atendida (Pendientes/Todas).
/// Búsqueda por texto sobre patente/tipo/VIN.
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
      cancelText: 'CANCELAR',
      confirmText: 'VER',
      saveText: 'VER',
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

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Alertas Volvo',
      body: Column(
        children: [
          // Buscador + acceso al mapa de eventos. El "Ver en mapa"
          // antes era un tab independiente del shell. Lo movimos acá
          // (2026-05-07) porque conceptualmente es la misma data — el
          // mapa muestra los mismos eventos que el tablero, solo geo-
          // localizados — y tener dos accesos paralelos confundía.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtl,
                    decoration: InputDecoration(
                      hintText: 'Buscar por patente, tipo o VIN...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              tooltip: 'Limpiar búsqueda',
                              onPressed: () => _searchCtl.clear(),
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                IconButton.filledTonal(
                  icon: const Icon(Icons.map_outlined),
                  tooltip: 'Ver en mapa',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AdminMapaVolvoScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Filtros visuales.
          _BarraFiltros(
            fechaEtiqueta: _etiquetaFecha,
            esHoy: _esHoy,
            soloPendientes: _soloPendientes,
            severidadFiltro: _severidadFiltro,
            onElegirFecha: _elegirFecha,
            onIrAHoy: () {
              final hoy = _truncarDia(DateTime.now());
              setState(() {
                _rango = DateTimeRange(start: hoy, end: hoy);
                _pagina = 0;
              });
            },
            onTogglePendientes: (v) => setState(() {
              _soloPendientes = v;
              _pagina = 0;
            }),
            onSeveridadChange: (s) => setState(() {
              _severidadFiltro = s;
              _pagina = 0;
            }),
          ),
          // Lista paginada.
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _alertasStream,
              builder: (ctx, snap) {
                if (snap.hasError) {
                  return AppErrorState(subtitle: snap.error.toString());
                }
                if (!snap.hasData) {
                  return const AppLoadingState();
                }
                final docsTodos = snap.data!.docs;
                final docsFiltrados = _filtrar(docsTodos);
                if (docsFiltrados.isEmpty) {
                  return AppEmptyState(
                    icon: Icons.notifications_off_outlined,
                    title: _emptyTitle(),
                    subtitle: _emptySubtitle(),
                  );
                }
                final totalPaginas =
                    (docsFiltrados.length / _itemsPorPagina).ceil();
                if (_pagina >= totalPaginas) {
                  // Si la página actual queda fuera de rango (porque
                  // se filtró más fuerte), volvemos a la primera.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _pagina = 0);
                  });
                }
                final inicio = _pagina * _itemsPorPagina;
                final fin =
                    (inicio + _itemsPorPagina).clamp(0, docsFiltrados.length);
                final pagina = docsFiltrados.sublist(inicio, fin);
                return Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        itemCount: pagina.length,
                        itemBuilder: (_, i) => _AlertaCard(doc: pagina[i]),
                      ),
                    ),
                    if (totalPaginas > 1)
                      _Paginador(
                        pagina: _pagina,
                        totalPaginas: totalPaginas,
                        totalItems: docsFiltrados.length,
                        itemsPorPagina: _itemsPorPagina,
                        onPrev: _pagina > 0
                            ? () => setState(() => _pagina--)
                            : null,
                        onNext: _pagina < totalPaginas - 1
                            ? () => setState(() => _pagina++)
                            : null,
                      ),
                  ],
                );
              },
            ),
          ),
        ],
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
// BARRA DE FILTROS — fecha + atendidas + severidad
// =============================================================================

class _BarraFiltros extends StatelessWidget {
  final String fechaEtiqueta;
  final bool esHoy;
  final bool soloPendientes;
  final String? severidadFiltro;
  final VoidCallback onElegirFecha;
  final VoidCallback onIrAHoy;
  final ValueChanged<bool> onTogglePendientes;
  final ValueChanged<String?> onSeveridadChange;

  const _BarraFiltros({
    required this.fechaEtiqueta,
    required this.esHoy,
    required this.soloPendientes,
    required this.severidadFiltro,
    required this.onElegirFecha,
    required this.onIrAHoy,
    required this.onTogglePendientes,
    required this.onSeveridadChange,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: onElegirFecha,
            icon: const Icon(Icons.calendar_month_outlined, size: 18),
            label: Text(fechaEtiqueta),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(
                color: esHoy ? AppColors.success : Colors.white38,
              ),
            ),
          ),
          if (!esHoy)
            TextButton.icon(
              onPressed: onIrAHoy,
              icon: const Icon(Icons.today_outlined, size: 18),
              label: const Text('Ir a hoy'),
              style: TextButton.styleFrom(
                  foregroundColor: AppColors.success),
            ),
          FilterChip(
            label: Text(
              soloPendientes ? 'Solo pendientes' : 'Mostrar atendidas',
            ),
            selected: soloPendientes,
            onSelected: onTogglePendientes,
            avatar: Icon(
              soloPendientes
                  ? Icons.filter_alt
                  : Icons.filter_alt_off_outlined,
              size: 18,
            ),
          ),
          // Filtro por severidad — null = todas.
          ChoiceChip(
            label: const Text('Todas'),
            selected: severidadFiltro == null,
            onSelected: (_) => onSeveridadChange(null),
          ),
          _ChipSeveridad(
            label: 'HIGH',
            color: const Color(0xFFD32F2F),
            seleccionado: severidadFiltro == 'HIGH',
            onTap: () => onSeveridadChange('HIGH'),
          ),
          _ChipSeveridad(
            label: 'MEDIUM',
            color: const Color(0xFFEF6C00),
            seleccionado: severidadFiltro == 'MEDIUM',
            onTap: () => onSeveridadChange('MEDIUM'),
          ),
          _ChipSeveridad(
            label: 'LOW',
            color: const Color(0xFFFBC02D),
            seleccionado: severidadFiltro == 'LOW',
            onTap: () => onSeveridadChange('LOW'),
          ),
        ],
      ),
    );
  }
}

class _ChipSeveridad extends StatelessWidget {
  final String label;
  final Color color;
  final bool seleccionado;
  final VoidCallback onTap;

  const _ChipSeveridad({
    required this.label,
    required this.color,
    required this.seleccionado,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: seleccionado,
      onSelected: (_) => onTap(),
      labelStyle: AppType.eyebrow.copyWith(color: seleccionado ? Colors.white : color, fontWeight: FontWeight.bold),
      backgroundColor: color.withAlpha(25),
      selectedColor: color,
      side: BorderSide(color: color, width: 1),
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
    final desde = pagina * itemsPorPagina + 1;
    final hasta = ((pagina + 1) * itemsPorPagina).clamp(0, totalItems);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1B2A),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          Text(
            'Mostrando $desde-$hasta de $totalItems',
            style: AppType.eyebrow.copyWith(color: Colors.white60),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: onPrev,
            color: onPrev == null ? Colors.white24 : Colors.white,
            tooltip: 'Anterior',
          ),
          Text(
            'Pág. ${pagina + 1} / $totalPaginas',
            style: AppType.label.copyWith(color: Colors.white),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: onNext,
            color: onNext == null ? Colors.white24 : Colors.white,
            tooltip: 'Siguiente',
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// CARD DE LA ALERTA
// =============================================================================

class _AlertaCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _AlertaCard({required this.doc});

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final severidad = (data['severidad'] ?? 'LOW').toString();
    final patente = (data['patente'] ?? '—').toString();
    final atendida = data['atendida'] == true;
    final creadoEn = data['creado_en'] as Timestamp?;
    final atendidaPor = (data['atendida_por'] ?? '').toString();
    final atendidaEn = data['atendida_en'] as Timestamp?;
    // Etiqueta usa el doc completo para resolver subtipo cuando el
    // tipo principal es GENERIC (SEATBELT, TELL_TALE, etc.). Sin esto
    // todos los GENERIC se mostraban como "Evento genérico" sin info.
    final etiqueta = etiquetaAlertaVolvoFromDoc(data);

    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _SeveridadChip(severidad: severidad),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    etiqueta,
                    style: AppType.body.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                if (atendida)
                  Chip(
                    label: const Text('Atendida'),
                    avatar: const Icon(Icons.check_circle, size: 16),
                    backgroundColor: const Color(0xFF1B5E20),
                    labelStyle: AppType.eyebrow.copyWith(color: Colors.white),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                const Icon(Icons.local_shipping_outlined,
                    size: 16, color: Colors.white70),
                const SizedBox(width: AppSpacing.xs),
                Flexible(
                  child: Text(patente,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, color: Colors.white)),
                ),
                const SizedBox(width: AppSpacing.lg),
                const Icon(Icons.access_time,
                    size: 14, color: Colors.white54),
                const SizedBox(width: AppSpacing.xs),
                Flexible(
                  child: Text(
                    _formatTimestamp(creadoEn),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        AppType.label.copyWith(color: Colors.white70),
                  ),
                ),
              ],
            ),
            if (atendida) ...[
              const SizedBox(height: 6),
              Text(
                'Atendida por $atendidaPor — ${_formatTimestamp(atendidaEn)}',
                style: AppType.eyebrow.copyWith(color: Colors.white54),
              ),
            ] else ...[
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: () => _marcarAtendida(context),
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Marcar atendida'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.success,
                    side: const BorderSide(color: AppColors.success),
                  ),
                ),
              ),
            ],
          ],
        ),
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

String _formatTimestamp(Timestamp? ts) {
  if (ts == null) return '—';
  final dt = ts.toDate().toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)}-${two(dt.month)}-${dt.year} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

class _SeveridadChip extends StatelessWidget {
  final String severidad;
  const _SeveridadChip({required this.severidad});

  @override
  Widget build(BuildContext context) {
    final color = switch (severidad.toUpperCase()) {
      'HIGH' => const Color(0xFFD32F2F),
      'MEDIUM' => const Color(0xFFEF6C00),
      'LOW' => const Color(0xFFFBC02D),
      _ => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        severidad.toUpperCase(),
        style: AppType.eyebrow.copyWith(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 0.5),
      ),
    );
  }
}
