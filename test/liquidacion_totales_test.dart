// Tests del cálculo firme/estimado de la pantalla de Liquidación
// (LiquidacionTotales) — la visión de la planilla llevada a la app:
//   GANANCIA − ADELANTOS + GASTOS = NETO firme (concluidos)
//   NETO + OTROS VIAJES = TOTAL ESTIMADO (especulación)

import 'package:flutter_test/flutter_test.dart';

import 'package:coopertrans_movil/features/logistica/models/adelanto_chofer.dart';
import 'package:coopertrans_movil/features/logistica/models/tarifa_logistica.dart';
import 'package:coopertrans_movil/features/logistica/models/viaje.dart';
import 'package:coopertrans_movil/features/logistica/utils/liquidacion_totales.dart';

Viaje vje({
  required String id,
  required EstadoViaje estado,
  double vecchi = 0,
  double chofer = 0,
  double gastos = 0,
  bool liquidado = false,
}) {
  const snap = TarifaSnapshot(
    origenEtiqueta: 'A',
    destinoEtiqueta: 'B',
    empresaOrigenNombre: 'X',
    empresaDestinoNombre: 'Y',
    unidadTarifa: UnidadTarifa.porViaje,
    tarifaReal: 0,
    tarifaChofer: 0,
  );
  return Viaje(
    id: id,
    tramos: [const TramoViaje(id: 't', tarifaId: 'T', tarifaSnapshot: snap)],
    choferDni: '1',
    estado: estado,
    montoVecchi: vecchi,
    montoChofer: chofer,
    montoChoferRedondeado: chofer,
    comisionChoferPct: 18,
    gastosTotal: gastos,
    liquidacionChofer: 0,
    liquidado: liquidado,
  );
}

AdelantoChofer adel(double monto) => AdelantoChofer(
      id: 'a$monto',
      choferDni: '1',
      fecha: DateTime(2026, 6, 1),
      monto: monto,
    );

void main() {
  group('LiquidacionTotales.de', () {
    test('separa concluidos (firme) de en curso/planeados (otros)', () {
      final tot = LiquidacionTotales.de(
        [
          vje(id: 'c1', estado: EstadoViaje.concluido, vecchi: 100, chofer: 80, gastos: 10),
          vje(id: 'c2', estado: EstadoViaje.concluido, vecchi: 50, chofer: 40),
          vje(id: 'o1', estado: EstadoViaje.enCurso, chofer: 30),
          vje(id: 'o2', estado: EstadoViaje.planeado, chofer: 20),
        ],
        [adel(25)],
      );
      expect(tot.nConcluidos, 2);
      expect(tot.nOtros, 2);
      expect(tot.facturadoFirme, 150); // 100 + 50
      expect(tot.gananciaFirme, 120); // 80 + 40
      expect(tot.gastosFirme, 10);
      expect(tot.adelantos, 25);
      // NETO firme = 120 - 25 + 10 = 105.
      expect(tot.netoFirme, 105);
      // OTROS = ganancia de en curso/planeados = 30 + 20 = 50.
      expect(tot.gananciaOtros, 50);
      // TOTAL ESTIMADO = 105 + 50 = 155.
      expect(tot.totalEstimado, 155);
      expect(tot.hayOtros, isTrue);
    });

    test('los gastos/adelantos de los OTROS no entran (son especulación)', () {
      final tot = LiquidacionTotales.de(
        [
          vje(id: 'o1', estado: EstadoViaje.enCurso, chofer: 100, gastos: 999),
        ],
        const [],
      );
      // Sin concluidos: NETO firme = 0 - 0 + 0 = 0.
      expect(tot.netoFirme, 0);
      // OTROS = solo la ganancia (100), NO los gastos de ese viaje.
      expect(tot.gananciaOtros, 100);
      expect(tot.gastosFirme, 0);
      expect(tot.totalEstimado, 100);
    });

    test('pendientes = concluidos NO liquidados', () {
      final tot = LiquidacionTotales.de(
        [
          vje(id: 'c1', estado: EstadoViaje.concluido, liquidado: true),
          vje(id: 'c2', estado: EstadoViaje.concluido, liquidado: false),
          vje(id: 'c3', estado: EstadoViaje.concluido, liquidado: false),
          // Un en curso no liquidado NO cuenta como pendiente de pago.
          vje(id: 'o1', estado: EstadoViaje.enCurso, liquidado: false),
        ],
        const [],
      );
      expect(tot.pendientes, 2);
    });

    test('solo adelantos (sin viajes) → neto negativo, sin otros', () {
      final tot = LiquidacionTotales.de(const [], [adel(50), adel(30)]);
      expect(tot.nConcluidos, 0);
      expect(tot.adelantos, 80);
      expect(tot.netoFirme, -80);
      expect(tot.hayOtros, isFalse);
      expect(tot.totalEstimado, -80);
      expect(tot.nAdelantos, 2);
    });

    test('sin otros viajes → hayOtros false y total == neto', () {
      final tot = LiquidacionTotales.de(
        [vje(id: 'c1', estado: EstadoViaje.concluido, chofer: 100)],
        const [],
      );
      expect(tot.hayOtros, isFalse);
      expect(tot.netoFirme, 100);
      expect(tot.totalEstimado, 100);
    });

    test('vacío → todo en cero', () {
      final tot = LiquidacionTotales.de(const [], const []);
      expect(tot.netoFirme, 0);
      expect(tot.totalEstimado, 0);
      expect(tot.nConcluidos, 0);
      expect(tot.nOtros, 0);
      expect(tot.pendientes, 0);
      expect(tot.hayOtros, isFalse);
    });
  });
}
