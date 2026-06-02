// lib/shared/widgets/app_map_marker.dart
//
// REFACTOR NÚCLEO · jun 2026 — markers + panels para los 5 mapas:
//   - Mapa de flota (Sitrack live)
//   - Mapa Volvo (alertas)
//   - ICM mapa de calor
//   - Zonas de descarga (geocercas)
//   - Logística mapa de tarifas
//
// Antes cada pantalla pintaba sus propios markers con tamaños y colores
// distintos. Acá unificamos: un dot semántico + label mono + glow
// firma cuando seleccionado.
//
// USO (sobre flutter_map):
//   Marker(
//     point: LatLng(...),
//     width: 60, height: 60,
//     builder: (_) => AppMapMarker(
//       label: 'VOL-187',
//       value: '72',
//       status: AppMarkerStatus.live,
//       selected: _selectedId == 'VOL-187',
//       onTap: () => _select('VOL-187'),
//     ),
//   )

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_typography.dart';

/// Estado semántico del marker — determina el color del dot.
enum AppMarkerStatus { live, idle, warning, error, info, neutral }

extension _StatusColor on AppMarkerStatus {
  Color resolve(AppColorsExt c) {
    switch (this) {
      case AppMarkerStatus.live: return c.brand;
      case AppMarkerStatus.idle: return c.textMuted;
      case AppMarkerStatus.warning: return c.warning;
      case AppMarkerStatus.error: return c.error;
      case AppMarkerStatus.info: return c.info;
      case AppMarkerStatus.neutral: return c.textSecondary;
    }
  }
}

class AppMapMarker extends StatelessWidget {
  /// Texto principal arriba del dot (patente, código zona, etc.).
  final String label;

  /// Texto opcional al lado del label (velocidad, distancia, count).
  final String? value;

  /// Estado semántico — define el color.
  final AppMarkerStatus status;

  /// Si `true`, el marker se agranda y tiene halo glow del brand.
  /// Reservado para el seleccionado del momento (1 a la vez).
  final bool selected;

  /// Tap callback.
  final VoidCallback? onTap;

  /// Tamaño del dot interno (px). 8 default; 12 cuando seleccionado.
  final double dotSize;

  const AppMapMarker({
    super.key,
    required this.label,
    required this.status,
    this.value,
    this.selected = false,
    this.onTap,
    this.dotSize = 8,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final statusColor = status.resolve(c);
    final size = selected ? dotSize * 1.4 : dotSize;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Halo glow cuando seleccionado — gesto firma Núcleo
          if (selected)
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.brand.withValues(alpha: 0.1),
                border: Border.all(color: c.brand.withValues(alpha: 0.45), width: 1),
              ),
            ),
          // Dot principal con shadow del color
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: size, height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor,
                  boxShadow: [
                    BoxShadow(
                      color: statusColor.withValues(alpha: 0.6),
                      blurRadius: selected ? 12 : 6,
                    ),
                  ],
                  border: selected
                      ? Border.all(color: c.text, width: 1.5)
                      : null,
                ),
              ),
              const SizedBox(height: 4),
              // Label pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: c.bg.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  value == null ? label : '$label · $value',
                  style: AppType.monoSm.copyWith(
                    color: c.text,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Panel info que flota sobre el mapa (coordenadas, zoom, layer toggle,
/// etc.). Cristal escarchado + border + radius Núcleo.
class AppMapInfoPill extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const AppMapInfoPill({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: c.bg.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: c.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: DefaultTextStyle(
        style: AppType.monoSm.copyWith(color: c.text),
        child: child,
      ),
    );
  }
}

/// Legend bar al pie del mapa (qué significa cada color de marker).
class AppMapLegend extends StatelessWidget {
  final List<({String label, AppMarkerStatus status})> items;
  const AppMapLegend({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppMapInfoPill(
      child: Wrap(
        spacing: 16, runSpacing: 8,
        children: items.map((it) {
          final color = it.status.resolve(c);
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6, height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                it.label.toUpperCase(),
                style: AppType.monoSm.copyWith(
                  color: c.text,
                  fontSize: 10,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}
