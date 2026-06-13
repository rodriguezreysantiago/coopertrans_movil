// Tests del censo mensual de colecciones (censo_colecciones.ts). Lógica
// PURA: comparación mes a mes (nuevas + crecimientos >umbral con piso de
// 500 docs), armado del mensaje y la key del mes anterior en ART.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  compararCensos,
  construirMensajeCenso,
  mesKeyAnteriorArt,
  UMBRAL_CRECIMIENTO_PCT,
} = require('../lib/censo_colecciones');

describe('compararCensos', () => {
  test('primer censo (sin anterior): solo totales, sin novedades', () => {
    const d = compararCensos({ A: 100, B: 200 }, null);
    assert.strictEqual(d.totalDocs, 300);
    assert.strictEqual(d.totalColecciones, 2);
    assert.deepStrictEqual(d.nuevas, []);
    assert.deepStrictEqual(d.crecimientos, []);
  });

  test('colección nueva → reportada (ordenada por tamaño)', () => {
    const d = compararCensos(
      { A: 100, NUEVA_GRANDE: 5000, NUEVA_CHICA: 10 },
      { A: 100 },
    );
    assert.deepStrictEqual(d.nuevas.map((n) => n.id),
      ['NUEVA_GRANDE', 'NUEVA_CHICA']);
  });

  test('crecimiento sobre el umbral → reportado con %', () => {
    const d = compararCensos({ EVENTOS: 1500 }, { EVENTOS: 1000 });
    assert.strictEqual(d.crecimientos.length, 1);
    assert.strictEqual(d.crecimientos[0].pct, 50);
  });

  test('crecimiento bajo el umbral → silencio', () => {
    const d = compararCensos({ EVENTOS: 1300 }, { EVENTOS: 1000 });
    assert.deepStrictEqual(d.crecimientos, []);
  });

  test('piso de 500 docs: un contador chico que se duplica NO es señal', () => {
    const d = compararCensos({ COUNTERS: 20 }, { COUNTERS: 10 });
    assert.deepStrictEqual(d.crecimientos, []);
  });

  test('disparador ABSOLUTO: colección chica que EXPLOTA 10x a >2000 alerta', () => {
    // 100 → 3000 (30x): el piso relativo de 500 no la agarra (antes<500),
    // pero el absoluto sí (poller en loop sobre una colección nueva).
    const d = compararCensos({ EVENTOS_X: 3000 }, { EVENTOS_X: 100 });
    assert.strictEqual(d.crecimientos.length, 1);
    assert.strictEqual(d.crecimientos[0].id, 'EVENTOS_X');
  });

  test('explosión relativa pero todavía chica (<2000) NO dispara el absoluto', () => {
    // 50 → 600 (12x) pero 600<2000 y 50<500 → ninguno de los dos triggers.
    const d = compararCensos({ CHICA: 600 }, { CHICA: 50 });
    assert.deepStrictEqual(d.crecimientos, []);
  });

  test('crecimientos ordenados por % descendente', () => {
    const d = compararCensos(
      { A: 2000, B: 3000 },
      { A: 1000, B: 2000 },
    );
    assert.deepStrictEqual(d.crecimientos.map((c) => c.id), ['A', 'B']);
  });
});

describe('construirMensajeCenso', () => {
  test('sin novedades → "crecimiento normal"', () => {
    const actual = { A: 100, B: 50 };
    const msg = construirMensajeCenso('2026-06', actual,
      compararCensos(actual, { A: 100, B: 50 }));
    assert.match(msg, /Censo Firestore — 2026-06/);
    assert.match(msg, /2 colecciones · 150 docs/);
    assert.match(msg, /Sin novedades/);
  });

  test('con anomalías → secciones de crecimiento y nuevas', () => {
    const actual = { EVENTOS: 2000, NUEVA: 300 };
    const msg = construirMensajeCenso('2026-06', actual,
      compararCensos(actual, { EVENTOS: 1000 }));
    assert.match(msg, /Crecimiento fuerte/);
    assert.match(msg, /EVENTOS: 1\.000 → 2\.000 \(\+100%\)/);
    assert.match(msg, /Colecciones nuevas/);
    assert.match(msg, /NUEVA \(300 docs\)/);
  });

  test('el umbral exportado es 40 (documentado en el encabezado)', () => {
    assert.strictEqual(UMBRAL_CRECIMIENTO_PCT, 40);
  });
});

describe('mesKeyAnteriorArt', () => {
  test('corre el 1 de julio ART → retrata junio', () => {
    assert.strictEqual(
      mesKeyAnteriorArt(Date.parse('2026-07-01T03:30:00-03:00')),
      '2026-06');
  });

  test('cruce de año: 1 de enero → diciembre del año anterior', () => {
    assert.strictEqual(
      mesKeyAnteriorArt(Date.parse('2027-01-01T03:30:00-03:00')),
      '2026-12');
  });

  test('borde TZ: 1 de julio 01:00 ART (= 04:00 UTC del 1) sigue siendo junio', () => {
    assert.strictEqual(
      mesKeyAnteriorArt(Date.parse('2026-07-01T01:00:00-03:00')),
      '2026-06');
  });
});
