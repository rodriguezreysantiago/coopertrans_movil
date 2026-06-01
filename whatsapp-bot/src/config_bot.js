// =============================================================================
// CONFIG DEL BOT — umbrales operativos ajustables desde Firestore
// (doc META/config_bot), con cache 5 min.
// =============================================================================
//
// Por qué Firestore y no solo el .env: el .env vive SOLO en la PC dedicada,
// así que cambiar un umbral (ej. el tope de mensajes/hora) obligaba a entrar
// por RDP a editarlo. Con esto se ajusta desde la nube (o desde la app a
// futuro) sin tocar la dedicada. Mismo patrón que destinatarios.js /
// canales_pausados.js.
//
// Orden de prioridad de cada valor: Firestore → .env → default hardcodeado.
// Diseño defensivo: cualquier falla de lectura → cae al .env/default.

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
    const snap = await _getDb().collection('META').doc('config_bot').get();
    _cache = snap.exists ? (snap.data() || {}) : {};
    _cacheExpiraMs = Date.now() + TTL_MS;
    return _cache;
  } catch (_e) {
    return _cache || {};
  }
}

/**
 * Tope de mensajes por hora (anti-baneo de WhatsApp). Prioridad:
 *   1. META/config_bot.max_msgs_hora (Firestore, ajustable sin RDP)
 *   2. process.env.MAX_MESSAGES_PER_HOUR (.env de la dedicada)
 *   3. 30 (default)
 * Acotado a 1..60: subir mucho dispara baneo de WhatsApp (>40/h es zona roja).
 */
async function maxMensajesPorHora() {
  const fbEnv = parseInt(process.env.MAX_MESSAGES_PER_HOUR || '30', 10);
  const fallback = Number.isFinite(fbEnv) && fbEnv > 0 ? fbEnv : 30;
  const map = await _cargar();
  const raw = map.max_msgs_hora;
  const n = typeof raw === 'number' ? raw : parseInt(raw, 10);
  if (Number.isFinite(n) && n >= 1 && n <= 60) return n;
  return fallback;
}

function invalidarCache() {
  _cache = null;
  _cacheExpiraMs = 0;
}

module.exports = { maxMensajesPorHora, invalidarCache };
