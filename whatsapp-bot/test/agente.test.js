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
  test('gestión (SEG_HIGIENE): menciona jornada + flota/posición, NO Cachatore (RBAC)', () => {
    const p = agente._systemPrompt({ rol: 'SEG_HIGIENE', nombre: 'Molina', data: {} });
    assert.ok(/rol SEG_HIGIENE/i.test(p));
    assert.ok(/jornada/i.test(p), 'menciona jornada');
    assert.ok(/flota|posici/i.test(p), 'menciona flota/posición');
    assert.ok(!/cachatore/i.test(p), 'NO menciona Cachatore en lo que PODÉS');
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
  test('ADMIN/SUPERVISOR: set completo de gestión (vencimientos + flota + cachatore)', () => {
    for (const rol of ['ADMIN', 'SUPERVISOR']) {
      const t = agente._toolsAnthropic(rol).map((x) => x.name);
      assert.ok(t.includes('buscar_vencimientos'), `${rol} buscar_vencimientos`);
      assert.ok(t.includes('donde_esta'), `${rol} donde_esta`);
      assert.ok(t.includes('viajes_resumen'), `${rol} viajes_resumen`);
      assert.ok(t.includes('service_unidad'), `${rol} service_unidad`);
      assert.ok(t.includes('cachatore_estado'), `${rol} cachatore_estado`);
      assert.ok(t.includes('poner_a_buscar_turno'), `${rol} poner_a_buscar_turno`);
    }
  });
  test('SEG_HIGIENE: jornada (ICM) + posición/flota/alertas; NO vencimientos/cachatore/personal (RBAC)', () => {
    const t = agente._toolsAnthropic('SEG_HIGIENE').map((x) => x.name);
    // verIcm → jornada de un chofer (conducta de manejo — Molina la necesita).
    assert.ok(t.includes('jornada_de'), 'SEG_HIGIENE jornada_de (verIcm)');
    // verAlertasVolvo (Mapa Flota + tableros Volvo) → estas 3.
    assert.ok(t.includes('donde_esta'), 'SEG_HIGIENE donde_esta');
    assert.ok(t.includes('estado_flota'), 'SEG_HIGIENE estado_flota');
    assert.ok(t.includes('alertas_unidad'), 'SEG_HIGIENE alertas_unidad');
    // NO tiene verVencimientos / verCachatore / verListaPersonal en la app.
    assert.ok(!t.includes('buscar_vencimientos'), 'SEG_HIGIENE sin vencimientos');
    assert.ok(!t.includes('poner_a_buscar_turno'), 'SEG_HIGIENE sin cachatore');
    assert.ok(!t.includes('info_chofer'), 'SEG_HIGIENE sin datos de personal');
  });
  test('PLANTA / GOMERIA: sin tools (su módulo no tiene tool en el agente todavía)', () => {
    assert.strictEqual(agente._toolsAnthropic('PLANTA').length, 0);
    assert.strictEqual(agente._toolsAnthropic('GOMERIA').length, 0);
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
      data: { NOMBRE: 'PEREZ', VEHICULO: 'AA111AA', VENCIMIENTO_LICENCIA_DE_CONDUCIR: '14-06-2026' },
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

  test('mis_vencimientos: VEHICULO "-" (sin asignar) → unidad_asignada null (B6)', async () => {
    const persona = { rol: 'CHOFER', dni: '1', data: { NOMBRE: 'X', VEHICULO: '-' } };
    const r = await agente._ejecutarTool(dbMock({}), 'mis_vencimientos', persona);
    assert.strictEqual(r.unidad_asignada, null); // antes daba '-' y consultaba doc('-')
    assert.deepStrictEqual(r.papeles_de_la_unidad, []);
  });

  test('mi_unidad: "-" / "SIN ASIGNAR" → tractor y enganche null + nota (B6)', async () => {
    const persona = { rol: 'CHOFER', dni: '1', data: { VEHICULO: '-', ENGANCHE: 'SIN ASIGNAR' } };
    const r = await agente._ejecutarTool(dbMock({}), 'mi_unidad', persona);
    assert.strictEqual(r.tractor, null);
    assert.strictEqual(r.enganche, null);
    assert.match(r.nota, /no tenés/i);
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
        { id: '30111222', data: { NOMBRE: 'PEREZ JUAN', VEHICULO: 'AA111AA', VENCIMIENTO_LICENCIA_DE_CONDUCIR: '14-06-2026' } },
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
    assert.strictEqual(r.con_turno_detalle.length, 1);
    assert.strictEqual(r.con_turno_detalle[0].nombre, 'A');
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

describe('agente — memoria conversacional', () => {
  test('guarda y recupera turnos; aísla por clave', () => {
    agente._resetHistorial();
    agente._guardarHistorial('k1', [
      { rol: 'user', texto: 'cuantos con turno' },
      { rol: 'assistant', texto: 'son 2' },
    ]);
    const h = agente._recuperarHistorial('k1');
    assert.strictEqual(h.length, 2);
    assert.strictEqual(h[0].texto, 'cuantos con turno');
    assert.strictEqual(h[1].rol, 'assistant');
    assert.strictEqual(agente._recuperarHistorial('k2').length, 0);
  });

  test('recorta a los últimos 8 turnos', () => {
    agente._resetHistorial();
    const muchos = Array.from({ length: 12 }, (_, i) => ({ rol: 'user', texto: `t${i}` }));
    agente._guardarHistorial('k', muchos);
    const h = agente._recuperarHistorial('k');
    assert.strictEqual(h.length, 8);
    assert.strictEqual(h[0].texto, 't4'); // descartó los 4 más viejos
  });
});

describe('agente — herramientas nuevas (jornada, turno, vencimientos, info)', () => {
  function dbMockFull({ empleados = [], vehiculos = {}, jornadas = [], cacheObj = {}, cacheList = [] } = {}) {
    function colJornadas() {
      const f = {};
      const q = {};
      q.where = (campo, _op, val) => { f[campo] = val; return q; };
      q.limit = () => q;
      q.get = async () => {
        let res = jornadas;
        if ('chofer_dni' in f) res = res.filter((j) => j.chofer_dni === f.chofer_dni);
        if ('jornada_fin_ts' in f) res = res.filter((j) => (j.jornada_fin_ts ?? null) === f.jornada_fin_ts);
        return { empty: res.length === 0, docs: res.map((j) => ({ id: j.chofer_dni, data: () => j })) };
      };
      return q;
    }
    return {
      collection(name) {
        if (name === 'JORNADAS') return colJornadas();
        return {
          doc(id) {
            return {
              async get() {
                if (name === 'VEHICULOS') { const d = vehiculos[id]; return { exists: !!d, data: () => d }; }
                if (name === 'CACHATORE_OBJETIVOS') { const d = cacheObj[id]; return { exists: !!d, data: () => d }; }
                return { exists: false, data: () => undefined };
              },
            };
          },
          async get() {
            if (name === 'EMPLEADOS') return { docs: empleados.map((e) => ({ id: e.id, data: () => e.data })) };
            if (name === 'VEHICULOS') return { docs: Object.entries(vehiculos).map(([id, data]) => ({ id, data: () => data })) };
            if (name === 'CACHATORE_OBJETIVOS') return { docs: cacheList.map((o) => ({ id: o.dni, data: () => o })) };
            return { docs: [] };
          },
        };
      },
    };
  }

  test('mi_jornada: jornada activa → manejo y bloques', async () => {
    const db = dbMockFull({ jornadas: [
      { chofer_dni: '30111222', jornada_fin_ts: null, estado: 'manejando', total_manejo_seg: 5400, bloques_completos: 1, bloque_actual_manejo_seg: 1800, bloque_actual_pausa_seg: 0, ultima_patente: 'AA111AA' },
    ] });
    const r = await agente._ejecutarTool(db, 'mi_jornada', { rol: 'CHOFER', dni: '30111222', data: { NOMBRE: 'PEREZ' } });
    assert.strictEqual(r.jornada_activa, true);
    assert.strictEqual(r.manejo_total, '1h 30m');
    assert.strictEqual(r.bloques_completos, 1);
    assert.strictEqual(r.unidad, 'AA111AA');
  });

  test('mi_jornada: sin jornada activa', async () => {
    const r = await agente._ejecutarTool(dbMockFull({ jornadas: [] }), 'mi_jornada', { rol: 'CHOFER', dni: 'x', data: {} });
    assert.strictEqual(r.jornada_activa, false);
  });

  test('jornada_de: resuelve por nombre', async () => {
    const db = dbMockFull({
      empleados: [{ id: '30111222', data: { NOMBRE: 'PEREZ JUAN', ROL: 'CHOFER', ACTIVO: true } }],
      jornadas: [{ chofer_dni: '30111222', jornada_fin_ts: null, estado: 'manejando', total_manejo_seg: 3600 }],
    });
    const r = await agente._ejecutarTool(db, 'jornada_de', { rol: 'ADMIN' }, { query: 'perez' });
    assert.strictEqual(r.jornada_activa, true);
    assert.strictEqual(r.manejo_total, '1h 0m');
  });

  test('mi_turno_ypf: reservado', async () => {
    const db = dbMockFull({ cacheObj: { '30111222': { activo: true, estado: 'reservado', estado_turno: '05-06 06:00', franja: 'manana' } } });
    const r = await agente._ejecutarTool(db, 'mi_turno_ypf', { rol: 'CHOFER', dni: '30111222', data: {} });
    assert.strictEqual(r.tiene_turno, true);
    assert.strictEqual(r.turno, '05-06 06:00');
  });

  test('vencimientos_proximos: filtra por ventana de días', async () => {
    const hoy = new Date();
    const en = (d) => { const x = new Date(hoy); x.setUTCDate(x.getUTCDate() + d); return x.toISOString().slice(0, 10); };
    const db = dbMockFull({
      empleados: [{ id: '1', data: { NOMBRE: 'A', ROL: 'CHOFER', ACTIVO: true, VENCIMIENTO_LICENCIA_DE_CONDUCIR: en(5) } }],
      vehiculos: { AA111AA: { VENCIMIENTO_RTO: en(40) } },
    });
    const r = await agente._ejecutarTool(db, 'vencimientos_proximos', { rol: 'ADMIN' }, { dias: 15 });
    assert.strictEqual(r.cantidad, 1); // la licencia (5d) entra; RTO (40d) no
    assert.strictEqual(r.vencen[0].papel, 'Licencia de conducir');
  });

  test('info_chofer: datos por nombre', async () => {
    const db = dbMockFull({ empleados: [{ id: '30111222', data: { NOMBRE: 'PEREZ JUAN', ROL: 'CHOFER', ACTIVO: true, TELEFONO: '549', VEHICULO: 'AA111AA', VENCIMIENTO_LICENCIA_DE_CONDUCIR: '14-06-2026' } }] });
    const r = await agente._ejecutarTool(db, 'info_chofer', { rol: 'ADMIN' }, { query: 'perez' });
    assert.strictEqual(r.dni, '30111222');
    assert.strictEqual(r.unidad, 'AA111AA');
    assert.strictEqual(r.licencia_vence, '2026-06-14'); // lee VENCIMIENTO_LICENCIA_DE_CONDUCIR (regresión B1)
  });

  test('turnos_ypf_detalle: agrupa con nombres', async () => {
    const db = dbMockFull({ cacheList: [
      { dni: '1', nombre: 'A', activo: true, estado: 'reservado', estado_turno: 'X' },
      { dni: '2', nombre: 'B', activo: true, estado: 'buscando' },
      { dni: '3', nombre: 'C', activo: true, estado: 'sin_patente' },
    ] });
    const r = await agente._ejecutarTool(db, 'turnos_ypf_detalle', { rol: 'ADMIN' }, {});
    assert.strictEqual(r.con_turno.length, 1);
    assert.strictEqual(r.con_turno[0].nombre, 'A');
    assert.strictEqual(r.buscando.length, 1);
    assert.strictEqual(r.con_problemas.length, 1);
  });

  test('helpers _fmtHHMM y _diasHasta', () => {
    assert.strictEqual(agente._fmtHHMM(5400), '1h 30m');
    assert.strictEqual(agente._fmtHHMM(120), '2m');
    assert.strictEqual(agente._diasHasta(null), null);
    assert.strictEqual(agente._diasHasta('no-fecha'), null);
  });
});

describe('agente — herramientas de flota / operación', () => {
  // Mock genérico: data = { COLECCION: [ {id, ...campos} ] }. Soporta
  // collection().where().get(), collection().doc(id).get(), collection().get().
  function dbMockGen(data) {
    function makeQuery(name) {
      const filtros = [];
      const q = {
        where(campo, op, val) { filtros.push([campo, op, val]); return q; },
        limit() { return q; },
        orderBy() { return q; },
        async get() {
          let docs = data[name] || [];
          for (const [campo, op, val] of filtros) {
            docs = docs.filter((d) => {
              if (op === '==') return (d[campo] ?? null) === val;
              if (op === '>=') {
                const v = d[campo];
                const ms = v && v.toMillis ? v.toMillis() : (typeof v === 'number' ? v : null);
                const valMs = val && val.toMillis ? val.toMillis() : val;
                return ms != null && ms >= valMs;
              }
              return true;
            });
          }
          return { size: docs.length, empty: docs.length === 0, docs: docs.map((d) => ({ id: d.id, data: () => d })) };
        },
      };
      return q;
    }
    return {
      collection(name) {
        const q = makeQuery(name);
        return {
          where: q.where,
          limit: q.limit,
          orderBy: q.orderBy,
          get: q.get,
          doc(id) {
            return {
              async get() {
                const found = (data[name] || []).find((d) => d.id === id);
                return { exists: !!found, data: () => found };
              },
            };
          },
        };
      },
    };
  }

  test('mis_adelantos: suma pendiente/pagado e ignora eliminados y otros', async () => {
    const db = dbMockGen({ ADELANTOS_CHOFER: [
      { id: 'a1', chofer_dni: '30', monto: 1500, pagado: false },
      { id: 'a2', chofer_dni: '30', monto: 2000, pagado: true },
      { id: 'a3', chofer_dni: '30', monto: 500, pagado: false, eliminado: true },
      { id: 'a4', chofer_dni: '99', monto: 9999, pagado: false },
    ] });
    const r = await agente._ejecutarTool(db, 'mis_adelantos', { rol: 'CHOFER', dni: '30', data: { NOMBRE: 'X' } });
    assert.strictEqual(r.total_pendiente, 1500);
    assert.strictEqual(r.total_pagado, 2000);
    assert.strictEqual(r.cantidad, 2);
  });

  test('donde_esta_mi_unidad: VOLVO_ESTADO en ruta', async () => {
    const db = dbMockGen({ VOLVO_ESTADO: [{ id: 'AA111AA', speed_kmh: 80, motor_encendido: true, posicion_ts: new Date().toISOString() }] });
    const r = await agente._ejecutarTool(db, 'donde_esta_mi_unidad', { rol: 'CHOFER', dni: '1', data: { VEHICULO: 'AA111AA' } });
    assert.strictEqual(r.en_ruta, true);
    assert.strictEqual(r.velocidad_kmh, 80);
  });

  test('donde_esta_mi_unidad: sin unidad asignada', async () => {
    const r = await agente._ejecutarTool(dbMockGen({}), 'donde_esta_mi_unidad', { rol: 'CHOFER', dni: '1', data: {} });
    assert.strictEqual(r.encontrado, false);
  });

  test('estado_flota: categoriza por velocidad y frescura', async () => {
    const ahora = new Date().toISOString();
    const viejo = new Date(Date.now() - 3 * 3600 * 1000).toISOString();
    const db = dbMockGen({ VOLVO_ESTADO: [
      { id: '1', speed_kmh: 80, posicion_ts: ahora },
      { id: '2', speed_kmh: 0, posicion_ts: ahora },
      { id: '3', speed_kmh: 50, posicion_ts: viejo },
    ] });
    const r = await agente._ejecutarTool(db, 'estado_flota', { rol: 'ADMIN' });
    assert.strictEqual(r.total_unidades, 3);
    assert.strictEqual(r.en_ruta, 1);
    assert.strictEqual(r.paradas, 1);
    assert.strictEqual(r.sin_datos_recientes, 1);
  });

  test('quien_esta_descargando: lista la cola', async () => {
    const db = dbMockGen({ ZONA_DESCARGA_COLA: [
      { id: 'AA_z', patente: 'AA111AA', nombre_zona: 'Añelo', chofer_nombre: 'PEREZ', entrada_ts: { toMillis: () => Date.now() - 1800000 } },
    ] });
    const r = await agente._ejecutarTool(db, 'quien_esta_descargando', { rol: 'ADMIN' });
    assert.strictEqual(r.cantidad, 1);
    assert.strictEqual(r.unidades[0].zona, 'Añelo');
  });

  test('alertas_unidad: filtra 24h y cuenta críticas', async () => {
    const reciente = { toMillis: () => Date.now() - 3600000 };
    const viejo = { toMillis: () => Date.now() - 48 * 3600000 };
    const db = dbMockGen({ VOLVO_ALERTAS: [
      { id: '1', patente: 'AA111AA', tipo: 'OVERSPEED', severidad: 'HIGH', creado_en: reciente },
      { id: '2', patente: 'AA111AA', tipo: 'IDLING', severidad: 'LOW', creado_en: reciente },
      { id: '3', patente: 'AA111AA', tipo: 'OVERSPEED', severidad: 'HIGH', creado_en: viejo },
    ] });
    const r = await agente._ejecutarTool(db, 'alertas_unidad', { rol: 'ADMIN' }, { query: 'AA111AA' });
    assert.strictEqual(r.alertas_24h, 2);
    assert.strictEqual(r.criticas, 1);
  });

  test('service_unidad: horas y distancia', async () => {
    const db = dbMockGen({ VOLVO_ESTADO: [{ id: 'AA111AA', horas_motor: 12500, service_distance_km: 2000 }] });
    const r = await agente._ejecutarTool(db, 'service_unidad', { rol: 'ADMIN' }, { query: 'AA111AA' });
    assert.strictEqual(r.horas_motor, 12500);
    assert.strictEqual(r.km_al_proximo_service, 2000);
  });

  test('viajes_resumen: cuenta por estado e ignora borrados', async () => {
    const reciente = { toMillis: () => Date.now() - 2 * 86400000 };
    const db = dbMockGen({ VIAJES_LOGISTICA: [
      { id: '1', estado: 'CONCLUIDO', creado_en: reciente },
      { id: '2', estado: 'EN_CURSO', creado_en: reciente },
      { id: '3', estado: 'PLANEADO', creado_en: reciente, activo: false },
    ] });
    const r = await agente._ejecutarTool(db, 'viajes_resumen', { rol: 'ADMIN' }, { dias: 7 });
    assert.strictEqual(r.total, 2);
    assert.strictEqual(r.concluidos, 1);
    assert.strictEqual(r.en_curso, 1);
  });

  test('_getEmpleadosDocs cachea por instancia de db (no relee la colección)', async () => {
    let lecturas = 0;
    const db = { collection: () => ({ get: async () => { lecturas++; return { docs: [{ id: '1', data: () => ({ NOMBRE: 'X' }) }] }; } }) };
    const a = await agente._getEmpleadosDocs(db);
    const b = await agente._getEmpleadosDocs(db);
    assert.strictEqual(lecturas, 1);
    assert.strictEqual(a, b);
  });

  test('responder: audio con proveedor Anthropic → null (Claude no oye audio)', async () => {
    const prevP = process.env.AGENTE_PROVIDER;
    const prevK = process.env.ANTHROPIC_API_KEY;
    const prevG = process.env.GEMINI_API_KEY;
    process.env.AGENTE_PROVIDER = 'anthropic';
    process.env.ANTHROPIC_API_KEY = 'sk-test';
    delete process.env.GEMINI_API_KEY;
    try {
      const r = await agente.responder(
        { texto: '', audio: { data: 'AAA', mimetype: 'audio/ogg' }, persona: { rol: 'CHOFER', dni: '1' }, telefono: '1' },
        { inicializar: () => ({}) }
      );
      assert.strictEqual(r, null);
    } finally {
      if (prevP === undefined) delete process.env.AGENTE_PROVIDER; else process.env.AGENTE_PROVIDER = prevP;
      if (prevK === undefined) delete process.env.ANTHROPIC_API_KEY; else process.env.ANTHROPIC_API_KEY = prevK;
      if (prevG === undefined) delete process.env.GEMINI_API_KEY; else process.env.GEMINI_API_KEY = prevG;
    }
  });

  test('responder: audio que supera el tope de tamaño → mensaje claro (B9)', async () => {
    const prev = {
      P: process.env.AGENTE_PROVIDER, G: process.env.GEMINI_API_KEY,
      E: process.env.AGENTE_ENABLED, M: process.env.AGENTE_MAX_AUDIO_B64,
    };
    process.env.AGENTE_PROVIDER = 'gemini';
    process.env.GEMINI_API_KEY = 'g-test';
    process.env.AGENTE_ENABLED = 'true';
    process.env.AGENTE_MAX_AUDIO_B64 = '10'; // tope chico para el test
    try {
      // base64 de 50 chars > tope 10 → corta antes de llamar a Gemini.
      const r = await agente.responder(
        { texto: '', audio: { data: 'X'.repeat(50), mimetype: 'audio/ogg' }, persona: { rol: 'CHOFER', dni: 'b9' }, telefono: 'b9' },
        { inicializar: () => ({}) }
      );
      assert.match(r, /muy largo/);
    } finally {
      const set = (k, v) => { if (v === undefined) delete process.env[k]; else process.env[k] = v; };
      set('AGENTE_PROVIDER', prev.P); set('GEMINI_API_KEY', prev.G);
      set('AGENTE_ENABLED', prev.E); set('AGENTE_MAX_AUDIO_B64', prev.M);
    }
  });
});
