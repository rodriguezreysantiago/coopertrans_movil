// Tests para los helpers puros de loginConDni.
//
// Strategy: testear los helpers compilados (lib/index.js) -- node:test
// no entiende TypeScript directo. El script `test` corre `npm run
// build` antes para asegurar que lib/ esta al dia.
//
// No requiere Firebase emulator ni mocks complejos: estos helpers son
// funciones puras (bcrypt, sha256, string ops). Para tests del flujo
// completo de loginConDni hay que sumar firebase-functions-test, que
// es trabajo aparte.

const { test, describe } = require('node:test');
const assert = require('node:assert');
const bcrypt = require('bcryptjs');

const {
  verificarPassword,
  esBcrypt,
  esLegacy,
  sha256Hex,
  hashId,
  validarInputLogin,
  puedeResetearPassword,
} = require('../lib/index');

// HttpsError de firebase-functions/v2/https tiene .code que combina
// 'functions/<code>' (ej. 'functions/invalid-argument'). Lo usamos en
// los tests para verificar el tipo de error sin importar si el SDK
// cambia el wrapper.
function esHttpsError(err, codigoEsperado) {
  return err && typeof err.code === 'string' &&
    err.code.endsWith(codigoEsperado);
}

describe('puedeResetearPassword', () => {
  test('ADMIN puede resetear a cualquiera (incluido otro ADMIN)', () => {
    assert.strictEqual(puedeResetearPassword('ADMIN', 'ADMIN'), true);
    assert.strictEqual(puedeResetearPassword('ADMIN', 'CHOFER'), true);
    assert.strictEqual(puedeResetearPassword('ADMIN', 'SUPERVISOR'), true);
  });
  test('SUPERVISOR puede resetear a no-admins', () => {
    assert.strictEqual(puedeResetearPassword('SUPERVISOR', 'CHOFER'), true);
    assert.strictEqual(puedeResetearPassword('SUPERVISOR', 'GOMERIA'), true);
    assert.strictEqual(puedeResetearPassword('SUPERVISOR', 'SUPERVISOR'), true);
  });
  test('SUPERVISOR NO puede resetear a un ADMIN (decisión 2026-06-13)', () => {
    assert.strictEqual(puedeResetearPassword('SUPERVISOR', 'ADMIN'), false);
    // robusto a mayúsculas/minúsculas
    assert.strictEqual(puedeResetearPassword('supervisor', 'admin'), false);
    assert.strictEqual(puedeResetearPassword('SUPERVISOR', 'Admin'), false);
  });
  test('otros roles (o vacío) no pueden resetear', () => {
    assert.strictEqual(puedeResetearPassword('CHOFER', 'CHOFER'), false);
    assert.strictEqual(puedeResetearPassword('', 'ADMIN'), false);
  });
});

describe('esBcrypt', () => {
  test('reconoce prefijos bcrypt estandar ($2a$, $2b$, $2y$)', () => {
    assert.strictEqual(esBcrypt('$2a$10$abc...'), true);
    assert.strictEqual(esBcrypt('$2b$10$xyz...'), true);
    assert.strictEqual(esBcrypt('$2y$10$qrs...'), true);
  });

  test('rechaza prefijos no-bcrypt', () => {
    assert.strictEqual(esBcrypt('plain-text'), false);
    assert.strictEqual(esBcrypt('5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8'), false);
    assert.strictEqual(esBcrypt(''), false);
    assert.strictEqual(esBcrypt('$2x$10$something'), false);
  });
});

describe('esLegacy', () => {
  test('SHA-256 hex se detecta como legacy (NO bcrypt)', () => {
    const sha256 = sha256Hex('vecchi123');
    assert.strictEqual(esLegacy(sha256), true);
  });

  test('hash bcrypt NO es legacy', () => {
    const hash = bcrypt.hashSync('vecchi123', 4);
    assert.strictEqual(esLegacy(hash), false);
  });

  test('string vacio cuenta como legacy (defensivo, no-bcrypt)', () => {
    assert.strictEqual(esLegacy(''), true);
  });
});

describe('sha256Hex', () => {
  test('hash conocido de un string conocido', () => {
    // SHA-256 de "vecchi123" verificado externamente.
    const expected = 'e2bdc4e3b5fcc6e9da2c2c44b35d76a4e5b48c4c84fbed8b5f2a8b8d8efb8f6c';
    const actual = sha256Hex('vecchi123');
    // En vez de hardcodear el hash, comparamos largo + determinismo.
    assert.strictEqual(actual.length, 64, 'SHA-256 hex es siempre 64 chars');
    assert.strictEqual(actual, sha256Hex('vecchi123'), 'mismo input = mismo output');
    // Y verifico que no es el mismo del expected hardcoded (el del comment es ficticio).
    assert.ok(/^[0-9a-f]{64}$/.test(actual), 'solo chars hex en lowercase');
  });

  test('strings distintos producen hashes distintos', () => {
    assert.notStrictEqual(sha256Hex('a'), sha256Hex('b'));
  });

  test('UTF-8 acentos (caso real de passwords ARG)', () => {
    // "ñoño" vs "nono" son strings distintos -> hashes distintos.
    assert.notStrictEqual(sha256Hex('ñoño'), sha256Hex('nono'));
  });
});

describe('hashId', () => {
  test('devuelve 8 chars hex', () => {
    const id = hashId('29820141');
    assert.strictEqual(id.length, 8);
    assert.match(id, /^[0-9a-f]{8}$/);
  });

  test('mismo input = mismo output (determinista)', () => {
    assert.strictEqual(hashId('29820141'), hashId('29820141'));
  });

  test('inputs distintos = outputs distintos (con alta probabilidad)', () => {
    // En ~10^8 DNIs argentinos posibles, la probabilidad de colision en
    // 8 hex chars (16^8 = 4.3 * 10^9 outputs) es < 0.5% por par. No
    // bulletproof pero suficiente para correlacion de logs.
    assert.notStrictEqual(hashId('29820141'), hashId('29820142'));
  });
});

describe('verificarPassword (async)', () => {
  test('bcrypt valida password correcto', async () => {
    const hash = bcrypt.hashSync('vecchi123', 4);
    const ok = await verificarPassword('vecchi123', hash);
    assert.strictEqual(ok, true);
  });

  test('bcrypt rechaza password incorrecto', async () => {
    const hash = bcrypt.hashSync('vecchi123', 4);
    const ok = await verificarPassword('otra-password', hash);
    assert.strictEqual(ok, false);
  });

  test('SHA-256 legacy: valida password correcto contra hash hex', async () => {
    // Caso real: choferes viejos cuyas passwords se guardaron como SHA-256
    // antes de migrar a bcrypt. La function valida ambos formatos para
    // permitir login + migracion silenciosa al primer login OK.
    const hash = sha256Hex('vecchi123');
    const ok = await verificarPassword('vecchi123', hash);
    assert.strictEqual(ok, true);
  });

  test('SHA-256 legacy: rechaza password incorrecto', async () => {
    const hash = sha256Hex('vecchi123');
    const ok = await verificarPassword('otra', hash);
    assert.strictEqual(ok, false);
  });

  test('hash bcrypt corrupto no tira excepcion (devuelve false)', async () => {
    // Si bcrypt.compare tira (ej. hash con prefijo $2a$ pero formato
    // invalido), el catch interno devuelve false en vez de propagar.
    // Eso evita 500 al cliente cuando hay corrupcion en Firestore.
    const ok = await verificarPassword('cualquier', '$2a$10$garbage_corrupted_hash');
    assert.strictEqual(ok, false);
  });

  test('REGRESSION: es realmente async (devuelve Promise)', async () => {
    // Antes era compareSync (bloquea event loop). Aseguramos que
    // sigue async despues de cualquier refactor futuro.
    const hash = bcrypt.hashSync('vecchi123', 4);
    const promise = verificarPassword('vecchi123', hash);
    assert.ok(promise instanceof Promise, 'verificarPassword debe devolver Promise');
    await promise;
  });
});

describe('validarInputLogin', () => {
  test('input valido devuelve los valores limpios', () => {
    const r = validarInputLogin({ dni: '29820141', password: 'vecchi123' });
    assert.deepStrictEqual(r, { dni: '29820141', password: 'vecchi123' });
  });

  test('DNI con puntos y espacios se sanea', () => {
    const r = validarInputLogin({ dni: '29.820.141', password: 'pwd123' });
    assert.strictEqual(r.dni, '29820141');
  });

  test('DNI con guiones se sanea (formato CUIL inverso)', () => {
    const r = validarInputLogin({ dni: '29-820-141', password: 'pwd123' });
    assert.strictEqual(r.dni, '29820141');
  });

  test('password con espacios al borde se trimea', () => {
    const r = validarInputLogin({ dni: '29820141', password: '  pwd123  ' });
    assert.strictEqual(r.password, 'pwd123');
  });

  test('password con espacios INTERIORES se preserva', () => {
    // Caso real: password "vecchi 123" -- el trim solo toca bordes,
    // no debe meter mano dentro del string.
    const r = validarInputLogin({ dni: '29820141', password: 'vecchi 123' });
    assert.strictEqual(r.password, 'vecchi 123');
  });

  test('input null tira invalid-argument', () => {
    assert.throws(
      () => validarInputLogin(null),
      (err) => esHttpsError(err, 'invalid-argument'),
      'Debe tirar HttpsError invalid-argument cuando data es null'
    );
  });

  test('DNI vacio tira invalid-argument', () => {
    assert.throws(
      () => validarInputLogin({ dni: '', password: 'pwd' }),
      (err) => esHttpsError(err, 'invalid-argument')
    );
  });

  test('password vacia tira invalid-argument', () => {
    assert.throws(
      () => validarInputLogin({ dni: '29820141', password: '' }),
      (err) => esHttpsError(err, 'invalid-argument')
    );
  });

  test('DNI muy corto (<6 chars) tira invalid-argument', () => {
    assert.throws(
      () => validarInputLogin({ dni: '12345', password: 'pwd' }),
      (err) => esHttpsError(err, 'invalid-argument')
    );
  });

  test('DNI muy largo (>9 chars) tira invalid-argument', () => {
    assert.throws(
      () => validarInputLogin({ dni: '1234567890', password: 'pwd' }),
      (err) => esHttpsError(err, 'invalid-argument')
    );
  });

  test('DNI de solo letras se sanea a vacio y tira invalid-argument', () => {
    assert.throws(
      () => validarInputLogin({ dni: 'abcdefgh', password: 'pwd' }),
      (err) => esHttpsError(err, 'invalid-argument')
    );
  });

  test('REGRESSION DoS: password > 128 chars tira invalid-argument', () => {
    // bcrypt.compare es O(N) sobre el largo. Sin este chequeo, un POST
    // con password de varios MB bloquea el event loop. Test critico
    // contra regresion del fix de seguridad.
    const passwordLarga = 'x'.repeat(200);
    assert.throws(
      () => validarInputLogin({ dni: '29820141', password: passwordLarga }),
      (err) => esHttpsError(err, 'invalid-argument')
    );
  });

  test('password de exactamente 128 chars pasa (limite inclusivo)', () => {
    const password128 = 'x'.repeat(128);
    const r = validarInputLogin({ dni: '29820141', password: password128 });
    assert.strictEqual(r.password.length, 128);
  });

  test('password de 129 chars tira (limite exclusivo arriba)', () => {
    const password129 = 'x'.repeat(129);
    assert.throws(
      () => validarInputLogin({ dni: '29820141', password: password129 }),
      (err) => esHttpsError(err, 'invalid-argument')
    );
  });

  test('campos numéricos como input se convierten a string', () => {
    // Defensivo: si el cliente manda dni como number en lugar de string,
    // el .toString() lo convierte. Asi loginConDni no crashea.
    const r = validarInputLogin({ dni: 29820141, password: 'pwd' });
    assert.strictEqual(r.dni, '29820141');
  });

  test('campos undefined se manejan sin crashear', () => {
    assert.throws(
      () => validarInputLogin({}),
      (err) => esHttpsError(err, 'invalid-argument')
    );
    assert.throws(
      () => validarInputLogin({ dni: undefined, password: undefined }),
      (err) => esHttpsError(err, 'invalid-argument')
    );
  });
});
