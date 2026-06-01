// Tests de la lógica PURA del agente conversacional (agente.js).
//
// NO llaman a la API de Anthropic (eso requiere API key + red). Cubren lo
// que SÍ se puede lockear sin la API: normalización de fechas, rate limit,
// armado del system prompt, extracción del texto de la respuesta, forma de
// las tools y ejecución de cada tool contra un Firestore mockeado.
//
// La pieza que NO se testea acá (la llamada HTTP a Anthropic) se valida en
// vivo cuando se carga la API key.
process.env.TZ = 'America/Argentina/Buenos_Aires';

const { test, describe } = require('node:test');
const assert = require('node:assert');
const agente = require('../src/agente');

describe('agente._fechaIso — normaliza a YYYY-MM-DD', () => {
  test('Timestamp de Firestore', () => {
    const ts = { toDate: () => new Date('2026-06-14T12:00:00Z') };
    assert.strictEqual(agente._fechaIso(ts), '2026-06-14');
  });
  test('string DD-MM-AAAA', () => {
    assert.strictEqual(agente._fechaIso('14-06-2026'), '2026-06-14');
  });
  test('string D/M/AAAA (sin ceros)', () => {
    assert.strictEqual(agente._fechaIso('5/3/2027'), '2027-03-05');
  });
  test('string YYYY-MM-DD se mantiene', () => {
    assert.strictEqual(agente._fechaIso('2026-12-01'), '2026-12-01');
  });
  test('vacío / null / basura → null', () => {
    assert.strictEqual(agente._fechaIso(''), null);
    assert.strictEqual(agente._fechaIso(null), null);
    assert.strictEqual(agente._fechaIso('no es fecha'), null);
  });
});

describe('agente._rateLimited — tope por chofer', () => {
  test('no limita hasta el cupo, después sí', () => {
    agente._resetRateLimit();
    const dni = '12345678';
    for (let i = 0; i < 20; i++) {
      assert.strictEqual(agente._rateLimited(dni), false, `iter ${i}`);
    }
    assert.strictEqual(agente._rateLimited(dni), true);
  });
  test('el cupo es por DNI (no se mezclan choferes)', () => {
    agente._resetRateLimit();
    for (let i = 0; i < 20; i++) agente._rateLimited('111');
    assert.strictEqual(agente._rateLimited('111'), true);
    assert.strictEqual(agente._rateLimited('222'), false);
  });
});

describe('agente._systemPrompt', () => {
  test('incluye nombre, DNI, fecha de hoy y la regla anti-invención', () => {
    const p = agente._systemPrompt({
      dni: '30111222',
      data: { NOMBRE: 'PEREZ JUAN' },
    });
    assert.ok(p.includes('PEREZ JUAN'));
    assert.ok(p.includes('30111222'));
    assert.ok(/\d{4}-\d{2}-\d{2}/.test(p), 'lleva la fecha de hoy');
    assert.ok(/NUNCA inventes/i.test(p), 'tiene la regla anti-invención');
  });
});

describe('agente._textoDeRespuesta', () => {
  test('junta los bloques de texto e ignora tool_use', () => {
    const resp = {
      content: [
        { type: 'text', text: 'Hola' },
        { type: 'tool_use', name: 'x', id: '1', input: {} },
        { type: 'text', text: 'mundo' },
      ],
    };
    assert.strictEqual(agente._textoDeRespuesta(resp), 'Hola\nmundo');
  });
  test('sin content → string vacío', () => {
    assert.strictEqual(agente._textoDeRespuesta({}), '');
    assert.strictEqual(agente._textoDeRespuesta(null), '');
  });
});

describe('agente.TOOLS_CHOFER — forma válida para la API', () => {
  test('cada tool tiene name, description e input_schema', () => {
    assert.ok(agente.TOOLS_CHOFER.length >= 2);
    for (const t of agente.TOOLS_CHOFER) {
      assert.strictEqual(typeof t.name, 'string');
      assert.ok(t.description.length > 10);
      assert.strictEqual(t.input_schema.type, 'object');
    }
  });
});

describe('agente._ejecutarTool — contra Firestore mockeado', () => {
  // Mock mínimo: db.collection(X).doc(id).get() → {exists, data()}.
  function dbMock(vehiculos) {
    return {
      collection() {
        return {
          doc(id) {
            return {
              async get() {
                const data = (vehiculos || {})[id];
                return { exists: !!data, data: () => data };
              },
            };
          },
        };
      },
    };
  }

  test('mis_vencimientos arma papeles del chofer y de su unidad', async () => {
    const chofer = {
      dni: '30111222',
      data: {
        NOMBRE: 'PEREZ',
        VEHICULO: 'AA111AA',
        LICENCIA_DE_CONDUCIR: '14-06-2026',
        PREOCUPACIONAL: '2027-01-10',
      },
    };
    const db = dbMock({ AA111AA: { VENCIMIENTO_RTO: '01-08-2026' } });
    const r = await agente._ejecutarTool(db, 'mis_vencimientos', chofer);
    assert.strictEqual(r.unidad_asignada, 'AA111AA');
    const papeles = r.papeles_del_chofer.map((p) => p.papel);
    assert.ok(papeles.includes('Licencia de conducir'));
    assert.ok(papeles.includes('Preocupacional'));
    const lic = r.papeles_del_chofer.find(
      (p) => p.papel === 'Licencia de conducir'
    );
    assert.strictEqual(lic.vence, '2026-06-14'); // normalizado
    assert.ok(r.papeles_de_la_unidad.some((p) => p.papel === 'RTO'));
  });

  test('mis_vencimientos sin datos → nota explicativa', async () => {
    const chofer = { dni: '1', data: { NOMBRE: 'X' } };
    const r = await agente._ejecutarTool(dbMock({}), 'mis_vencimientos', chofer);
    assert.strictEqual(r.papeles_del_chofer.length, 0);
    assert.ok(r.nota);
  });

  test('mi_unidad devuelve tractor y enganche con detalle', async () => {
    const chofer = {
      dni: '1',
      data: { VEHICULO: 'AA111AA', ENGANCHE: 'BB222BB' },
    };
    const db = dbMock({
      AA111AA: { TIPO: 'TRACTOR', MARCA: 'Volvo' },
      BB222BB: { TIPO: 'BATEA' },
    });
    const r = await agente._ejecutarTool(db, 'mi_unidad', chofer);
    assert.strictEqual(r.tractor.patente, 'AA111AA');
    assert.strictEqual(r.tractor.marca, 'Volvo');
    assert.strictEqual(r.enganche.patente, 'BB222BB');
    assert.strictEqual(r.enganche.tipo, 'BATEA');
  });

  test('mi_unidad sin enganche → enganche null', async () => {
    const chofer = { dni: '1', data: { VEHICULO: 'AA111AA' } };
    const r = await agente._ejecutarTool(dbMock({}), 'mi_unidad', chofer);
    assert.strictEqual(r.enganche, null);
    assert.strictEqual(r.tractor.patente, 'AA111AA');
  });

  test('tool desconocida → {error}', async () => {
    const r = await agente._ejecutarTool(dbMock({}), 'no_existe', {
      dni: '1',
      data: {},
    });
    assert.ok(r.error);
  });
});
