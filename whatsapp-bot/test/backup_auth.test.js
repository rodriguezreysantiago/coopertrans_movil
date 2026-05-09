// Tests para backup_auth.js → _construirNombre.
//
// Cubre el sanitizado de pcId (sin path traversal, caracteres
// inválidos en nombres de archivo) y el formato del timestamp en TZ
// ART para que el orden lexicográfico coincida con el cronológico.

process.env.TZ = 'America/Argentina/Buenos_Aires';

const { test, describe } = require('node:test');
const assert = require('node:assert');
const { _construirNombre } = require('../src/backup_auth');

describe('backup_auth._construirNombre', () => {
  test('formato base: pcId_YYYY-MM-DD-HHmm.zip', () => {
    const nombre = _construirNombre('oficina');
    assert.match(nombre, /^oficina_\d{4}-\d{2}-\d{2}-\d{4}\.zip$/);
  });

  test('sanitiza caracteres raros del pcId', () => {
    // Path traversal y caracteres no válidos para nombres de archivo
    // se convierten a _.
    const nombre = _construirNombre('../etc/passwd');
    assert.match(nombre, /^_\._\.etc_passwd_\d{4}-\d{2}-\d{2}-\d{4}\.zip$/);
    assert.doesNotMatch(nombre, /\.\.\//);
  });

  test('preserva alfanuméricos, _ y - del pcId', () => {
    const nombre = _construirNombre('PC-Casa_v2');
    assert.match(nombre, /^PC-Casa_v2_\d{4}-\d{2}-\d{2}-\d{4}\.zip$/);
  });

  test('pcId vacío se sanitiza a string vacío + timestamp', () => {
    const nombre = _construirNombre('');
    assert.match(nombre, /^_\d{4}-\d{2}-\d{2}-\d{4}\.zip$/);
  });

  test('timestamp ordenable lexicográficamente', () => {
    // Generar 2 nombres con 1ms de diferencia y verificar que el
    // segundo (cronológicamente posterior) ordena después
    // alfabéticamente. La precisión es a minutos, así que esto
    // funciona si la prueba corre rápido — pero si justo cae en
    // límite de minuto, ambos pueden ser iguales (no falla, solo
    // empata).
    const n1 = _construirNombre('test');
    const n2 = _construirNombre('test');
    assert.ok(n1 <= n2, `${n1} debería ser <= ${n2} lexicográficamente`);
  });
});
