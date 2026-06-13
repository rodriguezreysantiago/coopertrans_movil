// Tests de la lógica PURA del reporte de estadía en plantas YPF
// (reporte_estadia.ts). El I/O (query a ZONA_DESCARGA_HISTORICO + encolar
// WhatsApp) NO se testea acá.
const { test, describe } = require('node:test');
const assert = require('node:assert');
const {
  franjaDeHora,
  computarReporteEstadia,
  formatearMensajeEstadia,
  ventanaSemanaAnterior,
} = require('../lib/index');

describe('franjaDeHora', () => {
  test('buckets correctos', () => {
    assert.strictEqual(franjaDeHora(0), 'madrugada');
    assert.strictEqual(franjaDeHora(5), 'madrugada');
    assert.strictEqual(franjaDeHora(6), 'mañana');
    assert.strictEqual(franjaDeHora(11), 'mañana');
    assert.strictEqual(franjaDeHora(12), 'tarde');
    assert.strictEqual(franjaDeHora(17), 'tarde');
    assert.strictEqual(franjaDeHora(18), 'noche');
    assert.strictEqual(franjaDeHora(23), 'noche');
  });
  test('fuera de rango → desconocida', () => {
    assert.strictEqual(franjaDeHora(-1), 'desconocida');
    assert.strictEqual(franjaDeHora(24), 'desconocida');
  });
});

const rec = (slug, nombre, patente, horaArt, duracionMin) =>
  ({ slug, nombre, patente, choferNombre: 'X', horaArt, duracionMin });

describe('computarReporteEstadia', () => {
  const estadias = [
    rec('lc', 'Loma Campana', 'AAA111', 8, 60),
    rec('lc', 'Loma Campana', 'AAA111', 9, 180), // > umbral 120
    rec('lc', 'Loma Campana', 'BBB222', 14, 120), // == umbral (no cuenta como >)
    rec('vm', 'Vaca Muerta', 'AAA111', 20, 240), // > umbral
  ];

  test('por planta: promedio/máx/n/% sobre umbral, ordenado por promedio desc', () => {
    const r = computarReporteEstadia(estadias, 120);
    assert.strictEqual(r.totalEstadias, 4);
    // VM: promedio 240 > LC: promedio (60+180+120)/3=120 → VM primero
    assert.strictEqual(r.porPlanta[0].slug, 'vm');
    assert.strictEqual(r.porPlanta[0].promedioMin, 240);
    assert.strictEqual(r.porPlanta[0].pctSobreUmbral, 100);
    const lc = r.porPlanta.find((p) => p.slug === 'lc');
    assert.strictEqual(lc.n, 3);
    assert.strictEqual(lc.promedioMin, 120);
    assert.strictEqual(lc.maxMin, 180);
    // solo 1 de 3 (180) supera 120 estrictamente → 33%
    assert.strictEqual(lc.pctSobreUmbral, 33);
  });

  test('top unidades por minutos totales desc', () => {
    const r = computarReporteEstadia(estadias, 120);
    // AAA111: 60+180+240=480 ; BBB222: 120 → AAA111 primero
    assert.strictEqual(r.topUnidades[0].patente, 'AAA111');
    assert.strictEqual(r.topUnidades[0].totalMin, 480);
    assert.strictEqual(r.topUnidades[0].n, 3);
  });

  test('por franja en orden madrugada→noche', () => {
    const r = computarReporteEstadia(estadias, 120);
    const franjas = r.porFranja.map((f) => f.franja);
    // hay mañana (8,9), tarde (14), noche (20) → en ese orden
    assert.deepStrictEqual(franjas, ['mañana', 'tarde', 'noche']);
  });

  test('vacío no rompe', () => {
    const r = computarReporteEstadia([], 120);
    assert.strictEqual(r.totalEstadias, 0);
    assert.deepStrictEqual(r.porPlanta, []);
    assert.deepStrictEqual(r.topUnidades, []);
  });
});

describe('formatearMensajeEstadia', () => {
  test('sin estadías → mensaje claro', () => {
    const msg = formatearMensajeEstadia(
      computarReporteEstadia([], 120), 'semana X');
    assert.match(msg, /Sin estadías registradas/);
  });
  test('con data → incluye plantas y top unidades', () => {
    const r = computarReporteEstadia([
      rec('lc', 'Loma Campana', 'AAA111', 9, 180),
    ], 120);
    const msg = formatearMensajeEstadia(r, 'semana 09/06–15/06');
    assert.match(msg, /Loma Campana/);
    assert.match(msg, /AAA111/);
    assert.match(msg, /semana 09\/06–15\/06/);
  });
});

describe('ventanaSemanaAnterior', () => {
  test('un lunes → semana lunes-a-domingo anterior (ART)', () => {
    // Lunes 2026-06-15 09:00 ART = 12:00Z. Semana anterior = lun 08 → dom 14.
    const r = ventanaSemanaAnterior(new Date('2026-06-15T12:00:00.000Z'));
    assert.strictEqual(r.desde.toISOString(), '2026-06-08T03:00:00.000Z'); // lun 08 00:00 ART
    assert.strictEqual(r.hasta.toISOString(), '2026-06-15T03:00:00.000Z'); // lun 15 00:00 ART
    assert.match(r.label, /08\/06.*14\/06/);
  });
  test('rango es exactamente 7 días', () => {
    const r = ventanaSemanaAnterior(new Date('2026-06-15T12:00:00.000Z'));
    const dias = (r.hasta - r.desde) / 864e5;
    assert.strictEqual(dias, 7);
  });
});
