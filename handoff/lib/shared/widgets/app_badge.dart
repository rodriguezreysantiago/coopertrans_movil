// handoff/lib/shared/widgets/app_badge.dart
//
// REFACTOR NÚCLEO · jun 2026
//
// AppBadge — pill semántica. Reemplaza al AppStatusBadge 2026-05-24 con
// la misma API esencial.

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_typography.dart';

enum AppBadgeSize { sm, md, lg }

class AppBadge extends StatelessWidget {
  final String text;
  final Color color;
  final bool solid;
  final bool dot;
  final AppBadgeSize size;
  final IconData? icon;

  const AppBadge({
    super.key,
    required this.text,
    required this.color,
    this.solid = false,
    this.dot = false,
    this.size = AppBadgeSize.md,
    this.icon,
  });

  factory AppBadge.success(String text, {AppBadgeSize size = AppBadgeSize.md, bool dot = false, Key? key}) {
    final c = const Color(0xFF4ADE80); // resolve at build time in real implementation
    return AppBadge(key: key, text: text, color: c, size: size, dot: dot);
  }

  ({double px, double py, double fs, double gap}) get _dims {
    switch (size) {
      case AppBadgeSize.sm: return (px: 7,  py: 2, fs: 10, gap: 5);
      case AppBadgeSize.md: return (px: 9,  py: 3, fs: 11, gap: 6);
      case AppBadgeSize.lg: return (px: 12, py: 5, fs: 12, gap: 7);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final d = _dims;
    final bg = solid ? color : color.withOpacity(isDark ? 0.16 : 0.10);
    final fg = solid ? (isDark ? const Color(0xFF050505) : Colors.white) : color;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: d.px, vertical: d.py),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            SizedBox(width: d.gap),
          ],
          if (icon != null) ...[
            Icon(icon, size: d.fs + 2, color: fg),
            SizedBox(width: d.gap),
          ],
          Text(text, style: AppType.body.copyWith(
            fontSize: d.fs, fontWeight: FontWeight.w600, color: fg, height: 1.2,
          )),
        ],
      ),
    );
  }
}
