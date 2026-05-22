// Heartbeat del bot — mantiene un doc `BOT_HEALTH/main` en Firestore con
// el estado actual, para que la app Flutter pueda mostrar una pantalla
// "Estado del bot" sin necesidad de SSH al server.
//
// Cómo encaja con el resto del bot:
//   - `iniciar(db, fs, wa)`: arranca un setInterval que cada
//     HEARTBEAT_INTERVAL_SECONDS escribe el doc.
//   - `registrarEnvio()`: hook que index.js llama después de cada envío
//     OK. Bumpea el contador de "mensajes hoy" y refresca el ts.
//   - `registrarError(contexto, mensaje)`: agrega un error al ring buffer
//     (últimos 10) y refresca el ts.
//   - `registrarCicloCron(stats)`: hook que cron.js llama al cerrar un
//     ciclo. Guarda timestamp + stats.
//   - `setEstadoCliente(estado)`: hook que whatsapp.js llama cuando el
//     cliente WA cambia de estado (LISTO / DESCONECTADO / etc).
//
// La lógica de "el bot está caído" la hace la app del lado del cliente:
// si `ultimoHeartbeat` es de hace > 2 minutos, el bot no está respondiendo.
// Acá no escribimos un campo "vivo: true/false" porque sería mentira:
// si el bot crashea, no hay nadie que lo ponga en false.

const admin = require('firebase-admin');
const os = require('os');
const log = require('./logger');

// Identificador de la PC donde corre el bot. Coincide con la
// constante PC_ID en index.js — duplicado a proposito para que
// health.js sea autocontenido y no introduzca un require ciclico.
// Si en el futuro se mueve a un modulo `config.js` central, mejor.
const PC_ID = process.env.BOT_PC_ID || os.hostname() || 'desconocida';

// ─── Estado en memoria ─────────────────────────────────────────────
//
// Todo esto es efímero — si el bot reinicia, vuelve a 0 y se va
// rellenando a medida que pasan cosas. Lo que persiste entre reinicios
// es lo que ya escribimos al doc de Firestore.

const BUFFER_ERRORES_MAX = 10;
const VERSION = require('../package.json').version || 'desconocida';

let _db = null;
let _fs = null; // módulo firestore.js (para leer COLECCION/ESTADO)
let _wa = null; // módulo whatsapp.js (para leer estado del cliente)
let _timer = null;

const _state = {
  estadoCliente: 'INICIANDO',
  ultimoCicloCron: null, // Date | null
  ultimoCicloStats: null, // { encolados, salteados, errores } | null
  ultimoMensajeEnviado: null, // Date | null
  mensajesEnviadosHoy: 0,
  fechaContadorHoy: _hoyIso(), // YYYY-MM-DD en TZ del server
  erroresRecientes: [], // [{ en: Date, contexto, mensaje }]
  // Timestamps (en ms) de los últimos envíos de la última hora — usados
  // para enforcear MAX_MESSAGES_PER_HOUR. Buffer rotativo: cada vez que
  // se llama enviadosUltimaHora() se descartan los > 1h. Cap defensivo
  // de 200 entries por si hay un bug y se llena.
  timestampsUltimaHora: [],
  // Detección de cola creciendo: timestamp cuando la cola pasó arriba
  // del umbral. Si se mantiene > N min, alertamos al admin. Reset
  // cuando vuelve por debajo.
  colaCrecienteDesde: null,
  colaCrecienteAlertada: false,
};

function _hoyIso() {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${dd}`;
}

// ─── Hooks que llaman los otros módulos ────────────────────────────

/**
 * Cambia el estado del cliente WhatsApp. Estados posibles:
 *   - 'INICIANDO'        — proceso arrancando, todavía no hay cliente.
 *   - 'AUTH_PENDIENTE'   — esperando QR o login.
 *   - 'AUTENTICADO'      — pasó el auth pero todavía no llegó el ready.
 *   - 'LISTO'            — puede enviar mensajes.
 *   - 'DESCONECTADO'     — el cliente cayó (sesión expiró, internet, etc).
 *   - 'AUTH_FALLO'       — auth_failure del cliente, requiere reescaneo de QR.
 */
function setEstadoCliente(estado) {
  _state.estadoCliente = estado;
}

/**
 * Llamar después de cada envío exitoso.
 * Bumpea el contador del día y registra el timestamp.
 */
function registrarEnvio() {
  // Si cambió el día desde el último envío, reseteamos el contador.
  // Esto evita acumular el contador para siempre (ahora la app puede
  // mostrar "X mensajes enviados HOY" sin lógica extra).
  const hoy = _hoyIso();
  if (hoy !== _state.fechaContadorHoy) {
    _state.mensajesEnviadosHoy = 0;
    _state.fechaContadorHoy = hoy;
  }
  _state.mensajesEnviadosHoy++;
  const ahora = new Date();
  _state.ultimoMensajeEnviado = ahora;
  _state.timestampsUltimaHora.push(ahora.getTime());
  // Cap defensivo (no debería llegar acá si MAX_MESSAGES_PER_HOUR funciona)
  if (_state.timestampsUltimaHora.length > 200) {
    _state.timestampsUltimaHora.splice(0, _state.timestampsUltimaHora.length - 200);
  }
}

/**
 * Cuántos envíos hubo en los últimos 60 minutos (rolling window).
 * Cleanup oportunista: descarta timestamps viejos en cada llamada.
 *
 * Usado por el flow de envío para enforcear MAX_MESSAGES_PER_HOUR del
 * .env (anti-baneo: WhatsApp típicamente flaggea >40 mensajes/hora con
 * patrón uniforme).
 */
function enviadosUltimaHora() {
  const cutoff = Date.now() - 60 * 60 * 1000;
  // Filtrar in-place para evitar GC innecesario.
  let i = 0;
  while (i < _state.timestampsUltimaHora.length &&
         _state.timestampsUltimaHora[i] < cutoff) {
    i++;
  }
  if (i > 0) _state.timestampsUltimaHora.splice(0, i);
  return _state.timestampsUltimaHora.length;
}

/**
 * Si hay rate limit activo, cuánto hay que esperar (en ms) hasta que
 * un slot se libere. Devuelve 0 si no hay limit. El slot se libera
 * cuando el envío más viejo de la ventana cumple 60 min.
 */
function msHastaSlotLibre(maxPorHora) {
  const enviados = enviadosUltimaHora();
  if (enviados < maxPorHora) return 0;
  const ahora = Date.now();
  const masViejo = _state.timestampsUltimaHora[0];
  const liberaEn = masViejo + 60 * 60 * 1000;
  return Math.max(0, liberaEn - ahora);
}

/**
 * Llamar cuando ocurre un error que conviene mostrar al admin.
 *
 * @param {string} contexto - corto: 'envio', 'cron', 'cliente_wa', 'firestore'.
 * @param {string} mensaje  - mensaje de error legible (sin stack trace).
 */
function registrarError(contexto, mensaje) {
  _state.erroresRecientes.unshift({
    en: new Date(),
    contexto: String(contexto || '').slice(0, 40),
    mensaje: String(mensaje || '').slice(0, 300),
  });
  // Mantener solo los últimos N — si el bot tiene un mal día con
  // muchos errores, no queremos que el doc crezca sin límite.
  if (_state.erroresRecientes.length > BUFFER_ERRORES_MAX) {
    _state.erroresRecientes.length = BUFFER_ERRORES_MAX;
  }
}

/**
 * Llamar al final de cada ciclo del cron.
 *
 * @param {{encolados: number, salteados: number, errores: number}} stats
 */
function registrarCicloCron(stats) {
  _state.ultimoCicloCron = new Date();
  _state.ultimoCicloStats = stats || null;
}

// ─── Loop de heartbeat ─────────────────────────────────────────────

/**
 * Arranca el heartbeat. Idempotente: una segunda llamada no duplica el timer.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {object} firestoreModule - el módulo `./firestore` (necesitamos
 *   acceso a COLECCION y ESTADO para contar la cola).
 * @param {object} whatsappModule  - el módulo `./whatsapp` (opcional;
 *   si está, intentamos leer estado actual del cliente como fallback).
 */
function iniciar(db, firestoreModule, whatsappModule) {
  if (_timer) return; // ya arrancado

  _db = db;
  _fs = firestoreModule;
  _wa = whatsappModule;

  const intervaloSeg = parseInt(
    process.env.HEARTBEAT_INTERVAL_SECONDS || '60',
    10
  );
  log.info(`Heartbeat cada ${intervaloSeg}s a BOT_HEALTH/main.`);

  // Primera escritura inmediata para que la app vea algo enseguida.
  _escribirSerializado();

  _timer = setInterval(() => {
    _escribirSerializado();
  }, intervaloSeg * 1000);
}

// Serializa las escrituras de heartbeat para evitar que dos calls
// concurrentes (ej: el setInterval anterior tardó más que su período)
// se pisen entre sí escribiendo al mismo doc. Si Firestore está lento
// y un heartbeat tarda 90s mientras el intervalo es 60s, sin esto
// habría dos escrituras concurrentes en flight con potencial conflict.
let _escribiendoHeartbeat = false;

function _escribirSerializado() {
  if (_escribiendoHeartbeat) {
    log.debug('Heartbeat anterior aún en curso, skip este intervalo.');
    return;
  }
  _escribiendoHeartbeat = true;
  // Timeout 30s (auditoria 2026-05-17): si Firestore queda lento o
  // se corta la red, sin timeout `escribirHeartbeat()` puede quedar
  // pendiente para siempre. El flag _escribiendoHeartbeat se queda
  // en true y todos los proximos intervals skipean → el doc
  // `BOT_HEALTH/main` deja de actualizarse → `botHealthWatchdog`
  // (Cloud Function) cree que el bot murio y manda falsa alarma.
  const timeoutPromise = new Promise((_, reject) => {
    setTimeout(() => reject(new Error('Heartbeat write timeout 30s')), 30000);
  });
  Promise.race([escribirHeartbeat(), timeoutPromise])
    .catch((e) => {
      log.warn(`Heartbeat falló: ${e.message}`);
    })
    .finally(() => {
      _escribiendoHeartbeat = false;
    });
}

function detener() {
  if (_timer) {
    clearInterval(_timer);
    _timer = null;
  }
}

/**
 * Construye el documento y lo escribe en `BOT_HEALTH/main`.
 *
 * Decisión: usamos `set` con merge para que cada heartbeat sobreescriba
 * solo los campos que conoce. Si en algún futuro otro proceso escribe a
 * `BOT_HEALTH/main` (no debería, pero por las dudas), no lo pisamos
 * entero.
 */
async function escribirHeartbeat() {
  if (!_db || !_fs) {
    throw new Error('health.iniciar() no fue llamado');
  }

  // Contadores de cola — una query por estado. Son livianas porque
  // sólo hacemos count(), no traemos los docs. Si Firestore no soporta
  // count() en tu versión del SDK Admin, cae a get().size.
  const cola = await _contarCola();

  // Importamos acá para no crear ciclo de require en boot. `humano.js`
  // depende solo de variables de entorno.
  const { enHorarioHabil } = require('./humano');

  // Calculamos próximo ciclo del cron sumando el intervalo configurado
  // al último ciclo registrado. Si nunca corrió, dejamos null.
  const cronIntervaloMin = parseInt(
    process.env.CRON_INTERVAL_MINUTES || '60',
    10
  );
  const proximoCicloCron = _state.ultimoCicloCron
    ? new Date(_state.ultimoCicloCron.getTime() + cronIntervaloMin * 60 * 1000)
    : null;

  const doc = {
    ultimoHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
    estadoCliente: _state.estadoCliente,

    // Identificador de la PC que esta corriendo el bot. Lo lee
    // index.js al arrancar para detectar el caso "ya hay otra PC con
    // el bot vivo, no levantes una segunda instancia".
    pcId: PC_ID,

    cola,

    cron: {
      ultimoCiclo: _state.ultimoCicloCron
        ? admin.firestore.Timestamp.fromDate(_state.ultimoCicloCron)
        : null,
      proximoCicloAprox: proximoCicloCron
        ? admin.firestore.Timestamp.fromDate(proximoCicloCron)
        : null,
      ultimoCicloStats: _state.ultimoCicloStats,
      intervaloMinutos: cronIntervaloMin,
    },

    mensajes: {
      ultimoEnviado: _state.ultimoMensajeEnviado
        ? admin.firestore.Timestamp.fromDate(_state.ultimoMensajeEnviado)
        : null,
      enviadosHoy: _state.mensajesEnviadosHoy,
      fechaContadorHoy: _state.fechaContadorHoy,
    },

    erroresRecientes: _state.erroresRecientes.map((e) => ({
      en: admin.firestore.Timestamp.fromDate(e.en),
      contexto: e.contexto,
      mensaje: e.mensaje,
    })),

    config: {
      enHorarioHabil: enHorarioHabil(),
      autoAvisos:
        String(process.env.AUTO_AVISOS_ENABLED || 'false').toLowerCase() ===
        'true',
      autoRespuestas:
        String(
          process.env.AUTO_RESPUESTAS_ENABLED || 'false'
        ).toLowerCase() === 'true',
      workingHoursStart: parseInt(process.env.WORKING_HOURS_START || '8', 10),
      workingHoursEnd: parseInt(process.env.WORKING_HOURS_END || '20', 10),
      timezone:
        process.env.WORKING_TIMEZONE || 'America/Argentina/Buenos_Aires',
    },

    // Reglas de notificación: a qué DNI van los resúmenes diarios
    // (service + alertas Volvo). Las publicamos en el doc para que la
    // app pueda mostrarlas en pantalla "Estado del Bot" sin tener que
    // adivinar/duplicar valores. Si Vecchi cambia el destinatario, lo
    // hace en el .env del bot y se refleja en el próximo heartbeat.
    //
    // Vencimientos profesionales/vehiculares NO van acá porque el
    // destinatario es dinámico (chofer afectado / chofer asignado al
    // vehículo) — la app lo describe textualmente.
    reglasNotificacion: {
      serviceDiario: {
        destinatarioDni:
          process.env.SERVICE_DESTINATARIO_DNI || null,
        descripcion: 'Resumen diario de tractores con service próximo o vencido.',
      },
      // Nota (2026-05-22): la regla `alertasVolvoDiario` se removió. Leía
      // `ALERTAS_RESUMEN_DESTINATARIO_DNI`, pero esa env var YA NO dispara
      // ningún envío del bot — el "Parte de mantenimiento" lo manda la CF
      // `resumenMantenimientoVehiculosDiario` (functions/src/volvo_mantenimiento.ts)
      // con DNI hardcodeado `MANTENIMIENTO_VEHICULOS_DNI` en functions/src/comun.ts.
      // Publicar acá esa regla confundía (cambiar la env var no reenrutaba nada).
      vencimientosChofer: {
        destinatarioDni: 'CHOFER_AFECTADO',
        descripcion:
          'Vencimientos de licencia / ART / 931 al chofer dueño del documento.',
      },
      vencimientosVehiculo: {
        destinatarioDni: 'CHOFER_ASIGNADO',
        descripcion:
          'Vencimientos de RTO / Seguro / Extintores al chofer asignado al vehículo.',
      },
    },

    bot: {
      version: VERSION,
      pid: process.pid,
      nodeVersion: process.version,
      // process.uptime() devuelve segundos como float. Lo redondeamos
      // para que el doc no tenga ruido decimal.
      uptimeSegundos: Math.round(process.uptime()),
    },
  };

  await _db.collection('BOT_HEALTH').doc('main').set(doc, { merge: true });

  // Verificar si la cola está creciendo de forma anormal y alertar al
  // admin (best-effort — si falla la alerta, no rompemos el heartbeat).
  try {
    await _verificarColaCreciente(cola);
  } catch (e) {
    log.warn(`Verificación cola creciente falló: ${e.message}`);
  }
}

/**
 * Detecta si la cola pendiente lleva > UMBRAL docs por > MINUTOS_SOSTENIDOS
 * minutos seguidos. En ese caso encola un mensaje de alerta al admin.
 *
 * Diferencia con el watchdog (`botHealthWatchdog` Cloud Function): el
 * watchdog detecta CAÍDAS del bot (heartbeat stale). Esto detecta
 * "bot vivo pero procesando muy lento" — escenario distinto que un
 * watchdog basado en heartbeat no captura.
 *
 * Configuración via .env:
 *   - COLA_CRECIENTE_ALERT_DNI: DNI del destinatario. Sin esta var,
 *     el check es no-op (no se alerta).
 *   - COLA_CRECIENTE_UMBRAL: pendientes > este número (default 50).
 *   - COLA_CRECIENTE_MIN_SOSTENIDO: minutos sostenidos arriba (default 30).
 *
 * Idempotencia: una vez alertado en este episodio, no spamea hasta
 * que la cola vuelva a bajar del umbral (`colaCrecienteAlertada` flag).
 */
async function _verificarColaCreciente(cola) {
  const dniAlert = process.env.COLA_CRECIENTE_ALERT_DNI;
  if (!dniAlert) return;

  const threshold = parseInt(process.env.COLA_CRECIENTE_UMBRAL || '50', 10);
  const sustainedMin = parseInt(
    process.env.COLA_CRECIENTE_MIN_SOSTENIDO || '30', 10
  );

  if (cola.pendientes <= threshold) {
    // Cola sana — resetear estado para que un próximo episodio
    // alerte de nuevo.
    if (_state.colaCrecienteDesde) {
      log.info(
        `Cola volvió a estado sano (${cola.pendientes} ≤ ${threshold}).`
      );
    }
    _state.colaCrecienteDesde = null;
    _state.colaCrecienteAlertada = false;
    return;
  }

  // Cola arriba del umbral.
  if (!_state.colaCrecienteDesde) {
    _state.colaCrecienteDesde = new Date();
    log.warn(
      `Cola arriba del umbral (${cola.pendientes} > ${threshold}). ` +
      `Si se mantiene ${sustainedMin} min, alerto al admin.`
    );
    return;
  }
  if (_state.colaCrecienteAlertada) return;

  const minutosArriba =
    (Date.now() - _state.colaCrecienteDesde.getTime()) / 60000;
  if (minutosArriba < sustainedMin) return;

  // Pasó el umbral por suficiente tiempo — encolar alerta.
  try {
    await _encolarAlertaColaCreciente(
      dniAlert,
      cola.pendientes,
      Math.round(minutosArriba)
    );
    _state.colaCrecienteAlertada = true;
  } catch (e) {
    log.warn(
      `No se pudo encolar alerta cola creciente a ${dniAlert}: ${e.message}`
    );
  }
}

async function _encolarAlertaColaCreciente(dni, pendientes, minutos) {
  const empSnap = await _db.collection('EMPLEADOS').doc(dni).get();
  if (!empSnap.exists) {
    log.warn(`COLA_CRECIENTE_ALERT_DNI=${dni} no existe en EMPLEADOS.`);
    return;
  }
  const data = empSnap.data() || {};
  const tel = String(data.TELEFONO || '').trim();
  if (!tel) {
    log.warn(`Destinatario alerta cola ${dni} sin TELEFONO.`);
    return;
  }
  await _db.collection(_fs.COLECCION).add({
    telefono: tel,
    mensaje:
      `🚨 *Alerta del bot — cola creciente*\n\n` +
      `Hay ${pendientes} mensajes pendientes en la cola (sostenido por ` +
      `~${minutos} min). El bot está vivo pero procesando lento.\n\n` +
      `Posibles causas:\n` +
      `   • Ráfaga de eventos Volvo / vencimientos.\n` +
      `   • Rate limit de WhatsApp activo.\n` +
      `   • Bot ↔ Firestore con latencia alta.\n\n` +
      `Mandá /estado al bot por WhatsApp para más info.`,
    estado: _fs.ESTADO.pendiente,
    encolado_en: admin.firestore.FieldValue.serverTimestamp(),
    // TTL Fase 2 (2026-05-18): alerta operativa - si llega 30 min
    // tarde el problema seguramente ya cambio (o se resolvio solo).
    expira_en: admin.firestore.Timestamp.fromMillis(
      Date.now() + 30 * 60 * 1000
    ),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: 'health_alert_cola_creciente',
    destinatario_coleccion: 'EMPLEADOS',
    destinatario_id: dni,
    campo_base: 'COLA_CRECIENTE',
    admin_dni: 'BOT',
    admin_nombre: 'Bot health',
  });
  log.warn(
    `🚨 Alerta cola creciente encolada para ${dni} ` +
    `(pendientes=${pendientes}, ${minutos} min sostenido).`
  );
}

/**
 * Cuenta los docs en COLA_WHATSAPP por estado. Devuelve un objeto con
 * `pendientes`, `procesando`, `error`, `reintentando`. Los `enviados`
 * no los contamos porque el contador crece sin límite y no aporta
 * información útil en tiempo real.
 *
 * `reintentando` es un subset de `pendientes`: docs que están
 * técnicamente en estado PENDIENTE pero con `proximoIntentoEn` en el
 * futuro (vinieron de un reintento fallido y todavía esperan el
 * próximo turno). La suma `pendientes + procesando + error` sigue
 * siendo el total de la cola activa (sin doble contar).
 *
 * Para PENDIENTE traemos los docs (no count) porque necesitamos
 * inspeccionar `proximoIntentoEn` campo a campo. La cola es chica
 * (decenas, no miles) así que el costo es despreciable. Para
 * PROCESANDO y ERROR usamos count() que es una sola lectura agregada.
 */
async function _contarCola() {
  const colRef = _db.collection(_fs.COLECCION);
  const out = { pendientes: 0, procesando: 0, error: 0, reintentando: 0 };

  // PENDIENTES + REINTENTANDO (mismo estado, distinguidos por proximoIntentoEn).
  try {
    const snap = await colRef.where('estado', '==', _fs.ESTADO.pendiente).get();
    out.pendientes = snap.size;
    const ahoraMs = Date.now();
    snap.forEach((d) => {
      const prox = d.data().proximoIntentoEn;
      if (!prox) return;
      const t = typeof prox.toMillis === 'function'
        ? prox.toMillis()
        : new Date(prox).getTime();
      if (!isNaN(t) && t > ahoraMs) out.reintentando++;
    });
  } catch (err) {
    // Si la query falla, dejamos los contadores en 0 — es preferible
    // mostrar 0 que tirar el heartbeat entero por una lectura.
  }

  // PROCESANDO y ERROR — count() agregado.
  for (const e of ['procesando', 'error']) {
    const valor = _fs.ESTADO[e];
    try {
      const snap = await colRef.where('estado', '==', valor).count().get();
      const n = snap.data().count;
      if (e === 'procesando') out.procesando = n;
      if (e === 'error') out.error = n;
    } catch (err) {
      const snap = await colRef.where('estado', '==', valor).get();
      const n = snap.size;
      if (e === 'procesando') out.procesando = n;
      if (e === 'error') out.error = n;
    }
  }

  return out;
}

module.exports = {
  iniciar,
  detener,
  setEstadoCliente,
  registrarEnvio,
  registrarError,
  registrarCicloCron,
  enviadosUltimaHora,
  msHastaSlotLibre,
  // Para tests / debugging:
  _state,
  escribirHeartbeat,
};
