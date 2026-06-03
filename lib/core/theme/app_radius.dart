// REFACTOR NÚCLEO · jun 2026
//
// El sistema anterior usaba un default de 16 (cards). Núcleo baja los
// radii a una escala más tight, software-native (4 / 6 / 8 / 12 / 16 / pill).
//
// CONVENCIÓN FIJA (no se mezcla):
//   sm   4   → chips chicos, ticks
//   md   6   → toolbar pills, segmented controls
//   lg   8   → botones, inputs (DEFAULT)
//   xl   12  → cards bento (DEFAULT)
//   xxl  16  → modales, sheets, dialogs
//   full pill → badges, status pills, avatares circulares

class AppRadius {
  AppRadius._();

  static const double sm = 4;
  static const double md = 6;
  static const double lg = 8;
  static const double xl = 12;
  static const double xxl = 16;
  static const double full = 999;
}
