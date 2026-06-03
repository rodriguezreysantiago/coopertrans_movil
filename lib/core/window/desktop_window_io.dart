// REFACTOR NÚCLEO · Fase 5 · ventana desktop — implementación real.
//
// Este archivo SÍ se compila en móvil (tiene dart:io vía window_manager), pero
// los guards por plataforma lo vuelven un no-op fuera de desktop, así que el
// plugin nunca se invoca en Android/iOS. En web ni se compila (ver
// desktop_window.dart → usa el stub).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:coopertrans_movil/shared/constants/app_colors.dart';

bool get _esDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

/// Alto de la title bar custom (px lógicos).
const double _kTitleBarHeight = 38;

/// Configura la ventana nativa en desktop (Windows/macOS/Linux). No-op en
/// móvil. Llamar una vez desde main(), antes de runApp().
///
/// - Title bar OCULTA (`TitleBarStyle.hidden`): la dibujamos nosotros con
///   [wrapDesktopChrome] para que combine con el Núcleo (near-black). En macOS
///   dejamos visibles los semáforos nativos (traffic lights); en Windows/Linux
///   los reemplazan los botones propios de la barra custom.
/// - Fondo near-black (#050505): evita el flash blanco al abrir en frío.
/// - Tamaño mínimo 1200×720: el layout admin (rail + bento) no colapsa.
Future<void> initDesktopWindow() async {
  if (!_esDesktop) return;

  await windowManager.ensureInitialized();

  final esMac = defaultTargetPlatform == TargetPlatform.macOS;
  final opts = WindowOptions(
    size: const Size(1440, 900),
    minimumSize: const Size(1200, 720),
    center: true,
    title: 'Coopertrans Móvil',
    backgroundColor: const Color(0xFF050505),
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: esMac, // semáforos nativos solo en macOS
  );
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

/// Envuelve la app con la title bar custom en desktop. No-op en móvil (devuelve
/// el child tal cual). En web ni se compila este archivo.
Widget wrapDesktopChrome(Widget child) {
  if (!_esDesktop) return child;
  return Column(
    children: [
      const _DesktopTitleBar(),
      Expanded(child: child),
    ],
  );
}

class _DesktopTitleBar extends StatefulWidget {
  const _DesktopTitleBar();

  @override
  State<_DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<_DesktopTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refreshMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refreshMaximized() async {
    final m = await windowManager.isMaximized();
    if (mounted && m != _maximized) setState(() => _maximized = m);
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final esMac = defaultTargetPlatform == TargetPlatform.macOS;

    // Material provee el DefaultTextStyle correcto. Sin él, este chrome vive
    // FUERA del Navigator y los Text salen con el subrayado de "missing
    // material" (doble línea amarilla en debug).
    return Material(
      color: AppColors.surface1,
      child: Container(
        height: _kTitleBarHeight,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
        ),
        child: Row(
          children: [
            // En macOS, hueco para los 3 semáforos nativos.
            SizedBox(width: esMac ? 76 : 12),
            if (!esMac) ...[
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: AppColors.brand,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
            ],
            const Text(
              'Coopertrans Móvil',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
            // Resto = zona arrastrable (+ doble click maximiza/restaura).
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onDoubleTap: _toggleMaximize,
                child: const DragToMoveArea(child: SizedBox.expand()),
              ),
            ),
            if (!esMac) ...[
              _WindowButton(
                icon: Icons.remove,
                onTap: windowManager.minimize,
              ),
              _WindowButton(
                icon: _maximized
                    ? Icons.filter_none
                    : Icons.crop_square_outlined,
                iconSize: _maximized ? 13 : 15,
                onTap: _toggleMaximize,
              ),
              _WindowButton(
                icon: Icons.close,
                isClose: true,
                onTap: windowManager.close,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isClose;
  final double iconSize;

  const _WindowButton({
    required this.icon,
    required this.onTap,
    this.isClose = false,
    this.iconSize = 16,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hoverBg = widget.isClose
        ? AppColors.error
        : Colors.white.withValues(alpha: 0.07);
    final iconColor = _hover
        ? (widget.isClose ? Colors.white : AppColors.textPrimary)
        : AppColors.textSecondary;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: _kTitleBarHeight,
          color: _hover ? hoverBg : Colors.transparent,
          alignment: Alignment.center,
          child: Icon(widget.icon, size: widget.iconSize, color: iconColor),
        ),
      ),
    );
  }
}
