// REFACTOR NÚCLEO · jun 2026 — fix del fondo violeta gigante.
//
// EL BUG:
// La versión anterior pintaba en `body` un `LinearGradient(brandDark →
// background)` con stop 0 → 55%, es decir un degradé indigo SATURADO que
// invadía la mitad superior del viewport. Esto era la firma visual del
// "rebrand 2026-05-24" — pero pelea con AppAmbient (gesto Núcleo, radial
// sutil), produciendo el efecto "Hola Santi sobre fondo morado eléctrico"
// del screenshot que mandó Santiago.
//
// EL FIX:
// 1. Default `showBackground: true` mantiene compatibilidad — pero ahora
//    pinta `colors.bg` (near-black sólido) + un `AppAmbient` MUY sutil
//    (intensity 0.4) anclado en la esquina superior derecha. Look Núcleo
//    out-of-the-box para todas las pantallas que aún no fueron migradas.
// 2. Las pantallas que YA tienen su propio AppAmbient en el body
//    (admin_panel_screen, main_panel) van a ver dos ambients sumándose,
//    pero como cada uno es sutil el resultado sigue siendo casi negro.
// 3. Para volver al gradient legacy explícito (no lo necesitamos en
//    Núcleo): pasar `legacyGradient: true`. Solo dejado por compat.

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import 'app_ambient.dart';
import 'app_shell_context.dart';
import 'coopertrans_logo.dart';

import 'package:coopertrans_movil/core/theme/app_typography.dart';

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

  /// Si `true`, vuelve al LinearGradient brandDark→bg de la versión 2026-05-24.
  /// NUEVO en Núcleo: por defecto `false` (fondo sólido + ambient sutil).
  final bool legacyGradient;

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
    this.legacyGradient = false,
  });

  @override
  Widget build(BuildContext context) {
    final isEmbedded = AppShellContext.of(context);
    final c = context.colors;

    // Si estamos dentro de un shell, solo devolvemos el body + FAB.
    // El shell se encarga del AppBar, fondo, navegación y SafeArea.
    if (isEmbedded) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: bottom != null
            ? Column(children: [bottom!, Expanded(child: body)])
            : body,
        floatingActionButton: floatingActionButton,
        floatingActionButtonLocation: floatingActionButtonLocation,
      );
    }

    final effectiveOverlay = overlayColor ?? Colors.black.withAlpha(200);

    return Scaffold(
      backgroundColor: c.bg, // ← Núcleo: fondo sólido near-black
      extendBodyBehindAppBar: showBackground,
      appBar: AppBar(
        title: title != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CoopertransLogo(size: CoopertransLogoSize.s),
                  const SizedBox(width: 10),
                  Container(width: 1, height: 14, color: c.border),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      title!,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.heading.copyWith(
                          fontWeight: FontWeight.w600, letterSpacing: 1.2),
                    ),
                  ),
                ],
              )
            : const CoopertransLogo(size: CoopertransLogoSize.s),
        leading: leading,
        actions: actions,
        centerTitle: false,
        titleSpacing: 12,
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: c.text,
        bottom: bottom,
      ),
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      body: showBackground
          ? Stack(
              children: [
                // Fondo base: sólido near-black de Núcleo.
                Positioned.fill(child: ColoredBox(color: c.bg)),

                // OPT-IN: gradient legacy (NO se usa en Núcleo).
                if (legacyGradient)
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
                  )
                else
                  // NÚCLEO: ambient glow sutil en la esquina superior derecha.
                  // Si la pantalla además tiene su propio AppAmbient (ej.
                  // admin_panel_screen, main_panel) el resultado se suma pero
                  // a opacities bajas — sigue siendo casi negro.
                  const AppAmbient(
                    alignment: Alignment(0.9, -1.1),
                    sizeFactor: 0.8,
                    intensity: 0.4,
                  ),

                if (overlayColor != null)
                  Positioned.fill(child: Container(color: effectiveOverlay)),
                SafeArea(child: body),
              ],
            )
          : SafeArea(child: body),
    );
  }
}
