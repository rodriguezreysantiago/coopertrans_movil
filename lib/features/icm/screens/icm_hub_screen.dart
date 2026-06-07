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
///   1. Grid de navegación (bento): Ranking / Reporte mensual / Mapa de calor /
///      Jornada — las acciones que el operador más usa, arriba de todo.
///   2. Personas: top 5 mejores (verde) + top 5 a mejorar (rojo).
///   3. Panorama: KPI ICM flota del mes + tendencia ICM oficial Sitrack diaria.
///
/// Tile "DETALLE POR CHOFER" eliminado 2026-05-23 — el operador prefiere
/// abrir el portal Sitrack para drill-down real; la pantalla daba poco
/// valor agregado (mismos números que ya aparecen en el reporte).
///
/// Los widgets ricos (KpiGrandeCard, TendenciaIcmChart, TopChoferesLista)
/// antes vivían en el panel de inicio del admin (mudados al ICM Hub
/// 2026-05-23 por decisión de Santiago). Ya están migrados a Núcleo y se
/// reusan TAL CUAL (no se tocan acá). Comparten clases con
/// `VistaEjecutivaService` (KpiIcm, PuntoTendencia, ChoferRankingItem).
///
/// El número que muestra el módulo es EL que audita YPF: lo calcula
/// Sitrack con su cartografía de segmento vial (urbano/no-urbano), dato
/// que nosotros no tenemos. Se ingiere a `ICM_OFICIAL/{YYYY-MM}` con el
/// scraper `sitrack_sync/sync_icm.py` (1 vez al día).
///
/// REFACTOR NÚCLEO (jun 2026): re-estilizado SIN tocar la capa de datos.
/// El State (`_futureKpis`, `_cargar`, `_refrescar`), `IcmHubService.cargarKpis`,
/// `KpisIcmHub`/`periodoLabel` y la navegación quedan intactos — sólo se
/// reescribió el árbol de widgets: tiles de navegación a bento (icon chip
/// indigo + eyebrow), labels de sección en `textMuted` y los widgets ricos
/// (ya Núcleo) reordenados alrededor.
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
    final c = context.colors;
    return AppScaffold(
      title: 'ICM — Conducta de Manejo',
      body: RefreshIndicator(
        onRefresh: _refrescar,
        color: c.brand,
        backgroundColor: c.surface2,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            // Orden 2026-05-24: primero los accesos (Ranking, Reporte mensual,
            // Mapa de calor, Jornada), después Personas y al final los
            // gráficos. Antes era al revés (gráficos arriba) y el operador
            // tenía que scrollear para llegar a las acciones que más usa.
            const _GridSubpantallas(),
            const SizedBox(height: AppSpacing.xl),
            FutureBuilder<KpisIcmHub>(
              future: _futureKpis,
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const _SeccionesSkeleton();
                }
                if (snap.hasError) {
                  return AppErrorState(
                    title: 'No se pudieron cargar los KPIs del ICM',
                    subtitle: snap.error.toString(),
                    onRetry: _cargar,
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

/// Las 3 secciones ricas del hub: Personas (2 top 5) + Panorama (KPI ICM
/// flota + tendencia). Reusa los widgets de `vista_ejecutiva` (ya migrados
/// a Núcleo) sin tocarlos.
class _SeccionesIcm extends StatelessWidget {
  final KpisIcmHub kpis;
  const _SeccionesIcm({required this.kpis});

  @override
  Widget build(BuildContext context) {
    final esDesktop = MediaQuery.of(context).size.width >= 800;
    // Sufijo con el mes que realmente se muestra (puede no ser el actual si
    // recién arrancó y todavía no hay ICM de Sitrack — el service cae al
    // último mes con datos).
    final sufijoPeriodo =
        kpis.periodoLabel.isEmpty ? '' : ' · ${kpis.periodoLabel}';
    // KPI ICM flota + Tendencias lado a lado en desktop. En mobile siguen
    // apilados, card primero.
    final cardIcm = KpiGrandeCard.icm(
      label: 'ICM flota',
      kpi: kpis.icmFlota,
      icono: Icons.leaderboard,
      onTap: () => Navigator.pushNamed(
          context, AppRoutes.adminIcmReporteSemanal),
    );
    final chartTendencia = TendenciaIcmChart(
      puntos: kpis.tendenciaIcm,
      titulo: 'ICM oficial Sitrack · por día$sufijoPeriodo',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ─── Personas: top 5 mejores + top 5 a mejorar ───
        AppEyebrow('Personas$sufijoPeriodo'),
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
              const SizedBox(width: AppSpacing.mdDense),
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
          const SizedBox(height: AppSpacing.mdDense),
          TopChoferesLista(
            titulo: 'TOP 5 — A MEJORAR',
            icono: Icons.priority_high,
            colorTitulo: AppColors.error,
            items: kpis.top5Peores,
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        // ─── ICM flota + Tendencias (lado a lado en desktop) — AL FINAL ───
        AppEyebrow('Panorama$sufijoPeriodo'),
        const SizedBox(height: AppSpacing.sm),
        if (esDesktop)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 280, child: cardIcm),
                const SizedBox(width: AppSpacing.mdDense),
                Expanded(child: chartTendencia),
              ],
            ),
          )
        else ...[
          cardIcm,
          const SizedBox(height: AppSpacing.mdDense),
          chartTendencia,
        ],
      ],
    );
  }
}

/// Skeleton de las secciones ricas mientras carga el future (en lugar de un
/// box gris pelado — imita la silueta de Personas + Panorama).
class _SeccionesSkeleton extends StatelessWidget {
  const _SeccionesSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSkeleton.box(height: 14, width: 120),
        SizedBox(height: AppSpacing.md),
        AppSkeleton.box(height: 180),
        SizedBox(height: AppSpacing.xl),
        AppSkeleton.box(height: 14, width: 120),
        SizedBox(height: AppSpacing.md),
        AppSkeleton.box(height: 200),
      ],
    );
  }
}

/// Grid de las 4 sub-pantallas de navegación, en bento Núcleo.
class _GridSubpantallas extends StatelessWidget {
  const _GridSubpantallas();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final w = constraints.maxWidth;
        // Desktop 4×1, tablet 2×2, mobile 1 col.
        final cols = w >= 800 ? 4 : (w >= 540 ? 2 : 1);
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: AppSpacing.mdDense,
          mainAxisSpacing: AppSpacing.mdDense,
          childAspectRatio: cols == 1 ? 3.0 : 1.25,
          children: const [
            _HubTile(
              titulo: 'Ranking',
              subtitulo: 'Choferes ordenados por ICM (#1 = mejor)',
              icono: Icons.leaderboard_outlined,
              ruta: AppRoutes.adminIcmRanking,
            ),
            _HubTile(
              titulo: 'Reporte mensual',
              subtitulo: 'Flota + severidad + top 5',
              icono: Icons.assessment_outlined,
              ruta: AppRoutes.adminIcmReporteSemanal,
            ),
            _HubTile(
              titulo: 'Mapa de calor',
              subtitulo: 'Lugares y horarios con más infracciones',
              icono: Icons.map_outlined,
              ruta: AppRoutes.adminIcmMapaCalor,
            ),
            _HubTile(
              titulo: 'Jornada',
              subtitulo: 'Inicio, paradas y descansos por chofer + día',
              icono: Icons.timeline,
              ruta: AppRoutes.adminIcmJornadaDia,
            ),
            _HubTile(
              titulo: 'Jornada real (v3)',
              subtitulo: 'Registro a posteriori: manejo, pausas y confianza',
              icono: Icons.fact_check_outlined,
              ruta: AppRoutes.adminRegistroJornada,
            ),
          ],
        );
      },
    );
  }
}

/// Tile de navegación bento: icon chip indigo (única tinta) + título + sub.
/// Alineado a la izquierda (no centrado) — patrón de tile de acción del
/// sistema. El acento de color es siempre brand; lo semántico queda para
/// dots/badges de datos, no para chrome de navegación.
class _HubTile extends StatelessWidget {
  final String titulo;
  final String subtitulo;
  final IconData icono;
  final String ruta;

  const _HubTile({
    required this.titulo,
    required this.subtitulo,
    required this.icono,
    required this.ruta,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      onTap: () => Navigator.pushNamed(context, ruta),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c.surface3,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(icono, size: 16, color: c.brand),
              ),
              const Spacer(),
              Icon(Icons.arrow_outward, size: 14, color: c.textMuted),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            titulo,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.h5.copyWith(color: c.text),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            subtitulo,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppType.monoSm.copyWith(color: c.textMuted),
          ),
        ],
      ),
    );
  }
}
