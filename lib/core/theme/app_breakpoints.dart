import 'package:flutter/widgets.dart';

/// Breakpoints responsive — REFACTOR 2026-05-27 (multiplatform addon).
///
/// La app corre en iOS, Android, Chrome (web), macOS y Windows. Las
/// pantallas tienen que verse bien desde un iPhone SE (375px) hasta
/// un monitor 4K. Estos breakpoints son los puntos donde el layout
/// cambia de forma.
///
/// **Convención:**
/// - `< mobile` (≤ 599) — phone portrait. Stack vertical, 1 columna.
/// - `< tablet` (≤ 904) — phone landscape, small tablet. 2 columnas si aplica.
/// - `< desktop` (≤ 1239) — large tablet, laptop. 3 columnas.
/// - `≥ desktop` — desktop / external monitor. Sidebar permanente,
///   layouts más amplios.
///
/// Coinciden a grandes rasgos con los breakpoints de Material 3
/// (compact / medium / expanded / large).
class AppBreakpoints {
  AppBreakpoints._();

  /// Hasta este ancho el layout es "compact" / phone.
  static const double mobile = 600;

  /// Hasta este ancho el layout es "medium" / tablet.
  static const double tablet = 905;

  /// Hasta este ancho el layout es "expanded" / laptop.
  static const double desktop = 1240;

  /// Helpers — `if (AppBreakpoints.isDesktop(context)) ...`
  static bool isMobile(BuildContext c) =>
      MediaQuery.of(c).size.width < mobile;
  static bool isTablet(BuildContext c) {
    final w = MediaQuery.of(c).size.width;
    return w >= mobile && w < tablet;
  }
  static bool isDesktopOrLarger(BuildContext c) =>
      MediaQuery.of(c).size.width >= tablet;
  static bool isLargeDesktop(BuildContext c) =>
      MediaQuery.of(c).size.width >= desktop;

  /// Ancho máximo de contenido recomendado para layouts "centered".
  /// En mobile = todo el ancho. En desktop, un cap para que las líneas
  /// de texto no se vuelvan ilegibles a 2000px.
  static double contentMaxWidth(BuildContext c) {
    final w = MediaQuery.of(c).size.width;
    if (w < mobile) return w;
    if (w < tablet) return 640;
    if (w < desktop) return 880;
    return 1080;
  }
}
