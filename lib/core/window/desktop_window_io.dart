// REFACTOR NÚCLEO · Fase 5 · ventana desktop — implementación real.
//
// Este archivo SÍ se compila en móvil (tiene dart:io vía window_manager), pero
// el guard por plataforma lo vuelve un no-op fuera de desktop, así que el
// plugin nunca se invoca en Android/iOS.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Configura la ventana nativa en desktop (Windows/macOS/Linux). No-op en
/// móvil. Llamar una vez desde main(), antes de runApp().
///
/// - Fondo near-black (#050505): evita el flash blanco al abrir la ventana en
///   frío (antes de que Flutter pinte el primer frame).
/// - Tamaño mínimo 1200×720: el layout admin (rail + bento) no colapsa.
/// - Title bar nativa (.normal): conserva los controles de cerrar/min/max del
///   SO. La title bar 100% custom (oculta + botones propios) queda pendiente
///   para una pasada con validación visual en vivo — en Windows, ocultarla sin
///   botones propios dejaría la ventana sin forma de cerrarse.
Future<void> initDesktopWindow() async {
  final esDesktop = defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
  if (!esDesktop) return;

  await windowManager.ensureInitialized();
  const opts = WindowOptions(
    size: Size(1440, 900),
    minimumSize: Size(1200, 720),
    center: true,
    title: 'Coopertrans Móvil',
    backgroundColor: Color(0xFF050505),
    titleBarStyle: TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
