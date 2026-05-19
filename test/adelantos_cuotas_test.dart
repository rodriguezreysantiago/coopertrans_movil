// Tests para los helpers puros de cuotas mensuales (Santiago 2026-05-19).
// `repartirEnCuotas`: divide un monto total en N cuotas múltiplo de 5,
//                     la primera lleva el resto.
// `sumarMesesPreservandoDia`: mismo día del mes siguiente con manejo
//                              de fin de mes (31 ene + 1 mes = 28 feb).

import 'package:flutter_test/flutter_test.dart';

import 'package:coopertrans_movil/features/logistica/services/adelantos_service.dart';

void main() {
  group('repartirEnCuotas', () {
    test('división exacta sin resto', () {
      // $90.000 / 3 = $30.000 c/u, ya múltiplo de 5
      expect(
        AdelantosService.repartirEnCuotas(montoTotal: 90000, cuotas: 3),
        [30000, 30000, 30000],
      );
    });

    test('división con resto: primera cuota lleva la diferencia', () {
      // $100 / 3 = 33.33 → floor5 = 30 base. Resto = 100 - 30*3 = 10
      // → cuota 1: 40, cuota 2: 30, cuota 3: 30. Suma = 100.
      final r = AdelantosService.repartirEnCuotas(montoTotal: 100, cuotas: 3);
      expect(r, [40, 30, 30]);
      expect(r.reduce((a, b) => a + b), 100);
    });

    test('división con monto no múltiplo de 5', () {
      // $103 / 2 = 51.5 → floor5 = 50 base. Resto = 103 - 50*2 = 3
      // → cuota 1: 53, cuota 2: 50. Suma = 103.
      final r = AdelantosService.repartirEnCuotas(montoTotal: 103, cuotas: 2);
      expect(r, [53, 50]);
      expect(r.reduce((a, b) => a + b), 103);
    });

    test('división compleja: 50000 en 6 cuotas', () {
      // 50000/6 = 8333.33 → floor5 = 8330. Resto = 50000 - 8330*6 = 20
      // → cuota 1: 8350, resto: 8330 cada una. Suma = 50000.
      final r = AdelantosService.repartirEnCuotas(montoTotal: 50000, cuotas: 6);
      expect(r[0], 8350);
      expect(r.skip(1).toList(), [8330, 8330, 8330, 8330, 8330]);
      expect(r.reduce((a, b) => a + b), 50000);
    });

    test('monto chico que no llega al primer múltiplo de 5', () {
      // $2 / 2 = 1 → floor5 = 0 base. Resto = 2 - 0*2 = 2
      // → cuota 1: 2, cuota 2: 0. Suma = 2.
      final r = AdelantosService.repartirEnCuotas(montoTotal: 2, cuotas: 2);
      expect(r, [2, 0]);
    });
  });

  group('sumarMesesPreservandoDia', () {
    test('0 meses → misma fecha', () {
      final base = DateTime(2026, 5, 19);
      expect(AdelantosService.sumarMesesPreservandoDia(base, 0), base);
    });

    test('1 mes → mismo día mes siguiente', () {
      // 19 mayo → 19 junio
      expect(
        AdelantosService.sumarMesesPreservandoDia(DateTime(2026, 5, 19), 1),
        DateTime(2026, 6, 19),
      );
    });

    test('cruzar año: diciembre → enero del año siguiente', () {
      expect(
        AdelantosService.sumarMesesPreservandoDia(DateTime(2026, 12, 15), 1),
        DateTime(2027, 1, 15),
      );
    });

    test('31 de enero + 1 mes → 28/29 de febrero (fin de mes)', () {
      // 2026 NO es bisiesto → febrero tiene 28 días
      expect(
        AdelantosService.sumarMesesPreservandoDia(DateTime(2026, 1, 31), 1),
        DateTime(2026, 2, 28),
      );
      // 2028 SÍ es bisiesto → febrero tiene 29 días
      expect(
        AdelantosService.sumarMesesPreservandoDia(DateTime(2028, 1, 31), 1),
        DateTime(2028, 2, 29),
      );
    });

    test('31 de marzo + 1 mes → 30 de abril (abril tiene 30)', () {
      expect(
        AdelantosService.sumarMesesPreservandoDia(DateTime(2026, 3, 31), 1),
        DateTime(2026, 4, 30),
      );
    });

    test('múltiples meses adelante', () {
      // 19 mayo + 5 meses = 19 octubre
      expect(
        AdelantosService.sumarMesesPreservandoDia(DateTime(2026, 5, 19), 5),
        DateTime(2026, 10, 19),
      );
    });

    test('preserva hora/minuto/segundo', () {
      final base = DateTime(2026, 5, 19, 14, 30, 45);
      final r = AdelantosService.sumarMesesPreservandoDia(base, 1);
      expect(r.year, 2026);
      expect(r.month, 6);
      expect(r.day, 19);
      expect(r.hour, 14);
      expect(r.minute, 30);
      expect(r.second, 45);
    });
  });
}
