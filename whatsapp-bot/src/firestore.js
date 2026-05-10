// Inicialización del Firebase Admin SDK + helpers para la cola.

const admin = require('firebase-admin');
const path = require('path');
const fs = require('fs');
const log = require('./logger');

let inicializado = false;

/**
 * Levanta el SDK con el service account configurado en `.env`. La ruta
 * puede ser relativa al CWD donde se ejecuta `npm start` (típicamente
 * `whatsapp-bot/`).
 */
function inicializar() {
  if (inicializado) return admin.firestore();

  const credPath =
    process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
  const absPath = path.resolve(credPath);

  if (!fs.existsSync(absPath)) {
    throw new Error(
      `Firebase credentials no encontradas en: ${absPath}\n` +
        '→ Ajustar FIREBASE_CREDENTIALS_PATH en .env'
    );
  }

  const serviceAccount = require(absPath);
  // El bucket por default de Firebase es `<projectId>.appspot.com`
  // (legacy) o `<projectId>.firebasestorage.app` en proyectos nuevos.
  // Tomamos el que esté en el `.env` si lo hay, sino caemos al pattern
  // legacy que es el que usa el resto de la app Flutter.
  const projectId =
    process.env.FIREBASE_PROJECT_ID || serviceAccount.project_id;
  const storageBucket =
    process.env.FIREBASE_STORAGE_BUCKET || `${projectId}.appspot.com`;
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
    projectId,
    storageBucket,
  });
  inicializado = true;
  log.info(
    `Firebase Admin inicializado (project: ${projectId}, ` +
      `bucket: ${storageBucket})`
  );
  return admin.firestore();
}

/**
 * Sube `bytes` (Buffer) a Firebase Storage en `path` y devuelve la
 * URL pública signed para que la app pueda mostrar el archivo desde
 * cualquier cliente sin token de auth.
 *
 * Usar con `RESPUESTAS_BOT/{dni}_{timestamp}.{ext}` para mantener
 * todos los archivos del bot bajo un mismo prefijo en el bucket.
 */
async function subirAStorage({ path, bytes, contentType }) {
  if (!inicializado) inicializar();
  const bucket = admin.storage().bucket();
  const file = bucket.file(path);
  await file.save(bytes, {
    contentType: contentType || 'application/octet-stream',
    resumable: false, // archivos chicos, no necesitamos chunked upload
  });
  // makePublic() convierte el archivo en world-readable. Equivalente
  // a la URL firmada que devuelve `getDownloadURL` desde el SDK
  // cliente — la app Flutter ya está acostumbrada a usar URLs públicas
  // (todas las que llegan vía StorageService son así).
  await file.makePublic();
  return `https://storage.googleapis.com/${bucket.name}/${encodeURIComponent(
    path
  )}`;
}

/**
 * Constantes de la colección y los estados del workflow. Mantener
 * sincronizadas con `lib/features/whatsapp_bot/services/...` en la app
 * Flutter.
 */
const COLECCION = 'COLA_WHATSAPP';

const ESTADO = {
  pendiente: 'PENDIENTE',
  procesando: 'PROCESANDO',
  enviado: 'ENVIADO',
  error: 'ERROR',
};

/** Marca un doc como en proceso de envío (transitorio). */
async function marcarProcesando(docRef) {
  await docRef.update({
    estado: ESTADO.procesando,
    intentos: admin.firestore.FieldValue.increment(1),
    procesando_en: admin.firestore.FieldValue.serverTimestamp(),
  });
}

/**
 * Versión transaccional de marcarProcesando: verifica DENTRO de una
 * transacción que el doc sigue en estado PENDIENTE antes de marcarlo
 * PROCESANDO. Si en el medio (entre la lectura del polling y este
 * call) otro proceso lo cambió, retorna false y el caller skipea.
 *
 * Útil para evitar race condition cuando hay dos PCs corriendo y
 * ambas leen el mismo doc PENDIENTE casi al mismo tiempo. Sin esto,
 * ambas marcaban PROCESANDO y las dos enviaban el mensaje (chofer
 * recibe duplicado, riesgo de baneo de WhatsApp).
 *
 * Retry defensivo: el `runTransaction` de Firebase Admin ya reintenta
 * automáticamente conflictos de versión (hasta 5 veces internas), pero
 * NO reintenta errores transient de red (DEADLINE_EXCEEDED,
 * UNAVAILABLE). Si la transacción tira por red, sin este wrapper el
 * caller lo trata como error fatal y el doc queda sin procesar hasta
 * el próximo polling. Acá hacemos hasta 3 reintentos con backoff
 * (200ms / 500ms / 1000ms) y solo después propagamos el error.
 *
 * @returns {Promise<boolean>} true si tomamos el lock, false si otro
 *   proceso ya lo tenía o el doc ya no está PENDIENTE.
 */
async function marcarProcesandoSiPendiente(docRef) {
  const db = docRef.firestore;
  const maxIntentos = 3;
  const backoffMs = [200, 500, 1000];
  let ultimoError = null;
  for (let intento = 0; intento < maxIntentos; intento++) {
    try {
      return await db.runTransaction(async (tx) => {
        const snap = await tx.get(docRef);
        if (!snap.exists) return false;
        if (snap.data().estado !== ESTADO.pendiente) return false;
        tx.update(docRef, {
          estado: ESTADO.procesando,
          intentos: admin.firestore.FieldValue.increment(1),
          procesando_en: admin.firestore.FieldValue.serverTimestamp(),
        });
        return true;
      });
    } catch (e) {
      ultimoError = e;
      const code = (e && e.code) || '';
      const msg = (e && e.message) || '';
      // Solo reintentamos errores claramente transient; errores de
      // permisos, validación o lógicos los propagamos sin demora.
      const esTransient =
        code === 4 || // DEADLINE_EXCEEDED
        code === 14 || // UNAVAILABLE
        code === 10 || // ABORTED (raro acá porque runTransaction ya retry interno)
        /deadline.exceeded|unavailable|aborted|network|timeout/i.test(msg);
      if (!esTransient || intento === maxIntentos - 1) {
        throw e;
      }
      log.warn(
        `marcarProcesandoSiPendiente fallo transient (intento ${intento + 1}/${maxIntentos}): ${msg}`
      );
      await new Promise((r) => setTimeout(r, backoffMs[intento]));
    }
  }
  // Inalcanzable, pero defensivo.
  throw ultimoError || new Error('marcarProcesandoSiPendiente: error desconocido');
}

/**
 * Marca un doc como enviado exitosamente. Si se pasa el [waMessageId]
 * (id devuelto por wwebjs al enviar) lo guardamos para asociar
 * después las respuestas que cite ese mensaje (Fase 3).
 */
async function marcarEnviado(docRef, { waMessageId } = {}) {
  await docRef.update({
    estado: ESTADO.enviado,
    enviado_en: admin.firestore.FieldValue.serverTimestamp(),
    error: null,
    wa_message_id: waMessageId || null,
  });
}

/** Marca un doc con error y guarda el detalle para que lo vea el admin. */
async function marcarError(docRef, mensaje) {
  const error = String(mensaje).slice(0, 500);
  await docRef.update({
    estado: ESTADO.error,
    error,
    error_en: admin.firestore.FieldValue.serverTimestamp(),
    // Histórico de errores: arrayUnion suma el error con timestamp ISO
    // sin sobrescribir los anteriores. Útil cuando un doc tuvo varios
    // reintentos transitorios antes de fallar — el campo `error` solo
    // muestra el último, pero `historial_errores` deja la traza
    // completa. Cada entrada es {msg, at} (at en ISO local).
    historial_errores: admin.firestore.FieldValue.arrayUnion({
      msg: error,
      at: new Date().toISOString(),
    }),
  });
}

/**
 * Marca un doc para reintento: lo deja en PENDIENTE con un timestamp
 * futuro `proximoIntentoEn`. El polling de COLA_WHATSAPP filtra por
 * ese campo y solo encola docs cuyo `proximoIntentoEn` ya pasó.
 *
 * `intentos` ya fue incrementado por `marcarProcesando` antes del
 * intento que falló — acá no lo tocamos. El error se guarda como `error`
 * para que el admin vea por qué lo dejamos en cola otra vez.
 *
 * @param {FirebaseFirestore.DocumentReference} docRef
 * @param {string} mensajeError - texto del error para mostrar al admin.
 * @param {Date}   cuandoReintentar - fecha futura del próximo intento.
 */
async function marcarReintento(docRef, mensajeError, cuandoReintentar) {
  const err = String(mensajeError).slice(0, 500);
  await docRef.update({
    estado: ESTADO.pendiente,
    error: err,
    error_en: admin.firestore.FieldValue.serverTimestamp(),
    proximoIntentoEn: admin.firestore.Timestamp.fromDate(cuandoReintentar),
    historial_errores: admin.firestore.FieldValue.arrayUnion({
      msg: err,
      at: new Date().toISOString(),
    }),
  });
}

/**
 * Recupera docs que quedaron stale en PROCESANDO. Caso tipico:
 * el bot crashea entre `marcarProcesando` y `enviarMensaje` (o entre
 * `enviarMensaje` y `marcarEnviado`). NSSM lo reinicia, pero el polling
 * solo trae docs PENDIENTE asi que el doc queda en PROCESANDO para
 * siempre y el mensaje se pierde sin alerta.
 *
 * Este sweeper detecta docs en PROCESANDO con `procesando_en` mas
 * antiguo que `umbralMs` (default 5 min) y los devuelve a PENDIENTE
 * para que el polling los retome. Conservador: si el doc no tiene
 * timestamp valido, no lo toca (defensivo, evita corromper algo raro).
 *
 * Filtramos localmente por timestamp en lugar de combinarlo con un
 * `where('procesando_en', '<', cutoff)` para no requerir indice
 * compuesto -- la cantidad de docs PROCESANDO en un momento dado es
 * 0 o 1 en condiciones normales, asi que el filtro local es trivial.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {number} umbralMs - default 5 minutos.
 * @returns {Promise<number>} cantidad de docs recuperados.
 */
async function recuperarStaleProcesando(db, umbralMs = 5 * 60 * 1000) {
  const cutoffMs = Date.now() - umbralMs;
  const snap = await db
    .collection(COLECCION)
    .where('estado', '==', ESTADO.procesando)
    .get();
  if (snap.empty) return 0;

  let recuperados = 0;
  const batch = db.batch();
  snap.forEach((doc) => {
    const data = doc.data();
    const ts = data.procesando_en;
    if (!ts || typeof ts.toMillis !== 'function') {
      // Doc PROCESANDO sin timestamp valido: dato inconsistente, no
      // sabemos cuanto tiempo lleva ahi. No lo tocamos.
      return;
    }
    if (ts.toMillis() >= cutoffMs) {
      // Esta procesando recien -- otro intento legitimo en curso.
      return;
    }
    batch.update(doc.ref, {
      estado: ESTADO.pendiente,
      error: 'Recuperado por sweeper: el bot se reinicio durante el envio. Reintentando.',
      error_en: admin.firestore.FieldValue.serverTimestamp(),
    });
    recuperados++;
  });
  if (recuperados > 0) await batch.commit();
  return recuperados;
}

module.exports = {
  inicializar,
  subirAStorage,
  COLECCION,
  ESTADO,
  marcarProcesando,
  marcarProcesandoSiPendiente,
  marcarEnviado,
  marcarError,
  marcarReintento,
  recuperarStaleProcesando,
};
