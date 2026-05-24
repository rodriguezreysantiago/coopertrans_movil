// =============================================================================
// CANALES PAUSADOS — espejo Node del helper que vive en
// functions/src/canales_pausados.ts.
// =============================================================================
//
// Lee el doc META/canales_pausados con cache 5 min. Sirve para que los
// crons del bot (serviceDiario, vencimientosProximosConsolidado) y la
// alerta de cola creciente puedan preguntar "¿está pausada la categoría
// X?" antes de encolar.
//
// Diseño defensivo: cualquier falla → "no hay pausa" (devuelve false).
// Preferimos enviar de más a silenciar un mensaje crítico por un fallo
// de red.

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

async function _cargar() {
  if (_cache && Date.now() < _cacheExpiraMs) return _cache;
  try {
    const snap = await _getDb()
      .collection('META')
      .doc('canales_pausados')
      .get();
    _cache = snap.exists ? (snap.data() || {}) : {};
    _cacheExpiraMs = Date.now() + TTL_MS;
    return _cache;
  } catch (_e) {
    return _cache || {};
  }
}

/**
 * Devuelve `true` si el canal `key` está pausado (no vencido).
 * Úsalo al inicio de un cron:
 *
 *     if (await estaCanalPausado('serviceDiario')) return;
 */
async function estaCanalPausado(key) {
  const map = await _cargar();
  const raw = map[key];
  if (!raw || typeof raw !== 'object') return false;
  const hasta = raw.hasta_iso;
  if (typeof hasta === 'string' && hasta.length > 0) {
    const ms = Date.parse(hasta);
    if (Number.isFinite(ms) && Date.now() >= ms) return false;
  }
  return true;
}

function invalidarCache() {
  _cache = null;
  _cacheExpiraMs = 0;
}

module.exports = {
  estaCanalPausado,
  invalidarCache,
};
