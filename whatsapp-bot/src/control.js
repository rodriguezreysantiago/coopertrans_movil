// Lectura del flag de pausa del bot.
//
// La pantalla "Estado del Bot" del admin tiene un toggle Pausar/Reanudar
// que escribe a `BOT_CONTROL/main.pausado: true|false`. El bot consulta
// ese flag antes de procesar cada item de la cola — si está pausado,
// salta y deja el doc en PENDIENTE para reintentarlo cuando se reanude.
//
// Performance: cacheamos el valor en memoria con TTL corto (default 10s)
// para no leer Firestore en cada item de la cola. La latencia para que
// un cambio del admin se refleje es <= TTL + intervalo de polling.
//
// Diseño:
//   - Si el doc no existe → asumimos NO pausado (default seguro:
//     "el bot funciona si nadie lo pausó").
//   - Si la lectura falla (Firestore caído, timeout) → asumimos NO
//     pausado y logueamos warning. Mejor un envío de más durante un
//     outage que dejar la cola muerta.

const log = require('./logger');

let _db = null;
let _cache = { pausado: false, motivo: null, leidoEn: 0 };

function _ttlMs() {
  // TTL bajado de 10s a 2s para que pausas/reanudaciones rápidas del
  // admin se reflejen casi al instante sin overhead notable de reads
  // (con polling cada 15s y ~30 mensajes/hora, un read cada 2s significa
  // ~3-5 reads/min máximo — despreciable).
  return parseInt(process.env.BOT_CONTROL_CACHE_TTL_MS || '2000', 10);
}

/**
 * Inicializar con la instancia de Firestore. Hay que llamarlo una vez
 * antes de usar `estaPausado()`.
 */
function inicializar(db) {
  _db = db;
}

/**
 * Devuelve true si el bot está pausado por el admin desde la app.
 * Cachea durante BOT_CONTROL_CACHE_TTL_MS para no martillar Firestore.
 */
async function estaPausado() {
  if (!_db) return false;
  const ahora = Date.now();
  if (ahora - _cache.leidoEn < _ttlMs()) {
    return _cache.pausado;
  }
  try {
    const snap = await _db.collection('BOT_CONTROL').doc('main').get();
    const data = snap.exists ? snap.data() || {} : {};
    let pausado = data.pausado === true;
    const motivo = data.motivo || null;
    // Auto-reanudación si vencio el `pausado_hasta` (set por /pausar Nh).
    // Si admin hizo `/pausar 24h` el comando guardo `pausado_hasta = now+24h`.
    // Pasadas las 24h, el bot se reanuda solo y limpia el flag — sin
    // necesidad de que admin acuerde de mandar /reanudar. Antes este
    // chequeo no existia: si admin se olvidaba, el bot quedaba muerto.
    if (
      pausado &&
      data.pausado_hasta &&
      typeof data.pausado_hasta.toMillis === 'function' &&
      data.pausado_hasta.toMillis() <= ahora
    ) {
      log.info(
        `Bot AUTO-REANUDADO: vencio "pausado_hasta" (${new Date(data.pausado_hasta.toMillis()).toISOString()}).`
      );
      try {
        await _db.collection('BOT_CONTROL').doc('main').set(
          {
            pausado: false,
            reanudado_en: new Date(),
            pausado_hasta: null,
            motivo: null,
          },
          { merge: true }
        );
      } catch (e) {
        // Si no podemos escribir el flag, igual reanudamos en memoria — el
        // proximo ciclo reintentara. Mejor un envio de mas que dejar la
        // cola muerta.
        log.warn(`No se pudo persistir auto-reanudacion: ${e.message}`);
      }
      pausado = false;
    }
    // Logueamos solo cuando cambia el estado, no en cada lectura.
    if (pausado !== _cache.pausado) {
      if (pausado) {
        log.warn(
          `Bot PAUSADO por admin${motivo ? ` (motivo: "${motivo}")` : ''}.`
        );
      } else {
        log.info('Bot REANUDADO por admin.');
      }
    }
    _cache = { pausado, motivo, leidoEn: ahora };
    return pausado;
  } catch (e) {
    log.warn(`Lectura de BOT_CONTROL/main falló: ${e.message}`);
    // Default seguro: si no podemos leer, asumimos no pausado.
    return false;
  }
}

/**
 * Devuelve los datos crudos del último estado conocido (cacheado).
 * Útil para que el heartbeat los exponga al doc BOT_HEALTH/main sin
 * tener que duplicar otra lectura a Firestore.
 */
function ultimoEstado() {
  return { pausado: _cache.pausado, motivo: _cache.motivo };
}

/**
 * Fuerza el descarte del cache. La próxima llamada a `estaPausado()`
 * va a leer de Firestore de nuevo. Útil después de un cambio
 * intencional (ej: comando admin /pausar que escribe BOT_CONTROL).
 */
function invalidarCache() {
  _cache = { pausado: false, motivo: null, leidoEn: 0 };
}

module.exports = {
  inicializar,
  estaPausado,
  ultimoEstado,
  invalidarCache,
};
