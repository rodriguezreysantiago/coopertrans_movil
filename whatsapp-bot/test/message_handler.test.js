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
const { _buscarEmpleadoEn, _buscarPorLid } = require('../src/message_handler');

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

// ─── Match por WA_LID memorizado (chats @lid sin teléfono real) ───
// Casi todos los choferes mandan desde @lid: WhatsApp ya no entrega su teléfono.
// La 1ª vez que el bot los reconoce por teléfono (estando agendados) memoriza su
// "linked id" (WA_LID); de ahí en más los reconoce EXACTO por ese lid. Igualdad
// estricta — sin heurísticas de nombre (el match por pushname se descartó por
// inseguro 2026-06-03: podía confundir dos personas y filtrar datos sensibles).
const empLid = (dni, waLid) => ({ dni, data: { WA_LID: waLid } });

describe('_buscarPorLid — match exacto por WA_LID memorizado (@lid)', () => {
  const roster = [
    empLid('1', '259463437111345'),
    empLid('2', '188900112233445'),
    { dni: '3', data: {} }, // sin WA_LID aprendido todavía
  ];

  test('lid memorizado → matchea exacto', () => {
    const r = _buscarPorLid('259463437111345', roster);
    assert.ok(r);
    assert.strictEqual(r.dni, '1');
  });

  test('lid con caracteres no-dígito se normaliza igual', () => {
    const r = _buscarPorLid('259463437111345@lid', roster);
    assert.ok(r);
    assert.strictEqual(r.dni, '1');
  });

  test('lid desconocido → null (no adivina)', () => {
    assert.strictEqual(_buscarPorLid('999999999999999', roster), null);
  });

  test('empleado sin WA_LID nunca matchea', () => {
    assert.strictEqual(_buscarPorLid('', roster), null);
    // un lid vacío no debe colapsar contra el empleado sin WA_LID (dni 3)
    assert.strictEqual(_buscarPorLid('   ', roster), null);
  });

  test('inputs nulos → null', () => {
    assert.strictEqual(_buscarPorLid(null, roster), null);
    assert.strictEqual(_buscarPorLid('259463437111345', null), null);
  });
});
