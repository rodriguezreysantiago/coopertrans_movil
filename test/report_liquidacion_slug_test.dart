// Test del slug de nombre de archivo de la liquidación (ReportLiquidacionService
// .slugSeguro). Lockea el fix 2026-05-22: el substring usaba raw.length sobre
// el string YA transformado (los replaceAll lo acortan) → RangeError y la
// liquidación no se generaba para nombres con puntos/espacios/símbolos.

import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/logistica/services/report_liquidacion.dart';

void main() {
  group('ReportLiquidacionService.slugSeguro', () {
    // El caso que crasheaba: nombre ≤32 chars donde los replaceAll acortan
    // (puntos, espacios dobles, símbolo al final) → raw.length > slug.length.
    test('nombre con puntos no crashea (RangeError) y queda saneado', () {
      final s = ReportLiquidacionService.slugSeguro('Vecchi S.R.L.');
      expect(s, 'vecchi_s_r_l');
    });

    test('espacios dobles colapsan a un solo guion bajo', () {
      expect(ReportLiquidacionService.slugSeguro('Ariel   Vecchi'),
          'ariel_vecchi');
    });

    test('símbolos al final no dejan guion colgante', () {
      expect(ReportLiquidacionService.slugSeguro('Transporte!!!'),
          'transporte');
    });

    test('acentos y ñ se normalizan', () {
      expect(ReportLiquidacionService.slugSeguro('Peña Logística'),
          'pena_logistica');
    });

    test('recorta a 32 chars sobre el string transformado (no el original)', () {
      // 40 letras → slug de 40 → recorta a 32. No RangeError.
      final s = ReportLiquidacionService.slugSeguro('a' * 40);
      expect(s.length, 32);
    });

    test('string que se vuelve vacío tras sanear no rompe', () {
      expect(ReportLiquidacionService.slugSeguro('---'), '');
      expect(ReportLiquidacionService.slugSeguro(''), '');
    });

    test('CUIT con guiones queda saneado sin crash', () {
      expect(ReportLiquidacionService.slugSeguro('30-12345678-9'),
          '30_12345678_9');
    });
  });
}
