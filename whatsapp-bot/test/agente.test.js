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
// aIsoLocal: normalizador que usa el cron — oráculo del test de equivalencia.
const { aIsoLocal } = require('../src/fechas');

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
  // Fix 2 (auditoría 2026-06-06): _fechaIso ahora delega Timestamps/Date en
  // aIsoLocal (misma conversión que el cron), en vez de toISOString() (día UTC).
  test('Timestamp midnight-UTC (fecha calendario) → día UTC, no shift ART', () => {
    // Python guarda datetime(2026,5,30) como medianoche UTC. En ART eso es
    // 21h del 29; el día que el usuario quiso guardar es el 30.
    const ts = { toDate: () => new Date(Date.UTC(2026, 4, 30, 0, 0, 0, 0)) };
    assert.strictEqual(agente._fechaIso(ts), '2026-05-30');
  });
  test('Timestamp con hora real (no medianoche-UTC) usa componentes locales (ART)', () => {
    // 2026-06-14 22:00 ART = 2026-06-15 01:00 UTC. El día-calendario en ART es
    // el 14 — el código viejo (toISOString) devolvía 15 (off-by-one).
    const ts = { toDate: () => new Date(Date.UTC(2026, 5, 15, 1, 0, 0, 0)) };
    assert.strictEqual(agente._fechaIso(ts), '2026-06-14');
  });
  test('Timestamp serializado JSON con _seconds (midnight-UTC)', () => {
    const secs = Date.UTC(2026, 4, 30, 0, 0, 0, 0) / 1000;
    assert.strictEqual(agente._fechaIso({ _seconds: secs, _nanoseconds: 0 }), '2026-05-30');
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

// ── Fix 2 (auditoría 2026-06-06): _diasHasta del agente debe contar los días
//    con la MISMA fórmula que el cron, para no discrepar ±1 día con el aviso
//    automático sobre Timestamps de Firestore ──────────────────────────────
//
// Oráculo: réplica EXACTA de cron.calcularDiasRestantes (cron.js) — parseo
// manual de componentes Y-M-D y new Date(y,m,d) (medianoche LOCAL) en ambos
// extremos. Lo replicamos inline en vez de require('../src/cron') para que el
// test quede hermético (cron.js arrastra whatsapp/health/firestore). Si el
// algoritmo del cron cambiara, este oráculo (y el test) deben acompañarlo.
function _cronCalcularDiasRestantes(fechaIso) {
  if (!fechaIso) return null;
  const str = String(fechaIso).trim();
  let venc;
  const mIso = /^(\d{4})-(\d{2})-(\d{2})/.exec(str);
  const mAr = /^(\d{2})[\/\-](\d{2})[\/\-](\d{4})/.exec(str);
  if (mIso) {
    venc = new Date(parseInt(mIso[1], 10), parseInt(mIso[2], 10) - 1, parseInt(mIso[3], 10));
  } else if (mAr) {
    venc = new Date(parseInt(mAr[3], 10), parseInt(mAr[2], 10) - 1, parseInt(mAr[1], 10));
  } else {
    venc = new Date(str);
  }
  if (isNaN(venc.getTime())) return null;
  const hoy = new Date();
  const a = new Date(hoy.getFullYear(), hoy.getMonth(), hoy.getDate());
  const b = new Date(venc.getFullYear(), venc.getMonth(), venc.getDate());
  return Math.round((b.getTime() - a.getTime()) / (1000 * 60 * 60 * 24));
}

// Timestamp de Firestore (mock) cuyo día-calendario ART es `hoy + offsetDias`.
// La hora UTC se elige según el modo:
//   - 'medianoche': medianoche UTC (caso migración Python datetime(Y,M,D)).
//   - 'horaReal': 23:00 ART (= 02:00 UTC del día siguiente) — el caso que el
//     código viejo (toISOString) corría +1 día.
function _tsParaOffset(offsetDias, modo) {
  const base = new Date();
  base.setHours(0, 0, 0, 0);
  base.setDate(base.getDate() + offsetDias);
  const y = base.getFullYear();
  const m = base.getMonth();
  const d = base.getDate();
  const date = modo === 'horaReal'
    ? new Date(y, m, d, 23, 0, 0, 0) // 23:00 hora LOCAL (ART en el runner)
    : new Date(Date.UTC(y, m, d, 0, 0, 0, 0)); // medianoche UTC
  return { toDate: () => date };
}

describe('agente._diasHasta — conteo de días', () => {
  test('hoy (ISO) → 0; mañana → 1; ayer → -1', () => {
    const hoy = agente._hoyIso();
    assert.strictEqual(agente._diasHasta(hoy), 0);
    const [y, m, d] = hoy.split('-').map((n) => parseInt(n, 10));
    const manana = new Date(y, m - 1, d + 1);
    const isoManana = `${manana.getFullYear()}-${String(manana.getMonth() + 1).padStart(2, '0')}-${String(manana.getDate()).padStart(2, '0')}`;
    assert.strictEqual(agente._diasHasta(isoManana), 1);
    const ayer = new Date(y, m - 1, d - 1);
    const isoAyer = `${ayer.getFullYear()}-${String(ayer.getMonth() + 1).padStart(2, '0')}-${String(ayer.getDate()).padStart(2, '0')}`;
    assert.strictEqual(agente._diasHasta(isoAyer), -1);
  });

  test('null / fecha inválida → null', () => {
    assert.strictEqual(agente._diasHasta(null), null);
    assert.strictEqual(agente._diasHasta(''), null);
    assert.strictEqual(agente._diasHasta('xxxx'), null);
  });

  // EL TEST QUE FIJA EL FIX: para un Timestamp de Firestore, el conteo del
  // agente (_diasHasta ∘ _fechaIso) debe ser IDÉNTICO al del cron
  // (calcularDiasRestantes ∘ aIsoLocal). Antes del fix, _fechaIso usaba el día
  // UTC y _diasHasta restaba a medianoche UTC → discrepaba ±1 con el cron.
  for (const offset of [-5, -1, 0, 1, 7, 30]) {
    for (const modo of ['medianoche', 'horaReal']) {
      test(`equivalencia con el cron — Timestamp ${modo}, hoy+${offset}d`, () => {
        const ts = _tsParaOffset(offset, modo);
        const delAgente = agente._diasHasta(agente._fechaIso(ts));
        // El cron normaliza con aIsoLocal y cuenta con calcularDiasRestantes.
        const delCron = _cronCalcularDiasRestantes(aIsoLocal(ts));
        assert.strictEqual(
          delAgente, delCron,
          `agente=${delAgente} cron=${delCron} (modo=${modo}, offset=${offset})`,
        );
        // Y debe coincidir con el offset pedido (sanity, sin off-by-one).
        assert.strictEqual(delAgente, offset);
      });
    }
  }
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
  // Helper: nombres de las tools que el rol tiene definidas en Gemini.
  const nombresPara = (rol) =>
    agente._toolsGemini(rol)[0].functionDeclarations.map((d) => d.name);

  test('CHOFER: self-service sin parámetros + tools con args (contacto/discrepancia)', () => {
    const g = agente._toolsGemini('CHOFER');
    assert.ok(
      g[0].functionDeclarations.some((d) => d.name === 'contacto_oficina'),
      'CHOFER tiene la tool común contacto_oficina'
    );
    // Tools de chofer con parámetros: contacto_oficina (area), reportar_
    // discrepancia (tema/detalle) y registrar_parada_reportada (hora_inicio/
    // hora_fin/motivo). El resto es self-service sin args.
    const CON_PARAMS = new Set([
      'contacto_oficina', 'reportar_discrepancia', 'registrar_parada_reportada',
    ]);
    for (const d of g[0].functionDeclarations) {
      if (CON_PARAMS.has(d.name)) {
        assert.ok(d.parameters && d.parameters.properties, `${d.name} lleva parameters`);
      } else {
        assert.strictEqual(d.parameters, undefined); // self-service sin args
      }
    }
  });
  test('ADMIN: buscar_vencimientos con parámetro query', () => {
    const g = agente._toolsGemini('ADMIN');
    const gbv = g[0].functionDeclarations.find(
      (d) => d.name === 'buscar_vencimientos'
    );
    assert.ok(gbv, 'existe buscar_vencimientos');
    assert.ok(gbv.parameters.properties.query); // admin SÍ lleva parameters
  });
  test('ADMIN/SUPERVISOR: set completo de gestión (vencimientos + flota + cachatore)', () => {
    for (const rol of ['ADMIN', 'SUPERVISOR']) {
      const t = nombresPara(rol);
      assert.ok(t.includes('buscar_vencimientos'), `${rol} buscar_vencimientos`);
      assert.ok(t.includes('donde_esta'), `${rol} donde_esta`);
      assert.ok(t.includes('viajes_resumen'), `${rol} viajes_resumen`);
      assert.ok(t.includes('service_unidad'), `${rol} service_unidad`);
      assert.ok(t.includes('cachatore_estado'), `${rol} cachatore_estado`);
      assert.ok(t.includes('poner_a_buscar_turno'), `${rol} poner_a_buscar_turno`);
    }
  });
  test('SEG_HIGIENE: jornada (ICM) + posición/flota/alertas; NO vencimientos/cachatore/personal (RBAC)', () => {
    const t = nombresPara('SEG_HIGIENE');
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
    assert.strictEqual(
      agente._toolsGemini('PLANTA')[0].functionDeclarations.length, 0);
    assert.strictEqual(
      agente._toolsGemini('GOMERIA')[0].functionDeclarations.length, 0);
  });
});

describe('agente._provider — Gemini único', () => {
  // El bot quedó con Gemini como único proveedor (2026-06-08). El selector
  // se mantiene como interfaz por compat (firma de `_conversarRobusto`, log
  // y posibles fallbacks futuros), pero la lógica colapsó a "hay key o no".
  function conEnv(vars, fn) {
    const keys = ['GEMINI_API_KEY'];
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
  test('sin GEMINI_API_KEY → null (agente apagado)', () => {
    conEnv({}, () => assert.strictEqual(agente._provider(), null));
  });
  test('con GEMINI_API_KEY → "gemini"', () => {
    conEnv({ GEMINI_API_KEY: 'g-test' }, () =>
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

  // Unificación 2026-06-04: cachatore usa el mismo buscador que el resto.
  test('poner_a_buscar_turno resuelve orden invertido + tilde (buscador unificado)', async () => {
    const db = dbMockCacha({
      empleados: [{ id: '50', data: { NOMBRE: 'LESCANO GASTON ROBERTO', ROL: 'CHOFER', ACTIVO: true } }],
    });
    const r = await agente._ejecutarTool(db, 'poner_a_buscar_turno', { rol: 'ADMIN', dni: '1' }, { chofer: 'Gastón Lescano' });
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.dni, '50');
  });

  test('poner_a_buscar_turno NO resuelve a un chofer inactivo (soloActivos)', async () => {
    const db = dbMockCacha({
      empleados: [{ id: '51', data: { NOMBRE: 'BAJA PEDRO', ROL: 'CHOFER', ACTIVO: false } }],
    });
    const r = await agente._ejecutarTool(db, 'poner_a_buscar_turno', { rol: 'ADMIN' }, { chofer: 'baja pedro' });
    assert.strictEqual(r.ok, false);
    assert.strictEqual(Object.keys(db._escrituras).length, 0);
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

  test('mi_jornada: manejo_total = NETO (bloques cerrados + bloque en curso)', async () => {
    const db = dbMockFull({ jornadas: [
      { chofer_dni: '30111222', jornada_fin_ts: null, estado: 'manejando', total_manejo_seg: 5400, bloques_completos: 1, bloque_actual_manejo_seg: 1800, bloque_actual_pausa_seg: 0, ultima_patente: 'AA111AA' },
    ] });
    const r = await agente._ejecutarTool(db, 'mi_jornada', { rol: 'CHOFER', dni: '30111222', data: { NOMBRE: 'PEREZ' } });
    assert.strictEqual(r.jornada_activa, true);
    // 5400s (bloques cerrados) + 1800s (bloque en curso) = 7200s = 2h 0m.
    // Antes exponía solo los bloques cerrados (1h 30m) y el modelo mezclaba
    // los dos números → respuestas incoherentes. Ahora es la SUMA neta.
    assert.strictEqual(r.manejo_total, '2h 0m');
    assert.strictEqual(r.bloques_completos, 1);
    assert.strictEqual(r.unidad, 'AA111AA');
    assert.strictEqual(r.posible_arrastre, false);
  });

  test('mi_jornada: jornada abierta hace >16h → posible_arrastre + nota', async () => {
    const viejaMs = Date.now() - 20 * 3600000; // abierta hace 20h (no cerró)
    const db = dbMockFull({ jornadas: [
      { chofer_dni: '30111222', jornada_fin_ts: null, estado: 'manejando',
        total_manejo_seg: 43200, bloque_actual_manejo_seg: 0,
        jornada_inicio_ts: { toMillis: () => viejaMs } },
    ] });
    const r = await agente._ejecutarTool(db, 'mi_jornada', { rol: 'CHOFER', dni: '30111222', data: { NOMBRE: 'PEREZ' } });
    assert.strictEqual(r.posible_arrastre, true);
    assert.ok(r.nota && r.nota.length > 0, 'incluye nota de arrastre para el modelo');
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

  // Test "audio con proveedor Anthropic → null" eliminado 2026-06-08: el bot
  // ahora solo usa Gemini, que sí transcribe audio nativamente. No hay caso
  // donde un audio caiga al "no oye → null". Si entra un audio sin GEMINI_API_KEY
  // (agente apagado), ya está cubierto por el guard de responder() arriba.

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

describe('agente._ejecutarTool — crear_adelanto (acción de plata)', () => {
  // Mock con doc() SIN id (auto-id, como AdelantosService) + captura de escrituras.
  function dbMockAdel({ empleados = [] } = {}) {
    const escrituras = [];
    let seq = 0;
    return {
      _escrituras: escrituras,
      collection(name) {
        return {
          doc(id) {
            const docId = id || `auto_${++seq}`;
            return {
              id: docId,
              async set(data) { escrituras.push({ col: name, id: docId, data }); },
              async get() { return { exists: false, data: () => undefined }; },
            };
          },
          async get() {
            if (name === 'EMPLEADOS') {
              return { docs: empleados.map((e) => ({ id: e.id, data: () => e.data })) };
            }
            return { docs: [] };
          },
        };
      },
    };
  }

  const ADMIN = { rol: 'ADMIN', dni: '25999888', data: { NOMBRE: 'ERRAZU' } };
  const EMPS = [
    { id: '30111222', data: { NOMBRE: 'DIETRICH JUAN', ROL: 'CHOFER', ACTIVO: true } },
  ];

  test('paso 1 (sin confirmar) devuelve resumen y NO escribe', async () => {
    const db = dbMockAdel({ empleados: EMPS });
    const r = await agente._ejecutarTool(
      db, 'crear_adelanto', ADMIN, { empleado: 'dietrich', monto: 150000 });
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.requiere_confirmacion, true);
    assert.strictEqual(r.resumen.empleado, 'DIETRICH JUAN');
    assert.match(r.resumen.monto, /^\$150/);
    assert.strictEqual(r.resumen.medio_pago, 'efectivo');
    assert.strictEqual(db._escrituras.length, 0);
  });

  test('paso 2 (confirmado) escribe el doc con el contrato de la app', async () => {
    const db = dbMockAdel({ empleados: EMPS });
    const r = await agente._ejecutarTool(db, 'crear_adelanto', ADMIN, {
      empleado: 'dietrich', monto: 150000, confirmado: true, observacion: 'sueldo junio',
    });
    assert.strictEqual(r.ok, true);
    assert.ok(r.adelanto_id);
    assert.strictEqual(db._escrituras.length, 1);
    const esc = db._escrituras[0];
    assert.strictEqual(esc.col, 'ADELANTOS_CHOFER');
    assert.strictEqual(esc.data.chofer_dni, '30111222');
    assert.strictEqual(esc.data.chofer_nombre, 'DIETRICH JUAN');
    assert.strictEqual(esc.data.monto, 150000);
    assert.strictEqual(esc.data.medio_pago, 'EFECTIVO');
    assert.strictEqual(esc.data.pagado, false);
    assert.strictEqual(esc.data.creado_por_dni, '25999888');
    assert.strictEqual(esc.data.creado_por_nombre, 'ERRAZU');
    assert.strictEqual(esc.data.observacion, 'sueldo junio');
    assert.ok(esc.data.fecha, 'lleva fecha (Timestamp)');
  });

  test('nombre ambiguo (2 coincidencias) NO escribe y pide aclarar', async () => {
    const db = dbMockAdel({ empleados: [
      { id: '1', data: { NOMBRE: 'DIETRICH JUAN', ROL: 'CHOFER', ACTIVO: true } },
      { id: '2', data: { NOMBRE: 'DIETRICH PEDRO', ROL: 'PLANTA', ACTIVO: true } },
    ] });
    const r = await agente._ejecutarTool(
      db, 'crear_adelanto', ADMIN, { empleado: 'dietrich', monto: 1000, confirmado: true });
    assert.strictEqual(r.ok, false);
    assert.ok(r.ambiguo);
    assert.strictEqual(db._escrituras.length, 0);
  });

  test('monto inválido (0) → error, no escribe', async () => {
    const db = dbMockAdel({ empleados: EMPS });
    const r = await agente._ejecutarTool(
      db, 'crear_adelanto', ADMIN, { empleado: 'dietrich', monto: 0, confirmado: true });
    assert.strictEqual(r.ok, false);
    assert.match(r.error, /mayor a 0/);
    assert.strictEqual(db._escrituras.length, 0);
  });

  test('empleado inactivo (dado de baja) → no registra', async () => {
    const db = dbMockAdel({ empleados: [
      { id: '9', data: { NOMBRE: 'BAJA CARLOS', ROL: 'CHOFER', ACTIVO: false } },
    ] });
    const r = await agente._ejecutarTool(
      db, 'crear_adelanto', ADMIN, { empleado: 'baja', monto: 5000, confirmado: true });
    assert.strictEqual(r.ok, false);
    assert.match(r.error, /inactivo/i);
    assert.strictEqual(db._escrituras.length, 0);
  });

  test('medio transferencia + monto string "150.000" se interpretan bien', async () => {
    const db = dbMockAdel({ empleados: EMPS });
    const r = await agente._ejecutarTool(db, 'crear_adelanto', ADMIN, {
      empleado: 'dietrich', monto: '150.000', medio_pago: 'transferencia', confirmado: true,
    });
    assert.strictEqual(r.ok, true);
    assert.strictEqual(db._escrituras[0].data.monto, 150000);
    assert.strictEqual(db._escrituras[0].data.medio_pago, 'TRANSFERENCIA');
  });

  test('empleado vacío → error, no escribe', async () => {
    const db = dbMockAdel({ empleados: EMPS });
    const r = await agente._ejecutarTool(
      db, 'crear_adelanto', ADMIN, { monto: 1000, confirmado: true });
    assert.strictEqual(r.ok, false);
    assert.strictEqual(db._escrituras.length, 0);
  });

  test('fecha inválida → error claro, no escribe', async () => {
    const db = dbMockAdel({ empleados: EMPS });
    const r = await agente._ejecutarTool(db, 'crear_adelanto', ADMIN, {
      empleado: 'dietrich', monto: 1000, fecha: '2026-13-99', confirmado: true,
    });
    assert.strictEqual(r.ok, false);
    assert.strictEqual(db._escrituras.length, 0);
  });

  // Regresión del caso real Errazu/Lescano (2026-06-04): nombre dicho en orden
  // invertido (nombre apellido) + tilde de la transcripción de voz.
  test('resuelve orden invertido + tilde: "Gastón Lescano" → LESCANO GASTON ROBERTO', async () => {
    const db = dbMockAdel({ empleados: [
      { id: '40', data: { NOMBRE: 'LESCANO GASTON ROBERTO', ROL: 'CHOFER', ACTIVO: true } },
    ] });
    const r = await agente._ejecutarTool(db, 'crear_adelanto', ADMIN, { empleado: 'Gastón Lescano', monto: 150000 });
    assert.strictEqual(r.requiere_confirmacion, true, 'debe resolverlo, no "no encontré"');
    assert.strictEqual(r.resumen.empleado, 'LESCANO GASTON ROBERTO');
  });

  test('resuelve sin tilde y con ñ: "ibanez cristian" → IBAÑEZ CAMPOS CRISTIAN', async () => {
    const db = dbMockAdel({ empleados: [
      { id: '41', data: { NOMBRE: 'IBAÑEZ CAMPOS CRISTIAN', ROL: 'CHOFER', ACTIVO: true } },
    ] });
    const r = await agente._ejecutarTool(db, 'crear_adelanto', ADMIN, { empleado: 'ibanez cristian', monto: 5000 });
    assert.strictEqual(r.requiere_confirmacion, true);
    assert.strictEqual(r.resumen.empleado, 'IBAÑEZ CAMPOS CRISTIAN');
  });
});

describe('agente — mejoras 2026-06-06 (fuzzy + jornada pasada + adelantos emitidos + contacto)', () => {
  // Mock que distingue colecciones: EMPLEADOS (lista + doc), JORNADAS
  // (where/get) y ADELANTOS_CHOFER (get).
  function dbMix({ empleados = [], jornadas = [], adelantos = [] } = {}) {
    return {
      collection(name) {
        if (name === 'JORNADAS') {
          const q = { _f: {} };
          q.where = (c, _o, v) => { q._f[c] = v; return q; };
          q.limit = () => q;
          q.get = async () => {
            let r = jornadas;
            if ('chofer_dni' in q._f) r = r.filter((j) => j.chofer_dni === q._f.chofer_dni);
            if ('jornada_fin_ts' in q._f) r = r.filter((j) => (j.jornada_fin_ts ?? null) === q._f.jornada_fin_ts);
            return { empty: r.length === 0, docs: r.map((j) => ({ id: j.chofer_dni, data: () => j })) };
          };
          return q;
        }
        return {
          doc: (id) => ({
            get: async () => {
              if (name === 'EMPLEADOS') {
                const e = empleados.find((x) => x.id === id);
                return { exists: !!e, data: () => e && e.data };
              }
              return { exists: false, data: () => undefined };
            },
          }),
          get: async () => {
            if (name === 'EMPLEADOS') return { docs: empleados.map((e) => ({ id: e.id, data: () => e.data })) };
            if (name === 'ADELANTOS_CHOFER') return { docs: adelantos.map((a, i) => ({ id: String(i), data: () => a })) };
            return { docs: [] };
          },
        };
      },
    };
  }
  const ts = (d) => ({ toDate: () => d, toMillis: () => d.getTime() });

  test('fuzzy: "akerman" NO resuelve directo, sugiere ACKERMANN para confirmar', async () => {
    const db = dbMix({ empleados: [
      { id: '35416448', data: { NOMBRE: 'ACKERMANN HERNAN', ROL: 'CHOFER', ACTIVO: true } },
      { id: '99', data: { NOMBRE: 'GOMEZ JUAN', ROL: 'CHOFER', ACTIVO: true } },
    ] });
    const r = await agente._ejecutarTool(db, 'info_chofer', { rol: 'ADMIN' }, { query: 'akerman' });
    // Match aproximado de 1 sola persona → pide confirmar, no actúa sobre el posible equivocado.
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.sugerencia, 'ACKERMANN HERNAN');
  });

  test('fuzzy NO pisa el match exacto si existe', async () => {
    const db = dbMix({ empleados: [
      { id: '1', data: { NOMBRE: 'PEREZ JUAN', ROL: 'CHOFER', ACTIVO: true } },
      { id: '2', data: { NOMBRE: 'PERES CARLOS', ROL: 'CHOFER', ACTIVO: true } },
    ] });
    const r = await agente._ejecutarTool(db, 'info_chofer', { rol: 'ADMIN' }, { query: 'perez' });
    assert.strictEqual(r.nombre, 'PEREZ JUAN'); // exacto, sin fuzzy a "PERES"
  });

  test('jornada_de con dia="ayer" trae la jornada cerrada de ese día', async () => {
    const ayer = new Date(Date.now() - 24 * 3600 * 1000);
    const db = dbMix({
      empleados: [{ id: '1', data: { NOMBRE: 'PEREZ JUAN', ROL: 'CHOFER', ACTIVO: true } }],
      jornadas: [{
        chofer_dni: '1', jornada_fin_ts: ts(new Date()), jornada_inicio_ts: ts(ayer),
        total_manejo_seg: 28800, bloques_completos: 2, ultima_patente: 'AA111AA',
      }],
    });
    const r = await agente._ejecutarTool(db, 'jornada_de', { rol: 'ADMIN' }, { query: 'perez', dia: 'ayer' });
    assert.strictEqual(r.hay_jornada, true);
    assert.strictEqual(r.cerrada, true);
    assert.strictEqual(r.manejo_total, '8h 0m');
  });

  test('jornada_de día sin jornada → hay_jornada false', async () => {
    const db = dbMix({ empleados: [{ id: '1', data: { NOMBRE: 'PEREZ', ROL: 'CHOFER', ACTIVO: true } }], jornadas: [] });
    const r = await agente._ejecutarTool(db, 'jornada_de', { rol: 'ADMIN' }, { query: 'perez', dia: '2026-01-01' });
    assert.strictEqual(r.hay_jornada, false);
  });

  test('adelantos_emitidos: cuenta solo los creados en la ventana (hoy)', async () => {
    const hoyTs = { toMillis: () => Date.now() };
    const viejoTs = { toMillis: () => Date.now() - 5 * 24 * 3600 * 1000 };
    const db = dbMix({ adelantos: [
      { chofer_nombre: 'A', monto: 1000, creado_en: hoyTs },
      { chofer_nombre: 'B', monto: 2000, creado_en: hoyTs },
      { chofer_nombre: 'C', monto: 9999, creado_en: viejoTs },
    ] });
    const r = await agente._ejecutarTool(db, 'adelantos_emitidos', { rol: 'ADMIN' }, {});
    assert.strictEqual(r.cantidad, 2);
    assert.strictEqual(r.total, 3000);
  });

  test('adelantos_emitidos: ignora los eliminados', async () => {
    const hoyTs = { toMillis: () => Date.now() };
    const db = dbMix({ adelantos: [
      { chofer_nombre: 'A', monto: 1000, creado_en: hoyTs },
      { chofer_nombre: 'B', monto: 2000, creado_en: hoyTs, eliminado: true },
    ] });
    const r = await agente._ejecutarTool(db, 'adelantos_emitidos', { rol: 'ADMIN' }, {});
    assert.strictEqual(r.cantidad, 1);
    assert.strictEqual(r.total, 1000);
  });

  test('contacto_oficina: mantenimiento → Corchete Emmanuel con teléfono', async () => {
    const db = dbMix({ empleados: [
      { id: '29820141', data: { NOMBRE: 'CORCHETE EMMANUEL', TELEFONO: '5492914072695' } },
    ] });
    const r = await agente._ejecutarTool(db, 'contacto_oficina', { rol: 'CHOFER', dni: '1' }, { area: 'mantenimiento' });
    assert.strictEqual(r.nombre, 'CORCHETE EMMANUEL');
    assert.strictEqual(r.telefono, '5492914072695');
  });

  test('contacto_oficina: área desconocida → pide aclarar (no inventa)', async () => {
    const r = await agente._ejecutarTool(dbMix({}), 'contacto_oficina', { rol: 'CHOFER', dni: '1' }, { area: 'cualquiera' });
    assert.strictEqual(r.ok, false);
    assert.ok(Array.isArray(r.areas_validas));
  });

  test('CHOFER tiene contacto_oficina entre sus tools', () => {
    const nombres = agente._toolsGemini('CHOFER')[0].functionDeclarations
      .map((d) => d.name);
    assert.ok(nombres.includes('contacto_oficina'));
  });

  test('reportar_discrepancia: guarda pendiente con DNI/tema, sin tocar el dato', async () => {
    let guardado = null;
    const db = { collection: () => ({ doc: () => ({ id: 'r1', set: async (d) => { guardado = d; } }) }) };
    const r = await agente._ejecutarTool(
      db, 'reportar_discrepancia',
      { rol: 'CHOFER', dni: '30111222', data: { NOMBRE: 'PEREZ JUAN' } },
      { tema: 'jornada', detalle: 'salio 6:45 de Deraux y no figura' }
    );
    assert.strictEqual(r.ok, true);
    assert.strictEqual(guardado.estado, 'pendiente');
    assert.strictEqual(guardado.tema, 'jornada');
    assert.strictEqual(guardado.chofer_dni, '30111222');
    assert.ok(/6:45/.test(guardado.detalle));
  });

  test('reportar_discrepancia: tema inválido cae a "otro"', async () => {
    let guardado = null;
    const db = { collection: () => ({ doc: () => ({ id: 'r1', set: async (d) => { guardado = d; } }) }) };
    await agente._ejecutarTool(
      db, 'reportar_discrepancia',
      { rol: 'CHOFER', dni: '1', data: {} }, { tema: 'cualquiera', detalle: 'algo' }
    );
    assert.strictEqual(guardado.tema, 'otro');
  });

  test('registrar_parada_reportada: hora HH:MM + arranque + motivo → guarda con durSeg', async () => {
    let guardado = null;
    const db = { collection: () => ({ doc: () => ({ id: 'p1', set: async (d) => { guardado = d; } }) }) };
    const r = await agente._ejecutarTool(
      db, 'registrar_parada_reportada',
      { rol: 'CHOFER', dni: '30111222', data: { NOMBRE: 'PEREZ JUAN' } },
      { hora_inicio: '11:40', hora_fin: '12:05', motivo: 'almuerzo' }
    );
    assert.strictEqual(r.ok, true);
    assert.strictEqual(guardado.chofer_dni, '30111222');
    assert.strictEqual(guardado.inicio_label, '11:40');
    assert.strictEqual(guardado.fin_label, '12:05');
    assert.strictEqual(guardado.motivo, 'almuerzo');
    assert.strictEqual(guardado.estado, 'pendiente_cruce');
    // 25 min entre 11:40 y 12:05.
    assert.strictEqual(guardado.dur_seg, 25 * 60);
    assert.ok(/11:40/.test(r.mensaje) && /12:05/.test(r.mensaje));
  });

  test('registrar_parada_reportada: solo hora_inicio (parada en curso) → dur_seg null + mensaje "cuando arranques"', async () => {
    let guardado = null;
    const db = { collection: () => ({ doc: () => ({ id: 'p2', set: async (d) => { guardado = d; } }) }) };
    const r = await agente._ejecutarTool(
      db, 'registrar_parada_reportada',
      { rol: 'CHOFER', dni: '1', data: { NOMBRE: 'GARCIA' } },
      { hora_inicio: '9.05' } // punto en lugar de :, típico del chofer
    );
    assert.strictEqual(r.ok, true);
    assert.strictEqual(guardado.inicio_label, '09:05');
    assert.strictEqual(guardado.fin_label, null);
    assert.strictEqual(guardado.dur_seg, null);
    assert.ok(/cuando arranques/i.test(r.mensaje));
  });

  test('registrar_parada_reportada: hora_inicio inválida → error, NO escribe', async () => {
    let llamado = false;
    const db = { collection: () => ({ doc: () => ({ id: 'x', set: async () => { llamado = true; } }) }) };
    const r = await agente._ejecutarTool(
      db, 'registrar_parada_reportada',
      { rol: 'CHOFER', dni: '1', data: {} }, { hora_inicio: 'pronto' }
    );
    assert.strictEqual(r.ok, false);
    assert.strictEqual(llamado, false);
  });

  test('registrar_parada_reportada: formato HHMM sin separador → acepta y normaliza', async () => {
    let guardado = null;
    const db = { collection: () => ({ doc: () => ({ id: 'p3', set: async (d) => { guardado = d; } }) }) };
    const r = await agente._ejecutarTool(
      db, 'registrar_parada_reportada',
      { rol: 'CHOFER', dni: '1', data: {} },
      { hora_inicio: '1140', hora_fin: '1205' }
    );
    assert.strictEqual(r.ok, true);
    assert.strictEqual(guardado.inicio_label, '11:40');
    assert.strictEqual(guardado.fin_label, '12:05');
  });

  test('reportar_discrepancia: sin detalle → error, NO escribe', async () => {
    let llamado = false;
    const db = { collection: () => ({ doc: () => ({ id: 'r1', set: async () => { llamado = true; } }) }) };
    const r = await agente._ejecutarTool(
      db, 'reportar_discrepancia', { rol: 'CHOFER', dni: '1', data: {} }, { tema: 'jornada', detalle: '' }
    );
    assert.strictEqual(r.ok, false);
    assert.strictEqual(llamado, false);
  });
});
