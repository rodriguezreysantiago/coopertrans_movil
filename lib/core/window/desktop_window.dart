// REFACTOR NÚCLEO · Fase 5 · ventana desktop
//
// Punto de entrada multiplataforma para configurar la ventana nativa en
// desktop. Selecciona la implementación según la plataforma de COMPILACIÓN:
//
//   - con dart:io (móvil + desktop) → desktop_window_io.dart  (usa
//     window_manager; en runtime se auto-anula si NO es desktop)
//   - sin dart:io (web)             → desktop_window_stub.dart (no-op)
//
// Así `window_manager` —que importa dart:io y no soporta web— nunca entra al
// build web. Llamar `initDesktopWindow()` una vez desde main(), antes de
// runApp().
export 'desktop_window_stub.dart'
    if (dart.library.io) 'desktop_window_io.dart';
