import 'package:flutter/material.dart';

/// Paleta de colores centralizada de la app.
///
/// **Cuándo usar esto vs `Theme.of(context)` vs `Colors.greenAccent`:**
///
/// - Para colores que cambian con el tema (primary, surface, etc.) usar
///   `Theme.of(context).colorScheme.primary`. El [AppTheme] ya configura
///   esos tokens.
/// - Para colores semánticos puntuales (un badge de éxito en una card,
///   un border de warning, etc.) usar las constantes de `AppColors`.
/// - **NO** usar `Colors.greenAccent` / `Colors.redAccent` / `Colors.orangeAccent`
///   / `Colors.blueAccent` / `Colors.cyanAccent` / `Colors.amberAccent`
///   directo en código nuevo. Son los mismos valores pero descentralizados —
///   cuando cambies la paleta vas a tener que buscarlos archivo por archivo.
///
/// **El CI gatea esto** (`.github/workflows/ci.yml` step "No nuevos colors
/// hardcoded"): si introducís en un commit/PR un `Colors.<accent>` nuevo
/// en `lib/`, el job falla con un error claro. Esto previene que la deuda
/// histórica siga creciendo.
///
/// **`Colors.white` / `Colors.black` / `Colors.transparent` / `Colors.whiteXX`
/// SÍ siguen siendo válidos** — son tokens del design system de Material,
/// no marca propia. El guard del CI los ignora.
///
/// El código existente todavía usa `Colors.*<accent>` en ~820 lugares; la
/// migración es incremental — cada vez que toques un archivo por otro
/// motivo, aprovechá para reemplazar.
class AppColors {
  AppColors._();

  // ===========================================================================
  // SEMÁNTICOS (alineados con AppFeedback)
  // ===========================================================================
  /// Verde "guardado/exitoso" para snackbars, confirmaciones, badges.
  /// Mismo valor que [AppFeedback.colorSuccess] — referenciar uno u otro
  /// según contexto (helper de feedback vs. paleta visual).
  static const Color success = Color(0xFF2E7D32); // green 800

  /// Rojo "falló/destructivo" para errores, botones de borrado,
  /// confirmaciones destructivas.
  static const Color error = Color(0xFFD32F2F); // red 700

  /// Naranja "atención sin error" para warnings, estados intermedios,
  /// info que el usuario necesita ver pero no es bloqueante.
  static const Color warning = Color(0xFFEF6C00); // orange 800

  /// Azul "informativo" para tooltips, hints, mensajes neutros.
  static const Color info = Color(0xFF1565C0); // blue 800

  // ===========================================================================
  // BRAND (Coopertrans Móvil — rebrand 2026-05-02)
  // ===========================================================================
  /// Color principal de marca — azul cobalto. Tono moderno que diferencia
  /// la app del verde-accent default de Flutter. Usar en: logo grande,
  /// splash, botones primarios, énfasis principal.
  ///
  /// Coopertrans no tiene paleta de marca histórica — esta paleta es
  /// definición nueva del rebrand. Si el cliente decide otro color,
  /// se cambia acá y propaga a toda la app.
  static const Color brand = Color(0xFF0EA5E9); // sky-500 / cobalto

  /// Variante suave del brand para fondos, hover states, badges.
  /// Mismo hue, menos saturación — útil cuando el [brand] sería muy fuerte.
  static const Color brandSoft = Color(0xFF38BDF8); // sky-400

  /// Variante oscura del brand para gradients (login, splash).
  /// Acompaña al [brand] en transiciones hacia el [background].
  static const Color brandDark = Color(0xFF075985); // sky-800

  // ===========================================================================
  // ACCENT (los que se usan dispersos en el código actual)
  // ===========================================================================
  /// Verde accent — color primario de la marca. Es el mismo que el
  /// `colorScheme.primary` del tema. Útil para íconos secundarios y
  /// detalles cuando no querés depender de `Theme.of(context)`.
  static const Color accentGreen = Colors.greenAccent;

  /// Naranja accent — usado para warnings visuales en badges y avatares
  /// (más vibrante que [warning] que va en fondos sólidos).
  static const Color accentOrange = Colors.orangeAccent;

  /// Rojo accent — para íconos destructivos, borders de alerta.
  static const Color accentRed = Colors.redAccent;

  /// Azul accent — para íconos informativos, links, tooltips.
  static const Color accentBlue = Colors.blueAccent;

  /// Cyan accent — específico del Sync Dashboard / telemetría Volvo.
  static const Color accentCyan = Colors.cyanAccent;

  /// Amber accent — usado en alertas intermedias del bot, indicador
  /// "atención" que no llega a warning sólido.
  static const Color accentAmber = Colors.amberAccent;

  /// Teal accent — categoría visual para enganches/bateas en
  /// admin_vencimientos_menu y panel admin (diferenciar de tractores).
  static const Color accentTeal = Colors.tealAccent;

  /// Purple accent — categoría visual del bot WhatsApp / status
  /// "diferenciador" en admin_panel.
  static const Color accentPurple = Colors.purpleAccent;

  /// Deep orange — variante más fuerte de [accentOrange]. Usado para
  /// diferenciar visualmente el tile SERVICE del tile GOMERÍA en el
  /// panel admin (ambos son del rubro mantenimiento pero distintos).
  static const Color accentDeepOrange = Colors.deepOrangeAccent;

  /// Light green — variante suave de [accentGreen]. Usado para el tile
  /// ESTADO BOT en el panel admin (no es alerta, es info de servicio).
  static const Color accentLightGreen = Colors.lightGreenAccent;

  /// Light blue — variante suave de [accentBlue]. Usado para el badge
  /// del rol PLANTA (info de jerarquía, no atención ni acción).
  static const Color accentLightBlue = Colors.lightBlueAccent;

  // ===========================================================================
  // BACKGROUND / SURFACE
  // ===========================================================================
  /// Fondo principal de la app (oscuro). Coincide con
  /// `scaffoldBackgroundColor` del [AppTheme].
  static const Color background = Color(0xFF09141F);

  /// Fondo de cards, sheets, dialogs. Coincide con
  /// `colorScheme.surface` del [AppTheme].
  static const Color surface = Color(0xFF132538);

  // ===========================================================================
  // TEXT (jerarquía)
  // ===========================================================================
  /// Texto principal: títulos, valores destacados.
  static const Color textPrimary = Colors.white;

  /// Texto secundario: subtítulos, descripciones, body.
  static const Color textSecondary = Colors.white70;

  /// Texto terciario: labels, captions, info de menor jerarquía.
  static const Color textTertiary = Colors.white54;

  /// Texto disabled / placeholder / hint.
  static const Color textDisabled = Colors.white38;

  /// Texto extremadamente sutil — íconos decorativos, separators.
  static const Color textHint = Colors.white24;

  /// Borders muy sutiles (ej. shadow internas de cards).
  static const Color borderSubtle = Color(0x1AFFFFFF); // white con alpha 10%
}
