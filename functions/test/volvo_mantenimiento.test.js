// Tests del builder PURO del parte de mantenimiento a Emmanuel (#43).
// Lockea el formato del mensaje y el orden (peor severidad primero).

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  construirParteMantenimiento,
} = require('../lib/volvo_mantenimiento');

const adv = (id, nombre, categoria, estado, severidad) => ({
  id, nombre, categoria, estado, severidad,
});

describe('construirParteMantenimiento', () => {
  test('sin unidades → mensaje "sin advertencias"', () => {
    const m = construirParteMantenimiento([], 'Hola Emmanuel', '21/05/2026');
    assert.match(m, /Sin advertencias/);
    assert.match(m, /Hola Emmanuel/);
    assert.match(m, /21\/05\/2026/);
  });

  test('una unidad con advertencias lista los testigos en español', () => {
    const unidades = [
      {
        patente: 'AF869ZU',
        advertencias: [
          adv('ABS_TRAILER', 'ABS del acoplado', 'frenos', 'YELLOW', 'alto'),
          adv('POSITION_LIGHTS', 'Luces de posición', 'luces', 'YELLOW', 'bajo'),
        ],
      },
    ];
    const m = construirParteMantenimiento(unidades, 'Hola', '21/05/2026');
    assert.match(m, /AF869ZU/);
    assert.match(m, /ABS del acoplado/);
    assert.match(m, /Luces de posición/);
    assert.match(m, /1 camión con advertencias/);
  });

  test('ordena unidades por peor severidad (crítico primero)', () => {
    const unidades = [
      {
        patente: 'BBB111',
        advertencias: [adv('POSITION_LIGHTS', 'Luces de posición', 'luces', 'YELLOW', 'bajo')],
      },
      {
        patente: 'AAA999',
        advertencias: [adv('ENGINE_OIL', 'Aceite de motor', 'motor', 'RED', 'critico')],
      },
    ];
    const m = construirParteMantenimiento(unidades, 'Hola', '21/05/2026');
    // La unidad con crítico (AAA999) debe aparecer ANTES que la de bajo (BBB111).
    assert.ok(
      m.indexOf('AAA999') < m.indexOf('BBB111'),
      'la unidad crítica debe ir primero',
    );
    assert.match(m, /1 con falla crítica/);
    assert.match(m, /2 camiones con advertencias/);
  });

  test('emojis por severidad presentes', () => {
    const unidades = [
      {
        patente: 'AAA999',
        advertencias: [adv('ENGINE_OIL', 'Aceite de motor', 'motor', 'RED', 'critico')],
      },
    ];
    const m = construirParteMantenimiento(unidades, 'Hola', '21/05/2026');
    assert.ok(m.includes('🔴'), 'debe incluir el emoji crítico');
  });

  test('cobertura parcial → avisa cuántos camiones NO transmiten testigos', () => {
    // Caso real: 20 de 53 monitoreados → no dar falsa tranquilidad.
    const unidades = [
      {
        patente: 'AF869ZU',
        advertencias: [adv('ABS_TRAILER', 'ABS del acoplado', 'frenos', 'YELLOW', 'alto')],
      },
    ];
    const m = construirParteMantenimiento(unidades, 'Hola', '21/05/2026', {
      monitoreadas: 20,
      total: 53,
    });
    assert.match(m, /Monitoreados 20\/53/);
    assert.match(m, /33 todavía no transmiten/);
  });

  test('cobertura parcial sin advertencias → igual avisa el gap', () => {
    const m = construirParteMantenimiento([], 'Hola', '21/05/2026', {
      monitoreadas: 20,
      total: 53,
    });
    assert.match(m, /Sin advertencias/);
    assert.match(m, /33 todavía no transmiten/);
  });

  test('cobertura total → nota simple sin alarma', () => {
    const m = construirParteMantenimiento([], 'Hola', '21/05/2026', {
      monitoreadas: 53,
      total: 53,
    });
    assert.match(m, /Monitoreados 53\/53/);
    assert.doesNotMatch(m, /no transmiten/);
  });

  test('sin cobertura (undefined) → no rompe (compat)', () => {
    const m = construirParteMantenimiento([], 'Hola', '21/05/2026');
    assert.match(m, /Sin advertencias/);
  });
});
