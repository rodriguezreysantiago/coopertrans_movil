import 'dart:async';

import 'package:app_links/app_links.dart';

import '../constants/app_constants.dart';

/// Deep links (App Links Android / Universal Links iOS) sobre
/// `https://coopertrans-movil.web.app/app/ir/{destino}`.
///
/// Cada aviso de WhatsApp del bot termina en uno de estos links: tappearlo
/// abre la app DIRECTO en la pantalla pertinente (cierra el loop
/// aviso→acción que antes obligaba al chofer a entrar y navegar a mano).
///
/// El vocabulario de `{destino}` (keywords estables que el bot pone en las
/// URLs) se resuelve a rutas internas con [rutaDeDestino] — el MISMO mapa
/// que consumen los payloads de notificación local y, más adelante, el tap
/// de un push FCM (data.destino). Mantener los keywords estables: el bot
/// los hardcodea en las URLs.
///
/// Cold start (app cerrada → abierta por el link): si hay sesión persistida,
/// AuthGuard muestra la pantalla; si no, redirige a login y el link se
/// pierde (edge aceptable — el chofer navega a mano tras loguearse). App
/// corriendo/background: el stream navega al instante.
class DeepLinkService {
  DeepLinkService._();

  static final AppLinks _appLinks = AppLinks();
  static StreamSubscription<Uri>? _sub;

  /// keyword de `{destino}` → ruta interna (AppRoutes). Compartido por deep
  /// links, notificaciones locales y (futuro) push FCM.
  static const Map<String, String> rutasPorDestino = {
    'home': AppRoutes.home,
    'jornada': AppRoutes.miJornada,
    'vencimientos': AppRoutes.misVencimientos,
    'equipo': AppRoutes.equipo,
    'perfil': AppRoutes.perfil,
    // Compat con los payloads de notificación local existentes (mismo
    // vocabulario, sin duplicar el mapeo):
    'vencimiento': AppRoutes.misVencimientos,
    'admin_revision': AppRoutes.adminRevisiones,
  };

  /// Resuelve un keyword de destino a una ruta interna, o null si no se
  /// conoce (case-insensitive, tolera espacios).
  static String? rutaDeDestino(String? destino) {
    if (destino == null) return null;
    return rutasPorDestino[destino.trim().toLowerCase()];
  }

  /// Extrae el `{destino}` de una URI `…/app/ir/{destino}`. Devuelve null si
  /// la URI no tiene la forma esperada (no se navega).
  static String? destinoDeUri(Uri uri) {
    final s = uri.pathSegments;
    final i = s.indexOf('ir');
    if (i >= 0 && i + 1 < s.length && (i == 0 || s[i - 1] == 'app')) {
      final destino = s[i + 1].trim();
      return destino.isEmpty ? null : destino;
    }
    return null;
  }

  /// Arranca la escucha. [navegar] recibe la ruta YA resuelta; main.dart la
  /// conecta a `navigatorKey`. No-op seguro en plataformas sin soporte
  /// (Windows/web) — los `catch` evitan que un fallo del plugin tumbe el
  /// arranque de la app.
  static Future<void> iniciar(void Function(String ruta) navegar) async {
    // App fría: el link que abrió la app.
    try {
      final inicial = await _appLinks.getInitialLink();
      if (inicial != null) {
        final ruta = rutaDeDestino(destinoDeUri(inicial));
        if (ruta != null) {
          // Esperamos a que splash + grace period de AuthGuard (~1.5s) se
          // asienten antes de empujar, para no chocar con el flujo de
          // arranque (que hace pushNamedAndRemoveUntil).
          await Future<void>.delayed(const Duration(milliseconds: 1700));
          navegar(ruta);
        }
      }
    } catch (_) {
      /* sin deep link inicial o plataforma sin soporte */
    }
    // App corriendo / vuelta a foreground: links subsecuentes.
    try {
      _sub = _appLinks.uriLinkStream.listen(
        (uri) {
          final ruta = rutaDeDestino(destinoDeUri(uri));
          if (ruta != null) navegar(ruta);
        },
        onError: (_) {/* ignorar URIs inválidas */},
      );
    } catch (_) {
      /* plataforma sin soporte */
    }
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
