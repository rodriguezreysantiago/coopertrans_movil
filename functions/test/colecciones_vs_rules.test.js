// Vacuna anti-regresión del bug AGENTE_CONVERSACIONES (auditoría 2026-06-12):
// la colección se usaba desde el cliente Flutter pero NO tenía match block en
// firestore.rules → caía al catch-all `if false` y el dashboard del agente
// tiraba permission-denied EN PRODUCCIÓN.
//
// Este test estático (sin emulador) compara las colecciones que el cliente
// conoce (constantes de AppCollections en app_constants.dart) contra los
// match blocks de firestore.rules. Si agregás una colección al cliente sin
// escribirle regla, este test falla ANTES del deploy.
//
// OJO: esto NO valida que las reglas sean CORRECTAS (eso lo hace la suite
// de test_rules/ con el emulador) — solo que existan.

const { test, describe } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const RAIZ = path.resolve(__dirname, '..', '..');

// Colecciones de AppCollections que NO necesitan regla porque el cliente
// jamás las consulta directo (server-only por diseño). Hoy: ninguna —
// si algún día se agrega una constante server-only a AppCollections,
// documentarla acá con el motivo.
const SERVER_ONLY = new Set([]);

function coleccionesDelCliente() {
  const dart = fs.readFileSync(
    path.join(RAIZ, 'lib', 'core', 'constants', 'app_constants.dart'),
    'utf8',
  );
  const inicio = dart.indexOf('class AppCollections');
  assert.ok(inicio >= 0, 'no encontré la clase AppCollections');
  const fin = dart.indexOf('class ', inicio + 10);
  const bloque = dart.slice(inicio, fin > 0 ? fin : undefined);
  return [...bloque.matchAll(/static const String \w+ =\s*'([A-Z_0-9]+)'/g)]
    .map((m) => m[1]);
}

function matchBlocksDeRules() {
  const rules = fs.readFileSync(path.join(RAIZ, 'firestore.rules'), 'utf8');
  return new Set(
    [...rules.matchAll(/match \/([A-Z_0-9]+)\//g)].map((m) => m[1]),
  );
}

describe('AppCollections vs firestore.rules', () => {
  test('toda colección que usa el cliente tiene match block en rules', () => {
    const apps = coleccionesDelCliente();
    const reglas = matchBlocksDeRules();
    assert.ok(apps.length >= 40,
      `parse sospechoso: solo ${apps.length} colecciones (¿cambió el formato de AppCollections?)`);
    const sinRegla = apps.filter(
      (c) => !reglas.has(c) && !SERVER_ONLY.has(c),
    );
    assert.deepStrictEqual(sinRegla, [],
      `Colecciones usadas por la app SIN regla en firestore.rules (caen al ` +
      `catch-all deny → permission-denied en prod, como AGENTE_CONVERSACIONES ` +
      `2026-06-12): ${sinRegla.join(', ')}. Agregá el match block o, si es ` +
      `server-only, documentala en SERVER_ONLY de este test.`);
  });

  test('el catch-all deny final sigue existiendo', () => {
    const rules = fs.readFileSync(path.join(RAIZ, 'firestore.rules'), 'utf8');
    assert.match(rules, /match \/\{document=\*\*\}\s*\{\s*allow read, write: if false;/,
      'el catch-all {document=**} deny es la red de seguridad de TODO el modelo');
  });
});
