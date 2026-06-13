// Tests de las funciones puras del archivo frío (archivo_frio.ts). La lógica de
// I/O (query paginada + upload a GCS) NO se testea acá (necesita emulador/GCS);
// se cubre la lógica PURA: ventana del mes anterior + serialización NDJSON.
const { test, describe } = require('node:test');
const assert = require('node:assert');
const { Timestamp } = require('firebase-admin/firestore');
const { ventanaMesAnterior, ventanaDeMes, serializarDoc } = require('../lib/index');

describe('ventanaMesAnterior', () => {
  test('mes normal: julio → junio', () => {
    const r = ventanaMesAnterior(new Date(Date.UTC(2026, 6, 5))); // 2026-07-05
    assert.strictEqual(r.etiqueta, '2026-06');
    assert.strictEqual(r.inicio.toISOString(), '2026-06-01T00:00:00.000Z');
    assert.strictEqual(r.finExclusivo.toISOString(), '2026-07-01T00:00:00.000Z');
  });
  test('cruce de año: enero → diciembre del año anterior', () => {
    const r = ventanaMesAnterior(new Date(Date.UTC(2026, 0, 15))); // 2026-01-15
    assert.strictEqual(r.etiqueta, '2025-12');
    assert.strictEqual(r.inicio.toISOString(), '2025-12-01T00:00:00.000Z');
    assert.strictEqual(r.finExclusivo.toISOString(), '2026-01-01T00:00:00.000Z');
  });
  test('primer día del mes: marzo 1 → febrero', () => {
    const r = ventanaMesAnterior(new Date(Date.UTC(2026, 2, 1))); // 2026-03-01
    assert.strictEqual(r.etiqueta, '2026-02');
    assert.strictEqual(r.inicio.toISOString(), '2026-02-01T00:00:00.000Z');
    assert.strictEqual(r.finExclusivo.toISOString(), '2026-03-01T00:00:00.000Z');
  });
  test('último instante del mes cae en el mismo mes anterior', () => {
    const r = ventanaMesAnterior(new Date(Date.UTC(2026, 6, 31, 23, 59, 59))); // 2026-07-31
    assert.strictEqual(r.etiqueta, '2026-06');
  });
});

describe('ventanaDeMes (catch-up: offset 1 = M-1, offset 2 = M-2)', () => {
  test('offset 1 == mes anterior', () => {
    const ahora = new Date(Date.UTC(2026, 6, 5)); // 2026-07-05
    assert.strictEqual(ventanaDeMes(ahora, 1).etiqueta, '2026-06');
    assert.strictEqual(ventanaDeMes(ahora, 2).etiqueta, '2026-05'); // M-2 catch-up
  });
  test('offset 2 cruza el año hacia atrás (enero → noviembre)', () => {
    const ahora = new Date(Date.UTC(2026, 0, 5)); // 2026-01-05
    assert.strictEqual(ventanaDeMes(ahora, 1).etiqueta, '2025-12');
    assert.strictEqual(ventanaDeMes(ahora, 2).etiqueta, '2025-11');
    const m2 = ventanaDeMes(ahora, 2);
    assert.strictEqual(m2.inicio.toISOString(), '2025-11-01T00:00:00.000Z');
    assert.strictEqual(m2.finExclusivo.toISOString(), '2025-12-01T00:00:00.000Z');
  });
  test('ventanas M-1 y M-2 son contiguas y no se solapan', () => {
    const ahora = new Date(Date.UTC(2026, 2, 10)); // 2026-03-10
    const m1 = ventanaDeMes(ahora, 1); // febrero
    const m2 = ventanaDeMes(ahora, 2); // enero
    assert.strictEqual(m2.finExclusivo.toISOString(), m1.inicio.toISOString());
  });
});

describe('serializarDoc', () => {
  test('convierte Timestamp a ISO y agrega _id', () => {
    const ts = Timestamp.fromDate(new Date('2026-06-15T10:30:00.000Z'));
    const obj = JSON.parse(
      serializarDoc('rep-1', { report_date: ts, speed: 80, location: 'YPF' }),
    );
    assert.strictEqual(obj._id, 'rep-1');
    assert.strictEqual(obj.report_date, '2026-06-15T10:30:00.000Z');
    assert.strictEqual(obj.speed, 80);
    assert.strictEqual(obj.location, 'YPF');
  });
  test('preserva null, números y strings vacíos', () => {
    const obj = JSON.parse(
      serializarDoc('x', { latitude: null, event_id: 12, driver_dni: '' }),
    );
    assert.strictEqual(obj.latitude, null);
    assert.strictEqual(obj.event_id, 12);
    assert.strictEqual(obj.driver_dni, '');
  });
  test('cada línea es JSON válido y no tiene saltos (NDJSON)', () => {
    const l = serializarDoc('a', { x: 1, y: 'z' });
    assert.doesNotThrow(() => JSON.parse(l));
    assert.ok(!l.includes('\n'), 'una línea por doc');
  });
});
