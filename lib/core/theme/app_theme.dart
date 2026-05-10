import 'package:flutter/material.dart';

import '../../shared/constants/app_colors.dart';

class AppTheme {
  // ===========================================================================
  // PALETA DE COLORES CENTRALIZADA (Design Tokens)
  // ===========================================================================
  // _bgColor / _surfaceColor coinciden con AppColors.background/surface — se
  // dejan como aliases locales para no romper el resto del archivo.
  static const Color _bgColor = AppColors.background;
  static const Color _surfaceColor = AppColors.surface;

  // _primaryColor migrado de `Colors.greenAccent` (default Flutter accent que
  // sobrevivía del prototipo) al brand cobalto del rebrand 2026-05-03. Sin
  // este cambio, todo lo que usaba `Theme.of(context).colorScheme.primary`
  // (botones, FAB, focused borders, iconTheme del AppBar, etc.) seguía
  // pintando verde — el rebrand quedaba a medias.
  static const Color _primaryColor = AppColors.brand;

  // _secondaryColor / _errorColor son semánticos (warnings, errores), NO
  // brand. Se mantienen para que la jerarquía visual no se rompa.
  // Migrados a tokens AppColors (2026-05-10) para que cualquier cambio
  // futuro de paleta semántica se haga en un solo lugar.
  static const Color _secondaryColor = AppColors.accentOrange;
  static const Color _errorColor = AppColors.accentRed;
  static const Color _textPrimary = Colors.white;
  static const Color _textSecondary = Colors.white54;

  // ===========================================================================
  // TEMA PRINCIPAL
  // ===========================================================================
  static ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: _bgColor,
    colorScheme: const ColorScheme.dark(
      primary: _primaryColor,
      secondary: _secondaryColor,
      surface: _surfaceColor,
      error: _errorColor,
    ),

    // --- APP BAR ---
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      iconTheme: IconThemeData(
        color: _primaryColor,
      ),
      titleTextStyle: TextStyle(
        color: _textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),

    // --- INPUTS (Campos de texto) ---
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: _surfaceColor,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 18,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(
          color: _primaryColor,
          width: 1.5,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(
          color: _errorColor,
          width: 1,
        ),
      ),
      labelStyle: const TextStyle(
        color: _textSecondary,
        fontSize: 13,
      ),
      hintStyle: const TextStyle(
        color: Colors.white24,
        fontSize: 12,
      ),
    ),

    // --- BOTONES ---
    // foregroundColor blanco (no negro como tenía el theme verde anterior) —
    // sobre el cobalto #0EA5E9 contrasta mejor y queda alineado con
    // `_BotonIngresar` del login que ya usa blanco desde el rebrand.
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(
          vertical: 16,
          horizontal: 24,
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 16,
        ),
      ),
    ),

    // --- TARJETAS (Cards) ---
    // ✅ CORRECCIÓN: Adaptado al nuevo estándar CardThemeData de Flutter
    cardTheme: CardThemeData(
      color: _surfaceColor,
      elevation: 4,
      shadowColor: Colors.black45,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withAlpha(10), width: 1),
      ),
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
    ),

    // --- LIST TILES ---
    listTileTheme: const ListTileThemeData(
      iconColor: _primaryColor,
      textColor: _textPrimary,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    ),

    // --- SNACKBARS (Notificaciones emergentes) ---
    snackBarTheme: SnackBarThemeData(
      backgroundColor: _surfaceColor,
      contentTextStyle: const TextStyle(color: _textPrimary, fontWeight: FontWeight.w500),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      behavior: SnackBarBehavior.floating,
    ),

    // --- FLOATING ACTION BUTTON (Botón flotante) ---
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: _primaryColor,
      foregroundColor: Colors.white,
      elevation: 6,
    ),
  );
}