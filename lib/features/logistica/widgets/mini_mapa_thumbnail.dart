// Thumbnail estático de un punto geográfico, para mostrar al lado de
// cards de ubicación.
//
// Usa Mapbox Static Images API. El token se embebe como defaultValue
// (mismo patrón que Sentry y que LogisticaGeoUtils para geocoding).
// 50K loads/mes free, después USD 0.04/1000. Para Vecchi: ~9K/mes
// estimados, sobra el free tier.
//
// Si por alguna razón el token está vacío (override en build) o el
// fetch falla, fallback a un placeholder gráfico con ícono.
//
// Cache: usa `Image.network` que cachea automáticamente en disco /
// memoria via flutter framework. La misma URL se carga una vez.

import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/constants/map_constants.dart';

class MiniMapaThumbnail extends StatelessWidget {
  final double lat;
  final double lng;
  final double size;
  final double zoom;

  const MiniMapaThumbnail({
    super.key,
    required this.lat,
    required this.lng,
    this.size = 60,
    this.zoom = 12,
  });

  // Token Mapbox centralizado en MapConstants — compartido con
  // LogisticaGeoUtils (Geocoding API). Rotar el token = 1 sola
  // edición en map_constants.dart.
  static String get _mapboxToken => MapConstants.mapboxToken;
  static bool get _tieneMapbox => MapConstants.tieneMapbox;

  @override
  Widget build(BuildContext context) {
    if (!_tieneMapbox) {
      return _placeholder();
    }
    final url = _mapboxStaticUrl();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // Mientras carga, mostrar el placeholder. Si falla, idem.
        loadingBuilder: (ctx, child, prog) {
          if (prog == null) return child;
          return _placeholder();
        },
        errorBuilder: (_, __, ___) => _placeholder(),
      ),
    );
  }

  String _mapboxStaticUrl() {
    // Estilo "streets-v12" — match visual al mapa interactivo.
    // Pin rojo en el centro como marcador.
    final lonLat = '$lng,$lat';
    return 'https://api.mapbox.com/styles/v1/mapbox/streets-v12/static/'
        'pin-s+e74c3c($lonLat)/'
        '$lonLat,${zoom.toStringAsFixed(0)}/'
        '${size.toInt()}x${size.toInt()}@2x'
        '?access_token=$_mapboxToken';
  }

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.brandSoft.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: AppColors.brandSoft.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.place_outlined,
          color: AppColors.brandSoft,
          size: 24,
        ),
      ),
    );
  }
}
