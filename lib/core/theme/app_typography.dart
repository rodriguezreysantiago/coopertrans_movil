// lib/core/theme/app_typography.dart
//
// REFACTOR NÚCLEO · jun 2026
//
// Tipografía del sistema: Geist Sans (humano) + Geist Mono (técnico).
// Las fuentes están EMBEBIDAS en assets/fonts/ y declaradas en pubspec.yaml
// (family 'Geist' y 'GeistMono'). Por eso los estilos son `const TextStyle`
// directos — NO via google_fonts (runtime) — para que los cientos de
// `const Text(style: AppType.body)` del codebase sigan compilando.
//
// Color: usamos los tokens `const` de AppColors (textPrimary/Secondary/...),
// no `AppColors.dark.text` (acceso a field de instancia → no es const).

import 'package:flutter/material.dart';

import '../../shared/constants/app_colors.dart';

class AppType {
  AppType._();

  static const String _sans = 'Geist';
  static const String _mono = 'GeistMono';

  // ==========================================================================
  // DISPLAY · números héroe
  // ==========================================================================

  /// **mega** — 96 — el número gigante (hero numbers). Una por pantalla.
  static const TextStyle mega = TextStyle(
    fontFamily: _sans,
    fontSize: 96,
    height: 0.88,
    fontWeight: FontWeight.w600,
    letterSpacing: -4.8,
    color: AppColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// **hero** — 72 — saludo grande del login.
  static const TextStyle hero = TextStyle(
    fontFamily: _sans,
    fontSize: 72,
    height: 0.92,
    fontWeight: FontWeight.w600,
    letterSpacing: -3.2,
    color: AppColors.textPrimary,
  );

  /// **h1** — 56.
  static const TextStyle h1 = TextStyle(
    fontFamily: _sans,
    fontSize: 56,
    height: 0.95,
    fontWeight: FontWeight.w600,
    letterSpacing: -2.24,
    color: AppColors.textPrimary,
  );

  /// **h2** — 44.
  static const TextStyle h2 = TextStyle(
    fontFamily: _sans,
    fontSize: 44,
    height: 0.98,
    fontWeight: FontWeight.w600,
    letterSpacing: -1.32,
    color: AppColors.textPrimary,
  );

  /// **h3** — 30.
  static const TextStyle h3 = TextStyle(
    fontFamily: _sans,
    fontSize: 30,
    height: 1.05,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.75,
    color: AppColors.textPrimary,
  );

  /// **h4** — 22.
  static const TextStyle h4 = TextStyle(
    fontFamily: _sans,
    fontSize: 22,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.44,
    color: AppColors.textPrimary,
  );

  /// **h5** — 18.
  static const TextStyle h5 = TextStyle(
    fontFamily: _sans,
    fontSize: 18,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.27,
    color: AppColors.textPrimary,
  );

  // ==========================================================================
  // BODY · copy general
  // ==========================================================================

  static const TextStyle bodyLg = TextStyle(
    fontFamily: _sans,
    fontSize: 16,
    height: 1.55,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.08,
    color: AppColors.textPrimary,
  );

  static const TextStyle body = TextStyle(
    fontFamily: _sans,
    fontSize: 14.5,
    height: 1.55,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.07,
    color: AppColors.textPrimary,
  );

  static const TextStyle bodySm = TextStyle(
    fontFamily: _sans,
    fontSize: 13,
    height: 1.55,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.065,
    color: AppColors.textSecondary,
  );

  static const TextStyle label = TextStyle(
    fontFamily: _sans,
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
  );

  // ==========================================================================
  // EYEBROW · una por pantalla, UPPERCASE, mono
  // ==========================================================================

  static const TextStyle eyebrow = TextStyle(
    fontFamily: _mono,
    fontSize: 10.5,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.63,
    color: AppColors.textTertiary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle eyebrowLg = TextStyle(
    fontFamily: _mono,
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.72,
    color: AppColors.textTertiary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  // ==========================================================================
  // MONO · técnico (timestamps, IDs, métricas)
  // ==========================================================================

  static const TextStyle mono = TextStyle(
    fontFamily: _mono,
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle monoSm = TextStyle(
    fontFamily: _mono,
    fontSize: 10.5,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: AppColors.textTertiary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  // ==========================================================================
  // COMPATIBILIDAD — aliases con el sistema 2026-05-24 (const directos)
  // ==========================================================================

  /// alias legacy `display` (32px). Usar h2/h3 en código nuevo.
  static const TextStyle display = TextStyle(
    fontFamily: _sans,
    fontSize: 32,
    height: 1.05,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.75,
    color: AppColors.textPrimary,
  );

  /// alias de h4 — mismo size, nombre legacy.
  static const TextStyle title = h4;

  /// alias legacy `heading` (16px).
  static const TextStyle heading = TextStyle(
    fontFamily: _sans,
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.27,
    color: AppColors.textPrimary,
  );

  // ==========================================================================
  // HELPERS
  // ==========================================================================

  /// `AppType.on(AppType.body, context.colors.warning)` — aplica un color
  /// sin perder familia, tamaño, height, tracking, weight.
  static TextStyle on(TextStyle base, Color color) =>
      base.copyWith(color: color);
}
