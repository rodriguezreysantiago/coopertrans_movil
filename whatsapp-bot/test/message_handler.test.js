// Tests para _buscarEmpleadoEn (resolución de empleado por teléfono).
//
// Es el path que usa el AGENTE para identificar a supervisores/admins por su
// teléfono (vía _resolverPersonaAgente). El matching tiene que:
//   - reconciliar el "9" móvil AR: WhatsApp entrega el ID SIN el 9
//     (542915115568) pero los TELEFONOS suelen estar cargados CON el 9
//     (5492915115568) — sin esto el agente no respondía a supervisores.
//   - PERO el match EXACTO tiene que ganar SIEMPRE sobre el laxo, sin importar
//     el orden de iteración (fix B3): si dos números colapsan al mismo canónico
//     AR, manda el dueño exacto del número entrante.
process.env.TZ = 'America/Argentina/Buenos_Aires';

const { test, describe } = require('node:test');
const assert = require('node:assert');
const { _buscarEmpleadoEn } = require('../src/message_handler');

const emp = (dni, telefono, nombre) => ({
  dni,
  data: { TELEFONO: telefono, NOMBRE: nombre },
});

describe('_buscarEmpleadoEn — matching de teléfono', () => {
  test('canónico AR: ID sin-9 encuentra TELEFONO con-9 (fix supervisores)', () => {
    const lista = [emp('1', '5492915115568', 'ERRAZU')];
    const r = _buscarEmpleadoEn('542915115568', lista); // como llega de WhatsApp
    assert.ok(r);
    assert.strictEqual(r.dni, '1');
  });

  test('REGRESSION B3: el match EXACTO gana al laxo aunque el laxo esté primero', () => {
    // El de dni '5' está cargado con-9 → colapsa al mismo canónico que el
    // entrante (sin-9). El de dni '9' tiene el número EXACTO que entra. Aunque
    // el laxo se itere primero, tiene que ganar el exacto (antes ganaba el
    // primero iterado → identificaba a la persona equivocada).
    const lista = [
      emp('5', '5492915115568', 'COLISION_CANONICA'),
      emp('9', '542915115568', 'DUENO_EXACTO'),
    ];
    const r = _buscarEmpleadoEn('542915115568', lista);
    assert.ok(r);
    assert.strictEqual(r.dni, '9'); // el exacto, no el de canónico colisionante
  });

  test('número que no pertenece a nadie → null', () => {
    const lista = [emp('1', '5492915115568', 'ERRAZU')];
    assert.strictEqual(_buscarEmpleadoEn('5491100000000', lista), null);
  });

  test('inputs vacíos / lista vacía → null', () => {
    assert.strictEqual(_buscarEmpleadoEn('', [emp('1', '5492915115568', 'X')]), null);
    assert.strictEqual(_buscarEmpleadoEn('5492915115568', []), null);
    assert.strictEqual(_buscarEmpleadoEn(null, null), null);
  });
});
