// Tests del builder PURO del parte de mantenimiento a Emmanuel (#43).
// Lockea el formato del mensaje y el orden (peor severidad primero).

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  construirParteMantenimiento,
  clasificarEventoMant,
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

// Eventos de neumáticos / tacógrafo (VOLVO_ALERTAS) que se sumaron al Parte
// el 2026-05-22 al dejar de mandar el resumen duplicado del bot a Emmanuel.
const evt = (tipo, nombre, severidad, fechaHora) => ({
  tipo, nombre, severidad, fechaHora,
});

describe('clasificarEventoMant', () => {
  test('reconoce TPM / TTM / tacho directos con su severidad', () => {
    assert.equal(clasificarEventoMant('TPM', null).nombre, 'Presión de neumático');
    assert.equal(clasificarEventoMant('TPM', null).severidad, 'alto');
    assert.equal(clasificarEventoMant('TTM', null).severidad, 'alto');
    assert.equal(
      clasificarEventoMant('TACHO_OUT_OF_SCOPE_MODE_CHANGE', null).severidad,
      'medio',
    );
  });

  test('lee el subtipo de GENERIC (triggerType o type)', () => {
    assert.equal(clasificarEventoMant('GENERIC', { triggerType: 'TPM' }).tipo, 'TPM');
    assert.equal(clasificarEventoMant('GENERIC', { type: 'TTM' }).tipo, 'TTM');
  });

  test('ignora tipos que no son de mantenimiento', () => {
    assert.equal(clasificarEventoMant('OVERSPEED', null), null);
    assert.equal(clasificarEventoMant('GENERIC', { triggerType: 'SEATBELT' }), null);
    assert.equal(clasificarEventoMant(null, null), null);
  });
});

describe('construirParteMantenimiento — eventos de neumáticos / tacógrafo', () => {
  test('incluye el evento con su horario en ART', () => {
    const unidades = [{
      patente: 'AF235AB',
      advertencias: [],
      eventos: [
        evt('TPM', 'Presión de neumático', 'alto',
          new Date('2026-05-21T14:23:00-03:00')),
      ],
    }];
    const m = construirParteMantenimiento(unidades, 'Hola', '21/05/2026');
    assert.match(m, /AF235AB/);
    assert.match(m, /Presión de neumático \(14:23\)/);
  });

  test('condensa eventos repetidos del mismo tipo (Nx + horarios)', () => {
    const unidades = [{
      patente: 'AF235AB',
      advertencias: [],
      eventos: [
        evt('TPM', 'Presión de neumático', 'alto', new Date('2026-05-21T14:23:00-03:00')),
        evt('TPM', 'Presión de neumático', 'alto', new Date('2026-05-21T17:08:00-03:00')),
      ],
    }];
    const m = construirParteMantenimiento(unidades, 'Hola', '21/05/2026');
    assert.match(m, /2x Presión de neumático \(14:23 \/ 17:08\)/);
  });

  test('una unidad con SOLO eventos (sin testigo) igual aparece', () => {
    const unidades = [{
      patente: 'AH490YK',
      advertencias: [],
      eventos: [
        evt('TACHO_OUT_OF_SCOPE_MODE_CHANGE', 'Tacógrafo fuera de servicio', 'medio',
          new Date('2026-05-21T09:10:00-03:00')),
      ],
    }];
    const m = construirParteMantenimiento(unidades, 'Hola', '21/05/2026');
    assert.match(m, /AH490YK/);
    assert.match(m, /Tacógrafo fuera de servicio \(09:10\)/);
    assert.match(m, /1 camión con advertencias/);
  });

  test('testigo crítico ordena por encima de unidad con solo evento medio', () => {
    const unidades = [
      {
        patente: 'EVT001',
        advertencias: [],
        eventos: [evt('TACHO_OUT_OF_SCOPE_MODE_CHANGE', 'Tacógrafo fuera de servicio', 'medio',
          new Date('2026-05-21T09:10:00-03:00'))],
      },
      {
        patente: 'CRIT99',
        advertencias: [adv('ENGINE_OIL', 'Aceite de motor', 'motor', 'RED', 'critico')],
      },
    ];
    const m = construirParteMantenimiento(unidades, 'Hola', '21/05/2026');
    assert.ok(
      m.indexOf('CRIT99') < m.indexOf('EVT001'),
      'la unidad crítica debe ir antes que la de evento medio',
    );
  });

  test('testigos del tablero y eventos conviven en el mismo bloque', () => {
    const unidades = [{
      patente: 'AF235AB',
      advertencias: [adv('EBS', 'Frenos electrónicos (EBS)', 'frenos', 'YELLOW', 'alto')],
      eventos: [evt('TPM', 'Presión de neumático', 'alto',
        new Date('2026-05-21T14:23:00-03:00'))],
    }];
    const m = construirParteMantenimiento(unidades, 'Hola', '21/05/2026');
    assert.match(m, /Frenos electrónicos \(EBS\)/);
    assert.match(m, /Presión de neumático \(14:23\)/);
  });
});
