// Tests de excluidos.js — decide QUIÉN NO recibe avisos del bot (tanqueros de
// otra área + testers de review). Sin red previa (auditoría 2026-06-11): es
// lógica de "no mandar WhatsApp a quien no corresponde" y no tenía cobertura.

const { test, describe, beforeEach } = require('node:test');
const assert = require('node:assert');
const excluidos = require('../src/excluidos');

// db mock: soporta VEHICULOS.where().limit().get() y EMPLEADOS.limit().get().
function dbMock({ tanques = [], empleados = [], fallar = false } = {}) {
  const queryGet = (docs) => ({
    async get() {
      if (fallar) throw new Error('firestore caído (test)');
      return {
        size: docs.length,
        docs: docs.map((d) => ({ id: d.id, data: () => d.data })),
      };
    },
  });
  return {
    collection(name) {
      if (name === 'VEHICULOS') {
        return { where: () => ({ limit: () => queryGet(tanques) }) };
      }
      return { limit: () => queryGet(empleados) }; // EMPLEADOS
    },
  };
}

describe('excluidos.cargarExcluidos', () => {
  beforeEach(() => excluidos._resetCacheExcluidosParaTests());

  test('detecta testers por nombre (reviewer/tester/demo), sin falsos positivos', async () => {
    const db = dbMock({
      empleados: [
        { id: '1', data: { NOMBRE: 'APPLE REVIEWER', ACTIVO: true } },
        { id: '2', data: { NOMBRE: 'Android Tester', ACTIVO: true } },
        { id: '3', data: { NOMBRE: 'Cuenta Demo', ACTIVO: true } },
        { id: '4', data: { NOMBRE: 'DEMOLICION SA', ACTIVO: true } }, // NO matchea
        { id: '5', data: { NOMBRE: 'JUAN PEREZ', ACTIVO: true } },
      ],
    });
    const r = await excluidos.cargarExcluidos(db);
    assert.ok(r.dnis.has('1'));
    assert.ok(r.dnis.has('2'));
    assert.ok(r.dnis.has('3'));
    assert.ok(!r.dnis.has('4'), '"Demolición" NO debe matchear el regex tester');
    assert.ok(!r.dnis.has('5'));
  });

  test('detecta tanqueros (ENGANCHE = patente TANQUE) + su tractor', async () => {
    const db = dbMock({
      tanques: [{ id: 'TANQUE01', data: {} }],
      empleados: [
        { id: '10', data: { NOMBRE: 'CHOFER TANQUE', ENGANCHE: 'tanque01', VEHICULO: 'TRACTOR9', ACTIVO: true } },
        { id: '11', data: { NOMBRE: 'CHOFER NORMAL', ENGANCHE: 'OTRO', VEHICULO: 'TRACTOR1', ACTIVO: true } },
      ],
    });
    const r = await excluidos.cargarExcluidos(db);
    assert.ok(r.dnis.has('10'), 'el tanquero queda excluido (match case-insensitive)');
    assert.ok(!r.dnis.has('11'));
    assert.ok(r.patentes.has('TANQUE01'));
    assert.ok(r.patentes.has('TRACTOR9'), 'el tractor del tanquero también se excluye');
    assert.ok(!r.patentes.has('TRACTOR1'));
  });

  test('un inactivo NO se excluye aunque matchee (ya no recibe nada igual)', async () => {
    const db = dbMock({
      empleados: [{ id: '1', data: { NOMBRE: 'TESTER VIEJO', ACTIVO: false } }],
    });
    const r = await excluidos.cargarExcluidos(db);
    assert.ok(!r.dnis.has('1'));
  });

  test('fail-safe: si la query falla, devuelve set vacío (no rompe el cron)', async () => {
    const db = dbMock({ fallar: true });
    const r = await excluidos.cargarExcluidos(db);
    assert.strictEqual(r.dnis.size, 0);
    assert.strictEqual(r.patentes.size, 0);
  });
});

describe('excluidos.esExcluido', () => {
  test('matchea por dni y por patente (case-insensitive); vacío → false', () => {
    const set = { dnis: new Set(['99']), patentes: new Set(['AB123CD']) };
    assert.ok(excluidos.esExcluido(set, { dni: '99' }));
    assert.ok(excluidos.esExcluido(set, { patente: 'ab123cd' }));
    assert.ok(!excluidos.esExcluido(set, { dni: '00' }));
    assert.ok(!excluidos.esExcluido(set, { patente: 'ZZ999ZZ' }));
    assert.ok(!excluidos.esExcluido(set, {}));
  });
});
