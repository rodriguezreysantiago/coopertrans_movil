// lib/shared/widgets/app_button.dart
//
// REFACTOR NÚCLEO · jun 2026 — AppButton con glow + hover + iconAfter.
//
// SHIM RETROCOMPATIBLE: acepta TAMBIÉN la API 2026-05-24 (`variant:`,
// `isLoading:`, `expand:`, `AppButtonVariant`, `AppButtonSize.compact`) para no
// romper los ~259 call-sites existentes. El código nuevo usa `kind:`/`loading:`/
// `full:`. Cuando se migren todas las pantallas, se pueden quitar los alias.

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_typography.dart';

enum AppButtonKind { primary, secondary, ghost, danger }

/// Compat con el nombre 2026-05-24. Los valores coinciden 1:1.
typedef AppButtonVariant = AppButtonKind;

/// `compact` es legacy (mapea a sm). `xl` es nuevo.
enum AppButtonSize { compact, sm, md, lg, xl }

class AppButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final IconData? iconAfter;
  final VoidCallback? onPressed;
  final AppButtonSize size;
  final bool glow;

  // API nueva
  final AppButtonKind? kind;
  final bool full;
  final bool loading;

  // API vieja (compat — resueltos en build)
  final AppButtonKind? variant;
  final bool expand;
  final bool isLoading;

  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind,
    this.variant,
    this.size = AppButtonSize.md,
    this.icon,
    this.iconAfter,
    this.full = false,
    this.expand = false,
    this.glow = true,
    this.loading = false,
    this.isLoading = false,
  });

  const AppButton.primary({
    super.key,
    required this.label,
    required this.onPressed,
    this.size = AppButtonSize.md,
    this.icon,
    this.iconAfter,
    this.full = false,
    this.expand = false,
    this.glow = true,
    this.loading = false,
    this.isLoading = false,
  })  : kind = AppButtonKind.primary,
        variant = null;

  const AppButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.size = AppButtonSize.md,
    this.icon,
    this.iconAfter,
    this.full = false,
    this.expand = false,
    this.loading = false,
    this.isLoading = false,
  })  : kind = AppButtonKind.secondary,
        variant = null,
        glow = false;

  const AppButton.ghost({
    super.key,
    required this.label,
    required this.onPressed,
    this.size = AppButtonSize.md,
    this.icon,
    this.iconAfter,
    this.full = false,
    this.expand = false,
    this.loading = false,
    this.isLoading = false,
  })  : kind = AppButtonKind.ghost,
        variant = null,
        glow = false;

  const AppButton.danger({
    super.key,
    required this.label,
    required this.onPressed,
    this.size = AppButtonSize.md,
    this.icon,
    this.iconAfter,
    this.full = false,
    this.expand = false,
    this.glow = true,
    this.loading = false,
    this.isLoading = false,
  })  : kind = AppButtonKind.danger,
        variant = null;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _hover = false;

  ({double px, double py, double fs, double gap, double ic, double minH}) get _dims {
    switch (widget.size) {
      case AppButtonSize.compact:
        return (px: 10, py: 6, fs: 12, gap: 6, ic: 13, minH: 32);
      case AppButtonSize.sm:
        return (px: 12, py: 8, fs: 13, gap: 8, ic: 14, minH: 38);
      case AppButtonSize.md:
        return (px: 14, py: 10, fs: 14, gap: 8, ic: 15, minH: 44);
      case AppButtonSize.lg:
        return (px: 18, py: 14, fs: 15, gap: 10, ic: 17, minH: 52);
      case AppButtonSize.xl:
        return (px: 22, py: 16, fs: 16, gap: 12, ic: 18, minH: 56);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cols = context.colors;
    final d = _dims;

    // Resolución compat: nueva API gana; si no, la vieja.
    final kind = widget.kind ?? widget.variant ?? AppButtonKind.primary;
    final isFull = widget.full || widget.expand;
    final isLoading = widget.loading || widget.isLoading;
    final enabled = widget.onPressed != null && !isLoading;

    late Color bg, fg;
    late final Color borderC;
    List<BoxShadow>? shadow;
    switch (kind) {
      case AppButtonKind.primary:
        bg = cols.brand;
        fg = cols.brandFg;
        borderC = Colors.transparent;
        if (widget.glow && enabled) shadow = AppShadows.glow(cols.brand);
        break;
      case AppButtonKind.secondary:
        bg = cols.surface3;
        fg = cols.text;
        borderC = cols.borderStrong;
        break;
      case AppButtonKind.ghost:
        bg = Colors.transparent;
        fg = cols.text;
        borderC = cols.border;
        break;
      case AppButtonKind.danger:
        bg = cols.error;
        fg = Colors.white;
        borderC = Colors.transparent;
        if (widget.glow && enabled) shadow = AppShadows.glow(cols.error);
        break;
    }

    if (_hover && enabled) {
      bg = Color.alphaBlend(Colors.white.withValues(alpha: 0.04), bg);
    }
    if (!enabled) {
      bg = bg.withValues(alpha: 0.5);
      fg = fg.withValues(alpha: 0.5);
    }

    final content = Row(
      mainAxisSize: isFull ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: isFull
          ? (widget.iconAfter != null
              ? MainAxisAlignment.spaceBetween
              : MainAxisAlignment.center)
          : MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: d.ic, color: fg),
          SizedBox(width: d.gap),
        ],
        if (isLoading)
          SizedBox(
            width: d.ic,
            height: d.ic,
            child: CircularProgressIndicator(strokeWidth: 1.8, color: fg),
          )
        else
          Flexible(
            child: Text(
              widget.label,
              overflow: TextOverflow.ellipsis,
              style: AppType.body.copyWith(
                fontSize: d.fs,
                fontWeight: FontWeight.w600,
                color: fg,
                height: 1,
              ),
            ),
          ),
        if (widget.iconAfter != null) ...[
          SizedBox(width: d.gap),
          Icon(widget.iconAfter, size: d.ic, color: fg),
        ],
      ],
    );

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: BoxConstraints(
            minHeight: d.minH,
            minWidth: isFull ? double.infinity : 0,
          ),
          padding: EdgeInsets.symmetric(horizontal: d.px, vertical: d.py),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: borderC, width: 1),
            boxShadow: shadow,
          ),
          child: Center(child: content),
        ),
      ),
    );
  }
}
