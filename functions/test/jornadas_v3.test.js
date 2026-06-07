// Tests del REGISTRO A POSTERIORI del vigilador de jornada v3 (Paso 1, Camino B).
// Ver docs/PLAN_vigilador_jornada_v3.md.
//
// TDD sobre los DOS casos reales del 06-jun que originaron el rediseño (buzón
// REPORTES_DISCREPANCIA): FERNANDEZ (parada ~26 min con Contacto OFF en RP65 que
// el v2 no registró + una parada que el chofer reclama dentro de un gap sin
// reportes) y LOPEZ (baño ~60 min en Chinchinales que el v2 contó como "4h05 de
// manejo y sigue manejando"). Las secuencias crudas se sacaron con
// `node whatsapp-bot/scripts/dump_eventos_jornada_v3.js` (read-only).
//
// Estrategia: igual que jornadas_v2_tick.test.js — testear el compilado
// lib/jornadas_v3.js. Sin Firebase: reconstruirJornada es pura.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  reconstruirJornada,
  reconstruirJornadas,
  partirEnTurnos,
  esMovimientoEvento,
  esParoEvento,
  esArranqueEvento,
  horaMinArt,
  GAP_GRANDE_SEGUNDOS,
  PAUSA_REPORTABLE_SEGUNDOS,
} = require('../lib/jornadas_v3');

// Umbrales del v2 que el v3 reusa (single source of truth).
const {
  PAUSA_BLOQUE_SEGUNDOS, // 15 min
  BLOQUE_EXCEDIDO_SEGUNDOS, // 4 h
  BLOQUE_LIMITE_SEGUNDOS, // 3h45
  DESCANSO_MIN_SEGUNDOS, // 8 h
} = require('../lib/jornadas_v2');

// ── Helpers ──────────────────────────────────────────────────────────

// Mapea una fila compacta del dump {t,id,sp,gsp,ign,lat,lng,val} (t = segundos
// relativos al primer evento) a un EventoJornadaLite con ms absolutos.
function build(base, rows) {
  return rows.map((r) => ({
    ms: base + r.t * 1000,
    eventId: r.id,
    speed: r.sp,
    gpsSpeed: r.gsp,
    ignition: r.ign,
    lat: r.lat,
    lng: r.lng,
    gpsValidity: r.val,
  }));
}

// Evento sintético "suelto" (para los casos construidos a mano). Usa `in` para
// lat/lng/sp para respetar un `null` pasado a propósito (un `??` lo pisaría con
// el default — justo lo que rompe el caso "sin posición").
function ev(ms, over = {}) {
  const pick = (k, def) => (k in over ? over[k] : def);
  return {
    ms,
    eventId: pick('id', 283), // Cambio de curso por default
    speed: pick('sp', 70),
    gpsSpeed: pick('gsp', pick('sp', 70)),
    ignition: pick('ign', 1),
    lat: pick('lat', -38.0),
    lng: pick('lng', -68.0),
    gpsValidity: pick('val', 32),
  };
}

const MIN = 60 * 1000;
const H = 60 * MIN;

// ══════════════════════════════════════════════════════════════════════
// CASO REAL 1 — FERNANDEZ JOSE LUIS (DNI 26129762), 06-jun
// ══════════════════════════════════════════════════════════════════════
// Reclamo: "paró a la 1:50 y salió a las 14:40 en Baigorrita, el sistema no lo
// registró como parada de +20 min". La data muestra:
//   - Parada NÍTIDA 13:15:32 (Contacto OFF + Inicio detenido) → 13:41:34 (Fin
//     de detenido), ~26 min, misma posición en RP65. ESTO es lo que el v2 (que
//     mira casi solo velocidad de snapshot) no registró bien.
//   - La parada que el chofer ubica 13:50–14:40 cae dentro de un gap de 51 min
//     SIN reportes en el que el camión SÍ se movió 59 km → v3 no la inventa: la
//     marca baja confianza (a confirmar), no "manejo continuo" a secas.

const FERNANDEZ_BASE = 1780744328000; // 06-jun 08:12:08 ART
const FERNANDEZ = build(FERNANDEZ_BASE, [
  { t: 0, id: 283, sp: 27, gsp: 27, ign: 1, lat: -33.85442, lng: -59.54273, val: 32 },
  { t: 595, id: 283, sp: 33, gsp: 33, ign: 1, lat: -33.78376, lng: -59.64036, val: 32 },
  { t: 1234, id: 283, sp: 11, gsp: 11, ign: 1, lat: -33.69745, lng: -59.65144, val: 32 },
  { t: 1248, id: 283, sp: 22, gsp: 22, ign: 1, lat: -33.69759, lng: -59.65100, val: 32 },
  { t: 1290, id: 67, sp: 53, gsp: 53, ign: 1, lat: -33.69949, lng: -59.64767, val: 32 },
  { t: 1362, id: 283, sp: 18, gsp: 18, ign: 1, lat: -33.70323, lng: -59.64087, val: 32 },
  { t: 1707, id: 6, sp: 0, gsp: 0, ign: 1, lat: -33.69703, lng: -59.63516, val: 32 },
  { t: 3506, id: 283, sp: 14, gsp: 14, ign: 1, lat: -33.69574, lng: -59.63329, val: 32 },
  { t: 3555, id: 7, sp: 9, gsp: 9, ign: 1, lat: -33.69431, lng: -59.63272, val: 32 },
  { t: 3768, id: 6, sp: 0, gsp: 0, ign: 1, lat: -33.69294, lng: -59.63170, val: 32 },
  { t: 4057, id: 283, sp: 5, gsp: 5, ign: 1, lat: -33.69276, lng: -59.63191, val: 32 },
  { t: 4073, id: 283, sp: 3, gsp: 3, ign: 1, lat: -33.69282, lng: -59.63216, val: 32 },
  { t: 4894, id: 283, sp: 9, gsp: 9, ign: 1, lat: -33.69482, lng: -59.63369, val: 32 },
  { t: 4946, id: 283, sp: 7, gsp: 7, ign: 1, lat: -33.69589, lng: -59.63344, val: 32 },
  { t: 5460, id: 283, sp: 5, gsp: 5, ign: 1, lat: -33.69679, lng: -59.63452, val: 32 },
  { t: 5467, id: 283, sp: 7, gsp: 7, ign: 1, lat: -33.69681, lng: -59.63438, val: 32 },
  { t: 5476, id: 283, sp: 5, gsp: 5, ign: 1, lat: -33.69673, lng: -59.63423, val: 32 },
  { t: 5545, id: 283, sp: 9, gsp: 9, ign: 1, lat: -33.69573, lng: -59.63328, val: 32 },
  { t: 5567, id: 283, sp: 9, gsp: 9, ign: 1, lat: -33.69538, lng: -59.63375, val: 32 },
  { t: 5578, id: 283, sp: 9, gsp: 9, ign: 1, lat: -33.69553, lng: -59.63398, val: 32 },
  { t: 6697, id: 283, sp: 12, gsp: 12, ign: 1, lat: -33.70326, lng: -59.64113, val: 32 },
  { t: 6716, id: 7, sp: 24, gsp: 24, ign: 1, lat: -33.70281, lng: -59.64191, val: 32 },
  { t: 6873, id: 283, sp: 5, gsp: 5, ign: 1, lat: -33.69732, lng: -59.65123, val: 32 },
  { t: 6883, id: 283, sp: 5, gsp: 5, ign: 1, lat: -33.69727, lng: -59.65140, val: 32 },
  { t: 6891, id: 283, sp: 11, gsp: 11, ign: 1, lat: -33.69739, lng: -59.65151, val: 32 },
  { t: 7016, id: 283, sp: 20, gsp: 20, ign: 1, lat: -33.70681, lng: -59.65882, val: 32 },
  { t: 7429, id: 283, sp: 77, gsp: 77, ign: 1, lat: -33.77127, lng: -59.62589, val: 32 },
  { t: 7545, id: 283, sp: 29, gsp: 29, ign: 1, lat: -33.78376, lng: -59.64074, val: 32 },
  { t: 7976, id: 283, sp: 22, gsp: 22, ign: 1, lat: -33.76212, lng: -59.72231, val: 32 },
  { t: 9909, id: 383, sp: 75, gsp: 75, ign: 1, lat: -34.01693, lng: -59.97673, val: 32 },
  { t: 10410, id: 283, sp: 75, gsp: 75, ign: 1, lat: -34.06321, lng: -60.07186, val: 32 },
  { t: 10640, id: 283, sp: 16, gsp: 16, ign: 1, lat: -34.06021, lng: -60.09495, val: 32 },
  { t: 10875, id: 283, sp: 12, gsp: 12, ign: 1, lat: -34.07240, lng: -60.09492, val: 32 },
  { t: 10882, id: 283, sp: 18, gsp: 18, ign: 1, lat: -34.07246, lng: -60.09519, val: 32 },
  { t: 10995, id: 283, sp: 38, gsp: 38, ign: 1, lat: -34.07439, lng: -60.10814, val: 32 },
  { t: 12567, id: 283, sp: 27, gsp: 27, ign: 1, lat: -34.32065, lng: -60.23780, val: 32 },
  { t: 12578, id: 283, sp: 35, gsp: 35, ign: 1, lat: -34.32116, lng: -60.23848, val: 32 },
  { t: 12692, id: 283, sp: 75, gsp: 75, ign: 1, lat: -34.33409, lng: -60.25374, val: 32 },
  { t: 13466, id: 283, sp: 75, gsp: 75, ign: 0, lat: -34.42106, lng: -60.38786, val: 32 },
  { t: 14517, id: 283, sp: 14, gsp: 14, ign: 0, lat: -34.58619, lng: -60.47377, val: 32 },
  { t: 14582, id: 283, sp: 24, gsp: 24, ign: 0, lat: -34.58755, lng: -60.47012, val: 32 },
  { t: 14631, id: 283, sp: 29, gsp: 29, ign: 0, lat: -34.59002, lng: -60.46996, val: 32 },
  { t: 15558, id: 283, sp: 75, gsp: 75, ign: 0, lat: -34.65171, lng: -60.62158, val: 32 },
  { t: 15658, id: 383, sp: 75, gsp: 75, ign: 0, lat: -34.64794, lng: -60.64424, val: 32 },
  { t: 17206, id: 283, sp: 11, gsp: 11, ign: 0, lat: -34.61287, lng: -60.95569, val: 32 },
  { t: 17708, id: 283, sp: 44, gsp: 44, ign: 0, lat: -34.67648, lng: -60.96708, val: 32 },
  { t: 18204, id: 164, sp: 0, gsp: 0, ign: 0, lat: -34.74834, lng: -60.97658, val: 32 },
  { t: 18239, id: 6, sp: 0, gsp: 0, ign: 0, lat: -34.74834, lng: -60.97658, val: 32 },
  { t: 19532, id: 163, sp: 0, gsp: 0, ign: 1, lat: -34.74836, lng: -60.97660, val: 32 },
  { t: 19537, id: 194, sp: 0, gsp: 0, ign: 0, lat: -34.74836, lng: -60.97660, val: 32 },
  { t: 19766, id: 7, sp: 64, gsp: 64, ign: 1, lat: -34.75621, lng: -60.97806, val: 32 },
  { t: 21827, id: 67, sp: 75, gsp: 75, ign: 1, lat: -35.13777, lng: -60.99677, val: 32 },
  { t: 24897, id: 283, sp: 77, gsp: 77, ign: 1, lat: -35.66561, lng: -60.82181, val: 32 },
  { t: 25235, id: 283, sp: 77, gsp: 77, ign: 1, lat: -35.72152, lng: -60.84820, val: 32 },
  { t: 25414, id: 283, sp: 75, gsp: 75, ign: 1, lat: -35.75245, lng: -60.85137, val: 32 },
]);

describe('v3 caso real — FERNANDEZ (parada con Contacto OFF en RP65)', () => {
  const r = reconstruirJornada(FERNANDEZ);

  test('detecta la parada de ~26 min por Contacto OFF (la que el v2 no registró)', () => {
    const p = r.pausas.find(
      (x) => x.origen === 'contacto_off' && x.durSeg >= PAUSA_BLOQUE_SEGUNDOS
    );
    assert.ok(p, 'debe haber una pausa por contacto_off que cierra bloque');
    // 13:15:32 → 13:41:34 ≈ 26 min.
    assert.ok(p.durSeg >= 24 * 60 && p.durSeg <= 28 * 60,
      `pausa ~26 min, fue ${(p.durSeg / 60).toFixed(1)} min`);
    assert.equal(p.cierraBloque, true);
    assert.equal(horaMinArt(p.inicioMs), '13:15');
    assert.equal(horaMinArt(p.finMs), '13:41');
  });

  test('NO inventa la parada que el chofer ubica en el gap de 51 min: la marca baja confianza', () => {
    // El tramo de manejo posterior al arranque (19766) contiene el gap 21827→24897
    // (51 min, +59 km). Debe quedar como manejo de BAJA confianza, no negarse ni
    // afirmarse a ciegas.
    const tramoDudoso = r.segmentos.find(
      (s) => s.tipo === 'manejo' && s.confianza === 'baja'
    );
    assert.ok(tramoDudoso, 'el manejo con gap+desplazamiento debe ser baja confianza');
    assert.match(tramoDudoso.motivoBaja, /desplazamiento/);
    assert.notEqual(r.confianza, 'alta');
  });

  test('NO marca infracción de 4 h: ninguna racha de manejo continuo llega a 4 h', () => {
    assert.equal(r.bloquesExcedidos, 0);
    for (const b of r.bloques) {
      assert.ok(b.manejoNetoSeg < BLOQUE_EXCEDIDO_SEGUNDOS,
        `bloque ${b.indice} = ${(b.manejoNetoSeg / 3600).toFixed(2)}h < 4h`);
    }
  });

  test('detecta también las dos detenciones largas del playón de carga (mañana)', () => {
    const detenciones = r.pausas.filter((p) => p.origen === 'detenido');
    assert.ok(detenciones.length >= 2,
      `≥2 detenciones en el playón, fueron ${detenciones.length}`);
  });

  test('la explicación al chofer es legible y nombra la pausa', () => {
    assert.ok(r.explicacion[0].startsWith('Turno '));
    assert.ok(r.explicacion.some((l) => l.includes('motor apagado')),
      'la explicación debe mencionar el motor apagado de la pausa');
  });
});

// ══════════════════════════════════════════════════════════════════════
// CASO REAL 2 — LOPEZ CARLO JERONIMO (DNI 22987952), 06-jun
// ══════════════════════════════════════════════════════════════════════
// Reclamo: "paró antes de las 4 horas para bañarse en Chinchinales, pero el
// sistema le marca 4h 5m de manejo y que sigue manejando". La data muestra una
// parada de ~60 min (12:28:06 Inicio detenido + Contacto OFF → 13:28:51 Fin de
// detenido) en una calle de Chinchinales (misma posición). v3 debe acreditar esa
// pausa y NO marcar las 4 h.

const LOPEZ_BASE = 1780745885000; // 06-jun 08:38:05 ART
const LOPEZ = build(LOPEZ_BASE, [
  { t: 0, id: 163, sp: 0, gsp: 0, ign: 1, lat: -38.37336, lng: -68.62571, val: 32 },
  { t: 3, id: 194, sp: 0, gsp: 0, ign: 1, lat: -38.37336, lng: -68.62571, val: 32 },
  { t: 238, id: 283, sp: 7, gsp: 7, ign: 1, lat: -38.37319, lng: -68.62594, val: 32 },
  { t: 317, id: 283, sp: 14, gsp: 14, ign: 1, lat: -38.37159, lng: -68.62577, val: 32 },
  { t: 323, id: 283, sp: 11, gsp: 11, ign: 1, lat: -38.37141, lng: -68.62572, val: 32 },
  { t: 327, id: 283, sp: 9, gsp: 9, ign: 1, lat: -38.37138, lng: -68.62586, val: 32 },
  { t: 1654, id: 7, sp: 38, gsp: 38, ign: 1, lat: -38.37021, lng: -68.63332, val: 32 },
  { t: 1927, id: 283, sp: 18, gsp: 18, ign: 1, lat: -38.36575, lng: -68.65539, val: 32 },
  { t: 1939, id: 283, sp: 25, gsp: 25, ign: 1, lat: -38.36543, lng: -68.65608, val: 32 },
  { t: 1947, id: 283, sp: 27, gsp: 27, ign: 1, lat: -38.36573, lng: -68.65659, val: 32 },
  { t: 2186, id: 283, sp: 24, gsp: 24, ign: 1, lat: -38.39434, lng: -68.68770, val: 32 },
  { t: 2194, id: 283, sp: 25, gsp: 25, ign: 1, lat: -38.39466, lng: -68.68815, val: 32 },
  { t: 2202, id: 283, sp: 25, gsp: 25, ign: 1, lat: -38.39515, lng: -68.68807, val: 32 },
  { t: 2209, id: 283, sp: 29, gsp: 29, ign: 1, lat: -38.39533, lng: -68.68751, val: 32 },
  { t: 2646, id: 283, sp: 72, gsp: 72, ign: 1, lat: -38.44530, lng: -68.60961, val: 32 },
  { t: 2708, id: 1007, sp: 73, gsp: 73, ign: 1, lat: -38.45469, lng: -68.60115, val: 12 },
  { t: 2836, id: 1007, sp: 74, gsp: 74, ign: 1, lat: -38.46468, lng: -68.57385, val: 12 },
  { t: 3972, id: 283, sp: 18, gsp: 18, ign: 1, lat: -38.57328, lng: -68.37014, val: 32 },
  { t: 3999, id: 283, sp: 37, gsp: 37, ign: 1, lat: -38.57406, lng: -68.37228, val: 32 },
  { t: 4075, id: 283, sp: 64, gsp: 64, ign: 1, lat: -38.57368, lng: -68.38581, val: 32 },
  { t: 4309, id: 283, sp: 61, gsp: 61, ign: 1, lat: -38.60461, lng: -68.39583, val: 32 },
  { t: 4392, id: 283, sp: 50, gsp: 50, ign: 1, lat: -38.60661, lng: -68.41068, val: 32 },
  { t: 4463, id: 283, sp: 22, gsp: 22, ign: 1, lat: -38.61510, lng: -68.41487, val: 32 },
  { t: 4468, id: 283, sp: 22, gsp: 22, ign: 1, lat: -38.61519, lng: -68.41456, val: 32 },
  { t: 5563, id: 283, sp: 33, gsp: 33, ign: 1, lat: -38.73804, lng: -68.20593, val: 32 },
  { t: 5571, id: 1006, sp: 30, gsp: 30, ign: 1, lat: -38.73843, lng: -68.20535, val: 12 },
  { t: 5696, id: 283, sp: 33, gsp: 33, ign: 1, lat: -38.75024, lng: -68.18651, val: 32 },
  { t: 6412, id: 283, sp: 77, gsp: 77, ign: 1, lat: -38.88454, lng: -68.18270, val: 32 },
  { t: 6594, id: 283, sp: 18, gsp: 18, ign: 1, lat: -38.91276, lng: -68.16757, val: 32 },
  { t: 6610, id: 283, sp: 27, gsp: 27, ign: 1, lat: -38.91349, lng: -68.16811, val: 32 },
  { t: 6617, id: 283, sp: 33, gsp: 33, ign: 1, lat: -38.91365, lng: -68.16747, val: 32 },
  { t: 6851, id: 283, sp: 14, gsp: 14, ign: 1, lat: -38.91214, lng: -68.12177, val: 32 },
  { t: 6876, id: 283, sp: 29, gsp: 29, ign: 1, lat: -38.91285, lng: -68.12136, val: 32 },
  { t: 6880, id: 283, sp: 29, gsp: 29, ign: 1, lat: -38.91271, lng: -68.12106, val: 32 },
  { t: 6888, id: 283, sp: 33, gsp: 33, ign: 1, lat: -38.91238, lng: -68.12049, val: 32 },
  { t: 7123, id: 283, sp: 62, gsp: 62, ign: 1, lat: -38.91215, lng: -68.06977, val: 32 },
  { t: 7144, id: 283, sp: 68, gsp: 68, ign: 1, lat: -38.91080, lng: -68.06588, val: 32 },
  { t: 7423, id: 1006, sp: 40, gsp: 40, ign: 1, lat: -38.91642, lng: -68.01913, val: 12 },
  { t: 7443, id: 283, sp: 42, gsp: 42, ign: 1, lat: -38.91748, lng: -68.01743, val: 32 },
  { t: 10002, id: 283, sp: 46, gsp: 46, ign: 1, lat: -39.03954, lng: -67.61437, val: 32 },
  { t: 12168, id: 283, sp: 77, gsp: 77, ign: 1, lat: -39.08248, lng: -67.18503, val: 32 },
  { t: 12205, id: 283, sp: 77, gsp: 77, ign: 1, lat: -39.07866, lng: -67.17795, val: 32 },
  { t: 12735, id: 283, sp: 42, gsp: 42, ign: 1, lat: -39.09072, lng: -67.08853, val: 32 },
  { t: 12880, id: 283, sp: 38, gsp: 38, ign: 1, lat: -39.09867, lng: -67.08249, val: 32 },
  { t: 13569, id: 283, sp: 51, gsp: 51, ign: 1, lat: -39.11993, lng: -66.93144, val: 32 },
  { t: 13647, id: 283, sp: 11, gsp: 11, ign: 1, lat: -39.11631, lng: -66.92926, val: 32 },
  { t: 13679, id: 283, sp: 9, gsp: 9, ign: 1, lat: -39.11657, lng: -66.92822, val: 32 },
  { t: 13801, id: 6, sp: 0, gsp: 0, ign: 1, lat: -39.11682, lng: -66.92833, val: 32 },
  { t: 13852, id: 164, sp: 0, gsp: 0, ign: 0, lat: -39.11681, lng: -66.92833, val: 32 },
  { t: 16539, id: 163, sp: 0, gsp: 0, ign: 1, lat: -39.11677, lng: -66.92833, val: 32 },
  { t: 16543, id: 194, sp: 0, gsp: 0, ign: 1, lat: -39.11677, lng: -66.92833, val: 32 },
  { t: 17308, id: 283, sp: 9, gsp: 9, ign: 1, lat: -39.11748, lng: -66.92855, val: 32 },
  { t: 17312, id: 283, sp: 7, gsp: 7, ign: 1, lat: -39.11744, lng: -66.92867, val: 32 },
  { t: 17349, id: 283, sp: 9, gsp: 9, ign: 1, lat: -39.11715, lng: -66.92960, val: 32 },
  { t: 17446, id: 7, sp: 46, gsp: 46, ign: 1, lat: -39.11185, lng: -66.92769, val: 32 },
  { t: 17484, id: 283, sp: 57, gsp: 57, ign: 1, lat: -39.10758, lng: -66.92461, val: 32 },
  { t: 18771, id: 283, sp: 77, gsp: 77, ign: 1, lat: -39.06301, lng: -66.61494, val: 32 },
  { t: 22688, id: 283, sp: 66, gsp: 66, ign: 1, lat: -39.21423, lng: -65.71987, val: 32 },
  { t: 23291, id: 283, sp: 27, gsp: 27, ign: 1, lat: -39.28284, lng: -65.66729, val: 32 },
  { t: 23417, id: 283, sp: 25, gsp: 25, ign: 1, lat: -39.28890, lng: -65.65594, val: 32 },
]);

describe('v3 caso real — LOPEZ (baño ~60 min en Chinchinales)', () => {
  const r = reconstruirJornada(LOPEZ);

  test('acredita la pausa de ~60 min (la que el v2 contó como manejo)', () => {
    const p = r.pausas.find((x) => x.durSeg >= 55 * 60);
    assert.ok(p, 'debe haber una pausa de ~60 min');
    // 12:28:06 → 13:28:51 ≈ 60.75 min.
    assert.ok(p.durSeg >= 58 * 60 && p.durSeg <= 63 * 60,
      `pausa ~60 min, fue ${(p.durSeg / 60).toFixed(1)} min`);
    assert.equal(p.cierraBloque, true);
    assert.equal(horaMinArt(p.inicioMs), '12:28');
    assert.ok(['detenido', 'contacto_off'].includes(p.origen));
  });

  test('paró ANTES de las 4 h: el primer bloque no llega ni a 3h45 → cero infracción', () => {
    assert.ok(r.bloques.length >= 2, 'la pausa parte el manejo en ≥2 bloques');
    const b1 = r.bloques[0];
    // El reclamo era "me marca 4h05 y sigo manejando". La verdad: ~3h22 y paró.
    assert.ok(b1.manejoNetoSeg < BLOQUE_LIMITE_SEGUNDOS,
      `bloque 1 = ${(b1.manejoNetoSeg / 3600).toFixed(2)}h, debe ser < 3h45`);
    assert.ok(b1.manejoNetoSeg > 3 * 3600,
      `bloque 1 ≈ 3h22, fue ${(b1.manejoNetoSeg / 3600).toFixed(2)}h`);
    assert.equal(r.bloquesExcedidos, 0, 'NUNCA debió marcar las 4 h');
  });

  test('el turno arranca con el primer movimiento, no con el Contacto ON inicial', () => {
    // 08:38 Contacto ON (parado en playón) NO es inicio de turno; 09:05 Fin de
    // detenido (primer movimiento) sí.
    assert.equal(horaMinArt(r.inicioTurnoMs), '09:05');
  });
});

// ══════════════════════════════════════════════════════════════════════
// Clasificación de señales (unit) — el hallazgo clínico ignition poco confiable
// ══════════════════════════════════════════════════════════════════════

describe('v3 — clasificación de eventos', () => {
  test('ignition==0 con speed>15 es MOVIMIENTO (ignition no es gatillo de paro)', () => {
    // Caso real FERNANDEZ 11:56: 283 sp75 ign0. No debe contarse como parado.
    const e = ev(0, { id: 283, sp: 75, ign: 0 });
    assert.equal(esMovimientoEvento(e), true);
    assert.equal(esParoEvento(e), false);
  });

  test('Contacto OFF (164) es paro; Contacto ON (163) NO es arranque', () => {
    assert.equal(esParoEvento(ev(0, { id: 164, sp: 0 })), true);
    assert.equal(esArranqueEvento(ev(0, { id: 163, sp: 0 })), false);
    assert.equal(esArranqueEvento(ev(0, { id: 7, sp: 0 })), true); // Fin detenido
  });

  test('Inicio de detenido (6) y Detenido (331/332) son paro', () => {
    assert.equal(esParoEvento(ev(0, { id: 6, sp: 0 })), true);
    assert.equal(esParoEvento(ev(0, { id: 331, sp: 0 })), true);
    assert.equal(esParoEvento(ev(0, { id: 332, sp: 0 })), true);
  });
});

// ══════════════════════════════════════════════════════════════════════
// Sintéticos — cada mecanismo aislado
// ══════════════════════════════════════════════════════════════════════

describe('v3 sintético — turno simple sin pausas', () => {
  test('manejo continuo en reportes densos → 1 bloque, sin pausas, confianza alta', () => {
    const t0 = Date.UTC(2026, 5, 6, 13, 0, 0); // 10:00 ART
    const rows = [];
    for (let i = 0; i < 10; i++) {
      rows.push(ev(t0 + i * 5 * MIN, { sp: 70, lat: -38.0 + i * 0.02, lng: -68.0 }));
    }
    const r = reconstruirJornada(rows);
    assert.equal(r.bloques.length, 1);
    assert.equal(r.pausas.length, 0);
    assert.equal(r.confianza, 'alta');
    assert.equal(r.bloquesExcedidos, 0);
    // 9 intervalos × 5 min = 45 min de manejo.
    assert.equal(r.manejoNetoSeg, 9 * 5 * 60);
  });
});

describe('v3 sintético — pausa por Contacto OFF/ON', () => {
  test('motor apagado 20 min → pausa contacto_off que cierra bloque', () => {
    const t0 = Date.UTC(2026, 5, 6, 13, 0, 0);
    const rows = [
      ev(t0, { sp: 70, lat: -38.0, lng: -68.0 }),
      ev(t0 + 10 * MIN, { sp: 70, lat: -38.05, lng: -68.0 }),
      ev(t0 + 20 * MIN, { id: 164, sp: 0, lat: -38.10, lng: -68.0 }), // Contacto OFF
      ev(t0 + 40 * MIN, { id: 7, sp: 55, lat: -38.10, lng: -68.0 }), // Fin detenido 20 min después
      ev(t0 + 50 * MIN, { sp: 70, lat: -38.15, lng: -68.0 }),
    ];
    const r = reconstruirJornada(rows);
    const p = r.pausas.find((x) => x.origen === 'contacto_off');
    assert.ok(p, 'pausa por contacto_off');
    assert.equal(p.durSeg, 20 * 60);
    assert.equal(p.cierraBloque, true);
    assert.equal(r.bloques.length, 2);
  });
});

describe('v3 sintético — pausa encubierta por gap + misma posición', () => {
  test('gap 30 min sin moverse (≤500 m) → pausa gap_misma_pos', () => {
    const t0 = Date.UTC(2026, 5, 6, 13, 0, 0);
    const rows = [
      ev(t0, { sp: 70, lat: -38.0, lng: -68.0 }),
      ev(t0 + 10 * MIN, { sp: 70, lat: -38.05, lng: -68.0 }),
      // 30 min después, prácticamente el mismo punto (paró sin cobertura):
      ev(t0 + 40 * MIN, { sp: 70, lat: -38.0501, lng: -68.0001 }),
      ev(t0 + 50 * MIN, { sp: 70, lat: -38.10, lng: -68.0 }),
    ];
    const r = reconstruirJornada(rows);
    const p = r.pausas.find((x) => x.origen === 'gap_misma_pos');
    assert.ok(p, 'pausa encubierta detectada');
    assert.equal(p.durSeg, 30 * 60);
    assert.equal(p.cierraBloque, true);
  });
});

describe('v3 sintético — gap grande con desplazamiento = manejo baja confianza', () => {
  test('gap 35 min moviéndose >500 m → manejo marcado baja confianza, no pausa', () => {
    const t0 = Date.UTC(2026, 5, 6, 13, 0, 0);
    const rows = [
      ev(t0, { sp: 70, lat: -38.0, lng: -68.0 }),
      ev(t0 + 10 * MIN, { sp: 70, lat: -38.05, lng: -68.0 }),
      // 35 min después (≥30, umbral baja), 39 km más lejos → siguió manejando
      // pero sin reportes: adentro pudo esconderse una parada que no vemos.
      ev(t0 + 45 * MIN, { sp: 70, lat: -38.40, lng: -68.0 }),
      ev(t0 + 55 * MIN, { sp: 70, lat: -38.45, lng: -68.0 }),
    ];
    const r = reconstruirJornada(rows);
    assert.equal(r.pausas.length, 0, 'no es pausa: se movió');
    const dudoso = r.segmentos.find((s) => s.tipo === 'manejo' && s.confianza === 'baja');
    assert.ok(dudoso, 'el manejo con gap+desplazamiento es baja confianza');
    assert.notEqual(r.confianza, 'alta');
  });
});

describe('v3 sintético — gap de ruta normal NO ensucia la confianza', () => {
  test('gap 20 min moviéndose (autopista, sin eventos 283) → confianza alta', () => {
    const t0 = Date.UTC(2026, 5, 6, 13, 0, 0);
    const rows = [
      ev(t0, { sp: 75, lat: -38.0, lng: -68.0 }),
      // 20 min recto sin reportes, 26 km más lejos: manejo normal, NO sospechoso.
      ev(t0 + 20 * MIN, { sp: 75, lat: -38.23, lng: -68.0 }),
      ev(t0 + 30 * MIN, { sp: 75, lat: -38.33, lng: -68.0 }),
    ];
    const r = reconstruirJornada(rows);
    assert.equal(r.confianza, 'alta');
    assert.equal(r.pausas.length, 0);
  });

  test('gap 20 min SIN posición → baja confianza (tramo ciego)', () => {
    const t0 = Date.UTC(2026, 5, 6, 13, 0, 0);
    const rows = [
      ev(t0, { sp: 75, lat: -38.0, lng: -68.0 }),
      // Sin lat/lng: no sabemos si paró → ciego desde los 15 min.
      ev(t0 + 20 * MIN, { sp: 75, lat: null, lng: null }),
      ev(t0 + 30 * MIN, { sp: 75, lat: -38.2, lng: -68.0 }),
    ];
    const r = reconstruirJornada(rows);
    const ciego = r.segmentos.find((s) => s.confianza === 'baja');
    assert.ok(ciego, 'el tramo sin posición debe ser baja confianza');
    assert.match(ciego.motivoBaja, /sin reportes ni posición/);
  });
});

describe('v3 sintético — baja confianza por Bloqueo GPS (386)', () => {
  test('un evento 386 en el turno → confianza global baja', () => {
    const t0 = Date.UTC(2026, 5, 6, 13, 0, 0);
    const rows = [
      ev(t0, { sp: 70, lat: -38.0, lng: -68.0 }),
      ev(t0 + 5 * MIN, { id: 386, sp: 0, lat: -38.02, lng: -68.0 }), // Bloqueo GPS
      ev(t0 + 10 * MIN, { sp: 70, lat: -38.04, lng: -68.0 }),
    ];
    const r = reconstruirJornada(rows);
    assert.equal(r.confianza, 'baja');
  });
});

describe('v3 sintético — bloque excedido (4 h sin pausa)', () => {
  test('4h10 de manejo continuo sin pausa ≥15 min → bloque excedido', () => {
    const t0 = Date.UTC(2026, 5, 6, 11, 0, 0);
    const rows = [];
    // 26 eventos cada 10 min = 25 × 10 min = 4h10 de manejo, avanzando.
    for (let i = 0; i < 26; i++) {
      rows.push(ev(t0 + i * 10 * MIN, { sp: 70, lat: -38.0 + i * 0.02, lng: -68.0 }));
    }
    const r = reconstruirJornada(rows);
    assert.equal(r.bloques.length, 1);
    assert.equal(r.bloques[0].excedido, true);
    assert.equal(r.bloquesExcedidos, 1);
    assert.ok(r.bloques[0].manejoNetoSeg >= BLOQUE_EXCEDIDO_SEGUNDOS);
  });
});

// ══════════════════════════════════════════════════════════════════════
// Turnos: corte por descanso de 8 h y cruce de medianoche
// ══════════════════════════════════════════════════════════════════════

describe('v3 — partición en turnos', () => {
  test('descanso ≥8 h corta el turno; reconstruirJornadas devuelve 2', () => {
    const dia1 = Date.UTC(2026, 5, 6, 12, 0, 0); // 09:00 ART
    const rows = [
      ev(dia1, { sp: 70, lat: -38.0, lng: -68.0 }),
      ev(dia1 + 30 * MIN, { sp: 70, lat: -38.1, lng: -68.0 }),
      ev(dia1 + 60 * MIN, { id: 164, sp: 0, lat: -38.2, lng: -68.0 }), // para a dormir
      // 9 h después arranca el día 2:
      ev(dia1 + 60 * MIN + 9 * H, { id: 7, sp: 60, lat: -38.2, lng: -68.0 }),
      ev(dia1 + 60 * MIN + 9 * H + 30 * MIN, { sp: 70, lat: -38.3, lng: -68.0 }),
    ];
    assert.equal(partirEnTurnos(rows).length, 2);
    const jornadas = reconstruirJornadas(rows);
    assert.equal(jornadas.length, 2);
    // reconstruirJornada (singular) trae solo la primera, cerrada antes del gap.
    const r1 = reconstruirJornada(rows);
    assert.ok(r1.finTurnoMs <= dia1 + 60 * MIN,
      'el turno 1 cierra en su último evento, antes del descanso');
  });

  test('turno que cruza medianoche (gaps < 8 h) NO se parte', () => {
    const t0 = Date.UTC(2026, 5, 6, 2, 0, 0); // 23:00 ART del 5/6
    const rows = [
      ev(t0, { sp: 70, lat: -38.0, lng: -68.0 }),
      ev(t0 + 1 * H, { sp: 70, lat: -38.1, lng: -68.0 }), // 00:00 ART
      ev(t0 + 2 * H, { sp: 70, lat: -38.2, lng: -68.0 }), // 01:00 ART
    ];
    assert.equal(partirEnTurnos(rows).length, 1);
    assert.equal(reconstruirJornadas(rows).length, 1);
  });
});

// ══════════════════════════════════════════════════════════════════════
// Bordes
// ══════════════════════════════════════════════════════════════════════

describe('v3 — bordes', () => {
  test('sin eventos → jornada vacía', () => {
    const r = reconstruirJornada([]);
    assert.equal(r.inicioTurnoMs, null);
    assert.equal(r.bloques.length, 0);
    assert.deepEqual(r.explicacion, []);
  });

  test('todo parado (nunca manejó) → jornada vacía', () => {
    const t0 = Date.UTC(2026, 5, 6, 13, 0, 0);
    const rows = [
      ev(t0, { id: 164, sp: 0, lat: -38.0, lng: -68.0 }),
      ev(t0 + 30 * MIN, { id: 6, sp: 0, lat: -38.0, lng: -68.0 }),
    ];
    const r = reconstruirJornada(rows);
    assert.equal(r.inicioTurnoMs, null);
  });

  test('horaMinArt formatea en ART y normaliza medianoche', () => {
    assert.equal(horaMinArt(Date.UTC(2026, 5, 6, 15, 30, 0)), '12:30'); // 12:30 ART
    assert.equal(horaMinArt(Date.UTC(2026, 5, 6, 3, 0, 0)), '00:00'); // 00:00 ART
  });
});
