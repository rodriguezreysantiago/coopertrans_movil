// Tests para commands.js. Corre con `node --test`.
//
// El test mas importante: regression del bug del 1-mayo donde el match
// laxo de _esAdmin permitia que cualquier numero terminado en los
// ultimos 7 digitos del admin ejecutara /pausar, /forzar-cron, etc.
process.env.TZ = 'America/Argentina/Buenos_Aires';

const { test, describe, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert');

// Capturamos el original para restaurar entre tests.
const ENV_ORIGINAL = process.env.ADMIN_PHONES;

function setWhitelist(csv) {
  process.env.ADMIN_PHONES = csv;
}

// Cargamos el modulo despues de configurar el env -- pero como los
// helpers leen ADMIN_PHONES en cada llamada (no en import), podemos
// requerir una sola vez al top.
const {
  _esAdmin,
  _adminWhitelist,
  _construirTextoJornadaChofer,
  MIN_DIGITOS_PARA_MATCH,
} = require('../src/commands');

// Fake de un DocumentSnapshot de Firestore para los tests del texto de
// jornada. `data` null → snap "vacío" (exists=false).
function fakeSnap(data) {
  return {
    exists: data != null,
    data: () => data || {},
  };
}

describe('commands._esAdmin — fix del bug de match laxo', () => {
  beforeEach(() => {
    setWhitelist('5492914567890');
  });

  afterEach(() => {
    if (ENV_ORIGINAL === undefined) delete process.env.ADMIN_PHONES;
    else process.env.ADMIN_PHONES = ENV_ORIGINAL;
  });

  test('numero igual al admin → true', () => {
    assert.strictEqual(_esAdmin('5492914567890'), true);
  });

  test('numero con codigo pais explicito → true (sufijo >= 10)', () => {
    // Argentina nacional sin codigo pais.
    assert.strictEqual(_esAdmin('2914567890'), true);
  });

  test('REGRESSION: sufijo de 7 digitos NO debe matchear', () => {
    // Bug que arreglamos: "4567890" matcheaba con "5492914567890"
    // porque endsWith() en cualquiera de los dos sentidos era true.
    // Ahora MIN_DIGITOS_PARA_MATCH=10 lo bloquea.
    assert.strictEqual(_esAdmin('4567890'), false);
  });

  test('REGRESSION: sufijo de 8 digitos tampoco matchea', () => {
    assert.strictEqual(_esAdmin('14567890'), false);
  });

  test('REGRESSION: sufijo de 9 digitos tampoco matchea', () => {
    assert.strictEqual(_esAdmin('914567890'), false);
  });

  test('numero distinto del admin → false', () => {
    assert.strictEqual(_esAdmin('5491100000000'), false);
  });

  test('formato con + y guiones se normaliza antes del match', () => {
    assert.strictEqual(_esAdmin('+54 9 291 4567890'), true);
    assert.strictEqual(_esAdmin('+54-9-2914567890'), true);
  });

  test('numero corto (< 10 digitos) → false', () => {
    assert.strictEqual(_esAdmin('123'), false);
    assert.strictEqual(_esAdmin('456789'), false);
  });

  test('input vacio o no string → false', () => {
    assert.strictEqual(_esAdmin(''), false);
    assert.strictEqual(_esAdmin(null), false);
    assert.strictEqual(_esAdmin(undefined), false);
  });

  test('whitelist vacia → false para cualquier input', () => {
    setWhitelist('');
    assert.strictEqual(_esAdmin('5492914567890'), false);
  });

  test('whitelist con varias entradas, match en una', () => {
    setWhitelist('5491100000001,5492914567890,5491100000002');
    assert.strictEqual(_esAdmin('5492914567890'), true);
  });

  test('whitelist con entrada corta (< 10 digitos) se descarta', () => {
    // Si alguien pone "123" en ADMIN_PHONES por error, _adminWhitelist
    // la filtra para que no cuente como admin.
    setWhitelist('123,5492914567890');
    assert.strictEqual(_esAdmin('123'), false);
    // Y la valida sigue funcionando.
    assert.strictEqual(_esAdmin('5492914567890'), true);
  });
});

describe('commands._adminWhitelist', () => {
  beforeEach(() => {
    setWhitelist('5492914567890,+5491100000000,abc,123');
  });

  afterEach(() => {
    if (ENV_ORIGINAL === undefined) delete process.env.ADMIN_PHONES;
    else process.env.ADMIN_PHONES = ENV_ORIGINAL;
  });

  test('separa por coma y limpia no-digitos', () => {
    const wl = _adminWhitelist();
    assert.deepStrictEqual(wl, ['5492914567890', '5491100000000']);
  });

  test('descarta entradas con < 10 digitos', () => {
    const wl = _adminWhitelist();
    assert.ok(!wl.includes('123'));
    assert.ok(!wl.includes('abc'));
  });
});

describe('commands.MIN_DIGITOS_PARA_MATCH', () => {
  test('es 10 (numero de digitos de un telefono argentino sin codigo pais)', () => {
    assert.strictEqual(MIN_DIGITOS_PARA_MATCH, 10);
  });
});

// El texto que produce este helper es lo que recibe el chofer tanto por
// /jornada (que lo tipea él) como por /enviar-jornada (que lo manda el
// admin). Es contenido que va a personas reales — lo lockeamos.
describe('commands._construirTextoJornadaChofer', () => {
  const chofer = { dni: '123', nombre: 'JUAN PEREZ', apodo: '', telefono: '' };
  const fecha = '2026-05-19';

  test('sin jornada activa → mensaje claro de que no hay jornada', () => {
    const txt = _construirTextoJornadaChofer({
      chofer, jSnap: null, silSnap: fakeSnap(null), fecha,
    });
    assert.match(txt, /Hola JUAN/);              // primer nombre (bot no capitaliza)
    assert.match(txt, /No tenés jornada activa/);
  });

  test('saludo usa apodo si está cargado', () => {
    const txt = _construirTextoJornadaChofer({
      chofer: { ...chofer, apodo: 'Pipi' },
      jSnap: null, silSnap: fakeSnap(null), fecha,
    });
    assert.match(txt, /Hola Pipi/);
  });

  test('jornada en curso (manejo neto < 12h) → muestra total + restante', () => {
    const jSnap = fakeSnap({
      total_manejo_seg: 6 * 3600,       // 6h en bloques cerrados
      bloque_actual_manejo_seg: 3600,   // 1h en bloque actual → 7h neto
      bloque_actual_pausa_seg: 0,
      descanso_segundos: 0,
      estado: 'manejando',
    });
    const txt = _construirTextoJornadaChofer({
      chofer, jSnap, silSnap: fakeSnap(null), fecha,
    });
    assert.match(txt, /Total manejado en la jornada: 7h 00m de 12 hs/);
    assert.match(txt, /te quedan \*5h 00m\*/);   // 12h - 7h = 5h restante
    assert.doesNotMatch(txt, /Llegaste al límite/);
  });

  test('manejo neto >= 12h → aviso de límite alcanzado', () => {
    const jSnap = fakeSnap({
      total_manejo_seg: 12 * 3600,
      bloque_actual_manejo_seg: 0,
      estado: 'manejando',
    });
    const txt = _construirTextoJornadaChofer({
      chofer, jSnap, silSnap: fakeSnap(null), fecha,
    });
    assert.match(txt, /Llegaste al límite de tu jornada diaria \(12 horas\)/);
  });

  test('silenciado → muestra el aviso de silencio', () => {
    const ms = Date.now() + 3600 * 1000;
    const futuro = { toMillis: () => ms, toDate: () => new Date(ms) };
    const txt = _construirTextoJornadaChofer({
      chofer, jSnap: null,
      silSnap: fakeSnap({ silenciado_hasta: futuro }),
      fecha,
    });
    assert.match(txt, /silenciados/);
  });

  test('lista avisos enviados (3h30 + heads-up 11h)', () => {
    const jSnap = fakeSnap({
      total_manejo_seg: 11 * 3600,
      bloque_actual_manejo_seg: 0,
      alerta_3_30_enviada: true,
      alerta_cuota_proxima_enviada: true,
      alerta_cuota_enviada: false,
      estado: 'manejando',
    });
    const txt = _construirTextoJornadaChofer({
      chofer, jSnap, silSnap: fakeSnap(null), fecha,
    });
    assert.match(txt, /Avisos de esta jornada/);
    assert.match(txt, /parar a descansar 20 min/);
    assert.match(txt, /Llevás 11 horas/);
  });

  test('heads-up 11h NO se muestra si ya llegó al límite (12h)', () => {
    const jSnap = fakeSnap({
      total_manejo_seg: 12 * 3600,
      bloque_actual_manejo_seg: 0,
      alerta_cuota_proxima_enviada: true,
      alerta_cuota_enviada: true,
      estado: 'manejando',
    });
    const txt = _construirTextoJornadaChofer({
      chofer, jSnap, silSnap: fakeSnap(null), fecha,
    });
    // El heads-up "Llevás 11 horas" no debe aparecer cuando ya hay aviso firme.
    assert.doesNotMatch(txt, /Llevás 11 horas/);
    assert.match(txt, /Llegaste al límite/);
  });
});
