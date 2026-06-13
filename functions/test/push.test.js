// Tests de la lógica PURA de push (push.ts): qué tokens FCM podar según el
// resultado del multicast. El envío en sí (getMessaging) + el trigger
// necesitan el SDK/emulador y no se testean acá.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const { tokensAPodar } = require('../lib/push');

describe('tokensAPodar', () => {
  test('token con error "not-registered" → se poda', () => {
    const tokens = ['t1', 't2'];
    const resp = [
      { exito: true },
      { exito: false, codigoError: 'messaging/registration-token-not-registered' },
    ];
    assert.deepStrictEqual(tokensAPodar(tokens, resp), ['t2']);
  });

  test('error TRANSITORIO (unavailable) NO se poda — el token sigue válido', () => {
    const tokens = ['t1'];
    const resp = [{ exito: false, codigoError: 'messaging/server-unavailable' }];
    assert.deepStrictEqual(tokensAPodar(tokens, resp), []);
  });

  test('invalid-registration-token y invalid-argument se podan', () => {
    const tokens = ['a', 'b', 'c'];
    const resp = [
      { exito: false, codigoError: 'messaging/invalid-registration-token' },
      { exito: false, codigoError: 'messaging/invalid-argument' },
      { exito: true },
    ];
    assert.deepStrictEqual(tokensAPodar(tokens, resp), ['a', 'b']);
  });

  test('todos OK → nada que podar', () => {
    assert.deepStrictEqual(
      tokensAPodar(['x', 'y'], [{ exito: true }, { exito: true }]),
      []);
  });

  test('respuesta faltante (desalineada) no rompe', () => {
    assert.deepStrictEqual(tokensAPodar(['x'], []), []);
  });
});
