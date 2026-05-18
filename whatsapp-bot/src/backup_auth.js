// Backup automático de la carpeta `.wwebjs_auth/` (sesión QR de
// WhatsApp Web) a Cloud Storage.
//
// Por qué importa: si la PC donde corre el bot se rompe físicamente,
// la sesión local se pierde y hay que volver a escanear el QR desde
// el celular dedicado del bot. Con backups automáticos en Cloud
// Storage, se baja el último zip a otra PC, se descomprime en
// `.wwebjs_auth/`, y el bot reconecta sin nuevo escaneo.
//
// Decisión Santiago 2026-05-09: opt-in via WWEBJS_BACKUP_ENABLED=true
// en .env. Si está apagado, no se hace nada.
//
// Cómo funciona:
//   1. Cada WWEBJS_BACKUP_INTERVAL_HOURS (default 24h), comprime la
//      carpeta `.wwebjs_auth/` (relativa al cwd del bot, igual que la
//      lib whatsapp-web.js la lee) a un .zip en memoria.
//   2. Sube el zip a Cloud Storage en
//      `gs://{BUCKET}/wwebjs_auth/{pcId}_{YYYY-MM-DD-HHmm}.zip`.
//      El bucket por default es `coopertrans-movil-backups` (mismo
//      que usa `backupFirestoreScheduled`).
//   3. Limpia backups antiguos (> WWEBJS_BACKUP_RETENTION_DAYS).
//
// Seguridad: el bucket es privado por default (solo accede el service
// account del proyecto). El zip NO está cifrado adicionalmente — si
// querés capa extra, encriptar con AES antes de subir.
//
// Si el backup falla (red, permisos, falta archiver), loguea WARN y
// sigue. El bot no se rompe por un backup roto.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');
const admin = require('firebase-admin');
const log = require('./logger');

const execFileAsync = promisify(execFile);

let _timer = null;
let _initialTimer = null;  // Fix L2 24/7: capturamos el setTimeout
                            // inicial (10 min) para poder cancelarlo
                            // si llaman `detener()` antes del primer backup.
let _db = null; // No se usa hoy pero queda por si en futuro queremos persistir metadata.

/**
 * Inicia el job de backup. Si `WWEBJS_BACKUP_ENABLED` no es 'true',
 * sale en silencio (feature opt-in).
 *
 * Hace el primer backup ~10 min después del arranque (no inmediato:
 * dejamos que el bot estabilice primero) y después cada N horas.
 */
function iniciar(db) {
  _db = db || null;
  const enabled =
    String(process.env.WWEBJS_BACKUP_ENABLED || 'false').toLowerCase() === 'true';
  if (!enabled) {
    log.info(
      'Backup .wwebjs_auth/ DESHABILITADO (WWEBJS_BACKUP_ENABLED=false). ' +
      'Para activar, setear true en .env y reiniciar.'
    );
    return;
  }
  if (_timer) return;

  const intervaloHs = parseFloat(
    process.env.WWEBJS_BACKUP_INTERVAL_HOURS || '24'
  );
  const intervaloMs = intervaloHs * 60 * 60 * 1000;
  // Primer backup en 10 min — dejamos que el bot autentique y termine
  // de arrancar antes de hacer trabajo de I/O pesado.
  const primerDelayMs = 10 * 60 * 1000;

  log.info(
    `Backup .wwebjs_auth/ ACTIVO. Primer backup en ${primerDelayMs / 60000} min, ` +
    `después cada ${intervaloHs}h.`
  );

  _initialTimer = setTimeout(() => {
    _initialTimer = null;
    _ejecutarBackup().catch((e) => {
      log.warn(`Primer backup .wwebjs_auth/ falló: ${e.message}`);
    });
    _timer = setInterval(() => {
      _ejecutarBackup().catch((e) => {
        log.warn(`Backup .wwebjs_auth/ falló: ${e.message}`);
      });
    }, intervaloMs);
  }, primerDelayMs);
}

function detener() {
  // Fix L2 24/7 (2026-05-18): cancelar tambien el setTimeout
  // inicial. Si detener() se llama dentro de los 10 min de
  // primerDelayMs, antes solo cancelabamos _timer (que aun no
  // existia) y dejabamos el setTimeout pendiente -> el primer
  // backup se disparaba igual + arrancaba _timer despues del
  // shutdown.
  if (_initialTimer) {
    clearTimeout(_initialTimer);
    _initialTimer = null;
  }
  if (_timer) {
    clearInterval(_timer);
    _timer = null;
  }
}

/**
 * Comprime y sube un backup. Si la carpeta no existe (todavía no
 * autenticó), saltea silenciosamente.
 */
async function _ejecutarBackup() {
  const carpetaAuth = path.resolve(process.cwd(), '.wwebjs_auth');
  if (!fs.existsSync(carpetaAuth)) {
    log.debug(`.wwebjs_auth/ no existe en ${carpetaAuth}, skip backup.`);
    return;
  }

  // Importamos `archiver` solo cuando el feature está activo. Si no
  // está instalado y el feature está apagado, el bot arranca sin
  // problemas.
  let archiver;
  try {
    archiver = require('archiver');
  } catch (e) {
    log.warn(
      "Backup .wwebjs_auth/ no se puede ejecutar: falta dependencia " +
      "`archiver`. Correr `npm install archiver` en whatsapp-bot/ y " +
      'reiniciar.'
    );
    return;
  }

  const bucketName =
    process.env.WWEBJS_BACKUP_BUCKET || 'coopertrans-movil-backups';
  const pcId = process.env.BOT_PC_ID || 'desconocida';

  // Nombre del archivo: {pcId}_{YYYY-MM-DD-HHmm}.zip en TZ ART para
  // que el orden lexicográfico coincida con el cronológico real.
  const nombreArchivo = _construirNombre(pcId);
  const objectPath = `wwebjs_auth/${nombreArchivo}`;

  log.info(`Backup .wwebjs_auth/ → gs://${bucketName}/${objectPath} ...`);

  const inicio = Date.now();
  const buffer = await _comprimirCarpeta(archiver, carpetaAuth);

  const bucket = admin.storage().bucket(bucketName);
  const file = bucket.file(objectPath);
  await file.save(buffer, {
    contentType: 'application/zip',
    resumable: false,
    metadata: {
      metadata: {
        pcId,
        fechaIso: new Date().toISOString(),
        bot_version: require('../package.json').version || 'desconocida',
      },
    },
  });

  const duracionSeg = Math.round((Date.now() - inicio) / 100) / 10;
  log.info(
    `✓ Backup .wwebjs_auth/ subido (${(buffer.length / 1024 / 1024).toFixed(1)} MB, ${duracionSeg}s).`
  );

  // Limpieza de backups viejos (best-effort). Si falla, no rompe el
  // backup actual — el siguiente ciclo lo intenta de nuevo.
  try {
    await _limpiarBackupsAntiguos(bucket, pcId);
  } catch (e) {
    log.warn(`Cleanup backups viejos falló: ${e.message}`);
  }
}

/**
 * Nombres de directorios (no globs) cuyos contenidos no incluimos
 * en el backup. Son caches volátiles del Chromium embebido que
 * whatsapp-web.js usa internamente: están locked mientras el bot
 * corre, y se regeneran solos en el próximo arranque.
 *
 * Match: si el path relativo del archivo CONTIENE un segmento con
 * cualquiera de estos nombres, se skipea. Sin globs porque algunos
 * caches anidan distinto en versiones distintas de Chromium.
 */
const DIRS_EXCLUIDOS = new Set([
  'Cache',
  'Cache_Data',
  'Code Cache',
  'GPUCache',
  'ShaderCache',
  'GraphiteDawnCache',
  'component_crx_cache',
  'CacheStorage',
  'ScriptCache',
  'Network',
  // 'optimization_guide_*' — match por prefix abajo
]);

/**
 * Comprime una carpeta a un Buffer en memoria, tolerando archivos
 * que estén locked (EBUSY) o desaparecidos durante el walk.
 *
 * Estrategia (decisión 2026-05-09):
 *   1. Caminamos el árbol manualmente con `fs.readdir`.
 *   2. Cada archivo se lee con `readFile` y se agrega al zip.
 *   3. Si un archivo falla con EBUSY, EACCES, ENOENT, etc. — log
 *      a DEBUG y SKIP. El zip sigue construyéndose.
 *   4. Skipeamos directorios cuyos nombres están en DIRS_EXCLUIDOS
 *      (caches del Chromium) — ahorra trabajo + evita locks típicos.
 *
 * Por qué este approach en lugar de `archive.directory()` o
 * `archive.glob()`:
 *   - archive.directory hace stream de cada archivo. Si uno tira
 *     EBUSY, archiver emite 'error' y el zip entero aborta. No
 *     hay forma estándar de continuar.
 *   - archive.glob tiene el mismo problema con archivos locked.
 *   - Manual walking + readFile permite try/catch por archivo y
 *     archive.append(buffer) en lugar de stream — desacopla la
 *     lectura de la escritura del zip.
 *
 * `.wwebjs_auth/` típicamente queda en < 30 MB después de excluir
 * caches.
 */
async function _comprimirCarpeta(archiver, carpeta) {
  const archive = archiver('zip', { zlib: { level: 9 } });
  const chunks = [];
  const skipped = [];

  archive.on('data', (chunk) => chunks.push(chunk));
  archive.on('warning', (e) => {
    log.debug(`archiver warning: ${e.message}`);
  });

  const finalPromise = new Promise((resolve, reject) => {
    archive.on('error', reject);
    archive.on('end', () => {
      if (skipped.length > 0) {
        log.info(
          `Backup .wwebjs_auth/: ${skipped.length} archivo(s) locked ` +
          `skipeados (caches volátiles del Chromium).`
        );
      }
      resolve(Buffer.concat(chunks));
    });
  });

  await _walkAndAppend(archive, carpeta, '', skipped);
  archive.finalize();

  return finalPromise;
}

/**
 * Caminata recursiva tolerante a errores. Para cada archivo: intenta
 * leer y agregar al archivo zip. Si falla (locked, permisos, race
 * con borrado), lo skipea y sigue.
 */
async function _walkAndAppend(archive, dirAbs, relBase, skipped) {
  let entries;
  try {
    entries = await fs.promises.readdir(dirAbs, { withFileTypes: true });
  } catch (e) {
    skipped.push(`(readdir ${e.code}) ${relBase || '.'}`);
    return;
  }
  for (const ent of entries) {
    const fullAbs = path.join(dirAbs, ent.name);
    const rel = relBase ? `${relBase}/${ent.name}` : ent.name;

    if (ent.isDirectory()) {
      // Skip de directorios excluidos por nombre exacto + prefix
      // para optimization_guide_* (Chromium 117+).
      if (
        DIRS_EXCLUIDOS.has(ent.name) ||
        ent.name.startsWith('optimization_guide_')
      ) {
        continue;
      }
      await _walkAndAppend(archive, fullAbs, rel, skipped);
    } else if (ent.isFile()) {
      try {
        const data = await fs.promises.readFile(fullAbs);
        archive.append(data, { name: rel });
      } catch (e) {
        // EBUSY (locked), EACCES (permisos), ENOENT (race con borrado),
        // EPERM (Windows particular), EMFILE (too many files), etc.
        // En todos los casos: skip y seguir.
        skipped.push(`(${e.code || 'ERR'}) ${rel}`);
      }
    }
    // Otros tipos (symlinks, devices) los ignoramos silenciosamente.
  }
}

function _construirNombre(pcId) {
  // YYYY-MM-DD-HHmm en ART (ordenable lexicográficamente).
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Argentina/Buenos_Aires',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
  const parts = fmt.formatToParts(new Date());
  const y = parts.find((p) => p.type === 'year').value;
  const m = parts.find((p) => p.type === 'month').value;
  const d = parts.find((p) => p.type === 'day').value;
  const hh = parts.find((p) => p.type === 'hour').value;
  const mm = parts.find((p) => p.type === 'minute').value;
  // Sanitizar pcId (sin caracteres raros para nombres de archivo).
  const pcSafe = String(pcId).replace(/[^a-zA-Z0-9_-]/g, '_');
  return `${pcSafe}_${y}-${m}-${d}-${hh}${mm}.zip`;
}

/**
 * Borra backups del MISMO pcId con > retentionDays días. Mantiene el
 * historial de OTRAS PCs intacto (cada PC limpia los suyos al hacer
 * su backup — funciona aunque las PCs alternen).
 */
async function _limpiarBackupsAntiguos(bucket, pcId) {
  const retentionDays = parseInt(
    process.env.WWEBJS_BACKUP_RETENTION_DAYS || '30', 10
  );
  const cutoffMs = Date.now() - retentionDays * 24 * 60 * 60 * 1000;
  const prefijo = `wwebjs_auth/${String(pcId).replace(/[^a-zA-Z0-9_-]/g, '_')}_`;

  const [files] = await bucket.getFiles({ prefix: prefijo });
  let borrados = 0;
  for (const f of files) {
    // Preferimos timeCreated del metadata (cuando GCS recibió el
    // archivo) — invariante a TZ y siempre presente.
    const created = f.metadata && f.metadata.timeCreated
      ? new Date(f.metadata.timeCreated).getTime()
      : 0;
    if (created > 0 && created < cutoffMs) {
      try {
        await f.delete();
        borrados++;
      } catch (e) {
        log.debug(`No se pudo borrar ${f.name}: ${e.message}`);
      }
    }
  }
  if (borrados > 0) {
    log.info(
      `Backups .wwebjs_auth/ viejos borrados: ${borrados} (> ${retentionDays} días).`
    );
  }
}

// ============================================================================
// RESTORE — bajar el ultimo backup del bucket y restaurar `.wwebjs_auth/`
// ============================================================================
//
// Critico para el setup 24/7 en PC dedicada: si `.wwebjs_auth/` se corrompio
// (restart abrupto, disk full, whatsapp web revoco la session, etc.), al
// arrancar el bot intentamos restaurar el ultimo backup del bucket ANTES de
// inicializar whatsapp-web.js. Si el restore es exitoso, el bot reconecta
// sin pedir QR.
//
// Usa `Expand-Archive` de PowerShell (built-in Windows, no requiere npm
// install adicional — `archiver` solo comprime, no descomprime).
//
// Si el restore falla (sin backups en el bucket, zip corrupto, sin red),
// loguea WARN y el bot va a pedir QR como antes — fallback seguro.

/**
 * Baja el ultimo backup `.wwebjs_auth/` del bucket para el `pcId` dado y
 * lo descomprime sobre la carpeta `.wwebjs_auth/` local.
 *
 * @param {object} [opts]
 * @param {string} [opts.pcId] - override de BOT_PC_ID
 * @returns {Promise<boolean>} true si restauro OK, false si no hay backup
 *   o si el restore fallo (loguea internamente).
 */
async function restaurarUltimoBackup({ pcId } = {}) {
  const bucketName =
    process.env.WWEBJS_BACKUP_BUCKET || 'coopertrans-movil-backups';
  const pcSafe = String(pcId || process.env.BOT_PC_ID || 'desconocida')
    .replace(/[^a-zA-Z0-9_-]/g, '_');
  const prefijo = `wwebjs_auth/${pcSafe}_`;

  try {
    const bucket = admin.storage().bucket(bucketName);
    const [files] = await bucket.getFiles({ prefix: prefijo });

    if (files.length === 0) {
      log.warn(
        `Restore .wwebjs_auth/: sin backups en gs://${bucketName}/${prefijo}*. ` +
        `Bot va a pedir QR.`
      );
      return false;
    }

    // Ordenar por timeCreated descendente (mas reciente primero).
    files.sort((a, b) => {
      const ta = a.metadata?.timeCreated
        ? new Date(a.metadata.timeCreated).getTime() : 0;
      const tb = b.metadata?.timeCreated
        ? new Date(b.metadata.timeCreated).getTime() : 0;
      return tb - ta;
    });
    const ultimo = files[0];
    const tamMb = ultimo.metadata?.size
      ? (parseInt(ultimo.metadata.size, 10) / 1024 / 1024).toFixed(1)
      : '?';

    log.info(
      `Restaurando .wwebjs_auth/ desde gs://${bucketName}/${ultimo.name} ` +
      `(${tamMb} MB, creado ${ultimo.metadata?.timeCreated || '?'})...`
    );

    // Bajar a archivo temporal.
    const tempZip = path.join(
      os.tmpdir(),
      `wwebjs_restore_${Date.now()}_${process.pid}.zip`
    );
    await ultimo.download({ destination: tempZip });

    const carpetaAuth = path.resolve(process.cwd(), '.wwebjs_auth');

    // Si ya existe la carpeta (corrupta), moverla a un .corrupt.<ts>
    // para no perder datos por si el restore tambien falla. Limpieza
    // manual despues si todo OK.
    if (fs.existsSync(carpetaAuth)) {
      const corruptPath = `${carpetaAuth}.corrupt.${Date.now()}`;
      log.warn(
        `.wwebjs_auth/ existe pero pidio restore. Lo muevo a ` +
        `${path.basename(corruptPath)} para no perder datos.`
      );
      try {
        fs.renameSync(carpetaAuth, corruptPath);
      } catch (e) {
        log.warn(
          `No pude mover .wwebjs_auth/ corrupta: ${e.message}. ` +
          `Intentando borrar...`
        );
        try {
          fs.rmSync(carpetaAuth, { recursive: true, force: true });
        } catch (e2) {
          log.error(
            `Tampoco pude borrar .wwebjs_auth/ vieja: ${e2.message}. ` +
            `Aborto restore para no romper estado parcial.`
          );
          try { fs.unlinkSync(tempZip); } catch { /* ignore */ }
          return false;
        }
      }
    }

    fs.mkdirSync(carpetaAuth, { recursive: true });

    // Expand-Archive de PowerShell. Built-in en Windows desde 5.0+.
    // Output redirect a NUL (Windows) para no spamear stderr.
    await execFileAsync(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        `Expand-Archive -Path '${tempZip}' -DestinationPath '${carpetaAuth}' -Force`,
      ],
      { timeout: 120000 } // 2 min max
    );

    // Limpiar zip temporal.
    try { fs.unlinkSync(tempZip); } catch { /* ignore */ }

    // Verificacion minima: la carpeta tiene que tener archivos.
    const entries = fs.readdirSync(carpetaAuth);
    if (entries.length === 0) {
      log.warn(
        `Restore termino pero .wwebjs_auth/ quedo vacia. ` +
        `Bot va a pedir QR.`
      );
      return false;
    }

    log.info(
      `✓ Restore OK: .wwebjs_auth/ con ${entries.length} entries top-level. ` +
      `whatsapp-web.js deberia reconectar sin QR.`
    );
    return true;
  } catch (e) {
    log.warn(
      `Restore .wwebjs_auth/ fallo: ${e.message}. Bot va a pedir QR.`
    );
    return false;
  }
}

/**
 * Ejecuta un backup AHORA (sincronico desde el caller). Usado por el
 * shutdown handler del bot para guardar el ultimo estado bueno antes
 * de cerrar el cliente — minimiza el riesgo de que un restart agresivo
 * deje `.wwebjs_auth/` corrupta entre 2 backups del timer normal (24h).
 *
 * Igual que el backup periodico, si falla loguea WARN y no tira.
 */
async function ejecutarBackupAhora() {
  try {
    await _ejecutarBackup();
    return true;
  } catch (e) {
    log.warn(`Backup pre-shutdown fallo: ${e.message}`);
    return false;
  }
}

module.exports = {
  iniciar,
  detener,
  restaurarUltimoBackup,
  ejecutarBackupAhora,
  // Exportados para tests.
  _construirNombre,
};
