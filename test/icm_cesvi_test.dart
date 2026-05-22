// Tests para helpers PUROS del cálculo CESVI del ICM (Dart).
// Espejo de `functions/test/icm_cesvi.test.js`. Si cambiás casos acá,
// cambialos también allá — el cliente Flutter y el cron Cloud Function
// deben dar el MISMO ICM para la misma data.

import 'package:flutter_test/flutter_test.dart';

import 'package:coopertrans_movil/features/icm/services/icm_cesvi.dart';

void main() {
  group('PesoCesvi (constantes del slide 3 Carsync)', () {
    test('Aceleración brusca = 2.8', () {
      expect(PesoCesvi.aceleracionBrusca, 2.8);
    });
    test('Frenada brusca = 5.8 (el más severo)', () {
      expect(PesoCesvi.frenadaBrusca, 5.8);
    });
    test('Giro brusco = 2.8 (igual que aceleración)', () {
      expect(PesoCesvi.giroBrusco, 2.8);
    });
  });

  group('gravedadExceso (clasificación urban/rural)', () {
    test('velMax ≤ límite → null', () {
      expect(
        gravedadExceso(velMaxKmh: 100, velLimiteKmh: 110, areaType: 'rural'),
        null,
      );
      expect(
        gravedadExceso(velMaxKmh: 110, velLimiteKmh: 110, areaType: 'rural'),
        null,
      );
    });
    test('límite 0 → null', () {
      expect(
        gravedadExceso(velMaxKmh: 100, velLimiteKmh: 0, areaType: 'rural'),
        null,
      );
    });
    test('rural: 105 sobre 100 (5%) → media', () {
      expect(
        gravedadExceso(velMaxKmh: 105, velLimiteKmh: 100, areaType: 'rural'),
        GravedadExceso.media,
      );
    });
    test('rural: 102 sobre 100 (2%) → baja', () {
      expect(
        gravedadExceso(velMaxKmh: 102, velLimiteKmh: 100, areaType: 'rural'),
        GravedadExceso.baja,
      );
    });
    test('rural: 110 sobre 100 (10%) → alta', () {
      expect(
        gravedadExceso(velMaxKmh: 110, velLimiteKmh: 100, areaType: 'rural'),
        GravedadExceso.alta,
      );
    });
    test('urban: 105 sobre 100 (5%) → media (umbral 5-10%)', () {
      expect(
        gravedadExceso(velMaxKmh: 105, velLimiteKmh: 100, areaType: 'urban'),
        GravedadExceso.media,
      );
    });
    test('urban: 103 sobre 100 (3%) → baja', () {
      expect(
        gravedadExceso(velMaxKmh: 103, velLimiteKmh: 100, areaType: 'urban'),
        GravedadExceso.baja,
      );
    });
    test('urban: 115 sobre 100 (15%) → alta (>10%)', () {
      expect(
        gravedadExceso(velMaxKmh: 115, velLimiteKmh: 100, areaType: 'urban'),
        GravedadExceso.alta,
      );
    });
    test('unknown se trata como rural', () {
      expect(
        gravedadExceso(velMaxKmh: 110, velLimiteKmh: 100, areaType: 'unknown'),
        GravedadExceso.alta,
      );
    });
  });

  group('puntajeSobrevelocidad (fórmula slide 11)', () {
    test('sin gravedad → 0', () {
      expect(
        puntajeSobrevelocidad(
          gravedad: null, velMaxKmh: 90, velPromKmh: 85, duracionSeg: 30),
        0,
      );
    });
    test('baja → 1 fijo', () {
      expect(
        puntajeSobrevelocidad(
          gravedad: GravedadExceso.baja,
          velMaxKmh: 105, velPromKmh: 102, duracionSeg: 30),
        1,
      );
    });
    test('media: clamp [1.1, 1.4]', () {
      // (110-105)*9*0.01 = 0.45 → 1.1
      expect(
        puntajeSobrevelocidad(
          gravedad: GravedadExceso.media,
          velMaxKmh: 110, velPromKmh: 105, duracionSeg: 9),
        1.1,
      );
      // (120-105)*20*0.01 = 3 → 1.4
      expect(
        puntajeSobrevelocidad(
          gravedad: GravedadExceso.media,
          velMaxKmh: 120, velPromKmh: 105, duracionSeg: 20),
        1.4,
      );
      // (120-100)*6*0.01 = 1.2 → en rango
      expect(
        puntajeSobrevelocidad(
          gravedad: GravedadExceso.media,
          velMaxKmh: 120, velPromKmh: 100, duracionSeg: 6),
        closeTo(1.2, 0.001),
      );
    });
    test('alta: clamp [1.5, 5]', () {
      // ejemplo del slide 12: (55.75-50.52)*9*0.01 = 0.4707 → 1.5
      expect(
        puntajeSobrevelocidad(
          gravedad: GravedadExceso.alta,
          velMaxKmh: 55.75, velPromKmh: 50.52, duracionSeg: 9),
        1.5,
      );
      // (120-100)*30*0.01 = 6 → 5
      expect(
        puntajeSobrevelocidad(
          gravedad: GravedadExceso.alta,
          velMaxKmh: 120, velPromKmh: 100, duracionSeg: 30),
        5,
      );
      // (120-100)*15*0.01 = 3 → en rango
      expect(
        puntajeSobrevelocidad(
          gravedad: GravedadExceso.alta,
          velMaxKmh: 120, velPromKmh: 100, duracionSeg: 15),
        closeTo(3, 0.001),
      );
    });
  });

  group('puntajeFatigaPorBloque (escalera slide 3)', () {
    test('< 2h → 0', () {
      expect(puntajeFatigaPorBloque(0), 0);
      expect(puntajeFatigaPorBloque(60 * 60), 0);
      expect(puntajeFatigaPorBloque(7000), 0);
    });
    test('2h a 3h → 5', () {
      expect(puntajeFatigaPorBloque(2 * 3600), 5);
      expect(puntajeFatigaPorBloque(2.5 * 3600), 5);
    });
    test('3h a 4h → 10', () {
      expect(puntajeFatigaPorBloque(3 * 3600), 10);
      expect(puntajeFatigaPorBloque(3.5 * 3600), 10);
    });
    test('> 4h → 15', () {
      expect(puntajeFatigaPorBloque(4 * 3600), 15);
      expect(puntajeFatigaPorBloque(6 * 3600), 15);
    });
  });

  group('tiempo de activación (slide 6) — filtro infracción CESVI', () {
    EventoSitrackICM ev({
      required int id,
      required int ts,
      double speed = 110,
      double limit = 100,
      String area = 'rural',
    }) {
      return EventoSitrackICM(
        eventId: id, reportDateMs: ts,
        assetId: 'A', driverDni: '1',
        speed: speed, cartographyLimitSpeed: limit, areaType: area,
      );
    }

    test('URBAN → 6s mínimo', () {
      final r1 = calcularIcmJornada([
        ev(id: 8, ts: 0, speed: 110, limit: 80, area: 'urban'),
        ev(id: 9, ts: 5000, speed: 105, limit: 80, area: 'urban'),
      ], [0]);
      expect(r1.sobrevelocidades, 0);
      expect(r1.icm, 100);
      final r2 = calcularIcmJornada([
        ev(id: 8, ts: 0, speed: 110, limit: 80, area: 'urban'),
        ev(id: 9, ts: 7000, speed: 105, limit: 80, area: 'urban'),
      ], [0]);
      expect(r2.sobrevelocidades, 1);
      expect(r2.icm, lessThan(100));
    });

    test('RURAL → 10s mínimo', () {
      final r1 = calcularIcmJornada([
        ev(id: 8, ts: 0, speed: 120, limit: 100, area: 'rural'),
        ev(id: 9, ts: 9000, speed: 115, limit: 100, area: 'rural'),
      ], [0]);
      expect(r1.sobrevelocidades, 0);
      final r2 = calcularIcmJornada([
        ev(id: 8, ts: 0, speed: 120, limit: 100, area: 'rural'),
        ev(id: 9, ts: 11000, speed: 115, limit: 100, area: 'rural'),
      ], [0]);
      expect(r2.sobrevelocidades, 1);
    });

    test('UNKNOWN tratado como rural (10s)', () {
      final r = calcularIcmJornada([
        ev(id: 8, ts: 0, speed: 120, limit: 100, area: 'unknown'),
        ev(id: 9, ts: 8000, speed: 115, limit: 100, area: 'unknown'),
      ], [0]);
      expect(r.sobrevelocidades, 0);
    });

    test('par sin cartografía (límite 0) → no infracción', () {
      final r = calcularIcmJornada([
        ev(id: 8, ts: 0, speed: 120, limit: 0, area: 'rural'),
        ev(id: 9, ts: 30000, speed: 115, limit: 0, area: 'rural'),
      ], [0]);
      expect(r.sobrevelocidades, 0);
    });
  });

  group('categorizarCesvi (umbrales YPF 91/71)', () {
    test('>= 91 → bajo', () {
      expect(categorizarCesvi(91), CategoriaCesvi.bajo);
      expect(categorizarCesvi(100), CategoriaCesvi.bajo);
    });
    test('71-90 → medio', () {
      expect(categorizarCesvi(71), CategoriaCesvi.medio);
      expect(categorizarCesvi(90.99), CategoriaCesvi.medio);
      expect(categorizarCesvi(79), CategoriaCesvi.medio);
    });
    test('< 71 → alto', () {
      expect(categorizarCesvi(0), CategoriaCesvi.alto);
      expect(categorizarCesvi(70.99), CategoriaCesvi.alto);
    });
  });

  group('agruparSobrevelocidades (pareo 8+9)', () {
    EventoSitrackICM ev({
      required int id,
      required int ts,
      String asset = 'AB1',
      String dni = '111',
      double speed = 110,
      double limit = 100,
      String area = 'rural',
    }) {
      return EventoSitrackICM(
        eventId: id,
        reportDateMs: ts,
        assetId: asset,
        driverDni: dni,
        speed: speed,
        cartographyLimitSpeed: limit,
        areaType: area,
      );
    }

    test('inicio + fin contiguos → 1 par', () {
      final pares = agruparSobrevelocidades([
        ev(id: 8, ts: 1000),
        ev(id: 9, ts: 30000, speed: 105),
      ]);
      expect(pares.length, 1);
      expect(pares[0].duracionSeg, 29);
    });
    test('inicio sin fin → descartado', () {
      expect(agruparSobrevelocidades([ev(id: 8, ts: 1000)]).length, 0);
    });
    test('fin sin inicio → descartado', () {
      expect(agruparSobrevelocidades([ev(id: 9, ts: 1000)]).length, 0);
    });
    test('par fuera de ventana 30min → descartado', () {
      final pares = agruparSobrevelocidades([
        ev(id: 8, ts: 1000),
        ev(id: 9, ts: 1000 + 31 * 60 * 1000),
      ]);
      expect(pares.length, 0);
    });
    test('2 pares en orden → 2 pares', () {
      final pares = agruparSobrevelocidades([
        ev(id: 8, ts: 1000),
        ev(id: 9, ts: 10000),
        ev(id: 8, ts: 50000),
        ev(id: 9, ts: 80000),
      ]);
      expect(pares.length, 2);
      expect(pares[0].duracionSeg, 9);
      expect(pares[1].duracionSeg, 30);
    });
    test('eventos de DIFERENTES choferes NO se cruzan', () {
      final pares = agruparSobrevelocidades([
        ev(id: 8, ts: 1000, dni: '111'),
        ev(id: 9, ts: 10000, dni: '222'),
      ]);
      expect(pares.length, 0);
    });
  });

  group('calcularIcmJornada (integración fórmula completa)', () {
    EventoSitrackICM ev({
      required int id,
      required int ts,
      String asset = 'AB1',
      String dni = '111',
      double? speed,
      double? limit,
      String area = 'rural',
    }) {
      return EventoSitrackICM(
        eventId: id,
        reportDateMs: ts,
        assetId: asset,
        driverDni: dni,
        speed: speed,
        cartographyLimitSpeed: limit,
        areaType: area,
      );
    }

    test('jornada sin eventos y < 2h → ICM 100', () {
      final r = calcularIcmJornada([], [3600]);
      expect(r.icm, 100);
      expect(r.categoria, CategoriaCesvi.bajo);
      expect(r.puntosTotales, 0);
    });

    test('1 frenada brusca → ICM 94.2', () {
      final r = calcularIcmJornada([
        ev(id: 67, ts: 1000, speed: 50, limit: 80, area: 'urban'),
      ], [3600]);
      expect(r.frenadasBruscas, 1);
      expect(r.puntosFrenada, 5.8);
      expect(r.icm, closeTo(94.2, 0.01));
    });

    test('jornada >4h sin infracciones → ICM 85 por fatiga', () {
      final r = calcularIcmJornada([], [4.5 * 3600]);
      expect(r.puntosFatiga, 15);
      expect(r.icm, 85);
    });

    test('mezcla CESVI completa (sobrevelocidad >10s rural)', () {
      // 2 frenadas (-11.6) + 1 acel (-2.8) + 3 giros (-8.4)
      // + 1 sobrevelocidad rural 12s (-1) + bloque >4h (-15) = -38.8 → ICM 61.2
      final r = calcularIcmJornada([
        ev(id: 67, ts: 1000, speed: 60, limit: 80, area: 'urban'),
        ev(id: 67, ts: 2000, speed: 50, limit: 80, area: 'urban'),
        ev(id: 66, ts: 3000, speed: 40, limit: 80, area: 'urban'),
        ev(id: 383, ts: 4000, speed: 30, limit: 80, area: 'urban'),
        ev(id: 383, ts: 5000, speed: 30, limit: 80, area: 'urban'),
        ev(id: 383, ts: 6000, speed: 30, limit: 80, area: 'urban'),
        // Sobrevelocidad rural 102 sobre 100 (baja), 12s (supera 10s) → -1
        ev(id: 8, ts: 10000, speed: 102, limit: 100, area: 'rural'),
        ev(id: 9, ts: 22000, speed: 101, limit: 100, area: 'rural'),
      ], [4.5 * 3600]);
      expect(r.frenadasBruscas, 2);
      expect(r.aceleracionesBruscas, 1);
      expect(r.girosBruscos, 3);
      expect(r.sobrevelocidades, 1);
      expect(r.puntosTotales, closeTo(38.8, 0.01));
      expect(r.icm, closeTo(61.2, 0.01));
      // 61.2 < 71 → ALTO con umbrales YPF (antes era medio con 80/60).
      expect(r.categoria, CategoriaCesvi.alto);
    });

    test('infracciones extremas → ICM clampea a 0', () {
      final eventos = <EventoSitrackICM>[];
      for (var i = 0; i < 50; i++) {
        eventos.add(ev(id: 67, ts: 1000 + i, speed: 50, limit: 80, area: 'urban'));
      }
      final r = calcularIcmJornada(eventos, [3600]);
      expect(r.icm, 0);
      expect(r.categoria, CategoriaCesvi.alto);
    });
  });

  group('combinarJornadas (promedio ponderado por km)', () {
    const desgloseVacio = DesgloseIcm(
      icm: 100, categoria: CategoriaCesvi.bajo, puntosTotales: 0,
      aceleracionesBruscas: 0, frenadasBruscas: 0, girosBruscos: 0,
      sobrevelocidades: 0,
      puntosAceleracion: 0, puntosFrenada: 0, puntosGiro: 0,
      puntosSobrevelocidad: 0, puntosFatiga: 0,
    );

    test('1 jornada → ICM = ICM de la jornada', () {
      final r = combinarJornadas([
        const JornadaConIcm(icm: 85, km: 200, desglose: desgloseVacio),
      ]);
      expect(r.icm, 85);
      expect(r.kmTotales, 200);
      expect(r.jornadas, 1);
    });

    test('1000km @ 90 + 100km @ 50 → ponderado 86.36', () {
      // (90*1000 + 50*100) / 1100 = 86.36
      final r = combinarJornadas([
        const JornadaConIcm(icm: 90, km: 1000, desglose: desgloseVacio),
        const JornadaConIcm(icm: 50, km: 100, desglose: desgloseVacio),
      ]);
      expect(r.icm, closeTo(86.36, 0.1));
      expect(r.kmTotales, 1100);
    });

    test('lista vacía → SIN_DATOS', () {
      final r = combinarJornadas([]);
      expect(r.icm, 0);
      expect(r.categoria, CategoriaCesvi.sinDatos);
    });

    test('todas con km=0 → promedio simple (peso=max(km,1)), NO SIN_DATOS', () {
      // Antes devolvía SIN_DATOS y escondía choferes con infracciones
      // reales sin odómetro. Ahora pesa 1 cada día → promedio simple.
      final r = combinarJornadas([
        const JornadaConIcm(icm: 80, km: 0, desglose: desgloseVacio),
        const JornadaConIcm(icm: 60, km: 0, desglose: desgloseVacio),
      ]);
      expect(r.icm, 70); // (80+60)/2
      expect(r.kmTotales, 0); // km real reportado sigue siendo 0
      expect(r.categoria, CategoriaCesvi.alto);
    });

    test('día con km domina; día con infracción sin km NO se pierde', () {
      // 600km @ 100 (limpio) + 0km @ 40 (infracción sin odómetro):
      // pesos 600 y 1 → (100*600 + 40*1)/601 = 99.9.
      final r = combinarJornadas([
        const JornadaConIcm(icm: 100, km: 600, desglose: desgloseVacio),
        const JornadaConIcm(icm: 40, km: 0, desglose: desgloseVacio),
      ]);
      expect(r.icm, closeTo(99.9, 0.05));
      expect(r.kmTotales, 600);
    });

    test('suma totales across jornadas', () {
      final r = combinarJornadas([
        const JornadaConIcm(
          icm: 90, km: 100,
          desglose: DesgloseIcm(
            icm: 90, categoria: CategoriaCesvi.bajo, puntosTotales: 11.6,
            aceleracionesBruscas: 0, frenadasBruscas: 2, girosBruscos: 0,
            sobrevelocidades: 0,
            puntosAceleracion: 0, puntosFrenada: 11.6, puntosGiro: 0,
            puntosSobrevelocidad: 0, puntosFatiga: 0,
          ),
        ),
        const JornadaConIcm(
          icm: 80, km: 100,
          desglose: DesgloseIcm(
            icm: 80, categoria: CategoriaCesvi.bajo, puntosTotales: 5.8,
            aceleracionesBruscas: 0, frenadasBruscas: 1, girosBruscos: 0,
            sobrevelocidades: 0,
            puntosAceleracion: 0, puntosFrenada: 5.8, puntosGiro: 0,
            puntosSobrevelocidad: 0, puntosFatiga: 0,
          ),
        ),
      ]);
      expect(r.totalFrenadas, 3);
    });
  });
}
