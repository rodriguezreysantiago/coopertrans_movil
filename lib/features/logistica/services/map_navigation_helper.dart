// Helper para abrir un punto geográfico en apps de navegación externa
// (Google Maps, Waze) o web fallback. Útil desde cards y bottom sheets:
// "Quiero ir a este silo" → tap → se abre Maps o Waze listo para
// navegar.
//
// Estrategia por plataforma:
//   - Android: intent URI `geo:lat,lng?q=lat,lng(label)` que respeta
//     la app default de mapas del usuario (Google Maps, Maps.me, etc.).
//     Para forzar Waze: `https://waze.com/ul?ll=lat,lng&navigate=yes`.
//   - iOS: HTTPS universal link de Google Maps
//     `https://www.google.com/maps/search/?api=1&query=lat,lng` (abre la
//     app de Google Maps si está instalada, sino el navegador). Waze:
//     `https://waze.com/ul?ll=lat,lng&navigate=yes`. NO usamos los schemes
//     nativos comgooglemaps:// / waze:// (necesitarían
//     LSApplicationQueriesSchemes en Info.plist, que no está declarado).
//   - Windows / Web: link web a Google Maps en el browser.
//
// Como Vecchi opera multi-plataforma (admin Windows + chofer Android),
// el helper detecta la plataforma y elige la URL apropiada. La UI
// muestra "Abrir en Google Maps" siempre — el usuario no necesita
// saber qué scheme se usa por debajo.

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

class MapNavigationHelper {
  MapNavigationHelper._();

  /// Abre Google Maps (o equivalente nativo) centrado en el punto.
  /// `label` opcional: se muestra como nombre del marcador.
  /// Devuelve true si se pudo lanzar la URL.
  static Future<bool> abrirEnGoogleMaps({
    required double lat,
    required double lng,
    String? label,
  }) async {
    final uri = _googleMapsUri(lat: lat, lng: lng, label: label);
    return _launch(uri);
  }

  /// Abre Waze listo para navegar al punto. En Windows/Web cae al
  /// link web (que igual abre la app si está instalada en el SO).
  static Future<bool> abrirEnWaze({
    required double lat,
    required double lng,
  }) async {
    // Waze deeplink universal — funciona desde browser y abre la
    // app si está instalada.
    final uri = Uri.parse(
      'https://waze.com/ul?ll=$lat,$lng&navigate=yes',
    );
    return _launch(uri);
  }

  static Uri _googleMapsUri({
    required double lat,
    required double lng,
    String? label,
  }) {
    if (kIsWeb) {
      return Uri.parse('https://www.google.com/maps?q=$lat,$lng');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        // `geo:` intent — abre la app default de mapas del SO.
        // El query duplica las coords con label opcional para
        // que aparezca un pin con el nombre.
        final lab = label != null ? '($label)' : '';
        return Uri.parse('geo:$lat,$lng?q=$lat,$lng$lab');
      case TargetPlatform.iOS:
        // HTTPS universal link: abre la app de Google Maps si está
        // instalada, sino Google Maps en el navegador (no Apple Maps).
        // No usamos comgooglemaps:// para no depender de
        // LSApplicationQueriesSchemes en el Info.plist.
        return Uri.parse(
          'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
        );
      default:
        // Windows, macOS desktop, Linux, fuchsia → link web.
        return Uri.parse('https://www.google.com/maps?q=$lat,$lng');
    }
  }

  static Future<bool> _launch(Uri uri) async {
    try {
      if (await canLaunchUrl(uri)) {
        return launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // ignored — return false abajo
    }
    return false;
  }
}
