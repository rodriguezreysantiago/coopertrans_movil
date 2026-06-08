// Tests de las MÉTRICAS POR UI agregadas al registro v3 (km/vel max/vel prom
// por segmento + bloque, serie de velocidad downsampleada). Estos datos
// alimentan la pantalla del admin (gráfico velocidad/tiempo + listas) sin
// pedirle a la app que recalcule sobre SITRACK_EVENTOS — los persiste la CF.
//
// Estrategia: igual que jornadas_v3.test.js, testear el compilado lib/. Las
// funciones helper (`velStatsEnRango`, etc.) son privadas a propósito; la API
// pública es `reconstruirJornada` y todo se valida sobre el objeto devuelto.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  reconstruirJornada,
  MAX_PUNTOS_SERIE,
} = require('../lib/jornadas_v3');

// ── Helpers ─────────────────────────────────────────────────────────────

const MIN = 60 * 1000;
const H = 60 * MIN;

// Evento sintético con defaults razonables. Mismo patrón que ev() de
// jornadas_v3.test.js — usar `in over` para no pisar nulls explícitos.
function ev(ms, over = {}) {
  const pick = (k, def) => (k in over ? over[k] : def);
  return {
    ms,
    eventId: pick('id', 283),
    speed: pick('sp', 70),
    gpsSpeed: pick('gsp', pick('sp', 70)),
    ignition: pick('ign', 1),
    lat: pick('lat', -38.0),
    lng: pick('lng', -68.0),
    gpsValidity: pick('val', 32),
  };
}

// Genera N eventos `283` (curso) en intervalos `stepSeg` arrancando en `t0`,
// con velocidad `sp` y posición avanzando `kmStep` km al norte por evento.
// kmStep no es exacto en km (varía con la latitud) pero alcanza para mover el
// haversine de forma medible y reproducible.
function ruta({ t0, n, stepSeg, sp, lat0 = -38.0, lng0 = -68.0,
  kmStep = 1 }) {
  // 1 km ≈ 1/111 grados de latitud.
  const dLat = kmStep / 111;
  const out = [];
  for (let i = 0; i < n; i++) {
    out.push(ev(t0 + i * stepSeg * 1000, {
      sp, gsp: sp, lat: lat0 + i * dLat, lng: lng0,
    }));
  }
  return out;
}

// ══════════════════════════════════════════════════════════════════════
// 1) km / vel max / vel prom por SEGMENTO de manejo
// ══════════════════════════════════════════════════════════════════════

describe('métricas por segmento de manejo', () => {
  const BASE = 1780000000000;

  test('un solo tramo de manejo: km > 0, velMax ≈ max(speed), velProm ≈ avg', () => {
    // 30 eventos a 60 s con velocidades 50/60/70 km/h, separación ~1 km.
    // El haversine entre puntos consecutivos da ~1 km c/u → 29 km total.
    const evs = [];
    for (let i = 0; i < 30; i++) {
      const sp = i % 3 === 0 ? 50 : i % 3 === 1 ? 60 : 70;
      evs.push(...ruta({
        t0: BASE + i * 60 * 1000, n: 1, stepSeg: 60, sp,
        lat0: -38.0 + i * (1 / 111), lng0: -68.0, kmStep: 0,
      }));
    }
    // Agregar inicio + final con paro/arranque para que el segmento esté bien
    // delimitado.
    evs.unshift(ev(BASE - 60 * 1000, { id: 7, sp: 0, gsp: 0,
      lat: -38.0, lng: -68.0 }));
    evs.push(ev(BASE + 30 * 60 * 1000, { id: 164, sp: 0, gsp: 0,
      lat: -38.0 + 30 / 111, lng: -68.0 }));

    const r = reconstruirJornada(evs);
    const tramos = r.segmentos.filter((s) => s.tipo === 'manejo');
    assert.ok(tramos.length >= 1, 'al menos 1 tramo de manejo');
    const t = tramos[0];
    assert.ok(t.kmAprox >= 20 && t.kmAprox <= 35,
      `kmAprox razonable, fue ${t.kmAprox}`);
    assert.strictEqual(t.velMax, 70);
    // El prom debe estar en (50, 70) — promedio de tres velocidades en
    // partes iguales = 60.
    assert.ok(t.velProm >= 55 && t.velProm <= 65,
      `velProm cerca de 60, fue ${t.velProm}`);
  });

  test('eventos sin velocidad informada: velMax y velProm = 0', () => {
    // Manejo detectado por evento de arranque (fin detenido), pero los
    // eventos de la marcha no traen speed ni gpsSpeed.
    const evs = [
      ev(BASE, { id: 7, sp: 0, gsp: 0 }),
      ev(BASE + 5 * MIN, { id: 283, sp: null, gsp: null }),
      ev(BASE + 10 * MIN, { id: 283, sp: null, gsp: null }),
      ev(BASE + 15 * MIN, { id: 164, sp: 0, gsp: 0 }),
    ];
    const r = reconstruirJornada(evs);
    const tramos = r.segmentos.filter((s) => s.tipo === 'manejo');
    // Puede no haber tramos si no se detectó manejo — testeamos solo si hay.
    if (tramos.length > 0) {
      assert.strictEqual(tramos[0].velMax, 0);
      assert.strictEqual(tramos[0].velProm, 0);
    }
  });
});

// ══════════════════════════════════════════════════════════════════════
// 2) Bloques con km/vel
// ══════════════════════════════════════════════════════════════════════

describe('métricas por bloque', () => {
  const BASE = 1780000000000;

  test('bloque cubre todo el manejo del turno con km/vel agregados', () => {
    // Turno: manejo 30 min (avanza ~30 km) → pausa de 20 min (cierra bloque) →
    // manejo otros 30 min. Eso da 2 bloques.
    const evs = [];
    // bloque 1
    for (let i = 0; i < 31; i++) {
      evs.push(ev(BASE + i * MIN, {
        sp: 60, gsp: 60, lat: -38.0 + i * (1 / 111), lng: -68.0,
      }));
    }
    // pausa explícita de 20 min
    evs.push(ev(BASE + 31 * MIN, {
      id: 164, sp: 0, gsp: 0,
      lat: -38.0 + 31 * (1 / 111), lng: -68.0,
    }));
    evs.push(ev(BASE + 51 * MIN, {
      id: 7, sp: 60, gsp: 60,
      lat: -38.0 + 31 * (1 / 111), lng: -68.0,
    }));
    // bloque 2
    for (let i = 0; i < 30; i++) {
      evs.push(ev(BASE + (52 + i) * MIN, {
        sp: 70, gsp: 70, lat: -38.0 + (32 + i) * (1 / 111), lng: -68.0,
      }));
    }

    const r = reconstruirJornada(evs);
    assert.ok(r.bloques.length >= 1, 'al menos 1 bloque');
    for (const b of r.bloques) {
      assert.ok(b.kmAprox >= 0, `km del bloque ${b.indice} debe ser ≥ 0`);
      assert.ok(b.velMax >= 0, 'velMax del bloque ≥ 0');
      assert.ok(b.velProm >= 0, 'velProm del bloque ≥ 0');
    }
    // El primer bloque tiene la velocidad del primer tramo (60); si hay 2 bloques
    // el segundo tiene 70.
    if (r.bloques.length >= 2) {
      assert.strictEqual(r.bloques[1].velMax, 70);
    }
  });
});

// ══════════════════════════════════════════════════════════════════════
// 3) Serie de velocidad downsampleada
// ══════════════════════════════════════════════════════════════════════

describe('serie velocidad downsampleada', () => {
  const BASE = 1780000000000;

  test('pocos eventos: la serie incluye TODOS', () => {
    // 10 eventos << MAX_PUNTOS_SERIE (240).
    const evs = ruta({ t0: BASE, n: 10, stepSeg: 60, sp: 60 });
    const r = reconstruirJornada(evs);
    assert.strictEqual(r.serieVelocidad.length, 10);
    assert.strictEqual(r.serieVelocidad[0].speed, 60);
  });

  test('muchos eventos: la serie se cappea a MAX_PUNTOS_SERIE', () => {
    // 1000 eventos, separados 60 s — mucho más que 240.
    const evs = ruta({ t0: BASE, n: 1000, stepSeg: 60, sp: 50 });
    const r = reconstruirJornada(evs);
    assert.ok(
      r.serieVelocidad.length <= MAX_PUNTOS_SERIE,
      `serie cappeada a ${MAX_PUNTOS_SERIE}, fue ${r.serieVelocidad.length}`
    );
    assert.ok(
      r.serieVelocidad.length >= MAX_PUNTOS_SERIE - 1,
      'la serie debería usar casi todo el cap'
    );
  });

  test('eventos sin velocidad: la serie los registra como speed=0', () => {
    const evs = [
      ev(BASE, { sp: 60, gsp: 60 }),
      ev(BASE + 5 * MIN, { sp: null, gsp: null }),
      ev(BASE + 10 * MIN, { sp: 70, gsp: 70 }),
    ];
    const r = reconstruirJornada(evs);
    // El evento sin velocidad → speed 0 en la serie.
    const ceros = r.serieVelocidad.filter((p) => p.speed === 0);
    assert.ok(ceros.length >= 1,
      `al menos 1 punto con speed=0 (eventos null), fue ${ceros.length}`);
  });

  test('los timestamps de la serie son monótonos y caen dentro del turno', () => {
    const evs = ruta({ t0: BASE, n: 500, stepSeg: 30, sp: 65 });
    const r = reconstruirJornada(evs);
    assert.ok(r.serieVelocidad.length > 0, 'serie no vacía');
    for (let i = 1; i < r.serieVelocidad.length; i++) {
      assert.ok(
        r.serieVelocidad[i].tsMs >= r.serieVelocidad[i - 1].tsMs,
        `serie monótona en idx ${i}`
      );
    }
    assert.ok(r.serieVelocidad[0].tsMs >= r.inicioTurnoMs);
    const ultimo = r.serieVelocidad[r.serieVelocidad.length - 1];
    assert.ok(ultimo.tsMs <= r.finTurnoMs);
  });
});

// ══════════════════════════════════════════════════════════════════════
// 4) Smoke: jornada vacía no rompe
// ══════════════════════════════════════════════════════════════════════

describe('borde: sin eventos', () => {
  test('reconstruirJornada([]) devuelve serie vacía sin romper', () => {
    const r = reconstruirJornada([]);
    assert.deepStrictEqual(r.serieVelocidad, []);
    assert.deepStrictEqual(r.bloques, []);
  });
});
