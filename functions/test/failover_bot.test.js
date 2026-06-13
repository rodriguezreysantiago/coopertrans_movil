// Tests de la lógica PURA del failover de avisos críticos (failover_bot.ts):
// qué docs de COLA_WHATSAPP hay que reenviar por push cuando el bot está
// caído, y el armado de la escalación a Santiago.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  aFailover,
  construirEscalacion,
  ORIGENES_CRITICOS,
} = require('../lib/failover_bot');

describe('aFailover', () => {
  test('selecciona crítico PENDIENTE con destinatario y sin marcar', () => {
    const docs = [
      { id: 'a', origen: 'jornada_v2_cuota_cumplida', estado: 'PENDIENTE', destinatario_id: '111' },
    ];
    assert.deepStrictEqual(aFailover(docs).map((d) => d.id), ['a']);
  });

  test('ignora orígenes NO críticos (vencimientos, resúmenes)', () => {
    const docs = [
      { id: 'a', origen: 'drift_diario', estado: 'PENDIENTE', destinatario_id: '111' },
      { id: 'b', origen: 'resumen_mantenimiento_vehiculos', estado: 'PENDIENTE', destinatario_id: '222' },
    ];
    assert.deepStrictEqual(aFailover(docs), []);
  });

  test('NO re-failover un doc ya marcado (anti-spam por doc)', () => {
    const docs = [
      { id: 'a', origen: 'volvo_alert_high', estado: 'PENDIENTE', destinatario_id: '111', fallback_push: true },
    ];
    assert.deepStrictEqual(aFailover(docs), []);
  });

  test('ignora ya enviados (estado != PENDIENTE) y sin destinatario', () => {
    const docs = [
      { id: 'a', origen: 'bypass_seguridad', estado: 'ENVIADO', destinatario_id: '111' },
      { id: 'b', origen: 'bypass_seguridad', estado: 'PENDIENTE' }, // sin destinatario
    ];
    assert.deepStrictEqual(aFailover(docs), []);
  });

  test('mezcla realista: solo el crítico fresco con destinatario', () => {
    const docs = [
      { id: 'jornada', origen: 'jornada_v2_bloque_excedido', estado: 'PENDIENTE', destinatario_id: '1' },
      { id: 'turno', origen: 'cachatore', estado: 'PENDIENTE', destinatario_id: '2' },
      { id: 'resumen', origen: 'resumen_conducta_manejo_diario', estado: 'PENDIENTE', destinatario_id: '3' },
      { id: 'viejo', origen: 'volvo_alert_high', estado: 'PENDIENTE', destinatario_id: '4', fallback_push: true },
    ];
    assert.deepStrictEqual(aFailover(docs).map((d) => d.id).sort(), ['jornada', 'turno']);
  });

  test('los orígenes críticos incluyen seguridad + jornada + turno', () => {
    for (const o of ['bypass_seguridad', 'jornada_v2_cuota_cumplida', 'cachatore', 'volvo_alert_high']) {
      assert.ok(ORIGENES_CRITICOS.has(o), `falta ${o}`);
    }
    // NO debe incluir confirmaciones de comando ni resúmenes
    assert.ok(!ORIGENES_CRITICOS.has('silenciado_aviso'));
    assert.ok(!ORIGENES_CRITICOS.has('drift_diario'));
  });
});

describe('construirEscalacion', () => {
  test('lista los avisos con origen → destinatario', () => {
    const msg = construirEscalacion([
      { id: 'a', origen: 'jornada_v2_cuota_cumplida', destinatario_id: '111' },
    ]);
    assert.match(msg, /Failover \(bot caído\)/);
    assert.match(msg, /jornada_v2_cuota_cumplida → 111/);
    assert.match(msg, /bot sigue caído/);
  });

  test('trunca a 15 con "y N más"', () => {
    const items = Array.from({ length: 20 }, (_, i) =>
      ({ id: String(i), origen: 'volvo_alert_high', destinatario_id: String(i) }));
    const msg = construirEscalacion(items);
    assert.match(msg, /… y 5 más/);
  });
});
