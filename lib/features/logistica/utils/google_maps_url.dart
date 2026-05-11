/// Parser de URLs / strings de Google Maps para extraer `lat` y `lng`.
///
/// Caso de uso (Santiago 2026-05-12): el operador busca el lugar en
/// Google Maps, copia el link y lo pega — más rápido que el picker
/// dentro de la app cuando ya sabe dónde está (ej. "Sea White,
/// Bahía Blanca" — google lo encuentra al toque por nombre).
///
/// **Formatos soportados**:
///
///   1. URL completa con `@<lat>,<lng>,<zoom>z`:
///      `https://www.google.com/maps/place/Nombre/@-38.7167,-62.2667,15z/...`
///
///   2. URL con query `?q=<lat>,<lng>`:
///      `https://www.google.com/maps?q=-38.7167,-62.2667`
///      `https://maps.google.com/maps?ll=-38.7167,-62.2667`
///
///   3. Coordenadas pegadas directo (sin URL):
///      `-38.7167,-62.2667`
///      `-38.7167, -62.2667`  (con espacio)
///      `-38.7167° -62.2667°` (con símbolo grado, raro pero soportado)
///
/// **No soporta** (devuelven null):
///   - Short URLs `maps.app.goo.gl/...` → requieren HTTP follow.
///     Si recibe una, el caller debería avisar al user "expandí el
///     link en el browser primero".
///   - Strings que parecen URL pero sin coords (place IDs, etc.).
class GoogleMapsUrlParser {
  GoogleMapsUrlParser._();

  /// Intenta extraer `(lat, lng)` del string. Devuelve null si no
  /// puede parsear. Las coords deben estar en rango válido
  /// (-90..90 para lat, -180..180 para lng) sino las descarta.
  static ({double lat, double lng})? extraer(String? input) {
    if (input == null) return null;
    final s = input.trim();
    if (s.isEmpty) return null;

    // 1. Patrón `@<lat>,<lng>` (URL de Google Maps con coord en el path).
    //    Más específico que el resto — buscamos primero porque las URLs
    //    suelen tener varios pares de números y este es el "real".
    final atMatch = RegExp(
      r'@(-?\d+\.\d+),(-?\d+\.\d+)',
    ).firstMatch(s);
    if (atMatch != null) {
      final r = _validar(atMatch.group(1)!, atMatch.group(2)!);
      if (r != null) return r;
    }

    // 2. Query param `q=<lat>,<lng>` o `ll=<lat>,<lng>`.
    final queryMatch = RegExp(
      r'[?&](?:q|ll|center)=(-?\d+\.\d+),(-?\d+\.\d+)',
    ).firstMatch(s);
    if (queryMatch != null) {
      final r = _validar(queryMatch.group(1)!, queryMatch.group(2)!);
      if (r != null) return r;
    }

    // 3. Par de coords pegadas directo. Acepta separador "," o ", ".
    //    Defensivo: si el string es solo coords (sin URL alrededor),
    //    también funciona.
    final pareMatch = RegExp(
      r'(-?\d+\.\d+)\s*[,°]\s*(-?\d+\.\d+)',
    ).firstMatch(s);
    if (pareMatch != null) {
      final r = _validar(pareMatch.group(1)!, pareMatch.group(2)!);
      if (r != null) return r;
    }

    return null;
  }

  /// Detecta short URLs de Google Maps que requieren follow HTTP.
  /// Útil para que la UI muestre un mensaje específico al user.
  static bool esShortUrl(String? input) {
    if (input == null) return false;
    final s = input.trim().toLowerCase();
    return s.contains('maps.app.goo.gl') ||
        s.contains('goo.gl/maps') ||
        s.contains('g.co/');
  }

  static ({double lat, double lng})? _validar(String latStr, String lngStr) {
    final lat = double.tryParse(latStr);
    final lng = double.tryParse(lngStr);
    if (lat == null || lng == null) return null;
    if (lat < -90 || lat > 90) return null;
    if (lng < -180 || lng > 180) return null;
    return (lat: lat, lng: lng);
  }
}
