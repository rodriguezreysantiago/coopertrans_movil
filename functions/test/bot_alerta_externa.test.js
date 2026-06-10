// Tests de la alerta externa (Telegram) del botHealthWatchdog.
//
// Toda la máquina de estados del incidente es lógica PURA en
// src/bot_alerta_externa.ts (mismo patrón que jornadas_v2_tick): acá se
// testea contra lib/ compilado, sin Firestore ni red. El envío real a
// Telegram (enviarTelegram) no se testea — es un POST trivial y nunca
// lanza por diseño.

const { test, describe } = require('node:test');
const assert = require('node:assert');
const { Timestamp } = require('firebase-admin/firestore');

const {
  evaluarAlertaExterna,
  incidenteVacio,
  incidenteDesdeDoc,
  incidenteHaciaDoc,
  sonIncidentesIguales,
  construirMensajeAlerta,
  duracionHumana,
  UMBRAL_STALE_MIN,
  UMBRAL_NO_LISTO_MIN,
  REAVISO_TEMPRANO_MIN,
  REAVISO_TARDIO_MIN,
} = require('../lib/bot_alerta_externa');

const MIN = 60_000;
const AHORA = 1_770_000_000_000; // epoch ms arbitrario, fijo para los tests

/** Heartbeat fresco (1 min atrás). */
const HB_FRESCO = AHORA - 1 * MIN;
/** Heartbeat stale (pasado el umbral). */
const HB_STALE = AHORA - (UMBRAL_STALE_MIN + 5) * MIN;

function evaluar({ hb = HB_FRESCO, estado = 'LISTO', incidente = incidenteVacio() } = {}) {
  return evaluarAlertaExterna({
    ahoraMs: AHORA,
    ultimoHeartbeatMs: hb,
    estadoCliente: estado,
    incidente,
  });
}

describe('evaluarAlertaExterna — sin incidente previo', () => {
  test('bot sano (latido fresco + LISTO) → no avisa', () => {
    const r = evaluar();
    assert.strictEqual(r.avisar, false);
    assert.strictEqual(r.clase, null);
    assert.strictEqual(r.incidente.activa, false);
  });

  test('latido stale → apertura bot_caido', () => {
    const r = evaluar({ hb: HB_STALE });
    assert.strictEqual(r.avisar, true);
    assert.strictEqual(r.clase, 'apertura');
    assert.strictEqual(r.incidente.activa, true);
    assert.strictEqual(r.incidente.motivo, 'bot_caido');
    assert.strictEqual(r.incidente.avisosEnviados, 1);
    assert.strictEqual(r.incidente.desdeMs, AHORA);
    assert.strictEqual(r.incidente.ultimoAvisoEnMs, AHORA);
  });

  test('AUTH_PENDIENTE con latido fresco → apertura whatsapp_roto INMEDIATA', () => {
    const r = evaluar({ estado: 'AUTH_PENDIENTE' });
    assert.strictEqual(r.avisar, true);
    assert.strictEqual(r.clase, 'apertura');
    assert.strictEqual(r.incidente.motivo, 'whatsapp_roto');
    assert.strictEqual(r.incidente.detalle, 'AUTH_PENDIENTE');
  });

  test('AUTH_FALLO también alerta inmediato', () => {
    const r = evaluar({ estado: 'AUTH_FALLO' });
    assert.strictEqual(r.avisar, true);
    assert.strictEqual(r.incidente.motivo, 'whatsapp_roto');
  });

  test('DESCONECTADO recién visto → NO avisa, arranca el tracking noListoDesde', () => {
    const r = evaluar({ estado: 'DESCONECTADO' });
    assert.strictEqual(r.avisar, false);
    assert.strictEqual(r.incidente.activa, false);
    assert.strictEqual(r.incidente.noListoDesdeMs, AHORA);
  });

  test('DESCONECTADO sostenido < umbral → sigue sin avisar', () => {
    const inc = {
      ...incidenteVacio(),
      noListoDesdeMs: AHORA - (UMBRAL_NO_LISTO_MIN - 10) * MIN,
    };
    const r = evaluar({ estado: 'DESCONECTADO', incidente: inc });
    assert.strictEqual(r.avisar, false);
    // El tracking se conserva (no se resetea por tick).
    assert.strictEqual(r.incidente.noListoDesdeMs, inc.noListoDesdeMs);
  });

  test('DESCONECTADO sostenido ≥ umbral → apertura whatsapp_roto', () => {
    const inc = {
      ...incidenteVacio(),
      noListoDesdeMs: AHORA - UMBRAL_NO_LISTO_MIN * MIN,
    };
    const r = evaluar({ estado: 'DESCONECTADO', incidente: inc });
    assert.strictEqual(r.avisar, true);
    assert.strictEqual(r.clase, 'apertura');
    assert.strictEqual(r.incidente.motivo, 'whatsapp_roto');
    assert.strictEqual(r.incidente.detalle, 'DESCONECTADO');
  });

  test('clavado en INICIANDO ≥ umbral → también alerta (Chromium roto)', () => {
    const inc = {
      ...incidenteVacio(),
      noListoDesdeMs: AHORA - (UMBRAL_NO_LISTO_MIN + 1) * MIN,
    };
    const r = evaluar({ estado: 'INICIANDO', incidente: inc });
    assert.strictEqual(r.avisar, true);
    assert.strictEqual(r.incidente.motivo, 'whatsapp_roto');
  });

  test('volver a LISTO limpia el tracking noListoDesde', () => {
    const inc = { ...incidenteVacio(), noListoDesdeMs: AHORA - 5 * MIN };
    const r = evaluar({ estado: 'LISTO', incidente: inc });
    assert.strictEqual(r.avisar, false);
    assert.strictEqual(r.incidente.noListoDesdeMs, null);
  });

  test('latido stale CONGELA el tracking noListoDesde (estado desconocido)', () => {
    const marca = AHORA - 5 * MIN;
    const inc = { ...incidenteVacio(), noListoDesdeMs: marca };
    const r = evaluar({ hb: HB_STALE, estado: 'DESCONECTADO', incidente: inc });
    assert.strictEqual(r.incidente.noListoDesdeMs, marca);
    assert.strictEqual(r.incidente.motivo, 'bot_caido'); // stale domina
  });
});

describe('evaluarAlertaExterna — incidente abierto (backoff de re-avisos)', () => {
  function incidenteAbierto(overrides = {}) {
    return {
      activa: true,
      motivo: 'bot_caido',
      detalle: 'LISTO',
      desdeMs: AHORA - 90 * MIN,
      ultimoAvisoEnMs: AHORA - 30 * MIN,
      avisosEnviados: 1,
      noListoDesdeMs: null,
      ...overrides,
    };
  }

  test('sigue caído pero el último aviso fue hace poco → no re-avisa', () => {
    const r = evaluar({ hb: HB_STALE, incidente: incidenteAbierto() });
    assert.strictEqual(r.avisar, false);
    assert.strictEqual(r.incidente.avisosEnviados, 1);
  });

  test('2º aviso recién a los 60 min del 1º', () => {
    const inc = incidenteAbierto({
      ultimoAvisoEnMs: AHORA - REAVISO_TEMPRANO_MIN * MIN,
    });
    const r = evaluar({ hb: HB_STALE, incidente: inc });
    assert.strictEqual(r.avisar, true);
    assert.strictEqual(r.clase, 'reaviso');
    assert.strictEqual(r.incidente.avisosEnviados, 2);
    assert.strictEqual(r.incidente.ultimoAvisoEnMs, AHORA);
  });

  test('del 3º en adelante el backoff es de 6 h: a las 2 h NO re-avisa', () => {
    const inc = incidenteAbierto({
      avisosEnviados: 2,
      ultimoAvisoEnMs: AHORA - 120 * MIN,
    });
    const r = evaluar({ hb: HB_STALE, incidente: inc });
    assert.strictEqual(r.avisar, false);
  });

  test('del 3º en adelante: a las 6 h sí re-avisa', () => {
    const inc = incidenteAbierto({
      avisosEnviados: 2,
      ultimoAvisoEnMs: AHORA - REAVISO_TARDIO_MIN * MIN,
    });
    const r = evaluar({ hb: HB_STALE, incidente: inc });
    assert.strictEqual(r.avisar, true);
    assert.strictEqual(r.incidente.avisosEnviados, 3);
  });

  test('cambio de motivo avisa SIN esperar backoff (QR → bot apagado)', () => {
    const inc = incidenteAbierto({
      motivo: 'whatsapp_roto',
      ultimoAvisoEnMs: AHORA - 5 * MIN, // recién avisado
    });
    const r = evaluar({ hb: HB_STALE, incidente: inc });
    assert.strictEqual(r.avisar, true);
    assert.strictEqual(r.clase, 'cambio');
    assert.strictEqual(r.incidente.motivo, 'bot_caido');
    assert.strictEqual(r.incidente.avisosEnviados, 2);
    // El inicio del incidente NO se resetea con el cambio.
    assert.strictEqual(r.incidente.desdeMs, inc.desdeMs);
  });

  test('recuperación: latido fresco + LISTO → aviso 🟢 y reset del incidente', () => {
    const r = evaluar({ incidente: incidenteAbierto() });
    assert.strictEqual(r.avisar, true);
    assert.strictEqual(r.clase, 'recuperacion');
    assert.deepStrictEqual(r.incidente, incidenteVacio());
  });

  test('en recuperación a medias (INICIANDO fresco) NO cierra ni re-avisa', () => {
    const inc = incidenteAbierto();
    const r = evaluar({ estado: 'INICIANDO', incidente: inc });
    assert.strictEqual(r.avisar, false);
    assert.strictEqual(r.incidente.activa, true);
    // Arranca el tracking por si se queda clavado en INICIANDO.
    assert.strictEqual(r.incidente.noListoDesdeMs, AHORA);
  });
});

describe('duracionHumana', () => {
  test('menos de una hora → minutos', () => {
    assert.strictEqual(duracionHumana(47 * MIN), '47 min');
  });
  test('hora exacta → sin minutos', () => {
    assert.strictEqual(duracionHumana(60 * MIN), '1 h');
  });
  test('horas y minutos', () => {
    assert.strictEqual(duracionHumana(192 * MIN), '3 h 12 min');
  });
  test('negativo/cero no rompe', () => {
    assert.strictEqual(duracionHumana(-5), '0 min');
  });
});

describe('construirMensajeAlerta', () => {
  const base = {
    estadoCliente: 'LISTO',
    pcId: 'coopertransmovil',
    ahoraMs: AHORA,
    ultimoHeartbeatMs: HB_STALE,
    desdeMs: AHORA - 75 * MIN,
    avisosEnviados: 1,
  };

  test('apertura bot_caido: nombra la PC y avisa que la cola está detenida', () => {
    const t = construirMensajeAlerta({ ...base, clase: 'apertura', motivo: 'bot_caido' });
    assert.match(t, /Bot de WhatsApp caído/);
    assert.match(t, /coopertransmovil/);
    assert.match(t, /cola de avisos.*detenida/i);
  });

  test('AUTH_PENDIENTE: instrucciones de QR (Dispositivos vinculados)', () => {
    const t = construirMensajeAlerta({
      ...base,
      clase: 'apertura',
      motivo: 'whatsapp_roto',
      estadoCliente: 'AUTH_PENDIENTE',
      ultimoHeartbeatMs: HB_FRESCO,
    });
    assert.match(t, /QR/);
    assert.match(t, /Dispositivos vinculados/);
  });

  test('reaviso incluye el número de aviso', () => {
    const t = construirMensajeAlerta({
      ...base,
      clase: 'reaviso',
      motivo: 'bot_caido',
      avisosEnviados: 3,
    });
    assert.match(t, /\(aviso 3\)/);
    assert.match(t, /sigue caído/);
  });

  test('cambio lleva el prefijo de cambio', () => {
    const t = construirMensajeAlerta({ ...base, clase: 'cambio', motivo: 'bot_caido' });
    assert.match(t, /Cambio en el incidente/);
  });

  test('recuperación: 🟢 con duración del incidente', () => {
    const t = construirMensajeAlerta({
      ...base,
      clase: 'recuperacion',
      motivo: 'bot_caido',
      estadoCliente: 'LISTO',
      ultimoHeartbeatMs: HB_FRESCO,
    });
    assert.match(t, /🟢/);
    assert.match(t, /recuperado/);
    assert.match(t, /1 h 15 min/);
  });
});

describe('(de)serialización del campo alertaExterna', () => {
  test('doc sin el campo (bot viejo) → incidente vacío', () => {
    assert.deepStrictEqual(incidenteDesdeDoc(undefined), incidenteVacio());
    assert.deepStrictEqual(incidenteDesdeDoc(null), incidenteVacio());
    assert.deepStrictEqual(incidenteDesdeDoc('basura'), incidenteVacio());
  });

  test('roundtrip haciaDoc → desdeDoc conserva todo', () => {
    const inc = {
      activa: true,
      motivo: 'whatsapp_roto',
      detalle: 'AUTH_PENDIENTE',
      desdeMs: AHORA - 10 * MIN,
      ultimoAvisoEnMs: AHORA - 5 * MIN,
      avisosEnviados: 2,
      noListoDesdeMs: AHORA - 12 * MIN,
    };
    assert.deepStrictEqual(incidenteDesdeDoc(incidenteHaciaDoc(inc)), inc);
  });

  test('motivo desconocido en el doc → null (tolerante a docs viejos)', () => {
    const raw = { activa: true, motivo: 'otra_cosa', avisosEnviados: 1 };
    const inc = incidenteDesdeDoc(raw);
    assert.strictEqual(inc.motivo, null);
    assert.strictEqual(inc.activa, true);
  });

  test('timestamps del doc se convierten a millis', () => {
    const raw = {
      activa: true,
      motivo: 'bot_caido',
      desde: Timestamp.fromMillis(AHORA - MIN),
      avisosEnviados: 1,
    };
    assert.strictEqual(incidenteDesdeDoc(raw).desdeMs, AHORA - MIN);
  });

  test('sonIncidentesIguales detecta cambios de cualquier campo', () => {
    const a = incidenteVacio();
    assert.strictEqual(sonIncidentesIguales(a, incidenteVacio()), true);
    assert.strictEqual(
      sonIncidentesIguales(a, { ...incidenteVacio(), noListoDesdeMs: 1 }),
      false,
    );
    assert.strictEqual(
      sonIncidentesIguales(a, { ...incidenteVacio(), avisosEnviados: 1 }),
      false,
    );
  });
});
