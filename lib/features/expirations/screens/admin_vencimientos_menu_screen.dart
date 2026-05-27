import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
/// Menú principal de auditoría de vencimientos.
class AdminVencimientosMenuScreen extends StatelessWidget {
  const AdminVencimientosMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Auditoría de Vencimientos',
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 20),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 10, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AUDITORÍA PREVENTIVA (60 DÍAS)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.success,
                    letterSpacing: 1.5,
                  ),
                ),
                SizedBox(height: AppSpacing.xs),
                Text(
                  'Control proactivo de documentación próxima a vencer.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // REVISIONES movido acá 2026-05-24 (estaba como tab propio del
          // shell). Conceptualmente vive con vencimientos: el chofer carga
          // un trámite que vence pronto, el admin lo aprueba o lo rechaza
          // desde acá. Lo mantenemos primero porque es la acción más
          // urgente del día (cosas en bandeja esperando aprobación).
          //
          // Badge con el mismo stream que el tab "Vencimientos" del shell
          // (admin_shell.dart línea ~103): así el rojo afuera y el rojo
          // adentro apuntan al mismo lugar y se sabe qué responder.
          _MenuTile(
            titulo: 'REVISIONES',
            subtitulo: 'Aprobar/rechazar trámites cargados por choferes',
            icono: Icons.fact_check_outlined,
            colorIcono: AppColors.surface3,
            ruta: AppRoutes.adminRevisiones,
            badgeStream: FirebaseFirestore.instance
                .collection(AppCollections.revisiones)
                .where('estado', isEqualTo: 'PENDIENTE')
                .limit(100)
                .snapshots(),
          ),
          const _MenuTile(
            titulo: 'CALENDARIO MENSUAL',
            subtitulo: 'Vista global con todos los vencimientos por día',
            icono: Icons.event_note,
            colorIcono: AppColors.surface3,
            ruta: '/vencimientos_calendario',
          ),
          const _MenuTile(
            titulo: 'VENCIMIENTOS DE PERSONAL',
            subtitulo: 'Seguimiento de carnets, preocupacional y ART',
            icono: Icons.person_search,
            colorIcono: AppColors.surface3,
            ruta: '/vencimientos_choferes',
          ),
          const _MenuTile(
            titulo: 'VENCIMIENTOS DE TRACTORES',
            subtitulo: 'Control de RTO y seguros de camiones',
            icono: Icons.local_shipping,
            colorIcono: AppColors.surface3,
            ruta: '/vencimientos_chasis',
          ),
          const _MenuTile(
            titulo: 'VENCIMIENTOS DE ENGANCHES',
            subtitulo: 'Auditoría de bateas, tolvas, bivuelcos y tanques',
            icono: Icons.grid_view,
            colorIcono: AppColors.surface3,
            ruta: '/vencimientos_acoplados',
          ),
          // ─── ABM por empresa empleadora ───
          // Visualmente separado: arriba son auditorías por persona /
          // unidad; este es ABM de docs comunes a todos los empleados de
          // una misma razón social (Póliza ART y Formulario 931).
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 16, 8),
            child: Text(
              'POR EMPRESA EMPLEADORA',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppColors.info,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const _MenuTile(
            titulo: 'EMPRESAS Y SEGUROS',
            subtitulo: 'Póliza ART y Formulario 931 por razón social',
            icono: Icons.business_outlined,
            colorIcono: AppColors.surface3,
            ruta: AppRoutes.adminEmpresasEmpleadoras,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 25, vertical: 30),
            child: Divider(color: Colors.white10),
          ),
          const Center(
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
  /// Si está seteado, se renderiza un badge rojo con el count del stream
  /// arriba a la derecha del icono — mismo patrón que `admin_shell.dart`
  /// usa en el rail. Útil para que el rojo del menú padre y el del tile
  /// hijo apunten visualmente al mismo lugar.
  final Stream<QuerySnapshot>? badgeStream;

  const _MenuTile({
    required this.titulo,
    required this.subtitulo,
    required this.icono,
    required this.colorIcono,
    required this.ruta,
    this.badgeStream,
  });

  Widget _buildIcono(BuildContext context) {
    // Phase 6.3 (design-system refactor 2026-05-27): dropeamos la
    // categorizacion por color. Disc neutro (surface3) + icono blanco
    // (textPrimary) en TODOS los tiles. La identidad del modulo viene
    // del icono + etiqueta, no del color. Si en el futuro se quiere
    // re-introducir color, hacer un branch sobre colorIcono igual a
    // surface3 (default) -> neutro, otro -> usar como antes.
    final esNeutro = colorIcono == AppColors.surface3;
    final iconoBase = Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: esNeutro ? AppColors.surface3 : colorIcono.withAlpha(30),
        shape: BoxShape.circle,
      ),
      child: Icon(
        icono,
        color: esNeutro ? AppColors.textPrimary : colorIcono,
        size: 24,
      ),
    );
    if (badgeStream == null) return iconoBase;
    return StreamBuilder<QuerySnapshot>(
      stream: badgeStream,
      builder: (context, snap) {
        final count = snap.data?.docs.length ?? 0;
        if (count == 0) return iconoBase;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            iconoBase,
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                constraints: const BoxConstraints(
                  minWidth: 18,
                  minHeight: 18,
                ),
                decoration: BoxDecoration(
                  color: AppColors.error,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 1.5,
                  ),
                ),
                child: Text(
                  count > 99 ? '99+' : '$count',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: AppCard(
        onTap: () => Navigator.pushNamed(context, ruta),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            _buildIcono(context),
            const SizedBox(width: AppSpacing.lg),
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
                  const SizedBox(height: AppSpacing.xs),
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
