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
  test('gestión (ADMIN): menciona Cachatore, acceso a cualquiera, anti-invención', () => {
    const p = agente._systemPrompt({ rol: 'ADMIN', nombre: 'Santiago', data: {} });
    assert.ok(/cachatore/i.test(p), 'menciona Cachatore');
    assert.ok(/cualquier/i.test(p));
    assert.ok(/NUNCA inventes/i.test(p));
    assert.ok(/rol ADMIN/i.test(p));
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
  test('ADMIN/SUPERVISOR: incluyen las tools de Cachatore', () => {
    for (const rol of ['ADMIN', 'SUPERVISOR']) {
      const t = agente._toolsAnthropic(rol).map((x) => x.name);
      assert.ok(t.includes('buscar_vencimientos'), `${rol} buscar_vencimientos`);
      assert.ok(t.includes('cachatore_estado'), `${rol} cachatore_estado`);
      assert.ok(t.includes('poner_a_buscar_turno'), `${rol} poner_a_buscar_turno`);
    }
  });
  test('roles sin tools propias todavía → vacío', () => {
    assert.strictEqual(agente._toolsAnthropic('PLANTA').length, 0);
    assert.strictEqual(agente._toolsAnthropic('GOMERIA').length, 0);
    assert.strictEqual(agente._toolsAnthropic('SEG_HIGIENE').length, 0);
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

describe('agente._ejecutarTool — Cachatore', () => {
  function dbMockCacha({ objetivos = [], estadoBot = null, empleados = [] } = {}) {
    const escrituras = {};
    return {
      _escrituras: escrituras,
      collection(name) {
        return {
          doc(id) {
            return {
              async get() {
                if (name === 'CACHATORE_ESTADO' && id === 'bot') {
                  return { exists: !!estadoBot, data: () => estadoBot };
                }
                return { exists: false, data: () => undefined };
              },
              async set(data) {
                escrituras[`${name}/${id}`] = data;
              },
            };
          },
          async get() {
            if (name === 'CACHATORE_OBJETIVOS') {
              return { docs: objetivos.map((o) => ({ id: o.dni, data: () => o })) };
            }
            if (name === 'EMPLEADOS') {
              return { docs: empleados.map((e) => ({ id: e.id, data: () => e.data })) };
            }
            return { docs: [] };
          },
        };
      },
    };
  }

  test('cachatore_estado cuenta por estado (ignora inactivos)', async () => {
    const db = dbMockCacha({
      objetivos: [
        { dni: '1', nombre: 'A', activo: true, estado: 'reservado' },
        { dni: '2', nombre: 'B', activo: true, estado: 'buscando' },
        { dni: '3', nombre: 'C', activo: true, estado: 'buscando', reagendar: true },
        { dni: '4', nombre: 'D', activo: false, estado: 'reservado' },
        { dni: '5', nombre: 'E', activo: true, estado: 'sin_patente' },
      ],
      estadoBot: { modo: 'activo' },
    });
    const r = await agente._ejecutarTool(db, 'cachatore_estado', { rol: 'ADMIN' }, {});
    assert.strictEqual(r.total_objetivos, 4);
    assert.strictEqual(r.con_turno, 1);
    assert.strictEqual(r.buscando, 2);
    assert.strictEqual(r.para_reagendar, 1);
    assert.strictEqual(r.con_problemas, 1);
  });

  test('poner_a_buscar_turno escribe el objetivo con el contrato exacto', async () => {
    const db = dbMockCacha({
      empleados: [{ id: '30111222', data: { NOMBRE: 'PEZOA CARLOS', ROL: 'CHOFER', ACTIVO: true } }],
    });
    const r = await agente._ejecutarTool(
      db, 'poner_a_buscar_turno', { rol: 'ADMIN', dni: '25999888' },
      { chofer: 'pezoa', franja: 'manana', fecha: 'manana' }
    );
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.dni, '30111222');
    assert.strictEqual(r.franja, 'manana');
    const esc = db._escrituras['CACHATORE_OBJETIVOS/30111222'];
    assert.ok(esc, 'escribió el objetivo');
    assert.strictEqual(esc.franja, 'manana');
    assert.strictEqual(esc.fecha, 'manana');
    assert.strictEqual(esc.activo, true);
    assert.strictEqual(esc.reagendar, false);
    assert.strictEqual(esc.creado_por_dni, '25999888');
  });

  test('poner_a_buscar_turno ambiguo (2 coincidencias) NO escribe', async () => {
    const db = dbMockCacha({
      empleados: [
        { id: '1', data: { NOMBRE: 'PEZOA CARLOS', ROL: 'CHOFER', ACTIVO: true } },
        { id: '2', data: { NOMBRE: 'PEZOA JUAN', ROL: 'CHOFER', ACTIVO: true } },
      ],
    });
    const r = await agente._ejecutarTool(db, 'poner_a_buscar_turno', { rol: 'ADMIN' }, { chofer: 'pezoa' });
    assert.strictEqual(r.ok, false);
    assert.ok(r.ambiguo);
    assert.strictEqual(Object.keys(db._escrituras).length, 0);
  });

  test('poner_a_buscar_turno: franja inválida → cualquiera', async () => {
    const db = dbMockCacha({
      empleados: [{ id: '1', data: { NOMBRE: 'GOMEZ', ROL: 'CHOFER', ACTIVO: true } }],
    });
    const r = await agente._ejecutarTool(db, 'poner_a_buscar_turno', { rol: 'ADMIN' }, { chofer: 'gomez', franja: 'xyz' });
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.franja, 'cualquiera');
  });

  test('poner_a_buscar_turno sin chofer → error', async () => {
    const r = await agente._ejecutarTool(dbMockCacha(), 'poner_a_buscar_turno', { rol: 'ADMIN' }, {});
    assert.strictEqual(r.ok, false);
  });
});
