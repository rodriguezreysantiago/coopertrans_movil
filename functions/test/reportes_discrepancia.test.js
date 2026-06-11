// Tests de la devolución por WhatsApp al chofer cuando se resuelve su reclamo
// (REPORTES_DISCREPANCIA). Cubre las dos funciones PURAS: la condición de
// disparo (debeEnviarDevolucion) y el armado del texto (construirMensajeDevolucion).
// El envío real (leer EMPLEADOS + encolar en COLA_WHATSAPP) NO se testea acá
// (necesitaría emulator); la lógica decisiva vive en estas dos funciones.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  debeEnviarDevolucion,
  construirMensajeDevolucion,
} = require('../lib/reportes_discrepancia');

describe('debeEnviarDevolucion — cuándo se avisa al chofer', () => {
  const after = { estado: 'revisado', veredicto: 'cierto', detalle: 'paré 20 min', chofer_dni: '30' };

  test('pendiente → revisado/cierto (reclamo directo) → SÍ', () => {
    assert.strictEqual(debeEnviarDevolucion({ estado: 'pendiente' }, after), true);
  });
  test('pendiente → revisado/no_cierto → SÍ', () => {
    assert.strictEqual(debeEnviarDevolucion({ estado: 'pendiente' }, { ...after, veredicto: 'no_cierto' }), true);
  });
  test('ya revisado, MISMO veredicto (editar la nota) → NO (no re-manda)', () => {
    assert.strictEqual(debeEnviarDevolucion({ estado: 'revisado', veredicto: 'cierto' }, after), false);
  });
  test('reabierto y re-resuelto con OTRO veredicto → SÍ (corrección)', () => {
    assert.strictEqual(debeEnviarDevolucion({ estado: 'revisado', veredicto: 'no_cierto' }, after), true);
  });
  test('auto-generado de parada → NO (detalle técnico, no citable)', () => {
    assert.strictEqual(debeEnviarDevolucion({ estado: 'pendiente' }, { ...after, origen: 'parada_reportada_auto' }), false);
  });
  test('revisado SIN veredicto → NO', () => {
    assert.strictEqual(debeEnviarDevolucion({ estado: 'pendiente' }, { estado: 'revisado', detalle: 'x', chofer_dni: '30' }), false);
  });
  test('sin detalle o sin dni → NO', () => {
    assert.strictEqual(debeEnviarDevolucion({ estado: 'pendiente' }, { ...after, detalle: '' }), false);
    assert.strictEqual(debeEnviarDevolucion({ estado: 'pendiente' }, { ...after, chofer_dni: '' }), false);
  });
  test('reabrir (revisado → pendiente) → NO', () => {
    assert.strictEqual(debeEnviarDevolucion({ estado: 'revisado', veredicto: 'cierto' }, { estado: 'pendiente' }), false);
  });
  test('after vacío/undefined → NO (defensivo)', () => {
    assert.strictEqual(debeEnviarDevolucion({ estado: 'pendiente' }, undefined), false);
  });
});

describe('construirMensajeDevolucion — texto al chofer', () => {
  const com = { saludoNombre: 'Rodo', detalle: 'paré 20 min y no figura', nota: '', fechaRec: '11/06' };

  test('cierto: saluda, CITA el reclamo, le da la razón y firma', () => {
    const m = construirMensajeDevolucion({ ...com, veredicto: 'cierto' });
    assert.match(m, /Hola Rodo/);
    assert.match(m, /tu reclamo del 11\/06/);
    assert.match(m, /paré 20 min y no figura/); // cita literal
    assert.match(m, /Tenías razón/);
    assert.match(m, /Bot-On — Coopertrans Móvil/);
  });
  test('cierto CON nota del revisor: usa la nota en vez del genérico', () => {
    const m = construirMensajeDevolucion({ ...com, veredicto: 'cierto', nota: 'el GPS confirma la pausa 18:50-19:17' });
    assert.match(m, /el GPS confirma la pausa/);
  });
  test('no_cierto: dato correcto, NO acusa, igual agradece', () => {
    const m = construirMensajeDevolucion({ ...com, veredicto: 'no_cierto' });
    assert.match(m, /figura correcto/);
    assert.match(m, /gracias por avisar/i);
    assert.doesNotMatch(m, /Tenías razón/);
  });
  test('sin saludoNombre → "Hola" pelado, sigue citando', () => {
    const m = construirMensajeDevolucion({ ...com, saludoNombre: '', veredicto: 'cierto' });
    assert.match(m, /^Hola, revisamos tu reclamo/);
  });
  test('sin fechaRec → no escribe " del " colgando', () => {
    const m = construirMensajeDevolucion({ ...com, fechaRec: '', veredicto: 'cierto' });
    assert.match(m, /revisamos tu reclamo:/);
    assert.doesNotMatch(m, /del \n/);
  });
});
