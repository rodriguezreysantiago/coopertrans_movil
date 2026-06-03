// REFACTOR NÚCLEO · jun 2026
//
// Configuración multiplataforma del "chrome" del SO — status bar (iOS,
// Android), title bar (macOS, Windows), browser theme-color (Chrome / web).
//
// LLAMAR UNA VEZ desde `main()` después de `WidgetsFlutterBinding.ensureInitialized()`.
// Idempotente: se puede llamar de nuevo al cambiar themeMode.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PlatformChrome {
  PlatformChrome._();

  /// Aplica los ajustes del SO al tema [brightness]. Dark = cabina,
  /// light = escritorio admin.
  static Future<void> apply(Brightness brightness) async {
    if (kIsWeb) {
      // Web: no se puede setear theme-color desde Flutter. Esto se hace en
      // web/index.html — actualizar el `<meta name="theme-color">` ahí:
      //   <meta name="theme-color" content="#050505" media="(prefers-color-scheme: dark)">
      //   <meta name="theme-color" content="#fafafa" media="(prefers-color-scheme: light)">
      return;
    }

    final isDark = brightness == Brightness.dark;

    // Edge-to-edge real (Android 15 / SDK 35): el contenido se dibuja DEBAJO de
    // las barras del sistema. Es la forma Flutter-nativa de opt-in — el engine
    // hace el setup correcto para SDK 35 (sin tocar las APIs nativas deprecadas
    // de color de barra) y los insets los toma SafeArea en cada Scaffold. En
    // iOS/desktop es no-op. Reemplaza al (intransitable) enableEdgeToEdge() de
    // androidx en MainActivity.
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // -------------------------------------------------------------------------
    // iOS · Android — status bar + bottom nav (edge-to-edge, SDK 35+)
    // -------------------------------------------------------------------------
    // Las barras van TRANSPARENTES: en Android 15 el contenido se dibuja detrás
    // de ellas (edge-to-edge) y los insets los maneja SafeArea en cada Scaffold.
    // Setear un color OPACO en la nav bar usa setNavigationBarColor, deprecado
    // en SDK 35 y disparador del warning de Play Console. Solo controlamos el
    // brillo de los íconos para que contrasten con el fondo near-black.
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light, // iOS
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    ));

    // -------------------------------------------------------------------------
    // Orientación — la app no rota en móvil, fija portrait. Tablet libre.
    // -------------------------------------------------------------------------
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      // Landscape habilitado solo si es desktop o tablet — Flutter detecta
      // automáticamente con shortestSide del screen al inicializar.
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // -------------------------------------------------------------------------
    // macOS / Windows — title bar
    // Se hace con `window_manager` (ver pubspec) en `setupDesktopWindow()` —
    // este método solo afecta SystemUiOverlayStyle. Para chrome nativo de
    // ventana, ver lib/main.dart `_initDesktopWindow()`.
    // -------------------------------------------------------------------------
  }
}

/// LLAMAR desde main() ANTES de runApp() en plataformas desktop. Configura
/// el tamaño mínimo, el título y el color de la title bar.
///
/// Requiere `window_manager: ^0.4.2` en pubspec.yaml.
///
/// ```dart
/// import 'package:window_manager/window_manager.dart';
///
/// Future<void> _initDesktopWindow() async {
///   if (kIsWeb || !(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;
///
///   await windowManager.ensureInitialized();
///   const opts = WindowOptions(
///     size: Size(1440, 900),
///     minimumSize: Size(1200, 720),
///     center: true,
///     title: 'Coopertrans · Ops',
///     backgroundColor: Color(0xFF050505),
///     titleBarStyle: TitleBarStyle.hidden, // o .normal con backgroundColor
///   );
///   await windowManager.waitUntilReadyToShow(opts, () async {
///     await windowManager.show();
///     await windowManager.focus();
///   });
/// }
/// ```
class DesktopWindow {
  DesktopWindow._();
}
