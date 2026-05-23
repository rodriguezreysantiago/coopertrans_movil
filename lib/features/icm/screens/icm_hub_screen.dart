import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../vista_ejecutiva/widgets/kpi_grande_card.dart';
import '../../vista_ejecutiva/widgets/tendencia_icm_chart.dart';
import '../../vista_ejecutiva/widgets/top_choferes_lista.dart';
import '../services/icm_hub_service.dart';

/// Hub del módulo ICM (Índice de Conducta de Manejo).
///
/// Layout (de arriba abajo):
///
///   1. Banner explicativo (escala oficial Sitrack — más bajo = mejor).
///   2. KPI grande: ICM flota del mes + variación vs mes anterior.
///   3. Tendencia ICM oficial Sitrack — por día del mes en curso.
///   4. Grid de 4 sub-pantallas:
///      - RANKING: choferes ordenados por ICM.
///      - REPORTE MENSUAL: flota + severidad + top 5.
///      - MAPA DE CALOR: distribución geográfica de infracciones.
///      - DETALLE POR CHOFER: drill-down individual.
///   5. Top 5 mejores choferes (verde).
///   6. Top 5 a mejorar (rojo).
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
        color: AppColors.accentGreen,
        backgroundColor: AppColors.surface,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            const _BannerInfo(),
            const SizedBox(height: 16),
            FutureBuilder<KpisIcmHub>(
              future: _futureKpis,
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: CircularProgressIndicator(
                          color: AppColors.accentGreen),
                    ),
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
            const SizedBox(height: 20),
            const _GridSubpantallas(),
          ],
        ),
      ),
    );
  }
}

class _BannerInfo extends StatelessWidget {
  const _BannerInfo();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.accentBlue.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.accentBlue.withValues(alpha: 0.30),
        ),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, color: AppColors.accentBlue, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'ICM oficial de Sitrack — el mismo número que audita YPF. '
              'Acá MÁS BAJO = MEJOR (la flota ronda ~20). Color por '
              'severidad: verde sin/pocas infracciones, amarillo medio, '
              'rojo alto. Se actualiza una vez al día.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
        ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ─── KPI ICM flota (card grande única) ───
        const _SeccionLabel('ICM flota'),
        const SizedBox(height: 10),
        // En desktop la card ocupa media pantalla (no se ve gigante);
        // en mobile va full-width.
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: esDesktop ? 280 : double.infinity,
              minHeight: 140,
            ),
            child: KpiGrandeCard.icm(
              label: 'ICM flota',
              kpi: kpis.icmFlota,
              icono: Icons.leaderboard,
              onTap: () => Navigator.pushNamed(
                  context, AppRoutes.adminIcmReporteSemanal),
            ),
          ),
        ),
        const SizedBox(height: 24),
        // ─── Tendencia ICM oficial ───
        const _SeccionLabel('Tendencias'),
        const SizedBox(height: 10),
        TendenciaIcmChart(
          puntos: kpis.tendenciaIcm,
          titulo: 'ICM oficial Sitrack · por día (mes en curso)',
        ),
        const SizedBox(height: 24),
        // ─── Personas: top 5 mejores + top 5 a mejorar ───
        const _SeccionLabel('Personas'),
        const SizedBox(height: 10),
        if (esDesktop)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TopChoferesLista(
                  titulo: 'TOP 5 — MEJORES CHOFERES',
                  icono: Icons.emoji_events,
                  colorTitulo: AppColors.accentGreen,
                  items: kpis.top5Mejores,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TopChoferesLista(
                  titulo: 'TOP 5 — A MEJORAR',
                  icono: Icons.priority_high,
                  colorTitulo: AppColors.accentRed,
                  items: kpis.top5Peores,
                ),
              ),
            ],
          )
        else ...[
          TopChoferesLista(
            titulo: 'TOP 5 — MEJORES CHOFERES',
            icono: Icons.emoji_events,
            colorTitulo: AppColors.accentGreen,
            items: kpis.top5Mejores,
          ),
          const SizedBox(height: 10),
          TopChoferesLista(
            titulo: 'TOP 5 — A MEJORAR',
            icono: Icons.priority_high,
            colorTitulo: AppColors.accentRed,
            items: kpis.top5Peores,
          ),
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
      padding: const EdgeInsets.only(left: 6, top: 4),
      child: Text(
        texto.toUpperCase(),
        style: const TextStyle(
          color: AppColors.accentGreen,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
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
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const Icon(Icons.error_outline,
              color: AppColors.accentRed, size: 36),
          const SizedBox(height: 8),
          const Text(
            'No se pudieron cargar los KPIs del ICM',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: onReintentar,
            icon: const Icon(Icons.refresh),
            label: const Text('Reintentar'),
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
        final cols = w >= 800 ? 4 : (w >= 540 ? 2 : 1);
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: cols == 1 ? 2.4 : 1.3,
          children: const [
            _HubTile(
              titulo: 'RANKING',
              subtitulo: 'Choferes ordenados por ICM',
              icono: Icons.leaderboard_outlined,
              color: AppColors.accentBlue,
              ruta: AppRoutes.adminIcmRanking,
            ),
            _HubTile(
              titulo: 'REPORTE MENSUAL',
              subtitulo: 'Flota + severidad + top 5',
              icono: Icons.assessment_outlined,
              color: AppColors.accentGreen,
              ruta: AppRoutes.adminIcmReporteSemanal,
            ),
            _HubTile(
              titulo: 'MAPA DE CALOR',
              subtitulo: 'Lugares y horarios con más infracciones',
              icono: Icons.map_outlined,
              color: AppColors.accentOrange,
              ruta: AppRoutes.adminIcmMapaCalor,
            ),
            _HubTile(
              titulo: 'DETALLE POR CHOFER',
              subtitulo: 'Histórico individual + gráficos',
              icono: Icons.person_search_outlined,
              color: AppColors.accentTeal,
              ruta: AppRoutes.adminIcmDetalleChofer,
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
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icono, color: color, size: 36),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              titulo,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitulo,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white60,
            ),
          ),
        ],
      ),
    );
  }
}
