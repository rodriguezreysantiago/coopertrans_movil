// REFACTOR NÚCLEO · jun 2026
//
// El sistema Núcleo evita sombras decorativas. Las tres únicas sombras
// permitidas son:
//
// 1. lift     — sombra mínima para cards flotantes (modales, sheets).
//               Drop-shadow 1-4px, opacidad baja.
// 2. glow     — efecto firma del sistema. Sombra del color brand alrededor
//               de un elemento primario (botón primario, KPI activo).
//               BoxShadow con `blurRadius` grande y color con alfa.
// 3. ambient  — el radial gradient detrás del bg. NO es una sombra,
//               se construye con `RadialGradient` (ver app_ambient.dart).
//
// No usar shadows para "elevar" cards de la grilla bento — la separación
// está dada por el border + surface2 sobre bg.

import 'package:flutter/material.dart';

class AppShadows {
  AppShadows._();

  static const List<BoxShadow> none = <BoxShadow>[];

  /// Sombra liviana para sheets / modals / dropdowns flotantes.
  static const List<BoxShadow> lift = [
    BoxShadow(
      color: Color(0x2E000000), // black 18%
      offset: Offset(0, 1),
      blurRadius: 2,
    ),
    BoxShadow(
      color: Color(0x1F000000), // black 12%
      offset: Offset(0, 4),
      blurRadius: 12,
    ),
  ];

  /// Glow del color brand — sombra firma. Usar SOLO en:
  /// - Botón primario (al hover/focus o always-on de la action principal)
  /// - Badge "live" del status row
  /// - Marker seleccionado del mapa de flota
  /// - Avatar de identidad
  static List<BoxShadow> glow(Color brand, {double intensity = 0.4}) => [
    BoxShadow(
      color: brand.withValues(alpha: intensity * 0.5),
      blurRadius: 24,
      spreadRadius: 0,
    ),
  ];

  /// Glow doble — más intenso, para el splash y el logo grande.
  static List<BoxShadow> glowDouble(Color brand) => [
    BoxShadow(color: brand.withValues(alpha: 0.30), blurRadius: 60),
    BoxShadow(color: brand.withValues(alpha: 0.20), blurRadius: 120),
  ];
}
