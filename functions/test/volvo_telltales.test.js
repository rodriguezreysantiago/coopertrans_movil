// Tests del clasificador PURO de tell-tales (lib/volvo_telltales.js).
// Lockea el diccionario ISO→español y la severidad por sistema que alimenta
// el parte de mantenimiento a Emmanuel (#43).

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  nombreTellTale,
  clasificarAdvertencia,
  clasificarAdvertencias,
} = require('../lib/volvo_telltales');

describe('nombreTellTale', () => {
  test('traduce IDs conocidos al español', () => {
    assert.strictEqual(nombreTellTale('ABS_TRAILER'), 'ABS del acoplado');
    assert.strictEqual(
      nombreTellTale('ADVANCED_EMERGENCY_BREAKING'),
      'Frenado de emergencia (AEBS)',
    );
    assert.strictEqual(nombreTellTale('WORN_BRAKE_LININGS'), 'Pastillas de freno gastadas');
  });

  test('ID desconocido → humanizado', () => {
    assert.strictEqual(nombreTellTale('SOME_NEW_LIGHT'), 'Some new light');
  });
});

describe('clasificarAdvertencia (uno)', () => {
  test('RED → crítico sin importar el sistema', () => {
    const a = clasificarAdvertencia('POSITION_LIGHTS', 'RED');
    assert.strictEqual(a.severidad, 'critico');
    assert.strictEqual(a.estado, 'RED');
  });

  test('YELLOW en frenos → alto', () => {
    const a = clasificarAdvertencia('ABS_TRAILER', 'YELLOW');
    assert.strictEqual(a.severidad, 'alto');
    assert.strictEqual(a.categoria, 'frenos');
    assert.strictEqual(a.nombre, 'ABS del acoplado');
  });

  test('YELLOW en luces → bajo', () => {
    const a = clasificarAdvertencia('POSITION_LIGHTS', 'YELLOW');
    assert.strictEqual(a.severidad, 'bajo');
    assert.strictEqual(a.categoria, 'luces');
  });

  test('YELLOW en seguridad activa (AEBS) → alto', () => {
    assert.strictEqual(
      clasificarAdvertencia('ADVANCED_EMERGENCY_BREAKING', 'YELLOW').severidad,
      'alto',
    );
  });

  test('INFO / OFF / NOT_AVAILABLE → null (no es advertencia)', () => {
    assert.strictEqual(clasificarAdvertencia('PARKING_BRAKE', 'INFO'), null);
    assert.strictEqual(clasificarAdvertencia('ABS_TRAILER', 'OFF'), null);
    assert.strictEqual(clasificarAdvertencia('PARKING_HEATER', 'NOT_AVAILABLE'), null);
    assert.strictEqual(clasificarAdvertencia('FUEL_LEVEL', ''), null);
  });

  test('case-insensitive en el estado', () => {
    assert.strictEqual(clasificarAdvertencia('ABS_TRAILER', 'yellow').severidad, 'alto');
  });
});

describe('clasificarAdvertencias (lista, real flota)', () => {
  test('caso AF869ZU: filtra INFO y ordena por severidad', () => {
    // Datos reales capturados de la flota Vecchi 2026-05-21.
    const crudos = [
      { id: 'ABS_TRAILER', estado: 'YELLOW' },
      { id: 'PARKING_BRAKE', estado: 'INFO' },
      { id: 'WINDSCREEN_WASHER_FLUID', estado: 'INFO' },
      { id: 'ADVANCED_EMERGENCY_BREAKING', estado: 'YELLOW' },
      { id: 'LANE_DEPARTURE_INDICATOR', estado: 'YELLOW' },
      { id: 'POSITION_LIGHTS', estado: 'YELLOW' },
    ];
    const adv = clasificarAdvertencias(crudos);
    // PARKING_BRAKE INFO + WASHER INFO se filtran → quedan 4.
    assert.strictEqual(adv.length, 4);
    // Los 3 "alto" (frenos/seguridad) antes que el "bajo" (luces).
    assert.deepStrictEqual(
      adv.map((a) => a.severidad),
      ['alto', 'alto', 'alto', 'bajo'],
    );
    // El de luces queda último.
    assert.strictEqual(adv[3].id, 'POSITION_LIGHTS');
  });

  test('todo OFF/INFO → lista vacía (unidad sana)', () => {
    const adv = clasificarAdvertencias([
      { id: 'ABS_TRAILER', estado: 'OFF' },
      { id: 'PARKING_BRAKE', estado: 'INFO' },
      { id: 'ENGINE_OIL', estado: 'OFF' },
    ]);
    assert.deepStrictEqual(adv, []);
  });

  test('RED ordena antes que YELLOW alto', () => {
    const adv = clasificarAdvertencias([
      { id: 'ABS_TRAILER', estado: 'YELLOW' }, // alto
      { id: 'ENGINE_OIL', estado: 'RED' }, // critico
    ]);
    assert.strictEqual(adv[0].id, 'ENGINE_OIL');
    assert.strictEqual(adv[0].severidad, 'critico');
    assert.strictEqual(adv[1].severidad, 'alto');
  });

  test('robusto ante entradas basura', () => {
    const adv = clasificarAdvertencias([
      null,
      { id: '', estado: 'RED' },
      { id: 'ENGINE_OIL', estado: 'RED' },
    ]);
    assert.strictEqual(adv.length, 1);
    assert.strictEqual(adv[0].id, 'ENGINE_OIL');
  });

  test('lista vacía / undefined no rompe', () => {
    assert.deepStrictEqual(clasificarAdvertencias([]), []);
    assert.deepStrictEqual(clasificarAdvertencias(undefined), []);
  });
});
