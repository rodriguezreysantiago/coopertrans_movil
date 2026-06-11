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
const admin = require('firebase-admin');
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
      // protocolTimeout: tope de cada llamada al browser headless (protocolo
      // DevTools). El default de puppeteer (180s) timeouteaba en la dedicada
      // bajo carga/lentitud — "Runtime.callFunctionOn timed out" en
      // `tieneWhatsApp`/envíos, dejando la cola trabada sin mandar (incidente
      // 2026-06-05: mandó hasta cierto punto y se degradó). Lo subimos a 4 min
      // para tolerar picos. (Si el browser se CUELGA de verdad, el restart del
      // servicio + `_matarChromesHuerfanos` lo recupera.)
      protocolTimeout: 240000,
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-dev-shm-usage',
      ],
    },
  });

  client.on('qr', (qr) => {
    health.setEstadoCliente('AUTH_PENDIENTE');
    // Fix M4 (auditoria 24/7 2026-05-18): log CRITICAL muy visible
    // cuando el bot pide QR. La operacion 24/7 idealmente nunca
    // requiere QR (el auto-restore desde backup cubre el caso de
    // .wwebjs_auth/ corrupta). Si pide QR es porque:
    //   1. PC nueva sin backups previos (primera vez en la dedicada)
    //   2. Meta revoco el dispositivo del lado servidor (~1/6-12m)
    //   3. Restore fallo y no hay backup viable
    //
    // El log con prefijo `[CRITICAL_QR_PEDIDO]` permite filtrar
    // facil en monitor_logs.ps1 + Sentry. Ademas, el estado
    // AUTH_PENDIENTE queda reflejado en BOT_HEALTH/main (heartbeat
    // sigue latiendo) y el watchdog Cloud Function lo detecta y
    // avisa a Santiago por TELEGRAM — canal fuera de banda que no
    // depende del propio bot, que justo en este estado no puede
    // mandar WhatsApp. (Resuelto 2026-06-10, era el TODO "Fase 3
    // 24/7"; ver functions/src/bot_alerta_externa.ts.)
    log.error(
      '[CRITICAL_QR_PEDIDO] El bot esta pidiendo QR. La operacion ' +
      '24/7 quedo INTERRUMPIDA hasta que alguien escanee desde el ' +
      'celular del numero de Coopertrans. Causa probable: backup de ' +
      '.wwebjs_auth/ corrupto, primera vez en esta PC, o Meta revoco ' +
      'el dispositivo.'
    );
    health.registrarError(
      'qr_pedido',
      'Bot pidiendo QR — requiere intervencion humana'
    );
    log.info('Ajustes -> Dispositivos vinculados -> Vincular un dispositivo.');
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

  // M11 — Confirmaciones de lectura. WhatsApp emite `message_ack` con
  // un nivel:
  //   1 SERVER   recibido por el server WA (lo seteamos ya como ENVIADO)
  //   2 DEVICE   entregado al dispositivo del receptor
  //   3 READ     leído (doble check azul)
  //   4 PLAYED   audio reproducido (no aplica para texto)
  // Mapeamos 2→entregado_en, 3→leido_en sobre WHATSAPP_HISTORICO.
  //
  // CAVEAT: el ack solo llega si el bot está vivo cuando WhatsApp lo
  // notifica. Si el bot reinicia, los acks pasados se pierden — la app
  // muestra los checks que llegaron, no más. Para mensajes anteriores
  // al deploy M11, los campos quedan vacíos (esperado).
  client.on('message_ack', _handleMessageAck);
}

async function _handleMessageAck(msg, ack) {
  try {
    if (ack < 2) return; // 0/1 ya se setearon como ENVIADO al marcar el doc
    if (!msg || !msg.id || !msg.id._serialized) return;
    const waId = msg.id._serialized;
    const db = admin.firestore();
    const snap = await db
      .collection('WHATSAPP_HISTORICO')
      .where('wa_message_id', '==', waId)
      .limit(1)
      .get();
    if (snap.empty) return;
    const doc = snap.docs[0];
    const data = doc.data() || {};
    const updates = {};
    if (ack === 2) {
      // Solo set si todavía no estaba — evita rewrite con timestamp
      // diferente cuando llegan acks duplicados (sync entre devices).
      if (!data.entregado_en) {
        updates.entregado_en = admin.firestore.FieldValue.serverTimestamp();
      }
    } else if (ack >= 3) {
      // READ implica DELIVERED. Setear entregado_en si faltaba.
      if (!data.entregado_en) {
        updates.entregado_en = admin.firestore.FieldValue.serverTimestamp();
      }
      if (!data.leido_en) {
        updates.leido_en = admin.firestore.FieldValue.serverTimestamp();
      }
    }
    if (Object.keys(updates).length > 0) {
      await doc.ref.set(updates, { merge: true });
    }
  } catch (e) {
    // Defensivo: jamás romper el flujo del bot por un ack que falla.
    log.warn(`message_ack handler falló: ${e.message}`);
  }
}

function _safeInitialize() {
  client.initialize().catch((e) => {
    log.error(`client.initialize() falló: ${e.message}`);
    health.registrarError(
      "cliente_wa",
      `Initialize falló: ${e.message}`
    );
    // Fix H3 (auditoria 24/7 2026-05-18): la guard original
    // `!_readyWatchdogTimer` dejaba el bot colgado en el siguiente
    // edge case: watchdog dispara destroy + _safeInitialize, el
    // initialize falla rapido, pero el watchdog timer aun no
    // termino su ciclo (esta seteado). Como `_readyWatchdogTimer !=
    // null`, NO se disparaba `_intentarReconexion`. Si el watchdog
    // se cae despues (proceso muerto, GC raro), el cliente queda
    // permanentemente muerto hasta que NSSM lo detecte y reinicie
    // el servicio entero (lento, depende de health alerts).
    //
    // Fix: chequear AMBOS — solo skipear reconexion si efectivamente
    // hay un ciclo de watchdog ACTIVO Y con intentos remanentes.
    // Si el watchdog ya agoto sus intentos (intentosReadyTimeout >=
    // maxReadyTimeouts), no nos quedamos esperando — disparamos
    // reconexion como si fuera un arranque limpio.
    const watchdogActivoConIntentos =
      _readyWatchdogTimer &&
      _intentosReadyTimeout < _maxReadyTimeouts;
    if (!watchdogActivoConIntentos) {
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
  // Marcar el texto ANTES de enviar — cierra el race del id (el reflejo
  // message_create puede llegar antes de que registremos el id del saliente).
  _marcarTextoPropio(texto);
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
    const idSer = sent && sent.id && sent.id._serialized
      ? sent.id._serialized : null;
    _marcarPropio(idSer); // para que el handler descarte su reflejo (anti-auto-respuesta)
    return idSer;
  } catch (_) {
    return null;
  }
}

// Defensivo: guardamos el último handler registrado para poder
// removerlo si se vuelve a llamar `onMensajeEntrante`. Hoy index.js lo
// llama solo una vez en el bootstrap (no hay leak real), pero si una
// refactor futura lo invoca 2 veces, sin este guardia se duplicaría
// silenciosamente y cada mensaje se procesaría N veces.
//
// Flow completo incluyendo reconstruccion del cliente (auditoria 24/7
// 2026-05-18 — agente reporto race, verificado que no es bug):
//
//   1. Bootstrap: onMensajeEntrante(handler) -> _messageHandler=handler,
//      client.on('message_create', handler). Total: 1 listener.
//
//   2. Reconstruccion del cliente (recovery tras crash):
//      _construirCliente() crea nuevo `client` y al final, si
//      `_messageHandler` no es null, lo engancha al NUEVO client
//      (linea ~118). El viejo client se descarta (GC). Total
//      en cliente nuevo: 1 listener (handler) + cliente viejo
//      descartado.
//
//   3. Re-registro post-reconstruccion: onMensajeEntrante(handler2):
//      a) removeListener('message_create', handler1) sobre el NUEVO
//         client (donde estaba enganchado tras paso 2). OK.
//      b) _messageHandler=handler2, client.on(...handler2).
//      Total: 1 listener (handler2).
//
// Sin race: el remove+add son sincronicos dentro del mismo tick, no
// hay ventana donde queden 2 listeners.
let _messageHandler = null;

// IDs de WhatsApp de los mensajes que ENVIÓ el bot. El handler escucha
// `message_create` (necesario para que dispare en chats nuevos), que TAMBIÉN
// dispara para los salientes propios. En una sesión recién vinculada (cambio de
// dispositivo) esos reflejos llegan con fromMe/id/body CORRUPTOS y las defensas
// por contenido (firma "Bot-On", BOT_PHONE) fallan → el bot procesaba sus
// propios avisos (vigilador/sitrack) como entrantes y SE AUTO-RESPONDÍA (el
// "hablan entre ellos" reportado 2026-06-04). Registrar el id de cada saliente y
// descartarlo en el handler es la defensa INFALIBLE: el id no se puede falsear.
// Set acotado (FIFO) para no crecer infinito.
const _idsPropios = new Set();
const _MAX_IDS_PROPIOS = 2000;
function _marcarPropio(idSer) {
  if (!idSer || typeof idSer !== 'string') return;
  _idsPropios.add(idSer);
  if (_idsPropios.size > _MAX_IDS_PROPIOS) {
    _idsPropios.delete(_idsPropios.values().next().value); // descarta el más viejo
  }
}
/** ¿Este id de WhatsApp corresponde a un mensaje que enviamos nosotros? */
function esMensajePropio(idSer) {
  return typeof idSer === 'string' && idSer.length > 0 && _idsPropios.has(idSer);
}

// Cerrojo por CONTENIDO — cierra el RACE del id: el `id` de un saliente se genera
// DENTRO de sendMessage (durante el await), y el reflejo `message_create` puede
// llegar ANTES de que `_marcarPropio` lo registre → race (el bot seguía
// auto-respondiéndose, 2026-06-04 17:17). El TEXTO lo conocemos ANTES de enviar,
// así que lo marcamos sincrónicamente antes del envío: cuando el reflejo llega
// (mismo body), ya está marcado y se descarta. Map texto→ts, TTL 90s.
//
// ACOTADO POR FIRMA (auditoría 2026-06-06): esta capa SOLO mira textos que llevan
// la firma del bot ("Bot-On"). Antes marcaba/descartaba CUALQUIER saliente de ≥12
// chars, y un entrante que casualmente coincidía con una frase fija del bot ("No
// tenés unidad asignada.", etc.) se descartaba como "reflejo propio" → el chofer
// copiaba/repetía esa frase y su mensaje se perdía sin acuse. El motivo real de
// esta capa es el reflejo corrupto de la sesión recién vinculada de los AVISOS del
// vigilador/sitrack (el "hablan entre ellos", ver whatsapp.js:653) — y TODOS esos
// avisos llevan "Bot-On". Los salientes SIN firma (acuses, respuestas del agente)
// ya quedan cubiertos por la defensa infalible del id (_marcarPropio) + BOT_PHONE,
// así que sacarlos de esta capa no abre ningún hueco y evita el falso positivo.
const _FIRMA_BOT = 'Bot-On';
const _textosPropios = new Map();
const _TEXTO_PROPIO_TTL_MS = 90 * 1000;
function _normTextoPropio(t) {
  return String(t || '').trim().replace(/\s+/g, ' ').slice(0, 600);
}
function _llevaFirmaBot(texto) {
  return String(texto || '').includes(_FIRMA_BOT);
}
function _marcarTextoPropio(texto) {
  // Solo los avisos firmados entran al cerrojo por contenido — ver cabecera.
  if (!_llevaFirmaBot(texto)) return;
  const k = _normTextoPropio(texto);
  if (k.length < 12) return; // defensivo: avisos reales son largos
  const ahora = Date.now();
  _textosPropios.set(k, ahora);
  if (_textosPropios.size > 300) {
    for (const [kk, ts] of _textosPropios) {
      if (ahora - ts > _TEXTO_PROPIO_TTL_MS) _textosPropios.delete(kk);
    }
  }
}
/**
 * ¿El body coincide con un saliente FIRMADO nuestro de los últimos ~90s?
 * Solo aplica a textos con la firma "Bot-On" (avisos del bot) — un entrante
 * sin firma nunca se descarta por esta capa aunque copie una frase del bot.
 */
function esTextoPropio(texto) {
  if (!_llevaFirmaBot(texto)) return false;
  const k = _normTextoPropio(texto);
  if (k.length < 12) return false;
  const ts = _textosPropios.get(k);
  return ts != null && (Date.now() - ts) < _TEXTO_PROPIO_TTL_MS;
}

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
  _marcarTextoPropio(texto); // anti-race del reflejo (ver enviarMensaje)
  try {
    const sent = await msg.reply(texto);
    if (sent && sent.id && sent.id._serialized) {
      _marcarPropio(sent.id._serialized); // anti-auto-respuesta (reflejo del saliente)
    }
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

/**
 * Resuelve el teléfono real (PN) de un chat @lid. WhatsApp moderno entrega los
 * mensajes como @lid (linked id) y OCULTA el número (getContact().number viene
 * vacío), pero `getContactLidAndPhone` lo FUERZA vía el Store interno de
 * WhatsApp Web — funciona para contactos AGENDADOS (el caso de los choferes,
 * todos agendados en el teléfono del bot). Devuelve el teléfono en solo-dígitos
 * (549XXXXXXXXXX) o null si no se pudo resolver. Best-effort: cualquier fallo
 * cae a null y el caller sigue con su fallback (getContact / lid aprendido).
 */
async function obtenerTelefonoDeLid(lid) {
  if (!client || !listo || !lid) return null;
  const lidId = String(lid).includes('@') ? String(lid) : `${lid}@lid`;
  try {
    const res = await client.getContactLidAndPhone([lidId]);
    const pn = res && res[0] && res[0].pn; // "549XXXXXXXXXX@c.us"
    if (!pn) return null;
    return String(pn).replace(/\D+/g, '');
  } catch (e) {
    log.warn(`obtenerTelefonoDeLid(${lid}) falló: ${e.message}`);
    return null;
  }
}

/**
 * Probe ACTIVO de liveness del cliente (P2.1): valida que el browser de
 * Puppeteer esté realmente vivo, no solo que el último evento dijera LISTO.
 * `client.getState()` toca la página real; si el browser murió sin emitir
 * `disconnected`, tira o se cuelga → con timeout corto devolvemos false. Lo usa
 * el heartbeat para no reportar "LISTO" sobre una sesión zombi (bot fantasma).
 */
async function estaVivo(timeoutMs = 5000) {
  if (!client || !listo) return false;
  try {
    const estado = await Promise.race([
      client.getState(),
      new Promise((_, rej) =>
        setTimeout(() => rej(new Error('probe timeout')), timeoutMs)),
    ]);
    return estado === 'CONNECTED';
  } catch (e) {
    return false;
  }
}

module.exports = {
  inicializar,
  tieneWhatsApp,
  enviarMensaje,
  onMensajeEntrante,
  responder,
  esMensajePropio,
  esTextoPropio,
  estaVivo,
  obtenerTelefonoDeLid,
  destroy,
  // Exportados para tests del cerrojo por contenido (fix 1, 2026-06-06).
  _marcarTextoPropio,
  _resetTextosPropiosParaTests: () => _textosPropios.clear(),
};
