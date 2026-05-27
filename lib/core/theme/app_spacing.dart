/// Sistema de espaciado y radius — REFACTOR 2026-05-24.
///
/// **Antes:** 20 valores distintos en el código (2/4/6/8/10/12/14/15/16/
/// 18/20/22/24/25/28/30/35/40/45/60) y 4 radios (14/16/22/25).
///
/// **Ahora:** 7 espacios + 4 radios con nombre.
///
/// Uso:
/// ```dart
/// padding: const EdgeInsets.all(AppSpacing.lg),
/// SizedBox(height: AppSpacing.md),
/// borderRadius: BorderRadius.circular(AppRadius.md),
/// ```
class AppSpacing {
  AppSpacing._();

  /// 4 — gap icon → label, ajustes muy finos.
  static const double xs = 4;

  /// 8 — gaps inline (chip a chip, icon a texto en una row).
  static const double sm = 8;

  /// 12 — gutters de grid de KPIs.
  static const double md = 12;

  /// 16 — **el default**. Padding interno de card, gap entre cards.
  static const double lg = 16;

  /// 24 — entre secciones de una pantalla, padding lateral de scaffold.
  static const double xl = 24;

  /// 32 — header de sección a primer contenido, separador grande.
  static const double xxl = 32;

  /// 48 — entre bloques mayores (saludo → "Hoy" en admin panel).
  static const double xxxl = 48;
}

/// Border radius canónico. **Default = [md] (16).** Toda superficie
/// del sistema (cards, inputs, botones, sheets, dialogs) usa este
/// radio salvo excepción documentada.
class AppRadius {
  AppRadius._();

  /// 8 — chips, badges, pills.
  static const double sm = 8;

  /// 12 — buttons, inputs pequeños.
  static const double md = 12;

  /// 16 — **el default**. Cards, sheets, dialogs, inputs grandes.
  static const double lg = 16;

  /// 999 — circular / pill total. Avatares, FAB, badges-pill.
  static const double full = 999;
}
