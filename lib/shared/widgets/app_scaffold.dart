import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import 'app_shell_context.dart';
import 'coopertrans_logo.dart';

import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Scaffold unificado con fondo de imagen + overlay oscuro.
/// Reemplaza el patrón repetido de Stack con Positioned.fill + Image.asset.
///
/// Uso típico:
/// ```
/// AppScaffold(
///   title: 'Gestión de Flota',
///   actions: [IconButton(...)],
///   floatingActionButton: FloatingActionButton(...),
///   body: ListView(...),
/// );
/// ```
///
/// **Modo embebido (shell):** si la pantalla está dentro de un shell de
/// navegación (ej: AdminShell con NavigationRail), AppScaffold detecta
/// el [AppShellContext] y solo renderiza el body + FAB. El AppBar y
/// el fondo decorado los pone el shell.
///
/// Si la pantalla NO debe tener el fondo decorado (ej: pantallas internas
/// de visor/preview), pasar `showBackground: false`.
class AppScaffold extends StatelessWidget {
  final String? title;
  final List<Widget>? actions;
  final Widget body;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final PreferredSizeWidget? bottom;
  final Widget? leading;
  final bool showBackground;
  final bool centerTitle;
  final Color? overlayColor;

  const AppScaffold({
    super.key,
    this.title,
    this.actions,
    required this.body,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottom,
    this.leading,
    this.showBackground = true,
    this.centerTitle = true,
    this.overlayColor,
  });

  @override
  Widget build(BuildContext context) {
    final isEmbedded = AppShellContext.of(context);

    // Si estamos dentro de un shell, solo devolvemos el body + FAB.
    // El shell se encarga del AppBar, fondo, navegación y SafeArea.
    if (isEmbedded) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        // El bottom (TabBar etc.) lo respetamos en modo embedded:
        // si la pantalla lo necesita, lo ponemos arriba del body.
        body: bottom != null
            ? Column(
                children: [
                  bottom!,
                  Expanded(child: body),
                ],
              )
            : body,
        floatingActionButton: floatingActionButton,
        floatingActionButtonLocation: floatingActionButtonLocation,
      );
    }

    // Modo normal (full screen, sin shell): comportamiento original.
    final effectiveOverlay =
        overlayColor ?? Colors.black.withAlpha(200);

    return Scaffold(
      extendBodyBehindAppBar: showBackground,
      appBar: AppBar(
        title: title != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CoopertransLogo(size: CoopertransLogoSize.s),
                  const SizedBox(width: 10),
                  Container(
                    width: 1,
                    height: 14,
                    color: Colors.white24,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      title!,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.heading.copyWith(fontWeight: FontWeight.bold, letterSpacing: 1.2),
                    ),
                  ),
                ],
              )
            : null,
        leading: leading,
        actions: actions,
        // El logo + separador + título es ancho variable; lo dejamos
        // alineado a la izquierda (después del back button si existe)
        // en lugar de centrado para que no quede flotando en el medio.
        centerTitle: title != null ? false : centerTitle,
        titleSpacing: 12,
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        bottom: bottom,
      ),
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      body: showBackground
          ? Stack(
              children: [
                // Gradient brand → fondo oscuro. Reemplaza la foto histórica
                // (fondo_login.jpg) por algo coherente con el rebrand visual.
                // Si una pantalla concreta quiere otro tratamiento, puede
                // pasar `showBackground: false` y armarse el suyo.
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          AppColors.brandDark,
                          AppColors.background,
                          AppColors.background,
                        ],
                        stops: [0.0, 0.55, 1.0],
                      ),
                    ),
                  ),
                ),
                // Overlay opcional (si la pantalla pidió un teñido extra
                // sobre el gradient).
                if (overlayColor != null)
                  Positioned.fill(child: Container(color: effectiveOverlay)),
                SafeArea(child: body),
              ],
            )
          : SafeArea(child: body),
    );
  }
}
