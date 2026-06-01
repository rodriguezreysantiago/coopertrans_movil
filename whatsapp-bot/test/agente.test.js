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

describe('agente — tools neutras y conversores por proveedor', () => {
  test('TOOLS_CHOFER en formato neutro (name, description, params)', () => {
    assert.ok(agente.TOOLS_CHOFER.length >= 2);
    for (const t of agente.TOOLS_CHOFER) {
      assert.strictEqual(typeof t.name, 'string');
      assert.ok(t.description.length > 10);
      assert.strictEqual(typeof t.params, 'object');
    }
  });
  test('_toolsAnthropic → input_schema object por tool', () => {
    const tools = agente._toolsAnthropic();
    assert.strictEqual(tools.length, agente.TOOLS_CHOFER.length);
    for (const t of tools) {
      assert.strictEqual(typeof t.name, 'string');
      assert.strictEqual(t.input_schema.type, 'object');
    }
  });
  test('_toolsGemini → un bloque con functionDeclarations', () => {
    const tools = agente._toolsGemini();
    assert.strictEqual(tools.length, 1);
    const decls = tools[0].functionDeclarations;
    assert.strictEqual(decls.length, agente.TOOLS_CHOFER.length);
    for (const d of decls) {
      assert.strictEqual(typeof d.name, 'string');
      assert.ok(d.description.length > 10);
      // tools sin args: no debe llevar `parameters` con properties vacío
      assert.strictEqual(d.parameters, undefined);
    }
  });
});

describe('agente._provider — selección de proveedor', () => {
  // Corre `fn` con SOLO las env vars dadas (restaura las previas al salir).
  function conEnv(vars, fn) {
    const keys = ['AGENTE_PROVIDER', 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY'];
    const prev = {};
    for (const k of keys) prev[k] = process.env[k];
    for (const k of keys) delete process.env[k];
    for (const [k, v] of Object.entries(vars)) process.env[k] = v;
    try {
      fn();
    } finally {
      for (const k of keys) {
        if (prev[k] === undefined) delete process.env[k];
        else process.env[k] = prev[k];
      }
    }
  }

  test('respeta AGENTE_PROVIDER explícito', () => {
    conEnv({ AGENTE_PROVIDER: 'anthropic' }, () =>
      assert.strictEqual(agente._provider(), 'anthropic')
    );
    conEnv({ AGENTE_PROVIDER: 'gemini' }, () =>
      assert.strictEqual(agente._provider(), 'gemini')
    );
  });
  test('sin nada configurado → null (apagado)', () => {
    conEnv({}, () => assert.strictEqual(agente._provider(), null));
  });
  test('autodetecta por key; Gemini tiene prioridad', () => {
    conEnv({ ANTHROPIC_API_KEY: 'x' }, () =>
      assert.strictEqual(agente._provider(), 'anthropic')
    );
    conEnv({ ANTHROPIC_API_KEY: 'x', GEMINI_API_KEY: 'y' }, () =>
      assert.strictEqual(agente._provider(), 'gemini')
    );
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
