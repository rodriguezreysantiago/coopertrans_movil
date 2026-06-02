// handoff/lib/shared/widgets/app_ambient.dart
//
// REFACTOR NÚCLEO · jun 2026
//
// AppAmbient — el radial gradient firma del sistema. Va detrás del contenido
// principal de pantallas hero (login, dashboard, splash, detalle hero).
//
// USO:
//   Stack(
//     children: [
//       const AppAmbient(),           // se renderiza al fondo
//       SafeArea(child: yourContent), // contenido encima
//     ],
//   );

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

class AppAmbient extends StatelessWidget {
  final Alignment alignment;
  final double sizeFactor;
  final double intensity;
  final Color? color;

  const AppAmbient({
    super.key,
    this.alignment = const Alignment(0, -1.2),
    this.sizeFactor = 1.4,
    this.intensity = 1.0,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.colors.brand;
    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(builder: (_, box) {
          final radius = box.maxWidth.clamp(0.0, 1200.0) * sizeFactor;
          return Stack(children: [
            Align(
              alignment: alignment,
              child: Container(
                width: radius, height: radius,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      c.withValues(alpha: 0.18 * intensity),
                      c.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.7],
                  ),
                ),
              ),
            ),
          ]);
        }),
      ),
    );
  }
}
