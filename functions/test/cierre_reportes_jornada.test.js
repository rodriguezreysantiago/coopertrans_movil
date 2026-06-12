// Tests del cierre automático de reclamos de jornada (cron 08:00). Funciones
// PURAS de decisión: cuándo es CIERTO (v3 o GPS detenido), cuándo NO_CIERTO (GPS
// en movimiento, con evidencia) y cuándo NO se decide (sin hora / hueco GPS →
// revisión manual, nunca acusa a ciegas).

const { test, describe } = require('node:test');
const assert = require('node:assert');

const {
  horasDelReclamo,
  ventanaReclamada,
  v3ConfirmaPausa,
  analizarGpsVentana,
  decidirCierre,
} = require('../lib/cierre_reportes_jornada');

const FECHA = '2026-06-11';
const ms = (hhmm) => Date.parse(`${FECHA}T${hhmm}:00-03:00`);
const pausa = (ini, fin) => ({ inicioMs: ms(ini), finMs: ms(fin), durSeg: (ms(fin) - ms(ini)) / 1000 });
const ev = (hhmm, speed, name = '') => ({ ms: ms(hhmm), speed, eventName: name });

describe('horasDelReclamo', () => {
  test('extrae HH:MM y H.MM', () => {
    assert.deepStrictEqual(horasDelReclamo('paré 18:50 a 19.23').map((x) => x.label), ['18:50', '19:23']);
  });
  test('ignora "4 horas" / "10 minutos" (no son HH:MM)', () => {
    assert.strictEqual(horasDelReclamo('me pasé 10 minutos de un bloque de 4 horas').length, 0);
  });
});

describe('ventanaReclamada', () => {
  test('2 horas → [h1, h2]', () => {
    const v = ventanaReclamada('paré 18:50 a 19:23', FECHA);
    assert.strictEqual(v.t0, ms('18:50'));
    assert.strictEqual(v.t1, ms('19:23'));
  });
  test('sin hora concreta → null', () => {
    assert.strictEqual(ventanaReclamada('me pasé 10 min', FECHA), null);
  });
});

describe('v3ConfirmaPausa', () => {
  test('pausa v3 cerca de la hora reclamada (±20 min) → confirma', () => {
    const r = v3ConfirmaPausa('paré 18:50', FECHA, [pausa('18:51', '19:17')], ms('19:30'));
    assert.strictEqual(r.confirma, true);
    assert.match(r.nota, /confirma tu pausa de 18:51 a 19:17/);
  });
  test('pausa < 15 min no alcanza el umbral', () => {
    const r = v3ConfirmaPausa('paré 19:30', FECHA, [pausa('19:42', '19:54')], ms('19:55'));
    assert.strictEqual(r.confirma, false);
  });
  test('sin hora pero pausa reciente al reporte → confirma (reciencia)', () => {
    const r = v3ConfirmaPausa('estuve parado 20 min', FECHA, [pausa('19:00', '19:25')], ms('19:30'));
    assert.strictEqual(r.confirma, true);
  });
});

describe('analizarGpsVentana', () => {
  test('detención que cubre la franja → detenido', () => {
    const r = analizarGpsVentana([ev('18:51', 0, 'Inicio de detenido'), ev('19:17', 77, 'Fin de detenido')], ms('18:50'), ms('19:23'));
    assert.strictEqual(r.resultado, 'detenido');
    assert.match(r.nota, /detenido de 18:51 a 19:17/);
  });
  test('velocidad sostenida en la franja → movimiento (con evidencia)', () => {
    const r = analizarGpsVentana([ev('19:00', 70), ev('19:10', 80), ev('19:20', 65)], ms('19:00'), ms('19:23'));
    assert.strictEqual(r.resultado, 'movimiento');
    assert.match(r.nota, /km\/h/);
  });
  test('una sola muestra rápida (arranque) NO alcanza para acusar', () => {
    const r = analizarGpsVentana([ev('19:22', 70)], ms('19:00'), ms('19:23'));
    assert.notStrictEqual(r.resultado, 'movimiento');
  });
  test('sin eventos en la franja → incierto (hueco de señal)', () => {
    const r = analizarGpsVentana([], ms('19:00'), ms('19:23'));
    assert.strictEqual(r.resultado, 'incierto');
  });
});

describe('decidirCierre — decisión final conservadora', () => {
  const base = { detalle: '', fechaArt: FECHA, reporteMs: ms('19:30'), pausasV3: [], eventosGps: [] };

  test('v3 confirma → CIERTO', () => {
    const d = decidirCierre({ ...base, detalle: 'paré 18:50', pausasV3: [pausa('18:51', '19:17')] });
    assert.strictEqual(d.veredicto, 'cierto');
  });
  test('v3 no la ve pero GPS detenido → CIERTO (v3 la perdió por gap)', () => {
    const d = decidirCierre({ ...base, detalle: 'paré 18:50 a 19:23', eventosGps: [ev('18:51', 0, 'Inicio de detenido'), ev('19:17', 60, 'Fin de detenido')] });
    assert.strictEqual(d.veredicto, 'cierto');
  });
  test('v3 no la ve y GPS andando → NO_CIERTO con evidencia', () => {
    const d = decidirCierre({ ...base, detalle: 'paré 19:00 a 19:23', eventosGps: [ev('19:05', 70), ev('19:15', 75)] });
    assert.strictEqual(d.veredicto, 'no_cierto');
    assert.match(d.nota, /movimiento/);
  });
  test('sin hora concreta (justifica un exceso, tipo FERNANDEZ) → MANUAL (null)', () => {
    const d = decidirCierre({ ...base, detalle: 'me pasé 10 minutos de un bloque de 4 horas para llegar a la planta' });
    assert.strictEqual(d, null);
  });
  test('GPS con hueco de señal → MANUAL (null), NO acusa', () => {
    const d = decidirCierre({ ...base, detalle: 'paré 19:00 a 19:23', eventosGps: [] });
    assert.strictEqual(d, null);
  });
});
