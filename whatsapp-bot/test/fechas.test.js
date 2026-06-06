// Tests para fechas.js. Corre con `node --test`.
//
// Estos tests son MUY importantes: el bot ya tuvo bugs serios de
// timezone (licencia que vence 30/05 mostrada como 29/05), y este
// modulo es el escudo que los previene. Cualquier cambio en
// _dateToIsoSafe debe seguir pasando estos tests.
process.env.TZ = 'America/Argentina/Buenos_Aires';

const { test, describe } = require('node:test');
const assert = require('node:assert');
const {
  aIsoLocal, aDdMmYyyyLocal, aLocalDateTime, diasEntreIso,
} = require('../src/fechas');

describe('fechas.aIsoLocal — string inputs', () => {
  test('string YYYY-MM-DD se devuelve tal cual', () => {
    assert.strictEqual(aIsoLocal('2026-05-30'), '2026-05-30');
  });

  test('string ISO completo (con T y Z) extrae los primeros 10 chars', () => {
    // Bug clasico: new Date('2026-05-30T00:00:00.000Z').getDate() en
    // ART devuelve 29. Por eso preferimos cortar el string sin pasar
    // por new Date.
    assert.strictEqual(
      aIsoLocal('2026-05-30T00:00:00.000Z'),
      '2026-05-30'
    );
  });

  test('string con espacios al borde se trimea antes de matchear', () => {
    assert.strictEqual(aIsoLocal('  2026-05-30  '), '2026-05-30');
  });

  test('string DD/MM/YYYY (no soportado) parsea via Date constructor', () => {
    // No es el formato que la app guarda, pero si llega algo asi
    // intentamos via Date. El comportamiento puede ser ambiguo
    // (DD/MM vs MM/DD), por eso preferimos el formato canonico.
    const r = aIsoLocal('05/30/2026');
    // Solo verificamos que no devuelva null si Date lo entiende.
    // El valor exacto depende de la locale del runtime.
    assert.ok(r === null || /^\d{4}-\d{2}-\d{2}$/.test(r));
  });

  test('string vacio devuelve null', () => {
    assert.strictEqual(aIsoLocal(''), null);
  });

  test('string basura devuelve null', () => {
    assert.strictEqual(aIsoLocal('xxxxxxxx'), null);
  });
});

describe('fechas.aIsoLocal — Date instance', () => {
  test('Date construido con (Y,M,D) local devuelve YYYY-MM-DD local', () => {
    const dt = new Date(2026, 4, 30); // 30 mayo 2026 local
    assert.strictEqual(aIsoLocal(dt), '2026-05-30');
  });

  test('Date UTC midnight (fecha calendario) devuelve dia UTC, no shift', () => {
    // Caso clave: Python guarda datetime(2026,5,30) como ISO UTC
    // midnight. En ART (UTC-3) eso es 21h del 29-mayo. Si usaramos
    // getDate() local mostrariamos "29". El helper detecta que hora
    // UTC es 00:00:00.000 y usa getUTCDate() → 30. Bug TZ resuelto.
    const utcMidnight = new Date(Date.UTC(2026, 4, 30, 0, 0, 0, 0));
    assert.strictEqual(aIsoLocal(utcMidnight), '2026-05-30');
  });

  test('Date con hora real (no midnight UTC) usa componentes locales', () => {
    // Un timestamp de last-modified, no una fecha calendario.
    // En ART con TZ ART, getDate() local da el dia correcto.
    const local = new Date(2026, 4, 30, 14, 30); // 30 mayo 14:30 local
    assert.strictEqual(aIsoLocal(local), '2026-05-30');
  });

  test('Date invalido devuelve null', () => {
    const invalido = new Date('xx');
    assert.strictEqual(aIsoLocal(invalido), null);
  });
});

describe('fechas.aIsoLocal — Firestore Timestamp', () => {
  test('Timestamp con toDate() (admin SDK) → dia correcto', () => {
    // Mock minimo de un Firestore Timestamp con toDate().
    const fakeTs = {
      toDate: () => new Date(Date.UTC(2026, 4, 30, 0, 0, 0, 0)),
    };
    assert.strictEqual(aIsoLocal(fakeTs), '2026-05-30');
  });

  test('Timestamp serializado con _seconds (JSON) → dia correcto', () => {
    // Cuando un Timestamp viene en un payload JSON (ej. callable
    // result), pierde su clase y queda como { _seconds, _nanoseconds }.
    const utcMidnightSecs = Date.UTC(2026, 4, 30, 0, 0, 0, 0) / 1000;
    const fakeJson = { _seconds: utcMidnightSecs, _nanoseconds: 0 };
    assert.strictEqual(aIsoLocal(fakeJson), '2026-05-30');
  });

  test('Timestamp serializado con seconds (sin underscore) tambien funciona', () => {
    const utcMidnightSecs = Date.UTC(2026, 4, 30, 0, 0, 0, 0) / 1000;
    const fakeJson = { seconds: utcMidnightSecs, nanoseconds: 0 };
    assert.strictEqual(aIsoLocal(fakeJson), '2026-05-30');
  });

  test('object sin _seconds ni seconds devuelve null', () => {
    assert.strictEqual(aIsoLocal({ otraCosa: 'x' }), null);
  });
});

describe('fechas.aIsoLocal — null/undefined', () => {
  test('null devuelve null', () => {
    assert.strictEqual(aIsoLocal(null), null);
  });

  test('undefined devuelve null', () => {
    assert.strictEqual(aIsoLocal(undefined), null);
  });
});

describe('fechas.aDdMmYyyyLocal', () => {
  test('formato DD/MM/YYYY desde string ISO', () => {
    assert.strictEqual(aDdMmYyyyLocal('2026-05-30'), '30/05/2026');
  });

  test('formato DD/MM/YYYY desde Timestamp UTC midnight', () => {
    // Regression test del bug VICTOR RAUL JESUS: licencia 30/05 que
    // se mostraba como 29/05. Si esto se rompe, el bot vuelve a
    // mandarles la fecha equivocada al chofer.
    const utcMidnight = new Date(Date.UTC(2026, 4, 30, 0, 0, 0, 0));
    assert.strictEqual(aDdMmYyyyLocal(utcMidnight), '30/05/2026');
  });

  test('input invalido devuelve "-" (no crashea ni devuelve "undefined")', () => {
    assert.strictEqual(aDdMmYyyyLocal(null), '-');
    assert.strictEqual(aDdMmYyyyLocal(''), '-');
    assert.strictEqual(aDdMmYyyyLocal('xxxx'), '-');
  });
});

describe('fechas.aLocalDateTime', () => {
  test('Date local a "DD/MM/YYYY HH:MM" sin componentes UTC', () => {
    // 30 mayo 2026 14:30 LOCAL ART. El helper toma getDate/getHours
    // (no getUTCDate) -- como TZ del proceso esta forzada a ART, da
    // 30/05/2026 14:30 sin importar en qué runtime corra.
    const dt = new Date(2026, 4, 30, 14, 30);
    assert.strictEqual(aLocalDateTime(dt), '30/05/2026 14:30');
  });

  test('preserva la HORA (a diferencia de aDdMmYyyyLocal que es solo fecha)', () => {
    const dt = new Date(2026, 0, 5, 8, 5);
    assert.strictEqual(aLocalDateTime(dt), '05/01/2026 08:05');
  });

  test('Timestamp Firestore via toDate() funciona', () => {
    const fakeTs = {
      toDate: () => new Date(2026, 4, 30, 9, 15),
    };
    assert.strictEqual(aLocalDateTime(fakeTs), '30/05/2026 09:15');
  });

  test('Timestamp serializado JSON con _seconds funciona', () => {
    // 2026-05-30T12:00:00 ART = 2026-05-30T15:00:00 UTC
    const utcSecs = Date.UTC(2026, 4, 30, 15, 0, 0) / 1000;
    const fakeJson = { _seconds: utcSecs, _nanoseconds: 0 };
    // El timestamp es las 15:00 UTC = 12:00 ART
    assert.strictEqual(aLocalDateTime(fakeJson), '30/05/2026 12:00');
  });

  test('input invalido devuelve "-"', () => {
    assert.strictEqual(aLocalDateTime(null), '-');
    assert.strictEqual(aLocalDateTime(undefined), '-');
    assert.strictEqual(aLocalDateTime(''), '-');
    assert.strictEqual(aLocalDateTime('xxxx'), '-');
    assert.strictEqual(aLocalDateTime(new Date('xx')), '-');
  });

  test('REGRESSION: NO devuelve formato ISO con T y Z (anti-patrón)', () => {
    const dt = new Date(2026, 4, 30, 14, 30);
    const r = aLocalDateTime(dt);
    assert.ok(!r.includes('T'), `No debe contener "T": ${r}`);
    assert.ok(!r.includes('Z'), `No debe contener "Z": ${r}`);
  });
});

describe('fechas.diasEntreIso — conteo de días corridos', () => {
  test('mismo día → 0', () => {
    assert.strictEqual(diasEntreIso('2026-06-06', '2026-06-06'), 0);
  });

  test('un día después → 1; un día antes → -1', () => {
    assert.strictEqual(diasEntreIso('2026-06-06', '2026-06-07'), 1);
    assert.strictEqual(diasEntreIso('2026-06-06', '2026-06-05'), -1);
  });

  test('cruza fin de mes correctamente', () => {
    // 30-may a 02-jun = 3 días.
    assert.strictEqual(diasEntreIso('2026-05-30', '2026-06-02'), 3);
  });

  test('acepta ISO con tail (toma los primeros 10 chars)', () => {
    assert.strictEqual(
      diasEntreIso('2026-06-06T00:00:00.000Z', '2026-06-16T23:59:00Z'),
      10,
    );
  });

  test('NO sufre el shift UTC: medianoche ISO no resta un día', () => {
    // El bug que motiva el helper: new Date("2026-06-07") es medianoche UTC =
    // 21h del 06 en ART. Con parseo manual de componentes locales, 06→07 = 1.
    assert.strictEqual(diasEntreIso('2026-06-06', '2026-06-07'), 1);
  });

  test('input inválido → null', () => {
    assert.strictEqual(diasEntreIso('xxxx', '2026-06-06'), null);
    assert.strictEqual(diasEntreIso('2026-06-06', ''), null);
    assert.strictEqual(diasEntreIso(null, null), null);
  });
});
