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
const { _buscarEmpleadoEn, _buscarPorPushname } = require('../src/message_handler');

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

// ─── Fallback por PUSHNAME (chats @lid sin teléfono real) ───
// Casi todos los choferes mandan desde @lid: WhatsApp ya no entrega su teléfono
// real, así que el match por teléfono falla y el resolver cae a identificar por
// el nombre de WhatsApp. Confirmado 2026-06-03: el agente solo respondía a
// admins porque ningún chofer/supervisor @lid resolvía por teléfono.
const empPN = (dni, nombre, apodo, activo = true) => ({
  dni,
  data: { NOMBRE: nombre, APODO: apodo, ACTIVO: activo },
});

describe('_buscarPorPushname — fallback por nombre de WhatsApp (@lid)', () => {
  const roster = [
    empPN('1', 'BASTIAS HORACIO RENE', ''),
    empPN('2', 'PEREZ JUAN CARLOS', 'PIPI'),
    empPN('3', 'GOMEZ MARIA', ''),
  ];

  test('NOMBRE contiene todos los tokens del pushname → matchea', () => {
    const r = _buscarPorPushname('Bastias Horacio', roster);
    assert.ok(r);
    assert.strictEqual(r.dni, '1');
  });

  test('APODO exacto (case-insensitive) → matchea', () => {
    const r = _buscarPorPushname('pipi', roster);
    assert.ok(r);
    assert.strictEqual(r.dni, '2');
  });

  test('un solo token (sin apodo) → null (evita falsos positivos)', () => {
    assert.strictEqual(_buscarPorPushname('Horacio', roster), null);
  });

  test('pushname que matchea 2 empleados → null (ambiguo)', () => {
    const dup = [empPN('1', 'PEREZ JUAN', ''), empPN('2', 'PEREZ JUANA', '')];
    assert.strictEqual(_buscarPorPushname('Perez Juan', dup), null);
  });

  test('empleado ACTIVO=false no matchea', () => {
    const inactivo = [empPN('1', 'BASTIAS HORACIO RENE', '', false)];
    assert.strictEqual(_buscarPorPushname('Bastias Horacio', inactivo), null);
  });

  test('pushname vacío / muy corto / lista nula → null', () => {
    assert.strictEqual(_buscarPorPushname('', roster), null);
    assert.strictEqual(_buscarPorPushname('ab', roster), null);
    assert.strictEqual(_buscarPorPushname('Bastias Horacio', null), null);
  });
});
