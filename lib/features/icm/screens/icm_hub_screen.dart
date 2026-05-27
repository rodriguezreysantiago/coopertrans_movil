import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../vista_ejecutiva/widgets/kpi_grande_card.dart';
import '../../vista_ejecutiva/widgets/tendencia_icm_chart.dart';
import '../../vista_ejecutiva/widgets/top_choferes_lista.dart';
import '../services/icm_hub_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Hub del módulo ICM (Índice de Conducta de Manejo).
///
/// Layout (de arriba abajo):
///
///   1. Banner explicativo (escala oficial Sitrack — más bajo = mejor).
///   2. KPI grande: ICM flota del mes + variación vs mes anterior.
///   3. Tendencia ICM oficial Sitrack — por día del mes en curso.
///   4. Grid de 3 sub-pantallas:
///      - RANKING: choferes ordenados por ICM (con buscador).
///      - REPORTE MENSUAL: flota + severidad + top 5.
///      - MAPA DE CALOR: distribución geográfica de infracciones.
///   5. Top 5 mejores choferes (verde).
///   6. Top 5 a mejorar (rojo).
///
/// Tile "DETALLE POR CHOFER" eliminado 2026-05-23 — el operador prefiere
/// abrir el portal Sitrack para drill-down real; la pantalla daba poco
/// valor agregado (mismos números que ya aparecen en el reporte).
///
/// Los widgets 2-3-5-6 antes vivían en el panel de inicio del admin
/// (mudados al ICM Hub 2026-05-23 por decisión de Santiago — pertenecen
/// más a este módulo que al tablero general). Comparten clases con
/// `VistaEjecutivaService` (KpiIcm, PuntoTendencia, ChoferRankingItem)
/// para reusar los widgets sin tocarlos.
///
/// El número que muestra el módulo es EL que audita YPF: lo calcula
/// Sitrack con su cartografía de segmento vial (urbano/no-urbano), dato
/// que nosotros no tenemos. Se ingiere a `ICM_OFICIAL/{YYYY-MM}` con el
/// scraper `sitrack_sync/sync_icm.py` (1 vez al día).
class IcmHubScreen extends StatefulWidget {
  const IcmHubScreen({super.key});

  @override
  State<IcmHubScreen> createState() => _IcmHubScreenState();
}

class _IcmHubScreenState extends State<IcmHubScreen> {
  Future<KpisIcmHub>? _futureKpis;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  void _cargar() {
    setState(() {
      _futureKpis =
          IcmHubService.cargarKpis(db: FirebaseFirestore.instance);
    });
  }

  Future<void> _refrescar() async {
    _cargar();
    await _futureKpis;
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'ICM — Conducta de Manejo',
      body: RefreshIndicator(
        onRefresh: _refrescar,
        color: AppColors.success,
        backgroundColor: AppColors.surface,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            // Orden 2026-05-24: primero los iconos de acceso (Ranking,
            // Reporte mensual, Mapa de calor, Jornada), después Personas
            // y al final los gráficos. Antes era al revés (gráficos
            // arriba) y el operador tenía que scrollear para llegar a
            // las acciones que más usa.
            const _GridSubpantallas(),
            const SizedBox(height: AppSpacing.xl),
            FutureBuilder<KpisIcmHub>(
              future: _futureKpis,
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: AppSkeleton.box(height: 180),
                  );
                }
                if (snap.hasError) {
                  return _ErrorReintentar(
                    error: snap.error.toString(),
                    onReintentar: _cargar,
                  );
                }
                final kpis = snap.data ?? KpisIcmHub.vacio;
                return _SeccionesIcm(kpis: kpis);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Las 3 secciones ricas del hub: KPI ICM flota + tendencia + 2 top 5.
class _SeccionesIcm extends StatelessWidget {
  final KpisIcmHub kpis;
  const _SeccionesIcm({required this.kpis});

  @override
  Widget build(BuildContext context) {
    final esDesktop = MediaQuery.of(context).size.width >= 800;
    // KPI ICM flota + Tendencias lado a lado en desktop (2026-05-24).
    // Antes la card ICM flota ocupaba toda una fila y debajo iba el
    // gráfico — quedaba mucho aire vertical. Ahora en desktop la card
    // queda a la izquierda (ancho fijo 280) y el gráfico ocupa el
    // resto. En mobile siguen apilados, card primero.
    final cardIcm = KpiGrandeCard.icm(
      label: 'ICM flota',
      kpi: kpis.icmFlota,
      icono: Icons.leaderboard,
      onTap: () => Navigator.pushNamed(
          context, AppRoutes.adminIcmReporteSemanal),
    );
    final chartTendencia = TendenciaIcmChart(
      puntos: kpis.tendenciaIcm,
      titulo: 'ICM oficial Sitrack · por día (mes en curso)',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ─── Personas: top 5 mejores + top 5 a mejorar ───
        const _SeccionLabel('Personas'),
        const SizedBox(height: AppSpacing.sm),
        if (esDesktop)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TopChoferesLista(
                  titulo: 'TOP 5 — MEJORES CHOFERES',
                  icono: Icons.emoji_events,
                  colorTitulo: AppColors.success,
                  items: kpis.top5Mejores,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: TopChoferesLista(
                  titulo: 'TOP 5 — A MEJORAR',
                  icono: Icons.priority_high,
                  colorTitulo: AppColors.error,
                  items: kpis.top5Peores,
                ),
              ),
            ],
          )
        else ...[
          TopChoferesLista(
            titulo: 'TOP 5 — MEJORES CHOFERES',
            icono: Icons.emoji_events,
            colorTitulo: AppColors.success,
            items: kpis.top5Mejores,
          ),
          const SizedBox(height: AppSpacing.sm),
          TopChoferesLista(
            titulo: 'TOP 5 — A MEJORAR',
            icono: Icons.priority_high,
            colorTitulo: AppColors.error,
            items: kpis.top5Peores,
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        // ─── ICM flota + Tendencias (lado a lado en desktop) — AL FINAL ───
        const _SeccionLabel('Panorama'),
        const SizedBox(height: AppSpacing.sm),
        if (esDesktop)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 280, child: cardIcm),
                const SizedBox(width: AppSpacing.md),
                Expanded(child: chartTendencia),
              ],
            ),
          )
        else ...[
          cardIcm,
          const SizedBox(height: AppSpacing.md),
          chartTendencia,
        ],
      ],
    );
  }
}

class _SeccionLabel extends StatelessWidget {
  final String texto;
  const _SeccionLabel(this.texto);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6, top: AppSpacing.xs),
      child: Text(
        texto.toUpperCase(),
        style: AppType.eyebrow
            .copyWith(color: AppColors.success, letterSpacing: 1.5),
      ),
    );
  }
}

class _ErrorReintentar extends StatelessWidget {
  final String error;
  final VoidCallback onReintentar;
  const _ErrorReintentar({required this.error, required this.onReintentar});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        children: [
          const Icon(Icons.error_outline,
              color: AppColors.error, size: 36),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'No se pudieron cargar los KPIs del ICM',
            style: AppType.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Text(
              error,
              textAlign: TextAlign.center,
              style: AppType.eyebrow.copyWith(color: AppColors.textHint),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Reintentar',
            icon: Icons.refresh,
            onPressed: onReintentar,
          ),
        ],
      ),
    );
  }
}

/// Grid de 4 sub-pantallas (lo único que tenía el hub antes del mudaje
/// de los widgets ricos 2026-05-23).
class _GridSubpantallas extends StatelessWidget {
  const _GridSubpantallas();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final w = constraints.maxWidth;
        // 3 tiles (antes 4; el de DETALLE POR CHOFER se sacó 2026-05-23).
        // Desktop 3×1, tablet 2×2 con el 3º solo en la 2ª fila, mobile 1 col.
        final cols = w >= 800 ? 4 : (w >= 540 ? 2 : 1);
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: AppSpacing.md,
          mainAxisSpacing: AppSpacing.md,
          childAspectRatio: cols == 1 ? 2.4 : 1.3,
          children: const [
            _HubTile(
              titulo: 'RANKING',
              subtitulo: 'Choferes ordenados por ICM (#1 = mejor)',
              icono: Icons.leaderboard_outlined,
              color: AppColors.info,
              ruta: AppRoutes.adminIcmRanking,
            ),
            _HubTile(
              titulo: 'REPORTE MENSUAL',
              subtitulo: 'Flota + severidad + top 5',
              icono: Icons.assessment_outlined,
              color: AppColors.success,
              ruta: AppRoutes.adminIcmReporteSemanal,
            ),
            _HubTile(
              titulo: 'MAPA DE CALOR',
              subtitulo: 'Lugares y horarios con más infracciones',
              icono: Icons.map_outlined,
              color: AppColors.warning,
              ruta: AppRoutes.adminIcmMapaCalor,
            ),
            _HubTile(
              titulo: 'JORNADA',
              subtitulo: 'Inicio, paradas y descansos por chofer + día',
              icono: Icons.timeline,
              color: AppColors.brandSoft,
              ruta: AppRoutes.adminIcmJornadaDia,
            ),
          ],
        );
      },
    );
  }
}

class _HubTile extends StatelessWidget {
  final String titulo;
  final String subtitulo;
  final IconData icono;
  final Color color;
  final String ruta;

  const _HubTile({
    required this.titulo,
    required this.subtitulo,
    required this.icono,
    required this.color,
    required this.ruta,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () => Navigator.pushNamed(context, ruta),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icono, color: color, size: 36),
          const SizedBox(height: AppSpacing.sm),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              titulo,
              style: AppType.body.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                  letterSpacing: 0.5),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            subtitulo,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppType.eyebrow.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
