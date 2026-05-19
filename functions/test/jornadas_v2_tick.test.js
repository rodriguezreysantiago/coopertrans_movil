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

  test('resetea pausa y tracking de descanso al manejar', () => {
    const j = nuevaJornadaTest({
      bloque_actual_pausa_seg: 300,
      descanso_segundos: 1000,
      descanso_inicio_ts: T0,
    });
    tickManejando(j, 600);
    assert.strictEqual(j.bloque_actual_pausa_seg, 0);
    assert.strictEqual(j.descanso_segundos, 0);
    assert.strictEqual(j.descanso_inicio_ts, null);
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
