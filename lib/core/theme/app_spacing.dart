// REFACTOR NÚCLEO · jun 2026
//
// La escala 4pt del refactor anterior se mantiene. Núcleo no cambió
// espaciados; lo único nuevo es exponer constantes para los `gap` típicos
// que usábamos a ojo (gap entre cards de un bento = 14, no 16).

// AppRadius se extrajo a app_radius.dart (refactor Núcleo). Lo re-exportamos
// para que los call-sites que lo importaban desde app_spacing.dart sigan
// compilando sin tocar cada archivo.
export 'app_radius.dart';

class AppSpacing {
  AppSpacing._();

  /// 4 — fine adjustments, icon → label.
  static const double xs = 4;

  /// 8 — inline gaps (chip a chip, icon a texto).
  static const double sm = 8;

  /// 12 — gap entre cards de un bento, gutter de grid de KPIs.
  static const double md = 12;

  /// 14 — gap "denso" entre cards (Núcleo style).
  static const double mdDense = 14;

  /// 16 — el default. Padding interno de card, gap entre cards std.
  static const double lg = 16;

  /// 20 — padding interno de card grande.
  static const double xl = 20;

  /// 24 — entre secciones, padding lateral de scaffold.
  static const double xxl = 24;

  /// 32 — bloques mayores.
  static const double xxxl = 32;

  /// 48 — entre bloques hero.
  static const double huge = 48;

  /// 64 — paddings de hero (login, dashboard greeting).
  static const double hero = 64;
}
