// Tests de la auto-verificación del backup (mantenimiento.ts). El inventario
// manual de collectionIds quedó corto TRES veces (2026-05-18, 2026-06-12 y
// los ICM encontrados al armar el backup v2): esta lógica compara la lista
// contra las colecciones REALES y lo que no esté clasificado dispara aviso.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  coleccionesSinClasificar,
  EXCLUIDAS_DEL_BACKUP,
} = require('../lib/mantenimiento');

describe('coleccionesSinClasificar', () => {
  test('todo clasificado → vacío', () => {
    const out = coleccionesSinClasificar(
      ['EMPLEADOS', 'CRON_HEALTH'],
      ['EMPLEADOS'],
      new Set(['CRON_HEALTH']),
    );
    assert.deepStrictEqual(out, []);
  });

  test('colección nueva sin clasificar → la reporta (el caso ICM_OFICIAL)', () => {
    const out = coleccionesSinClasificar(
      ['EMPLEADOS', 'ICM_OFICIAL', 'COLECCION_NUEVA'],
      ['EMPLEADOS'],
      new Set(),
    );
    assert.deepStrictEqual(out, ['COLECCION_NUEVA', 'ICM_OFICIAL']);
  });

  test('respaldada que ya no existe en la base NO molesta (export la ignora)', () => {
    const out = coleccionesSinClasificar(
      ['EMPLEADOS'],
      ['EMPLEADOS', 'COLECCION_RETIRADA'],
      new Set(),
    );
    assert.deepStrictEqual(out, []);
  });

  test('salida ordenada alfabéticamente (mensaje legible)', () => {
    const out = coleccionesSinClasificar(
      ['ZZZ', 'AAA', 'MMM'], [], new Set(),
    );
    assert.deepStrictEqual(out, ['AAA', 'MMM', 'ZZZ']);
  });
});

describe('EXCLUIDAS_DEL_BACKUP', () => {
  test('las efímeras conocidas están whitelisteadas con su razón en código', () => {
    for (const c of ['CRON_HEALTH', 'ZONA_DESCARGA_COLA', 'VOLVO_ESTADO']) {
      assert.ok(EXCLUIDAS_DEL_BACKUP.has(c), `falta ${c} en la whitelist`);
    }
  });

  test('ninguna colección de PLATA puede estar whitelisteada', () => {
    for (const c of ['VIAJES_LOGISTICA', 'ADELANTOS_CHOFER', 'TARIFAS_LOGISTICA',
      'ICM_OFICIAL', 'REGISTRO_JORNADAS', 'EMPLEADOS']) {
      assert.ok(!EXCLUIDAS_DEL_BACKUP.has(c),
        `${c} JAMÁS puede excluirse del backup`);
    }
  });
});
