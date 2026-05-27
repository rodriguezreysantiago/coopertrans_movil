import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../constants/app_colors.dart';

/// Variantes semánticas del botón unificado.
enum AppButtonVariant {
  /// CTA primario — cobalto sólido. Una por pantalla, idealmente.
  primary,

  /// CTA secundario — fondo transparente, borde brand. Acciones
  /// importantes pero no la principal.
  secondary,

  /// "Ghost" — sin borde, texto brand. Acciones de bajo peso visual
  /// (links inline, "Reintentar" dentro de un error state).
  ghost,

  /// Destructivo — rojo sólido. Borrar, anular, dar de baja.
  danger,
}

/// Tamaños — afectan padding y minimumSize.
///
/// - [compact] (32 min height) — para desktop/web donde el hover
///   reemplaza al touch target. NO usar en mobile.
/// - [sm] (36) — secundario denso, mobile OK.
/// - [md] (48) — **default**, touch-friendly en mobile.
/// - [lg] (56) — CTA hero (login, confirm dialogs).
enum AppButtonSize { compact, sm, md, lg }

/// Botón unificado — REFACTOR 2026-05-24.
///
/// Reemplaza:
/// - `ElevatedButton.styleFrom(...)` ad-hoc con backgroundColor manual.
/// - `Material + InkWell + Container` "tile button" del login.
/// - `TextButton` para "ghost" actions.
///
/// **Ejemplo:**
/// ```dart
/// AppButton(
///   label: 'Ingresar',
///   icon: Icons.arrow_forward,
///   onPressed: _login,
///   isLoading: _isLoading,
/// )
///
/// AppButton.danger(
///   label: 'Eliminar legajo',
///   onPressed: _confirmarBaja,
/// )
/// ```
class AppButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppButtonSize size;
  final bool isLoading;
  final bool expand;

  const AppButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.md,
    this.isLoading = false,
    this.expand = false,
  });

  const AppButton.secondary({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.size = AppButtonSize.md,
    this.isLoading = false,
    this.expand = false,
  }) : variant = AppButtonVariant.secondary;

  const AppButton.ghost({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.size = AppButtonSize.md,
    this.isLoading = false,
    this.expand = false,
  }) : variant = AppButtonVariant.ghost;

  const AppButton.danger({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.size = AppButtonSize.md,
    this.isLoading = false,
    this.expand = false,
  }) : variant = AppButtonVariant.danger;

  // ------- helpers --------------------------------------------------------

  ({Color bg, Color fg, Color? border}) _colors() {
    switch (variant) {
      case AppButtonVariant.primary:
        return (bg: AppColors.brand, fg: Colors.white, border: null);
      case AppButtonVariant.secondary:
        return (
          bg: Colors.transparent,
          fg: AppColors.brand,
          border: AppColors.brand,
        );
      case AppButtonVariant.ghost:
        return (bg: Colors.transparent, fg: AppColors.brand, border: null);
      case AppButtonVariant.danger:
        return (bg: AppColors.error, fg: Colors.white, border: null);
    }
  }

  ({double vPad, double hPad, double minH, double iconSize, TextStyle style})
      _sizing() {
    switch (size) {
      case AppButtonSize.compact:
        return (
          vPad: 6,
          hPad: AppSpacing.md,
          minH: 32,
          iconSize: 14,
          style: AppType.label.copyWith(
            color: Colors.white,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        );
      case AppButtonSize.sm:
        return (
          vPad: AppSpacing.sm,
          hPad: AppSpacing.md,
          minH: 36,
          iconSize: 16,
          style: AppType.label.copyWith(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        );
      case AppButtonSize.lg:
        return (
          vPad: AppSpacing.lg,
          hPad: AppSpacing.xl,
          minH: 56,
          iconSize: 20,
          style: AppType.heading.copyWith(color: Colors.white),
        );
      case AppButtonSize.md:
        return (
          vPad: AppSpacing.md,
          hPad: AppSpacing.lg,
          minH: 48,
          iconSize: 18,
          style: AppType.body.copyWith(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _colors();
    final s = _sizing();
    final disabled = onPressed == null || isLoading;

    final fg = disabled ? c.fg.withAlpha(120) : c.fg;
    final bg = disabled && variant == AppButtonVariant.primary
        ? c.bg.withAlpha(120)
        : (disabled && variant == AppButtonVariant.danger
            ? c.bg.withAlpha(120)
            : c.bg);

    final content = isLoading
        ? SizedBox(
            height: s.iconSize,
            width: s.iconSize,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: variant == AppButtonVariant.primary ||
                      variant == AppButtonVariant.danger
                  ? Colors.white
                  : AppColors.brand,
            ),
          )
        : Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: s.iconSize, color: fg),
                const SizedBox(width: AppSpacing.sm),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: s.style.copyWith(color: fg),
                ),
              ),
            ],
          );

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: disabled ? null : onPressed,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          constraints: BoxConstraints(
            minHeight: s.minH,
            minWidth: expand ? double.infinity : 0,
          ),
          padding: EdgeInsets.symmetric(
            vertical: s.vPad,
            horizontal: s.hPad,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: c.border != null
                ? Border.all(color: c.border!, width: 1.5)
                : null,
          ),
          child: Center(child: content),
        ),
      ),
    );
  }
}
