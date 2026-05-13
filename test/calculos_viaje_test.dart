// Tests del helper de cálculos del módulo Viajes (Logística).
//
// Foco: el redondeo a múltiplo de 5 descendente, el cálculo de
// montos brutos según tipo de tarifa, y la liquidación final
// (redondeado − adelanto + gastos).
//
// Estos cálculos manejan PLATA — un bug acá significa pagar de menos
// o de más al chofer. Tests exhaustivos en los casos borde.

import 'package:cloud_firestore/cloud_firestore.dart';
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

  group('calcularTodo — integración end-to-end (con comisión 18%)', () {
    test('POR_VIAJE con adelanto + gastos: liquidación final correcta', () {
      // base bruta chofer = $80.000 (tarifa fija por viaje).
      // 18% de 80000 = 14400 → ya múltiplo de 5 → redondeado 14400.
      // adelanto $5.000, gastos $2.000 → 14400 − 5000 + 2000 = 11400.
      final m = CalculosViaje.calcularTodo(
        unidadTarifa: UnidadTarifa.porViaje,
        tarifaReal: 200000,
        tarifaChofer: 80000,
        adelanto: 5000,
        gastos: [
          GastoViaje(monto: 2000, fecha: DateTime(2026, 5, 9)),
        ],
      );
      expect(m.montoVecchi, 200000);
      expect(m.montoChofer, closeTo(14400, 0.01));
      expect(m.montoChoferRedondeado, 14400);
      expect(m.gastosTotal, 2000);
      expect(m.liquidacionChofer, 11400);
      expect(m.comisionChoferPct, 18);
    });

    test('POR_TONELADA con descargados aplica comisión 18% y redondeo a múltiplo de 5',
        () {
      // Tarifa chofer 1237/TN × 27.5 TN = 34017.50 base bruta chofer.
      // 18% de 34017.50 = 6123.15 → redondeado al múltiplo de 5 abajo = 6120.
      final m = CalculosViaje.calcularTodo(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 5000,
        tarifaChofer: 1237,
        kgCargados: 28000,
        kgDescargados: 27500,
      );
      expect(m.montoVecchi, 137500);
      expect(m.montoChofer, closeTo(6123.15, 0.01));
      expect(m.montoChoferRedondeado, 6120);
    });

    test('POR_TONELADA estimado en curso (sin descargados): usa cargados', () {
      // Viaje EN_CURSO: cargó 30000 kg pero todavía no descargó.
      // El cálculo usa cargados como estimado.
      // base bruta chofer = 30 TN × $2000 = $60.000.
      // 18% × 60000 = 10800 → redondeado 10800.
      final m = CalculosViaje.calcularTodo(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 5000,
        tarifaChofer: 2000,
        kgCargados: 30000,
      );
      expect(m.montoVecchi, 150000);
      expect(m.montoChofer, closeTo(10800, 0.01));
      expect(m.montoChoferRedondeado, 10800);
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

    test('comisionPct custom — aplica al cálculo del chofer', () {
      // Si comisionPct = 22, el chofer cobra 22% (no 18). Base
      // bruta $80.000 × 0.22 = 17600. Múltiplo de 5 → 17600.
      final m = CalculosViaje.calcularTodo(
        unidadTarifa: UnidadTarifa.porViaje,
        tarifaReal: 200000,
        tarifaChofer: 80000,
        comisionPct: 22,
      );
      expect(m.comisionChoferPct, 22);
      expect(m.montoChofer, closeTo(17600, 0.01));
      expect(m.montoChoferRedondeado, 17600);
    });

    test('caso real de Santiago — UREA GRANULADA 34 TN', () {
      // tarifaReal = tarifaChofer = $68.624/TN, 34 TN descargadas.
      // montoVecchi = 34 × 68624 = $2.333.216 (factura a la empresa).
      // base bruta chofer = $2.333.216 (misma porque ambas tarifas son iguales).
      // 18% × 2333216 = 419978.88 → redondeado al múltiplo de 5 abajo = 419975.
      final m = CalculosViaje.calcularTodo(
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 68624,
        tarifaChofer: 68624,
        kgCargados: 35000,
        kgDescargados: 34000,
      );
      expect(m.montoVecchi, 2333216);
      expect(m.montoChofer, closeTo(419978.88, 0.01));
      expect(m.montoChoferRedondeado, 419975);
    });
  });

  // ─── Multi-tramo (Santiago 2026-05-11) ───
  group('calcularTodoMultiTramo', () {
    /// Helper para armar un tramo de prueba con la tarifa embebida en
    /// el snapshot (necesaria para que el cálculo sume por tramo).
    TramoViaje tramo({
      required UnidadTarifa unidad,
      required double tarifaReal,
      required double tarifaChofer,
      double? kgCargados,
      double? kgDescargados,
    }) {
      return TramoViaje(
        id: 't',
        tarifaId: 'fake',
        tarifaSnapshot: TarifaSnapshot(
          origenEtiqueta: 'O',
          destinoEtiqueta: 'D',
          empresaOrigenNombre: 'EO',
          empresaDestinoNombre: 'ED',
          unidadTarifa: unidad,
          tarifaReal: tarifaReal,
          tarifaChofer: tarifaChofer,
        ),
        kgCargados: kgCargados,
        kgDescargados: kgDescargados,
      );
    }

    test('un tramo single da el mismo resultado que calcularTodo', () {
      final viejo = CalculosViaje.calcularTodo(
        unidadTarifa: UnidadTarifa.porViaje,
        tarifaReal: 200000,
        tarifaChofer: 80000,
      );
      final nuevo = CalculosViaje.calcularTodoMultiTramo(tramos: [
        tramo(
          unidad: UnidadTarifa.porViaje,
          tarifaReal: 200000,
          tarifaChofer: 80000,
        ),
      ]);
      expect(nuevo.montoVecchi, viejo.montoVecchi);
      expect(nuevo.montoChofer, viejo.montoChofer);
      expect(nuevo.montoChoferRedondeado, viejo.montoChoferRedondeado);
    });

    test('dos tramos por viaje fijo: suma exacta + 18%', () {
      // BB → Olavarría: $200k Vecchi / $80k base chofer.
      // Olavarría → Tres Arroyos: $150k Vecchi / $60k base chofer.
      // Total: Vecchi $350k, base bruta chofer $140k.
      // 18% × 140k = $25.200 (ya múltiplo de 5).
      final m = CalculosViaje.calcularTodoMultiTramo(tramos: [
        tramo(
          unidad: UnidadTarifa.porViaje,
          tarifaReal: 200000,
          tarifaChofer: 80000,
        ),
        tramo(
          unidad: UnidadTarifa.porViaje,
          tarifaReal: 150000,
          tarifaChofer: 60000,
        ),
      ]);
      expect(m.montoVecchi, 350000);
      expect(m.montoChofer, closeTo(25200, 0.01));
      expect(m.montoChoferRedondeado, 25200);
    });

    test('dos tramos por tonelada con kg distintos', () {
      // Tramo 1: 28t @ $5000/tn Vecchi / $2000/tn chofer
      //   → Vecchi 140k, base chofer 56k.
      // Tramo 2: 30t @ $4000/tn Vecchi / $1500/tn chofer
      //   → Vecchi 120k, base chofer 45k.
      // Total: Vecchi 260k, base bruta chofer 101k.
      // 18% × 101.000 = 18.180 → ya múltiplo de 5 → redondeado 18.180.
      final m = CalculosViaje.calcularTodoMultiTramo(tramos: [
        tramo(
          unidad: UnidadTarifa.porTonelada,
          tarifaReal: 5000,
          tarifaChofer: 2000,
          kgDescargados: 28000,
        ),
        tramo(
          unidad: UnidadTarifa.porTonelada,
          tarifaReal: 4000,
          tarifaChofer: 1500,
          kgDescargados: 30000,
        ),
      ]);
      expect(m.montoVecchi, 260000);
      expect(m.montoChofer, closeTo(18180, 0.01));
      expect(m.montoChoferRedondeado, 18180);
    });

    test('mezcla de tramos por viaje y por tonelada con redondeo real', () {
      // Tramo 1 por viaje: base chofer 50001.
      // Tramo 2 por tonelada (28.5t @ $2003/tn): base chofer 57085.5.
      // Total base chofer: 107086.5.
      // 18% × 107086.5 = 19275.57 → múltiplo de 5 abajo = 19275.
      final m = CalculosViaje.calcularTodoMultiTramo(tramos: [
        tramo(
          unidad: UnidadTarifa.porViaje,
          tarifaReal: 100000,
          tarifaChofer: 50001,
        ),
        tramo(
          unidad: UnidadTarifa.porTonelada,
          tarifaReal: 5000,
          tarifaChofer: 2003,
          kgDescargados: 28500,
        ),
      ]);
      expect(m.montoChofer, closeTo(19275.57, 0.01));
      expect(m.montoChoferRedondeado, 19275);
      // El redondeado debe ser <= bruto y múltiplo de 5.
      expect(m.montoChoferRedondeado <= m.montoChofer, true);
      expect(m.montoChoferRedondeado % 5, 0);
    });

    test('redondeo se aplica sobre la suma con 18%, no por tramo', () {
      // base bruta chofer total: 33 + 37 = 70.
      // 18% × 70 = 12.6 → múltiplo de 5 abajo = 10.
      // Si redondeáramos por tramo: 33×0.18=5.94→5 + 37×0.18=6.66→5 → 10
      // que justo coincide acá, pero conceptualmente la fórmula es
      // sobre el total para evitar acumulación de errores.
      final m = CalculosViaje.calcularTodoMultiTramo(tramos: [
        tramo(
          unidad: UnidadTarifa.porViaje,
          tarifaReal: 100,
          tarifaChofer: 33,
        ),
        tramo(
          unidad: UnidadTarifa.porViaje,
          tarifaReal: 100,
          tarifaChofer: 37,
        ),
      ]);
      expect(m.montoChofer, closeTo(12.6, 0.01));
      expect(m.montoChoferRedondeado, 10);
    });

    test('adelanto + gastos sumados al total del viaje (no por tramo)', () {
      // 3 tramos por viaje: base bruta chofer total 120k.
      // 18% × 120000 = 21600 → ya múltiplo de 5 → redondeado 21600.
      // Adelanto $5k, gastos $1k.
      // Liquidación: 21600 − 5000 + 1000 = 17600.
      final m = CalculosViaje.calcularTodoMultiTramo(
        tramos: [
          tramo(
            unidad: UnidadTarifa.porViaje,
            tarifaReal: 100000,
            tarifaChofer: 40000,
          ),
          tramo(
            unidad: UnidadTarifa.porViaje,
            tarifaReal: 100000,
            tarifaChofer: 40000,
          ),
          tramo(
            unidad: UnidadTarifa.porViaje,
            tarifaReal: 100000,
            tarifaChofer: 40000,
          ),
        ],
        adelanto: 5000,
        gastos: [
          GastoViaje(monto: 1000, fecha: DateTime(2026, 5, 11)),
        ],
      );
      expect(m.montoChoferRedondeado, 21600);
      expect(m.gastosTotal, 1000);
      expect(m.liquidacionChofer, 17600);
    });

    test('tramo sin kg cargados ni descargados aporta 0', () {
      // Si un tramo todavía no tiene kg, su contribución es 0 — el
      // viaje se sigue calculando con los demás tramos. Útil mientras
      // el operador edita: muestra parcial correcto sin pisar el
      // resto.
      // base bruta chofer = 30t × $2000 = $60.000 (solo el primer
      // tramo aporta). 18% × 60000 = 10800.
      final m = CalculosViaje.calcularTodoMultiTramo(tramos: [
        tramo(
          unidad: UnidadTarifa.porTonelada,
          tarifaReal: 5000,
          tarifaChofer: 2000,
          kgCargados: 30000,
        ),
        tramo(
          unidad: UnidadTarifa.porTonelada,
          tarifaReal: 5000,
          tarifaChofer: 2000,
          // sin kg
        ),
      ]);
      expect(m.montoVecchi, 150000);
      expect(m.montoChofer, closeTo(10800, 0.01));
    });
  });

  // ─── Compat hacia atrás del modelo Viaje (Santiago 2026-05-11) ───
  group('Viaje compat hacia atrás (single-tramo viejo → multi-tramo)', () {
    test('Viaje.fromMap construye 1 tramo a partir de campos planos', () {
      // Doc viejo previo al refactor multi-tramo: tiene tarifa_id,
      // fecha_carga, kg_cargados, etc. al nivel del doc, NO tiene
      // array `tramos`. Debe parsear como single-tramo.
      final fechaCarga = DateTime(2026, 4, 15, 8, 30);
      final v = Viaje.fromMap('id-viejo', {
        'tarifa_id': 'tar-1',
        'tarifa_snapshot': {
          'origen_etiqueta': 'BB',
          'destino_etiqueta': 'OLA',
          'empresa_origen_nombre': 'CARGILL',
          'empresa_destino_nombre': 'LOMA NEGRA',
          'unidad_tarifa': 'POR_TONELADA',
          'tarifa_real': 5000,
          'tarifa_chofer': 2000,
        },
        'chofer_dni': '16969961',
        'estado': 'CONCLUIDO',
        'fecha_carga':
            Timestamp.fromDate(fechaCarga),
        'kg_cargados': 28000,
        'kg_descargados': 27800,
        'carga_transportada': 'Cemento',
        'remito_numero': 'A-12345',
        'monto_vecchi': 139000,
        'monto_chofer': 55600,
        'monto_chofer_redondeado': 55600,
        'comision_chofer_pct': 18,
        'gastos_total': 0,
        'liquidacion_chofer': 55600,
        'activo': true,
      });
      expect(v.tramos.length, 1);
      expect(v.esMultiTramo, false);
      expect(v.tramoPrincipal.tarifaId, 'tar-1');
      expect(v.tramoPrincipal.kgCargados, 28000);
      expect(v.tramoPrincipal.kgDescargados, 27800);
      expect(v.fechaCarga, fechaCarga);
      // Getter de compat — accede al primer tramo.
      expect(v.kgCargados, 28000);
      expect(v.rutaEtiqueta, 'BB → OLA');
    });

    test('Viaje.fromMap parsea correctamente array tramos[]', () {
      final v = Viaje.fromMap('id-nuevo', {
        'chofer_dni': '12345678',
        'estado': 'EN_CURSO',
        'tramos': [
          {
            'id': 't1',
            'tarifa_id': 'tar-A',
            'tarifa_snapshot': {
              'origen_etiqueta': 'BB',
              'destino_etiqueta': 'OLA',
              'empresa_origen_nombre': 'CARGILL',
              'empresa_destino_nombre': 'LOMA',
              'unidad_tarifa': 'POR_TONELADA',
              'tarifa_real': 5000,
              'tarifa_chofer': 2000,
            },
            'kg_cargados': 28000,
          },
          {
            'id': 't2',
            'tarifa_id': 'tar-B',
            'tarifa_snapshot': {
              'origen_etiqueta': 'OLA',
              'destino_etiqueta': 'TA',
              'empresa_origen_nombre': 'LOMA',
              'empresa_destino_nombre': 'YPF',
              'unidad_tarifa': 'POR_VIAJE',
              'tarifa_real': 100000,
              'tarifa_chofer': 40000,
            },
          },
        ],
        'monto_vecchi': 240000,
        'monto_chofer': 96000,
        'monto_chofer_redondeado': 95000,
        'comision_chofer_pct': 18,
        'gastos_total': 0,
        'liquidacion_chofer': 95000,
      });
      expect(v.tramos.length, 2);
      expect(v.esMultiTramo, true);
      expect(v.cantidadTramos, 2);
      expect(v.tramoPrincipal.tarifaId, 'tar-A');
      expect(v.tramoFinal.tarifaId, 'tar-B');
      expect(v.rutaEtiqueta, 'BB → … → TA (2 tramos)');
    });
  });
}
