// Heurísticas para que el patrón de envío parezca humano.
//
// WhatsApp tiene detectores de bots que miran:
//   - Ráfagas de mensajes (10 mensajes en 30s).
//   - Mensajes 24x7 sin pausa nocturna.
//   - Mensajes idénticos a contactos distintos.
//   - Tiempo entre login y primer mensaje sospechosamente corto.
//
// No podemos eliminar la huella de bot, pero la podemos suavizar.

const { esFeriado, descripcionFeriado } = require('./feriados_ar');

/**
 * Devuelve `true` si el momento actual está dentro de la ventana hábil
 * configurada para enviar mensajes automáticos.
 *
 * Reglas (configurables vía .env):
 *   - **Lunes a viernes**: ventana `WORKING_HOURS_START` a
 *     `WORKING_HOURS_END` (default 8 a 20). Para mandar hasta las
 *     23:59 setear `WORKING_HOURS_END=24`.
 *   - **Sábado**: si `WORKING_HOURS_SAT_END > 0`, ventana
 *     `WORKING_HOURS_SAT_START` a `WORKING_HOURS_SAT_END`. Default
 *     ambos en 0 → sábado NO manda.
 *   - **Domingo**: nunca manda (señal de bot demasiado obvia).
 *   - **Feriados nacionales AR**: nunca manda (lista hardcodeada en
 *     `feriados_ar.js`). Aplica también si el feriado cae sábado.
 *   - **Zona horaria**: `WORKING_TIMEZONE`, default
 *     `America/Argentina/Buenos_Aires`.
 *
 * Usa `Intl.DateTimeFormat` con zona explícita en lugar de
 * `now.getHours()` — eso es CRÍTICO porque el servidor puede correr
 * en otra TZ (cloud, contenedor, PC con reloj cambiado, etc.). Sin
 * la TZ explícita, los avisos pueden salir a las 3 AM hora real.
 *
 * Configuración operativa Vecchi 2026-05-08:
 *   WORKING_HOURS_START=8
 *   WORKING_HOURS_END=24
 *   WORKING_HOURS_SAT_START=8
 *   WORKING_HOURS_SAT_END=12
 *   WORKING_TIMEZONE=America/Argentina/Buenos_Aires
 */
function enHorarioHabil(now = new Date()) {
  const inicio = parseInt(process.env.WORKING_HOURS_START || '8', 10);
  const fin = parseInt(process.env.WORKING_HOURS_END || '20', 10);
  const satInicio = parseInt(
    process.env.WORKING_HOURS_SAT_START || '0',
    10
  );
  const satFin = parseInt(process.env.WORKING_HOURS_SAT_END || '0', 10);
  const tz =
    process.env.WORKING_TIMEZONE || 'America/Argentina/Buenos_Aires';

  // Extraemos día de la semana y hora EN la zona horaria objetivo —
  // independiente del reloj del proceso. Intl.DateTimeFormat es la
  // forma estándar de hacer esto en Node desde v10+.
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    weekday: 'short', // 'Mon'..'Sun'
    hour: '2-digit',
    hour12: false,
  });
  const parts = fmt.formatToParts(now);
  const weekday = parts.find((p) => p.type === 'weekday')?.value || '';
  const horaStr = parts.find((p) => p.type === 'hour')?.value || '0';
  // Algunas implementaciones devuelven "24" para medianoche; lo
  // normalizamos a 0.
  let hora = parseInt(horaStr, 10);
  if (hora === 24) hora = 0;

  // Domingo: skip duro (no configurable — mandar domingo es señal
  // obvia de bot y dispara baneo de WhatsApp).
  if (weekday === 'Sun') return false;

  // Feriados nacionales obligatorios de Argentina: skip antes que
  // cualquier ventana horaria. Aplica también si el feriado cae
  // sábado. Lista hardcodeada en feriados_ar.js (mantener anualmente).
  if (esFeriado(now)) return false;

  // Sábado: ventana propia. Si WORKING_HOURS_SAT_END no está seteado
  // (o queda en 0 por compatibilidad con configs viejas), sábado NO
  // manda — preserva el comportamiento histórico del bot.
  if (weekday === 'Sat') {
    if (satFin <= 0) return false;
    return hora >= satInicio && hora < satFin;
  }

  // Lunes a viernes: ventana normal.
  return hora >= inicio && hora < fin;
}

/**
 * Devuelve la descripcion del feriado actual, o null si no es feriado.
 * Util para logs y para que el admin entienda por que el bot no
 * mando nada un dia particular.
 */
function feriadoHoy(now = new Date()) {
  return descripcionFeriado(now);
}

/**
 * Origenes "time-sensitive" — mensajes que deben procesarse SIEMPRE,
 * incluso fuera de horario habil (de noche / fin de semana / feriados).
 *
 * Decision Vecchi 2026-05-18 (primera noche bot 24/7): hasta hoy el bot
 * respetaba L-V 8-20 / Sab 8-12 para TODOS los mensajes, incluyendo los
 * avisos del vigilador de jornada. Bug operativo: si un chofer entraba
 * en veda nocturna 00:00 ART manejando, el aviso quedaba encolado hasta
 * las 8 AM siguientes — para entonces ya pasaron 8 hs y el aviso es
 * inutil (o expira por TTL_JORNADA_VEDA_MIN=180).
 *
 * Ahora separamos:
 *   - Time-sensitive  -> procesar SIEMPRE (24/7)
 *   - Normal          -> respetar horario habil (L-V 8-22 / Sab 8-12,
 *                        domingo + feriados off)
 *
 * Lista cerrada (whitelist) — solo estos origenes pasan en horario
 * inhabil. Si en el futuro se suma un cron nuevo time-sensitive, hay
 * que agregarlo aca explicitamente.
 */
const ORIGENES_TIME_SENSITIVE = new Set([
  // Vigilador de jornada (Cloud Functions jornadas_v2)
  'jornada_v2_bloque_3h30',
  'jornada_v2_bloque_excedido',
  'jornada_v2_cuota_proxima',   // heads-up 11h (agregado 2026-05-19)
  'jornada_v2_cuota_cumplida',
  'jornada_v2_veda_nocturna',
  // Envío manual del estado de jornada (comando admin /enviar-jornada).
  // El admin lo pide explícitamente — debe entregarse ya, no esperar
  // horario hábil.
  'jornada_manual_admin',
  // Vigilador de jornada v1 (legacy — refactor a v2 2026-05-15).
  // Probablemente ya no se genera, pero por defensa lo dejamos
  // como time-sensitive (cero costo).
  'jornada_pausa_continua',
  'jornada_continua_12h',
  'jornada_continua_11h30',
  'jornada_continua_3h45',
  'jornada_continua_3h30',
  // Alertas Volvo y Sitrack en tiempo real
  'volvo_alert_high',
  'sitrack_chofer_no_identificado',
  // Confirmaciones de comandos del bot
  'silenciado_aviso',
  'desilenciado_aviso',
  'silencio_reanudado',
  // Alertas operativas del propio bot
  'health_alert_cola_creciente',
]);

/**
 * Devuelve true si el origen es time-sensitive (procesa 24/7).
 * Devuelve false para origenes normales (vencimientos, resumenes
 * diarios, etc) que respetan horario habil.
 */
function esTimeSensitive(origen) {
  if (!origen) return false;
  return ORIGENES_TIME_SENSITIVE.has(String(origen));
}

/**
 * Devuelve un delay aleatorio en milisegundos para esperar antes de
 * enviar el próximo mensaje. Default 15-60 segundos.
 *
 * El delay es uniforme dentro del rango — no exponencial — porque no
 * estamos modelando "tiempo entre mensajes humanos" sino "ritmo
 * razonable de operador con tareas concurrentes".
 */
function delayAleatorioMs() {
  const min = parseInt(process.env.DELAY_MIN_MS || '15000', 10);
  const max = parseInt(process.env.DELAY_MAX_MS || '60000', 10);
  return Math.floor(min + Math.random() * (max - min));
}

/**
 * `await sleep(ms)` para usar en async/await sin libs.
 */
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Convierte un número de teléfono al formato que espera WhatsApp Web
 * (`<numero>@c.us`). Acepta entradas con `+`, espacios y guiones.
 * Devuelve `null` si el número no parece válido.
 *
 * Ejemplos:
 *   "+54 291 456-7890"  → "5492914567890@c.us"
 *   "5492914567890"     → "5492914567890@c.us"
 *   "abc"               → null
 */
function normalizarTelefonoAWid(telefono) {
  if (!telefono) return null;
  const digitos = String(telefono).replace(/\D+/g, '');
  if (digitos.length < 10 || digitos.length > 15) return null;
  return `${digitos}@c.us`;
}

/**
 * Forma canónica de un teléfono para COMPARAR (NO para enviar). Reconcilia
 * el "9" móvil argentino: WhatsApp entrega el ID de un número AR SIN el 9
 * (`542915115568`), pero los TELEFONOS en EMPLEADOS suelen estar cargados
 * CON el 9 (`5492915115568`). Si no unificamos, el match por número falla y
 * el bot no identifica al remitente — caso real: el agente no respondía a
 * choferes ni supervisores; solo a admins (que entran por whitelist).
 *
 * Quita el `9` inmediatamente después del `54` (indicador de móvil AR;
 * ningún código de área argentino empieza con 9, así que es seguro). NO se
 * usa para enviar: el envío sigue con `normalizarTelefonoAWid`.
 *
 * @param {string} telefono
 * @returns {string} dígitos canónicos (sin el 9 móvil AR), o '' si vacío.
 */
function telefonoCanonicalAr(telefono) {
  let d = String(telefono || '').replace(/\D+/g, '');
  if (!d) return '';
  if (d.startsWith('549')) d = `54${d.slice(3)}`;
  return d;
}

/**
 * Parte un mensaje muy largo en múltiples chunks para evitar que
 * WhatsApp lo flagee como spam.
 *
 * WhatsApp soporta técnicamente hasta 65536 caracteres por mensaje,
 * pero en la práctica mensajes > 4096 chars empiezan a aumentar el
 * scoring anti-spam. Más allá de 8000-10000 directamente los rechaza.
 * El umbral por default (3500) deja margen.
 *
 * Estrategia:
 *  1. Si el texto cabe en `maxChars`, devolver array de 1 elemento.
 *  2. Sino, partir por bloques separados por doble salto de línea
 *     (preserva formato visual del resumen — cada bloque queda
 *     completo en su parte).
 *  3. Si un bloque solo es > maxChars (caso patológico, no debería
 *     ocurrir con resúmenes), se hace split duro por chars.
 *  4. Cuando hay > 1 parte, prepender "(parte i/N)" para que el
 *     destinatario sepa que falta más.
 *
 * El caller debe esperar ~2s entre cada send para no parecer flood.
 *
 * @param {string} texto       — mensaje completo
 * @param {number} maxChars    — umbral por chunk (default 3500)
 * @returns {string[]} 1 o más partes listas para enviar
 */
function partirMensajeLargo(texto, maxChars = 3500) {
  const t = String(texto || '');
  if (t.length <= maxChars) return [t];

  // Paso 1: agrupar bloques separados por '\n\n' sin pasar el cap.
  const bloques = t.split('\n\n');
  const grupos = [];
  let actual = '';
  for (const b of bloques) {
    if (actual === '') {
      actual = b;
    } else if (actual.length + 2 + b.length <= maxChars) {
      actual += '\n\n' + b;
    } else {
      grupos.push(actual);
      actual = b;
    }
  }
  if (actual) grupos.push(actual);

  // Paso 2: defensa por si un bloque solo es > maxChars (caso raro).
  const partes = [];
  for (const g of grupos) {
    if (g.length <= maxChars) {
      partes.push(g);
    } else {
      for (let i = 0; i < g.length; i += maxChars) {
        partes.push(g.slice(i, i + maxChars));
      }
    }
  }

  // Paso 3: prepender marcador (parte i/N) si > 1.
  if (partes.length === 1) return partes;
  const total = partes.length;
  return partes.map((p, i) => `(parte ${i + 1}/${total})\n${p}`);
}

module.exports = {
  enHorarioHabil,
  feriadoHoy,
  delayAleatorioMs,
  sleep,
  normalizarTelefonoAWid,
  telefonoCanonicalAr,
  partirMensajeLargo,
  esTimeSensitive,
  ORIGENES_TIME_SENSITIVE,
};
