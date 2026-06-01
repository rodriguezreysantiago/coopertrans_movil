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
  ///
  /// Nota: el path correcto es `rastertiles/voyager/`, NO solo
  /// `voyager/`. La versión sin `rastertiles/` devuelve 404 silencioso
  /// — flutter_map no muestra tiles y el mapa queda en blanco aunque
  /// los markers/clusters sigan renderizando. Bug detectado
  /// 2026-05-08 después de que TODOS los mapas de la app aparecieran
  /// vacíos.
  static const String tileUrl =
      'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png';

  /// URL de tiles satelitales HÍBRIDOS. Mapbox Satellite Streets
  /// (`satellite-streets-v12`): la imagen satelital CON las calles,
  /// rutas y sus nombres dibujados encima. Así se identifica un punto
  /// por su aspecto físico (silos, galpones, accesos a campos) Y se sabe
  /// sobre qué ruta está parado el camión (RN22, etc.) — el satélite
  /// "pelado" (`satellite-v9`) se veía incompleto para eso (Santiago
  /// 2026-06-01). Mismo token y mismo costo: el style híbrido sólo suma
  /// la capa vectorial de calles sobre la misma imagen. Cuando se accede
  /// a esta URL en runtime hay que reemplazar `{token}` por `mapboxToken`
  /// (no hay subdomains — Mapbox usa un solo host).
  static const String tileSatelliteUrlTemplate =
      'https://api.mapbox.com/styles/v1/mapbox/satellite-streets-v12/tiles/'
      '256/{z}/{x}/{y}?access_token={token}';

  /// URL de tiles satelitales LISTA para usar — token ya inyectado.
  /// Si el token no está configurado, devuelve string vacío (el
  /// caller debería skippear el toggle en ese caso).
  static String get tileSatelliteUrl => tieneMapbox
      ? tileSatelliteUrlTemplate.replaceAll('{token}', mapboxToken)
      : '';

  /// Atribución para vista satelital — exigida por Mapbox.
  static const String attributionSatelite =
      '© Mapbox · © OpenStreetMap · © Maxar';

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

  /// Token público Mapbox (embebido como defaultValue, mismo patrón
  /// que SENTRY_DSN). Los tokens `pk.` de Mapbox NO son secret — están
  /// diseñados para usarse en clientes públicos (apps mobile/desktop/
  /// web) y son extraíbles del binario igualmente. La protección
  /// contra abuso está en los scopes del token (configurados desde
  /// Mapbox Account: solo GEOCODING:READ y STYLES:READ habilitados)
  /// y los rate limits por token (Mapbox cap automático).
  ///
  /// Usado por:
  ///   - `LogisticaGeoUtils.buscar` / `.reverso` (Geocoding API)
  ///   - `MiniMapaThumbnail` (Static Images API)
  ///
  /// Para rotar: crear nuevo token en Mapbox Account → Tokens, cambiar
  /// el defaultValue de abajo + commit + redeploy. El token viejo
  /// queda activo hasta que lo borres en Mapbox.
  ///
  /// Para deshabilitar Mapbox en dev (forzar fallback a Nominatim,
  /// sin static thumbnails):
  ///   flutter run -d windows --dart-define=MAPBOX_TOKEN=
  static const String mapboxToken = String.fromEnvironment(
    'MAPBOX_TOKEN',
    defaultValue:
        'pk.eyJ1Ijoic2FudGlhZ29jb29wZXJ0cmFucyIsImEiOiJjbW93eWNpcWYwa3Z2MnFwb3dnZDRiaXRpIn0.ceoTO-MxvclzrlLlfXxflA',
  );

  /// `true` si hay token Mapbox configurado. Si está vacío (override
  /// en build), los servicios usan fallback (Nominatim para geocoding,
  /// placeholder con ícono para thumbnails).
  static bool get tieneMapbox => mapboxToken.isNotEmpty;
}
