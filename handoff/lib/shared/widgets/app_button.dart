// handoff/lib/shared/widgets/app_button.dart
//
// REFACTOR NÚCLEO · jun 2026
//
// AppButton — botón canónico del sistema en 4 kinds × 4 sizes.
// Reemplaza el AppButton 2026-05-24 manteniendo la misma API
// (`AppButton.primary(...)`, `.secondary(...)`, `.ghost(...)`, `.danger(...)`).
//
// CAMBIOS clave vs. versión previa:
// - El primario ahora glows. La sombra es `context.colors.brandGlow`.
// - Radius por defecto = 8 (era 12).
// - Tamaños: sm/md/lg/xl (eran solo sm/md/lg).
// - Hover state nativo en desktop / web — alfa subtle del fg.
// - `iconAfter` además de `icon` — el flecha del CTA va a la derecha.
// - `full` toma todo el ancho disponible.
// - Min touch target 44x44 (iOS HIG / Material 48dp).

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_typography.dart';

enum AppButtonKind { primary, secondary, ghost, danger }
enum AppButtonSize { sm, md, lg, xl }

class AppButton extends StatefulWidget {
  final String label;
  final AppButtonKind kind;
  final AppButtonSize size;
  final IconData? icon;
  final IconData? iconAfter;
  final VoidCallback? onPressed;
  final bool full;
  final bool glow;
  final bool loading;

  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = AppButtonKind.primary,
    this.size = AppButtonSize.md,
    this.icon,
    this.iconAfter,
    this.full = false,
    this.glow = true,
    this.loading = false,
  });

  factory AppButton.primary(String label, {VoidCallback? onPressed, IconData? icon, IconData? iconAfter, AppButtonSize size = AppButtonSize.md, bool full = false, bool glow = true, bool loading = false, Key? key}) =>
    AppButton(key: key, label: label, onPressed: onPressed, kind: AppButtonKind.primary, size: size, icon: icon, iconAfter: iconAfter, full: full, glow: glow, loading: loading);

  factory AppButton.secondary(String label, {VoidCallback? onPressed, IconData? icon, IconData? iconAfter, AppButtonSize size = AppButtonSize.md, bool full = false, Key? key}) =>
    AppButton(key: key, label: label, onPressed: onPressed, kind: AppButtonKind.secondary, size: size, icon: icon, iconAfter: iconAfter, full: full);

  factory AppButton.ghost(String label, {VoidCallback? onPressed, IconData? icon, IconData? iconAfter, AppButtonSize size = AppButtonSize.md, bool full = false, Key? key}) =>
    AppButton(key: key, label: label, onPressed: onPressed, kind: AppButtonKind.ghost, size: size, icon: icon, iconAfter: iconAfter, full: full);

  factory AppButton.danger(String label, {VoidCallback? onPressed, IconData? icon, IconData? iconAfter, AppButtonSize size = AppButtonSize.md, bool full = false, Key? key}) =>
    AppButton(key: key, label: label, onPressed: onPressed, kind: AppButtonKind.danger, size: size, icon: icon, iconAfter: iconAfter, full: full);

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _hover = false;

  ({double px, double py, double fs, double gap, double ic}) get _dims {
    switch (widget.size) {
      case AppButtonSize.sm: return (px: 10, py: 6,  fs: 12,   gap: 6,  ic: 13);
      case AppButtonSize.md: return (px: 14, py: 9,  fs: 13,   gap: 8,  ic: 14);
      case AppButtonSize.lg: return (px: 18, py: 13, fs: 15,   gap: 10, ic: 16);
      case AppButtonSize.xl: return (px: 22, py: 16, fs: 16,   gap: 12, ic: 18);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cols = context.colors;
    final d = _dims;
    final enabled = widget.onPressed != null && !widget.loading;

    late final Color bg, fg, borderC;
    List<BoxShadow>? shadow;
    switch (widget.kind) {
      case AppButtonKind.primary:
        bg = cols.brand; fg = cols.brandFg; borderC = Colors.transparent;
        if (widget.glow && enabled) shadow = AppShadows.glow(cols.brand);
        break;
      case AppButtonKind.secondary:
        bg = cols.surface3; fg = cols.text; borderC = cols.borderStrong;
        break;
      case AppButtonKind.ghost:
        bg = Colors.transparent; fg = cols.text; borderC = cols.border;
        break;
      case AppButtonKind.danger:
        bg = cols.error; fg = Colors.white; borderC = Colors.transparent;
        if (widget.glow && enabled) shadow = AppShadows.glow(cols.error);
        break;
    }

    if (_hover && enabled) {
      // sutile hover
      bg = Color.alphaBlend(Colors.white.withOpacity(0.04), bg);
    }
    if (!enabled) {
      bg = bg.withOpacity(0.5);
      fg = fg.withOpacity(0.5);
    }

    final content = Row(
      mainAxisSize: widget.full ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: widget.full
          ? (widget.iconAfter != null ? MainAxisAlignment.spaceBetween : MainAxisAlignment.center)
          : MainAxisAlignment.start,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: d.ic, color: fg),
          SizedBox(width: d.gap),
        ],
        if (widget.loading)
          SizedBox(
            width: d.ic, height: d.ic,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: fg),
          )
        else
          Text(widget.label, style: AppType.body.copyWith(
            fontSize: d.fs, fontWeight: FontWeight.w600, color: fg, height: 1,
          )),
        if (widget.iconAfter != null) ...[
          SizedBox(width: d.gap),
          Icon(widget.iconAfter, size: d.ic, color: fg),
        ],
      ],
    );

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit:  (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: BoxConstraints(
            minHeight: widget.size == AppButtonSize.sm ? 32 : 44, // iOS min touch
          ),
          padding: EdgeInsets.symmetric(horizontal: d.px, vertical: d.py),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: borderC, width: 1),
            boxShadow: shadow,
          ),
          child: content,
        ),
      ),
    );
  }
}
