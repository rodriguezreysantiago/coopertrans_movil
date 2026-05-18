// Entrypoint del bot. Orquesta:
//   1. Carga de .env
//   2. Inicialización de Firebase Admin
//   3. Conexión a WhatsApp Web (con persistencia de sesión)
//   4. Listener de COLA_WHATSAPP que procesa mensajes uno por uno
//      respetando horario hábil y delay aleatorio.

// `quiet: true` silencia el splash informativo que dotenv 17+ imprime
// al cargar (algo tipo "◇ injected env (15) from .env"). Es ruido en
// el log del bot que se confunde con eventos reales.
require('dotenv').config({ quiet: true });

// Fijamos la TZ del proceso EN EL TOP, antes de cualquier require que
// dependa de fechas (cron, historico, calcularDiasRestantes). Sin esto
// el bot heredaria la TZ del host -- si maniana migramos a Cloud Run
// region US, los avisos se desfasarian un dia (medianoche ART vs UTC).
// Configurable via env: BOT_TIMEZONE=America/Argentina/Buenos_Aires
// (default si no esta seteada).
process.env.TZ = process.env.BOT_TIMEZONE || 'America/Argentina/Buenos_Aires';

const fsNode = require('fs');
const path = require('path');
const os = require('os');

const admin = require('firebase-admin');
const log = require('./logger');

// Handlers globales de excepciones no atrapadas. Antes el bot las
// dejaba burbujear: NSSM reiniciaba el proceso y nadie sabia que paso
// (timer rejection en polling? heartbeat? watchdog?). Ahora siempre
// queda el stack en stdout/NSSM logs.
//
// Decision sobre exit:
//   - unhandledRejection: NO matamos. Una promesa puntual que falla
//     (ej. Firestore timeout en un .get()) no debe tirar el proceso
//     entero -- los polling loops y el cron deben seguir. Solo logear.
//   - uncaughtException: SI matamos. Excepcion sincronica = bug
//     serio en estado dificil de razonar. Mejor reset limpio y que
//     NSSM reinicie. exit(1) hace que el supervisor lo detecte como
//     fallo y aplique backoff.
process.on('unhandledRejection', (reason, _promise) => {
  log.error('UNHANDLED PROMISE REJECTION:', reason);
  if (reason instanceof Error && reason.stack) {
    log.error(reason.stack);
  }
});
process.on('uncaughtException', (error) => {
  log.error('UNCAUGHT EXCEPTION:', error);
  if (error instanceof Error && error.stack) {
    log.error(error.stack);
  }
  process.exit(1);
});

const fs = require('./firestore');
const wa = require('./whatsapp');
const cron = require('./cron');
const health = require('./health');
const control = require('./control');
const backupAuth = require('./backup_auth');
const messageHandler = require('./message_handler');
const agrupador = require('./agrupador');

// Identificador de esta PC. Configurable via env var BOT_PC_ID
// (recomendado: "casa", "oficina", "server-prod"). Si no se setea,
// usamos el hostname del SO como fallback ("DESKTOP-XYZ123"). Lo
// usamos para detectar el caso "el bot ya esta corriendo en otra PC"
// y evitar dos instancias procesando la misma cola.
const PC_ID = process.env.BOT_PC_ID || os.hostname() || 'desconocida';
const {
  enHorarioHabil,
  delayAleatorioMs,
  sleep,
  normalizarTelefonoAWid,
  partirMensajeLargo,
} = require('./humano');
const { aLocalDateTime } = require('./fechas');

// Limpieza preventiva al arrancar — desbloquea Chromium si quedó
// medio muerto del proceso anterior.
//
// Bugs recurrentes de `whatsapp-web.js` cuando el proceso anterior no
// cerró limpio (Ctrl+C contestando "S" a la pregunta de PowerShell,
// crash, kill -9, etc.):
//
//   1. Cache corrupto en `.wwebjs_cache/` → arranque cuelga sin llegar
//      a "WhatsApp listo".
//   2. **SingletonLock / SingletonCookie / SingletonSocket** dentro de
//      `.wwebjs_auth/` → Chromium nuevo cree que hay otra instancia
//      viva y se queda esperando. ESTE es el más jodido porque NO se
//      ve en el log; el bot queda en "Sesión autenticada" eternamente.
//
// La sesión real (cookies, login persistido) está en otros archivos
// que NO empiezan con "Singleton". Borrar los Singleton* no requiere
// reescanear QR.
function limpiarLocksChromium() {
  const root = path.resolve(__dirname, '..');

  // (1) Cache: borrar la carpeta entera. Se reconstruye sola.
  const cacheDir = path.join(root, '.wwebjs_cache');
  if (fsNode.existsSync(cacheDir)) {
    try {
      fsNode.rmSync(cacheDir, { recursive: true, force: true });
      log.info('Cache de Chromium limpiado (.wwebjs_cache/).');
    } catch (e) {
      log.warn(`No pude limpiar .wwebjs_cache/: ${e.message}`);
    }
  }

  // (2) Singleton locks dentro de la sesión persistida.
  // wwebjs los guarda dentro de `.wwebjs_auth/` en una ubicación que
  // depende de la versión (`session/`, `session/Default/`, etc).
  // Búsqueda RECURSIVA para cubrir cualquier layout. Solo borramos
  // archivos que matchean "Singleton*" — la sesión real (Cookies,
  // Local State, Login Data) NO tiene ese prefijo y queda intacta.
  const authRoot = path.join(root, '.wwebjs_auth');
  let borrados = 0;
  if (fsNode.existsSync(authRoot)) {
    const stack = [authRoot];
    while (stack.length > 0) {
      const dir = stack.pop();
      let entries;
      try {
        entries = fsNode.readdirSync(dir, { withFileTypes: true });
      } catch (_) {
        continue;
      }
      for (const ent of entries) {
        const full = path.join(dir, ent.name);
        if (ent.isDirectory()) {
          stack.push(full);
        } else if (ent.name.startsWith('Singleton')) {
          try {
            fsNode.rmSync(full, { force: true });
            borrados++;
          } catch (e) {
            log.warn(`No pude borrar ${full}: ${e.message}`);
          }
        }
      }
    }
  }
  if (borrados > 0) {
    log.info(`Locks de Chromium previos limpiados (${borrados} archivos Singleton*).`);
  } else {
    log.info('No había locks Singleton* previos (sesión limpia).');
  }
}

// Mata procesos `chrome.exe` que quedaron zombis del intento anterior
// del bot (puppeteer no siempre cierra limpio si node crasheó, kill -9,
// o el padre se cerró sin SIGTERM). Solo Windows. Filtra por CommandLine
// que contenga el path raíz del bot — NO toca Chrome del usuario ni
// instancias de Puppeteer de otros proyectos.
//
// Sin esto, `client.initialize()` falla con
// "The browser is already running for ...\.wwebjs_auth\session" y los
// retries de `_safeInitialize()` rebotan todos contra el mismo zombi.
// Diagnosticado el 2026-05-06.
function matarProcesosChromiumZombi() {
  if (process.platform !== 'win32') return;
  const root = path.resolve(__dirname, '..');
  const psCmd =
    `Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | ` +
    `Where-Object { $_.CommandLine -like '*${root}*' } | ` +
    `ForEach-Object { Stop-Process -Id $_.ProcessId -Force; ` +
    `Write-Output $_.ProcessId }`;
  try {
    const { execFileSync } = require('child_process');
    const out = execFileSync(
      'powershell.exe',
      ['-NoProfile', '-Command', psCmd],
      { encoding: 'utf-8', timeout: 10000 }
    );
    const pids = out.trim().split(/\s+/).filter(Boolean);
    if (pids.length > 0) {
      log.info(
        `Procesos Chromium zombi del bot anterior matados: ${pids.length} ` +
        `(PIDs ${pids.join(', ')}).`
      );
    } else {
      log.info('No había procesos Chromium zombi del bot.');
    }
  } catch (e) {
    log.warn(`No pude matar procesos Chromium zombi: ${e.message}`);
  }
}

// Cola en memoria con los doc IDs pendientes en orden FIFO.
const colaProcesar = [];
let procesando = false;

function encolar(doc) {
  if (colaProcesar.includes(doc.id)) return;
  colaProcesar.push(doc.id);
  log.info(`+ Encolado ${doc.id} (total en cola: ${colaProcesar.length})`);
  if (!procesando) procesarSiguiente();
}

// ─── Reintentos automáticos con backoff ──────────────────────────────
//
// Lista INVERTIDA (allowlist de errores definitivos): todo lo que no
// está acá se trata como TRANSITORIO y se reintenta. Esto cubre el caso
// de errores nuevos de WhatsApp (ej. "rate limit exceeded", "phone
// temporarily unavailable") que antes caían como definitivos por no
// matchear la lista cerrada de transitorios — y se perdían mensajes
// que sí podrían enviarse después.
//
// Para sumar un patrón definitivo nuevo: agregarlo acá con un comment
// que justifique por qué NO se debe reintentar.
const _PATRONES_DEFINITIVOS = [
  // Teléfono mal formado / sin WhatsApp registrado — NO reintentar,
  // hace falta que el admin corrija el TELEFONO en EMPLEADOS.
  /numero invalido/i,
  /no tiene whatsapp/i,
  /phone number is invalid/i,
  /wid not found/i,
  /no registered/i,
  // Mensaje rechazado por contenido / política de WhatsApp — reintentar
  // no va a cambiar nada.
  /message blocked/i,
  /content rejected/i,
];

function _esErrorTransitorio(error) {
  const msg = (error && error.message) || String(error || '');
  // Default-retry: si NO matchea ningún patrón definitivo, es transitorio.
  return !_PATRONES_DEFINITIVOS.some((re) => re.test(msg));
}

function _backoffSegundos(intento) {
  const raw = process.env.RETRY_BACKOFF_SEC || '30,120,600';
  const arr = raw
    .split(',')
    .map((s) => parseInt(s.trim(), 10))
    .filter((n) => !isNaN(n) && n > 0);
  if (arr.length === 0) return 60;
  const idx = Math.min(Math.max(intento - 1, 0), arr.length - 1);
  return arr[idx];
}

/**
 * Si la fecha cae fuera de horario hábil, la desplaza al próximo slot
 * hábil (próximo día L-V dentro del horario, o lunes si es viernes/finde).
 * Esto evita que un reintento programado para 19:45 + 30min termine como
 * "next attempt 20:15" (fuera de horario, queda flotando hasta el lunes).
 *
 * Heurística simple: si `cuando` no está en horario hábil, lo seteamos al
 * próximo bucket de horario hábil (8:05 AM del próximo día hábil para
 * dar margen vs el `enHorarioHabil` exacto). Si SÍ está en horario, lo
 * dejamos como vino.
 */
function _ajustarAHorarioHabil(cuando) {
  if (enHorarioHabil(cuando)) return cuando;
  // Iterar día a día hasta encontrar uno hábil.
  const c = new Date(cuando);
  for (let i = 0; i < 7; i++) {
    c.setDate(c.getDate() + (i === 0 ? 0 : 1));
    c.setHours(8, 5, 0, 0);
    if (enHorarioHabil(c)) return c;
  }
  // Defensa improbable: si en 7 días no encontramos uno hábil, devolvemos
  // el cuando original (mejor reintentar fuera de horario que perderlo).
  return cuando;
}

async function _despacharFalloEnvio(docRef, error) {
  const maxRetries = parseInt(process.env.MAX_RETRIES || '3', 10);
  const transitorio = _esErrorTransitorio(error);
  const snap = await docRef.get();
  const intentos = (snap.exists && snap.data().intentos) || 0;

  if (transitorio && intentos < maxRetries) {
    const backoffSeg = _backoffSegundos(intentos);
    const cuandoRaw = new Date(Date.now() + backoffSeg * 1000);
    // Si el reintento cae fuera de horario hábil, lo desplazamos al
    // próximo slot hábil para que el log no mienta y el doc no quede
    // flotando hasta el lunes con un proximoIntentoEn falso.
    const cuando = _ajustarAHorarioHabil(cuandoRaw);
    await fs.marcarReintento(docRef, error.message, cuando);
    const ajustado = cuando.getTime() !== cuandoRaw.getTime();
    log.info(
      `↻ Reintento ${intentos}/${maxRetries} de ${docRef.id} ` +
        `(${ajustado ? 'desplazado a horario hábil' : `en ${backoffSeg}s`}) ` +
        `→ ${aLocalDateTime(cuando)}`
    );
    return;
  }

  const motivo = transitorio
    ? `agotados ${maxRetries} reintentos`
    : 'error no transitorio';
  await fs.marcarError(docRef, `${error.message} (${motivo})`);
  log.warn(`✗ ${docRef.id}: ERROR definitivo (${motivo}).`);
}

async function procesarSiguiente() {
  if (procesando) return;
  if (colaProcesar.length === 0) return;
  procesando = true;

  const docId = colaProcesar.shift();
  const db = fs.inicializar();
  const docRef = db.collection(fs.COLECCION).doc(docId);

  try {
    const snap = await docRef.get();
    if (!snap.exists) {
      log.warn(`${docId} ya no existe; salto.`);
      return;
    }
    const data = snap.data();
    if (data.estado !== fs.ESTADO.pendiente) {
      log.debug(`${docId} ya no está PENDIENTE (es ${data.estado}); salto.`);
      return;
    }

    // ─── Validación: aviso expirado ───
    // Algunos avisos son tiempo-sensibles (vigilador de jornada, eventos
    // Volvo de manejo en vivo, "pasá el iButton"). Cloud Functions setea
    // `expira_en` al encolarlos. Si el bot estuvo apagado y procesa la
    // cola horas después, esos avisos ya no tienen sentido (ej. "te
    // quedan 15 min para parar" llegando 14 horas después). Se borran
    // sin enviar — los resúmenes diarios y vencimientos NO tienen
    // expira_en y siguen al margen de este filtro. Decisión Vecchi
    // 2026-05-08.
    if (
      data.expira_en &&
      typeof data.expira_en.toMillis === 'function' &&
      data.expira_en.toMillis() < Date.now()
    ) {
      const segundosVencido = Math.floor(
        (Date.now() - data.expira_en.toMillis()) / 1000
      );
      log.info(
        `${docId}: aviso EXPIRADO (origen=${data.origen}, ` +
          `vencido hace ${segundosVencido}s); borrando de la cola.`
      );
      try {
        await docRef.delete();
      } catch (e) {
        log.warn(`No se pudo borrar ${docId} expirado: ${e.message}`);
      }
      return;
    }

    if (!enHorarioHabil()) {
      log.info(`Fuera de horario hábil. ${docId} queda PENDIENTE para que el polling lo reintente.`);
      return;
    }

    // ─── Validación: kill-switch del admin ───
    // El admin puede pausar el bot desde la app (BOT_CONTROL/main.pausado).
    // Si está pausado, dejamos el doc en PENDIENTE — el polling lo va a
    // re-detectar cuando se reanude. Importante: no marcamos ERROR para
    // no inflar el contador de errores con algo que no es realmente fallo.
    if (await control.estaPausado()) {
      log.info(`Bot pausado por admin. ${docId} queda PENDIENTE.`);
      return;
    }

    const wid = normalizarTelefonoAWid(data.telefono);
    if (!wid) {
      log.warn(`${docId} con teléfono inválido: ${data.telefono}`);
      await fs.marcarError(
        docRef,
        `Teléfono inválido: "${data.telefono}". Esperado E.164 (+5492914567890).`
      );
      return;
    }

    let existe;
    try {
      existe = await wa.tieneWhatsApp(wid);
    } catch (e) {
      log.warn(`Verificación de ${wid} falló (transient): ${e.message}`);
      await docRef.update({ estado: fs.ESTADO.pendiente });
      return;
    }
    if (!existe) {
      log.warn(`${docId}: ${wid} no tiene WhatsApp.`);
      await fs.marcarError(docRef, 'El número no tiene WhatsApp registrado.');
      return;
    }

    // Rate limit por hora (anti-baneo). MAX_MESSAGES_PER_HOUR del .env
    // (default 30). Si ya enviamos ese cap en los últimos 60 min, NO
    // tomamos el lock — dejamos el doc PENDIENTE y reagendamos para
    // cuando se libere un slot. El polling lo va a respetar gracias al
    // proximoIntentoEn que setea marcarReintento.
    const maxPorHora = parseInt(process.env.MAX_MESSAGES_PER_HOUR || '30', 10);
    const msHastaSlot = health.msHastaSlotLibre(maxPorHora);
    if (msHastaSlot > 0) {
      const cuando = new Date(Date.now() + msHastaSlot + 5000); // +5s margen
      await fs.marcarReintento(
        docRef,
        `Rate limit ${maxPorHora}/hora alcanzado`,
        cuando
      );
      log.info(
        `⏳ Rate limit (${health.enviadosUltimaHora()}/${maxPorHora} en última h). ` +
        `${docId} reagendado para ${aLocalDateTime(cuando)}.`
      );
      return;
    }

    // Silencio del chofer (chequeo PRE-lock, post-encolado): cubre el
    // caso donde el mensaje se encolo SIN silencio activo, pero el
    // admin aplico /silenciar despues. El cron diario ya respetaba
    // silenciamiento al encolar, pero los avisos individuales encolados
    // por Cloud Functions (volvo_alert_high, sitrack_chofer_no_id,
    // jornada_v2_*) podian quedar pendientes minutos a horas, ventana
    // donde el silencio pudo haberse activado.
    //
    // Solo aplica si el destinatario es CHOFER (los resumenes a
    // admin/supervisor/seg_higiene NO se silencian — son operativos).
    // Decision Vecchi 2026-05-18 (auditoria 24/7): silenciamiento debe
    // valer en TODOS los paths, incluido consumer-side.
    if (data.destinatario_coleccion === 'EMPLEADOS' && data.destinatario_id) {
      try {
        const silSnap = await db
          .collection('BOT_SILENCIADOS_CHOFER')
          .doc(String(data.destinatario_id))
          .get();
        if (silSnap.exists) {
          const hasta = silSnap.data() && silSnap.data().silenciado_hasta;
          if (hasta && typeof hasta.toMillis === 'function' &&
              hasta.toMillis() > Date.now()) {
            log.info(
              `${docId}: destinatario ${data.destinatario_id} silenciado, ` +
              `skip envio (origen=${data.origen}).`
            );
            // Marcamos el doc como ENVIADO con flag silenciado_skipped
            // para auditoria — NO se manda al chofer, pero queda traza
            // de que se descarto por silencio (no por error). Mantiene
            // consistencia con dedup_skipped (mismo patron).
            await docRef.update({
              estado: fs.ESTADO.enviado,
              enviado_en: admin.firestore.FieldValue.serverTimestamp(),
              silenciado_skipped: true,
            });
            return;
          }
        }
      } catch (e) {
        // Si falla el read NO bloqueamos — peor caso le llega un aviso
        // que el admin pidio silenciar.
        log.warn(`${docId}: no pude leer BOT_SILENCIADOS_CHOFER, sigo: ${e.message}`);
      }
    }

    // Delay anti-bot ANTES del lock (auditoria 2026-05-17): si el bot
    // crashea / es reiniciado durante este sleep (hasta 60s), el doc
    // sigue PENDIENTE y el proximo poll lo agarra inmediato. Antes
    // el delay venia despues del lock → si crasheaba en el sleep, el
    // doc quedaba PROCESANDO y solo el sweeper de 5 min lo repescaba.
    // Para avisos con expira_en corto (vigilador jornada), esos
    // 5 min eran latencia perdida.
    const delay = delayAleatorioMs();

    // Lock atómico: si otra instancia se adelantó (race poco probable
    // ya que el anti-doble-bot debería garantizar single-instance, pero
    // defensa en profundidad), retorna false y skipeamos sin enviar.
    const tomamosElLock = await fs.marcarProcesandoSiPendiente(docRef);
    if (!tomamosElLock) {
      log.debug(`${docId}: otro proceso lo tomó primero, salto.`);
      return;
    }

    // Dedup pre-envío: si en los últimos 5 min ya se envió el MISMO
    // texto al MISMO número, no reenviar. Defensa contra:
    //  - Bugs que doble-encolan (race entre cron y Cloud Function que
    //    encola el mismo aviso por 2 caminos).
    //  - Reintento manual del admin (forzar-cron) cuando ya se mandó.
    //  - Documents huérfanos que se reagregan al recuperar Firestore.
    // Si match: marcar como ENVIADO con flag dedup_skipped + dedup_de
    // (referencia al doc original). NO se manda — el destinatario ya
    // recibió el contenido en los últimos minutos. Mantiene
    // consistencia con el resto del flow (ENVIADO en lugar de un
    // estado nuevo SKIPPED que requeriría cambios en queries).
    const dupId = await _esEnvioDuplicado(db, fs, data);
    if (dupId) {
      await docRef.update({
        estado: fs.ESTADO.enviado,
        enviado_en: admin.firestore.FieldValue.serverTimestamp(),
        dedup_de: dupId,
        dedup_skipped: true,
      });
      log.warn(
        `${docId}: dedup-skipped (mismo texto a ${data.telefono} ` +
        `en últimos 5 min, original ${dupId}).`
      );
      return;
    }

    // Agrupación al envío (consumer-side). Si este doc es de un origen
    // agrupable (volvo_alert_high / volvo_alert_mantenimiento) y hay
    // otros pendientes para el mismo destinatario, los combinamos en
    // UN solo mensaje. El cron interno del bot ya tiene agrupación al
    // ENCOLAR (cron_aviso_agrupado) — este flow cubre lo que viene de
    // Cloud Functions y no pasa por el cron.
    let mensajeFinal = data.mensaje;
    let docsAgrupados = [];
    try {
      const plan = await agrupador.planificarEnvioAgrupado(db, snap);
      if (plan) {
        mensajeFinal = plan.mensajeCombinado;
        docsAgrupados = plan.otrosDocsAgrupados;
        log.info(
          `${docId}: agrupando con ${docsAgrupados.length} otro(s) ` +
          `pendiente(s) del mismo destinatario.`
        );
      }
    } catch (e) {
      // Si el agrupador falla (Firestore down, query rota, lo que sea),
      // mejor mandar el mensaje individual que romper el envío entero.
      log.warn(`${docId}: agrupador falló (envío individual): ${e.message}`);
    }

    log.info(`→ Enviando ${docId} a ${data.telefono} en ${Math.round(delay / 1000)}s...`);
    await sleep(delay);

    // Splitting anti-baneo: WhatsApp puede flaggear mensajes > ~4096
    // chars como spam o rechazarlos. Si el resumen es muy largo (típico
    // del resumen Volvo HIGH a Alejandra cuando hay día con muchos
    // eventos), partimos en chunks de hasta 3500 chars con marcador
    // "(parte i/N)" y delay anti-flood entre envíos. El waMessageId que
    // guardamos es el del PRIMER chunk — el que el chofer ve como
    // "principal" si responde con quote.
    //
    // Auditoria 2026-05-17 (CRITICO): antes si fallaba un chunk en
    // mid-envio (chunk 2 de 3), el catch externo retri-encolaba el doc
    // entero → al proximo poll el destinatario recibia parte 1 + 2 + 3
    // de nuevo (parte 1 duplicada). Fix: marcar ENVIADO apenas el chunk
    // 1 sale OK; si chunks subsiguientes fallan, anotar `chunks_parcial`
    // pero NO retri-encolar — el operador puede ver el campo y decidir.
    const partes = partirMensajeLargo(mensajeFinal);
    let waMessageId = null;
    let chunksEnviados = 0;
    let chunkError = null;
    for (let i = 0; i < partes.length; i++) {
      if (i > 0) {
        // 2-3s entre partes: tiempo realista de un humano que escribió
        // el siguiente chunk. Sin esto, WhatsApp ve N mensajes idénticos
        // de tiempo en milisegundos = patrón de bot.
        await sleep(2000 + Math.floor(Math.random() * 1000));
      }
      try {
        const id = await wa.enviarMensaje(wid, partes[i]);
        if (i === 0) waMessageId = id;
        chunksEnviados++;
      } catch (chunkE) {
        chunkError = chunkE;
        log.error(`✗ Chunk ${i + 1}/${partes.length} de ${docId} falló: ` +
          `${chunkE.message}`);
        break;
      }
    }
    if (partes.length > 1) {
      log.info(
        `  ${docId}: ${chunksEnviados}/${partes.length} chunks enviados ` +
        `(${mensajeFinal.length} chars total)`
      );
    }
    if (chunksEnviados === 0) {
      // No se envio nada — re-tirar para que el catch externo decida.
      throw chunkError || new Error('Sin chunks enviados');
    }
    // Aunque haya habido falla en chunks subsiguientes, marcamos ENVIADO
    // (el chofer ya recibio al menos el primer chunk — re-enviar todo
    // duplicaria el chunk 1).
    const meta = { waMessageId };
    if (chunksEnviados < partes.length) {
      meta.chunksParcial = {
        enviados: chunksEnviados,
        total: partes.length,
        error: chunkError ? chunkError.message : 'desconocido',
      };
      log.warn(`⚠ Mensaje ${docId} parcial: ${chunksEnviados}/${partes.length}`);
      health.registrarError('envio_parcial',
        `${docId}: ${chunksEnviados}/${partes.length}`);
    }
    await fs.marcarEnviado(docRef, meta);

    // Marcar los docs agrupados como ENVIADO con `agrupado_en` apuntando
    // al doc principal — sin reenviar, queda traza para auditoría.
    if (docsAgrupados.length > 0) {
      const batch = db.batch();
      for (const otro of docsAgrupados) {
        batch.update(otro.ref, {
          estado: fs.ESTADO.enviado,
          enviado_en: admin.firestore.FieldValue.serverTimestamp(),
          agrupado_en: docId,
          wa_message_id: waMessageId || null,
        });
      }
      await batch.commit();
      log.info(`  ${docsAgrupados.length} doc(s) marcados como agrupados en ${docId}`);
    }

    health.registrarEnvio();
    log.info(`✓ Enviado ${docId} (wa_id: ${waMessageId || '?'})`);
  } catch (e) {
    log.error(`✗ Falló ${docId}: ${e.message}`);
    health.registrarError('envio', `${docId}: ${e.message}`);
    try {
      await _despacharFalloEnvio(docRef, e);
    } catch (e2) {
      // Si _despacharFalloEnvio falla (típicamente Firestore caído al
      // momento de marcar PENDIENTE/ERROR), el doc queda en estado
      // inconsistente. Antes el bot llamaba `procesarSiguiente()` de
      // inmediato → martillaba Firestore varias veces por segundo. Ahora
      // marcamos la flag para que el `finally` salte la siguiente
      // iteración y deje al polling reintentar dentro de 15s.
      log.error(
        `No se pudo despachar fallo de envío: ${e2.message}. ` +
        `Cortando procesarSiguiente — el polling reintenta en el próximo ciclo.`
      );
      _despachoFalloErrorReciente = Date.now();
    }
  } finally {
    procesando = false;
    // Si hubo fallo en el despacho hace poco, no llamamos
    // procesarSiguiente — esperamos al polling. Esto da tiempo a que
    // Firestore se recupere y evita el loop apretado.
    const haceCuanto = Date.now() - _despachoFalloErrorReciente;
    const recienHuboFallo = haceCuanto < 5000;
    if (!recienHuboFallo && colaProcesar.length > 0) {
      await sleep(500);
      procesarSiguiente();
    }
  }
}

// Timestamp del último fallo en `_despacharFalloEnvio()`. Si fue hace
// menos de 5s, `procesarSiguiente()` corta para no martillar Firestore
// con reintentos sincrónicos. El polling normal (cada 15s) toma el
// relevo. 0 = nunca falló (no hay corte activo).
let _despachoFalloErrorReciente = 0;

/**
 * Detecta si en los últimos `ventanaMin` minutos ya se envió el mismo
 * mensaje al mismo número. Devuelve el doc id del duplicado o `null`
 * si no hay match.
 *
 * Filtro Firestore: telefono + estado=ENVIADO + enviado_en >= cutoff.
 * El match exacto del campo `mensaje` se hace client-side porque
 * Firestore no indexa textos largos eficientemente. La cantidad
 * típica de docs traídos por la query es chica (< 20).
 */
async function _esEnvioDuplicado(db, fs, data, ventanaMin = 5) {
  if (!data || !data.telefono || !data.mensaje) return null;
  const desde = admin.firestore.Timestamp.fromMillis(
    Date.now() - ventanaMin * 60 * 1000
  );
  let snap;
  try {
    snap = await db
      .collection(fs.COLECCION)
      .where('telefono', '==', data.telefono)
      .where('estado', '==', fs.ESTADO.enviado)
      .where('enviado_en', '>=', desde)
      .limit(20)
      .get();
  } catch (e) {
    // Si Firestore falla, el dedup no debe romper el envío. Loguear
    // y seguir — peor caso es un mensaje duplicado, no fatal.
    log.warn(`Dedup query falló: ${e.message}`);
    return null;
  }
  for (const d of snap.docs) {
    const msg = d.data().mensaje;
    if (msg && msg === data.mensaje) return d.id;
  }
  return null;
}

// ─── Polling de COLA_WHATSAPP ───────────────────────────────────────
let _pollingTimer = null;
// Trackea el ultimo estado de horario habil visto por el polling
// para loguear SOLO al cruzar el umbral (no cada 15s). null = primer
// poll de la sesion.
let _ultimoEstadoHorario = null;

// Guard contra overlap del polling: si un ciclo tarda más que
// POLLING_INTERVAL_SECONDS (típicamente 15s, pero Firestore lento puede
// hacer que tarde 30s+), el setInterval dispara uno nuevo antes de que
// termine el anterior → dos pollings concurrentes encolan los mismos
// docs → un doc se procesa dos veces. Esta flag serializa.
let _polleando = false;

const POLL_TIMEOUT_MS = parseInt(
  process.env.POLL_TIMEOUT_MS || '10000',
  10
);

/**
 * Envuelve una promesa con un timeout. Si la promesa no resuelve en
 * `ms`, se rechaza con un error etiquetado. Útil para queries de
 * Firestore que de otro modo podrían quedar colgadas indefinidamente
 * cuando hay problemas de red.
 */
function _withTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(
        () => reject(new Error(`Timeout (${ms}ms): ${label}`)),
        ms
      )
    ),
  ]);
}

async function pollearCola(db) {
  if (_polleando) {
    log.debug('Polling previo aún en curso, skip este ciclo.');
    return;
  }
  _polleando = true;
  try {
    // Sweeper de docs stale en PROCESANDO: si el bot crasheo durante
    // un envio anterior (entre marcarProcesando y marcarEnviado), el
    // doc quedo PROCESANDO y nadie lo repesca. Lo devolvemos a
    // PENDIENTE para que entre al ciclo actual. Corre SIEMPRE -- aun
    // fuera de horario habil queremos mantener el estado de la cola.
    try {
      const recuperados = await _withTimeout(
        fs.recuperarStaleProcesando(db),
        POLL_TIMEOUT_MS,
        'sweeper PROCESANDO'
      );
      if (recuperados > 0) {
        log.warn(`Sweeper: recupere ${recuperados} doc(s) stale en PROCESANDO → PENDIENTE.`);
      }
    } catch (e) {
      log.warn(`Sweeper de PROCESANDO fallo: ${e.message}`);
    }

    // Skip rapido si estamos fuera de horario habil (incluye fines de
    // semana, noches, y feriados nacionales). Sin esto, el polling
    // re-traia el mismo doc PENDIENTE cada 15s y logueaba "Fuera de
    // horario..." en cada vuelta -> ~35K lineas inutiles en un fin
    // de semana largo, que ahogan los logs reales.
    //
    // Loguear solo al cruzar el umbral: cuando entramos a fuera de
    // horario, una linea; cuando volvemos a horario habil, otra.
    const enHorario = enHorarioHabil();
    if (_ultimoEstadoHorario === null) {
      log.info(enHorario
        ? 'Polling: en horario habil -- procesando envios.'
        : 'Polling: fuera de horario habil -- pausa hasta proximo dia habil.');
    } else if (_ultimoEstadoHorario !== enHorario) {
      log.info(enHorario
        ? 'Horario habil reanudado -- polling activo.'
        : 'Fuera de horario habil -- pausa hasta proximo dia habil.');
    }
    _ultimoEstadoHorario = enHorario;
    if (!enHorario) return;

    // FIFO por encolado_en. Sin orderBy explicito Firestore devuelve
    // orden no deterministico — cuando el bot procesa cola acumulada
    // (ej. lunes 8:30 con resumenes de viernes + sabado + domingo
    // pendientes), salian en orden aleatorio y el destinatario veia
    // los resumenes desordenados. Bug reportado 2026-05-11 por Ale.
    // Requiere indice compuesto (estado ASC, encolado_en ASC) en
    // firestore.indexes.json.
    const qs = await _withTimeout(
      db
        .collection(fs.COLECCION)
        .where('estado', '==', fs.ESTADO.pendiente)
        .orderBy('encolado_en', 'asc')
        .get(),
      POLL_TIMEOUT_MS,
      'pollearCola query'
    );
    const ahora = Date.now();
    qs.forEach((doc) => {
      const data = doc.data();
      const prox = data.proximoIntentoEn;
      if (prox) {
        const t = typeof prox.toMillis === 'function'
          ? prox.toMillis()
          : new Date(prox).getTime();
        if (!isNaN(t) && t > ahora) return;
      }
      encolar(doc);
    });
  } catch (e) {
    log.warn(`Polling Firestore falló: ${e.message}`);
  } finally {
    _polleando = false;
  }
}

function iniciarPolling(db) {
  if (_pollingTimer) return;
  const intervaloSeg = parseInt(process.env.POLLING_INTERVAL_SECONDS || '15', 10);
  log.info(`Polling de ${fs.COLECCION} cada ${intervaloSeg}s (modo robusto: sin streams gRPC).`);
  pollearCola(db);
  _pollingTimer = setInterval(() => pollearCola(db), intervaloSeg * 1000);
}

function detenerPolling() {
  if (_pollingTimer) {
    clearInterval(_pollingTimer);
    _pollingTimer = null;
  }
}

// Umbral en segundos para considerar un heartbeat como "fresco".
// Si la otra PC envio heartbeat hace menos que esto, asumimos que
// esta viva. El default es 150s (2.5x el heartbeat default de 60s),
// que da un margen razonable para cubrir un ciclo perdido por red
// o lentitud sin generar falsos positivos.
const UMBRAL_HEARTBEAT_FRESCO_SEG = parseInt(
  process.env.UMBRAL_OTRA_INSTANCIA_SEG || '150',
  10
);

async function _verificarNoHayOtraInstancia(db) {
  if (String(process.env.FORCE_START || '').toLowerCase() === 'true') {
    log.warn('FORCE_START=true -- saltando check de otra instancia.');
    return;
  }

  // Check + claim atómico: usamos transacción para que dos PCs que
  // arranquen casi simultáneamente NO pasen el check ambas. Una gana
  // la transacción y escribe su pcId; la otra ve la escritura ganadora
  // y aborta. Sin transacción había race window de ~100ms en que dos
  // bots procesaban la misma cola → mensajes duplicados → baneo.
  const ref = db.collection('BOT_HEALTH').doc('main');
  let abortInfo = null;

  try {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);

      if (snap.exists) {
        const data = snap.data();
        const ultimoHb = data.ultimoHeartbeat;
        const otroPcId = data.pcId || 'desconocida';
        if (ultimoHb) {
          const ultimoMs = typeof ultimoHb.toMillis === 'function'
            ? ultimoHb.toMillis()
            : new Date(ultimoHb).getTime();
          const segDesdeUltimo = Math.round((Date.now() - ultimoMs) / 1000);
          const fresco = segDesdeUltimo <= UMBRAL_HEARTBEAT_FRESCO_SEG;
          if (fresco && otroPcId !== PC_ID) {
            // Heartbeat fresco de OTRA PC — la otra está viva. Vamos
            // a abortar después de salir de la transacción (no
            // queremos process.exit dentro de una tx).
            abortInfo = { otroPcId, segDesdeUltimo };
            // Lanzamos error para abortar la tx (no queremos escribir).
            throw new Error('OTRA_INSTANCIA_VIVA');
          }
        }
      }

      // Llegamos acá si: no había doc, no había heartbeat, el heartbeat
      // estaba viejo (otra PC muerta), o el heartbeat era nuestro
      // (somos nosotros reiniciado). En todos los casos, claimeamos el
      // lock escribiendo nuestro pcId con un heartbeat fresco. Si dos
      // PCs llegan acá simultáneamente, Firestore detecta conflicto en
      // commit y reintenta — la perdedora va a ver el heartbeat de la
      // ganadora y entrar al branch de abort.
      tx.set(
        ref,
        {
          pcId: PC_ID,
          ultimoHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
          estadoCliente: 'INICIANDO',
          ultimoStartup: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    });
  } catch (e) {
    if (abortInfo) {
      // Branch de abort: hay otra PC viva. Mostramos mensaje claro y
      // exit(1). NSSM se va a quedar quieto (NO reinicia indefinidamente
      // porque el exit es deliberado, no por crash).
      log.error(
        `\nABORTANDO: el bot YA esta corriendo en otra PC.\n\n` +
        `  PC remota:        ${abortInfo.otroPcId}\n` +
        `  Mi PC:            ${PC_ID}\n` +
        `  Ultimo heartbeat: hace ${abortInfo.segDesdeUltimo}s\n` +
        `  Umbral:           ${UMBRAL_HEARTBEAT_FRESCO_SEG}s\n\n` +
        `Para evitar que dos bots procesen la misma cola y dupliquen ` +
        `mensajes (riesgo de baneo de WhatsApp), no arranco.\n\n` +
        `Soluciones:\n` +
        `  1. Detener el bot en "${abortInfo.otroPcId}" (recomendado).\n` +
        `  2. Si sabes que esa PC esta muerta y el heartbeat es residual, ` +
        `seteá FORCE_START=true en .env y reintentá.\n`
      );
      process.exit(1);
    }
    // Otro error de transacción (red, rules, conflicto irrecuperable) —
    // arrancamos igual. Mejor un bot arrancando con riesgo bajo de
    // duplicado que un bot bloqueado por una falla intermitente.
    log.warn(
      `Error en transacción de check de instancia: ${e.message}. ` +
      `Arrancando igual (best-effort).`
    );
  }
}

async function main() {
  log.info(`Iniciando whatsapp-bot (PC_ID=${PC_ID})...`);
  // Orden importa: matar procesos primero (al morir dejan locks frescos),
  // limpiar locks Singleton* después.
  matarProcesosChromiumZombi();
  limpiarLocksChromium();

  const db = fs.inicializar();

  // ─── Check anti-doble-bot ────────────────────────────────────────
  // Antes de inicializar WhatsApp Web (lo mas pesado y lo que dispara
  // un linkeo de dispositivo), verificamos que no haya OTRA PC ya
  // corriendo el bot. El criterio es: si el ultimo heartbeat de
  // BOT_HEALTH/main es de hace menos de UMBRAL_FRESCO segundos Y el
  // pcId del heartbeat es DISTINTO al nuestro, asumimos que esta otra
  // PC esta procesando la cola y abortamos. Si es del mismo pcId
  // (yo, simplemente reiniciado), o no hay heartbeat reciente, sigo.
  //
  // Bypass: setear FORCE_START=true en .env si querias arrancar igual
  // (util para casos raros tipo "la otra PC se colgo y yo se que esta
  // muerta aunque el heartbeat sea reciente").
  await _verificarNoHayOtraInstancia(db);

  log.info('Conectando a WhatsApp Web — esto puede demorar 10-30s...');
  await wa.inicializar();

  iniciarPolling(db);

  // Inicializar lectura del kill-switch BOT_CONTROL/main.
  control.inicializar(db);

  health.iniciar(db, fs, wa);

  cron.start(fs);

  // Backup automático de .wwebjs_auth/ a Cloud Storage. Opt-in via
  // WWEBJS_BACKUP_ENABLED en .env. Si está apagado, no hace nada.
  // Frecuencia configurable (default 24h) + retención automática.
  backupAuth.iniciar(db);

  // Handler de mensajes entrantes — registrado SIEMPRE para que los
  // comandos admin (/estado, /pausar, etc) funcionen aunque
  // AUTO_RESPUESTAS_ENABLED esté en false. La lógica de Fase 3
  // (respuestas de choferes que se convierten en revisiones) es lo
  // que se gatea por el flag — no la captura del mensaje.
  const respuestasHabilitado =
    String(process.env.AUTO_RESPUESTAS_ENABLED || 'false').toLowerCase() === 'true';
  log.info(
    respuestasHabilitado
      ? 'Handler de mensajes entrantes: comandos admin + Fase 3.'
      : 'Handler de mensajes entrantes: solo comandos admin (Fase 3 deshabilitada).'
  );
  wa.onMensajeEntrante(messageHandler.crearHandler(fs, wa));

  const delayMaxMs = parseInt(process.env.DELAY_MAX_MS || '60000', 10);
  const graceMs = delayMaxMs + 10000;

  const shutdown = async (sig) => {
    log.info(`Recibido ${sig}, cerrando (grace ${Math.round(graceMs / 1000)}s)...`);
    detenerPolling();
    cron.stop();
    health.detener();

    // Auditoria 2026-05-17: ademas del envio en curso, esperamos al
    // cron. Si Restart-Service cae mid-cron (batch.commit en vuelo),
    // el process.exit lo aborta y los encolados quedan sin registrar
    // en AVISOS_AUTOMATICOS_HISTORICO → proximo ciclo los re-encola.
    const start = Date.now();
    while (
      (procesando || cron.isRunning()) &&
      Date.now() - start < graceMs
    ) {
      await sleep(200);
    }
    if (procesando) {
      log.warn(
        'Grace period agotado con un envío en curso. ' +
        'El doc queda en PROCESANDO; revisalo manualmente al reiniciar.'
      );
    } else if (cron.isRunning()) {
      log.warn(
        'Grace period agotado con cron en ejecución. ' +
        'Algunos avisos pueden no haberse registrado.'
      );
    } else {
      log.info('Cola en pausa, sin envíos ni cron en curso.');
    }

    await wa.destroy();
    process.exit(0);
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

// Guard `require.main === module` (auditoria 2026-05-18): solo
// arranca `main()` si el archivo se ejecuta como entrypoint
// (`node src/index.js` o NSSM). Si alguien lo importa con
// `require('./src/index.js')` para tests / lint / parse-check, NO
// se inicializa el bot — antes un `node -e "require(...)"` para
// verificar sintaxis booteaba todo el bot (WhatsApp Web + cron +
// heartbeat) y dejaba el proceso vivo escribiendo heartbeats al
// Firestore (incidente 2026-05-18).
if (require.main === module) {
  main().catch((e) => {
    log.error(`Fatal: ${e.stack || e.message}`);
    process.exit(1);
  });
}
