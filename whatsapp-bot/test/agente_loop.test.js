// Tests del LOOP de tool-use del agente — dedup de escrituras por turno (P0.4)
// y que el retry `sin_texto` NO duplica una tool de ACCIÓN (P0.1). Mockea
// `fetch` (Gemini) con una cola de respuestas y captura las escrituras. Acá
// vive la plata: estos caminos no tenían cobertura antes del hardening.

const { test, describe, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert');
const agente = require('../src/agente');

const _fetchOrig = global.fetch;
beforeEach(() => { process.env.GEMINI_API_KEY = 'test-key'; });
afterEach(() => { global.fetch = _fetchOrig; });

// Cola de respuestas Gemini; la última se repite si se agota.
function mockFetch(respuestas) {
  let i = 0;
  global.fetch = async () => {
    const r = respuestas[Math.min(i++, respuestas.length - 1)];
    return { ok: true, async json() { return r; }, async text() { return ''; } };
  };
}
const fcResp = (calls) => ({
  candidates: [{
    content: { parts: calls.map((c) => ({ functionCall: c })) },
    finishReason: 'STOP',
  }],
});
const txtResp = (t) => ({
  candidates: [{ content: { parts: [{ text: t }] }, finishReason: 'STOP' }],
});
const vacioResp = () => ({
  candidates: [{ content: { parts: [] }, finishReason: 'STOP' }],
});

function dbMockCaptura() {
  const escrituras = [];
  return {
    _escrituras: escrituras,
    collection(name) {
      return {
        doc() {
          return {
            id: 'auto',
            async set(data) { escrituras.push({ col: name, data }); },
          };
        },
      };
    },
  };
}
const parad = (db) => db._escrituras.filter((e) => e.col === 'PARADAS_REPORTADAS');
const CHOFER = { rol: 'CHOFER', dni: '30111222', data: { NOMBRE: 'JUAN' } };

describe('agente._conversarGemini — dedup de escrituras por turno (P0.4)', () => {
  test('dos registrar_parada_reportada IDÉNTICOS en un turno → UNA escritura', async () => {
    mockFetch([
      fcResp([
        { name: 'registrar_parada_reportada', args: { hora_inicio: '14:00', hora_fin: '16:00' } },
        { name: 'registrar_parada_reportada', args: { hora_inicio: '14:00', hora_fin: '16:00' } },
      ]),
      txtResp('Listo, anoté tu parada.'),
    ]);
    const db = dbMockCaptura();
    const r = await agente._conversarGemini(db, 'sys', [], 'paré de 14 a 16', CHOFER);
    assert.strictEqual(parad(db).length, 1, 'la 2da llamada idéntica NO debe re-escribir');
    assert.ok(r.texto && r.texto.toLowerCase().includes('anot'));
  });

  test('dos paradas DISTINTAS en un turno → DOS escrituras (no se deduplican)', async () => {
    mockFetch([
      fcResp([
        { name: 'registrar_parada_reportada', args: { hora_inicio: '14:00' } },
        { name: 'registrar_parada_reportada', args: { hora_inicio: '18:00' } },
      ]),
      txtResp('Anoté las dos.'),
    ]);
    const db = dbMockCaptura();
    await agente._conversarGemini(db, 'sys', [], 'paré 14 y 18', CHOFER);
    assert.strictEqual(parad(db).length, 2);
  });
});

describe('agente._conversarRobusto — el retry sin_texto NO duplica una acción (P0.1)', () => {
  test('tool de ACCIÓN + sin_texto → no reintenta (huboToolDeAccion), 1 escritura', async () => {
    mockFetch([
      fcResp([{ name: 'registrar_parada_reportada', args: { hora_inicio: '14:00' } }]),
      vacioResp(), // STOP sin texto tras ejecutar la tool → sin_texto
      vacioResp(), // si reintentara (NO debe), re-ejecutaría → 2da escritura
    ]);
    const db = dbMockCaptura();
    const r = await agente._conversarRobusto('gemini', db, 'sys', [], 'paré 14', CHOFER);
    assert.strictEqual(parad(db).length, 1, 'el retry sin_texto NO debe re-ejecutar la escritura');
    assert.ok(r.huboToolDeAccion, 'registrar_parada está en TOOLS_DE_ACCION → marca huboToolDeAccion');
  });
});

describe('agente._conversarGemini — thinkingConfig en el request (regresión sin_texto 2026-06-11)', () => {
  test('el body a Gemini apaga el thinking (thinkingBudget=0)', async () => {
    // Por qué este test: con el thinking ON (default de gemini-2.5-flash) el
    // modelo devuelve candidato VACÍO ante consultas que requieren decidir una
    // tool (jornada/turnos) — medido 40/40 vacío. Si un refactor borra el
    // thinkingConfig del body, el bot vuelve a fallar al 100% en esas consultas
    // SIN romper ningún otro test. Este lo detecta.
    const bodies = [];
    global.fetch = async (_url, opts) => {
      bodies.push(JSON.parse(opts.body));
      return { ok: true, async json() { return txtResp('hola'); }, async text() { return ''; } };
    };
    await agente._conversarGemini(dbMockCaptura(), 'sys', [], 'hola', CHOFER);
    assert.ok(bodies.length >= 1, 'debió llamar a Gemini al menos una vez');
    assert.deepStrictEqual(
      bodies[0].generationConfig && bodies[0].generationConfig.thinkingConfig,
      { thinkingBudget: 0 },
      'el thinking debe ir apagado (budget 0) — si esto falla, vuelve el sin_texto en jornada/turnos'
    );
  });
});
