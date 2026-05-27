import 'package:flutter/material.dart';

import '../../shared/constants/app_colors.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

/// Tema unificado de la app — REFACTOR 2026-05-24.
///
/// **Cambios clave vs. el theme anterior:**
/// - Brand cobalto (`AppColors.brand`) llega a todo: AppBar icons,
///   primary buttons, FAB, focus borders, ListTile iconColor.
/// - Radius unificado a [AppRadius.lg] (16) en cards, inputs, buttons.
///   Antes: 14/16/22/25 mezclados.
/// - Tipografía wireada a [AppType]: AppBar titles → [AppType.heading],
///   button labels → [AppType.heading] sin uppercase, hints → [AppType.label].
/// - Shadows aliviadas. La heavy shadow del login card sale (blur 25 →
///   blur 12, offset (0,8)). El dark gradient + el surface tier ya
///   separan visualmente.
class AppTheme {
  AppTheme._();

  static ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.surface0,

    colorScheme: const ColorScheme.dark(
      primary: AppColors.brand,
      onPrimary: Colors.white,
      secondary: AppColors.brandSoft,
      surface: AppColors.surface2,
      onSurface: AppColors.textPrimary,
      error: AppColors.error,
    ),

    // --- APP BAR ---
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      iconTheme: const IconThemeData(color: AppColors.textPrimary),
      titleTextStyle: AppType.heading.copyWith(letterSpacing: 0),
    ),

    // --- INPUTS ---
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface2,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.lg,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: const BorderSide(color: AppColors.brand, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: const BorderSide(color: AppColors.error, width: 1),
      ),
      labelStyle: AppType.label,
      // Antes: white24 — ilegible. Subido a textTertiary (white54).
      hintStyle: AppType.label.copyWith(color: AppColors.textTertiary),
    ),

    // --- BOTONES ---
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.brand,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        padding: const EdgeInsets.symmetric(
          vertical: AppSpacing.lg,
          horizontal: AppSpacing.xl,
        ),
        // Sentence-case. Sin letterSpacing.
        textStyle: AppType.heading.copyWith(letterSpacing: 0),
        minimumSize: const Size(0, 48), // touch target
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.brand,
        textStyle: AppType.heading.copyWith(letterSpacing: 0),
        minimumSize: const Size(0, 44),
      ),
    ),

    // --- CARDS ---
    cardTheme: CardThemeData(
      color: AppColors.surface2,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.borderSubtle, width: 1),
      ),
      margin: const EdgeInsets.symmetric(
        vertical: AppSpacing.sm,
        horizontal: 0,
      ),
    ),

    // --- LIST TILES ---
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.textSecondary,
      textColor: AppColors.textPrimary,
      contentPadding: EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
    ),

    // --- SNACKBARS ---
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surface3,
      contentTextStyle: AppType.body.copyWith(color: AppColors.textPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
    ),

    // --- FAB ---
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.brand,
      foregroundColor: Colors.white,
      elevation: 2,
    ),

    // --- DIVIDERS ---
    dividerTheme: const DividerThemeData(
      color: AppColors.borderSubtle,
      thickness: 1,
      space: AppSpacing.lg,
    ),

    // --- NAV RAIL / BOTTOM NAV ---
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: AppColors.surface1,
      selectedIconTheme: const IconThemeData(color: AppColors.brand, size: 24),
      unselectedIconTheme: const IconThemeData(
        color: AppColors.textTertiary,
        size: 22,
      ),
      selectedLabelTextStyle: AppType.label.copyWith(
        color: AppColors.brand,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: AppType.label,
      useIndicator: true,
      indicatorColor: const Color(0x1A0EA5E9), // brand @ 10%
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: AppColors.surface1,
      selectedItemColor: AppColors.brand,
      unselectedItemColor: AppColors.textTertiary,
      selectedLabelStyle: AppType.label.copyWith(
        color: AppColors.brand,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelStyle: AppType.label,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
  );
}
