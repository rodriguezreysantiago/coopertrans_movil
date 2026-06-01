// Tests de la máquina de estados PURA del vigilador de jornada v2
// (`evaluarTickJornada`). Extraída de `tickVigiladorJornada` el
// 2026-05-19 justamente para poder lockear esta lógica sin emulator.
//
// Cubre el fix del mismo día: avisos de jornada por MANEJO NETO
// acumulado (cuota_proxima 11h / cuota 12h) en lugar de por
// `bloques_completos >= 3` (que daba falsos positivos — caso César:
// 3 bloques con 7h54 manejo real recibía "12h jornada").
//
// Estrategia: igual que jornadas_v2_helpers.test.js — testear el
// compilado lib/jornadas_v2.js. Sin Firebase: evaluarTickJornada es
// pura (el query de la excepción de veda lo externalizamos al caller).

const { test, describe } = require('node:test');
const assert = require('node:assert');
const { Timestamp } = require('firebase-admin/firestore');

const {
  evaluarTickJornada,
  analizarEventosDetencion,
  construirMensajeResumenJornadas,
  BLOQUE_ALERTA_TEMPRANA_SEGUNDOS, // 3h30
  BLOQUE_EXCEDIDO_SEGUNDOS, // 4h
  JORNADA_MANEJO_PROXIMA_SEGUNDOS, // 11h
  JORNADA_MANEJO_LIMITE_SEGUNDOS, // 12h
  PAUSA_BLOQUE_SEGUNDOS, // 15 min
  DESCANSO_MIN_SEGUNDOS, // 8h
} = require('../lib/jornadas_v2');

// ── Helpers ─────────────────────────────────────────────────────────

const T0 = Timestamp.fromMillis(0);

function nuevaJornadaTest(overrides = {}) {
  return {
    chofer_dni: '123',
    jornada_inicio_ts: T0,
    jornada_fin_ts: null,
    bloques_completos: 0,
    bloque_actual_manejo_seg: 0,
    bloque_actual_pausa_seg: 0,
    total_manejo_seg: 0,
    ultima_actualizacion_ts: T0,
    ultima_patente: 'AAA111',
    ultima_lat: null,
    ultima_lng: null,
    descanso_inicio_ts: null,
    descanso_inicio_lat: null,
    descanso_inicio_lng: null,
    descanso_segundos: 0,
    estado: 'manejando',
    alerta_3_30_enviada: false,
    alerta_3_45_enviada: false,
    alerta_cuota_proxima_enviada: false,
    alerta_cuota_enviada: false,
    alerta_veda_enviada: false,
    bloque_excedido: false,
    cuota_excedida: false,
    veda_excedida: false,
    creado_en: T0,
    ...overrides,
  };
}

// 12:00 ART (= 15:00 UTC) — fuera de veda nocturna.
const MEDIODIA_MS = Date.UTC(2026, 4, 19, 15, 0, 0);
// 02:00 ART (= 05:00 UTC) — dentro de veda nocturna (00:00-06:00).
const VEDA_MS = Date.UTC(2026, 4, 19, 5, 0, 0);

function tickManejando(j, deltaSeg, opts = {}) {
  return evaluarTickJornada(j, {
    manejando: true,
    deltaSeg,
    ahoraMs: opts.ahoraMs ?? MEDIODIA_MS,
    lat: opts.lat ?? null,
    lng: opts.lng ?? null,
    tieneDescansoPrevio: opts.tieneDescansoPrevio ?? false,
    paroEnMs: opts.paroEnMs ?? null,
    arrancoMs: opts.arrancoMs ?? null,
    pausaPreviaSeg: opts.pausaPreviaSeg ?? null,
  });
}

function tickParado(j, deltaSeg, opts = {}) {
  return evaluarTickJornada(j, {
    manejando: false,
    deltaSeg,
    ahoraMs: opts.ahoraMs ?? MEDIODIA_MS,
    lat: opts.lat ?? null,
    lng: opts.lng ?? null,
    tieneDescansoPrevio: false,
    paroEnMs: opts.paroEnMs ?? null,
    arrancoMs: opts.arrancoMs ?? null,
    pausaPreviaSeg: opts.pausaPreviaSeg ?? null,
  });
}

// ── Manejo: acumulación + avisos de bloque ──────────────────────────

describe('evaluarTickJornada — manejando, acumulación', () => {
  test('suma deltaSeg al bloque actual de manejo', () => {
    const j = nuevaJornadaTest();
    tickManejando(j, 600);
    assert.strictEqual(j.bloque_actual_manejo_seg, 600);
    assert.strictEqual(j.estado, 'manejando');
  });

  test('resetea pausa y tracking de descanso al manejar (descanso corto)', () => {
    const j = nuevaJornadaTest({
      bloque_actual_pausa_seg: 300,
      descanso_segundos: 1000,
      // Paró hace 1h (pausa, NO descanso de jornada de 8h): al volver a
      // manejar debe resetear el tracking y seguir la MISMA jornada.
      descanso_inicio_ts: Timestamp.fromMillis(MEDIODIA_MS - 3600 * 1000),
    });
    const { cerrada } = tickManejando(j, 600);
    assert.ok(!cerrada, 'no debe cerrar la jornada por una pausa corta');
    assert.strictEqual(j.bloque_actual_pausa_seg, 0);
    assert.strictEqual(j.descanso_segundos, 0);
    assert.strictEqual(j.descanso_inicio_ts, null);
  });

  // Regresión Balbiano 2026-06-01: paró 23:23, el equipo se APAGÓ (dejó de
  // transmitir → gap de horas sin reporte) y arrancó 07:26. El tracking
  // incremental del descanso (+= deltaSeg tick a tick) no acumuló nada
  // porque el tick no veía al camión, y la ventana de eventos (2h) no
  // alcanzaba a ver cuándo paró → el sistema seguía contando la jornada del
  // día anterior y le mandó "11h de conducción". El fix mide el descanso por
  // la DURACIÓN real desde que paró (descanso_inicio_ts) y, al arrancar tras
  // ≥8h, cierra la jornada (descanso de jornada cumplido).
  test('arranca tras ≥8h parado (camión apagado) → cierra jornada por descanso', () => {
    const j = nuevaJornadaTest({
      estado: 'descanso',
      // Paró hace 8h 3min (≥ DESCANSO_MIN_SEGUNDOS = 8h) en una posición.
      descanso_inicio_ts: Timestamp.fromMillis(
        MEDIODIA_MS - (DESCANSO_MIN_SEGUNDOS + 180) * 1000,
      ),
      descanso_inicio_lat: -38.0,
      descanso_inicio_lng: -68.0,
      // El tracking incremental "perdió" el descanso por el gap de reporte.
      descanso_segundos: 0,
    });
    const { cerrada } = tickManejando(j, 600);
    assert.ok(cerrada, 'debe cerrar la jornada al arrancar tras el descanso');
    assert.strictEqual(j.estado, 'descanso_jornada');
    assert.ok(
      j.descanso_segundos >= DESCANSO_MIN_SEGUNDOS,
      'descanso registrado >= 8h aunque el tracking incremental fuera 0',
    );
    assert.ok(j.jornada_fin_ts != null, 'jornada cerrada con fin_ts');
  });
});

describe('evaluarTickJornada — descanso por gap de reporte (camión apagado)', () => {
  test('reaparece PARADO tras gap largo en misma posición → ancla descanso al gap y cierra', () => {
    // El equipo se apagó ~8h (no reportó), el tick nunca lo procesó →
    // descanso_inicio_ts quedó null. Reaparece PARADO en la misma posición:
    // anclamos el descanso al último tick visto y lo damos por cumplido.
    const ultVisto = Timestamp.fromMillis(
      MEDIODIA_MS - (DESCANSO_MIN_SEGUNDOS + 300) * 1000,
    );
    const j = nuevaJornadaTest({
      estado: 'pausa_intra_bloque',
      descanso_inicio_ts: null,
      descanso_segundos: 0,
      ultima_actualizacion_ts: ultVisto,
      ultima_lat: -38.0,
      ultima_lng: -68.0,
    });
    const { cerrada } = tickParado(j, 60, { lat: -38.0001, lng: -68.0001 });
    assert.ok(cerrada, 'debe cerrar la jornada (descanso de 8h por gap)');
    assert.strictEqual(j.estado, 'descanso_jornada');
    assert.ok(j.descanso_segundos >= DESCANSO_MIN_SEGUNDOS);
  });

  test('reaparece PARADO tras gap largo en OTRA posición → NO ancla (siguió en ruta)', () => {
    const ultVisto = Timestamp.fromMillis(
      MEDIODIA_MS - (DESCANSO_MIN_SEGUNDOS + 300) * 1000,
    );
    const j = nuevaJornadaTest({
      descanso_inicio_ts: null,
      descanso_segundos: 0,
      ultima_actualizacion_ts: ultVisto,
      ultima_lat: -38.0,
      ultima_lng: -68.0,
    });
    // Reaparece a ~200 km: no es un descanso en el lugar → no debe anclar.
    const { cerrada } = tickParado(j, 60, { lat: -39.5, lng: -69.5 });
    assert.ok(!cerrada, 'no debe cerrar: reapareció en otra posición');
    assert.strictEqual(j.descanso_segundos, 0);
  });

  test('gap corto (5 min, dentro de operación normal) NO ancla', () => {
    const ultVisto = Timestamp.fromMillis(MEDIODIA_MS - 300 * 1000);
    const j = nuevaJornadaTest({
      descanso_inicio_ts: null,
      descanso_segundos: 0,
      ultima_actualizacion_ts: ultVisto,
      ultima_lat: -38.0,
      ultima_lng: -68.0,
    });
    const { cerrada } = tickParado(j, 60, { lat: -38.0, lng: -68.0 });
    assert.ok(!cerrada);
    // Sin gap significativo, el descanso arranca en ~0 (no anclado al pasado).
    assert.ok(j.descanso_segundos < 60);
  });
});

describe('evaluarTickJornada — aviso 3h30 (manejo continuo)', () => {
  test('cruza 3h30 → aviso "3h30" + flag', () => {
    const j = nuevaJornadaTest({
      bloque_actual_manejo_seg: BLOQUE_ALERTA_TEMPRANA_SEGUNDOS - 100,
    });
    const { avisos } = tickManejando(j, 200);
    assert.ok(avisos.includes('3h30'));
    assert.strictEqual(j.alerta_3_30_enviada, true);
  });

  test('idempotente: segundo tick no re-avisa 3h30', () => {
    const j = nuevaJornadaTest({
      bloque_actual_manejo_seg: BLOQUE_ALERTA_TEMPRANA_SEGUNDOS + 100,
      alerta_3_30_enviada: true,
    });
    const { avisos } = tickManejando(j, 200);
    assert.ok(!avisos.includes('3h30'));
  });

  test('antes de 3h30 no avisa', () => {
    const j = nuevaJornadaTest({
      bloque_actual_manejo_seg: BLOQUE_ALERTA_TEMPRANA_SEGUNDOS - 600,
    });
    const { avisos } = tickManejando(j, 60);
    assert.ok(!avisos.includes('3h30'));
  });
});

describe('evaluarTickJornada — aviso 4h (bloque excedido)', () => {
  test('cruza 4h → "bloque_excedido" + flag', () => {
    const j = nuevaJornadaTest({
      bloque_actual_manejo_seg: BLOQUE_EXCEDIDO_SEGUNDOS - 100,
    });
    const { avisos } = tickManejando(j, 200);
    assert.ok(avisos.includes('bloque_excedido'));
    assert.strictEqual(j.bloque_excedido, true);
  });

  test('idempotente: no re-avisa si ya excedido', () => {
    const j = nuevaJornadaTest({
      bloque_actual_manejo_seg: BLOQUE_EXCEDIDO_SEGUNDOS + 500,
      bloque_excedido: true,
    });
    const { avisos } = tickManejando(j, 200);
    assert.ok(!avisos.includes('bloque_excedido'));
  });

  // Regresión 2026-05-22: el flag se seteaba 1 vez y nunca se reseteaba al
  // cerrar bloque → el aviso de 4h salía 1 vez por JORNADA, no por bloque.
  test('reset por bloque: 4h en un 2º bloque de la misma jornada re-avisa', () => {
    // Bloque 1: cruza 4h → bloque_excedido.
    const j = nuevaJornadaTest({
      bloque_actual_manejo_seg: BLOQUE_EXCEDIDO_SEGUNDOS - 100,
    });
    const r1 = tickManejando(j, 200);
    assert.ok(r1.avisos.includes('bloque_excedido'));
    assert.strictEqual(j.bloque_excedido, true);

    // Pausa >= 15 min: cierra el bloque y DEBE resetear bloque_excedido.
    tickParado(j, PAUSA_BLOQUE_SEGUNDOS);
    assert.strictEqual(
      j.bloque_excedido, false,
      'al cerrar el bloque, bloque_excedido vuelve a false'
    );

    // Bloque 2: vuelve a cruzar 4h continuas → DEBE re-avisar.
    const r2 = tickManejando(j, BLOQUE_EXCEDIDO_SEGUNDOS + 100);
    assert.ok(
      r2.avisos.includes('bloque_excedido'),
      'la 2ª infracción de 4h en la misma jornada también avisa'
    );
  });
});

// ── Jornada por MANEJO NETO (el fix de 2026-05-19) ──────────────────

describe('evaluarTickJornada — cuota por manejo NETO (fix Santiago)', () => {
  test('manejo neto cruza 11h → "cuota_proxima" (heads-up)', () => {
    const j = nuevaJornadaTest({
      total_manejo_seg: JORNADA_MANEJO_PROXIMA_SEGUNDOS - 100,
    });
    const { avisos } = tickManejando(j, 200);
    assert.ok(avisos.includes('cuota_proxima'));
    assert.strictEqual(j.alerta_cuota_proxima_enviada, true);
    assert.ok(!avisos.includes('cuota'));
  });

  test('manejo neto cruza 12h → "cuota" (límite) + marca proxima', () => {
    const j = nuevaJornadaTest({
      total_manejo_seg: JORNADA_MANEJO_LIMITE_SEGUNDOS - 100,
    });
    const { avisos } = tickManejando(j, 200);
    assert.ok(avisos.includes('cuota'));
    assert.strictEqual(j.alerta_cuota_enviada, true);
    assert.strictEqual(j.cuota_excedida, true);
    // Forzamos el flag de heads-up para no mandar "11h" después del firme.
    assert.strictEqual(j.alerta_cuota_proxima_enviada, true);
  });

  test('REGRESIÓN bug César: 3 bloques con manejo neto < 11h NO dispara cuota', () => {
    // Caso real 2026-05-19: César tenía bloques_completos=3 con 7h54 de
    // manejo neto real. El modelo viejo (bloques >= 3) le mandaba "12h
    // jornada". Ahora el disparador es manejo neto → no debe avisar.
    const j = nuevaJornadaTest({
      bloques_completos: 3,
      total_manejo_seg: 7 * 3600 + 54 * 60, // 7h54
      bloque_actual_manejo_seg: 0,
    });
    const { avisos } = tickManejando(j, 600);
    assert.ok(!avisos.includes('cuota'), 'no debe mandar cuota con 7h54 neto');
    assert.ok(!avisos.includes('cuota_proxima'), 'tampoco heads-up < 11h');
    assert.strictEqual(j.cuota_excedida, false);
  });

  test('cuenta el bloque actual abierto en el manejo neto', () => {
    // 10h cerradas + 1h05 en bloque abierto = 11h05 → cruza 11h.
    const j = nuevaJornadaTest({
      total_manejo_seg: 10 * 3600,
      bloque_actual_manejo_seg: 60 * 60 + 4 * 60, // 1h04
    });
    const { avisos } = tickManejando(j, 120); // +2 min → 11h06 neto
    assert.ok(avisos.includes('cuota_proxima'));
  });

  test('jerárquico: si ya pasó 12h no manda heads-up de 11h', () => {
    const j = nuevaJornadaTest({
      total_manejo_seg: JORNADA_MANEJO_LIMITE_SEGUNDOS + 3600, // 13h
      alerta_cuota_enviada: true,
      cuota_excedida: true,
    });
    const { avisos } = tickManejando(j, 200);
    assert.ok(!avisos.includes('cuota_proxima'));
    assert.ok(!avisos.includes('cuota')); // ya enviada
  });
});

// ── Veda nocturna ───────────────────────────────────────────────────

describe('evaluarTickJornada — veda nocturna', () => {
  test('manejando en veda (02:00 ART) sin descanso previo → "veda"', () => {
    const j = nuevaJornadaTest({ total_manejo_seg: 3 * 3600 });
    const { avisos } = tickManejando(j, 200, { ahoraMs: VEDA_MS });
    assert.ok(avisos.includes('veda'));
    assert.strictEqual(j.veda_excedida, true);
  });

  test('en veda + manejo < 2h + descanso previo → NO avisa (salida legítima)', () => {
    const j = nuevaJornadaTest({ total_manejo_seg: 30 * 60 }); // 30 min
    const { avisos } = tickManejando(j, 200, {
      ahoraMs: VEDA_MS,
      tieneDescansoPrevio: true,
    });
    assert.ok(!avisos.includes('veda'));
  });

  test('en veda + manejo >= 2h → avisa aunque tenga descanso previo', () => {
    const j = nuevaJornadaTest({ total_manejo_seg: 3 * 3600 }); // 3h
    const { avisos } = tickManejando(j, 200, {
      ahoraMs: VEDA_MS,
      tieneDescansoPrevio: true,
    });
    assert.ok(avisos.includes('veda'));
  });

  test('mediodía (fuera de veda) nunca avisa veda', () => {
    const j = nuevaJornadaTest({ total_manejo_seg: 3 * 3600 });
    const { avisos } = tickManejando(j, 200, { ahoraMs: MEDIODIA_MS });
    assert.ok(!avisos.includes('veda'));
  });
});

// ── Parado: pausa, cierre de bloque, descanso ───────────────────────

describe('evaluarTickJornada — parado', () => {
  test('pausa < 15 min no cierra el bloque', () => {
    const j = nuevaJornadaTest({ bloque_actual_manejo_seg: 2 * 3600 });
    tickParado(j, 5 * 60); // 5 min
    assert.strictEqual(j.bloques_completos, 0);
    assert.strictEqual(j.bloque_actual_manejo_seg, 2 * 3600); // intacto
    assert.strictEqual(j.estado, 'pausa_intra_bloque');
  });

  test('pausa >= 15 min con manejo previo cierra el bloque', () => {
    const j = nuevaJornadaTest({
      bloque_actual_manejo_seg: 3 * 3600,
      total_manejo_seg: 1 * 3600,
      bloque_actual_pausa_seg: PAUSA_BLOQUE_SEGUNDOS - 60,
      alerta_3_30_enviada: true,
    });
    tickParado(j, 120); // cruza 15 min
    assert.strictEqual(j.bloques_completos, 1);
    assert.strictEqual(j.total_manejo_seg, 4 * 3600); // 1h + 3h del bloque
    assert.strictEqual(j.bloque_actual_manejo_seg, 0);
    assert.strictEqual(j.alerta_3_30_enviada, false); // reset para próximo bloque
    assert.strictEqual(j.estado, 'descanso_post_bloque');
  });

  test('descanso 8h misma posición cierra la jornada', () => {
    const j = nuevaJornadaTest({
      descanso_inicio_ts: T0,
      descanso_inicio_lat: -38.7,
      descanso_inicio_lng: -62.27,
      descanso_segundos: DESCANSO_MIN_SEGUNDOS - 100,
    });
    const { cerrada } = tickParado(j, 200, { lat: -38.7, lng: -62.27 });
    assert.strictEqual(cerrada, true);
    assert.strictEqual(j.estado, 'descanso_jornada');
    assert.ok(j.jornada_fin_ts != null);
  });

  test('moverse > 1000 m resetea el descanso acumulado', () => {
    const j = nuevaJornadaTest({
      descanso_inicio_ts: T0,
      descanso_inicio_lat: -38.7,
      descanso_inicio_lng: -62.27,
      descanso_segundos: 5 * 3600, // ya llevaba 5h
    });
    // ~3 km al norte (lat +0.03 ≈ 3.3 km) → fuera del radio 1000 m.
    const { cerrada } = tickParado(j, 200, { lat: -38.67, lng: -62.27 });
    assert.strictEqual(j.descanso_segundos, 0); // reset
    assert.strictEqual(cerrada, false);
  });

  test('primer tick parado con GPS arranca el tracking de descanso', () => {
    const j = nuevaJornadaTest({ descanso_inicio_ts: null });
    tickParado(j, 300, { lat: -38.7, lng: -62.27 });
    assert.ok(j.descanso_inicio_ts != null);
    assert.strictEqual(j.descanso_segundos, 0); // primer tick: arranca, no acumula
  });
});

// ── Resumen diario de jornadas a Molina (construcción del mensaje) ──

describe('construirMensajeResumenJornadas', () => {
  const T = (ms) => Timestamp.fromMillis(ms);
  // 19/05/2026 06:30 ART = 09:30 UTC.
  const inicioMs = Date.UTC(2026, 4, 19, 9, 30, 0);

  function exceso(over = {}) {
    return {
      choferDni: '123',
      patente: 'AAA111',
      inicio: T(inicioMs),
      fin: null,
      bloquesCompletos: 3,
      totalManejoSeg: 12 * 3600,
      bloqueExcedido: false,
      cuotaExcedida: false,
      vedaExcedida: false,
      ...over,
    };
  }

  test('sin excesos → mensaje "Sin incidencias"', () => {
    const m = construirMensajeResumenJornadas([], new Map(), 'Hola Molina', '19/05/2026');
    assert.match(m, /Sin incidencias/);
    assert.match(m, /Hola Molina/);
    assert.match(m, /19\/05\/2026/);
  });

  test('1 exceso de bloque → muestra flag + nombre + patente', () => {
    const nombres = new Map([['123', 'PEREZ JUAN']]);
    const m = construirMensajeResumenJornadas(
      [exceso({ bloqueExcedido: true })], nombres, 'Hola', '19/05/2026'
    );
    assert.match(m, /1 jornada con/); // singular
    assert.match(m, /PEREZ JUAN/);
    assert.match(m, /AAA111/);
    assert.match(m, /bloque > 4h sin pausa/);
  });

  test('nombre faltante cae a "DNI X"', () => {
    const m = construirMensajeResumenJornadas(
      [exceso({ vedaExcedida: true })], new Map(), 'Hola', '19/05/2026'
    );
    assert.match(m, /DNI 123/);
    assert.match(m, /circuló después de 00:00 ART/);
  });

  test('múltiples flags se listan juntos', () => {
    const m = construirMensajeResumenJornadas(
      [exceso({ bloqueExcedido: true, cuotaExcedida: true, vedaExcedida: true })],
      new Map(), 'Hola', '19/05/2026'
    );
    assert.match(m, /bloque > 4h sin pausa/);
    assert.match(m, /manejó post-cuota cumplida/);
    assert.match(m, /circuló después de 00:00 ART/);
  });

  test('plural con 2+ excesos', () => {
    const m = construirMensajeResumenJornadas(
      [exceso({ bloqueExcedido: true }), exceso({ choferDni: '456', vedaExcedida: true })],
      new Map(), 'Hola', '19/05/2026'
    );
    assert.match(m, /2 jornadas con/);
  });
});

// ── analizarEventosDetencion (PURA) — fix AB493CP 2026-05-29 ─────────

describe('analizarEventosDetencion', () => {
  // evento a las 17:<min> ART (= 20:<min> UTC).
  const ev = (min, speed, eventId = null) => ({
    ms: Date.UTC(2026, 4, 28, 20, min, 0), speed, gpsSpeed: speed, eventId,
  });

  test('sin eventos → fuente sin_eventos (caller usa fallback)', () => {
    const r = analizarEventosDetencion([], Date.UTC(2026, 4, 28, 20, 30, 0));
    assert.strictEqual(r.fuente, 'sin_eventos');
    assert.strictEqual(r.parado, false);
    assert.strictEqual(r.paroEnMs, null);
  });

  test('último evento en movimiento → manejando, sin pausa previa', () => {
    const r = analizarEventosDetencion(
      [ev(0, 40), ev(5, 50), ev(10, 45)], Date.UTC(2026, 4, 28, 20, 12, 0)
    );
    assert.strictEqual(r.parado, false);
    assert.strictEqual(r.fuente, 'eventos');
    assert.strictEqual(r.pausaPreviaSeg, null);
  });

  test('parado → paroEnMs = primer no-movimiento tras el último movimiento', () => {
    const eventos = [ev(0, 40), ev(5, 45), ev(10, 0), ev(15, 0)];
    const ahora = Date.UTC(2026, 4, 28, 20, 20, 0); // 17:20
    const r = analizarEventosDetencion(eventos, ahora);
    assert.strictEqual(r.parado, true);
    assert.strictEqual(r.paroEnMs, eventos[2].ms); // 17:10
    assert.strictEqual((ahora - r.paroEnMs) / 60000, 10); // 10 min en curso
  });

  test('arrancó tras pausa → pausaPreviaSeg = arranque − paró', () => {
    const eventos = [ev(0, 40), ev(5, 0), ev(10, 0), ev(22, 60)];
    const r = analizarEventosDetencion(eventos, Date.UTC(2026, 4, 28, 20, 25, 0));
    assert.strictEqual(r.parado, false);
    assert.strictEqual(r.arrancoMs, eventos[3].ms); // 17:22
    assert.strictEqual(r.pausaPreviaSeg, 17 * 60); // 17:22 − 17:05 = 17 min
  });

  test('"Fin de detenido" (eventId 7) cuenta como movimiento aunque speed bajo', () => {
    const eventos = [
      ev(0, 40), ev(5, 0), ev(10, 0),
      { ms: Date.UTC(2026, 4, 28, 20, 20, 0), speed: 5, gpsSpeed: 5, eventId: 7 },
    ];
    const r = analizarEventosDetencion(eventos, Date.UTC(2026, 4, 28, 20, 25, 0));
    assert.strictEqual(r.parado, false); // el "Fin de detenido" marca arranque
  });

  test('REPRODUCE caso AB493CP: pausa de 17 min se detecta', () => {
    // Datos reales del 28/5: último mov 17:14, Contacto OFF 17:25 (speed 0),
    // detenido 17:27 y 17:39, arranca 17:42 (Fin de detenido).
    const eventos = [
      ev(14, 40), ev(25, 0), ev(27, 0), ev(39, 0), ev(42, 70, 7),
    ];
    const r = analizarEventosDetencion(eventos, Date.UTC(2026, 4, 28, 20, 45, 0));
    assert.strictEqual(r.parado, false); // ya arrancó
    assert.ok(r.pausaPreviaSeg >= PAUSA_BLOQUE_SEGUNDOS); // ≥ 15 min → cierra
    assert.strictEqual(Math.round(r.pausaPreviaSeg / 60), 17); // 17 min
  });
});

// ── evaluarTickJornada con detección por eventos (fix AB493CP) ───────

describe('evaluarTickJornada — pausa por eventos (fix AB493CP)', () => {
  test('pausa en curso medida por paroEnMs (NO acumulada por deltaSeg)', () => {
    const ahora = MEDIODIA_MS;
    const j = nuevaJornadaTest({ bloque_actual_manejo_seg: 3000 });
    tickParado(j, 600, { ahoraMs: ahora, paroEnMs: ahora - 10 * 60 * 1000 });
    assert.strictEqual(j.bloque_actual_pausa_seg, 600); // 10 min reales
  });

  test('cierra bloque con pausa en curso ≥15min (motor apagado, sin acumular)', () => {
    const ahora = MEDIODIA_MS;
    const j = nuevaJornadaTest({ bloque_actual_manejo_seg: 10000 });
    tickParado(j, 600, { ahoraMs: ahora, paroEnMs: ahora - 15 * 60 * 1000 });
    assert.strictEqual(j.bloques_completos, 1);
    assert.strictEqual(j.bloque_actual_manejo_seg, 0);
    assert.strictEqual(j.estado, 'descanso_post_bloque');
  });

  test('NO cierra bloque si la pausa en curso < 15 min', () => {
    const ahora = MEDIODIA_MS;
    const j = nuevaJornadaTest({ bloque_actual_manejo_seg: 10000 });
    tickParado(j, 600, { ahoraMs: ahora, paroEnMs: ahora - 14 * 60 * 1000 });
    assert.strictEqual(j.bloques_completos, 0);
  });

  test('cierra bloque RETROACTIVO cuando arrancó tras pausa ≥15min entre ticks', () => {
    const ahora = MEDIODIA_MS;
    const j = nuevaJornadaTest({
      bloque_actual_manejo_seg: 12000,
      ultima_actualizacion_ts: Timestamp.fromMillis(ahora - 5 * 60 * 1000),
    });
    tickManejando(j, 300, {
      ahoraMs: ahora, arrancoMs: ahora - 2 * 60 * 1000, pausaPreviaSeg: 17 * 60,
    });
    assert.strictEqual(j.bloques_completos, 1); // cerró por la pausa previa
    assert.strictEqual(j.bloque_actual_manejo_seg, 300); // nuevo bloque arranca
  });

  test('idempotencia: NO recuenta pausa previa si arrancó ANTES del último tick', () => {
    const ahora = MEDIODIA_MS;
    const j = nuevaJornadaTest({
      bloque_actual_manejo_seg: 1000,
      ultima_actualizacion_ts: Timestamp.fromMillis(ahora - 5 * 60 * 1000),
    });
    tickManejando(j, 300, {
      ahoraMs: ahora, arrancoMs: ahora - 8 * 60 * 1000, pausaPreviaSeg: 17 * 60,
    });
    assert.strictEqual(j.bloques_completos, 0); // arranque viejo, ya contado
  });

  test('idempotencia: parado ≥15min varios ticks no incrementa bloques 2 veces', () => {
    const ahora = MEDIODIA_MS;
    const paroEnMs = ahora - 20 * 60 * 1000;
    const j = nuevaJornadaTest({ bloque_actual_manejo_seg: 10000 });
    tickParado(j, 600, { ahoraMs: ahora, paroEnMs });
    assert.strictEqual(j.bloques_completos, 1);
    tickParado(j, 600, { ahoraMs: ahora + 5 * 60 * 1000, paroEnMs });
    assert.strictEqual(j.bloques_completos, 1); // manejo ya en 0 → no recuenta
  });

  test('fallback: sin paroEnMs (sin eventos) acumula por deltaSeg como antes', () => {
    const j = nuevaJornadaTest({ bloque_actual_manejo_seg: 10000 });
    tickParado(j, 900); // sin opts → paroEnMs null → fallback
    assert.strictEqual(j.bloques_completos, 1); // 900s = 15min acumulados
  });
});
