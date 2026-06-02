// handoff/lib/shared/widgets/app_input.dart
//
// REFACTOR NÚCLEO · jun 2026
//
// AppInput — campo de entrada con label uppercase/mono a la izquierda
// estilo Núcleo. Para inputs estándar de form Material seguir usando
// TextField — el theme ya está alineado.
//
// Este widget es para "field rows" donde el label es parte de la fila
// (login DNI, settings, configuraciones rápidas).

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_typography.dart';

class AppInput extends StatefulWidget {
  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final TextInputType? keyboardType;
  final bool obscure;
  final bool mono;
  final IconData? icon;
  final String? trailingAction;
  final VoidCallback? onTrailingTap;
  final FocusNode? focusNode;
  final String? errorText;
  final bool enabled;
  final void Function(String)? onChanged;

  const AppInput({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.keyboardType,
    this.obscure = false,
    this.mono = false,
    this.icon,
    this.trailingAction,
    this.onTrailingTap,
    this.focusNode,
    this.errorText,
    this.enabled = true,
    this.onChanged,
  });

  @override
  State<AppInput> createState() => _AppInputState();
}

class _AppInputState extends State<AppInput> {
  late final FocusNode _node;
  bool _focused = false;
  bool _obscured = true;

  @override
  void initState() {
    super.initState();
    _node = widget.focusNode ?? FocusNode();
    _node.addListener(() => setState(() => _focused = _node.hasFocus));
    _obscured = widget.obscure;
  }

  @override
  void dispose() {
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;

    final Color borderC = hasError
        ? c.error
        : (_focused ? c.borderFocus : c.border);

    final List<BoxShadow> shadow = _focused && !hasError
        ? [BoxShadow(color: c.brandGlow, blurRadius: 0, spreadRadius: 4)]
        : const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: borderC, width: _focused ? 1.5 : 1),
            boxShadow: shadow,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 15, color: c.textMuted),
                const SizedBox(width: 12),
              ],
              if (widget.label != null) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 60),
                  child: Text(
                    widget.label!.toUpperCase(),
                    style: AppType.eyebrow.copyWith(color: c.textMuted),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  keyboardType: widget.keyboardType,
                  obscureText: _obscured && widget.obscure,
                  enabled: widget.enabled,
                  focusNode: _node,
                  onChanged: widget.onChanged,
                  style: (widget.mono ? AppType.mono : AppType.body).copyWith(
                    fontSize: 15, color: c.text, height: 1.2,
                    letterSpacing: widget.obscure && _obscured ? 4 : null,
                  ),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: widget.hint,
                    hintStyle: AppType.body.copyWith(color: c.textPlaceholder, fontSize: 15),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              if (widget.trailingAction != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: widget.obscure
                      ? () => setState(() => _obscured = !_obscured)
                      : widget.onTrailingTap,
                  child: Text(
                    widget.trailingAction!.toUpperCase(),
                    style: AppType.eyebrow.copyWith(color: c.brand),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (hasError) Padding(
          padding: const EdgeInsets.only(top: 6, left: 4),
          child: Text(widget.errorText!, style: AppType.label.copyWith(color: c.error)),
        ),
      ],
    );
  }
}
