/**
 * Helpers de fecha anti-timezone.
 *
 * El bot trabaja en TZ ART (forzada via process.env.TZ en index.js).
 * Pero las fechas pueden venir de Firestore en varios formatos:
 *
 *   - String YYYY-MM-DD (lo que guarda la app actual).
 *   - String ISO completo "YYYY-MM-DDTHH:MM:SS.sssZ" (data importada).
 *   - Date object (poco comun, pero algun script Python podria).
 *   - Firestore Timestamp (los campos de vencimiento podrian estar
 *     guardados asi si fueron migrados desde un script).
 *
 * Cualquiera de estos puede generar bugs de "1 dia menos" cuando se
 * formatean en TZ ART, porque:
 *
 *   datetime(2026, 5, 30) en Python -> Firestore Timestamp UTC midnight
 *   new Date desde ese Timestamp     -> medianoche UTC = 21h del 29 ART
 *   getDate() en ART                 -> 29 en lugar de 30
 *
 * Estos helpers encapsulan la conversion segura. Para STRINGS ISO
 * tomamos los primeros 10 chars (lo que ve el usuario en la app).
 * Para DATE/TIMESTAMP, distinguimos:
 *
 *   - Si la hora UTC es exactamente medianoche (00:00:00.000), asumimos
 *     que es una "fecha calendario" pura (caso tipico de migraciones
 *     desde Python o JavaScript con `new Date("YYYY-MM-DD")`). Usamos
 *     getUTCDate() para obtener el dia que el usuario ESPERABA guardar.
 *
 *   - Si tiene hora distinta (ej. timestamp de last-modified), es un
 *     momento real -- usamos getDate() local (ya en ART por TZ del
 *     proceso).
 */

/**
 * Normaliza cualquier representacion de fecha a string YYYY-MM-DD.
 *
 * @param {string|Date|object|null} fecha
 * @returns {string|null}
 */
function aIsoLocal(fecha) {
  if (fecha === null || fecha === undefined || fecha === '') return null;

  // String: si empieza con YYYY-MM-DD (con o sin tail), tomamos los
  // primeros 10 chars sin pasar por new Date() (que ahi si shiftearia
  // por UTC). Cubre tanto "2026-05-30" como "2026-05-30T00:00:00.000Z".
  if (typeof fecha === 'string') {
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(fecha.trim());
    if (m) return `${m[1]}-${m[2]}-${m[3]}`;
    const d = new Date(fecha);
    if (!isNaN(d.getTime())) return _dateToIsoSafe(d);
    return null;
  }

  // Firestore Timestamp (admin SDK los expone con .toDate()).
  if (fecha && typeof fecha.toDate === 'function') {
    return _dateToIsoSafe(fecha.toDate());
  }

  // Date instance.
  if (fecha instanceof Date) {
    return _dateToIsoSafe(fecha);
  }

  // Object plano con _seconds / seconds (Timestamp serializado a JSON).
  if (fecha && typeof fecha === 'object') {
    const secs = fecha._seconds ?? fecha.seconds;
    if (typeof secs === 'number') {
      return _dateToIsoSafe(new Date(secs * 1000));
    }
  }

  return null;
}

/**
 * Formatea cualquier representacion de fecha a 'DD/MM/YYYY'.
 * Devuelve '-' si no se pudo parsear.
 */
function aDdMmYyyyLocal(fecha) {
  const iso = aIsoLocal(fecha);
  if (!iso) return '-';
  return `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`;
}

/**
 * Formatea cualquier representacion de fecha a 'DD/MM/YYYY HH:MM' usando
 * componentes LOCALES. A diferencia de `aDdMmYyyyLocal` (que es para
 * fechas calendario), este preserva la HORA -- usalo cuando la
 * granularidad es momento real, no dia.
 *
 * Para timestamps de retries, logs, "ultima actualizacion", etc.
 * Anti-patrón: NO usar `new Date().toISOString()` que devuelve UTC --
 * obliga al admin a restar 3hs en la cabeza.
 *
 * Devuelve '-' si no se pudo parsear.
 */
function aLocalDateTime(fecha) {
  if (fecha === null || fecha === undefined || fecha === '') return '-';

  let d;
  if (fecha instanceof Date) {
    d = fecha;
  } else if (fecha && typeof fecha.toDate === 'function') {
    d = fecha.toDate();
  } else if (typeof fecha === 'string') {
    d = new Date(fecha);
  } else if (fecha && typeof fecha === 'object') {
    const secs = fecha._seconds ?? fecha.seconds;
    if (typeof secs === 'number') d = new Date(secs * 1000);
  }

  if (!(d instanceof Date) || isNaN(d.getTime())) return '-';

  const dd = String(d.getDate()).padStart(2, '0');
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  const yyyy = d.getFullYear();
  const hh = String(d.getHours()).padStart(2, '0');
  const mi = String(d.getMinutes()).padStart(2, '0');
  return `${dd}/${mm}/${yyyy} ${hh}:${mi}`;
}

/**
 * Formatea cualquier representacion de fecha a 'HH:MM' usando
 * componentes LOCALES (TZ forzada en index.js a ART). Devuelve '-' si
 * no se pudo parsear.
 *
 * Para mostrar SOLO la hora — para fecha + hora completa usar
 * `aLocalDateTime`. Reemplaza el patron `_formatHora` privado que vivia
 * duplicado en builders de mensajes.
 */
function aLocalTime(fecha) {
  if (fecha === null || fecha === undefined || fecha === '') return '-';

  let d;
  if (fecha instanceof Date) {
    d = fecha;
  } else if (fecha && typeof fecha.toDate === 'function') {
    d = fecha.toDate();
  } else if (typeof fecha === 'string') {
    d = new Date(fecha);
  } else if (fecha && typeof fecha === 'object') {
    const secs = fecha._seconds ?? fecha.seconds;
    if (typeof secs === 'number') d = new Date(secs * 1000);
  }

  if (!(d instanceof Date) || isNaN(d.getTime())) return '-';

  const hh = String(d.getHours()).padStart(2, '0');
  const mi = String(d.getMinutes()).padStart(2, '0');
  return `${hh}:${mi}`;
}

/**
 * Días entre dos fechas-calendario expresadas como `YYYY-MM-DD` (o ISO con
 * tail). Devuelve `hasta - desde` en días corridos (positivo si `hasta` es
 * posterior; negativo si ya pasó). `null` si alguna no parsea.
 *
 * Misma aritmética que `calcularDiasRestantes` en cron.js: parseo MANUAL de los
 * componentes Y-M-D y `new Date(y, m, d)` (medianoche LOCAL) en ambos extremos,
 * para NO sufrir el shift `new Date("YYYY-MM-DD")` = medianoche UTC = 21h del día
 * anterior en ART. Centraliza ese cálculo para que el agente (agente._diasHasta)
 * y el cron cuenten los días con la MISMA fórmula — antes el agente usaba
 * medianoche UTC y discrepaba ±1 día con el aviso automático.
 *
 * @param {string} isoDesde - YYYY-MM-DD (típicamente hoy en ART).
 * @param {string} isoHasta - YYYY-MM-DD (la fecha de vencimiento).
 * @returns {number|null}
 */
function diasEntreIso(isoDesde, isoHasta) {
  const a = _isoYmdALocalDate(isoDesde);
  const b = _isoYmdALocalDate(isoHasta);
  if (!a || !b) return null;
  return Math.round((b.getTime() - a.getTime()) / 86400000);
}

/**
 * Helper interno: `YYYY-MM-DD` (o ISO con tail) → Date a medianoche LOCAL.
 * Parseo manual de los 3 componentes (NO `new Date(str)`, que interpreta
 * `YYYY-MM-DD` como UTC). Devuelve null si no matchea el patrón.
 */
function _isoYmdALocalDate(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || '').trim());
  if (!m) return null;
  const d = new Date(parseInt(m[1], 10), parseInt(m[2], 10) - 1, parseInt(m[3], 10));
  return isNaN(d.getTime()) ? null : d;
}

/**
 * Helper interno: convierte un Date a YYYY-MM-DD eligiendo entre
 * componentes UTC (cuando es fecha calendario, hora UTC = 00:00:00.000)
 * o componentes locales (cuando es momento real con hora). Ver el
 * comentario al top del modulo para el rationale.
 *
 * Defensivo: si el input no es Date o es Date invalido (NaN), devuelve
 * null. Sin esto, los getters devuelven NaN y el template literal
 * armaba "NaN-NaN-NaN" como si fuera una fecha valida.
 */
function _dateToIsoSafe(d) {
  if (!(d instanceof Date) || isNaN(d.getTime())) return null;
  const esFechaCalendario =
    d.getUTCHours() === 0 &&
    d.getUTCMinutes() === 0 &&
    d.getUTCSeconds() === 0 &&
    d.getUTCMilliseconds() === 0;

  if (esFechaCalendario) {
    const year = d.getUTCFullYear();
    const month = String(d.getUTCMonth() + 1).padStart(2, '0');
    const day = String(d.getUTCDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }
  const year = d.getFullYear();
  const month = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

module.exports = {
  aIsoLocal,
  aDdMmYyyyLocal,
  aLocalDateTime,
  aLocalTime,
  diasEntreIso,
  // Exportado para tests / debugging.
  _dateToIsoSafe,
};
