// Tests de las funciones PURAS del envoltorio de I/O del registro v3
// (jornadas_v3_batch.ts): mapeo SITRACK_EVENTOS → EventoJornadaLite, fecha/doc
// id determinístico, agrupar+reconstruir y serialización a Firestore. La capa de
// I/O real (procesarVentana / cron / backfill) usa Firestore y no se testea acá.
//
// Estrategia: igual que el resto — testear el compilado lib/. Requerir el módulo
// carga ./index → ./setup (initializeApp), igual que jornada_historico.test.js;
// las funciones puras no tocan la red.

const { test, describe } = require('node:test');
const assert = require('node:assert');
const { Timestamp } = require('firebase-admin/firestore');

const {
  mapearDocEvento,
  fechaArt,
  docIdRegistro,
  agruparYReconstruir,
  registroToFirestore,
} = require('../lib/jornadas_v3_batch');

// Doc estilo SITRACK_EVENTOS (campos del poller). `in` respeta null/0 explícito.
function doc(over = {}) {
  const pick = (k, def) => (k in over ? over[k] : def);
  return {
    driver_dni: pick('dni', 'A'),
    asset_id: pick('pat', 'AAA111'),
    report_date: Timestamp.fromMillis(over.ms),
    event_id: pick('id', 283),
    event_name: pick('name', 'Cambio de curso'),
    speed: pick('sp', 70),
    gps_speed: pick('gsp', pick('sp', 70)),
    ignition: pick('ign', 1),
    latitude: pick('lat', -38.0),
    longitude: pick('lng', -68.0),
    gps_validity: pick('val', 32),
  };
}

const MIN = 60 * 1000;

describe('v3 batch — mapearDocEvento', () => {
  test('mapea los campos del doc SITRACK_EVENTOS', () => {
    const ms = Date.UTC(2026, 5, 6, 13, 0, 0);
    const e = mapearDocEvento({
      report_date: Timestamp.fromMillis(ms),
      event_id: 164, event_name: 'Contacto OFF',
      speed: 0, gps_speed: 0, ignition: 0,
      latitude: -34.7, longitude: -60.9, gps_validity: 32,
    });
    assert.equal(e.ms, ms);
    assert.equal(e.eventId, 164);
    assert.equal(e.eventName, 'Contacto OFF');
    assert.equal(e.speed, 0);
    assert.equal(e.ignition, 0);
    assert.equal(e.lat, -34.7);
    assert.equal(e.gpsValidity, 32);
  });

  test('acepta report_date como Date o epoch ms, no solo Timestamp', () => {
    const ms = Date.UTC(2026, 5, 6, 13, 0, 0);
    assert.equal(mapearDocEvento({ report_date: new Date(ms) }).ms, ms);
    assert.equal(mapearDocEvento({ report_date: ms }).ms, ms);
  });

  test('campos ausentes → null; sin fecha → null entero', () => {
    const e = mapearDocEvento({ report_date: Timestamp.fromMillis(0) });
    assert.equal(e.eventId, null);
    assert.equal(e.speed, null);
    assert.equal(e.ignition, null);
    assert.equal(e.lat, null);
    assert.equal(mapearDocEvento({}), null);
  });

  test('ignition solo 0/1; cualquier otra cosa → null', () => {
    assert.equal(mapearDocEvento({ report_date: 1, ignition: 0 }).ignition, 0);
    assert.equal(mapearDocEvento({ report_date: 1, ignition: 1 }).ignition, 1);
    assert.equal(
      mapearDocEvento({ report_date: 1, ignition: true }).ignition, null);
  });
});

describe('v3 batch — fechaArt / docIdRegistro', () => {
  test('fechaArt da YYYY-MM-DD en hora Argentina', () => {
    // 03:00 UTC = 00:00 ART del 6/6 → "2026-06-06".
    assert.equal(fechaArt(Date.UTC(2026, 5, 6, 3, 0, 0)), '2026-06-06');
    // 02:59 UTC = 23:59 ART del 5/6 → "2026-06-05" (borde de medianoche).
    assert.equal(fechaArt(Date.UTC(2026, 5, 6, 2, 59, 0)), '2026-06-05');
  });

  test('docIdRegistro = dni_fecha (determinístico → idempotente)', () => {
    const ms = Date.UTC(2026, 5, 6, 13, 0, 0); // 10:00 ART del 6/6
    assert.equal(docIdRegistro('26129762', ms), '26129762_2026-06-06');
    // El prefijo antes del '_' es el DNI → la regla de Firestore se lo da al
    // chofer dueño (doc.split('_')[0] == uid), igual que VOLVO_JORNADAS_HISTORICO.
    assert.equal(docIdRegistro('26129762', ms).split('_')[0], '26129762');
  });
});

describe('v3 batch — agruparYReconstruir', () => {
  // Chofer A: manejo continuo. Chofer B: pausa por Contacto OFF de 20 min.
  const t0 = Date.UTC(2026, 5, 6, 13, 0, 0); // 10:00 ART
  const docs = [];
  // A — 10 reportes cada 5 min, avanzando (sin pausas).
  for (let i = 0; i < 10; i++) {
    docs.push(doc({ dni: 'A', pat: 'AAA111', ms: t0 + i * 5 * MIN,
      sp: 72, lat: -38.0 + i * 0.02, lng: -68.0 }));
  }
  // B — maneja, Contacto OFF 20 min, Fin de detenido, sigue.
  docs.push(doc({ dni: 'B', pat: 'BBB222', ms: t0, sp: 70, lat: -39.0 }));
  docs.push(doc({ dni: 'B', pat: 'BBB222', ms: t0 + 10 * MIN, sp: 70,
    lat: -39.05 }));
  docs.push(doc({ dni: 'B', pat: 'BBB222', ms: t0 + 20 * MIN, id: 164, sp: 0,
    ign: 0, lat: -39.10 }));
  docs.push(doc({ dni: 'B', pat: 'BBB222', ms: t0 + 40 * MIN, id: 7, sp: 55,
    lat: -39.10 }));
  docs.push(doc({ dni: 'B', pat: 'BBB222', ms: t0 + 50 * MIN, sp: 70,
    lat: -39.15 }));

  const entradas = agruparYReconstruir(docs);

  test('una entrada por chofer (con su patente principal)', () => {
    assert.equal(entradas.length, 2);
    const a = entradas.find((e) => e.dni === 'A');
    const b = entradas.find((e) => e.dni === 'B');
    assert.equal(a.patente, 'AAA111');
    assert.equal(b.patente, 'BBB222');
  });

  test('A sin pausas; B con la pausa por Contacto OFF detectada', () => {
    const a = entradas.find((e) => e.dni === 'A');
    const b = entradas.find((e) => e.dni === 'B');
    assert.equal(a.registro.pausas.length, 0);
    const p = b.registro.pausas.find((x) => x.origen === 'contacto_off');
    assert.ok(p, 'B debe tener la pausa por contacto_off');
    assert.equal(p.durSeg, 20 * 60);
    assert.equal(p.cierraBloque, true);
  });

  test('docs sin driver_dni o sin fecha se ignoran', () => {
    const sucio = [
      doc({ dni: '', ms: t0 }),
      { driver_dni: 'C', asset_id: 'CCC' }, // sin report_date
    ];
    assert.equal(agruparYReconstruir(sucio).length, 0);
  });
});

describe('v3 batch — registroToFirestore', () => {
  const t0 = Date.UTC(2026, 5, 6, 13, 0, 0);
  const docs = [];
  docs.push(doc({ dni: 'B', pat: 'BBB222', ms: t0, sp: 70, lat: -39.0 }));
  docs.push(doc({ dni: 'B', pat: 'BBB222', ms: t0 + 10 * MIN, sp: 70,
    lat: -39.05 }));
  docs.push(doc({ dni: 'B', pat: 'BBB222', ms: t0 + 20 * MIN, id: 164, sp: 0,
    ign: 0, lat: -39.10 }));
  docs.push(doc({ dni: 'B', pat: 'BBB222', ms: t0 + 40 * MIN, id: 7, sp: 55,
    lat: -39.10 }));
  docs.push(doc({ dni: 'B', pat: 'BBB222', ms: t0 + 50 * MIN, sp: 70,
    lat: -39.15 }));
  const { dni, patente, registro } = agruparYReconstruir(docs)[0];
  const fs = registroToFirestore(dni, patente, registro);

  test('forma del doc: metadatos + version 3 + fecha ART', () => {
    assert.equal(fs.version, 3);
    assert.equal(fs.chofer_dni, 'B');
    assert.equal(fs.patente, 'BBB222');
    assert.equal(fs.fecha, '2026-06-06');
    assert.equal(typeof fs.manejo_neto_seg, 'number');
    assert.equal(typeof fs.confianza, 'string');
    assert.ok(Array.isArray(fs.explicacion) && fs.explicacion.length > 0);
  });

  test('tiempos serializados como Timestamp (no ms crudos)', () => {
    assert.ok(fs.inicio_turno instanceof Timestamp);
    assert.ok(fs.fin_turno instanceof Timestamp);
    assert.equal(fs.inicio_turno.toMillis(), registro.inicioTurnoMs);
  });

  test('pausas/segmentos/bloques se serializan con Timestamp', () => {
    assert.ok(Array.isArray(fs.pausas) && fs.pausas.length >= 1);
    const p = fs.pausas[0];
    assert.ok(p.inicio instanceof Timestamp);
    assert.equal(typeof p.dur_seg, 'number');
    assert.equal(typeof p.cierra_bloque, 'boolean');
    assert.ok(Array.isArray(fs.segmentos) && fs.segmentos.length >= 1);
    assert.ok(fs.segmentos[0].inicio instanceof Timestamp);
    assert.ok(Array.isArray(fs.bloques) && fs.bloques.length >= 1);
    assert.ok(fs.bloques[0].inicio instanceof Timestamp);
  });

  test('procesado_en presente (FieldValue sentinel)', () => {
    assert.ok(fs.procesado_en != null);
  });
});
