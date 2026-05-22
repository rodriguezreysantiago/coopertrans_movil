// Tests para agrupador.js → planificarEnvioAgrupado.
//
// Crítico: si esto se rompe sin tests, el bot vuelve al comportamiento
// pre-fix (1 mensaje por alerta) y arriesgamos baneo del número de
// WhatsApp por spam — exactamente lo que el FIX 4 del 2026-05-03 vino
// a evitar.
//
// Strategy: mock manual de Firestore. Simulamos `db.collection().where()
// .where().where().where().get()` con un objeto que devuelve docs
// según los filtros aplicados. Nada de fake_firestore — overkill para
// la complejidad de la query.

process.env.TZ = 'America/Argentina/Buenos_Aires';

const { test, describe } = require('node:test');
const assert = require('node:assert');
const { Timestamp } = require('firebase-admin/firestore');

const { planificarEnvioAgrupado, ORIGENES_AGRUPABLES } = require('../src/agrupador');

// ============================================================================
// Helpers de mocking
// ============================================================================

function fakeDoc({ id, data }) {
  return {
    id,
    data: () => data,
    ref: { id, _isMockRef: true },
  };
}

/**
 * Mock de db con una sola colección y resultados pre-cocidos.
 * `whereResults`: array de docs que devolverá el .get() después de
 * aplicar los .where(). El mock IGNORA los .where() (no filtra) — el
 * caller tiene que pasar los docs ya filtrados.
 */
function fakeDbConDocs(docs) {
  const queryChain = {
    where: function () { return this; },
    // orderBy + limit agregados 2026-05-19: el código de producción
    // (agrupador.js planificarEnvioAgrupado) encadena .orderBy('encolado_en')
    // + .limit() para el FIFO. El mock los ignora (devuelve this) — el
    // caller pasa los docs ya en el orden esperado.
    orderBy: function () { return this; },
    limit: function () { return this; },
    get: async () => ({ docs }),
  };
  return {
    collection: () => queryChain,
  };
}

const NOW_MS = Date.now();
const HACE_1H = NOW_MS - 60 * 60 * 1000;
const HACE_3H = NOW_MS - 3 * 60 * 60 * 1000;

function tsHace(ms) {
  return Timestamp.fromMillis(NOW_MS - ms);
}

// ============================================================================

describe('planificarEnvioAgrupado — origen NO agrupable', () => {
  test('cron_aviso_vencimiento → null (ya tiene su propia agrupación al encolar)', async () => {
    const docActual = fakeDoc({
      id: 'doc1',
      data: { origen: 'cron_aviso_vencimiento', destinatario_id: '12345' },
    });
    const db = fakeDbConDocs([]);
    const result = await planificarEnvioAgrupado(db, docActual);
    assert.strictEqual(result, null);
  });

  test('bot_watchdog → null (alerta única, no agrupable)', async () => {
    const docActual = fakeDoc({
      id: 'doc1',
      data: { origen: 'bot_watchdog', destinatario_id: '12345' },
    });
    const db = fakeDbConDocs([]);
    assert.strictEqual(await planificarEnvioAgrupado(db, docActual), null);
  });

  test('origen vacío / null → null', async () => {
    const docActual = fakeDoc({
      id: 'doc1',
      data: { destinatario_id: '12345' },
    });
    assert.strictEqual(await planificarEnvioAgrupado(fakeDbConDocs([]), docActual), null);
  });

  test('sin destinatario_id → null', async () => {
    const docActual = fakeDoc({
      id: 'doc1',
      data: { origen: 'volvo_alert_high' },
    });
    assert.strictEqual(await planificarEnvioAgrupado(fakeDbConDocs([]), docActual), null);
  });
});

describe('ORIGENES_AGRUPABLES contiene los esperados', () => {
  test('volvo_alert_high está, volvo_alert_mantenimiento NO (cron diario consolida)', () => {
    assert.ok(ORIGENES_AGRUPABLES.has('volvo_alert_high'));
    // Desde el commit b587822 (2026-05-05), mantenimiento ya no se encola
    // individualmente — onAlertaVolvoMantenimientoCreated solo persiste en
    // VOLVO_ALERTAS y el cron diario arma 1 mensaje consolidado.
    assert.ok(!ORIGENES_AGRUPABLES.has('volvo_alert_mantenimiento'));
  });

  test('cron_aviso_vencimiento NO está (tiene su propia agrupación al encolar)', () => {
    assert.ok(!ORIGENES_AGRUPABLES.has('cron_aviso_vencimiento'));
  });
});

describe('planificarEnvioAgrupado — sin otros pendientes', () => {
  test('volvo_alert_high pero solo el doc actual existe → null (envío individual)', async () => {
    const docActual = fakeDoc({
      id: 'doc1',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: '12345',
        mensaje: 'Hola Juan, ...',
      },
    });
    // El mock devuelve solo el doc actual — el agrupador lo filtra y queda 0 otros.
    const db = fakeDbConDocs([docActual]);
    const result = await planificarEnvioAgrupado(db, docActual);
    assert.strictEqual(result, null);
  });
});

describe('planificarEnvioAgrupado — agrupación volvo_alert_high', () => {
  test('2 pendientes mismo destinatario+patente → mensaje combinado', async () => {
    const dest = '12345';
    const patente = 'AB123CD';

    const doc1 = fakeDoc({
      id: 'doc1',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'Hola Juan, se detectó evento ...',
        alert_patente: patente,
        alert_tipo: 'OVERSPEED',
        alert_creado_en: tsHace(2 * 60 * 60 * 1000), // hace 2h
      },
    });
    const doc2 = fakeDoc({
      id: 'doc2',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'Hola Juan, se detectó evento ...',
        alert_patente: patente,
        alert_tipo: 'IDLING',
        alert_creado_en: tsHace(60 * 60 * 1000), // hace 1h
      },
    });
    const db = fakeDbConDocs([doc1, doc2]);
    const result = await planificarEnvioAgrupado(db, doc1);

    assert.ok(result, 'Debe devolver un plan');
    assert.strictEqual(result.otrosDocsAgrupados.length, 1);
    assert.strictEqual(result.otrosDocsAgrupados[0].id, 'doc2');
    // El mensaje combinado debe contener el saludo "Hola Juan" (extraído
    // del primer mensaje), la patente y los dos tipos de evento.
    assert.match(result.mensajeCombinado, /Hola Juan/);
    assert.match(result.mensajeCombinado, /AB123CD/);
    assert.match(result.mensajeCombinado, /Exceso de velocidad/);
    assert.match(result.mensajeCombinado, /Motor en ralent/);
    // Y debe decir "se detectaron N eventos" (N=2).
    assert.match(result.mensajeCombinado, /detectaron 2 eventos/);
  });

  test('3 eventos del MISMO tipo en la misma patente → "3x" en el bloque', async () => {
    const dest = '12345';
    const docActual = fakeDoc({
      id: 'doc1',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'Hola Carlos, ...',
        alert_patente: 'XX111YY',
        alert_tipo: 'OVERSPEED',
        alert_creado_en: tsHace(3 * 60 * 60 * 1000),
      },
    });
    const otros = [1, 2].map((i) => fakeDoc({
      id: `doc${i + 1}`,
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'irrelevante',
        alert_patente: 'XX111YY',
        alert_tipo: 'OVERSPEED',
        alert_creado_en: tsHace(i * 60 * 60 * 1000),
      },
    }));
    const db = fakeDbConDocs([docActual, ...otros]);
    const result = await planificarEnvioAgrupado(db, docActual);
    assert.ok(result);
    assert.match(result.mensajeCombinado, /3x Exceso de velocidad/);
  });

  test('eventos en distintas patentes → bloques separados', async () => {
    const dest = '12345';
    const docActual = fakeDoc({
      id: 'doc1',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'Hola, ...',
        alert_patente: 'AAA111',
        alert_tipo: 'OVERSPEED',
        alert_creado_en: tsHace(60 * 60 * 1000),
      },
    });
    const otro = fakeDoc({
      id: 'doc2',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'irrelevante',
        alert_patente: 'BBB222',
        alert_tipo: 'IDLING',
        alert_creado_en: tsHace(2 * 60 * 60 * 1000),
      },
    });
    const db = fakeDbConDocs([docActual, otro]);
    const result = await planificarEnvioAgrupado(db, docActual);
    assert.ok(result);
    assert.match(result.mensajeCombinado, /AAA111/);
    assert.match(result.mensajeCombinado, /BBB222/);
  });
});

describe('planificarEnvioAgrupado — volvo_alert_mantenimiento NO se agrupa', () => {
  // La consolidación de mantenimiento la hace la Cloud Function
  // resumenMantenimientoVehiculosDiario (1 "Parte" por día al jefe de mant;
  // desde 2026-05-22 reemplazó al cron_mantenimiento_diario del bot). Si por
  // defensa llega un doc con origen='volvo_alert_mantenimiento' a
  // COLA_WHATSAPP, el agrupador lo ignora y se envía individual.
  test('origen volvo_alert_mantenimiento → null (envío individual)', async () => {
    const docActual = fakeDoc({
      id: 'mant1',
      data: {
        origen: 'volvo_alert_mantenimiento',
        destinatario_id: '35244439',
        mensaje: '🔧 Alerta de mantenimiento ...',
        alert_patente: 'AC383ND',
        alert_tipo: 'CATALYST',
      },
    });
    const result = await planificarEnvioAgrupado(fakeDbConDocs([docActual]), docActual);
    assert.strictEqual(result, null);
  });
});

describe('planificarEnvioAgrupado — subTipo GENERIC (regresión 2026-05-07)', () => {
  test('GENERIC + alert_sub_tipo SEATBELT → muestra "Cinturón..." no "Evento genérico"', async () => {
    const dest = '12345';
    const doc1 = fakeDoc({
      id: 'doc1',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'Hola Juan, ...',
        alert_patente: 'AB123CD',
        alert_tipo: 'GENERIC',
        alert_sub_tipo: 'SEATBELT',
        alert_creado_en: tsHace(2 * 60 * 60 * 1000),
      },
    });
    const doc2 = fakeDoc({
      id: 'doc2',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'irrelevante',
        alert_patente: 'AB123CD',
        alert_tipo: 'GENERIC',
        alert_sub_tipo: 'SEATBELT',
        alert_creado_en: tsHace(60 * 60 * 1000),
      },
    });
    const db = fakeDbConDocs([doc1, doc2]);
    const result = await planificarEnvioAgrupado(db, doc1);
    assert.ok(result);
    assert.match(result.mensajeCombinado, /Cinturón/);
    assert.match(result.mensajeCombinado, /2x Cinturón/);
    assert.doesNotMatch(result.mensajeCombinado, /Evento genérico/);
  });

  test('GENERIC sin alert_sub_tipo → cae a "Evento genérico" (compat docs viejos)', async () => {
    const dest = '12345';
    const doc1 = fakeDoc({
      id: 'doc1',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'Hola Juan, ...',
        alert_patente: 'AB123CD',
        alert_tipo: 'GENERIC',
        // sin alert_sub_tipo (doc encolado pre-fix 2026-05-07)
        alert_creado_en: tsHace(2 * 60 * 60 * 1000),
      },
    });
    const doc2 = fakeDoc({
      id: 'doc2',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'irrelevante',
        alert_patente: 'AB123CD',
        alert_tipo: 'GENERIC',
        alert_creado_en: tsHace(60 * 60 * 1000),
      },
    });
    const db = fakeDbConDocs([doc1, doc2]);
    const result = await planificarEnvioAgrupado(db, doc1);
    assert.ok(result);
    assert.match(result.mensajeCombinado, /Evento genérico/);
  });

  test('separa por subTipo: SEATBELT y TELL_TALE no se colapsan', async () => {
    const dest = '12345';
    const doc1 = fakeDoc({
      id: 'doc1',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'Hola Juan, ...',
        alert_patente: 'AB123CD',
        alert_tipo: 'GENERIC',
        alert_sub_tipo: 'SEATBELT',
        alert_creado_en: tsHace(2 * 60 * 60 * 1000),
      },
    });
    const doc2 = fakeDoc({
      id: 'doc2',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'irrelevante',
        alert_patente: 'AB123CD',
        alert_tipo: 'GENERIC',
        alert_sub_tipo: 'TELL_TALE',
        alert_creado_en: tsHace(60 * 60 * 1000),
      },
    });
    const db = fakeDbConDocs([doc1, doc2]);
    const result = await planificarEnvioAgrupado(db, doc1);
    assert.ok(result);
    // Ambos subtipos en líneas separadas.
    assert.match(result.mensajeCombinado, /Cinturón/);
    assert.match(result.mensajeCombinado, /Luz de tablero/);
  });
});

describe('planificarEnvioAgrupado — defensas', () => {
  test('cap defensivo: > 50 docs → solo agrupa los primeros 49 otros', async () => {
    const dest = '12345';
    const docActual = fakeDoc({
      id: 'principal',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'Hola, ...',
        alert_patente: 'AAA111',
        alert_tipo: 'OVERSPEED',
        alert_creado_en: tsHace(60 * 60 * 1000),
      },
    });
    // 100 docs adicionales — solo deberían agruparse 49 (cap interno).
    const otros = Array.from({ length: 100 }, (_, i) => fakeDoc({
      id: `doc${i}`,
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'X',
        alert_patente: 'AAA111',
        alert_tipo: 'OVERSPEED',
        alert_creado_en: tsHace(i * 60 * 1000),
      },
    }));
    const db = fakeDbConDocs([docActual, ...otros]);
    const result = await planificarEnvioAgrupado(db, docActual);
    assert.ok(result);
    assert.strictEqual(result.otrosDocsAgrupados.length, 49,
      'Debe limitar a 49 otros (50 con el actual)');
  });

  test('alert_creado_en faltante → fallback a encolado_en', async () => {
    const dest = '12345';
    const doc1 = fakeDoc({
      id: 'doc1',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'Hola Pedro, ...',
        alert_patente: 'AAA111',
        alert_tipo: 'OVERSPEED',
        // SIN alert_creado_en (doc viejo pre-fix)
        encolado_en: tsHace(60 * 60 * 1000),
      },
    });
    const doc2 = fakeDoc({
      id: 'doc2',
      data: {
        origen: 'volvo_alert_high',
        destinatario_id: dest,
        mensaje: 'irrelevante',
        alert_patente: 'AAA111',
        alert_tipo: 'IDLING',
        encolado_en: tsHace(2 * 60 * 60 * 1000),
      },
    });
    const db = fakeDbConDocs([doc1, doc2]);
    const result = await planificarEnvioAgrupado(db, doc1);
    // No debe romper aunque alert_creado_en falte. El mensaje sale OK.
    assert.ok(result);
    assert.match(result.mensajeCombinado, /Exceso de velocidad/);
  });
});
