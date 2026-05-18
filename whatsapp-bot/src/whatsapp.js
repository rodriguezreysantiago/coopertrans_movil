// Wrapper sobre whatsapp-web.js. Encapsula:
//   - LocalAuth para que la sesión persista en .wwebjs_auth/
//   - QR rendering en consola al primer login
//   - Estado del cliente (autenticado / pronto para enviar)
//   - Verificación de número antes de enviar (evita "el chofer no tiene WhatsApp")
//   - Watchdog del evento READY (resuelve cuelgue del A/B testing)
//   - Modo dry-run (BOT_DRY_RUN=true): no envía mensajes reales

const { Client, LocalAuth } = require('whatsapp-web.js');
const qrcode = require('qrcode-terminal');
const { execSync } = require('child_process');
const path = require('path');
const log = require('./logger');
const health = require('./health');

let client = null;
let listo = false;
const callbacksAlEstarListo = [];

function inicializar() {
  if (client) return _esperarListo();
  _construirCliente();
  // Bug observado en producción: si `client.initialize()` lanza un
  // error sincrónico o rechaza la promesa antes de que dispare el
  // evento `authenticated`, el watchdog (que solo arranca con ese
  // evento) NUNCA arranca → bot queda colgado en estado INICIANDO sin
  // recovery. NSSM lo reinicia pero arranca con el mismo problema →
  // loop de cuelgues que requiere reejecutar manual.
  //
  // Fix: catcheamos el error y disparamos el flujo de reconexión
  // (mismo backoff exponencial que `disconnected`), de modo que el
  // bot intente reinicializar N veces antes de exit(1).
  _safeInitialize();
  return _esperarListo();
}

/**
 * Crea una instancia nueva de `Client` con todos los event listeners.
 * Reusable: lo llama `inicializar()` la primera vez y
 * `_recrearCliente()` cada vez que el initialize falla porque la
 * referencia vieja al cliente quedó podrida (browser huérfano,
 * userDataDir lockeado, etc.).
 *
 * Si había un handler de mensajes entrantes registrado (vía
 * `onMensajeEntrante`), lo re-registra automáticamente en la nueva
 * instancia — sin esto perderíamos los mensajes entrantes después de
 * un recovery.
 */
function _construirCliente() {
  client = new Client({
    authStrategy: new LocalAuth({}),
    // ─── webVersionCache remoto ───
    // Crítico para evitar el bug "autenticado pero nunca ready".
    // El cache remoto baja siempre una versión estable conocida del
    // repo de wppconnect (que monitorea cuál anda y cuál no).
    webVersionCache: {
      type: 'remote',
      remotePath:
        'https://raw.githubusercontent.com/wppconnect-team/wa-version/main/html/{version}.html',
      strict: false,
    },
    puppeteer: {
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-dev-shm-usage',
      ],
    },
  });

  client.on('qr', (qr) => {
    health.setEstadoCliente('AUTH_PENDIENTE');
    log.info('QR recibido — escaneá desde WhatsApp en el teléfono descartable.');
    log.info('Ajustes → Dispositivos vinculados → Vincular un dispositivo.');
    qrcode.generate(qr, { small: true });
  });

  client.on('authenticated', () => {
    health.setEstadoCliente('AUTENTICADO');
    log.info('Sesión de WhatsApp autenticada y persistida en .wwebjs_auth/');
    // Arranca el watchdog: si ready no llega en READY_TIMEOUT_SEC,
    // matamos el cliente y reintentamos. Resuelve el bug conocido
    // "autenticado pero never ready" del A/B testing de WhatsApp Web.
    _arrancarWatchdogReady();
  });

  client.on('auth_failure', (msg) => {
    health.setEstadoCliente('AUTH_FALLO');
    health.registrarError('cliente_wa', `Auth failure: ${msg}`);
    log.error(`Auth failure: ${msg}`);
  });

  client.on('ready', () => {
    listo = true;
    health.setEstadoCliente('LISTO');
    _intentosReconexion = 0;
    _intentosReadyTimeout = 0;
    _detenerWatchdogReady();
    log.info('WhatsApp listo para enviar.');
    callbacksAlEstarListo.splice(0).forEach((cb) => cb());
  });

  client.on('disconnected', (reason) => {
    listo = false;
    health.setEstadoCliente('DESCONECTADO');
    health.registrarError('cliente_wa', `Cliente desconectado: ${reason}`);
    log.warn(`Cliente desconectado: ${reason}.`);
    // Limpieza preventiva: si hay callers esperando `_esperarListo()`
    // antes de la desconexión, sus resolvers están en el array. La
    // reconexión va a disparar `ready` de nuevo y se resuelven solos —
    // no los limpiamos para no romper esa promesa. Si la reconexión
    // falla 5 veces y exit(1), las promesas mueren con el proceso.
    _intentarReconexion();
  });

  // Re-registrar el handler de mensajes entrantes si había uno (caso
  // recovery del cliente — la instancia nueva no hereda los listeners).
  if (_messageHandler) {
    client.on('message_create', _messageHandler);
  }
}

function _safeInitialize() {
  client.initialize().catch((e) => {
    log.error(`client.initialize() falló: ${e.message}`);
    health.registrarError(
      "cliente_wa",
      `Initialize falló: ${e.message}`
    );
    // Importante: NO llamar _intentarReconexion() acá si ya estamos
    // dentro del watchdog — eso lo maneja el watchdog mismo. Solo
    // disparamos reconexión cuando el initialize falló afuera de un
    // ciclo de watchdog (caso del primer arranque).
    if (!_readyWatchdogTimer) {
      _intentarReconexion();
    }
  });
}

function _esperarListo() {
  if (listo) return Promise.resolve();
  return new Promise((resolve) => callbacksAlEstarListo.push(resolve));
}

// ─── Reconexión con backoff exponencial ─────────────────────────────
let _reconexionEnCurso = false;
let _intentosReconexion = 0;
const _maxReconexiones = 5;

/**
 * Detecta el caso del "browser huérfano": después de un crash del
 * cliente, Puppeteer puede dejar un proceso Chromium vivo que sigue
 * tomando el lock de `.wwebjs_auth/session/`. En ese caso el nuevo
 * `initialize()` falla con un mensaje tipo:
 *   "The browser is already running for ... Use a different `userDataDir` or stop the running browser first."
 *
 * Este patrón se usa para decidir si hay que matar manualmente los
 * Chromes huérfanos antes de reintentar.
 */
function _esErrorBrowserHuerfano(e) {
  const msg = (e && e.message) || String(e || '');
  return /browser is already running/i.test(msg) ||
      /already running for/i.test(msg) ||
      /different.*userdatadir/i.test(msg);
}

/**
 * Matar Chromes huérfanos en Windows que tengan el `userDataDir` del
 * bot abierto. Sin esto, el siguiente `initialize()` vuelve a fallar
 * con "already running" y caemos en loop. Solo se ejecuta cuando
 * detectamos el patrón específico — no spammeamos taskkill cada
 * recovery.
 *
 * En Linux/macOS no hace nada por ahora (no observamos el problema
 * ahí; whatsapp-web.js suele limpiar bien fuera de Windows).
 */
function _matarChromesHuerfanos() {
  if (process.platform !== 'win32') return;
  // Path absoluto del userDataDir donde LocalAuth persiste la sesión.
  // En Windows lleva backslashes en la commandline de Chrome — los
  // escapamos para el filtro WMIC.
  const sessionDir = path.resolve(
    process.cwd(),
    '.wwebjs_auth',
    'session'
  );
  const sessionDirEscaped = sessionDir.replace(/\\/g, '\\\\');
  try {
    // WMIC busca chrome.exe cuya commandline contenga la ruta del
    // userDataDir, los lista en CSV y matamos cada uno. Si no hay
    // matches, WMIC devuelve "No Instance(s) Available." y no rompe.
    const stdout = execSync(
      `wmic process where "name='chrome.exe' and commandline like '%${sessionDirEscaped}%'" get processid /format:csv`,
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
    );
    const pids = stdout
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.toLowerCase().startsWith('node'))
      .map((line) => line.split(',').pop())
      .filter((pid) => /^\d+$/.test(pid));

    if (pids.length === 0) {
      log.info(
        'No se encontraron Chromes huérfanos del bot en la búsqueda WMIC.'
      );
      return;
    }
    log.warn(
      `Matando ${pids.length} Chrome(s) huérfano(s) del bot: PIDs ${pids.join(', ')}`
    );
    for (const pid of pids) {
      try {
        execSync(`taskkill /F /PID ${pid} /T`, {
          stdio: ['ignore', 'ignore', 'ignore'],
        });
      } catch (killErr) {
        // /T mata todo el árbol; si alguno ya murió, taskkill exit !=0
        // pero no es fatal.
        log.warn(`taskkill PID ${pid} falló: ${killErr.message}`);
      }
    }
  } catch (e) {
    // Si WMIC no está disponible (Win10+ marca deprecation) o falla
    // por otra razón, no es fatal — el siguiente retry capaz anda
    // solo si Chromium se cerró por su cuenta.
    log.warn(`Búsqueda de Chromes huérfanos falló: ${e.message}`);
  }
}

function _intentarReconexion() {
  if (_reconexionEnCurso) return;
  _reconexionEnCurso = true;

  if (_intentosReconexion >= _maxReconexiones) {
    log.error(
      `${_maxReconexiones} reintentos fallidos. Saliendo para que el supervisor reinicie limpio.`
    );
    process.exit(1);
  }

  _intentosReconexion++;
  const delayMs = Math.min(1000 * Math.pow(2, _intentosReconexion - 1), 16000);
  log.info(
    `Reintentando conexión (intento ${_intentosReconexion}/${_maxReconexiones}) en ${delayMs}ms...`
  );

  setTimeout(async () => {
    let huboError = false;
    try {
      await client.initialize();
    } catch (e) {
      huboError = true;
      log.warn(`Reconexión falló: ${e.message}`);
      // Si el error es el clásico "browser is already running"
      // (Chromium huérfano lockeando el userDataDir), matamos esos
      // procesos y recreamos el cliente desde cero. La referencia al
      // `client` viejo quedó podrida — `initialize()` no se recupera
      // sobre la misma instancia, hay que tirarla.
      //
      // Auditoria 2026-05-17: tambien recreamos en cualquier otro
      // fallo a partir del 2do intento. Casos reales: logout remoto,
      // NAVIGATION del frame de WhatsApp Web, sesion revocada. Antes
      // estos quedaban en loop de retry sobre el mismo client podrido
      // hasta agotar los 5 reintentos → 30+ seg de cola parada y docs
      // que llegaban a MAX_RETRIES como ERROR.
      const debeRecrear =
        _esErrorBrowserHuerfano(e) || _intentosReconexion >= 2;
      if (debeRecrear) {
        if (_esErrorBrowserHuerfano(e)) _matarChromesHuerfanos();
        try {
          await client.destroy();
        } catch (destroyErr) {
          log.warn(
            `Destroy del cliente viejo falló (esperable): ${destroyErr.message}`
          );
        }
        _construirCliente();
      }
    } finally {
      _reconexionEnCurso = false;
    }
    // Si el retry falló, encadenamos otro automáticamente sin esperar
    // que alguien lo dispare desde afuera. Sin esto, después del
    // primer fallo el bot quedaba en limbo: `client` vivo en memoria
    // pero `listo=false`, y nada vuelve a llamar `_intentarReconexion`.
    // Detectado 2026-05-13 con bot caído ~30min después de un crash.
    if (huboError) {
      _intentarReconexion();
    }
  }, delayMs);
}

// ─── Watchdog de READY ─────────────────────────────────────────────
//
// Bug conocido: después del evento `authenticated`, a veces el `ready`
// nunca llega — el cliente queda colgado en pantalla de carga al 99%.
// Causado por A/B testing del lado de WhatsApp Web 2.3000.x.
//
// Mitigación: timeout configurable (default 90s). Si no llega `ready`,
// matamos el cliente Chromium y reintentamos `initialize()`. La sesión
// persistida en .wwebjs_auth/ NO se borra, así que no requiere
// reescanear el QR.
//
// Si el watchdog dispara MAX_READY_TIMEOUTS veces seguidas, exit con
// código 1 — en producción NSSM reinicia el proceso desde cero.

let _readyWatchdogTimer = null;
let _readyProgressTimer = null;
let _intentosReadyTimeout = 0;
const _maxReadyTimeouts = parseInt(
  process.env.MAX_READY_TIMEOUTS || '3',
  10
);

function _arrancarWatchdogReady() {
  _detenerWatchdogReady();
  const timeoutSeg = parseInt(process.env.READY_TIMEOUT_SEC || '90', 10);
  // Cantidad de tics progresivos que vamos a emitir (uno cada 30s).
  // Para timeoutSeg=90, son 3 tics: 1/3, 2/3, 3/3.
  const totalTics = Math.max(1, Math.floor(timeoutSeg / 30));
  let ticActual = 0;

  // Log periódico cada 30s para ver el progreso desde la consola.
  // El contador se resetea cada vez que se arranca el watchdog (cada
  // reinicio del cliente arranca uno nuevo), así que en cada intento
  // vas a ver 1/3, 2/3, 3/3 desde cero.
  _readyProgressTimer = setInterval(() => {
    ticActual++;
    log.info(`Esperando WhatsApp listo... ${ticActual}/${totalTics}`);
  }, 30000);

  _readyWatchdogTimer = setTimeout(async () => {
    _detenerWatchdogReady();
    _intentosReadyTimeout++;

    log.warn(
      `Watchdog: ready no llegó en ${timeoutSeg}s ` +
      `(intento ${_intentosReadyTimeout}/${_maxReadyTimeouts}).`
    );
    health.registrarError(
      'cliente_wa',
      `Ready timeout (${timeoutSeg}s) — bug del A/B testing de WhatsApp Web. Reintentando.`
    );

    if (_intentosReadyTimeout >= _maxReadyTimeouts) {
      log.error(
        `${_maxReadyTimeouts} timeouts seguidos. Saliendo para que el supervisor reinicie limpio.`
      );
      process.exit(1);
    }

    try {
      await client.destroy();
    } catch (e) {
      log.warn(`Error cerrando cliente para reintento: ${e.message}`);
    }
    health.setEstadoCliente('INICIANDO');
    log.info('Reinicializando cliente WhatsApp...');
    try {
      await client.initialize();
    } catch (e) {
      log.error(`Reinicialización falló: ${e.message}`);
      health.registrarError(
        'cliente_wa',
        `Reinicialización tras timeout falló: ${e.message}`
      );
      // Caso "browser huérfano": matamos los Chromes que siguen
      // tomando el userDataDir y recreamos el cliente. El mismo fix
      // que el ciclo de `_intentarReconexion`, replicado acá porque
      // el watchdog tiene su propio flujo de retry.
      if (_esErrorBrowserHuerfano(e)) {
        _matarChromesHuerfanos();
        try {
          await client.destroy();
        } catch (destroyErr) {
          log.warn(
            `Destroy del cliente viejo falló (esperable): ${destroyErr.message}`
          );
        }
        _construirCliente();
      }
      // Si la reinicialización dentro del watchdog también falla, el
      // bot queda en INICIANDO sin watchdog activo. Re-arrancamos uno
      // nuevo con el mismo timeout para que el ciclo de retry no se
      // pierda — sin esto, el bot se cuelga silenciosamente.
      if (_intentosReadyTimeout < _maxReadyTimeouts) {
        _arrancarWatchdogReady();
        _safeInitialize();
      } else {
        log.error('Watchdog agotado después de fallo en reinicialización. exit(1).');
        process.exit(1);
      }
    }
  }, timeoutSeg * 1000);
}

function _detenerWatchdogReady() {
  if (_readyWatchdogTimer) {
    clearTimeout(_readyWatchdogTimer);
    _readyWatchdogTimer = null;
  }
  if (_readyProgressTimer) {
    clearInterval(_readyProgressTimer);
    _readyProgressTimer = null;
  }
}

// ─── Detección de browser muerto ───────────────────────────────────
//
// Bug observado 2026-05-06: después de horas de uso normal el browser
// de Puppeteer se desconecta sin que `whatsapp-web.js` emita el evento
// `disconnected`. El watchdog de READY no aplica (sólo cubre el arranque
// inicial). Resultado: cada llamada a `getNumberId`/`sendMessage` falla
// con "Attempted to use detached Frame ...", el index.js lo trata como
// transient y reencola — loop infinito sin recovery.
//
// Mitigación: detectamos esos errores específicos en el wrapper y
// disparamos `_gestionarBrowserMuerto()` que marca el cliente como no
// listo, lo destruye y arranca el flujo de reconexión.

const _PATRONES_BROWSER_MUERTO = [
  /detached frame/i,
  /target closed/i,
  /protocol error.*target/i,
  /browser is closed/i,
  /browser has disconnected/i,
  /session closed/i,
  /connection closed/i,
];

function _esErrorBrowserMuerto(e) {
  const msg = (e && e.message) || String(e || '');
  return _PATRONES_BROWSER_MUERTO.some((re) => re.test(msg));
}

let _browserMuertoEnCurso = false;
function _gestionarBrowserMuerto(e) {
  if (_browserMuertoEnCurso) return;
  _browserMuertoEnCurso = true;
  listo = false;
  health.setEstadoCliente('DESCONECTADO');
  health.registrarError(
    'cliente_wa',
    `Browser de Puppeteer muerto: ${e.message}`
  );
  log.error(
    `Browser de Puppeteer muerto. Reinicializando cliente. Causa: ${e.message}`
  );
  // destroy + reconexión en background — el caller actual no espera.
  setImmediate(async () => {
    try {
      await client.destroy();
    } catch (destroyErr) {
      log.warn(`Error al destruir cliente muerto: ${destroyErr.message}`);
    } finally {
      _browserMuertoEnCurso = false;
      _intentarReconexion();
    }
  });
}

// ─── API pública ───────────────────────────────────────────────────

async function tieneWhatsApp(wid) {
  if (!client || !listo) throw new Error('Cliente no inicializado');
  try {
    const numberId = await client.getNumberId(wid.replace('@c.us', ''));
    return numberId !== null;
  } catch (e) {
    if (_esErrorBrowserMuerto(e)) {
      _gestionarBrowserMuerto(e);
    }
    throw e;
  }
}

/**
 * Envía un mensaje de texto. Devuelve el id de WhatsApp del mensaje
 * recién enviado.
 *
 * **Modo dry-run**: si BOT_DRY_RUN=true, NO envía nada real. Loguea
 * el destino + texto y devuelve un id sintético `dryrun_*`. Útil para
 * validar cambios al cron / al builder sin spammear a los choferes.
 */
async function enviarMensaje(wid, texto) {
  const dryRun =
    String(process.env.BOT_DRY_RUN || 'false').toLowerCase() === 'true';
  if (dryRun) {
    log.info(
      `[DRY-RUN] enviarMensaje a ${wid} — ${texto.length} chars (no se envía).`
    );
    log.debug(`[DRY-RUN] Cuerpo: ${texto.slice(0, 200)}${texto.length > 200 ? '…' : ''}`);
    return `dryrun_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
  }
  if (!client || !listo) throw new Error('Cliente no inicializado');
  let sent;
  try {
    sent = await client.sendMessage(wid, texto);
  } catch (e) {
    if (_esErrorBrowserMuerto(e)) {
      _gestionarBrowserMuerto(e);
    }
    throw e;
  }
  try {
    return sent && sent.id && sent.id._serialized ? sent.id._serialized : null;
  } catch (_) {
    return null;
  }
}

// Defensivo: guardamos el último handler registrado para poder
// removerlo si se vuelve a llamar `onMensajeEntrante`. Hoy index.js lo
// llama solo una vez en el bootstrap (no hay leak real), pero si una
// refactor futura lo invoca 2 veces, sin este guardia se duplicaría
// silenciosamente y cada mensaje se procesaría N veces.
let _messageHandler = null;

function onMensajeEntrante(handler) {
  if (!client) throw new Error('Cliente no inicializado');
  // Si ya había un handler registrado, lo sacamos antes de registrar
  // el nuevo — evita acumulación de listeners en re-registros.
  if (_messageHandler) {
    try {
      client.removeListener('message_create', _messageHandler);
    } catch (e) {
      log.warn(`No se pudo remover handler anterior: ${e.message}`);
    }
  }
  _messageHandler = handler;
  // `message_create` dispara para TODOS los mensajes (entrantes y
  // salientes). Es más permisivo que `message`, que en algunas
  // versiones de wwebjs no dispara en conversaciones nuevas
  // (la primera vez que un número no-contacto escribe al bot).
  // El handler filtra `msg.fromMe` para descartar los nuestros.
  client.on('message_create', handler);
}

async function responder(msg, texto) {
  if (!client || !listo) throw new Error('Cliente no inicializado');
  try {
    await msg.reply(texto);
  } catch (e) {
    if (_esErrorBrowserMuerto(e)) {
      _gestionarBrowserMuerto(e);
    }
    throw e;
  }
}

async function destroy() {
  if (client) {
    try {
      await client.destroy();
    } catch (e) {
      log.warn(`Error cerrando cliente: ${e.message}`);
    }
  }
}

module.exports = {
  inicializar,
  tieneWhatsApp,
  enviarMensaje,
  onMensajeEntrante,
  responder,
  destroy,
};
