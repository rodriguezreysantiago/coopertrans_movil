// Bottom sheet con opciones para abrir un punto en apps de navegación
// externa. Reusable desde cards de ubicación y desde el detalle de
// tarifa en el mapa.
//
// Por simplicidad y consistencia visual, mostramos siempre las dos
// opciones (Google Maps + Waze). Si el dispositivo no tiene la app
// instalada, `url_launcher` fall-backea al browser — el usuario
// igual termina con un mapa abierto.

import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../services/map_navigation_helper.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
class AccionesNavegacionSheet extends StatelessWidget {
  final double lat;
  final double lng;
  final String? label;

  const AccionesNavegacionSheet({
    super.key,
    required this.lat,
    required this.lng,
    this.label,
  });

  /// Helper para abrir el sheet desde cualquier widget.
  static Future<void> abrir(
    BuildContext context, {
    required double lat,
    required double lng,
    String? label,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      builder: (_) => AccionesNavegacionSheet(
        lat: lat,
        lng: lng,
        label: label,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.md),
              child: Text(
                label!,
                style: AppType.heading.copyWith(fontSize: 15),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.md),
            child: Text(
              '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
              style: AppType.label.copyWith(
                  color: AppColors.textSecondary, fontFamily: 'monospace'),
            ),
          ),
          const Divider(color: AppColors.borderSubtle, height: 1),
          ListTile(
            leading: const Icon(Icons.map_outlined,
                color: AppColors.info),
            title: const Text(
              'Abrir en Google Maps',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: Text(
              'Ver ubicación en Google Maps',
              style:
                  AppType.label.copyWith(color: AppColors.textSecondary),
            ),
            onTap: () async {
              final ok = await MapNavigationHelper.abrirEnGoogleMaps(
                lat: lat,
                lng: lng,
                label: label,
              );
              if (!context.mounted) return;
              Navigator.pop(context);
              if (!ok) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('No se pudo abrir Google Maps'),
                  ),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.navigation,
                color: AppColors.brandSoft),
            title: const Text(
              'Navegar con Waze',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: Text(
              'Iniciar navegación en Waze',
              style:
                  AppType.label.copyWith(color: AppColors.textSecondary),
            ),
            onTap: () async {
              final ok = await MapNavigationHelper.abrirEnWaze(
                lat: lat,
                lng: lng,
              );
              if (!context.mounted) return;
              Navigator.pop(context);
              if (!ok) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('No se pudo abrir Waze'),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
