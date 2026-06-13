// Tests de la alerta de cola excedida en planta (detention en vivo).
// Lógica PURA de zonas_descarga.ts: detección por umbral con anti-spam
// POR EPISODIO de estadía (el mark guarda el entrada_ts alertado — una
// re-entrada posterior es episodio nuevo y vuelve a alertar) + el armado
// del mensaje consolidado.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  detectarColasExcedidas,
  construirMensajeColaExcedida,
  ALERTA_COLA_UMBRAL_DEFAULT_MIN,
} = require('../lib/zonas_descarga');

const MIN = 60 * 1000;
const AHORA = Date.parse('2026-06-12T15:00:00-03:00');

const unidad = (over = {}) => ({
  docId: 'AB123CD_necochea',
  patente: 'AB123CD',
  choferNombre: 'PEREZ JUAN',
  nombreZona: 'NECOCHEA DIETRICH',
  entradaMs: AHORA - 30 * MIN,
  alertaColaMs: null,
  ...over,
});

describe('detectarColasExcedidas', () => {
  test('bajo el umbral → no alerta', () => {
    const out = detectarColasExcedidas(AHORA, [
      unidad({ entradaMs: AHORA - 90 * MIN }),
    ], 120);
    assert.deepStrictEqual(out, []);
  });

  test('sobre el umbral y sin mark → alerta', () => {
    const out = detectarColasExcedidas(AHORA, [
      unidad({ entradaMs: AHORA - 121 * MIN }),
    ], 120);
    assert.strictEqual(out.length, 1);
    assert.strictEqual(out[0].patente, 'AB123CD');
  });

  test('ya alertada por ESTE episodio → silencio (anti-spam)', () => {
    const entrada = AHORA - 200 * MIN;
    const out = detectarColasExcedidas(AHORA, [
      unidad({ entradaMs: entrada, alertaColaMs: entrada }),
    ], 120);
    assert.deepStrictEqual(out, []);
  });

  test('mark de un episodio ANTERIOR (salió y volvió a entrar) → vuelve a alertar', () => {
    const entradaNueva = AHORA - 130 * MIN;
    const entradaVieja = AHORA - 600 * MIN;
    const out = detectarColasExcedidas(AHORA, [
      unidad({ entradaMs: entradaNueva, alertaColaMs: entradaVieja }),
    ], 120);
    assert.strictEqual(out.length, 1);
  });

  test('umbral configurable: 30 min agarra lo que 120 deja pasar', () => {
    const flota = [unidad({ entradaMs: AHORA - 45 * MIN })];
    assert.strictEqual(detectarColasExcedidas(AHORA, flota, 120).length, 0);
    assert.strictEqual(detectarColasExcedidas(AHORA, flota, 30).length, 1);
  });

  test('mezcla: solo las excedidas sin mark del episodio', () => {
    const e1 = AHORA - 180 * MIN; // excedida, sin mark → alerta
    const e2 = AHORA - 180 * MIN; // excedida, YA alertada → no
    const e3 = AHORA - 10 * MIN; //  recién entró → no
    const out = detectarColasExcedidas(AHORA, [
      unidad({ docId: 'a', patente: 'AAA111', entradaMs: e1 }),
      unidad({ docId: 'b', patente: 'BBB222', entradaMs: e2, alertaColaMs: e2 }),
      unidad({ docId: 'c', patente: 'CCC333', entradaMs: e3 }),
    ], 120);
    assert.deepStrictEqual(out.map((u) => u.patente), ['AAA111']);
  });
});

describe('construirMensajeColaExcedida', () => {
  test('una línea por unidad, con duración legible y hora de entrada ART', () => {
    const msg = construirMensajeColaExcedida([
      unidad({ entradaMs: AHORA - 135 * MIN }), // 2 h 15 min, entró 12:45
      unidad({
        patente: 'AC456EF', choferNombre: null,
        nombreZona: 'GALVAN', entradaMs: AHORA - 50 * MIN,
      }),
    ], AHORA, 120);
    assert.match(msg, /Cola excedida en planta/);
    assert.match(msg, /AB123CD \(PEREZ JUAN\) — 2 h 15 min en NECOCHEA DIETRICH \(entró 12:45\)/);
    // Sin chofer: sin paréntesis vacío.
    assert.match(msg, /AC456EF — 50 min en GALVAN/);
    assert.match(msg, /Umbral: 120 min/);
  });

  test('el default exportado es 120 (lo que documenta el README/config)', () => {
    assert.strictEqual(ALERTA_COLA_UMBRAL_DEFAULT_MIN, 120);
  });
});
