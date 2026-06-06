// Fix 1 (auditoría 2026-06-06): el cerrojo por CONTENIDO (esTextoPropio /
// _marcarTextoPropio) está acotado a salientes con la firma "Bot-On".
//
// El bug: antes, TODO saliente de ≥12 chars se marcaba 90s y CUALQUIER entrante
// con el mismo texto se descartaba como "reflejo propio". Si un chofer copiaba
// una frase fija del bot ("No tenés unidad asignada.", etc.) su mensaje se
// perdía sin acuse. El motivo real de esta capa es el reflejo corrupto de la
// sesión recién vinculada de los AVISOS (vigilador/sitrack), y esos avisos
// SIEMPRE llevan "Bot-On" → restringir la capa a textos firmados mata el falso
// positivo sin abrir hueco (los salientes sin firma ya los atrapa el id).

const { test, describe, beforeEach } = require('node:test');
const assert = require('node:assert');
const wa = require('../src/whatsapp');

const FIRMA = '\n_Bot-On — Coopertrans Móvil_';

describe('whatsapp.esTextoPropio — cerrojo por contenido acotado a firma Bot-On', () => {
  beforeEach(() => wa._resetTextosPropiosParaTests());

  test('aviso FIRMADO marcado → su reflejo (mismo body) se descarta', () => {
    const aviso = 'Te recuerdo que tu licencia vence en 5 días.' + FIRMA;
    wa._marcarTextoPropio(aviso);
    // El reflejo de message_create llega con el MISMO body → debe matchear.
    assert.strictEqual(wa.esTextoPropio(aviso), true);
  });

  test('FOOTGUN: entrante que copia una frase FIJA SIN firma NO se traga', () => {
    // El bot mandó esta frase (acuse/respuesta del agente, sin firma). Aunque
    // se "marque", al no llevar Bot-On el cerrojo por contenido la ignora.
    const fraseDelBot = 'No tenés unidad asignada.';
    wa._marcarTextoPropio(fraseDelBot);
    // El chofer la copia/responde: su mensaje NO debe descartarse por contenido.
    assert.strictEqual(wa.esTextoPropio(fraseDelBot), false);
  });

  test('texto SIN firma no entra al cerrojo aunque sea largo', () => {
    const largo = 'Listo, ya quedó registrado tu adelanto de la semana pasada.';
    wa._marcarTextoPropio(largo);
    assert.strictEqual(wa.esTextoPropio(largo), false);
  });

  test('un entrante CUALQUIERA sin firma siempre da false', () => {
    assert.strictEqual(wa.esTextoPropio('hola, todo bien?'), false);
    assert.strictEqual(wa.esTextoPropio('No tenés unidad asignada.'), false);
  });

  test('firma + texto muy corto: no rompe (defensivo, no marca)', () => {
    // La firma sola sin cuerpo no debería poder usarse para tragar entrantes
    // cortos; igual el guard de longitud (<12 del texto normalizado) la cubre.
    wa._marcarTextoPropio('Hola.' + FIRMA); // sí lleva firma y es largo por la firma
    // Coincidencia exacta del mismo saliente firmado: matchea (es su reflejo).
    assert.strictEqual(wa.esTextoPropio('Hola.' + FIRMA), true);
    // Pero el "Hola." pelado del chofer (sin firma) no se descarta.
    assert.strictEqual(wa.esTextoPropio('Hola.'), false);
  });
});
