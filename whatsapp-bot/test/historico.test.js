// Tests de historico.js — escalonado de URGENCIA (qué aviso manda) e
// IDEMPOTENCIA del id (no duplicar / recordatorio diario de vencidos). Lógica
// pura sin red. Sin cobertura previa (auditoría 2026-06-11): un off-by-one acá
// manda el aviso equivocado o lo duplica.

const { test, describe } = require('node:test');
const assert = require('node:assert');
const h = require('../src/historico');

describe('historico.urgenciaPara — fronteras de días', () => {
  test('null y lejano (>30) → null', () => {
    assert.strictEqual(h.urgenciaPara(null), null);
    assert.strictEqual(h.urgenciaPara(31), null);
    assert.strictEqual(h.urgenciaPara(100), null);
  });

  test('vencido (días < 0)', () => {
    assert.strictEqual(h.urgenciaPara(-1).codigo, 'vencido');
    assert.strictEqual(h.urgenciaPara(-100).codigo, 'vencido');
  });

  test('fronteras exactas: 0 / 7 / 8 / 15 / 16 / 30', () => {
    assert.strictEqual(h.urgenciaPara(0).codigo, 'hoy');
    assert.strictEqual(h.urgenciaPara(1).codigo, 'urgente');
    assert.strictEqual(h.urgenciaPara(7).codigo, 'urgente');
    assert.strictEqual(h.urgenciaPara(8).codigo, 'recordatorio');
    assert.strictEqual(h.urgenciaPara(15).codigo, 'recordatorio');
    assert.strictEqual(h.urgenciaPara(16).codigo, 'preventivo');
    assert.strictEqual(h.urgenciaPara(30).codigo, 'preventivo');
  });
});

describe('historico.urgenciaServicePara — fronteras de KM', () => {
  test('null / NaN / lejano (>5000) → null', () => {
    assert.strictEqual(h.urgenciaServicePara(null), null);
    assert.strictEqual(h.urgenciaServicePara(NaN), null);
    assert.strictEqual(h.urgenciaServicePara(5001), null);
  });

  test('fronteras: 0 / 1000 / 1001 / 2500 / 2501 / 5000', () => {
    assert.strictEqual(h.urgenciaServicePara(0).codigo, 'service_vencido');
    assert.strictEqual(h.urgenciaServicePara(-50).codigo, 'service_vencido');
    assert.strictEqual(h.urgenciaServicePara(1000).codigo, 'service_urgente');
    assert.strictEqual(h.urgenciaServicePara(1001).codigo, 'service_programar');
    assert.strictEqual(h.urgenciaServicePara(2500).codigo, 'service_programar');
    assert.strictEqual(h.urgenciaServicePara(2501).codigo, 'service_atencion');
    assert.strictEqual(h.urgenciaServicePara(5000).codigo, 'service_atencion');
  });
});

describe('historico.buildId — idempotencia + recordatorio diario', () => {
  const base = {
    coleccion: 'VEHICULOS', docId: 'AB123CD', campoBase: 'RTO',
    fechaVenc: '2026-08-01',
  };

  test('no-vencido: id ESTABLE (mismo en el día) → no se duplica', () => {
    const id1 = h.buildId({ ...base, urgencia: 'urgente' });
    const id2 = h.buildId({ ...base, urgencia: 'urgente' });
    assert.strictEqual(id1, id2);
  });

  test('vencido: agrega un segmento de fecha (recordatorio diario)', () => {
    const idUrgente = h.buildId({ ...base, urgencia: 'urgente' });
    const idVencido = h.buildId({ ...base, urgencia: 'vencido' });
    assert.ok(idVencido.includes('vencido'));
    // vencido lleva la fecha de HOY como segmento extra → más segmentos "_".
    assert.ok(
      idVencido.split('_').length > idUrgente.split('_').length,
      'el vencido debe llevar la fecha de hoy como segmento extra'
    );
  });

  test('service_vencido también agrega la fecha de hoy', () => {
    const id = h.buildId({ ...base, urgencia: 'service_vencido' });
    assert.ok(id.split('_').length >= 6);
  });

  test('sanitiza "/" (no apto para document IDs de Firestore)', () => {
    const id = h.buildId({
      coleccion: 'X', docId: 'A/B', campoBase: 'C', urgencia: 'hoy',
      fechaVenc: '2026/01/01',
    });
    assert.ok(!id.includes('/'), 'el id no debe tener barras');
  });
});
