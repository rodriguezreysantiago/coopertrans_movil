// Tests para `reconstruirJornadaDia` (función pura de jornada_historico.ts).
//
// Strategy: igual que jornadas_v2_helpers.test.js — testear el JS compilado
// (lib/jornada_historico.js). `npm test` corre `npm run build` antes.
//
// Caso central: el bug de FLORES JUAN DOMINGO (25/5/2026 20:06-20:20)
// donde Sitrack mandó UN solo evento speed=0 y nada por 14 min, y el
// algoritmo viejo descartaba la parada por durMs=0. El fix mide la parada
// hasta el ts del evento moviendo siguiente.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const { reconstruirJornadaDia } = require('../lib/jornada_historico');

// Helper: evento con campos defaulteados, solo los que importan en cada test.
function ev(min, speed, opts = {}) {
  return {
    ts: new Date(Date.UTC(2026, 4, 25, 13, min, 0)), // 25/5/2026 13:MM UTC = 10:MM ART
    speed,
    ignition: opts.ignition ?? true,
    patente: opts.patente ?? 'AB787RS',
    driverDni: opts.driverDni ?? '17379861',
    driverName: opts.driverName,
    lat: opts.lat ?? -34.6788,
    lng: opts.lng ?? -60.9670,
    odometer: opts.odometer,
  };
}

describe('reconstruirJornadaDia — fix paradas con un solo evento parado', () => {
  test('caso FLORES 25/5: 1 evento parado + gap 14min → parada de 14min se registra', () => {
    // Reproducción del caso real de Sitrack para AB787RS:
    //   20:00 speed=70 (moviendo previo)
    //   20:06:56 speed=0 (UN solo evento parado)
    //   20:21:14 speed=48 (vuelve a moverse — 14 min después)
    //   20:25 speed=50 (sigue moviendo)
    //
    // Bug viejo: bufferDesde == bufferUltimo (mismo evento parado) →
    // durMs=0 → parada descartada.
    // Fix: cerrarParada(eventoMoviendoSiguiente) mide hasta el ts del
    // evento que rompe la parada.
    const eventos = [
      ev(0, 70, { odometer: 11530 }),    // 13:00 UTC = 10:00 ART, moviendo
      ev(5, 75, { odometer: 11533 }),    // 13:05, moviendo
      ev(6, 0, { odometer: 11536.093 }), // 13:06, parado (único)
      ev(20, 48, { odometer: 11536.633 }), // 13:20, moviendo (14 min después)
      ev(25, 50, { odometer: 11540 }),     // 13:25, moviendo
    ];
    const j = reconstruirJornadaDia('17379861', '2026-05-25', eventos);
    assert.ok(j, 'jornada no debe ser null');
    assert.strictEqual(j.paradas.length, 1,
      `debe haber 1 parada, encontró ${j.paradas.length}`);
    const p = j.paradas[0];
    // Duración: 13:20 - 13:06 = 14 min (con tolerancia ±1 por redondeo de Math.round)
    assert.ok(p.duracion_min >= 13 && p.duracion_min <= 15,
      `parada debe durar ~14min, dio ${p.duracion_min}`);
    // Inicio en el evento parado, fin en el evento moviendo siguiente
    assert.strictEqual(p.desde.getUTCMinutes(), 6);
    assert.strictEqual(p.hasta.getUTCMinutes(), 20);
  });

  test('caso clásico (varios eventos parados) — sigue funcionando', () => {
    // Ya andaba antes del fix. Verificamos que no rompimos nada.
    const eventos = [
      ev(0, 70, { odometer: 1000 }),
      ev(5, 75, { odometer: 1005 }),
      ev(10, 0, { odometer: 1010 }),  // primer evento parado
      ev(15, 0, { odometer: 1010 }),  // todavía parado
      ev(20, 0, { odometer: 1010 }),  // todavía parado
      ev(25, 50, { odometer: 1010 }), // vuelve a moverse
      ev(30, 60, { odometer: 1015 }),
    ];
    const j = reconstruirJornadaDia('17379861', '2026-05-25', eventos);
    assert.ok(j);
    assert.strictEqual(j.paradas.length, 1);
    const p = j.paradas[0];
    // Antes del fix daba 10 min (20-10). Con el fix da 15 (25-10).
    // Esto es DESEABLE: la parada realmente terminó cuando volvió a moverse.
    assert.ok(p.duracion_min >= 14 && p.duracion_min <= 16,
      `parada debe durar ~15min, dio ${p.duracion_min}`);
  });

  test('parada menor a 1 min sigue descartándose (filtro 60_000 ms)', () => {
    const eventos = [
      ev(0, 70, { odometer: 1000 }),
      ev(5, 75, { odometer: 1005 }),
      ev(10, 0, { odometer: 1010 }),
      // Solo 30 segundos después vuelve a moverse → parada < 1 min, descartada
      { ...ev(10, 50, { odometer: 1010 }),
        ts: new Date(Date.UTC(2026, 4, 25, 13, 10, 30)) },
      ev(15, 60, { odometer: 1015 }),
    ];
    const j = reconstruirJornadaDia('17379861', '2026-05-25', eventos);
    assert.ok(j);
    assert.strictEqual(j.paradas.length, 0,
      'parada < 1 min debe seguir descartándose');
  });

  test('cierre del día con estado parado (sin evento siguiente) — comportamiento original', () => {
    // Si la última transición fue a "parado" y el día termina ahí, no
    // hay evento siguiente. Se mide entre primer y último parado (igual
    // que antes del fix). Acá hay >=60s entre el primer y último parado.
    const eventos = [
      ev(0, 70, { odometer: 1000 }),
      ev(5, 75, { odometer: 1005 }),
      ev(10, 0, { odometer: 1010 }),
      ev(13, 0, { odometer: 1010 }),
      ev(15, 0, { odometer: 1010 }),
    ];
    const j = reconstruirJornadaDia('17379861', '2026-05-25', eventos);
    assert.ok(j);
    assert.strictEqual(j.paradas.length, 1);
    assert.strictEqual(j.paradas[0].duracion_min, 5,
      'cierre final mide bufferDesde→bufferUltimo (5 min)');
  });

  test('tramo de manejo también extendido hasta el primer evento parado', () => {
    // Antes: tramo terminaba en el último evento moviendo (5 min).
    // Ahora: tramo termina en el primer evento parado (10 min).
    // Más fiel a la realidad: el chofer estuvo manejando hasta justo
    // antes de detenerse.
    //
    // Hace falta un evento moviendo bien después de la parada (>= 1 min
    // de tramo) para que el segundo tramo se cierre y veamos 2 tramos
    // en la salida — sino el del cierre final con durMs=0 cae al
    // filtro de 60_000ms.
    const eventos = [
      ev(0, 70, { odometer: 1000 }),
      ev(5, 75, { odometer: 1005 }),
      ev(10, 0, { odometer: 1010 }),  // primer evento parado
      ev(15, 0, { odometer: 1010 }),
      ev(20, 50, { odometer: 1010 }), // vuelve a moverse
      ev(25, 60, { odometer: 1015 }), // sostiene movimiento → tramo 2 cierra
    ];
    const j = reconstruirJornadaDia('17379861', '2026-05-25', eventos);
    assert.ok(j);
    assert.strictEqual(j.tramos.length, 2);
    // Primer tramo: 0 → 10 (no 0 → 5)
    assert.strictEqual(j.tramos[0].duracion_min, 10,
      'tramo debe extenderse hasta el primer evento parado (10 min, no 5)');
  });

  test('km del tramo usa odometer del evento que rompe (más preciso)', () => {
    // Si el primer evento parado tiene odo más reciente que el último
    // moviendo, el km del tramo es mayor — refleja la distancia real.
    const eventos = [
      ev(0, 70, { odometer: 1000 }),  // inicio tramo
      ev(5, 75, { odometer: 1005 }),  // último moviendo conocido
      ev(10, 0, { odometer: 1015 }),  // primer parado, odo=1015 (avanzó 10km entre evento 2 y 3)
      ev(15, 0, { odometer: 1015 }),
      ev(20, 50, { odometer: 1015 }),
    ];
    const j = reconstruirJornadaDia('17379861', '2026-05-25', eventos);
    assert.ok(j);
    // Con el fix: km = odo_evento_parado(1015) - odo_inicio(1000) = 15
    // Sin el fix daba: km = odo_ultimo_moviendo(1005) - odo_inicio(1000) = 5
    assert.strictEqual(j.tramos[0].km_aprox, 15,
      'km del tramo usa odometer del evento que rompe (1015-1000=15)');
  });
});
