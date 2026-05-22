import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';

/// Hub del módulo ICM (Índice de Conducta de Manejo). 4 sub-pantallas:
///
/// - **RANKING**: choferes del peor al mejor según el ICM OFICIAL de
///   Sitrack del mes (más bajo = mejor).
/// - **REPORTE MENSUAL**: ICM de la flota + severidad + top 5.
/// - **MAPA DE CALOR**: distribución geográfica de infracciones
///   (placeholder hasta tener data acumulada).
/// - **DETALLE POR CHOFER**: ICM oficial del mes, urbano/no-urbano,
///   infracciones y comparativa con el mes anterior.
///
/// El número que muestra el módulo es EL que audita YPF: lo calcula
/// Sitrack con su cartografía de segmento vial (urbano/no-urbano), dato
/// que nosotros no tenemos. Se ingiere a `ICM_OFICIAL/{YYYY-MM}` con el
/// scraper `sitrack_sync/sync_icm.py` (1 vez al día). Reemplaza el cálculo
/// CESVI interno, que daba números optimistas que no coincidían con YPF.
class IcmHubScreen extends StatelessWidget {
  const IcmHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'ICM — Conducta de Manejo',
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _BannerInfo(),
            const SizedBox(height: 16),
            Expanded(
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final w = constraints.maxWidth;
                  final cols = w >= 800 ? 4 : (w >= 540 ? 2 : 1);
                  return GridView.count(
                    crossAxisCount: cols,
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
              ),
            ),
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
