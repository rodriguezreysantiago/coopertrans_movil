// Tests del builder de resumen diario de alertas Volvo.
//
// Foco: que los eventos GENERIC se desambiguen por subTipo
// (SEATBELT, TELL_TALE, etc.) en lugar de mostrarse todos como
// "Evento genérico". Este bug se reportó el 2026-05-07: el resumen
// diario llegaba con 90+ líneas "Evento genérico" sin info útil.

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const {
  buildResumenDiario,
  ETIQUETAS_TIPO,
} = require('../src/aviso_alertas_volvo_builder');

function ev(overrides = {}) {
  return {
    patente: 'AB123CD',
    tipo: 'OVERSPEED',
    subTipo: null,
    choferNombre: 'Juan',
    fechaHora: new Date('2026-05-07T14:23:00-03:00'),
    ...overrides,
  };
}

describe('buildResumenDiario — GENERIC con subTipo', () => {
  test('GENERIC + subTipo SEATBELT muestra "Cinturón de seguridad sin abrochar"', () => {
    const msg = buildResumenDiario({
      destinatarioNombre: 'Santi',
      eventos: [ev({ tipo: 'GENERIC', subTipo: 'SEATBELT' })],
    });
    assert.match(msg, /Cinturón de seguridad sin abrochar/);
    assert.doesNotMatch(msg, /Evento genérico/);
  });

  test('GENERIC + subTipo TELL_TALE muestra "Luz de tablero encendida"', () => {
    const msg = buildResumenDiario({
      destinatarioNombre: 'Santi',
      eventos: [ev({ tipo: 'GENERIC', subTipo: 'TELL_TALE' })],
    });
    assert.match(msg, /Luz de tablero encendida/);
  });

  test('GENERIC sin subTipo (fallback) muestra "Evento genérico"', () => {
    const msg = buildResumenDiario({
      destinatarioNombre: 'Santi',
      eventos: [ev({ tipo: 'GENERIC', subTipo: null })],
    });
    assert.match(msg, /Evento genérico/);
  });

  test('eventos con tipo directo (no GENERIC) usan ETIQUETAS_TIPO[tipo]', () => {
    const msg = buildResumenDiario({
      destinatarioNombre: 'Santi',
      eventos: [
        ev({ tipo: 'OVERSPEED' }),
        ev({ tipo: 'IDLING' }),
        ev({ tipo: 'DAS' }),
      ],
    });
    assert.match(msg, /Exceso de velocidad/);
    assert.match(msg, /Motor en ralentí/);
    assert.match(msg, /Alerta de cansancio/);
  });

  test('subtipo desconocido cae al código crudo (no se rompe)', () => {
    const msg = buildResumenDiario({
      destinatarioNombre: 'Santi',
      eventos: [ev({ tipo: 'GENERIC', subTipo: 'NUEVO_TIPO_DE_VOLVO' })],
    });
    assert.match(msg, /NUEVO_TIPO_DE_VOLVO/);
  });

  test('agrupación: 3 GENERIC con mismo subTipo SEATBELT → "3x Cinturón..."', () => {
    const eventos = [1, 2, 3].map((h) => ev({
      tipo: 'GENERIC',
      subTipo: 'SEATBELT',
      fechaHora: new Date(`2026-05-07T1${h}:00:00-03:00`),
    }));
    const msg = buildResumenDiario({
      destinatarioNombre: 'Santi',
      eventos,
    });
    assert.match(msg, /3x Cinturón de seguridad sin abrochar/);
  });

  test('agrupación separa GENERIC por subTipo: SEATBELT ≠ TELL_TALE', () => {
    const eventos = [
      ev({ tipo: 'GENERIC', subTipo: 'SEATBELT', fechaHora: new Date('2026-05-07T10:00:00-03:00') }),
      ev({ tipo: 'GENERIC', subTipo: 'SEATBELT', fechaHora: new Date('2026-05-07T11:00:00-03:00') }),
      ev({ tipo: 'GENERIC', subTipo: 'TELL_TALE', fechaHora: new Date('2026-05-07T12:00:00-03:00') }),
    ];
    const msg = buildResumenDiario({
      destinatarioNombre: 'Santi',
      eventos,
    });
    // 2 lineas distintas, no agrupadas
    assert.match(msg, /2x Cinturón de seguridad sin abrochar/);
    assert.match(msg, /Luz de tablero encendida/);
  });
});

describe('buildResumenDiario — sin eventos / saludo', () => {
  // Decisión Santiago 2026-05-09: el contrato cambió de "devolver null
  // cuando no hay eventos" a "siempre devolver mensaje (con cuerpo
  // 'sin novedades' cuando vacío)". El silencio era ambiguo —
  // confirmar con un mensaje elimina la duda "¿no había nada o falló
  // el cron?".
  test('eventos vacíos → mensaje "sin novedades" (no null)', () => {
    const msg = buildResumenDiario({ destinatarioNombre: 'X', eventos: [] });
    assert.match(msg, /Sin eventos críticos en las últimas 24h/);
    assert.match(msg, /Hola X/);
  });

  test('saludo usa el nombre cuando viene', () => {
    const msg = buildResumenDiario({
      destinatarioNombre: 'Santi',
      eventos: [ev()],
    });
    assert.match(msg, /Hola Santi/);
  });

  test('saludo neutral cuando no hay nombre', () => {
    const msg = buildResumenDiario({
      destinatarioNombre: null,
      eventos: [ev()],
    });
    assert.match(msg, /^Hola\./m);
  });
});

describe('ETIQUETAS_TIPO contiene los códigos esperados', () => {
  test('SEATBELT está mapeado (regresión 2026-05-07)', () => {
    assert.ok(ETIQUETAS_TIPO.SEATBELT, 'SEATBELT debe estar en el mapa');
    assert.match(ETIQUETAS_TIPO.SEATBELT, /Cinturón/i);
  });
});
