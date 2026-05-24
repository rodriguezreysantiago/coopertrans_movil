import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';

/// Menú principal de auditoría de vencimientos.
class AdminVencimientosMenuScreen extends StatelessWidget {
  const AdminVencimientosMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Auditoría de Vencimientos',
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 20),
        children: const [
          Padding(
            padding: EdgeInsets.fromLTRB(20, 10, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AUDITORÍA PREVENTIVA (60 DÍAS)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.accentGreen,
                    letterSpacing: 1.5,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Control proactivo de documentación próxima a vencer.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          SizedBox(height: 10),
          // REVISIONES movido acá 2026-05-24 (estaba como tab propio del
          // shell). Conceptualmente vive con vencimientos: el chofer carga
          // un trámite que vence pronto, el admin lo aprueba o lo rechaza
          // desde acá. Lo mantenemos primero porque es la acción más
          // urgente del día (cosas en bandeja esperando aprobación).
          _MenuTile(
            titulo: 'REVISIONES',
            subtitulo: 'Aprobar/rechazar trámites cargados por choferes',
            icono: Icons.fact_check_outlined,
            colorIcono: AppColors.accentTeal,
            ruta: AppRoutes.adminRevisiones,
          ),
          _MenuTile(
            titulo: 'CALENDARIO MENSUAL',
            subtitulo: 'Vista global con todos los vencimientos por día',
            icono: Icons.event_note,
            colorIcono: AppColors.accentGreen,
            ruta: '/vencimientos_calendario',
          ),
          _MenuTile(
            titulo: 'VENCIMIENTOS DE PERSONAL',
            subtitulo: 'Seguimiento de carnets, preocupacional y ART',
            icono: Icons.person_search,
            colorIcono: AppColors.accentBlue,
            ruta: '/vencimientos_choferes',
          ),
          _MenuTile(
            titulo: 'VENCIMIENTOS DE TRACTORES',
            subtitulo: 'Control de RTO y seguros de camiones',
            icono: Icons.local_shipping,
            colorIcono: AppColors.accentOrange,
            ruta: '/vencimientos_chasis',
          ),
          _MenuTile(
            titulo: 'VENCIMIENTOS DE ENGANCHES',
            subtitulo: 'Auditoría de bateas, tolvas, bivuelcos y tanques',
            icono: Icons.grid_view,
            colorIcono: AppColors.accentTeal,
            ruta: '/vencimientos_acoplados',
          ),
          // ─── ABM por empresa empleadora ───
          // Visualmente separado: arriba son auditorías por persona /
          // unidad; este es ABM de docs comunes a todos los empleados de
          // una misma razón social (Póliza ART y Formulario 931).
          Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 16, 8),
            child: Text(
              'POR EMPRESA EMPLEADORA',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppColors.accentBlue,
                letterSpacing: 1.5,
              ),
            ),
          ),
          _MenuTile(
            titulo: 'EMPRESAS Y SEGUROS',
            subtitulo: 'Póliza ART y Formulario 931 por razón social',
            icono: Icons.business_outlined,
            colorIcono: AppColors.accentBlue,
            ruta: AppRoutes.adminEmpresasEmpleadoras,
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 25, vertical: 30),
            child: Divider(color: Colors.white10),
          ),
          Center(
            child: Text(
              '${AppTexts.appName} — Gestión de Flota',
              style: TextStyle(
                color: Colors.white24,
                fontSize: 10,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final String titulo;
  final String subtitulo;
  final IconData icono;
  final Color colorIcono;
  final String ruta;

  const _MenuTile({
    required this.titulo,
    required this.subtitulo,
    required this.icono,
    required this.colorIcono,
    required this.ruta,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: AppCard(
        onTap: () => Navigator.pushNamed(context, ruta),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorIcono.withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: Icon(icono, color: colorIcono, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    titulo,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitulo,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios,
                size: 16, color: Colors.white24),
          ],
        ),
      ),
    );
  }
}
