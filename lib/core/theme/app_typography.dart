import 'package:flutter/material.dart';

import '../../shared/constants/app_colors.dart';

/// Sistema tipográfico — REFACTOR 2026-05-24.
///
/// **Antes:** ~12 tamaños distintos (10/11/12/13/14/16/18/20/22/28/30/32)
/// y 4 letter-spacings de uppercase (0.5/1.0/1.5/2.0) repartidos a mano
/// en cada widget. Todo Roboto.
///
/// **Ahora:** 7 estilos con nombre. Cualquier `Text` que necesite size
/// fijo debe salir de [AppType]. El CI lint puede gatear `fontSize:`
/// literales (pendiente).
///
/// **Reglas:**
/// - **Una sola línea de uppercase por pantalla** — [eyebrow]. Tile
///   labels, botones, contadores van en sentence case.
/// - **Los números KPI** usan [mono] o el [display] con tabular figures
///   para que no "bailen" al cambiar de valor.
class AppType {
  AppType._();

  /// **display** — el saludo grande, el número grande de un KPI hero.
  /// Una por pantalla, máximo.
  static const TextStyle display = TextStyle(
    fontSize: 32,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    color: AppColors.textPrimary,
  );

  /// **title** — header de pantalla, "Buenas tardes, Santi".
  static const TextStyle title = TextStyle(
    fontSize: 22,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: AppColors.textPrimary,
  );

  /// **heading** — header de sección dentro de una pantalla,
  /// "Vencimientos del mes".
  static const TextStyle heading = TextStyle(
    fontSize: 16,
    height: 1.35,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  /// **body** — texto descriptivo principal. El subtítulo de una tile,
  /// la descripción de un módulo. **Sentence case.**
  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );

  /// **label** — etiquetas chicas pero no "eyebrow". Form labels,
  /// "Próximo vencimiento", footer text. **Sentence case.**
  static const TextStyle label = TextStyle(
    fontSize: 12,
    height: 1.35,
    fontWeight: FontWeight.w500,
    color: AppColors.textTertiary,
  );

  /// **eyebrow** — la ÚNICA línea uppercase de la pantalla. Section
  /// headers tipo "ESTA SEMANA", "ACCIONES RÁPIDAS".
  static const TextStyle eyebrow = TextStyle(
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.2,
    color: AppColors.textTertiary,
  );

  /// **mono** — números, fechas, DNIs, patentes. Tabular figures —
  /// no "salta" cuando el valor cambia.
  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['RobotoMono', 'Courier'],
    fontFeatures: [FontFeature.tabularFigures()],
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
  );

  // ============================================================================
  // Helpers para aplicar el estilo con color/peso ad-hoc sin perder la
  // jerarquía.
  // ============================================================================

  /// Aplica el [base] pero con [color] override. Útil cuando un KPI
  /// con [display] tiene que ser rojo/verde según estado.
  static TextStyle on(TextStyle base, Color color) =>
      base.copyWith(color: color);
}
