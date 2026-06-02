// Tests para humano.js → normalizarTelefonoAWid.
//
// Esta funcion es CRITICA: la usa cron.js (validacion E.164 antes de
// encolar — fix de 2026-05-03) e index.js (validacion antes de enviar).
// Si se rompe sin tests, el bot intenta enviar a WIDs basura, llena la
// cola de errores y arriesga el baneo del numero. Los tests cubren los
// casos reales que vamos a encontrar en la base de TELEFONOs de
// EMPLEADOS.
process.env.TZ = 'America/Argentina/Buenos_Aires';

const { test, describe } = require('node:test');
const assert = require('node:assert');
const {
  normalizarTelefonoAWid,
  partirMensajeLargo,
  telefonoCanonicalAr,
} = require('../src/humano');

describe('telefonoCanonicalAr — reconcilia el "9" movil AR para comparar', () => {
  test('con-9 y sin-9 del MISMO numero convergen (el bug del agente)', () => {
    assert.strictEqual(
      telefonoCanonicalAr('5492915115568'),
      telefonoCanonicalAr('542915115568')
    );
  });
  test('quita el 9 movil tras el 54', () => {
    assert.strictEqual(telefonoCanonicalAr('5492915115568'), '542915115568');
  });
  test('numero sin el 9 queda igual', () => {
    assert.strictEqual(telefonoCanonicalAr('542915115568'), '542915115568');
  });
  test('limpia separadores antes de canonizar', () => {
    assert.strictEqual(
      telefonoCanonicalAr('+54 9 2915 11-5568'),
      '542915115568'
    );
  });
  test('vacio / null → string vacio', () => {
    assert.strictEqual(telefonoCanonicalAr(''), '');
    assert.strictEqual(telefonoCanonicalAr(null), '');
  });
});

describe('normalizarTelefonoAWid — formatos validos', () => {
  test('numero AR tipico con +549 movil y espacios → wid limpio', () => {
    // +549... es el formato WhatsApp para moviles AR (el 9 es el
    // prefijo de movil que reemplaza al 15 historico).
    assert.strictEqual(
      normalizarTelefonoAWid('+54 9 291 456-7890'),
      '5492914567890@c.us'
    );
  });

  test('numero AR sin el 9 movil (12 digitos): tambien se acepta', () => {
    // Algunos admin cargan sin el 9 (formato landline). El bot lo
    // acepta — en runtime WhatsApp puede o no enrutarlo, pero la
    // validacion sintactica pasa.
    assert.strictEqual(
      normalizarTelefonoAWid('+54 291 456-7890'),
      '542914567890@c.us'
    );
  });

  test('numero AR sin +, sin espacios → wid igual', () => {
    assert.strictEqual(
      normalizarTelefonoAWid('5492914567890'),
      '5492914567890@c.us'
    );
  });

  test('numero AR con guiones y parentesis', () => {
    assert.strictEqual(
      normalizarTelefonoAWid('(0291) 456-7890'),
      '02914567890@c.us'
    );
  });

  test('numero corto valido (10 digitos = limite inferior)', () => {
    assert.strictEqual(
      normalizarTelefonoAWid('1234567890'),
      '1234567890@c.us'
    );
  });

  test('numero largo valido (15 digitos = limite superior E.164)', () => {
    assert.strictEqual(
      normalizarTelefonoAWid('123456789012345'),
      '123456789012345@c.us'
    );
  });

  test('acepta number tipo (no string) por coercion', () => {
    assert.strictEqual(
      normalizarTelefonoAWid(5492914567890),
      '5492914567890@c.us'
    );
  });
});

describe('normalizarTelefonoAWid — formatos invalidos', () => {
  test('null devuelve null', () => {
    assert.strictEqual(normalizarTelefonoAWid(null), null);
  });

  test('undefined devuelve null', () => {
    assert.strictEqual(normalizarTelefonoAWid(undefined), null);
  });

  test('string vacio devuelve null', () => {
    assert.strictEqual(normalizarTelefonoAWid(''), null);
  });

  test('string puro de espacios devuelve null', () => {
    assert.strictEqual(normalizarTelefonoAWid('   '), null);
  });

  test('texto sin numeros devuelve null', () => {
    assert.strictEqual(normalizarTelefonoAWid('abc'), null);
  });

  test('menos de 10 digitos devuelve null (typo del admin)', () => {
    assert.strictEqual(normalizarTelefonoAWid('12345'), null);
    assert.strictEqual(normalizarTelefonoAWid('123456789'), null); // 9 digitos
  });

  test('mas de 15 digitos devuelve null (no es E.164 valido)', () => {
    assert.strictEqual(normalizarTelefonoAWid('1234567890123456'), null); // 16 digitos
  });

  test('mezcla de letras y digitos: cuenta solo digitos', () => {
    // "abc123" → "123" → 3 digitos → invalido.
    assert.strictEqual(normalizarTelefonoAWid('abc123'), null);
  });

  test('REGRESSION: typo tipico admin (telefono cargado como nombre)', () => {
    // Casos reales que el agente espera ver al revisar EMPLEADOS:
    assert.strictEqual(normalizarTelefonoAWid('PEREZ JUAN'), null);
    assert.strictEqual(normalizarTelefonoAWid('-'), null);
    assert.strictEqual(normalizarTelefonoAWid('SIN TELEFONO'), null);
  });
});

describe('normalizarTelefonoAWid — proteccion contra inputs raros', () => {
  test('object devuelve null por toString basura', () => {
    // String({}) → "[object Object]" → 0 digitos → null.
    assert.strictEqual(normalizarTelefonoAWid({}), null);
  });

  test('array de un numero: extrae solo digitos', () => {
    // String([5492914567890]) → "5492914567890" → 13 digitos → valido.
    // Comportamiento esperado: lo aceptamos porque el dato esta ahi.
    // Es defensivo: si Firestore devuelve un array por error, no rompemos.
    assert.strictEqual(
      normalizarTelefonoAWid([5492914567890]),
      '5492914567890@c.us'
    );
  });
});

// ============================================================================
// partirMensajeLargo — splitting anti-baneo
// ============================================================================
// Crítico: si esto se rompe, los resúmenes muy largos de Alejandra (Volvo
// HIGH con 4 tipos forzados sumados hoy) pueden pasar 4096 chars y
// disparar baneo de WhatsApp. Tests cubren los casos modales: cabe en
// uno, parte en varios, bloque solo > maxChars (split duro), input vacío.

describe('partirMensajeLargo — casos típicos', () => {
  test('texto corto cabe en una sola parte (sin marcador)', () => {
    const partes = partirMensajeLargo('Hola, este es un mensaje corto.');
    assert.strictEqual(partes.length, 1);
    assert.strictEqual(partes[0], 'Hola, este es un mensaje corto.');
    // Sin marcador "(parte 1/1)" cuando es uno solo.
    assert.doesNotMatch(partes[0], /\(parte/);
  });

  test('texto vacío devuelve un array de 1 string vacío', () => {
    const partes = partirMensajeLargo('');
    assert.strictEqual(partes.length, 1);
    assert.strictEqual(partes[0], '');
  });

  test('null/undefined no rompe (defensivo)', () => {
    assert.deepStrictEqual(partirMensajeLargo(null), ['']);
    assert.deepStrictEqual(partirMensajeLargo(undefined), ['']);
  });

  test('texto largo se parte por bloques (\n\n) preservando formato', () => {
    // Construir un texto > 100 chars con bloques separados.
    const bloque = 'Esto es un bloque de aproximadamente 50 caracteres aaa';
    const texto = [bloque, bloque, bloque, bloque, bloque].join('\n\n');
    // Forzar maxChars chico para que parta sí o sí.
    const partes = partirMensajeLargo(texto, 100);
    assert.ok(partes.length >= 2, 'debe partirse en al menos 2');
    // Cada parte tiene marcador (parte i/N).
    partes.forEach((p, i) => {
      assert.match(p, new RegExp(`\(parte ${i + 1}/${partes.length}\)`));
    });
    // Re-ensamblar: sin los marcadores, los bloques siguen ahí.
    const reconstruido = partes
      .map((p) => p.replace(/^\(parte \d+\/\d+\)\n/, ''))
      .join('\n\n');
    assert.match(reconstruido, /Esto es un bloque/);
  });

  test('bloque único > maxChars se parte con split duro', () => {
    const texto = 'A'.repeat(500);
    const partes = partirMensajeLargo(texto, 100);
    assert.ok(partes.length >= 5, 'debe partir un bloque solo grande');
    // Cada parte tiene marcador y respeta el cap.
    partes.forEach((p) => {
      const sinMarcador = p.replace(/^\(parte \d+\/\d+\)\n/, '');
      assert.ok(
        sinMarcador.length <= 100,
        `parte excede maxChars: ${sinMarcador.length}`
      );
    });
  });

  test('texto exactamente en maxChars NO se parte', () => {
    const texto = 'X'.repeat(100);
    const partes = partirMensajeLargo(texto, 100);
    assert.strictEqual(partes.length, 1);
    assert.doesNotMatch(partes[0], /\(parte/);
  });

  test('default maxChars es 3500 (no parte resúmenes razonables)', () => {
    const texto = 'X'.repeat(3000);
    const partes = partirMensajeLargo(texto);
    assert.strictEqual(partes.length, 1);
  });
});
