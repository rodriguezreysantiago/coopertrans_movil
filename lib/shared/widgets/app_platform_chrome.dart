// lib/shared/widgets/app_platform_chrome.dart
//
// REFACTOR NÚCLEO · jun 2026 — chrome de plataforma (widget canónico).
//
// Envuelve la app (típicamente desde MaterialApp.builder) con el "chrome" de
// ventana que corresponde a cada plataforma:
//   - Desktop (Windows/macOS/Linux): la title bar custom Núcleo (oculta la
//     nativa + dibuja la nuestra). Delega en core/window/desktop_window, que
//     ya resuelve el caso por plataforma y es web-safe (conditional import).
//   - Móvil / web: passthrough — devuelve el child sin tocar.
//
// Es el punto ÚNICO del design system para el chrome de VENTANA. La config
// imperativa del status bar / system nav bar (móvil) vive aparte en
// core/theme/platform_chrome.dart (PlatformChrome.apply, llamada una vez en
// main); este widget no la duplica.

import 'package:flutter/widgets.dart';

import '../../core/window/desktop_window.dart';

class AppPlatformChrome extends StatelessWidget {
  final Widget child;

  const AppPlatformChrome({super.key, required this.child});

  @override
  Widget build(BuildContext context) => wrapDesktopChrome(child);
}
