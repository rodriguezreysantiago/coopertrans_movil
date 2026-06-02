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
import '../../vista_ejecutiva/widgets/kpi_grande_card.dart';
import '../../vista_ejecutiva/widgets/viajes_semanales_chart.dart';

/// Panel de administración — REFACTOR 2026-05-24 (split).
///
/// **Decisión del refactor:** este panel hacía DOS trabajos a la vez —
/// dashboard de operaciones (Hoy / Mes / Tendencias) Y launcher de
/// módulos (12 tiles de "Accesos rápidos"). El launcher duplicaba los
/// items del `AdminShell` NavigationRail / BottomNav, que ya los lista.
///
/// **Ahora:** el launcher SALE. Esta pantalla es 100% dashboard.
/// La navegación entre módulos sigue por el shell (sidebar / bottom
/// nav). El power-user usa `Ctrl+K` (la command palette ya existente).
///
/// **Layout:**
/// - Saludo (con hora del día + nombre + fecha)
/// - **Urgente** — 3 KPIs críticos con fondo destacado si hay rojos.
/// - **Esta semana / Mes** — viajes, eficiencia, ICM con trend ▲▼.
/// - **Tendencias** — chart de viajes 8 semanas.
/// - Footer versión.
///
/// **Lo que ya NO está acá:**
/// - Los 12 tiles `_AdminTile` y `_AdminTileWhatsAppBot` — ahora viven
///   exclusivamente en `admin_shell.dart`.
/// - Si necesitás un acceso rápido a un módulo que no está en el shell:
///   agregalo al shell, no acá.
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
    return AppScaffold(
      title: AppTexts.appName,
      body: RefreshIndicator(
        onRefresh: _refrescar,
        color: AppColors.brand,
        backgroundColor: AppColors.surface2,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          children: [
            const _Saludo(),
            const SizedBox(height: AppSpacing.lg),

            // ============ URGENTE — el bloque hero ============
            const _SeccionEyebrow('Urgente'),
            const SizedBox(height: AppSpacing.sm),
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _statsStream,
              builder: (ctx, statsSnap) {
                final stats = _Stats.fromDoc(statsSnap.data?.data());
                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _revisionesPendientesStream,
                  builder: (ctx2, revSnap) {
                    final statsFinal = revSnap.hasData
                        ? stats.conRevisionesPendientes(
                            revSnap.data!.docs.length,
                          )
                        : stats;
                    return _SeccionUrgente(stats: statsFinal);
                  },
                );
              },
            ),

            const SizedBox(height: AppSpacing.xl),

            // ============ ESTA SEMANA / MES ============
            if (_verKpisRicos) ...[
              _SeccionesEjecutivas(
                future: _futureKpisRicos!,
                onReintentar: _cargarKpisRicos,
              ),
              const SizedBox(height: AppSpacing.xl),
            ],

            // ============ FOOTER ============
            Center(
              child: Text(
                '${AppTexts.appVersion} · Base Operativa',
                style: AppType.label.copyWith(color: AppColors.textDisabled),
              ),
            ),
            // Hint a la command palette — la palette es la nueva
            // "accesos rápidos". En mobile no se muestra (no hay teclado);
            // en macOS dice ⌘K; en Windows/Linux dice Ctrl+K.
            Builder(
              builder: (ctx) {
                final hint = PlatformKeys.commandPaletteHint();
                if (hint == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.md),
                  child: Center(child: Text(hint, style: AppType.label)),
                );
              },
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SECCIÓN URGENTE — bloque hero
// =============================================================================

class _SeccionUrgente extends StatelessWidget {
  final _Stats stats;
  const _SeccionUrgente({required this.stats});

  @override
  Widget build(BuildContext context) {
    final hayCriticos = stats.vencidos > 0;
    final hayPendientes =
        stats.revisionesPendientes > 0 || stats.proximos7 > 0;

    final cuenta = (hayCriticos ? 1 : 0) +
        (stats.revisionesPendientes > 0 ? 1 : 0) +
        (stats.proximos7 > 0 ? 1 : 0);

    return AppCard(
      tier: 2,
      highlighted: hayCriticos,
      borderColor: hayCriticos
          ? AppColors.error.withAlpha(120)
          : (hayPendientes ? AppColors.warning.withAlpha(80) : null),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  stats.cargando
                      ? 'Cargando estado…'
                      : (cuenta == 0
                          ? 'Sin alertas urgentes hoy'
                          : 'Tenés $cuenta ${cuenta == 1 ? "cosa urgente" : "cosas urgentes"} hoy'),
                  style: AppType.heading,
                ),
              ),
              if (cuenta == 0)
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: AppColors.success,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _LineaUrgencia(
            color: stats.vencidos > 0
                ? AppColors.error
                : AppColors.textDisabled,
            valor: stats.cargando ? '…' : '${stats.vencidos}',
            label: stats.vencidos == 1
                ? 'papel vencido sin renovar'
                : 'papeles vencidos sin renovar',
            onTap: () => Navigator.pushNamed(
              context,
              '/vencimientos_calendario',
            ),
          ),
          const Divider(height: AppSpacing.lg),
          _LineaUrgencia(
            color: stats.revisionesPendientes > 0
                ? AppColors.warning
                : AppColors.textDisabled,
            valor: stats.cargando ? '…' : '${stats.revisionesPendientes}',
            label: stats.revisionesPendientes == 1
                ? 'trámite esperando tu revisión'
                : 'trámites esperando tu revisión',
            onTap: () => Navigator.pushNamed(context, '/admin_revisiones'),
          ),
          const Divider(height: AppSpacing.lg),
          _LineaUrgencia(
            color: stats.proximos7 > 0
                ? AppColors.warning
                : AppColors.textDisabled,
            valor: stats.cargando ? '…' : '${stats.proximos7}',
            label: 'vencen en los próximos 7 días',
            onTap: () => Navigator.pushNamed(
              context,
              '/vencimientos_calendario',
            ),
          ),
        ],
      ),
    );
  }
}

class _LineaUrgencia extends StatelessWidget {
  final Color color;
  final String valor;
  final String label;
  final VoidCallback onTap;

  const _LineaUrgencia({
    required this.color,
    required this.valor,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppSpacing.md),
            Text(
              valor,
              style: AppType.title.copyWith(color: color, fontSize: 24),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: AppType.body.copyWith(
                  color: AppColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios,
              size: 12,
              color: AppColors.textHint,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SECCIONES EJECUTIVAS — Esta semana / Mes / Tendencias
// =============================================================================

class _SeccionesEjecutivas extends StatelessWidget {
  final Future<KpisVistaEjecutiva> future;
  final VoidCallback onReintentar;

  const _SeccionesEjecutivas({
    required this.future,
    required this.onReintentar,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<KpisVistaEjecutiva>(
      future: future,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
            child: AppSkeletonList(count: 3, conAvatar: false),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Column(
              children: [
                const Icon(
                  Icons.error_outline,
                  color: AppColors.error,
                  size: 36,
                ),
                const SizedBox(height: AppSpacing.sm),
                const Text(
                  'No se pudieron cargar los KPIs del mes',
                  style: AppType.body,
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton.secondary(
                  label: 'Reintentar',
                  icon: Icons.refresh,
                  onPressed: onReintentar,
                ),
              ],
            ),
          );
        }
        final kpis = snap.data!;
        return _PanoramaYTendencias(kpis: kpis);
      },
    );
  }
}

class _PanoramaYTendencias extends StatelessWidget {
  final KpisVistaEjecutiva kpis;
  const _PanoramaYTendencias({required this.kpis});

  @override
  Widget build(BuildContext context) {
    final esDesktop = AppBreakpoints.isDesktopOrLarger(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SeccionEyebrow('Panorama del mes'),
        const SizedBox(height: AppSpacing.sm),
        GridView.count(
          crossAxisCount: esDesktop ? 3 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppSpacing.md,
          crossAxisSpacing: AppSpacing.md,
          childAspectRatio: esDesktop ? 1.0 : 0.95,
          children: [
            KpiGrandeCard.mes(
              label: 'Viajes del mes',
              kpi: kpis.viajesDelMes,
              icono: Icons.local_shipping,
              // Antes accentPurple → ahora cobalto del brand.
              color: AppColors.brand,
              mejorEsSubir: true,
              onTap: () => Navigator.pushNamed(
                context,
                AppRoutes.adminLogisticaViajes,
              ),
            ),
            KpiGrandeCard.simple(
              label: 'Alertas críticas',
              kpi: kpis.alertasCriticas,
              icono: Icons.warning_amber_rounded,
              color: kpis.alertasCriticas.valor > 0
                  ? AppColors.error
                  : AppColors.success,
              onTap: () => Navigator.pushNamed(
                context,
                AppRoutes.vencimientosCalendario,
              ),
            ),
            KpiGrandeCard.eficiencia(
              label: 'Eficiencia 30d',
              kpi: kpis.eficienciaCombustible,
              icono: Icons.local_gas_station,
              onTap: () => Navigator.pushNamed(
                context,
                AppRoutes.adminEcoDriving,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        const _SeccionEyebrow('Tendencias'),
        const SizedBox(height: AppSpacing.sm),
        ViajesSemanalesChart(
          puntos: kpis.viajesPorSemana,
          titulo: 'Viajes por semana · últimas 8',
        ),
      ],
    );
  }
}

// =============================================================================
// SALUDO
// =============================================================================

class _Saludo extends StatefulWidget {
  const _Saludo();

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

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, left: AppSpacing.xs),
      child: Column(
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
            style: AppType.h2,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// EYEBROW de sección
// =============================================================================

class _SeccionEyebrow extends StatelessWidget {
  final String texto;
  const _SeccionEyebrow(this.texto);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs, top: AppSpacing.xs),
      // Antes: ALL CAPS verde-neón con letterSpacing 1.5. Ahora: AppType.eyebrow
      // que es uppercase pero más sobrio + sentence case del título visible.
      // El "uppercase" sucede en el estilo, no en el string fuente.
      child: Text(texto.toUpperCase(), style: AppType.eyebrow),
    );
  }
}

// =============================================================================
// STATS (sin cambios — mismo modelo que la versión anterior)
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
