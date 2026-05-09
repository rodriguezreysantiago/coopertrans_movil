// Tests del helper de cálculos del módulo Viajes (Logística).
//
// Foco: el redondeo a múltiplo de 5 descendente, el cálculo de
// montos brutos según tipo de tarifa, y la liquidación final
// (redondeado − adelanto + gastos).
//
// Estos cálculos manejan PLATA — un bug acá significa pagar de menos
// o de más al chofer. Tests exhaustivos en los casos borde.

import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/logistica/models/tarifa_logistica.dart';
import 'package:coopertrans_movil/features/logistica/models/viaje.dart';
import 'package:coopertrans_movil/features/logistica/utils/calculos_viaje.dart';

void main() {
  group('redondearMultiploDe5Descendente', () {
    test('123.47 → 120 (caso típico con centavos)', () {
      expect(CalculosViaje.redondearMultiploDe5Descendente(123.47), 120);
    });

    test('158.99 → 155 (centavos altos no suben)', () {
      expect(CalculosViaje.redondearMultiploDe5Descendente(158.99), 155);
    });

    test('200.00 → 200 (ya es múltiplo de 5, no cambia)', () {
      expect(CalculosViaje.redondearMultiploDe5Descendente(200), 200);
    });

    test('124.00 → 120 (entero no múltiplo de 5)', () {
      expect(CalculosViaje.redondearMultiploDe5Descendente(124), 120);
    });

    test('125.00 → 125 (múltiplo de 5 entero)', () {
      expect(CalculosViaje.redondearMultiploDe5Descendente(125), 125);
    });

    test('124.99 → 120 (justo abajo del múltiplo)', () {
      expect(CalculosViaje.redondearMultiploDe5Descendente(124.99), 120);
    });

    test('0 → 0', () {
      expect(CalculosViaje.redondearMultiploDe5Descendente(0), 0);
    });

    test('4.99 → 0 (menos del primer múltiplo)', () {
      expect(CalculosViaje.redondearMultiploDe5Descendente(4.99), 0);
    });

    test('5 → 5', () {
      expect(CalculosViaje.redondearMultiploDe5Descendente(5), 5);
    });

    test('número grande con decimales: 1234567.89 → 1234565', () {
      expect(
        CalculosViaje.redondearMultiploDe5Descendente(1234567.89),
        1234565,
      );
    });
  });

  group('calcularMontosBrutos — POR_VIAJE', () {
    test('devuelve la tarifa fija sin tocar', () {
      final m = CalculosViaje.calcularMontosBrutos(
        unidadTarifa: UnidadTarifa.porViaje,
        tarifaReal: 200000,
        tarifaChofer: 80000,
        kgCargados: null,
      );
      expect(m.montoVecchi, 200000);
      expect(m.montoChofer, 80000);
    });

    test('ignora kgCargados aunque venga (no aplica para POR_VIAJE)', () {
      final m = CalculosViaje.calcularMontosBrutos(
        unidadTarifa: UnidadTarifa.porViaje,
        tarifaReal: 200000,
        tarifaChofer: 80000,
        kgCargados: 30000,
      );
      expect(m.montoVecchi, 200000);
      expect(m.montoChofer, 80000);
    });
  });

  group('calcularMontosBrutos — POR_TONELADA', () {
    test('descargados tienen prioridad sobre cargados (cifra final)', () {
      // Cargados 30000 (estimado), descargados 28500 (real). Usa 28500.
      final m = CalculosViaje.calcularMontosBrutos(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 5000,
        tarifaChofer: 2000,
        kgCargados: 30000,
        kgDescargados: 28500,
      );
      expect(m.montoVecchi, 142500); // 28.5 * 5000
      expect(m.montoChofer, 57000); // 28.5 * 2000
    });

    test('sin descargados, usa cargados como estimado', () {
      // Viaje en curso, todavía no descargó. Calcula con cargados.
      final m = CalculosViaje.calcularMontosBrutos(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 5000,
        tarifaChofer: 2000,
        kgCargados: 30000,
        kgDescargados: null,
      );
      expect(m.montoVecchi, 150000); // 30 * 5000
      expect(m.montoChofer, 60000); // 30 * 2000
    });

    test('kg parciales: 27500 kg descargados → 27.5 TN', () {
      final m = CalculosViaje.calcularMontosBrutos(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 5000,
        tarifaChofer: 2000,
        kgCargados: 28000,
        kgDescargados: 27500,
      );
      expect(m.montoVecchi, 137500);
      expect(m.montoChofer, 55000);
    });

    test('ambos null → 0 (viaje recién planeado)', () {
      final m = CalculosViaje.calcularMontosBrutos(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 5000,
        tarifaChofer: 2000,
        kgCargados: null,
        kgDescargados: null,
      );
      expect(m.montoVecchi, 0);
      expect(m.montoChofer, 0);
    });

    test('kg cargados = 0 y descargados null → 0', () {
      final m = CalculosViaje.calcularMontosBrutos(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 5000,
        tarifaChofer: 2000,
        kgCargados: 0,
      );
      expect(m.montoVecchi, 0);
      expect(m.montoChofer, 0);
    });

    test('kg descargados = 0 → cae a cargados (defensa contra typo)', () {
      // Si el operador puso descargados=0 por error, usar cargados.
      final m = CalculosViaje.calcularMontosBrutos(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 5000,
        tarifaChofer: 2000,
        kgCargados: 30000,
        kgDescargados: 0,
      );
      expect(m.montoVecchi, 150000);
      expect(m.montoChofer, 60000);
    });
  });

  group('calcularLiquidacion — formula: redondeado − adelanto + gastos', () {
    test('caso típico: 80000 − 30000 + 5000 = 55000', () {
      final l = CalculosViaje.calcularLiquidacion(
        montoChoferRedondeado: 80000,
        adelanto: 30000,
        gastosTotal: 5000,
      );
      expect(l, 55000);
    });

    test('sin adelanto ni gastos: liquidación = redondeado', () {
      final l = CalculosViaje.calcularLiquidacion(
        montoChoferRedondeado: 80000,
      );
      expect(l, 80000);
    });

    test('adelanto > monto chofer → liquidación negativa (caso real)', () {
      // El chofer ya cobró más del viaje — Vecchi le reclama o se
      // arregla en el siguiente viaje. La fórmula no clamp a 0.
      final l = CalculosViaje.calcularLiquidacion(
        montoChoferRedondeado: 50000,
        adelanto: 60000,
        gastosTotal: 0,
      );
      expect(l, -10000);
    });

    test('gastos compensan el adelanto', () {
      // 80000 − 30000 + 30000 = 80000.
      final l = CalculosViaje.calcularLiquidacion(
        montoChoferRedondeado: 80000,
        adelanto: 30000,
        gastosTotal: 30000,
      );
      expect(l, 80000);
    });
  });

  group('sumarGastos', () {
    test('suma los montos de la lista', () {
      final gastos = [
        GastoViaje(monto: 1500, fecha: DateTime(2026, 5, 9)),
        GastoViaje(monto: 2500, fecha: DateTime(2026, 5, 9)),
        GastoViaje(monto: 1000, fecha: DateTime(2026, 5, 9)),
      ];
      expect(CalculosViaje.sumarGastos(gastos), 5000);
    });

    test('lista vacía → 0', () {
      expect(CalculosViaje.sumarGastos([]), 0);
    });

    test('null → 0', () {
      expect(CalculosViaje.sumarGastos(null), 0);
    });
  });

  group('calcularTodo — integración end-to-end', () {
    test('POR_VIAJE con adelanto + gastos: liquidación final correcta', () {
      // tarifa fija $80.000 al chofer → redondeado 80000 (ya múltiplo).
      // adelanto $30.000, gastos $5.000 → liquidación = 80000-30000+5000=55000.
      final m = CalculosViaje.calcularTodo(
        unidadTarifa: UnidadTarifa.porViaje,
        tarifaReal: 200000,
        tarifaChofer: 80000,
        adelanto: 30000,
        gastos: [
          GastoViaje(monto: 5000, fecha: DateTime(2026, 5, 9)),
        ],
      );
      expect(m.montoVecchi, 200000);
      expect(m.montoChofer, 80000);
      expect(m.montoChoferRedondeado, 80000);
      expect(m.gastosTotal, 5000);
      expect(m.liquidacionChofer, 55000);
      expect(m.comisionChoferPct, 18);
    });

    test('POR_TONELADA con descargados aplica redondeo a múltiplo de 5', () {
      // Tarifa chofer 1237/TN x 27.5 TN = 34017.50 → redondeado 34015.
      final m = CalculosViaje.calcularTodo(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 5000,
        tarifaChofer: 1237,
        kgCargados: 28000,
        kgDescargados: 27500,
      );
      expect(m.montoVecchi, 137500);
      expect(m.montoChofer, closeTo(34017.5, 0.01));
      expect(m.montoChoferRedondeado, 34015);
    });

    test('POR_TONELADA estimado en curso (sin descargados): usa cargados', () {
      // Viaje EN_CURSO: cargó 30000 kg pero todavía no descargó.
      // El cálculo usa cargados como estimado.
      final m = CalculosViaje.calcularTodo(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 5000,
        tarifaChofer: 2000,
        kgCargados: 30000,
      );
      expect(m.montoVecchi, 150000);
      expect(m.montoChofer, 60000);
      expect(m.montoChoferRedondeado, 60000);
    });

    test('POR_TONELADA sin kg → todos los montos en 0', () {
      final m = CalculosViaje.calcularTodo(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 5000,
        tarifaChofer: 2000,
      );
      expect(m.montoVecchi, 0);
      expect(m.montoChofer, 0);
      expect(m.montoChoferRedondeado, 0);
      expect(m.liquidacionChofer, 0);
    });

    test('comisionPct custom para tests futuros', () {
      // Aunque no se aplica directo al monto del viaje (es informativo
      // en el modelo), el flag pasa al resultado para que la pantalla
      // de detalle pueda mostrarlo.
      final m = CalculosViaje.calcularTodo(
        unidadTarifa: UnidadTarifa.porViaje,
        tarifaReal: 200000,
        tarifaChofer: 80000,
        comisionPct: 22,
      );
      expect(m.comisionChoferPct, 22);
    });
  });
}
