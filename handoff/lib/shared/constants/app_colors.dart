// handoff/lib/core/theme/app_colors.dart
//
// REFACTOR NÚCLEO · jun 2026
//
// CAMBIOS vs. la versión 2026-05-24:
// 1. Brand cobalto (#0EA5E9) → brand indigo eléctrico (#7C83FF dark / #5B62E0 light).
//    Indigo deja respirar al verde/ámbar/coral semánticos sin colisionar.
// 2. Estructura dual: AppColors.dark y AppColors.light, ambos disponibles
//    en runtime. Theme.of(context).extension<AppColorsExt>() resuelve.
// 3. Surfaces más profundas: surface0 = #050505 (near-black, no azulado).
//    Esto da el contraste alto que los choferes necesitan en cabina con sol.
// 4. Texto en rgba sobre fondo (no opaco) — escala bien si en el futuro
//    sumamos un tema "midnight" o "espresso".
// 5. Glow del brand explícito (brandGlow) — gesto firma del sistema, usar
//    en botones primarios, focus rings y ambient backgrounds.
//
// MIGRACIÓN — call-sites quedan iguales: `AppColors.brand`, `AppColors.success`.
// Por compatibilidad seguimos exponiendo los nombres planos apuntando al tema
// oscuro (default). Para light theme, llamar `AppColors.light.brand`, etc.

import 'package:flutter/material.dart';

/// Paleta canónica del sistema Núcleo.
class AppColors {
  AppColors._();

  // ============================================================================
  // ACCESORES POR TEMA — usar estos en widgets que respetan el theme.
  // ============================================================================

  static const _Palette dark = _Palette(
    bg:               Color(0xFF050505),
    surface1:         Color(0xFF0A0A0B),
    surface2:         Color(0xFF0F0F10),
    surface3:         Color(0xFF16161A),
    surfaceHover:     Color(0xFF1D1D22),

    border:           Color(0x12FFFFFF), // white ~7%
    borderStrong:     Color(0x24FFFFFF), // white ~14%
    borderFocus:      Color(0x807C83FF), // brand 50%

    text:             Color(0xFFFAFAFA),
    textSecondary:    Color(0x9EFAFAFA), // 62%
    textMuted:        Color(0x66FAFAFA), // 40%
    textPlaceholder:  Color(0x47FAFAFA), // 28%

    brand:            Color(0xFF7C83FF),
    brandSoft:        Color(0xFFA5ACFF),
    brandDark:        Color(0xFF5B62E0),
    brandFg:          Color(0xFF050505),
    brandGlow:        Color(0x337C83FF),

    success:          Color(0xFF4ADE80),
    successSoft:      Color(0x294ADE80),
    warning:          Color(0xFFFBBF24),
    warningSoft:      Color(0x29FBBF24),
    error:            Color(0xFFFB7185),
    errorSoft:        Color(0x29FB7185),
    info:             Color(0xFF60A5FA),
    infoSoft:         Color(0x2960A5FA),
  );

  static const _Palette light = _Palette(
    bg:               Color(0xFFFAFAFA),
    surface1:         Color(0xFFF4F4F5),
    surface2:         Color(0xFFFFFFFF),
    surface3:         Color(0xFFE9E9EB),
    surfaceHover:     Color(0xFFDEDEDF),

    border:           Color(0x0F000000), // black ~6%
    borderStrong:     Color(0x1F000000), // black ~12%
    borderFocus:      Color(0x665B62E0), // brand 40%

    text:             Color(0xFF0A0A0A),
    textSecondary:    Color(0x9E0A0A0A),
    textMuted:        Color(0x660A0A0A),
    textPlaceholder:  Color(0x470A0A0A),

    brand:            Color(0xFF5B62E0),
    brandSoft:        Color(0xFF7C83FF),
    brandDark:        Color(0xFF3F44B0),
    brandFg:          Color(0xFFFFFFFF),
    brandGlow:        Color(0x1A5B62E0),

    success:          Color(0xFF16A34A),
    successSoft:      Color(0x1F16A34A),
    warning:          Color(0xFFD97706),
    warningSoft:      Color(0x1FD97706),
    error:            Color(0xFFE11D48),
    errorSoft:        Color(0x1FE11D48),
    info:             Color(0xFF2563EB),
    infoSoft:         Color(0x1F2563EB),
  );

  // ============================================================================
  // COMPATIBILIDAD — los nombres planos antiguos apuntan al tema oscuro.
  // Migración: refactorizar a `Theme.of(context).colors.brand` (ver app_theme.dart).
  // ============================================================================

  static Color get brand          => dark.brand;
  static Color get brandSoft      => dark.brandSoft;
  static Color get brandDark      => dark.brandDark;

  static Color get success        => dark.success;
  static Color get warning        => dark.warning;
  static Color get error          => dark.error;
  static Color get info           => dark.info;

  static Color get surface0       => dark.bg;
  static Color get surface1       => dark.surface1;
  static Color get surface2       => dark.surface2;
  static Color get surface3       => dark.surface3;

  static Color get textPrimary    => dark.text;
  static Color get textSecondary  => dark.textSecondary;
  static Color get textTertiary   => dark.textMuted;
  static Color get textDisabled   => dark.textPlaceholder;
  static Color get textHint       => dark.textPlaceholder;
  static Color get borderSubtle   => dark.border;
  static Color get borderStrong   => dark.borderStrong;

  // Aliases retro
  static Color get background     => dark.bg;
  static Color get surface        => dark.surface2;
}

/// Una paleta completa (un tema). Inmutable.
class _Palette {
  final Color bg, surface1, surface2, surface3, surfaceHover;
  final Color border, borderStrong, borderFocus;
  final Color text, textSecondary, textMuted, textPlaceholder;
  final Color brand, brandSoft, brandDark, brandFg, brandGlow;
  final Color success, successSoft, warning, warningSoft, error, errorSoft, info, infoSoft;

  const _Palette({
    required this.bg,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.surfaceHover,
    required this.border,
    required this.borderStrong,
    required this.borderFocus,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textPlaceholder,
    required this.brand,
    required this.brandSoft,
    required this.brandDark,
    required this.brandFg,
    required this.brandGlow,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.error,
    required this.errorSoft,
    required this.info,
    required this.infoSoft,
  });
}

/// ThemeExtension para que cada widget acceda a la paleta vía
/// `Theme.of(context).extension<AppColorsExt>()!`.
/// El tema oscuro y el claro instalan instancias distintas en MaterialApp.theme.
class AppColorsExt extends ThemeExtension<AppColorsExt> {
  final Color bg, surface1, surface2, surface3, surfaceHover;
  final Color border, borderStrong, borderFocus;
  final Color text, textSecondary, textMuted, textPlaceholder;
  final Color brand, brandSoft, brandDark, brandFg, brandGlow;
  final Color success, successSoft, warning, warningSoft, error, errorSoft, info, infoSoft;

  const AppColorsExt._({
    required this.bg,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.surfaceHover,
    required this.border,
    required this.borderStrong,
    required this.borderFocus,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textPlaceholder,
    required this.brand,
    required this.brandSoft,
    required this.brandDark,
    required this.brandFg,
    required this.brandGlow,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.error,
    required this.errorSoft,
    required this.info,
    required this.infoSoft,
  });

  static AppColorsExt fromPalette(_Palette p) => AppColorsExt._(
    bg: p.bg, surface1: p.surface1, surface2: p.surface2, surface3: p.surface3, surfaceHover: p.surfaceHover,
    border: p.border, borderStrong: p.borderStrong, borderFocus: p.borderFocus,
    text: p.text, textSecondary: p.textSecondary, textMuted: p.textMuted, textPlaceholder: p.textPlaceholder,
    brand: p.brand, brandSoft: p.brandSoft, brandDark: p.brandDark, brandFg: p.brandFg, brandGlow: p.brandGlow,
    success: p.success, successSoft: p.successSoft,
    warning: p.warning, warningSoft: p.warningSoft,
    error: p.error, errorSoft: p.errorSoft,
    info: p.info, infoSoft: p.infoSoft,
  );

  static AppColorsExt forDark() => fromPalette(AppColors.dark);
  static AppColorsExt forLight() => fromPalette(AppColors.light);

  @override
  AppColorsExt copyWith() => this; // theme switch is via lerp(0) → lerp(1)

  @override
  AppColorsExt lerp(covariant ThemeExtension<AppColorsExt>? other, double t) {
    if (other is! AppColorsExt) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return AppColorsExt._(
      bg: l(bg, other.bg),
      surface1: l(surface1, other.surface1),
      surface2: l(surface2, other.surface2),
      surface3: l(surface3, other.surface3),
      surfaceHover: l(surfaceHover, other.surfaceHover),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      borderFocus: l(borderFocus, other.borderFocus),
      text: l(text, other.text),
      textSecondary: l(textSecondary, other.textSecondary),
      textMuted: l(textMuted, other.textMuted),
      textPlaceholder: l(textPlaceholder, other.textPlaceholder),
      brand: l(brand, other.brand),
      brandSoft: l(brandSoft, other.brandSoft),
      brandDark: l(brandDark, other.brandDark),
      brandFg: l(brandFg, other.brandFg),
      brandGlow: l(brandGlow, other.brandGlow),
      success: l(success, other.success),
      successSoft: l(successSoft, other.successSoft),
      warning: l(warning, other.warning),
      warningSoft: l(warningSoft, other.warningSoft),
      error: l(error, other.error),
      errorSoft: l(errorSoft, other.errorSoft),
      info: l(info, other.info),
      infoSoft: l(infoSoft, other.infoSoft),
    );
  }
}

/// Atajo para acceder a la paleta activa desde un widget.
extension AppColorsContext on BuildContext {
  AppColorsExt get colors => Theme.of(this).extension<AppColorsExt>()!;
}
