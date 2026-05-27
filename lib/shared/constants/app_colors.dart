import 'package:flutter/material.dart';

/// Paleta de colores centralizada — REFACTOR 2026-05-24.
///
/// **Antes:** brand cobalto + 11 `Colors.<accent>` neon de la era prototipo.
/// **Ahora:** brand cobalto + 4 semánticos + 3 niveles de superficie.
///
/// **Reglas de uso (de memoria):**
///
/// 1. **Identidad (brand).** Solo para acciones primarias, focus, nav activa,
///    superficies de marca (login, splash, ilustraciones de empty state).
///    **Nunca** como "color de categoría" de un tile.
/// 2. **Estado (semántico).** [success] / [warning] / [error] / [info].
///    Son los únicos colores que pueden aparecer dentro de un número KPI,
///    badge o barra de gráfico.
/// 3. **Categoría de módulo.** Usar el icono + label. No el color.
///    Si una cosa "tiene que destacarse" use semántico (warning/error)
///    porque ahí el color significa algo, no decora.
///
/// **Histórico.** Hasta 2026-05-27 había 11 `accentXxx` aliases marcados
/// @Deprecated apuntando a los semánticos para soportar migración
/// incremental. El sweep de Phase 6 del refactor de design-system migró
/// los ~1000 call-sites a tokens semánticos y borró los aliases. El CI
/// guard de `Colors.<accent>` sigue vigente para no reintroducirlos.
class AppColors {
  AppColors._();

  // ============================================================================
  // BRAND (Coopertrans Móvil — cobalto)
  // ============================================================================

  /// Color principal de marca — azul cobalto. Usar en:
  /// - Botones primarios (`AppButton.primary`)
  /// - Focus rings de inputs
  /// - Nav activa (NavigationRail / BottomNav selectedItemColor)
  /// - Splash, login, ilustraciones de empty state
  ///
  /// **NO** usar como color de categoría / tile.
  static const Color brand = Color(0xFF0EA5E9);

  /// Variante suave del brand — para hovers, badges, fondos de hint.
  static const Color brandSoft = Color(0xFF38BDF8);

  /// Variante oscura del brand — para gradients (login, splash).
  static const Color brandDark = Color(0xFF075985);

  // ============================================================================
  // SEMÁNTICOS (estado)
  // ============================================================================

  /// Verde "OK / al día / guardado". Único verde de la app.
  /// Reemplaza a [accentGreen] y [accentLightGreen].
  static const Color success = Color(0xFF1F8A5B);

  /// Naranja "atención sin error / vence pronto / advertencia".
  /// Reemplaza a [accentOrange], [accentAmber], [accentDeepOrange].
  static const Color warning = Color(0xFFC46A14);

  /// Rojo "vencido / falló / destructivo".
  /// Reemplaza a [accentRed].
  static const Color error = Color(0xFFB3261E);

  /// Azul "informativo" para tooltips, hints, badges neutros.
  /// Reemplaza a [accentBlue] y [accentLightBlue] cuando son informativos
  /// (cuando se usaban como "categoría", usar surface3 + label).
  static const Color info = Color(0xFF0B6DA4);

  // ============================================================================
  // SUPERFICIE (3 niveles de elevación)
  // ============================================================================

  /// **surface-0** — fondo del scaffold. La capa más profunda.
  /// Sin contenido encima directamente; siempre hay al menos un
  /// surface-1 o surface-2 mediando.
  static const Color surface0 = Color(0xFF09141F);

  /// **surface-1** — secciones, listas grandes, contenedores de varias cards.
  static const Color surface1 = Color(0xFF0E1A26);

  /// **surface-2** — cards, sheets, dialogs, KPIs. La que se ve más.
  /// Equivale al viejo `surface` del AppTheme.
  static const Color surface2 = Color(0xFF132538);

  /// **surface-3** — elemento elevado sobre una card (badge, icon disc,
  /// hover state, raised button bg en card oscura).
  static const Color surface3 = Color(0xFF1A2E45);

  /// Alias retrocompatible — el viejo `background` del AppTheme apuntaba
  /// al scaffold. Migración incremental: cambiar a [surface0] cuando se
  /// toque el archivo.
  static const Color background = surface0;

  /// Alias retrocompatible — el viejo `surface` del AppTheme apuntaba a
  /// las cards. Migración incremental: cambiar a [surface2].
  static const Color surface = surface2;

  // ============================================================================
  // TEXTO (jerarquía sobre fondo oscuro)
  // ============================================================================

  /// Texto principal — títulos, valores destacados.
  static const Color textPrimary = Color(0xFFFFFFFF);

  /// Texto secundario — subtítulos, body, descripciones.
  static const Color textSecondary = Color(0xB3FFFFFF); // white 70%

  /// Texto terciario — labels, captions, info de menor jerarquía.
  static const Color textTertiary = Color(0x8AFFFFFF); // white 54%

  /// Texto disabled / hint / placeholder.
  static const Color textDisabled = Color(0x61FFFFFF); // white 38%

  /// Texto extremadamente sutil — íconos decorativos, separadores.
  static const Color textHint = Color(0x3DFFFFFF); // white 24%

  /// Borde sutil de cards (1px, 6% white).
  static const Color borderSubtle = Color(0x0FFFFFFF); // white ~6%

  /// Borde un poco más visible — separadores entre secciones.
  static const Color borderStrong = Color(0x1FFFFFFF); // white ~12%

}
