// REFACTOR NÚCLEO · jun 2026
//
// Configuración de ThemeData oscuro y claro. Usa AppColorsExt como extension
// para que widgets accedan a la paleta vía `context.colors.brand`.
//
// MIGRATION NOTES — main.dart:
//
// MaterialApp(
//   theme: AppTheme.light(),
//   darkTheme: AppTheme.dark(),
//   themeMode: ThemeMode.system,  // o ThemeMode.dark para cabina
//   ...
// );
//
// MULTIPLATAFORMA — esta clase es agnóstica del target. Para chrome de
// ventana en macOS / Windows y status bar en iOS / Android, ver:
//   - lib/core/theme/platform_chrome.dart (a crear — ver PROMPT_FOR_CLAUDE_CODE.md)
//
// El tema activa font fallbacks para asegurar que en plataformas donde
// google_fonts no resuelva (sin internet en primer arranque), el sistema
// caiga a Inter / SF Pro / Segoe UI según target.

import 'package:flutter/material.dart';
import '../../shared/constants/app_colors.dart';
import 'app_radius.dart';
import 'app_typography.dart';

class AppTheme {
  AppTheme._();

  static ThemeData dark() => _build(brightness: Brightness.dark);
  static ThemeData light() => _build(brightness: Brightness.light);

  static ThemeData _build({required Brightness brightness}) {
    final isDark = brightness == Brightness.dark;
    final ext = isDark ? AppColorsExt.forDark() : AppColorsExt.forLight();

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary:    ext.brand,
      onPrimary:  ext.brandFg,
      secondary:  ext.brandSoft,
      onSecondary: ext.brandFg,
      surface:    ext.surface2,
      onSurface:  ext.text,
      error:      ext.error,
      onError:    Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: ext.bg,
      canvasColor: ext.bg,
      dividerColor: ext.border,
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.adaptivePlatformDensity,

      // Transición de página sobria Núcleo: fade + slide vertical sutil, en vez
      // del slide/zoom Material default (brusco en desktop). iOS conserva la
      // transición Cupertino para no perder el swipe-back nativo por gesto.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          // iOS NO se incluye a propósito → usa el default de Flutter
          // (Cupertino), para conservar el swipe-back nativo por gesto.
          TargetPlatform.android: _NucleoPageTransitionsBuilder(),
          TargetPlatform.windows: _NucleoPageTransitionsBuilder(),
          TargetPlatform.macOS: _NucleoPageTransitionsBuilder(),
          TargetPlatform.linux: _NucleoPageTransitionsBuilder(),
        },
      ),

      // Texto default — Geist (embebida en assets/fonts/). Material widgets que
      // no usen AppType directamente toman esta familia.
      fontFamily: 'Geist',
      textTheme: ThemeData(brightness: brightness).textTheme.apply(
        bodyColor: ext.text,
        displayColor: ext.text,
        fontFamily: 'Geist',
        fontFamilyFallback: const ['Roboto', 'SF Pro Text', 'Segoe UI', 'sans-serif'],
      ),

      // Botones — un AppButton manual reemplaza esto pero los Material
      // defaults quedan razonables.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ext.brand,
          foregroundColor: ext.brandFg,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
          textStyle: AppType.body.copyWith(fontWeight: FontWeight.w600),
          minimumSize: const Size(0, 44),  // iOS HIG min touch target
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ext.text,
          side: BorderSide(color: ext.border),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
          textStyle: AppType.body.copyWith(fontWeight: FontWeight.w600),
          minimumSize: const Size(0, 44),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ext.brand,
          textStyle: AppType.body.copyWith(fontWeight: FontWeight.w600),
        ),
      ),

      // Inputs — match nuestro AppInput
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ext.surface2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: ext.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: ext.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: ext.borderFocus, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: ext.error),
        ),
        labelStyle: AppType.eyebrow.copyWith(color: ext.textMuted),
        hintStyle: AppType.body.copyWith(color: ext.textPlaceholder),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),

      // Cards — neutralizamos defaults; usamos AppCard.
      cardTheme: CardThemeData(
        color: ext.surface2,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: ext.border),
          borderRadius: BorderRadius.circular(AppRadius.xl),
        ),
      ),

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: ext.bg,
        foregroundColor: ext.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppType.h5.copyWith(color: ext.text),
      ),

      // Dialog
      dialogTheme: DialogThemeData(
        backgroundColor: ext.surface2,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xxl)),
      ),

      // Bottom sheet
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: ext.surface2,
        modalBackgroundColor: ext.surface2,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        ),
      ),

      // Selection
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: ext.brand,
        selectionColor: ext.brand.withValues(alpha: 0.3),
        selectionHandleColor: ext.brand,
      ),

      extensions: [ext],
    );
  }
}

// El typedef `_Palette = AppColorsExt` se eliminó: `_build` ya no recibe un
// `palette` (usaba AppColorsExt.forDark()/forLight() internamente igual). El
// original no compilaba — pasaba `AppColors.dark` (tipo _Palette privado de
// app_colors.dart) a un parámetro tipado AppColorsExt.

/// Transición de página del Núcleo: fade + un leve desplazamiento vertical
/// (~1.5% de la altura) con easeOutCubic. Sobria — reemplaza el zoom/slide
/// Material default en Android y desktop. iOS usa Cupertino (swipe-back).
class _NucleoPageTransitionsBuilder extends PageTransitionsBuilder {
  const _NucleoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final fade = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.015),
          end: Offset.zero,
        ).animate(fade),
        child: child,
      ),
    );
  }
}
