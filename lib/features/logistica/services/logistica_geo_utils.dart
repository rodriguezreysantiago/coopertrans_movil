// Helpers de geocoding + cálculos geodésicos para el módulo Logística.
//
// Geocoding: usa Nominatim (OpenStreetMap) — free, sin API key. Política
// de uso: 1 req/seg max, User-Agent obligatorio. Limitamos a Argentina
// (countrycodes=ar) para que la búsqueda sea relevante al operador
// (que va a buscar "Tres Arroyos" o "Bahía Blanca", no "Madrid").
//
// Distancia: geodésica (Haversine) usando latlong2.Distance(). Útil
// para mostrar "X km en línea recta" entre origen y destino. La
// distancia POR RUTA real necesita una API distinta (OSRM, Mapbox,
// Google Routes) — eso queda para cuando armemos el motor de
// planeamiento.

import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';

import '../../../shared/constants/map_constants.dart';

/// Resultado de búsqueda en Nominatim.
class GeoLugar {
  final String displayName;
  final LatLng punto;
  final String? localidad;
  final String? provincia;
  final String? direccion;

  const GeoLugar({
    required this.displayName,
    required this.punto,
    this.localidad,
    this.provincia,
    this.direccion,
  });
}

/// Resultado de routing OSRM. `puntos` define la geometría de la ruta
/// real (cada vértice es un giro o ajuste). Para dibujar la línea
/// curva en el mapa.
class GeoRuta {
  final double distanciaKm;
  final Duration duracion;
  final List<LatLng> puntos;

  const GeoRuta({
    required this.distanciaKm,
    required this.duracion,
    required this.puntos,
  });

  /// "3h 20min" o "45min" según corresponda. Útil para mostrar al lado
  /// de la distancia en cards.
  String get duracionFormateada {
    final h = duracion.inHours;
    final m = duracion.inMinutes - h * 60;
    if (h == 0) return '${m}min';
    return '${h}h ${m}min';
  }
}

class LogisticaGeoUtils {
  LogisticaGeoUtils._();

  // Token Mapbox centralizado en MapConstants.mapboxToken para que
  // rotar sea 1 sola edición (compartido con MiniMapaThumbnail).
  static String get _mapboxToken => MapConstants.mapboxToken;
  static bool get _tieneMapbox => MapConstants.tieneMapbox;

  // Cliente Dio dedicado para Nominatim (fallback gratis).
  static final Dio _dioNominatim = Dio(
    BaseOptions(
      baseUrl: 'https://nominatim.openstreetmap.org',
      headers: {
        // Política de Nominatim: User-Agent identificable + email
        // de contacto para reportes de abuso. Vecchi usa solo a
        // ritmo humano (operador cargando ubicaciones), bien debajo
        // del rate limit de 1 req/seg.
        'User-Agent': 'CoopertransMovil/1.0 (santiagocoopertrans@gmail.com)',
        'Accept-Language': 'es-AR,es;q=0.9',
      },
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  // Cliente para Mapbox Geocoding API. Solo se inicializa lazy si hay
  // token configurado. 100K req/mes free, después USD 0.75/1000.
  static final Dio _dioMapbox = Dio(
    BaseOptions(
      baseUrl: 'https://api.mapbox.com',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  /// Busca lugares por texto. Si MAPBOX_TOKEN está configurado usa
  /// Mapbox Geocoding (más preciso para silos / direcciones rurales
  /// AR); sino fallback a Nominatim. En ambos casos limitado a
  /// Argentina + máximo 8 resultados.
  static Future<List<GeoLugar>> buscar(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    if (_tieneMapbox) {
      try {
        return await _buscarMapbox(q);
      } catch (_) {
        // Si Mapbox falla (rate limit, key inválida, sin red),
        // intentamos con Nominatim como segunda chance. Mejor algo
        // que nada para el operador.
      }
    }
    return _buscarNominatim(q);
  }

  static Future<List<GeoLugar>> _buscarMapbox(String q) async {
    // Endpoint legacy v5 — más estable y barato que v6 search-box.
    // bbox de Argentina para filtrar resultados (-73.6,-55.0,-53.6,-21.8).
    final res = await _dioMapbox.get<Map<String, dynamic>>(
      '/geocoding/v5/mapbox.places/$q.json',
      queryParameters: {
        'access_token': _mapboxToken,
        'country': 'ar',
        'limit': 8,
        'language': 'es',
        'types': 'place,locality,neighborhood,address,poi',
      },
    );
    final features = res.data?['features'] as List<dynamic>? ?? [];
    return features
        .map((f) => _parseMapboxFeature(f as Map<String, dynamic>))
        .whereType<GeoLugar>()
        .toList();
  }

  static Future<List<GeoLugar>> _buscarNominatim(String q) async {
    final res = await _dioNominatim.get<List<dynamic>>(
      '/search',
      queryParameters: {
        'q': q,
        'format': 'json',
        'countrycodes': 'ar',
        'limit': 8,
        'addressdetails': 1,
      },
    );
    final data = res.data ?? [];
    return data
        .map((raw) => _parseSearchHit(raw as Map<String, dynamic>))
        .whereType<GeoLugar>()
        .toList();
  }

  /// Reverse geocoding: dado un punto, devuelve localidad/provincia/
  /// dirección. Mapbox > Nominatim si hay token.
  static Future<GeoLugar?> reverso(LatLng punto) async {
    if (_tieneMapbox) {
      try {
        return await _reversoMapbox(punto);
      } catch (_) {
        // fallback a Nominatim
      }
    }
    return _reversoNominatim(punto);
  }

  static Future<GeoLugar?> _reversoMapbox(LatLng punto) async {
    final res = await _dioMapbox.get<Map<String, dynamic>>(
      '/geocoding/v5/mapbox.places/'
      '${punto.longitude.toStringAsFixed(6)},'
      '${punto.latitude.toStringAsFixed(6)}.json',
      queryParameters: {
        'access_token': _mapboxToken,
        'language': 'es',
        'types': 'place,locality,neighborhood,address',
      },
    );
    final features = res.data?['features'] as List<dynamic>? ?? [];
    if (features.isEmpty) return null;
    return _parseMapboxFeature(
      features.first as Map<String, dynamic>,
      fallbackPunto: punto,
    );
  }

  static Future<GeoLugar?> _reversoNominatim(LatLng punto) async {
    final res = await _dioNominatim.get<Map<String, dynamic>>(
      '/reverse',
      queryParameters: {
        'lat': punto.latitude.toStringAsFixed(6),
        'lon': punto.longitude.toStringAsFixed(6),
        'format': 'json',
        'zoom': 14, // ~ciudad/pueblo, suficiente para localidad
        'addressdetails': 1,
      },
    );
    final data = res.data;
    if (data == null) return null;
    return _parseSearchHit(data, fallbackPunto: punto);
  }

  static GeoLugar? _parseMapboxFeature(
    Map<String, dynamic> raw, {
    LatLng? fallbackPunto,
  }) {
    final center = raw['center'] as List<dynamic>?;
    LatLng? punto;
    if (center != null && center.length >= 2) {
      // Mapbox devuelve [lon, lat] (estilo GeoJSON).
      punto = LatLng(
        (center[1] as num).toDouble(),
        (center[0] as num).toDouble(),
      );
    } else {
      punto = fallbackPunto;
    }
    if (punto == null) return null;
    // Mapbox da el contexto (jerarquía de lugares) en raw['context'].
    final ctx = (raw['context'] as List<dynamic>?) ?? const [];
    String? localidad;
    String? provincia;
    for (final c in ctx) {
      final m = c as Map<String, dynamic>;
      final id = (m['id'] ?? '').toString();
      final text = m['text']?.toString();
      if (id.startsWith('place.') || id.startsWith('locality.')) {
        localidad ??= text;
      } else if (id.startsWith('region.')) {
        provincia ??= text;
      }
    }
    // Si el feature mismo es un lugar, considerarlo como localidad.
    final placeType =
        (raw['place_type'] as List<dynamic>?)?.cast<String>() ?? const [];
    if (placeType.contains('place') || placeType.contains('locality')) {
      localidad ??= raw['text']?.toString();
    }
    return GeoLugar(
      displayName: raw['place_name']?.toString() ?? raw['text']?.toString() ?? '',
      punto: punto,
      localidad: localidad,
      provincia: provincia,
      direccion: placeType.contains('address')
          ? raw['place_name']?.toString()
          : null,
    );
  }

  static GeoLugar? _parseSearchHit(
    Map<String, dynamic> raw, {
    LatLng? fallbackPunto,
  }) {
    final lat = double.tryParse(raw['lat']?.toString() ?? '');
    final lon = double.tryParse(raw['lon']?.toString() ?? '');
    final punto = (lat != null && lon != null) ? LatLng(lat, lon) : fallbackPunto;
    if (punto == null) return null;
    final addr = raw['address'] as Map<String, dynamic>? ?? const {};
    // Nominatim devuelve la localidad bajo distintas keys según el
    // tipo de lugar (city/town/village/hamlet/...). Las leemos en
    // orden de preferencia.
    final localidad = addr['city']?.toString() ??
        addr['town']?.toString() ??
        addr['village']?.toString() ??
        addr['hamlet']?.toString() ??
        addr['municipality']?.toString();
    final provincia = addr['state']?.toString() ?? addr['region']?.toString();
    final calle = addr['road']?.toString();
    final numero = addr['house_number']?.toString();
    final direccion = (calle != null)
        ? (numero != null ? '$calle $numero' : calle)
        : null;
    return GeoLugar(
      displayName: raw['display_name']?.toString() ?? '',
      punto: punto,
      localidad: localidad,
      provincia: provincia,
      direccion: direccion,
    );
  }

  /// Distancia geodésica entre dos puntos en kilómetros (línea recta).
  /// Útil como fallback cuando OSRM no responde, o para sort rápido.
  static double distanciaKm(LatLng a, LatLng b) {
    return const Distance().as(LengthUnit.Kilometer, a, b);
  }

  // ─── Routing ─────────────────────────────────────────────────────

  // Cliente Dio dedicado para OSRM. Server público (free, sin API
  // key, sin SLA). Para producción seria a futuro evaluar Mapbox
  // Directions o levantar un OSRM propio.
  static final Dio _dioOsrm = Dio(
    BaseOptions(
      baseUrl: 'https://router.project-osrm.org',
      headers: {
        'User-Agent': 'CoopertransMovil/1.0 (santiagocoopertrans@gmail.com)',
      },
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
    ),
  );

  // Cache en memoria: mismo par origen-destino no se recalcula
  // dentro de la sesión. Las rutas son inmutables — los caminos no
  // cambian (salvo cierres temporales que OSRM no modela).
  static final Map<String, GeoRuta> _cacheRutas = {};

  /// Obtiene la ruta real (línea siguiendo carreteras) entre dos
  /// puntos, con distancia y tiempo estimado de manejo. Devuelve null
  /// si OSRM no puede resolver (sin red, par fuera del grafo, etc).
  /// El caller debe tener fallback (mostrar línea recta + distancia
  /// geodésica con `distanciaKm`).
  static Future<GeoRuta?> obtenerRuta(LatLng origen, LatLng destino) async {
    final key = '${origen.latitude},${origen.longitude}|'
        '${destino.latitude},${destino.longitude}';
    final cached = _cacheRutas[key];
    if (cached != null) return cached;

    try {
      // OSRM espera lon,lat (no lat,lon). overview=full devuelve la
      // geometría completa; geometries=geojson para parsearla
      // directo a List<LatLng>.
      final coords = '${origen.longitude},${origen.latitude};'
          '${destino.longitude},${destino.latitude}';
      final res = await _dioOsrm.get<Map<String, dynamic>>(
        '/route/v1/driving/$coords',
        queryParameters: {
          'overview': 'full',
          'geometries': 'geojson',
        },
      );
      final data = res.data;
      if (data == null || data['code'] != 'Ok') return null;
      final routes = data['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) return null;
      final r = routes.first as Map<String, dynamic>;
      final distanciaM = (r['distance'] as num?)?.toDouble() ?? 0;
      final duracionS = (r['duration'] as num?)?.toDouble() ?? 0;
      final geometry = r['geometry'] as Map<String, dynamic>?;
      final coordsRaw = geometry?['coordinates'] as List<dynamic>? ?? [];
      // OSRM devuelve [lon, lat] — invertir para LatLng.
      final puntos = coordsRaw.map((c) {
        final pair = c as List<dynamic>;
        return LatLng(
          (pair[1] as num).toDouble(),
          (pair[0] as num).toDouble(),
        );
      }).toList();
      final ruta = GeoRuta(
        distanciaKm: distanciaM / 1000,
        duracion: Duration(seconds: duracionS.round()),
        puntos: puntos,
      );
      _cacheRutas[key] = ruta;
      return ruta;
    } catch (_) {
      return null;
    }
  }

  /// Limpia el cache de rutas. Útil si en algún momento queremos
  /// forzar recálculo (raro — las rutas son estables).
  static void invalidarCacheRutas() {
    _cacheRutas.clear();
  }
}
