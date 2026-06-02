import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/capabilities.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_breakpoints.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/platform_keys.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../vista_ejecutiva/services/vista_ejecutiva_service.dart';
import '../../vista_ejecutiva/widgets/viajes_semanales_chart.dart';

/// Panel de administración — REFACTOR NÚCLEO (jun 2026, bento).
///
/// Reescrito al layout del prototipo (`nucleo/screens-desktop-core.jsx ::
/// Dashboard`): ticker + hero + grilla bento. **Toda la métrica es real**
/// (`STATS/dashboard`, `REVISIONES`, `KpisVistaEjecutiva`) — no hay números
/// inventados. Las casillas del prototipo que pedían data que el panel no
/// carga (estados live de servicios, ICM/mantenimiento en la strip) se
/// adaptaron a lo disponible en vez de fabricar valores.
///
/// **Layout bento:**
/// - Live ticker — unidades / choferes / fecha-hora (reales).
/// - Hero — saludo + nombre.
/// - **Urgente** (8) + **Asistente** (4) — fila 1.
/// - **KPI strip** (12) — viajes, eficiencia, alertas, choferes, unidades.
/// - **Chart viajes/semana** (8) + **Servicios** (4) — fila 3.
///
/// En mobile la grilla se apila en una columna. El bloque ejecutivo
/// (strip + chart) solo se carga si el rol tiene `verVistaEjecutiva`.
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _statsStream;
  late final Stream<QuerySnapshot<Map<String, dynamic>>>
      _revisionesPendientesStream;

  Future<KpisVistaEjecutiva>? _futureKpisRicos;
  bool get _verKpisRicos =>
      Capabilities.can(PrefsService.rol, Capability.verVistaEjecutiva);

  @override
  void initState() {
    super.initState();
    _statsStream = FirebaseFirestore.instance
        .collection('STATS')
        .doc('dashboard')
        .snapshots();
    _revisionesPendientesStream = FirebaseFirestore.instance
        .collection('REVISIONES')
        .where('estado', isEqualTo: 'PENDIENTE')
        .snapshots();
    if (_verKpisRicos) _cargarKpisRicos();
  }

  void _cargarKpisRicos() {
    setState(() {
      _futureKpisRicos = VistaEjecutivaService.cargar(
        db: FirebaseFirestore.instance,
      );
    });
  }

  Future<void> _refrescar() async {
    if (_verKpisRicos) {
      _cargarKpisRicos();
      await _futureKpisRicos;
    }
  }

  @override
  Widget build(BuildContext context) {
    final esDesktop = AppBreakpoints.isDesktopOrLarger(context);
    return AppScaffold(
      title: AppTexts.appName,
      body: RefreshIndicator(
        onRefresh: _refrescar,
        color: AppColors.brand,
        backgroundColor: AppColors.surface2,
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _statsStream,
          builder: (ctx, statsSnap) {
            final stats0 = _Stats.fromDoc(statsSnap.data?.data());
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _revisionesPendientesStream,
              builder: (ctx2, revSnap) {
                final stats = revSnap.hasData
                    ? stats0.conRevisionesPendientes(revSnap.data!.docs.length)
                    : stats0;
                return ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  children: [
                    _LiveTicker(stats: stats),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.md,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Saludo(grande: esDesktop),
                          const SizedBox(height: AppSpacing.xl),
                          ..._bento(stats, esDesktop),
                          const SizedBox(height: AppSpacing.xl),
                          _footer(),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // BENTO
  // ---------------------------------------------------------------------------

  List<Widget> _bento(_Stats stats, bool esDesktop) {
    final urgente = _BentoUrgente(stats: stats);
    const asistente = _AsistenteCard();

    if (esDesktop) {
      return [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 8, child: urgente),
              const SizedBox(width: AppSpacing.md),
              const Expanded(flex: 4, child: asistente),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_verKpisRicos)
          _kpisYChart(stats: stats, esDesktop: true)
        else
          const _ServiciosCard(),
      ];
    }

    // Mobile — todo apilado.
    return [
      urgente,
      const SizedBox(height: AppSpacing.md),
      asistente,
      if (_verKpisRicos) ...[
        const SizedBox(height: AppSpacing.md),
        _kpisYChart(stats: stats, esDesktop: false),
      ],
      const SizedBox(height: AppSpacing.md),
      const _ServiciosCard(),
    ];
  }

  /// Bloque ejecutivo: KPI strip + chart (+ servicios al lado en desktop).
  /// Depende del future de KPIs ricos.
  Widget _kpisYChart({required _Stats stats, required bool esDesktop}) {
    return FutureBuilder<KpisVistaEjecutiva>(
      future: _futureKpisRicos,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: AppSkeletonList(count: 3, conAvatar: false),
          );
        }
        if (snap.hasError || !snap.hasData) {
          return _errorKpis();
        }
        final kpis = snap.data!;
        final strip = _KpiStrip(stats: stats, kpis: kpis, esDesktop: esDesktop);
        final chart = ViajesSemanalesChart(
          puntos: kpis.viajesPorSemana,
          titulo: 'Viajes por semana · últimas 8',
        );

        if (esDesktop) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              strip,
              const SizedBox(height: AppSpacing.md),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 8, child: chart),
                    const SizedBox(width: AppSpacing.md),
                    const Expanded(flex: 4, child: _ServiciosCard()),
                  ],
                ),
              ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            strip,
            const SizedBox(height: AppSpacing.md),
            chart,
          ],
        );
      },
    );
  }

  Widget _errorKpis() {
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            const Icon(Icons.error_outline, color: AppColors.error, size: 32),
            const SizedBox(height: AppSpacing.sm),
            const Text('No se pudieron cargar los KPIs del mes',
                style: AppType.body),
            const SizedBox(height: AppSpacing.md),
            AppButton.secondary(
              label: 'Reintentar',
              icon: Icons.refresh,
              onPressed: _cargarKpisRicos,
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    final hint = PlatformKeys.commandPaletteHint();
    return Column(
      children: [
        const Center(
          child: Text(
            '${AppTexts.appVersion} · Base Operativa',
            style: AppType.monoSm,
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Center(child: Text(hint, style: AppType.monoSm)),
        ],
        const SizedBox(height: AppSpacing.md),
      ],
    );
  }
}

// =============================================================================
// LIVE TICKER — datos operativos reales
// =============================================================================

class _LiveTicker extends StatelessWidget {
  final _Stats stats;
  const _LiveTicker({required this.stats});

  @override
  Widget build(BuildContext context) {
    final ahora = DateTime.now();
    final fechaHora =
        '${AppFormatters.formatearFecha(ahora)} · ${_hhmm(ahora)}';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: 7,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const AppDot(AppColors.brand, size: 6),
            const SizedBox(width: 6),
            Text('ops live', style: AppType.monoSm.copyWith(
                color: AppColors.brand, fontWeight: FontWeight.w600)),
            _sep(),
            _tk('unidades',
                stats.cargando ? '…' : '${stats.unidadesAsignadas}/${stats.unidadesTotal}'),
            _sep(),
            _tk('choferes', stats.cargando ? '…' : '${stats.choferesActivos}'),
            _sep(),
            _tk(
              'revisiones',
              stats.cargando ? '…' : '${stats.revisionesPendientes}',
              valorColor: stats.revisionesPendientes > 0
                  ? AppColors.warning
                  : null,
            ),
            _sep(),
            Text(fechaHora, style: AppType.monoSm.copyWith(
                color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _sep() => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 11),
        child: Text('·', style: AppType.monoSm),
      );

  Widget _tk(String label, String valor, {Color? valorColor}) {
    return Row(
      children: [
        Text('$label ', style: AppType.monoSm),
        Text(valor, style: AppType.monoSm.copyWith(
            color: valorColor ?? AppColors.textPrimary,
            fontWeight: FontWeight.w600)),
      ],
    );
  }

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

// =============================================================================
// URGENTE — bloque hero (8 col)
// =============================================================================

class _BentoUrgente extends StatelessWidget {
  final _Stats stats;
  const _BentoUrgente({required this.stats});

  @override
  Widget build(BuildContext context) {
    final hayCriticos = stats.vencidos > 0;
    final cuenta = (stats.vencidos > 0 ? 1 : 0) +
        (stats.revisionesPendientes > 0 ? 1 : 0) +
        (stats.proximos7 > 0 ? 1 : 0);
    final vacio = !stats.cargando && cuenta == 0;

    return AppCard(
      highlighted: hayCriticos,
      borderColor: hayCriticos
          ? AppColors.error.withAlpha(120)
          : (cuenta > 0 ? AppColors.warning.withAlpha(80) : null),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                vacio ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                size: 14,
                color: vacio ? AppColors.success : AppColors.error,
              ),
              const SizedBox(width: 8),
              Text(
                vacio
                    ? 'TODO AL DÍA'
                    : 'URGENTE · $cuenta ${cuenta == 1 ? "ITEM" : "ITEMS"}',
                style: AppType.eyebrow.copyWith(
                  color: vacio ? AppColors.success : AppColors.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (stats.cargando)
            const Text('Cargando estado…', style: AppType.h4)
          else if (vacio)
            Text(
              'No tenés alertas urgentes hoy. Todos los papeles al día y sin trámites pendientes.',
              style: AppType.h4.copyWith(
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
              ),
            )
          else
            _parrafo(),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              AppButton.secondary(
                label: 'Abrir vencimientos',
                iconAfter: Icons.arrow_forward,
                onPressed: () => Navigator.pushNamed(
                    context, AppRoutes.vencimientosCalendario),
              ),
              if (stats.revisionesPendientes > 0)
                AppButton.ghost(
                  label: 'Trámites (${stats.revisionesPendientes})',
                  onPressed: () =>
                      Navigator.pushNamed(context, '/admin_revisiones'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Párrafo con los números coloreados inline (estilo prototipo).
  Widget _parrafo() {
    final base = AppType.h4.copyWith(
      fontWeight: FontWeight.w500,
      color: AppColors.textPrimary,
      height: 1.35,
    );
    TextSpan num(int n, String sustantivo, Color color) => TextSpan(
          text: '$n $sustantivo',
          style: base.copyWith(color: color, fontWeight: FontWeight.w700),
        );

    final partes = <TextSpan>[];
    partes.add(const TextSpan(text: 'Tenés '));
    final chunks = <TextSpan>[];
    if (stats.vencidos > 0) {
      chunks.add(num(stats.vencidos,
          stats.vencidos == 1 ? 'papel vencido' : 'papeles vencidos',
          AppColors.error));
    }
    if (stats.revisionesPendientes > 0) {
      chunks.add(num(
          stats.revisionesPendientes,
          stats.revisionesPendientes == 1
              ? 'trámite para revisar'
              : 'trámites para revisar',
          AppColors.warning));
    }
    if (stats.proximos7 > 0) {
      chunks.add(num(stats.proximos7, 'por vencer en 7 días',
          AppColors.warning));
    }
    // Unir con comas / "y".
    for (var i = 0; i < chunks.length; i++) {
      partes.add(chunks[i]);
      if (i < chunks.length - 2) {
        partes.add(const TextSpan(text: ', '));
      } else if (i == chunks.length - 2) {
        partes.add(const TextSpan(text: ' y '));
      }
    }
    partes.add(const TextSpan(text: '.'));

    return RichText(
      text: TextSpan(style: base, children: partes),
    );
  }
}

// =============================================================================
// ASISTENTE — card con glow (4 col) → abre la command palette
// =============================================================================

class _AsistenteCard extends StatelessWidget {
  const _AsistenteCard();

  @override
  Widget build(BuildContext context) {
    final hint = PlatformKeys.commandPaletteHint();
    return AppCard(
      glow: true,
      onTap: () => CommandPalette.show(context),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 14, color: AppColors.brand),
              const SizedBox(width: 8),
              Text('ASISTENTE',
                  style: AppType.eyebrow.copyWith(color: AppColors.brand)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Buscá cualquier chofer, unidad, viaje o pantalla — escribí lo que necesités.',
            style: AppType.body.copyWith(height: 1.4),
          ),
          const SizedBox(height: AppSpacing.md),
          const Divider(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: AppSpacing.sm),
          Text(
            hint != null ? 'Atajo: $hint' : 'Tocá para buscar',
            style: AppType.monoSm,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// KPI STRIP — 5 métricas reales en franja (12 col)
// =============================================================================

class _KpiStrip extends StatelessWidget {
  final _Stats stats;
  final KpisVistaEjecutiva kpis;
  final bool esDesktop;
  const _KpiStrip({
    required this.stats,
    required this.kpis,
    required this.esDesktop,
  });

  @override
  Widget build(BuildContext context) {
    final ef = kpis.eficienciaCombustible;
    final tieneEf = ef.diasConDatosActual > 0;
    final alertas = kpis.alertasCriticas.valor;

    final celdas = <Widget>[
      _KpiCell(
        label: 'Viajes 30d',
        valor: '${kpis.viajesDelMes.actual}',
        delta: _pct(kpis.viajesDelMes.variacionPct),
        deltaColor: _deltaColor(kpis.viajesDelMes.variacionPct, subirEsBueno: true),
      ),
      _KpiCell(
        label: 'Eficiencia',
        valor: tieneEf ? ef.litrosPor100kmActual.toStringAsFixed(1) : '—',
        unidad: tieneEf ? 'L/100km' : null,
        delta: tieneEf && ef.variacionAbs != null
            ? (ef.variacionAbs! >= 0
                ? '+${ef.variacionAbs!.toStringAsFixed(1)}'
                : ef.variacionAbs!.toStringAsFixed(1))
            : null,
        // En L/100km bajar es mejor → subirEsBueno: false.
        deltaColor: _deltaColor(ef.variacionAbs, subirEsBueno: false),
      ),
      _KpiCell(
        label: 'Alertas',
        valor: '$alertas',
        valorColor: alertas > 0 ? AppColors.error : AppColors.success,
      ),
      _KpiCell(
        label: 'Choferes',
        valor: '${stats.choferesActivos}',
        unidad: 'activos',
      ),
      _KpiCell(
        label: 'Unidades',
        valor: '${stats.unidadesAsignadas}',
        unidad: '/ ${stats.unidadesTotal}',
      ),
    ];

    return AppCard(
      padding: EdgeInsets.zero,
      child: esDesktop
          ? IntrinsicHeight(
              child: Row(
                children: [
                  for (var i = 0; i < celdas.length; i++) ...[
                    Expanded(child: celdas[i]),
                    if (i < celdas.length - 1)
                      const VerticalDivider(
                          width: 1, color: AppColors.borderSubtle),
                  ],
                ],
              ),
            )
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    for (var i = 0; i < celdas.length; i++) ...[
                      SizedBox(width: 132, child: celdas[i]),
                      if (i < celdas.length - 1)
                        const VerticalDivider(
                            width: 1, color: AppColors.borderSubtle),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  static String? _pct(double? pct) {
    if (pct == null) return null;
    return pct >= 0
        ? '+${pct.toStringAsFixed(0)}%'
        : '${pct.toStringAsFixed(0)}%';
  }

  /// Verde si la variación es "buena", rojo si "mala", neutro si null/0.
  static Color _deltaColor(double? v, {required bool subirEsBueno}) {
    if (v == null || v == 0) return AppColors.textSecondary;
    final esBueno = subirEsBueno ? v > 0 : v < 0;
    return esBueno ? AppColors.success : AppColors.error;
  }
}

class _KpiCell extends StatelessWidget {
  final String label;
  final String valor;
  final String? unidad;
  final String? delta;
  final Color? deltaColor;
  final Color? valorColor;
  const _KpiCell({
    required this.label,
    required this.valor,
    this.unidad,
    this.delta,
    this.deltaColor,
    this.valorColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(), style: AppType.eyebrow, maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  valor,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.display.copyWith(
                    color: valorColor ?? AppColors.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (unidad != null) ...[
                const SizedBox(width: 4),
                Text(unidad!, style: AppType.monoSm),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            delta ?? '—',
            style: AppType.monoSm.copyWith(
              color: deltaColor ?? AppColors.textTertiary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SERVICIOS EXTERNOS — informativo (4 col). Sin estado live (no fabricamos
// OK/LAG: el panel no carga los latidos de cada servicio).
// =============================================================================

class _ServiciosCard extends StatelessWidget {
  const _ServiciosCard();

  static const _items = [
    ('Bot WhatsApp', 'Avisos y resúmenes automáticos · 24/7'),
    ('Cachatore', 'Sniper de turnos de carga YPF'),
    ('Sitrack', 'GPS y eventos de la flota'),
    ('Volvo Connect', 'Telemetría y scores de conducción'),
  ];

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md,
                AppSpacing.lg, AppSpacing.sm),
            child: Text('SERVICIOS DEL SISTEMA', style: AppType.eyebrow),
          ),
          const Divider(height: 1, color: AppColors.borderSubtle),
          for (var i = 0; i < _items.length; i++) ...[
            if (i > 0)
              const Divider(height: 1, color: AppColors.borderSubtle),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: AppSpacing.md),
              child: Row(
                children: [
                  const AppDot(AppColors.brand, size: 6),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_items[i].$1,
                            style: AppType.body.copyWith(
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(_items[i].$2, style: AppType.monoSm, maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// SALUDO
// =============================================================================

class _Saludo extends StatefulWidget {
  final bool grande;
  const _Saludo({this.grande = false});

  @override
  State<_Saludo> createState() => _SaludoState();
}

class _SaludoState extends State<_Saludo> {
  late String _apodoResuelto = PrefsService.apodo.trim();

  @override
  void initState() {
    super.initState();
    if (_apodoResuelto.isEmpty) _resolverApodoLegacy();
  }

  Future<void> _resolverApodoLegacy() async {
    final dni = PrefsService.dni;
    if (dni.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(dni)
          .get();
      if (!mounted) return;
      final apodo = (snap.data()?['APODO'] ?? '').toString().trim();
      if (apodo.isEmpty) return;
      setState(() => _apodoResuelto = apodo);
      unawaited(PrefsService.setApodo(apodo));
    } catch (_) {}
  }

  String _saludoHora() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Buen día';
    if (h < 19) return 'Buenas tardes';
    return 'Buenas noches';
  }

  String? _primerNombre(String full) {
    final partes = full.trim().split(RegExp(r'\s+'));
    if (partes.length < 2) return null;
    final n = partes[1];
    if (n.isEmpty) return null;
    return '${n[0].toUpperCase()}${n.substring(1).toLowerCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final nombreFull = PrefsService.nombre;
    final nombre = _apodoResuelto.isNotEmpty
        ? _apodoResuelto
        : _primerNombre(nombreFull);
    final fechaHoy = AppFormatters.formatearFecha(DateTime.now());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_saludoHora()} · $fechaHoy'.toUpperCase(),
          style: AppType.eyebrow.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Text(
          nombre != null ? 'Hola $nombre.' : 'Panel.',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.grande ? AppType.h1 : AppType.h2,
        ),
      ],
    );
  }
}

// =============================================================================
// STATS (mismo modelo que la versión anterior)
// =============================================================================

class _Stats {
  final int choferesActivos;
  final int unidadesTotal;
  final int unidadesAsignadas;
  final int revisionesPendientes;
  final int vencidos;
  final int proximos7;
  final int proximos30;
  final bool cargando;

  const _Stats({
    required this.choferesActivos,
    required this.unidadesTotal,
    required this.unidadesAsignadas,
    required this.revisionesPendientes,
    required this.vencidos,
    required this.proximos7,
    required this.proximos30,
    required this.cargando,
  });

  factory _Stats.fromDoc(Map<String, dynamic>? data) {
    if (data == null) {
      return const _Stats(
        choferesActivos: 0,
        unidadesTotal: 0,
        unidadesAsignadas: 0,
        revisionesPendientes: 0,
        vencidos: 0,
        proximos7: 0,
        proximos30: 0,
        cargando: true,
      );
    }
    int asInt(dynamic v) =>
        v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);
    return _Stats(
      choferesActivos: asInt(data['choferes_activos']),
      unidadesTotal: asInt(data['unidades_total']),
      unidadesAsignadas: asInt(data['unidades_asignadas']),
      revisionesPendientes: asInt(data['revisiones_pendientes']),
      vencidos: asInt(data['vencidos']),
      proximos7: asInt(data['proximos_7']),
      proximos30: asInt(data['proximos_30']),
      cargando: false,
    );
  }

  _Stats conRevisionesPendientes(int cantidad) {
    return _Stats(
      choferesActivos: choferesActivos,
      unidadesTotal: unidadesTotal,
      unidadesAsignadas: unidadesAsignadas,
      revisionesPendientes: cantidad,
      vencidos: vencidos,
      proximos7: proximos7,
      proximos30: proximos30,
      cargando: cargando,
    );
  }
}
