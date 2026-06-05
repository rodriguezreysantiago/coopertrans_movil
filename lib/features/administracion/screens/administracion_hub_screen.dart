// lib/features/administracion/screens/administracion_hub_screen.dart
//
// Hub del módulo "Administración" — agrupa los submenús de gestión interna
// (RRHH y similares) dentro del Panel de control.
//
// Patrón Núcleo / bento idéntico al del LogisticaHubScreen / IcmHubScreen /
// GomeriaV2HubScreen — banner informativo + grid responsive de tiles.
//
// Primer submenú: VACACIONES (placeholder). Se agregan más a medida que se
// arme cada uno (Santiago va sumando).

import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/responsive_grid.dart';
import '../../../shared/widgets/app_widgets.dart';

import 'admin_vacaciones_screen.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Hub del módulo Administración. Por ahora 1 tile (Vacaciones); se suman
/// más a medida que se vayan armando los submenús internos.
class AdministracionHubScreen extends StatelessWidget {
  const AdministracionHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Administración',
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _BannerInfo(),
            const SizedBox(height: AppSpacing.lg),
            Expanded(
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  // Mismas thresholds que LogisticaHubScreen — Windows
                  // desktop / tablet / mobile. Con 1 sola tile el grid igual
                  // funciona, y al sumar tiles la grilla se rearma sola.
                  final w = constraints.maxWidth;
                  final int columnas;
                  if (w >= 1100) {
                    columnas = 5;
                  } else if (w >= 800) {
                    columnas = 4;
                  } else if (w >= 540) {
                    columnas = 3;
                  } else {
                    columnas = 2;
                  }
                  const totalTiles = 1; // sumar al agregar submenús
                  final filas = (totalTiles / columnas).ceil();
                  const spacing = AppSpacing.mdDense;
                  final ratio = computeGridRatio(
                    boxWidth: constraints.maxWidth,
                    boxHeight: constraints.maxHeight,
                    cols: columnas,
                    rows: filas,
                    spacing: spacing,
                    fallback: 1.05,
                  );
                  return GridView.count(
                    crossAxisCount: columnas,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: spacing,
                    childAspectRatio: ratio,
                    children: [
                      _HubTile(
                        titulo: 'Vacaciones',
                        subtitulo: 'Solicitudes, calendario y saldo',
                        icono: Icons.beach_access_outlined,
                        builder: (_) => const AdminVacacionesScreen(),
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

/// Banner informativo en la cabecera del hub. Mismo gesto firma que los otros
/// hubs del sistema (AppCard glow + eyebrow).
class _BannerInfo extends StatelessWidget {
  const _BannerInfo();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      glow: true,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c.surface3,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(Icons.admin_panel_settings_outlined,
                size: 16, color: c.brand),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppEyebrow('Gestión interna'),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Submenús de administración del personal y procesos '
                  'internos. Empezamos con vacaciones; se irán sumando '
                  'más a medida que los necesitemos.',
                  style: AppType.bodySm.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tile bento del hub — mismo diseño que LogisticaHubScreen._HubTile pero
/// con `builder` (WidgetBuilder) en lugar de `ruta`, así arrancamos sin
/// tener que registrar la ruta en AppRouter (la sumamos cuando Vacaciones
/// esté lista y se quiera deep-linkear).
class _HubTile extends StatelessWidget {
  final String titulo;
  final String subtitulo;
  final IconData icono;
  final WidgetBuilder builder;

  const _HubTile({
    required this.titulo,
    required this.subtitulo,
    required this.icono,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: builder),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
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
              // Sin contador todavía — cuando un submenú tenga una colección
              // contable, se suma `_StreamCount` acá (patrón de LogisticaHub).
              Icon(Icons.arrow_outward, size: 14, color: c.textMuted),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titulo,
                style: AppType.h5.copyWith(color: c.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitulo,
                style: AppType.monoSm.copyWith(color: c.textMuted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
