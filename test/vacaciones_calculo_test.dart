import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/administracion/services/vacaciones_calculo.dart';

void main() {
  group('calcularDiasVacacionesLct — escala LCT art. 150 (al 31/12)', () {
    test('hasta 5 años → 14 días', () {
      // Ingreso 2024-10-17 (Corral, Excel): al 31/12/2025 ≈ 1.2 años → 14.
      final r = calcularDiasVacacionesLct(
          ingreso: DateTime(2024, 10, 17), anio: 2025);
      expect(r.dias, 14);
      expect(r.esProporcional, false);
    });

    test('exactamente 5 años cumplidos → 14 (límite "hasta 5")', () {
      // Ingreso 2020-12-31, corte 2025-12-31 → 5.0 años exactos → 14.
      final r = calcularDiasVacacionesLct(
          ingreso: DateTime(2020, 12, 31), anio: 2025);
      expect(r.dias, 14);
    });

    test('+5 a 10 años → 21 días', () {
      // Errazu 2018-01-09 → ≈ 8 años → 21. Corchete 2019-12-01 → ≈ 6 → 21.
      expect(
          calcularDiasVacacionesLct(ingreso: DateTime(2018, 1, 9), anio: 2025)
              .dias,
          21);
      expect(
          calcularDiasVacacionesLct(ingreso: DateTime(2019, 12, 1), anio: 2025)
              .dias,
          21);
    });

    test('+10 a 20 años → 28 días', () {
      // Flores 2014-11-11 → ≈ 11 años → 28.
      final r = calcularDiasVacacionesLct(
          ingreso: DateTime(2014, 11, 11), anio: 2025);
      expect(r.dias, 28);
    });

    test('+20 años → 35 días', () {
      final r = calcularDiasVacacionesLct(
          ingreso: DateTime(2000, 1, 1), anio: 2025);
      expect(r.dias, 35);
    });
  });

  group('calcularDiasVacacionesLct — bordes y proporcional', () {
    test('ingreso posterior al período → 0 días', () {
      // Ghesla 2026-03-01, período 2025 → ingreso futuro → 0.
      final r = calcularDiasVacacionesLct(
          ingreso: DateTime(2026, 3, 1), anio: 2025);
      expect(r.dias, 0);
      expect(r.esProporcional, false);
    });

    test('ingreso en 2da mitad del año de ingreso → proporcional marcado', () {
      // Bayer 2025-08-12, período 2025 → proporcional (art. 151).
      final r = calcularDiasVacacionesLct(
          ingreso: DateTime(2025, 8, 12), anio: 2025);
      expect(r.esProporcional, true);
      // Estimado ~ (142 días / 20) ≈ 7 — coincide con lo cargado a mano.
      expect(r.dias, greaterThan(0));
      expect(r.dias, lessThan(14));
    });

    test('ingreso en 1ra mitad del año de ingreso → escala 14 (ya tiene 6m)', () {
      // Ingreso 2025-03-01, período 2025 → al 31/12 tiene ~10 meses → 14.
      final r = calcularDiasVacacionesLct(
          ingreso: DateTime(2025, 3, 1), anio: 2025);
      expect(r.dias, 14);
      expect(r.esProporcional, false);
    });

    test('proporcional solo aplica al año de INGRESO, no a años siguientes', () {
      // Ingreso 2024-08-12 (2da mitad), pero período 2025 → ya tiene >1 año
      // al 31/12/2025 → escala 14, NO proporcional.
      final r = calcularDiasVacacionesLct(
          ingreso: DateTime(2024, 8, 12), anio: 2025);
      expect(r.dias, 14);
      expect(r.esProporcional, false);
    });
  });
}
