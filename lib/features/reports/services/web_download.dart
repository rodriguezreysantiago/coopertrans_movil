// Punto de entrada multiplataforma para disparar la descarga de bytes (un
// .xlsx generado en memoria) desde la app — el equivalente web del "guardar
// archivo" que en desktop hace el file picker y en móvil hace SharePlus.
//
// Selecciona la implementación según la plataforma de COMPILACIÓN, igual que
// `core/window/desktop_window.dart`:
//
//   - sin dart:io (web)             → web_download_web.dart  (Blob + <a download>)
//   - con dart:io (móvil + desktop) → web_download_stub.dart (throw — no se usa)
//
// Así `package:web` + `dart:js_interop` —que NO compilan en la VM nativa—
// nunca entran al build móvil/desktop. En esas plataformas el guardado va por
// File/Process/SharePlus en `ReportSaveHelper`, y el branch `kIsWeb` corta
// antes, así que el stub jamás se invoca.
//
// El discriminador `dart.library.io` ya está validado en este proyecto: es
// `false` en web (por eso `desktop_window.dart` usa el mismo truco para que
// `window_manager`/dart:io no entre al build web, que está en vivo).
export 'web_download_web.dart'
    if (dart.library.io) 'web_download_stub.dart';
