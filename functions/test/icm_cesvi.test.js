// Tests para helpers PUROS del cálculo CESVI del ICM.
//
// Strategy: igual que otros tests — testear los helpers compilados
// (lib/icm_cesvi.js). El script `npm test` corre `npm run build` antes.
//
// La fórmula CESVI viene de la presentación Carsync homologada que vive
// en `G:/Mi unidad/REQUERIMIENTOS YPF/Presentación Avance Carsync...`.
// Los casos de test verifican que cada función pura aplica la fórmula
// exacta.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  PESO_CESVI,
  EVENT_ID,
  gravedadExceso,
  puntajeSobrevelocidad,
  puntajeFatigaPorBloque,
  categorizar,
  agruparSobrevelocidades,
  calcularIcmJornada,
  combinarJornadas,
} = require('../lib/icm_cesvi');

describe('PESO_CESVI (constantes del slide 3 Carsync)', () => {
  test('Aceleración brusca = 2.8', () => {
    assert.strictEqual(PESO_CESVI.ACELERACION_BRUSCA, 2.8);
  });
  test('Frenada brusca = 5.8 (el más severo)', () => {
    assert.strictEqual(PESO_CESVI.FRENADA_BRUSCA, 5.8);
  });
  test('Giro brusco = 2.8 (igual que aceleración)', () => {
    assert.strictEqual(PESO_CESVI.GIRO_BRUSCO, 2.8);
  });
});

describe('gravedadExceso (clasificación urban/rural)', () => {
  test('velMax ≤ límite → null (no es exceso)', () => {
    assert.strictEqual(gravedadExceso(100, 110, 'rural'), null);
    assert.strictEqual(gravedadExceso(110, 110, 'rural'), null);
  });

  test('límite 0 (sin cartografía) → null', () => {
    assert.strictEqual(gravedadExceso(100, 0, 'rural'), null);
  });

  test('rural: 105 sobre 100 (5% exceso) → media (umbral 3-6%)', () => {
    assert.strictEqual(gravedadExceso(105, 100, 'rural'), 'media');
  });

  test('rural: 102 sobre 100 (2% exceso) → baja', () => {
    assert.strictEqual(gravedadExceso(102, 100, 'rural'), 'baja');
  });

  test('rural: 110 sobre 100 (10% exceso) → alta (>6%)', () => {
    assert.strictEqual(gravedadExceso(110, 100, 'rural'), 'alta');
  });

  test('urban: 105 sobre 100 (5% exceso) → media (umbral 5-10%)', () => {
    assert.strictEqual(gravedadExceso(105, 100, 'urban'), 'media');
  });

  test('urban: 103 sobre 100 (3% exceso) → baja', () => {
    assert.strictEqual(gravedadExceso(103, 100, 'urban'), 'baja');
  });

  test('urban: 115 sobre 100 (15% exceso) → alta (>10%)', () => {
    assert.strictEqual(gravedadExceso(115, 100, 'urban'), 'alta');
  });

  test('unknown: trata como rural (operación Vecchi mayoría ruta)', () => {
    assert.strictEqual(gravedadExceso(110, 100, 'unknown'), 'alta');
    assert.strictEqual(gravedadExceso(105, 100, 'unknown'), 'media');
  });
});

describe('puntajeSobrevelocidad (fórmula slide 11)', () => {
  test('sin gravedad → 0 puntos', () => {
    assert.strictEqual(
      puntajeSobrevelocidad({
        gravedad: null,
        velMaxKmh: 90,
        velPromKmh: 85,
        duracionSeg: 30,
      }),
      0,
    );
  });

  test('gravedad baja → 1 punto fijo', () => {
    assert.strictEqual(
      puntajeSobrevelocidad({
        gravedad: 'baja',
        velMaxKmh: 105,
        velPromKmh: 102,
        duracionSeg: 30,
      }),
      1,
    );
  });

  test('gravedad media: (max-prom)*dur*0.01 con clamp [1.1, 1.4]', () => {
    // 110-105 = 5; *9s*0.01 = 0.45 → clampea a 1.1
    assert.strictEqual(
      puntajeSobrevelocidad({
        gravedad: 'media',
        velMaxKmh: 110,
        velPromKmh: 105,
        duracionSeg: 9,
      }),
      1.1,
    );
    // 120-105 = 15; *20s*0.01 = 3 → clampea a 1.4
    assert.strictEqual(
      puntajeSobrevelocidad({
        gravedad: 'media',
        velMaxKmh: 120,
        velPromKmh: 105,
        duracionSeg: 20,
      }),
      1.4,
    );
    // 120-100 = 20; *6s*0.01 = 1.2 → dentro de rango, devuelve 1.2
    assert.strictEqual(
      puntajeSobrevelocidad({
        gravedad: 'media',
        velMaxKmh: 120,
        velPromKmh: 100,
        duracionSeg: 6,
      }),
      1.2,
    );
  });

  test('gravedad alta: misma fórmula con clamp [1.5, 5]', () => {
    // ejemplo del slide 12: (50.52-40)*9*0.01 = 0.9468 → clampea a 1.5
    assert.strictEqual(
      puntajeSobrevelocidad({
        gravedad: 'alta',
        velMaxKmh: 55.75,
        velPromKmh: 50.52,
        duracionSeg: 9,
      }),
      1.5,
    );
    // 120-100 = 20; *30s*0.01 = 6 → clampea a 5
    assert.strictEqual(
      puntajeSobrevelocidad({
        gravedad: 'alta',
        velMaxKmh: 120,
        velPromKmh: 100,
        duracionSeg: 30,
      }),
      5,
    );
    // 120-100 = 20; *15s*0.01 = 3 → dentro de rango [1.5, 5]
    assert.strictEqual(
      puntajeSobrevelocidad({
        gravedad: 'alta',
        velMaxKmh: 120,
        velPromKmh: 100,
        duracionSeg: 15,
      }),
      3,
    );
  });
});

describe('puntajeFatigaPorBloque (escalera slide 3)', () => {
  test('< 2h → 0 puntos', () => {
    assert.strictEqual(puntajeFatigaPorBloque(0), 0);
    assert.strictEqual(puntajeFatigaPorBloque(60 * 60), 0);
    assert.strictEqual(puntajeFatigaPorBloque(7000), 0); // ~1h57m
  });

  test('2h a 3h → 5 puntos', () => {
    assert.strictEqual(puntajeFatigaPorBloque(2 * 3600), 5);
    assert.strictEqual(puntajeFatigaPorBloque(2.5 * 3600), 5);
  });

  test('3h a 4h → 10 puntos', () => {
    assert.strictEqual(puntajeFatigaPorBloque(3 * 3600), 10);
    assert.strictEqual(puntajeFatigaPorBloque(3.5 * 3600), 10);
  });

  test('> 4h → 15 puntos', () => {
    assert.strictEqual(puntajeFatigaPorBloque(4 * 3600), 15);
    assert.strictEqual(puntajeFatigaPorBloque(6 * 3600), 15);
  });
});

describe('tiempo de activación (slide 6) — filtro de infracción CESVI', () => {
  test('URBAN → 6s mínimo', () => {
    // Sobrevelocidad urban de 5s → no infracción
    const r1 = calcularIcmJornada([
      { eventId: 8, reportDateMs: 0, assetId: 'A', driverDni: '1',
        speed: 110, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null },
      { eventId: 9, reportDateMs: 5000, assetId: 'A', driverDni: '1',
        speed: 105, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null },
    ], [0]);
    assert.strictEqual(r1.desglose.sobrevelocidades, 0);
    assert.strictEqual(r1.icm, 100);
    // Sobrevelocidad urban de 7s → SÍ infracción (>6s)
    const r2 = calcularIcmJornada([
      { eventId: 8, reportDateMs: 0, assetId: 'A', driverDni: '1',
        speed: 110, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null },
      { eventId: 9, reportDateMs: 7000, assetId: 'A', driverDni: '1',
        speed: 105, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null },
    ], [0]);
    assert.strictEqual(r2.desglose.sobrevelocidades, 1);
    assert.ok(r2.icm < 100);
  });

  test('RURAL → 10s mínimo', () => {
    // Sobrevelocidad rural de 9s → no infracción
    const r1 = calcularIcmJornada([
      { eventId: 8, reportDateMs: 0, assetId: 'A', driverDni: '1',
        speed: 120, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
      { eventId: 9, reportDateMs: 9000, assetId: 'A', driverDni: '1',
        speed: 115, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
    ], [0]);
    assert.strictEqual(r1.desglose.sobrevelocidades, 0);
    // Sobrevelocidad rural de 11s → SÍ infracción
    const r2 = calcularIcmJornada([
      { eventId: 8, reportDateMs: 0, assetId: 'A', driverDni: '1',
        speed: 120, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
      { eventId: 9, reportDateMs: 11000, assetId: 'A', driverDni: '1',
        speed: 115, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
    ], [0]);
    assert.strictEqual(r2.desglose.sobrevelocidades, 1);
  });

  test('UNKNOWN tratado como rural (10s)', () => {
    const r = calcularIcmJornada([
      { eventId: 8, reportDateMs: 0, assetId: 'A', driverDni: '1',
        speed: 120, cartographyLimitSpeed: 100, areaType: 'unknown', odometer: null },
      { eventId: 9, reportDateMs: 8000, assetId: 'A', driverDni: '1',
        speed: 115, cartographyLimitSpeed: 100, areaType: 'unknown', odometer: null },
    ], [0]);
    assert.strictEqual(r.desglose.sobrevelocidades, 0);
  });

  test('par sin cartografía (límite 0) → no infracción (sin gravedad)', () => {
    // El par dura >10s pero límite=0 → no podemos calcular gravedad → skip
    const r = calcularIcmJornada([
      { eventId: 8, reportDateMs: 0, assetId: 'A', driverDni: '1',
        speed: 120, cartographyLimitSpeed: 0, areaType: 'rural', odometer: null },
      { eventId: 9, reportDateMs: 30000, assetId: 'A', driverDni: '1',
        speed: 115, cartographyLimitSpeed: 0, areaType: 'rural', odometer: null },
    ], [0]);
    assert.strictEqual(r.desglose.sobrevelocidades, 0);
  });
});

describe('categorizar (umbrales YPF 91/71)', () => {
  test('ICM ≥ 91 → BAJO (verde)', () => {
    assert.strictEqual(categorizar(91), 'BAJO');
    assert.strictEqual(categorizar(95), 'BAJO');
    assert.strictEqual(categorizar(100), 'BAJO');
  });
  test('71 ≤ ICM < 91 → MEDIO (amarillo)', () => {
    assert.strictEqual(categorizar(71), 'MEDIO');
    assert.strictEqual(categorizar(79), 'MEDIO');
    assert.strictEqual(categorizar(90.99), 'MEDIO');
  });
  test('ICM < 71 → ALTO (rojo)', () => {
    assert.strictEqual(categorizar(0), 'ALTO');
    assert.strictEqual(categorizar(70.99), 'ALTO');
  });
});

describe('agruparSobrevelocidades (pareo 8+9)', () => {
  test('inicio + fin contiguos → 1 par', () => {
    const eventos = [
      { eventId: 8, reportDateMs: 1000, assetId: 'AB1', driverDni: '111',
        speed: 110, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
      { eventId: 9, reportDateMs: 30000, assetId: 'AB1', driverDni: '111',
        speed: 105, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
    ];
    const pares = agruparSobrevelocidades(eventos);
    assert.strictEqual(pares.length, 1);
    assert.strictEqual(pares[0].duracionSeg, 29);
  });

  test('inicio sin fin → descartado', () => {
    const eventos = [
      { eventId: 8, reportDateMs: 1000, assetId: 'AB1', driverDni: '111',
        speed: 110, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
    ];
    assert.strictEqual(agruparSobrevelocidades(eventos).length, 0);
  });

  test('fin sin inicio previo → descartado', () => {
    const eventos = [
      { eventId: 9, reportDateMs: 1000, assetId: 'AB1', driverDni: '111',
        speed: 105, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
    ];
    assert.strictEqual(agruparSobrevelocidades(eventos).length, 0);
  });

  test('par fuera de ventana 30min → descartado', () => {
    const eventos = [
      { eventId: 8, reportDateMs: 1000, assetId: 'AB1', driverDni: '111',
        speed: 110, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
      { eventId: 9, reportDateMs: 1000 + 31 * 60 * 1000, assetId: 'AB1',
        driverDni: '111', speed: 105, cartographyLimitSpeed: 100,
        areaType: 'rural', odometer: null },
    ];
    assert.strictEqual(agruparSobrevelocidades(eventos).length, 0);
  });

  test('2 pares en orden → 2 pares (no se cruzan)', () => {
    const eventos = [
      { eventId: 8, reportDateMs: 1000, assetId: 'AB1', driverDni: '111',
        speed: 110, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
      { eventId: 9, reportDateMs: 10000, assetId: 'AB1', driverDni: '111',
        speed: 105, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
      { eventId: 8, reportDateMs: 50000, assetId: 'AB1', driverDni: '111',
        speed: 115, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
      { eventId: 9, reportDateMs: 80000, assetId: 'AB1', driverDni: '111',
        speed: 108, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
    ];
    const pares = agruparSobrevelocidades(eventos);
    assert.strictEqual(pares.length, 2);
    assert.strictEqual(pares[0].duracionSeg, 9);
    assert.strictEqual(pares[1].duracionSeg, 30);
  });

  test('eventos de DIFERENTES choferes/patentes NO se cruzan', () => {
    const eventos = [
      { eventId: 8, reportDateMs: 1000, assetId: 'AB1', driverDni: '111',
        speed: 110, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
      { eventId: 9, reportDateMs: 10000, assetId: 'AB1', driverDni: '222',
        speed: 105, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
    ];
    assert.strictEqual(agruparSobrevelocidades(eventos).length, 0);
  });
});

describe('calcularIcmJornada (integración fórmula completa)', () => {
  test('jornada sin eventos y < 2h → ICM 100', () => {
    const r = calcularIcmJornada([], [3600]); // 1 bloque de 1h
    assert.strictEqual(r.icm, 100);
    assert.strictEqual(r.categoria, 'BAJO');
    assert.strictEqual(r.puntosTotales, 0);
  });

  test('1 frenada brusca → −5.8 → ICM 94.2', () => {
    const r = calcularIcmJornada([
      { eventId: 67, reportDateMs: 1000, assetId: 'AB1', driverDni: '111',
        speed: 50, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null },
    ], [3600]);
    assert.strictEqual(r.desglose.frenadasBruscas, 1);
    assert.strictEqual(r.desglose.puntosFrenada, 5.8);
    assert.ok(Math.abs(r.icm - 94.2) < 0.01);
  });

  test('jornada larga (>4h) sin infracciones → −15 fatiga → ICM 85', () => {
    const r = calcularIcmJornada([], [4.5 * 3600]);
    assert.strictEqual(r.desglose.puntosFatiga, 15);
    assert.strictEqual(r.icm, 85);
    // 85 < 91 → MEDIO con umbrales YPF (antes era BAJO con 80/60).
    assert.strictEqual(r.categoria, 'MEDIO');
  });

  test('mezcla CESVI completa (sobrevelocidad supera tiempo activación)', () => {
    // 2 frenadas (-5.8×2 = -11.6) + 1 acel (-2.8) + 3 giros (-2.8×3 = -8.4)
    // + 1 sobrevelocidad rural >10s (-1) + bloque >4h (-15)
    // = -38.8 → ICM 61.2 → MEDIO
    const r = calcularIcmJornada([
      { eventId: 67, reportDateMs: 1000, assetId: 'AB1', driverDni: '111',
        speed: 60, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null },
      { eventId: 67, reportDateMs: 2000, assetId: 'AB1', driverDni: '111',
        speed: 50, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null },
      { eventId: 66, reportDateMs: 3000, assetId: 'AB1', driverDni: '111',
        speed: 40, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null },
      { eventId: 383, reportDateMs: 4000, assetId: 'AB1', driverDni: '111',
        speed: 30, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null },
      { eventId: 383, reportDateMs: 5000, assetId: 'AB1', driverDni: '111',
        speed: 30, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null },
      { eventId: 383, reportDateMs: 6000, assetId: 'AB1', driverDni: '111',
        speed: 30, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null },
      // Sobrevelocidad rural baja 102 sobre 100, duración 12s (>10s) → -1
      { eventId: 8, reportDateMs: 10000, assetId: 'AB1', driverDni: '111',
        speed: 102, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
      { eventId: 9, reportDateMs: 22000, assetId: 'AB1', driverDni: '111',
        speed: 101, cartographyLimitSpeed: 100, areaType: 'rural', odometer: null },
    ], [4.5 * 3600]);
    assert.strictEqual(r.desglose.frenadasBruscas, 2);
    assert.strictEqual(r.desglose.aceleracionesBruscas, 1);
    assert.strictEqual(r.desglose.girosBruscos, 3);
    assert.strictEqual(r.desglose.sobrevelocidades, 1);
    assert.ok(Math.abs(r.puntosTotales - 38.8) < 0.01);
    assert.ok(Math.abs(r.icm - 61.2) < 0.01);
    // 61.2 < 71 → ALTO con umbrales YPF (antes era MEDIO con 80/60).
    assert.strictEqual(r.categoria, 'ALTO');
  });

  test('infracciones extremas → ICM clampea a 0 (no negativo)', () => {
    const eventos = [];
    for (let i = 0; i < 50; i++) {
      eventos.push({
        eventId: 67, reportDateMs: 1000 + i, assetId: 'AB1', driverDni: '111',
        speed: 50, cartographyLimitSpeed: 80, areaType: 'urban', odometer: null,
      });
    }
    const r = calcularIcmJornada(eventos, [3600]);
    assert.strictEqual(r.icm, 0);
    assert.strictEqual(r.categoria, 'ALTO');
  });
});

describe('combinarJornadas (promedio ponderado por km)', () => {
  const desgloseVacio = {
    aceleracionesBruscas: 0, frenadasBruscas: 0, girosBruscos: 0,
    sobrevelocidades: 0,
    puntosAceleracion: 0, puntosFrenada: 0, puntosGiro: 0,
    puntosSobrevelocidad: 0, puntosFatiga: 0,
  };

  test('1 jornada → ICM = ICM de la jornada', () => {
    const r = combinarJornadas([{ icm: 85, km: 200, desglose: desgloseVacio }]);
    assert.strictEqual(r.icm, 85);
    assert.strictEqual(r.kmTotales, 200);
    assert.strictEqual(r.jornadas, 1);
  });

  test('jornada 1000km @ ICM 90 + jornada 100km @ ICM 50 → promedio ponderado', () => {
    // (90 * 1000 + 50 * 100) / 1100 = (90000 + 5000) / 1100 = 86.36
    const r = combinarJornadas([
      { icm: 90, km: 1000, desglose: desgloseVacio },
      { icm: 50, km: 100, desglose: desgloseVacio },
    ]);
    assert.ok(Math.abs(r.icm - 86.36) < 0.1);
    assert.strictEqual(r.kmTotales, 1100);
  });

  test('lista vacía → SIN_DATOS', () => {
    const r = combinarJornadas([]);
    assert.strictEqual(r.icm, 0);
    assert.strictEqual(r.categoria, 'SIN_DATOS');
  });

  test('todos km=0 → promedio simple (peso=max(km,1)), NO SIN_DATOS', () => {
    // Antes devolvía SIN_DATOS y escondía choferes con infracciones
    // reales sin odómetro. Ahora pesa 1 cada día → promedio simple.
    const r = combinarJornadas([
      { icm: 80, km: 0, desglose: desgloseVacio },
      { icm: 60, km: 0, desglose: desgloseVacio },
    ]);
    assert.strictEqual(r.icm, 70); // (80+60)/2
    assert.strictEqual(r.kmTotales, 0);
    assert.strictEqual(r.categoria, 'ALTO');
  });

  test('día con km domina; día con infracción sin km NO se pierde', () => {
    // 600km @ 100 + 0km @ 40 → pesos 600 y 1 → (100*600+40)/601 ≈ 99.9
    const r = combinarJornadas([
      { icm: 100, km: 600, desglose: desgloseVacio },
      { icm: 40, km: 0, desglose: desgloseVacio },
    ]);
    assert.ok(Math.abs(r.icm - 99.9) < 0.05);
    assert.strictEqual(r.kmTotales, 600);
  });

  test('suma desgloses across jornadas', () => {
    const r = combinarJornadas([
      { icm: 90, km: 100, desglose: { ...desgloseVacio, frenadasBruscas: 2,
        puntosFrenada: 11.6 } },
      { icm: 80, km: 100, desglose: { ...desgloseVacio, frenadasBruscas: 1,
        puntosFrenada: 5.8 } },
    ]);
    assert.strictEqual(r.desgloseSumado.frenadasBruscas, 3);
    assert.ok(Math.abs(r.desgloseSumado.puntosFrenada - 17.4) < 0.01);
  });
});
