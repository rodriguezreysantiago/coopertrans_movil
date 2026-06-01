// Tests de la lógica PURA del agente conversacional (agente.js).
//
// NO llaman a las APIs de Gemini/Anthropic (eso requiere key + red). Cubren:
// normalización de fechas, rate limit, system prompt por rol, extracción del
// texto, selección de proveedor, tools por rol y ejecución de cada tool
// contra un Firestore mockeado (chofer y admin).
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

describe('agente._rateLimited — tope por clave', () => {
  test('no limita hasta el cupo, después sí', () => {
    agente._resetRateLimit();
    const k = '12345678';
    for (let i = 0; i < 20; i++) {
      assert.strictEqual(agente._rateLimited(k), false, `iter ${i}`);
    }
    assert.strictEqual(agente._rateLimited(k), true);
  });
  test('el cupo es por clave (no se mezclan)', () => {
    agente._resetRateLimit();
    for (let i = 0; i < 20; i++) agente._rateLimited('111');
    assert.strictEqual(agente._rateLimited('111'), true);
    assert.strictEqual(agente._rateLimited('222'), false);
  });
});

describe('agente._systemPrompt — por rol', () => {
  test('CHOFER: nombre, DNI, fecha, anti-invención', () => {
    const p = agente._systemPrompt({
      rol: 'CHOFER',
      dni: '30111222',
      data: { NOMBRE: 'PEREZ JUAN' },
    });
    assert.ok(p.includes('PEREZ JUAN'));
    assert.ok(p.includes('30111222'));
    assert.ok(/\d{4}-\d{2}-\d{2}/.test(p));
    assert.ok(/NUNCA inventes/i.test(p));
    assert.ok(/CHOFER/i.test(p));
  });
  test('ADMIN: menciona administrador y acceso a cualquiera', () => {
    const p = agente._systemPrompt({ rol: 'ADMIN', nombre: 'Santiago', data: {} });
    assert.ok(/ADMINISTRADOR/i.test(p));
    assert.ok(/cualquier/i.test(p));
    assert.ok(/NUNCA inventes/i.test(p));
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

describe('agente — tools por rol y conversores', () => {
  test('CHOFER: tools sin parámetros', () => {
    const a = agente._toolsAnthropic('CHOFER');
    assert.ok(a.length >= 2);
    for (const t of a) assert.strictEqual(t.input_schema.type, 'object');
    const g = agente._toolsGemini('CHOFER');
    for (const d of g[0].functionDeclarations) {
      assert.strictEqual(d.parameters, undefined); // sin args
    }
  });
  test('ADMIN: buscar_vencimientos con parámetro query', () => {
    const a = agente._toolsAnthropic('ADMIN');
    const bv = a.find((t) => t.name === 'buscar_vencimientos');
    assert.ok(bv, 'existe buscar_vencimientos');
    assert.ok(bv.input_schema.properties.query);
    const g = agente._toolsGemini('ADMIN');
    const gbv = g[0].functionDeclarations.find(
      (d) => d.name === 'buscar_vencimientos'
    );
    assert.ok(gbv.parameters.properties.query); // admin SÍ lleva parameters
  });
});

describe('agente._provider — selección de proveedor', () => {
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
  test('sin nada configurado → null', () => {
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
  // doc(id).get() lee de `vehiculos`; collection().get() devuelve `empleados`.
  function dbMock({ vehiculos = {}, empleados = [] } = {}) {
    return {
      collection() {
        return {
          doc(id) {
            return {
              async get() {
                const d = vehiculos[id];
                return { exists: !!d, data: () => d };
              },
            };
          },
          async get() {
            return { docs: empleados.map((e) => ({ id: e.id, data: () => e.data })) };
          },
        };
      },
    };
  }

  test('mis_vencimientos (chofer): papeles propios + de la unidad', async () => {
    const persona = {
      rol: 'CHOFER',
      dni: '30111222',
      data: { NOMBRE: 'PEREZ', VEHICULO: 'AA111AA', LICENCIA_DE_CONDUCIR: '14-06-2026' },
    };
    const db = dbMock({ vehiculos: { AA111AA: { VENCIMIENTO_RTO: '01-08-2026' } } });
    const r = await agente._ejecutarTool(db, 'mis_vencimientos', persona);
    assert.strictEqual(r.unidad_asignada, 'AA111AA');
    assert.ok(
      r.papeles_del_chofer.some(
        (p) => p.papel === 'Licencia de conducir' && p.vence === '2026-06-14'
      )
    );
    assert.ok(r.papeles_de_la_unidad.some((p) => p.papel === 'RTO'));
  });

  test('mi_unidad (chofer): tractor + enganche', async () => {
    const persona = { rol: 'CHOFER', dni: '1', data: { VEHICULO: 'AA111AA', ENGANCHE: 'BB222BB' } };
    const db = dbMock({
      vehiculos: { AA111AA: { TIPO: 'TRACTOR', MARCA: 'Volvo' }, BB222BB: { TIPO: 'BATEA' } },
    });
    const r = await agente._ejecutarTool(db, 'mi_unidad', persona);
    assert.strictEqual(r.tractor.patente, 'AA111AA');
    assert.strictEqual(r.tractor.marca, 'Volvo');
    assert.strictEqual(r.enganche.tipo, 'BATEA');
  });

  test('buscar_vencimientos por PATENTE (admin)', async () => {
    const db = dbMock({ vehiculos: { AB123CD: { TIPO: 'TRACTOR', VENCIMIENTO_RTO: '10-09-2026' } } });
    const r = await agente._ejecutarTool(db, 'buscar_vencimientos', { rol: 'ADMIN' }, { query: 'AB123CD' });
    assert.strictEqual(r.tipo, 'unidad');
    assert.strictEqual(r.patente, 'AB123CD');
    assert.ok(r.papeles.some((p) => p.papel === 'RTO' && p.vence === '2026-09-10'));
  });

  test('buscar_vencimientos por NOMBRE (admin)', async () => {
    const db = dbMock({
      empleados: [
        { id: '30111222', data: { NOMBRE: 'PEREZ JUAN', VEHICULO: 'AA111AA', LICENCIA_DE_CONDUCIR: '14-06-2026' } },
        { id: '40555666', data: { NOMBRE: 'GOMEZ LUIS' } },
      ],
    });
    const r = await agente._ejecutarTool(db, 'buscar_vencimientos', { rol: 'ADMIN' }, { query: 'perez' });
    assert.strictEqual(r.tipo, 'choferes');
    assert.strictEqual(r.resultados.length, 1);
    assert.strictEqual(r.resultados[0].nombre, 'PEREZ JUAN');
    assert.ok(r.resultados[0].papeles.some((p) => p.papel === 'Licencia de conducir'));
  });

  test('buscar_vencimientos sin coincidencias (admin)', async () => {
    const db = dbMock({ empleados: [{ id: '1', data: { NOMBRE: 'GOMEZ' } }] });
    const r = await agente._ejecutarTool(db, 'buscar_vencimientos', { rol: 'ADMIN' }, { query: 'xyz' });
    assert.strictEqual(r.encontrado, false);
  });

  test('buscar_vencimientos sin query → error', async () => {
    const r = await agente._ejecutarTool(dbMock(), 'buscar_vencimientos', { rol: 'ADMIN' }, {});
    assert.ok(r.error);
  });

  test('tool desconocida → error', async () => {
    const r = await agente._ejecutarTool(dbMock(), 'no_existe', { rol: 'CHOFER', data: {} });
    assert.ok(r.error);
  });
});
