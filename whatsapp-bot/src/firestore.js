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
  // CRITICO (auditoria 2026-05-17): antes file.makePublic() dejaba
  // las fotos enviadas por el chofer al bot (DNI, licencias, fotos
  // privadas) world-readable con path predictable. Atacante externo
  // sin auth podia iterar por timestamps y bajar fotos.
  // Ahora generamos una signed URL con expiracion 7 dias — la app
  // del admin la consume mientras dura, y el path queda inaccesible
  // sin la URL firmada.
  // Expiracion 90 dias: suficiente para que el admin revise las
  // fotos en el flujo normal (revision → aprobacion). Si necesita
  // mas, hay que re-generar la signed URL desde el doc cliente. No
  // expones la URL en la app del chofer — solo el admin la consume.
  const [signedUrl] = await file.getSignedUrl({
    action: 'read',
    expires: Date.now() + 90 * 24 * 60 * 60 * 1000,
  });
  return signedUrl;
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

// M8 — Histórico de envíos. Doc 1:1 con COLA_WHATSAPP (mismo docId)
// pero con TTL 30 días. Sirve para auditar "¿se mandó tal mensaje?"
// cuando alguien reclama. COLA_WHATSAPP tiene TTL muy corto (horas)
// porque su rol es "cola de trabajo", no archivo.
const COLECCION_HISTORICO = 'WHATSAPP_HISTORICO';
const TTL_HISTORICO_DIAS = 30;

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
 *
 * Si se pasa `data` (el contenido del doc original que ya leímos),
 * además persiste el mensaje en WHATSAPP_HISTORICO (M8, retention 30d)
 * para auditar mensajes pasados — COLA_WHATSAPP tiene TTL muy corto.
 * Si no se pasa data o el espejo falla, NO interrumpimos el flujo de
 * marcar enviado (mejor un mensaje sin histórico que un mensaje sin
 * marcar).
 */
async function marcarEnviado(docRef, dataOrOpts, opts) {
  // Compat con firma vieja: marcarEnviado(docRef, { waMessageId }).
  const { data, waMessageId } = _normalizarMarcarArgs(dataOrOpts, opts);
  await docRef.update({
    estado: ESTADO.enviado,
    enviado_en: admin.firestore.FieldValue.serverTimestamp(),
    error: null,
    wa_message_id: waMessageId || null,
  });
  if (data) {
    await _espejarAlHistorico(docRef, data, ESTADO.enviado, {
      waMessageId,
    });
  }
}

/** Marca un doc con error y guarda el detalle para que lo vea el admin. */
async function marcarError(docRef, dataOrMensaje, mensajeMaybe) {
  // Compat con firma vieja: marcarError(docRef, mensaje).
  const { data, mensaje } = _normalizarMarcarArgs(
    dataOrMensaje,
    mensajeMaybe,
    /* esError */ true,
  );
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
  if (data) {
    await _espejarAlHistorico(docRef, data, ESTADO.error, { error });
  }
}

/**
 * Acepta tanto la firma nueva `(docRef, data, opts)` como la vieja
 * `(docRef, opts|mensaje)` durante la migración. Si el segundo arg es
 * un Map con `telefono` y `mensaje`, lo trata como data; sino, como opts.
 */
function _normalizarMarcarArgs(dataOrOpts, second, esError = false) {
  // Firma vieja: marcarError(docRef, "texto error") o
  // marcarEnviado(docRef, { waMessageId }).
  if (
    typeof dataOrOpts === 'string' ||
    !dataOrOpts ||
    typeof dataOrOpts.mensaje !== 'string'
  ) {
    if (esError) {
      return { data: null, mensaje: String(dataOrOpts ?? '') };
    }
    return { data: null, waMessageId: (dataOrOpts || {}).waMessageId };
  }
  // Firma nueva: marcarEnviado(docRef, data, { waMessageId }) o
  // marcarError(docRef, data, "texto error").
  if (esError) {
    return { data: dataOrOpts, mensaje: String(second ?? '') };
  }
  return { data: dataOrOpts, waMessageId: (second || {}).waMessageId };
}

/**
 * M8 — espeja un mensaje terminal (ENVIADO / ERROR) a WHATSAPP_HISTORICO
 * con TTL 30 días. Best-effort: cualquier falla se loguea pero NO se
 * propaga (el mensaje ya fue enviado / marcado, no queremos romper el
 * flujo por un problema de auditoría).
 *
 * DocId = mismo ID del doc original en COLA_WHATSAPP. Idempotente: si
 * se llama dos veces, el segundo write sobreescribe.
 */
async function _espejarAlHistorico(docRef, data, estado, extras = {}) {
  try {
    const expiraEnMs = Date.now() + TTL_HISTORICO_DIAS * 24 * 3600 * 1000;
    const espejo = {
      cola_id: docRef.id,
      telefono: data.telefono || '',
      mensaje: data.mensaje || '',
      origen: data.origen || '',
      destinatario_id: data.destinatario_id || '',
      destinatario_coleccion: data.destinatario_coleccion || '',
      alert_patente: data.alert_patente || null,
      estado,
      registrado_en: admin.firestore.FieldValue.serverTimestamp(),
      expira_en: admin.firestore.Timestamp.fromMillis(expiraEnMs),
    };
    if (estado === ESTADO.enviado) {
      espejo.wa_message_id = extras.waMessageId || null;
      espejo.error = null;
    } else if (estado === ESTADO.error) {
      espejo.wa_message_id = null;
      espejo.error = extras.error || '';
    }
    await docRef.firestore
      .collection(COLECCION_HISTORICO)
      .doc(docRef.id)
      .set(espejo, { merge: true });
  } catch (e) {
    log.warn(
      `Espejar a WHATSAPP_HISTORICO falló para ${docRef.id}: ${e.message}`,
    );
  }
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
  COLECCION_HISTORICO,
  TTL_HISTORICO_DIAS,
};
