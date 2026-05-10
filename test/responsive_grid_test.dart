import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/shared/utils/responsive_grid.dart';

/// Tests del helper [computeGridRatio] que arma el `childAspectRatio`
/// dinámico de los hubs responsive (Gomería / Logística / main_panel).
///
/// Lógica original estaba duplicada inline en los 3 hubs con leves
/// variaciones de clamp y fallback. Centralizada acá para que un cambio
/// futuro (ej. clampMin más generoso) se haga en un solo lugar y los
/// edge cases queden cubiertos por tests.
void main() {
  group('computeGridRatio — caso típico', () {
    test('mobile portrait 2×2 (Gomería hub)', () {
      // iPhone SE en portrait, ~280 dp ancho efectivo, ~600 dp alto
      // (post-AppBar y banner alertas).
      final ratio = computeGridRatio(
        boxWidth: 280,
        boxHeight: 600,
        cols: 2,
        rows: 2,
        spacing: 16,
      );
      // (280 - 16)/2 = 132 ancho; (600 - 16)/2 = 292 alto; ratio ≈ 0.45.
      expect(ratio, closeTo(0.45, 0.01));
    });

    test('tablet landscape 4×2 (Logística 4 cols × 2 filas)', () {
      // iPad landscape ~1000 dp ancho, ~600 dp alto.
      final ratio = computeGridRatio(
        boxWidth: 1000,
        boxHeight: 600,
        cols: 4,
        rows: 2,
        spacing: 12,
      );
      // (1000 - 36)/4 = 241 ancho; (600 - 12)/2 = 294 alto; ratio ≈ 0.82.
      expect(ratio, closeTo(0.82, 0.02));
    });

    test('desktop 5×1 (Logística 5 cols × 1 fila)', () {
      final ratio = computeGridRatio(
        boxWidth: 1500,
        boxHeight: 400,
        cols: 5,
        rows: 1,
        spacing: 12,
      );
      // (1500 - 48)/5 = 290 ancho; 400 alto; ratio ≈ 0.73.
      expect(ratio, closeTo(0.73, 0.02));
    });
  });

  group('computeGridRatio — clamp', () {
    test('aplica clampMin si pantalla es muy alta y angosta', () {
      // Mobile angosto + 5 tiles en 2 cols → 3 filas → cards muy bajas.
      final ratio = computeGridRatio(
        boxWidth: 300,
        boxHeight: 1500, // alto absurdo
        cols: 2,
        rows: 3,
        spacing: 12,
        clampMin: 0.45,
      );
      // (300-12)/2 = 144 ancho; (1500-24)/3 = 492 alto; ratio raw ≈ 0.29.
      // Como < 0.45, debería quedar clampeado a 0.45.
      expect(ratio, 0.45);
    });

    test('aplica clampMax si pantalla es muy ancha y baja', () {
      // Pantalla rara: muy ancha y bajita.
      final ratio = computeGridRatio(
        boxWidth: 2000,
        boxHeight: 100,
        cols: 2,
        rows: 1,
        spacing: 12,
        clampMax: 2.0,
      );
      // raw ≈ 9.94, clamp a 2.0.
      expect(ratio, 2.0);
    });

    test('clampMin custom anula el default 0.45', () {
      final ratio = computeGridRatio(
        boxWidth: 300,
        boxHeight: 1500,
        cols: 2,
        rows: 3,
        spacing: 12,
        clampMin: 0.6, // más restrictivo que default
      );
      expect(ratio, 0.6);
    });
  });

  group('computeGridRatio — defensivo (devuelve fallback)', () {
    test('cols ≤ 0 → fallback', () {
      expect(
        computeGridRatio(
          boxWidth: 300,
          boxHeight: 600,
          cols: 0,
          rows: 2,
          spacing: 12,
          fallback: 1.5,
        ),
        1.5,
      );
    });

    test('rows ≤ 0 → fallback', () {
      expect(
        computeGridRatio(
          boxWidth: 300,
          boxHeight: 600,
          cols: 2,
          rows: 0,
          spacing: 12,
        ),
        1.0, // default fallback
      );
    });

    test('boxHeight ≤ 0 (LayoutBuilder con alto unbounded) → fallback', () {
      // Caso real: hub adentro de SingleChildScrollView sin Expanded.
      // constraints.maxHeight es infinito o 0. No queremos NaN.
      expect(
        computeGridRatio(
          boxWidth: 300,
          boxHeight: 0,
          cols: 2,
          rows: 2,
          spacing: 12,
          fallback: 1.1,
        ),
        1.1,
      );
    });

    test('boxWidth ≤ 0 → fallback', () {
      expect(
        computeGridRatio(
          boxWidth: 0,
          boxHeight: 600,
          cols: 2,
          rows: 2,
          spacing: 12,
        ),
        1.0,
      );
    });

    test('spacing se come todo el ancho disponible → fallback', () {
      // Edge case: pantalla absurdamente chica con spacing grande.
      // (50 - 12 * 4) / 5 = 0.4 ancho, válido pero límite.
      // (50 - 12 * 5) / 5 = -2 ancho, inválido → fallback.
      expect(
        computeGridRatio(
          boxWidth: 50,
          boxHeight: 600,
          cols: 6,
          rows: 1,
          spacing: 12,
          fallback: 1.0,
        ),
        1.0,
      );
    });

    test('spacing se come todo el alto disponible → fallback', () {
      expect(
        computeGridRatio(
          boxWidth: 600,
          boxHeight: 50,
          cols: 1,
          rows: 6,
          spacing: 12,
          fallback: 1.0,
        ),
        1.0,
      );
    });
  });

  group('computeGridRatio — escenarios reales de los 3 hubs', () {
    test('Gomería hub 2×2 sin banner alertas', () {
      // Pantalla mobile portrait típica iPhone 14: 390×844 dp.
      // Padding top 16 + AppBar ~80 + bottom nav 80 + padding bot 16
      // → ~650 dp para el body. Sin banner alertas (caso normal).
      final ratio = computeGridRatio(
        boxWidth: 358, // 390 - 32 padding
        boxHeight: 650,
        cols: 2,
        rows: 2,
        spacing: 16,
        clampMin: 0.5,
      );
      // (358-16)/2 = 171; (650-16)/2 = 317; ratio ≈ 0.54. Sobre 0.5
      // (clamp), queda 0.54.
      expect(ratio, closeTo(0.54, 0.02));
    });

    test('Gomería hub 2×2 con banner alertas (más alto consumido)', () {
      // Mismo iPhone pero con banner ~80 dp adicional.
      final ratio = computeGridRatio(
        boxWidth: 358,
        boxHeight: 570, // 650 - 80 banner
        cols: 2,
        rows: 2,
        spacing: 16,
        clampMin: 0.5,
      );
      // (358-16)/2 = 171; (570-16)/2 = 277; ratio ≈ 0.62.
      expect(ratio, closeTo(0.62, 0.02));
    });

    test('main_panel chofer 2×2 con 3 botones (admin=false)', () {
      // 3 botones en 2 cols → ceil(3/2) = 2 filas.
      // Pantalla iPhone 14 con max 600 dp constrained.
      final ratio = computeGridRatio(
        boxWidth: 358,
        boxHeight: 500, // post-_WelcomeHeader
        cols: 2,
        rows: 2,
        spacing: 15,
        clampMin: 0.5,
        fallback: 1.2,
      );
      // (358-15)/2 = 171; (500-15)/2 = 242; ratio ≈ 0.71.
      expect(ratio, closeTo(0.71, 0.02));
    });
  });
}
