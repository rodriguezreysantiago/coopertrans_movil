// REFACTOR NÚCLEO · jun 2026
//
// AppFilterChip — pill seleccionable de filtro (label + count).
//
// Extraído del `_Chip` privado de Gestión de Personal
// (`admin_personal_lista_screen.dart`) para reusarlo en Gestión de Flota
// y donde haga falta filtrar por categoría con el mismo look Núcleo.
//
// Estilo:
//  - activo:   fondo `AppColors.textPrimary`, texto `AppColors.surface0`.
//  - inactivo: transparente con borde `AppColors.borderStrong`.
//  - borderRadius 999 (pill), `AppType.label` para el texto y
//    `AppType.monoSm` para el contador.

import 'package:flutter/material.dart';

import '../../core/theme/app_typography.dart';
import '../constants/app_colors.dart';

/// Pill seleccionable con etiqueta + contador. Tocar dispara [onTap].
class AppFilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool activo;
  final VoidCallback onTap;

  const AppFilterChip({
    super.key,
    required this.label,
    required this.count,
    required this.activo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: activo ? AppColors.textPrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: activo
              ? null
              : Border.all(color: AppColors.borderStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppType.label.copyWith(
                color: activo ? AppColors.surface0 : AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: AppType.monoSm.copyWith(
                color: activo
                    ? AppColors.surface0.withValues(alpha: 0.6)
                    : AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
