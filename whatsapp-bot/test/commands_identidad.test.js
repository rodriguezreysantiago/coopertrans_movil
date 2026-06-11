// Tests de commands._resolverChoferPorTelefono — la defensa anti-suplantación
// del lado de los /comandos: resuelve al chofer SOLO por teléfono real (match
// estricto), nunca por pushname ni por sufijo coincidente. Sin cobertura previa
// (auditoría 2026-06-11) pese al historial de bugs de identidad en este archivo.

const { test, describe } = require('node:test');
const assert = require('node:assert');
const commands = require('../src/commands');

// db mock: EMPLEADOS.where('ROL','==','CHOFER').get().
function dbMock(choferes, { fallar = false } = {}) {
  return {
    collection() {
      return {
        where() {
          return {
            async get() {
              if (fallar) throw new Error('firestore caído (test)');
              return { docs: choferes.map((c) => ({ id: c.id, data: () => c.data })) };
            },
          };
        },
      };
    },
  };
}

const TEL = '5492915115568';
const EMPS = [
  { id: '30111222', data: { NOMBRE: 'JUAN', ROL: 'CHOFER', ACTIVO: true, TELEFONO: TEL } },
];

describe('commands._resolverChoferPorTelefono', () => {
  test('match estricto por teléfono → resuelve al chofer correcto', async () => {
    const r = await commands._resolverChoferPorTelefono(dbMock(EMPS), TEL);
    assert.ok(r);
    assert.strictEqual(r.dni, '30111222');
    assert.strictEqual(r.nombre, 'JUAN');
  });

  test('teléfono que NO matchea → null (no atiende a desconocidos)', async () => {
    const r = await commands._resolverChoferPorTelefono(dbMock(EMPS), '5491198765432');
    assert.strictEqual(r, null);
  });

  test('chofer inactivo (ACTIVO=false) → null', async () => {
    const inact = [{ id: '1', data: { NOMBRE: 'X', ROL: 'CHOFER', ACTIVO: false, TELEFONO: TEL } }];
    const r = await commands._resolverChoferPorTelefono(dbMock(inact), TEL);
    assert.strictEqual(r, null);
  });

  test('teléfono muy corto → no matchea (null)', async () => {
    const r = await commands._resolverChoferPorTelefono(dbMock(EMPS), '12345');
    assert.strictEqual(r, null);
  });

  test('fail-safe: si EMPLEADOS no se puede leer → null (no resuelve a nadie)', async () => {
    const r = await commands._resolverChoferPorTelefono(dbMock(EMPS, { fallar: true }), TEL);
    assert.strictEqual(r, null);
  });
});
