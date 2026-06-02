// handoff/lib/core/theme/app_theme.dart
//
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
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';
import 'app_radius.dart';
import 'app_typography.dart';

class AppTheme {
  AppTheme._();

  static ThemeData dark() => _build(brightness: Brightness.dark, palette: AppColors.dark);
  static ThemeData light() => _build(brightness: Brightness.light, palette: AppColors.light);

  static ThemeData _build({required Brightness brightness, required _Palette palette}) {
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

      // Texto default — Geist con fallbacks por plataforma.
      // Material widgets que no usen AppType directamente toman esto.
      textTheme: GoogleFonts.geistTextTheme(
        ThemeData(brightness: brightness).textTheme.apply(
          bodyColor: ext.text,
          displayColor: ext.text,
          fontFamilyFallback: const ['Inter', 'SF Pro Text', 'Segoe UI', 'Roboto', 'sans-serif'],
        ),
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
      cardTheme: CardTheme(
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
      dialogTheme: DialogTheme(
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
        selectionColor: ext.brand.withOpacity(0.3),
        selectionHandleColor: ext.brand,
      ),

      extensions: [ext],
    );
  }
}

/// Internal alias — AppColors._Palette es private. Lo exponemos como tipo
/// público dentro del paquete via this hack para que app_theme.dart compile.
typedef _Palette = AppColorsExt;
