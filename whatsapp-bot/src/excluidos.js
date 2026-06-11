// =============================================================================
// EXCLUIDOS — choferes/vehículos/usuarios que NO controla Coopertrans Móvil
// =============================================================================
//
// **Paralelo JS del helper TS** `functions/src/excluidos.ts`. Misma
// lógica, mismas constantes. Si tocás uno, tocá el otro. Razón de
// tener dos archivos en vez de un módulo compartido: el bot corre en
// PC dedicada con Node.js plano, sin paquete compartido publicado.
//
// Ver el header del archivo TS para el caso de negocio completo.
//
// Resumen:
// (A) 3 choferes asignados a 3 enganches TANQUE (combustibles
//     líquidos) — pertenecen a otra área de Vecchi que no controlamos.
//     Detectados dinámicamente: VEHICULOS where TIPO='TANQUE' →
//     EMPLEADOS where ENGANCHE in patentesTanque → dnis + tractores.
// (B) Usuarios tester (Apple Reviewer, Android tester) creados para
//     review de Play/TestFlight. Empleados reales preguntaban "quién
//     es éste?" en los listados. Detectados por NOMBRE matching
//     `/\b(reviewer|tester|demo)\b/i`.
//
// El bot usa este helper en los 4 crons que iteran EMPLEADOS o
// VEHICULOS para encolar avisos: vencimientos individuales, service
// diario Volvo, mantenimiento diario Volvo y vencimientos próximos
// (Giagante). Sin este filtro, el bot mandaría WhatsApp a los 3
// choferes tanqueros (que no son nuestros) y a los testers (que ni
// siquiera tienen WhatsApp real cargado).

const log = require('./logger');

/**
 * @typedef {Object} SetExcluidos
 * @property {Set<string>} dnis - DNIs excluidos
 * @property {Set<string>} patentes - Patentes excluidas (UPPERCASE)
 */

/** @type {SetExcluidos} */
const EXCLUIDOS_VACIO = Object.freeze({
  dnis: new Set(),
  patentes: new Set(),
});

// Cache in-memory. TTL 10 min — alta/baja de chofer o tanque es manual
// y un delay de propagación de hasta 10 min es tolerable.
/** @type {SetExcluidos | null} */
let _cacheData = null;
let _cacheExpiraEn = 0;
const TTL_MS = 10 * 60 * 1000;

/**
 * Regex para detectar usuarios tester por NOMBRE. Word boundary evita
 * falsos positivos ("Demolición", "Restful" NO matchean). Case-
 * insensitive: matchea "REVIEWER", "Reviewer", "reviewer", etc.
 */
const PATTERN_TESTER = /\b(reviewer|tester|demo)\b/i;

/**
 * Devuelve los DNIs y patentes que deben EXCLUIRSE de todo proceso
 * del bot (vencimientos, service, mantenimiento, etc.). Cacheado 10 min.
 *
 * Fail-safe: si Firestore falla, devuelve set vacío (mejor incluir a
 * alguien indebido por 1 ciclo que romper todo el cron) y loguea WARN.
 *
 * **Llamar UNA vez al inicio de cada cron** y reutilizar el resultado
 * — NO llamar dentro del loop de empleados (innecesario).
 *
 * @param {FirebaseFirestore.Firestore} db
 * @returns {Promise<SetExcluidos>}
 */
async function cargarExcluidos(db) {
  if (_cacheData && Date.now() < _cacheExpiraEn) {
    return _cacheData;
  }

  try {
    // ─── 1. Patentes de enganches TANQUE ──────────────────────────
    const tanquesSnap = await db
      .collection('VEHICULOS')
      .where('TIPO', '==', 'TANQUE')
      .limit(100)
      .get();
    if (tanquesSnap.size >= 100) {
      log.warn('[excluidos] VEHICULOS TANQUE alcanzó el cap de 100; revisar (P3.1).');
    }
    const patentesTanque = new Set();
    for (const d of tanquesSnap.docs) {
      patentesTanque.add(d.id.toUpperCase());
    }

    // ─── 2. Iterar EMPLEADOS — testers + choferes tanque ──────────
    // SIN filtro de rol (Apple Reviewer es ADMIN). Costo trivial.
    const empSnap = await db.collection('EMPLEADOS').limit(1000).get();
    if (empSnap.size >= 1000) {
      // Cap alcanzado: hay empleados sin evaluar contra exclusiones → un
      // tanquero/tester fuera del corte podría recibir avisos (fail-open, P3.1).
      // Hoy Vecchi está lejos del cap, pero avisamos para no fallar en silencio.
      log.warn('[excluidos] EMPLEADOS alcanzó el cap de 1000; algunos no se ' +
        'evaluaron contra exclusiones. Paginar o subir el límite.');
    }
    const dnis = new Set();
    const tractoresExcluidos = new Set();
    let testersDetectados = 0;
    let tanquerosDetectados = 0;
    for (const d of empSnap.docs) {
      const data = d.data();
      if (data.ACTIVO === false) continue;

      // (a) Testers por NOMBRE — independiente de rol/vehículo
      const nombre = String(data.NOMBRE || '');
      if (PATTERN_TESTER.test(nombre)) {
        dnis.add(d.id);
        testersDetectados++;
        // Un tester demo no tiene tractor real que excluir
        continue;
      }

      // (b) Choferes con ENGANCHE TANQUE (solo si hay tanques cargados)
      if (patentesTanque.size === 0) continue;
      const enganche = String(data.ENGANCHE || '').trim().toUpperCase();
      if (!enganche || !patentesTanque.has(enganche)) continue;
      dnis.add(d.id);
      tanquerosDetectados++;
      // Su tractor también queda excluido
      const tractor = String(data.VEHICULO || '').trim().toUpperCase();
      if (tractor && tractor !== '-') {
        tractoresExcluidos.add(tractor);
      }
    }

    // ─── 3. Combinar patentes (tanques + tractores) ───────────────
    const patentes = new Set([...patentesTanque, ...tractoresExcluidos]);

    _cacheData = { dnis, patentes };
    _cacheExpiraEn = Date.now() + TTL_MS;

    log.info(
      `[excluidos] cache actualizado: tanques=${patentesTanque.size} ` +
        `tanqueros=${tanquerosDetectados} testers=${testersDetectados} ` +
        `tractoresExcluidos=${tractoresExcluidos.size} ` +
        `totalDnis=${dnis.size} totalPatentes=${patentes.size}`,
    );
    return _cacheData;
  } catch (e) {
    log.warn(`[excluidos] query fallo, devuelve vacio: ${e.message}`);
    return EXCLUIDOS_VACIO;
  }
}

/**
 * Helper: ¿este DNI o patente está excluido? Normaliza patente a
 * uppercase. DNIs se comparan literal.
 *
 * @param {SetExcluidos} excluidos
 * @param {{dni?: string, patente?: string}} opts
 * @returns {boolean}
 */
function esExcluido(excluidos, opts = {}) {
  if (opts.dni && excluidos.dnis.has(opts.dni)) return true;
  if (opts.patente) {
    const norm = String(opts.patente).trim().toUpperCase();
    if (norm && excluidos.patentes.has(norm)) return true;
  }
  return false;
}

/** Solo para tests: invalida el cache. NO usar en producción. */
function _resetCacheExcluidosParaTests() {
  _cacheData = null;
  _cacheExpiraEn = 0;
}

module.exports = {
  cargarExcluidos,
  esExcluido,
  _resetCacheExcluidosParaTests,
};
