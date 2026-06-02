// handoff/lib/core/theme/app_typography.dart
//
// REFACTOR NÚCLEO · jun 2026
//
// Geist + Geist Mono. Carga vía `google_fonts: ^6.2.1` (agregar a pubspec).
// El theme las inyecta como default — los widgets refactorizados NO necesitan
// llamar GoogleFonts.geist() en cada Text.
//
// Estilos disponibles:
//   AppType.mega      96  · número héroe (1 por pantalla, ej "23 días")
//   AppType.hero      72  · saludo "Buenas tardes"
//   AppType.h1        56  · "Hola Santiago"
//   AppType.h2        44  · titular de sección
//   AppType.h3        30  · titular de card grande
//   AppType.h4        22  · titular de card chica
//   AppType.h5        18  · titular de subsección
//   AppType.title     22  · ALIAS de h4 (compat con código viejo)
//   AppType.display   32  · ALIAS de h2 reducido (compat)
//   AppType.heading   16  · ALIAS de h5 reducido (compat)
//   AppType.body      14.5· copy default
//   AppType.bodySm    13  · copy secundario
//   AppType.label     12  · form labels, captions
//   AppType.eyebrow   10.5· UPPERCASE caps, mono. Etiquetas de sección.
//   AppType.mono      13  · técnico (timestamps, IDs, métricas)
//   AppType.monoSm    10.5· técnico chico
//
// REGLA: una sola línea uppercase por pantalla — la del eyebrow.
// REGLA: números KPI siempre con tabularFigures().
// REGLA: para overrides puntuales de color/peso usar .copyWith() — el sistema
//        no penaliza esto.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

class AppType {
  AppType._();

  // ============================================================================
  // BASE TEXT STYLE — Geist Sans, default antialiased weight
  // ============================================================================

  static TextStyle _sans({
    required double fontSize,
    required double height,
    required FontWeight fontWeight,
    double letterSpacing = 0,
    Color? color,
    List<FontFeature> features = const [],
  }) {
    return GoogleFonts.geist(
      fontSize: fontSize,
      height: height,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing,
      color: color,
      fontFeatures: features.isEmpty ? null : features,
    );
  }

  static TextStyle _mono({
    required double fontSize,
    required double height,
    required FontWeight fontWeight,
    double letterSpacing = 0,
    Color? color,
  }) {
    return GoogleFonts.geistMono(
      fontSize: fontSize,
      height: height,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing,
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  // ============================================================================
  // DISPLAY · números héroe
  // ============================================================================

  /// **mega** — 96 — el número gigante. Usado para hero numbers como
  /// "23 días" en VencDetail o "142" en el KPI estrella del dashboard.
  /// Una por pantalla. Tabular figures.
  static TextStyle mega = _sans(
    fontSize: 96,
    height: 0.88,
    fontWeight: FontWeight.w600,
    letterSpacing: -4.8, // ~-0.05em
    color: AppColors.dark.text,
    features: [const FontFeature.tabularFigures()],
  );

  /// **hero** — 72 — saludo grande "Buenas tardes" del login.
  static TextStyle hero = _sans(
    fontSize: 72,
    height: 0.92,
    fontWeight: FontWeight.w600,
    letterSpacing: -3.2, // ~-0.045em
    color: AppColors.dark.text,
  );

  /// **h1** — 56 — "Hola Santiago" del dashboard.
  static TextStyle h1 = _sans(
    fontSize: 56,
    height: 0.95,
    fontWeight: FontWeight.w600,
    letterSpacing: -2.24, // -0.04em
    color: AppColors.dark.text,
  );

  /// **h2** — 44 — header de sección dentro de una pantalla.
  static TextStyle h2 = _sans(
    fontSize: 44,
    height: 0.98,
    fontWeight: FontWeight.w600,
    letterSpacing: -1.32, // -0.03em
    color: AppColors.dark.text,
  );

  /// **h3** — 30 — titular de card grande.
  static TextStyle h3 = _sans(
    fontSize: 30,
    height: 1.05,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.75, // -0.025em
    color: AppColors.dark.text,
  );

  /// **h4** — 22 — titular de card chica.
  static TextStyle h4 = _sans(
    fontSize: 22,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.44, // -0.02em
    color: AppColors.dark.text,
  );

  /// **h5** — 18 — titular de subsección.
  static TextStyle h5 = _sans(
    fontSize: 18,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.27, // -0.015em
    color: AppColors.dark.text,
  );

  // ============================================================================
  // BODY · copy general
  // ============================================================================

  static TextStyle bodyLg = _sans(
    fontSize: 16,
    height: 1.55,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.08,
    color: AppColors.dark.text,
  );

  static TextStyle body = _sans(
    fontSize: 14.5,
    height: 1.55,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.07,
    color: AppColors.dark.text,
  );

  static TextStyle bodySm = _sans(
    fontSize: 13,
    height: 1.55,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.065,
    color: AppColors.dark.textSecondary,
  );

  static TextStyle label = _sans(
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: AppColors.dark.textSecondary,
  );

  // ============================================================================
  // EYEBROW · una por pantalla, UPPERCASE, mono
  // ============================================================================

  static TextStyle eyebrow = _mono(
    fontSize: 10.5,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.63, // 0.06em
    color: AppColors.dark.textMuted,
  );

  static TextStyle eyebrowLg = _mono(
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.72,
    color: AppColors.dark.textMuted,
  );

  // ============================================================================
  // MONO · técnico
  // ============================================================================

  static TextStyle mono = _mono(
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: AppColors.dark.text,
  );

  static TextStyle monoSm = _mono(
    fontSize: 10.5,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: AppColors.dark.textMuted,
  );

  // ============================================================================
  // COMPATIBILIDAD — aliases con el sistema 2026-05-24
  // ============================================================================

  /// alias de h2 reducido para mantener el viejo `display` (32px) — usar
  /// directamente `h2` o `h3` en código nuevo.
  static TextStyle get display => h3.copyWith(fontSize: 32);

  /// alias de h4 — mismo size, nombre legacy.
  static TextStyle get title => h4;

  /// alias de h5 reducido para "heading" 16px.
  static TextStyle get heading => h5.copyWith(fontSize: 16);

  // ============================================================================
  // HELPERS
  // ============================================================================

  /// Atajo: `AppType.body.on(context.colors.warning)` — aplica un color sin
  /// perder familia, tamaño, height, tracking, weight.
  static TextStyle on(TextStyle base, Color color) => base.copyWith(color: color);
}

extension AppTypeOn on TextStyle {
  TextStyle on(Color color) => copyWith(color: color);
  TextStyle bold() => copyWith(fontWeight: FontWeight.w600);
  TextStyle tabular() => copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}
