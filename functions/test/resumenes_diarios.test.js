// Tests de las funciones PURAS de construcción de mensajes de los
// resúmenes diarios (extraídas de los crons el 2026-05-19 para poder
// testear el formato sin Firestore).
//
// Cubre: construirResumenBot, construirMensajeDrifts,
// construirMensajeConducta. (El 4to, construirMensajeResumenJornadas,
// vive en jornadas_v2.ts → ver jornadas_v2_tick.test.js.)
//
// Estrategia: testear el compilado lib/resumenes_diarios.js.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  construirResumenBot,
  construirMensajeDrifts,
  construirMensajeConducta,
} = require('../lib/resumenes_diarios');

// 19/05/2026 14:00 ART (= 17:00 UTC) — para fechas estables en el texto.
const AHORA_MS = Date.UTC(2026, 4, 19, 17, 0, 0);

// ── construirResumenBot ─────────────────────────────────────────────

describe('construirResumenBot', () => {
  test('sin eventos → "Sin caídas" + contadores en 0', () => {
    const r = construirResumenBot([], AHORA_MS);
    assert.match(r.mensaje, /Sin caídas ni eventos/);
    assert.strictEqual(r.totalCaidas, 0);
    assert.strictEqual(r.totalRecuperaciones, 0);
    assert.strictEqual(r.minutosCaidoTotal, 0);
  });

  test('1 caída → línea 🔴 + totalCaidas 1', () => {
    const r = construirResumenBot([
      { tipo: 'caida', detectadoEnMs: AHORA_MS, pcId: 'pc1', minutosSinHeartbeat: 4 },
    ], AHORA_MS);
    assert.match(r.mensaje, /🔴 \*Caída detectada\*/);
    assert.match(r.mensaje, /pc1/);
    assert.match(r.mensaje, /4 min sin heartbeat/);
    assert.strictEqual(r.totalCaidas, 1);
    assert.match(r.mensaje, /1 caída en últimas 24h/);
  });

  test('1 recuperación → línea 🟢 + suma minutos caído', () => {
    const r = construirResumenBot([
      { tipo: 'recuperado', detectadoEnMs: AHORA_MS, pcId: 'pc1', duracionMin: 12 },
    ], AHORA_MS);
    assert.match(r.mensaje, /🟢 \*Recuperado\*/);
    assert.match(r.mensaje, /caído ~12 min/);
    assert.strictEqual(r.totalRecuperaciones, 1);
    assert.strictEqual(r.minutosCaidoTotal, 12);
    assert.match(r.mensaje, /recuperaciones de caídas previas/);
  });

  test('título plural con 2 caídas', () => {
    const r = construirResumenBot([
      { tipo: 'caida', detectadoEnMs: AHORA_MS, pcId: 'pc1' },
      { tipo: 'caida', detectadoEnMs: AHORA_MS, pcId: 'pc1' },
    ], AHORA_MS);
    assert.match(r.mensaje, /2 caídas en últimas 24h/);
    assert.strictEqual(r.totalCaidas, 2);
  });

  test('caída + recuperación → muestra tiempo total caído', () => {
    const r = construirResumenBot([
      { tipo: 'caida', detectadoEnMs: AHORA_MS, pcId: 'pc1' },
      { tipo: 'recuperado', detectadoEnMs: AHORA_MS, pcId: 'pc1', duracionMin: 8 },
    ], AHORA_MS);
    assert.match(r.mensaje, /Tiempo total caído estimado: 8 min/);
  });
});

// ── construirMensajeDrifts ──────────────────────────────────────────

describe('construirMensajeDrifts', () => {
  function drift(over = {}) {
    return {
      patente: 'AAA111',
      driftTipo: 'CHOFER_DISTINTO',
      fisicoDni: '999',
      fisicoApellido: 'GOMEZ',
      asignadoDni: '123',
      asignadoNombre: 'PEREZ JUAN',
      ...over,
    };
  }

  test('sin drifts → "Sin drifts"', () => {
    const m = construirMensajeDrifts([], '19/05/2026');
    assert.match(m, /Sin drifts/);
    assert.match(m, /19\/05\/2026/);
  });

  test('1 drift CHOFER_DISTINTO → etiqueta + físico vs sistema', () => {
    const m = construirMensajeDrifts([drift()], '19/05/2026');
    assert.match(m, /1 inconsistencia/); // singular
    assert.match(m, /AAA111/);
    assert.match(m, /PEREZ JUAN \(DNI 123\)/); // sistema
    assert.match(m, /GOMEZ \(DNI 999\)/); // físico
    assert.match(m, /Chofer distinto al asignado/);
  });

  test('físico sin DNI → "(no se identificó)"', () => {
    const m = construirMensajeDrifts(
      [drift({ driftTipo: 'CHOFER_NO_IDENTIFICADO', fisicoDni: '', fisicoApellido: '' })],
      '19/05/2026'
    );
    assert.match(m, /\(no se identificó\)/);
  });

  test('asignado sin DNI → "(sin asignación)"', () => {
    const m = construirMensajeDrifts(
      [drift({ driftTipo: 'SIN_ASIGNACION', asignadoDni: '', asignadoNombre: '' })],
      '19/05/2026'
    );
    assert.match(m, /\(sin asignación\)/);
  });

  test('más de 10 drifts → "Y N más"', () => {
    const drifts = [];
    for (let i = 0; i < 13; i++) {
      drifts.push(drift({ patente: `P${i.toString().padStart(3, '0')}` }));
    }
    const m = construirMensajeDrifts(drifts, '19/05/2026');
    assert.match(m, /13 inconsistencias/);
    assert.match(m, /Y 3 más/); // 13 - 10
  });

  test('breakdown cuenta por tipo', () => {
    const m = construirMensajeDrifts([
      drift({ driftTipo: 'CHOFER_DISTINTO' }),
      drift({ patente: 'BBB222', driftTipo: 'SIN_ASIGNACION', asignadoDni: '', asignadoNombre: '' }),
    ], '19/05/2026');
    assert.match(m, /1× Chofer distinto al asignado/);
    assert.match(m, /1× Sin asignación en sistema/);
  });
});

// ── construirMensajeConducta ────────────────────────────────────────

describe('construirMensajeConducta', () => {
  function grupo(over = {}) {
    return {
      keyChoferDni: '123',
      patente: 'AAA111',
      atribuido: false,
      sitrack: new Map(),
      volvo: new Map(),
      maxSobreLimite: null,
      ...over,
    };
  }

  test('sin grupos → "Sin eventos"', () => {
    const m = construirMensajeConducta([], new Map(), 'Hola Molina', '19/05/2026');
    assert.match(m, /Sin eventos/);
    assert.match(m, /Hola Molina/);
  });

  test('grupo identificado con eventos sitrack → nombre + conteo', () => {
    const g = grupo({ sitrack: new Map([['Frenada brusca', 3]]) });
    const m = construirMensajeConducta([g], new Map([['123', 'PEREZ JUAN']]), 'Hola', '19/05/2026');
    assert.match(m, /1 chofer\/unidad con eventos/); // singular
    assert.match(m, /\*PEREZ JUAN\* · AAA111/);
    assert.match(m, /Frenada brusca: 3/);
  });

  test('grupo NO_ID → "CHOFER NO IDENTIFICADO"', () => {
    const g = grupo({ keyChoferDni: 'NO_ID', sitrack: new Map([['Salida de carril', 1]]) });
    const m = construirMensajeConducta([g], new Map(), 'Hola', '19/05/2026');
    assert.match(m, /\*CHOFER NO IDENTIFICADO\* · AAA111/);
  });

  test('peor sobrevelocidad se resalta', () => {
    const g = grupo({
      sitrack: new Map([['Sobrevelocidad', 5]]),
      maxSobreLimite: { sobre: 35, gpsSpeed: 95, cartLimit: 60 },
    });
    const m = construirMensajeConducta([g], new Map([['123', 'X']]), 'Hola', '19/05/2026');
    assert.match(m, /Peor exceso: 95 km\/h \(límite 60 km\/h, \+35\)/);
  });

  test('atribuido por asignación → marca * + leyenda', () => {
    const g = grupo({ atribuido: true, sitrack: new Map([['Giro brusco', 2]]) });
    const m = construirMensajeConducta([g], new Map([['123', 'PEREZ']]), 'Hola', '19/05/2026');
    assert.match(m, /\*PEREZ\* \* · AAA111/);
    assert.match(m, /atribuido por asignación/);
  });

  test('merge sitrack + volvo, traduce siglas Volvo', () => {
    const g = grupo({
      sitrack: new Map([['Frenada brusca', 1]]),
      volvo: new Map([['AEBS', 2]]),
    });
    const m = construirMensajeConducta([g], new Map([['123', 'X']]), 'Hola', '19/05/2026');
    assert.match(m, /Frenada brusca: 1/);
    assert.match(m, /Frenado automático de emergencia: 2/); // AEBS traducido
  });

  test('plural con 2+ grupos', () => {
    const m = construirMensajeConducta([
      grupo({ sitrack: new Map([['Frenada brusca', 1]]) }),
      grupo({ keyChoferDni: '456', patente: 'BBB222', sitrack: new Map([['Giro brusco', 1]]) }),
    ], new Map(), 'Hola', '19/05/2026');
    assert.match(m, /2 choferes\/unidades con eventos/);
  });
});
