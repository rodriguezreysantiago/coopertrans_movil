import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/gomeria/models/nivel_desgaste.dart';

/// Tests del semáforo de desgaste (rediseño gomería 2026-05-29).
void main() {
  group('nivelDesgaste — umbrales por defecto (80 / 100)', () {
    test('null => sinDatos', () {
      expect(nivelDesgaste(null), NivelDesgaste.sinDatos);
    });
    test('0% => ok', () {
      expect(nivelDesgaste(0), NivelDesgaste.ok);
    });
    test('79.9% => ok (justo por debajo de alerta)', () {
      expect(nivelDesgaste(79.9), NivelDesgaste.ok);
    });
    test('80% => alerta (borde inclusivo)', () {
      expect(nivelDesgaste(80), NivelDesgaste.alerta);
    });
    test('99% => alerta', () {
      expect(nivelDesgaste(99), NivelDesgaste.alerta);
    });
    test('100% => critico (borde inclusivo)', () {
      expect(nivelDesgaste(100), NivelDesgaste.critico);
    });
    test('125% (pasada de vida) => critico', () {
      expect(nivelDesgaste(125), NivelDesgaste.critico);
    });
  });

  group('nivelDesgaste — umbrales custom', () {
    test('respeta umbrales pasados por parámetro', () {
      expect(nivelDesgaste(70, umbralAlerta: 60, umbralCritico: 90),
          NivelDesgaste.alerta);
      expect(nivelDesgaste(95, umbralAlerta: 60, umbralCritico: 90),
          NivelDesgaste.critico);
      expect(nivelDesgaste(50, umbralAlerta: 60, umbralCritico: 90),
          NivelDesgaste.ok);
    });
  });
}
