// Tests del "cron de los crons" (cron_health.ts). Lógica PURA de decisión:
// cuándo un cron está STALE (no corre hace más de su tolerancia, incluyendo
// "nunca corrió desde que se lo vigila"), cuándo está FALLANDO (última
// corrida con error), y el anti-spam de 24 h por cron.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  evaluarSaludCrones,
  construirMensajeIncidentes,
  REGISTRO_CRONES,
} = require('../lib/cron_health');

const H = 60 * 60 * 1000;
const AHORA = Date.parse('2026-06-12T12:00:00-03:00');

// Registro de prueba: un poller (3 h) y un diario (26 h).
const REG = {
  poller: { maxStaleMin: 180 },
  diario: { maxStaleMin: 26 * 60 },
};

const estado = (id, over = {}) => ({
  id,
  ultimoOkMs: null,
  ultimoErrorMs: null,
  errorDetalle: null,
  primerChequeoMs: null,
  alertadoEnMs: null,
  ...over,
});

describe('evaluarSaludCrones — STALE', () => {
  test('cron fresco no genera incidente', () => {
    const out = evaluarSaludCrones(AHORA, [
      estado('poller', { ultimoOkMs: AHORA - 1 * H }),
    ], REG);
    assert.deepStrictEqual(out, []);
  });

  test('poller sin correr hace 4 h (tolerancia 3 h) → stale', () => {
    const out = evaluarSaludCrones(AHORA, [
      estado('poller', { ultimoOkMs: AHORA - 4 * H }),
    ], REG);
    assert.strictEqual(out.length, 1);
    assert.strictEqual(out[0].tipo, 'stale');
    assert.match(out[0].detalle, /sin corrida OK hace 4 h/);
  });

  test('diario corrido hace 20 h NO es stale (tolerancia 26 h)', () => {
    const out = evaluarSaludCrones(AHORA, [
      estado('diario', { ultimoOkMs: AHORA - 20 * H }),
    ], REG);
    assert.deepStrictEqual(out, []);
  });

  test('nunca corrió OK pero se lo vigila hace 5 h → stale "nunca corrió"', () => {
    const out = evaluarSaludCrones(AHORA, [
      estado('poller', { primerChequeoMs: AHORA - 5 * H }),
    ], REG);
    assert.strictEqual(out.length, 1);
    assert.match(out[0].detalle, /nunca corrió OK/);
  });

  test('recién sembrado (primer_chequeo hace 1 h) todavía no alerta', () => {
    const out = evaluarSaludCrones(AHORA, [
      estado('poller', { primerChequeoMs: AHORA - 1 * H }),
    ], REG);
    assert.deepStrictEqual(out, []);
  });

  test('sin ultimo_ok NI primer_chequeo no se puede medir → sin incidente', () => {
    const out = evaluarSaludCrones(AHORA, [estado('poller')], REG);
    assert.deepStrictEqual(out, []);
  });

  test('doc de un cron retirado (no está en el registro) se ignora', () => {
    const out = evaluarSaludCrones(AHORA, [
      estado('cronViejoQueYaNoExiste', { ultimoOkMs: AHORA - 100 * H }),
    ], REG);
    assert.deepStrictEqual(out, []);
  });
});

describe('evaluarSaludCrones — FALLANDO', () => {
  test('última corrida con error (y reciente) → fallando con detalle', () => {
    const out = evaluarSaludCrones(AHORA, [
      estado('poller', {
        ultimoOkMs: AHORA - 2 * H,
        ultimoErrorMs: AHORA - 1 * H,
        errorDetalle: 'quota exceeded',
      }),
    ], REG);
    assert.strictEqual(out.length, 1);
    assert.strictEqual(out[0].tipo, 'fallando');
    assert.match(out[0].detalle, /quota exceeded/);
  });

  test('se recuperó (ok DESPUÉS del error) → sin incidente', () => {
    const out = evaluarSaludCrones(AHORA, [
      estado('poller', {
        ultimoOkMs: AHORA - 1 * H,
        ultimoErrorMs: AHORA - 2 * H,
        errorDetalle: 'transitorio',
      }),
    ], REG);
    assert.deepStrictEqual(out, []);
  });

  test('error viejo (> 13 h) sin OK posterior pero cron fresco no reporta "fallando"', () => {
    // Caso raro: diario que falló ayer a la mañana y todavía no le tocó
    // correr de vuelta. El error quedó viejo → esperamos al próximo ciclo.
    const out = evaluarSaludCrones(AHORA, [
      estado('diario', {
        ultimoOkMs: AHORA - 20 * H,
        ultimoErrorMs: AHORA - 15 * H,
      }),
    ], REG);
    assert.deepStrictEqual(out, []);
  });

  test('stale tiene prioridad: no duplica con "fallando" para el mismo cron', () => {
    const out = evaluarSaludCrones(AHORA, [
      estado('poller', {
        ultimoOkMs: AHORA - 10 * H,
        ultimoErrorMs: AHORA - 1 * H,
        errorDetalle: 'crash loop',
      }),
    ], REG);
    assert.strictEqual(out.length, 1);
    assert.strictEqual(out[0].tipo, 'stale');
  });
});

describe('evaluarSaludCrones — anti-spam 24 h', () => {
  test('alertado hace 2 h → silencio aunque siga stale', () => {
    const out = evaluarSaludCrones(AHORA, [
      estado('poller', {
        ultimoOkMs: AHORA - 10 * H,
        alertadoEnMs: AHORA - 2 * H,
      }),
    ], REG);
    assert.deepStrictEqual(out, []);
  });

  test('alertado hace 30 h → re-avisa', () => {
    const out = evaluarSaludCrones(AHORA, [
      estado('poller', {
        ultimoOkMs: AHORA - 40 * H,
        alertadoEnMs: AHORA - 30 * H,
      }),
    ], REG);
    assert.strictEqual(out.length, 1);
  });
});

describe('construirMensajeIncidentes', () => {
  test('arma una línea por incidente con su ícono', () => {
    const msg = construirMensajeIncidentes([
      { id: 'poller', tipo: 'stale', detalle: 'sin corrida OK hace 4 h' },
      { id: 'diario', tipo: 'fallando', detalle: 'última corrida con ERROR' },
    ]);
    assert.match(msg, /⛔ poller — sin corrida OK hace 4 h/);
    assert.match(msg, /⚠️ diario — última corrida con ERROR/);
    assert.match(msg, /Salud de crons/);
  });
});

describe('REGISTRO_CRONES — consistencia con el código real', () => {
  test('los 27 onSchedule del codebase están registrados', () => {
    // Censo del 2026-06-12 (README "regenerado desde el código") +
    // censoColeccionesMensual + failoverCriticosBot (2026-06-13) +
    // archivarEventosSitrackFrio (2026-06-13). Si se agrega un cron nuevo,
    // este test recuerda sumarlo al registro.
    const esperados = [
      'backfillDescargasDiario', 'backupFirestoreScheduled',
      'botHealthWatchdog', 'censoColeccionesMensual',
      'cerrarReportesJornadaDiario', 'failoverCriticosBot',
      'cruzarParadasReportadasV3Diario', 'estadoVolvoPoller',
      'procesarSilenciadosExpirados', 'purgarColaWhatsappAntigua',
      'recomputeDashboardStats', 'reconstruirHistoricoIButtonsDiario',
      'reconstruirJornadasDiario', 'registrarJornadasV3Diario',
      'resumenBotDiario', 'resumenConductaManejoDiario',
      'resumenDriftsAsignacionesDiario', 'resumenExcesosJornadaDiario',
      'resumenMantenimientoVehiculosDiario', 'sitrackEventosPoller',
      'sitrackPosicionPoller', 'telemetriaSnapshotScheduled',
      'vigiladorJornadaChofer', 'volvoAlertasPoller', 'volvoScoresPoller',
      'zonaDescargaPoller', 'archivarEventosSitrackFrio',
    ];
    for (const id of esperados) {
      assert.ok(REGISTRO_CRONES[id], `falta ${id} en REGISTRO_CRONES`);
    }
    assert.strictEqual(Object.keys(REGISTRO_CRONES).length, esperados.length);
  });
});
