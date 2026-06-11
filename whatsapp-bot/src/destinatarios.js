// =============================================================================
// DESTINATARIOS DE NOTIFICACIÓN — override desde Firestore
// =============================================================================
//
// Espejo en Node.js del helper que vive en functions/src/comun.ts. Lee el
// doc META/destinatarios_notificacion con cache 5 min y devuelve el DNI
// override para una key dada, o el fallback (típicamente una env var)
// si no hay override válido.
//
// El doc lo edita el admin desde la pantalla "Destinatarios de
// notificación" en la app. Cambiar el destinatario NO requiere reiniciar
// el bot: el cache TTL 5 min hace que el próximo cron tome el valor
// nuevo sin downtime.
//
// Si Firestore falla / el doc no existe / la key no tiene override,
// devuelve el fallback. Esto significa que un Firestore caído no rompe
// el bot — solo seguimos usando los valores históricos del .env.

const admin = require('firebase-admin');

let _db = null;
let _cache = null;
let _cacheExpiraMs = 0;
const TTL_MS = 5 * 60 * 1000;

function _getDb() {
  if (_db) return _db;
  _db = admin.firestore();
  return _db;
}

/**
 * Lee el doc META/destinatarios_notificacion con cache 5 min.
 * Devuelve un map plano { key: dni }. Si la lectura falla, devuelve
 * el cache vencido (si existe) o un map vacío — los callers ya tienen
 * fallback al env var, así que Firestore caído no rompe nada.
 */
async function _cargar() {
  if (_cache && Date.now() < _cacheExpiraMs) return _cache;
  try {
    const snap = await _getDb()
      .collection('META')
      .doc('destinatarios_notificacion')
      .get();
    if (snap.exists) {
      _cache = snap.data() || {};
      _cacheExpiraMs = Date.now() + TTL_MS;
      return _cache;
    }
    // Doc no existe — cacheamos vacío para no leer Firestore en cada
    // llamada subsiguiente durante 5 min.
    _cache = {};
    _cacheExpiraMs = Date.now() + TTL_MS;
    return _cache;
  } catch (e) {
    // Fallback al cache viejo (aun vencido) o map vacío.
    return _cache || {};
  }
}

/**
 * Devuelve el DNI para `key` desde Firestore, o `fallback` si no hay
 * override válido. `fallback` típicamente es una env var (ej.
 * `process.env.SERVICE_DESTINATARIO_DNI`) o un string hardcoded.
 *
 * Keys conocidas:
 *   - serviceDiario, vencimientosProximosConsolidado (bot crons)
 *   - mantenimientoBot, driftsAsignaciones, parteMantenimientoVolvo,
 *     excesosJornada, conductaManejo, bypassSeguridad (CFs)
 *   - cachatoreEncargado (cachatore Python)
 *   - colaCreciente (bot health alert)
 */
async function obtenerDestinatario(key, fallback) {
  const map = await _cargar();
  const v = map[key];
  if (typeof v === 'string' && v.trim().length > 0) return v.trim();
  return fallback;
}

/** Invalida el cache. Útil para tests. */
function invalidarCache() {
  _cache = null;
  _cacheExpiraMs = 0;
}

/** Solo para tests: inyecta un db mock (evita admin.firestore() real). */
function _setDbParaTests(db) {
  _db = db;
}

module.exports = {
  obtenerDestinatario,
  invalidarCache,
  _setDbParaTests,
};
