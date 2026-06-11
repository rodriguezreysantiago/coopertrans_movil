// Tests de destinatarios.js — decide a QUIÉN va cada resumen/alerta (override
// Firestore vs fallback env). Un bug acá = resumen al destinatario equivocado.
// Sin cobertura previa (auditoría 2026-06-11).

const { test, describe, beforeEach } = require('node:test');
const assert = require('node:assert');
const destinatarios = require('../src/destinatarios');

function dbMock(data, { fallar = false } = {}) {
  return {
    collection() {
      return {
        doc() {
          return {
            async get() {
              if (fallar) throw new Error('firestore caído (test)');
              return { exists: data !== null, data: () => data };
            },
          };
        },
      };
    },
  };
}

describe('destinatarios.obtenerDestinatario', () => {
  beforeEach(() => destinatarios.invalidarCache());

  test('override válido en Firestore → devuelve el override (no el fallback)', async () => {
    destinatarios._setDbParaTests(dbMock({ serviceDiario: '34730329' }));
    const r = await destinatarios.obtenerDestinatario('serviceDiario', 'FALLBACK');
    assert.strictEqual(r, '34730329');
  });

  test('sin override para la key → fallback', async () => {
    destinatarios._setDbParaTests(dbMock({ otraKey: '111' }));
    const r = await destinatarios.obtenerDestinatario('serviceDiario', 'FALLBACK');
    assert.strictEqual(r, 'FALLBACK');
  });

  test('override vacío/whitespace → fallback (no manda a "")', async () => {
    destinatarios._setDbParaTests(dbMock({ serviceDiario: '   ' }));
    const r = await destinatarios.obtenerDestinatario('serviceDiario', 'FALLBACK');
    assert.strictEqual(r, 'FALLBACK');
  });

  test('override con espacios → se trimea', async () => {
    destinatarios._setDbParaTests(dbMock({ serviceDiario: '  34730329  ' }));
    const r = await destinatarios.obtenerDestinatario('serviceDiario', 'FALLBACK');
    assert.strictEqual(r, '34730329');
  });

  test('doc no existe → fallback', async () => {
    destinatarios._setDbParaTests(dbMock(null));
    const r = await destinatarios.obtenerDestinatario('serviceDiario', 'FALLBACK');
    assert.strictEqual(r, 'FALLBACK');
  });

  test('Firestore falla → fallback (un outage no rompe el cron ni redirige)', async () => {
    destinatarios._setDbParaTests(dbMock({}, { fallar: true }));
    const r = await destinatarios.obtenerDestinatario('serviceDiario', 'FALLBACK');
    assert.strictEqual(r, 'FALLBACK');
  });
});
