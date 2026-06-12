// Tests del cruce PARADAS_REPORTADAS ↔ REGISTRO_JORNADAS v3 (D Fase 2).
//
// El cron lee paradas reportadas con `estado=pendiente_cruce` y, contra las
// pausas que v3 detectó ese día, decide:
//   - confirmada_v3: v3 vio la pausa cerca del inicio reportado (±20 min).
//   - no_vista_v3: v3 no la ve → se escala a REPORTES_DISCREPANCIA auto.
//
// Estrategia: probamos la función PURA `cruzarUnaParada` (sin Firestore) con
// casos sintéticos cubriendo todos los caminos del veredicto.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  cruzarUnaParada,
  cruzarParadasConJornadas,
  TOL_HORA_EXPLICITA_MS,
  DUR_MIN_PAUSA_OPERATIVA_SEG,
} = require('../lib/paradas_reportadas');

// Helpers ─────────────────────────────────────────────────────────────────────

const HORA_MS = 60 * 60 * 1000;
const MIN_MS = 60 * 1000;

// Construye un epoch ms ART arbitrario (no importa el día absoluto, solo los
// deltas entre la parada reportada y las pausas v3).
const BASE = 1780000000000;

function pausa(offsetMin, durMin, over = {}) {
  return {
    inicioMs: BASE + offsetMin * MIN_MS,
    finMs: BASE + (offsetMin + durMin) * MIN_MS,
    durSeg: durMin * 60,
    origen: over.origen || 'detenido',
    confianza: over.confianza || 'alta',
    cierraBloque: over.cierraBloque ?? (durMin >= 15),
  };
}

function paradaReportada(offsetMin, over = {}) {
  return {
    id: over.id || 'p1',
    choferDni: over.choferDni || '12345678',
    choferNombre: over.choferNombre || 'PEREZ JUAN',
    fecha: over.fecha || '2026-06-08',
    inicioMs: over.sinInicio ? null : BASE + offsetMin * MIN_MS,
    inicioLabel: over.sinInicio ? null : '11:40',
    finMs: over.finMs ?? null,
    finLabel: over.finLabel ?? null,
    motivo: over.motivo ?? null,
  };
}

// ══════════════════════════════════════════════════════════════════════
// Veredictos del cruce
// ══════════════════════════════════════════════════════════════════════

describe('cruzarUnaParada — happy paths', () => {
  test('parada coincide casi exacta con pausa v3 → confirmada_v3', () => {
    const p = paradaReportada(60); // chofer dice "paré a las +60 min"
    const v3 = [pausa(58, 25)]; // v3 ve pausa a +58 min de 25 min
    const v = cruzarUnaParada(p, v3);
    assert.strictEqual(v.estado, 'confirmada_v3');
    assert.strictEqual(v.pausa.durSeg, 25 * 60);
    assert.match(v.razon, /25 min/);
  });

  test('match al borde de la tolerancia (±20 min) → confirmada_v3', () => {
    const p = paradaReportada(120);
    // Pausa arranca 19 min antes — dentro del ±20 min.
    const v3 = [pausa(101, 20)];
    const v = cruzarUnaParada(p, v3);
    assert.strictEqual(v.estado, 'confirmada_v3');
  });

  test('elije la pausa correcta cuando hay varias', () => {
    const p = paradaReportada(200);
    const v3 = [
      pausa(60, 30),   // matutina, lejos
      pausa(195, 22),  // matchea
      pausa(400, 50),  // tarde, lejos
    ];
    const v = cruzarUnaParada(p, v3);
    assert.strictEqual(v.estado, 'confirmada_v3');
    assert.strictEqual(v.pausa.inicioMs, BASE + 195 * MIN_MS);
  });
});

function turno(finOffsetMin, durMin = 480) {
  return {
    inicioMs: BASE + (finOffsetMin - durMin) * MIN_MS,
    finMs: BASE + finOffsetMin * MIN_MS,
  };
}

// ══════════════════════════════════════════════════════════════════════
// Veredicto CONFIRMADA_FIN_TURNO (descanso de fin de jornada)
// ══════════════════════════════════════════════════════════════════════

describe('cruzarUnaParada — confirmada_fin_turno', () => {
  test('parada coincide con el fin de un turno (±45 min) → confirmada_fin_turno', () => {
    const p = paradaReportada(600); // "paré (fin de jornada) a las +600 min"
    // v3 NO lista el descanso de fin de turno como pausa, pero el turno terminó ahí.
    const v = cruzarUnaParada(p, [], [turno(595)]);
    assert.strictEqual(v.estado, 'confirmada_fin_turno');
    assert.strictEqual(v.finTurnoMs, BASE + 595 * MIN_MS);
    assert.match(v.razon, /fin de jornada/i);
  });

  test('fin de turno lejos (>45 min) NO confirma → no_vista_v3', () => {
    const p = paradaReportada(600);
    const v = cruzarUnaParada(p, [], [turno(540)]); // 60 min antes, fuera de ±45
    assert.strictEqual(v.estado, 'no_vista_v3');
  });

  test('la pausa v3 explícita gana sobre el fin de turno si ambas matchean', () => {
    const p = paradaReportada(600);
    const v = cruzarUnaParada(p, [pausa(598, 30)], [turno(600)]);
    assert.strictEqual(v.estado, 'confirmada_v3');
  });

  test('sin turnos (llamada de 2 args, back-compat) → comportamiento anterior', () => {
    const p = paradaReportada(600);
    const v = cruzarUnaParada(p, []);
    assert.strictEqual(v.estado, 'no_vista_v3');
  });
});

// ══════════════════════════════════════════════════════════════════════
// Veredictos NO_VISTA
// ══════════════════════════════════════════════════════════════════════

describe('cruzarUnaParada — no_vista_v3', () => {
  test('pausa v3 muy lejos de la hora reportada (>20 min) → no_vista_v3', () => {
    const p = paradaReportada(100);
    const v3 = [pausa(180, 30)];
    const v = cruzarUnaParada(p, v3);
    assert.strictEqual(v.estado, 'no_vista_v3');
    assert.match(v.razon, /ninguna.*20 min/i);
  });

  test('v3 no detectó pausas el día → no_vista_v3', () => {
    const p = paradaReportada(100);
    const v = cruzarUnaParada(p, []);
    assert.strictEqual(v.estado, 'no_vista_v3');
    assert.match(v.razon, /no detectó pausas/i);
  });

  test('v3 solo tiene pausas cortas (<15 min) → no_vista_v3', () => {
    const p = paradaReportada(100);
    const v3 = [pausa(100, 5), pausa(105, 8)];
    const v = cruzarUnaParada(p, v3);
    assert.strictEqual(v.estado, 'no_vista_v3');
  });

  test('parada sin hora de inicio (parser bot falló) → no_vista_v3', () => {
    const p = paradaReportada(0, { sinInicio: true });
    const v3 = [pausa(60, 30)];
    const v = cruzarUnaParada(p, v3);
    assert.strictEqual(v.estado, 'no_vista_v3');
    assert.match(v.razon, /sin hora/i);
  });
});

// ══════════════════════════════════════════════════════════════════════
// Constantes (sanity)
// ══════════════════════════════════════════════════════════════════════

describe('constantes', () => {
  test('tolerancia 20 min y mínimo pausa 15 min', () => {
    assert.strictEqual(TOL_HORA_EXPLICITA_MS, 20 * 60 * 1000);
    assert.strictEqual(DUR_MIN_PAUSA_OPERATIVA_SEG, 15 * 60);
  });
});

// ══════════════════════════════════════════════════════════════════════
// Wrapper batch
// ══════════════════════════════════════════════════════════════════════

describe('cruzarParadasConJornadas — batch', () => {
  test('preserva el orden y devuelve veredicto por cada parada', () => {
    const paradas = [
      paradaReportada(60, { id: 'a' }),
      paradaReportada(200, { id: 'b' }),
      paradaReportada(400, { id: 'c', sinInicio: true }),
    ];
    const v3 = [pausa(58, 25), pausa(195, 22)];
    const res = cruzarParadasConJornadas(paradas, v3);
    assert.strictEqual(res.length, 3);
    assert.strictEqual(res[0].parada.id, 'a');
    assert.strictEqual(res[0].veredicto.estado, 'confirmada_v3');
    assert.strictEqual(res[1].parada.id, 'b');
    assert.strictEqual(res[1].veredicto.estado, 'confirmada_v3');
    assert.strictEqual(res[2].parada.id, 'c');
    assert.strictEqual(res[2].veredicto.estado, 'no_vista_v3');
  });
});
