// Constantes compartidas para todos los widgets que renderizan mapas
// con `flutter_map`. Centralizadas para que cambiar el provider o el
// estilo sea un solo edit.
//
// Tile provider: Carto Voyager. Mejor calidad visual que OSM raw,
// gratis sin API key, con subdomains para distribuir carga.
// Atribución: © OpenStreetMap contributors © CARTO.
//
// Si en el futuro queremos satellite o terrain, evaluar:
//   - Mapbox: https://api.mapbox.com/styles/v1/mapbox/satellite-v9/...
//     (free 50K loads/mes, requiere API key)
//   - Esri: https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/
//     (free, sin API key, atribución obligatoria)

import 'package:latlong2/latlong.dart';

class MapConstants {
  MapConstants._();

  /// URL de tiles. Carto Voyager — más nítida que OSM raw, gratis.
  /// Subdomains a/b/c/d distribuyen las requests.
  static const String tileUrl =
      'https://{s}.basemaps.cartocdn.com/voyager/{z}/{x}/{y}.png';

  /// Subdomains para `TileLayer.subdomains`.
  static const List<String> tileSubdomains = ['a', 'b', 'c', 'd'];

  /// Identificación obligatoria por la política del proveedor + OSM.
  static const String userAgent = 'com.coopertrans.movil';

  /// Centro default cuando no hay punto inicial. Bahía Blanca, base
  /// operativa de Vecchi.
  static const LatLng defaultCenter = LatLng(-38.7167, -62.2667);

  /// Texto de atribución que mostramos en `RichAttributionWidget` o
  /// `SimpleAttributionWidget` para cumplir términos de uso.
  static const String attribution = '© OpenStreetMap · © CARTO';
}
