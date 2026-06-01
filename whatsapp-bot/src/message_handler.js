// Fase 3 — manejo de mensajes entrantes.
//
// Cuando un chofer responde al bot con texto + foto del nuevo
// comprobante, este handler:
//
//   1. Filtra mensajes que no nos interesan (grupos, broadcasts,
//      propios, status updates).
//   2. Identifica al chofer cruzando el teléfono con `EMPLEADOS`. Si
//      no es un chofer registrado, ignora el mensaje (cualquiera podría
//      escribirle al bot).
//   3. Asocia la respuesta con un aviso anterior:
//      a) Si la respuesta cita un mensaje del bot (quote de WhatsApp),
//         buscamos por `wa_message_id` el doc original en
//         COLA_WHATSAPP — ahí sabemos qué papel era.
//      b) Si no hay quote pero el chofer tiene un único aviso reciente
//         (≤ 72h, estado ENVIADO) sin respuesta, asociamos a ese.
//      c) Si hay ambigüedad o ningún aviso reciente, marcamos como
//         "ambiguo" y lo dejamos para revisión manual del admin.
//   4. Si hay media (imagen / PDF), la sube a Firebase Storage en
//      `RESPUESTAS_BOT/{dni}_{timestamp}.{ext}`.
//   5. Extrae fecha del texto del mensaje con regex (port del
//      OcrService Dart).
//   6. Crea un doc en `REVISIONES` con la misma forma que las
//      revisiones manuales — el admin lo aprueba/rechaza desde la app
//      como cualquier otra. Marcado con `origen: 'BOT_WHATSAPP'`
//      para distinguirlas en el listado.
//   7. Acusa recibo al chofer.

const admin = require('firebase-admin');
const log = require('./logger');
const fechaExtractor = require('./fecha_extractor');
const commands = require('./commands');
const control = require('./control');
const cron = require('./cron');
const agente = require('./agente');
const { normalizarTelefonoAWid } = require('./humano');

// Mapeo de teléfono normalizado (solo dígitos) → DNI del chofer.
//
// Cache en memoria con TTL configurable (default 5min). Antes
// rebuildiamos por cada mensaje entrante leyendo TODA la coleccion
// EMPLEADOS (~57 docs). Con 100 mensajes por dia eran ~5700 reads
// solo para resolver el remitente. Con cache de 5min eso baja a
// ~57 reads por intervalo, ahorrando ordenes de magnitud.
//
// El TTL bajado de 5min a 1min para que altas/bajas/cambios de
// telefono se reflejen rapido. Con ~60 empleados y polling cada 15s,
// ~4 reads/min (1 cada vez que llega un mensaje y vence el TTL) son
// despreciables. Si un comando admin sabe que cambio EMPLEADOS,
// puede llamar `invalidarCache()` para forzar refresh inmediato.
const _CACHE_TTL_MS = parseInt(process.env.EMPLEADOS_CACHE_TTL_MS || '60000', 10);
let _cacheEmpleados = null;
let _cacheTimestamp = 0;
// Roster COMPLETO (cualquier rol) — solo para logs legibles: nombrar a los
// admin / destinatarios de resúmenes (Molina, Emmanuel, Giagante...) que NO
// son choferes y por eso no entran en `_cacheEmpleados`. Se llena en el mismo
// refresh (la query ya trae todos los empleados; solo guardamos su data).
let _rosterTodos = null;

/**
 * Fuerza el descarte del cache de empleados. La próxima llamada va a
 * leer de Firestore de nuevo. Útil cuando un comando admin sabe que
 * cambió EMPLEADOS y no quiere esperar al TTL.
 */
function invalidarCacheEmpleados() {
  _cacheEmpleados = null;
  _cacheTimestamp = 0;
}

async function _refrescarCacheEmpleados(db) {
  // El cache se usa para `_resolverChofer` (asociar el número que escribió
  // al bot con un chofer del sistema). Solo CHOFER puede manejar y
  // recibir/responder avisos automáticos — admins/supervisores/planta
  // pueden tener TELEFONO cargado pero no son destinatarios del bot,
  // así que los excluimos del cache. Acepta el legacy 'USUARIO' por
  // compatibilidad y trata ROL vacío como CHOFER (datos viejos).
  const snap = await db.collection('EMPLEADOS').get();
  const todos = snap.docs.length;
  _cacheEmpleados = snap.docs
    .map((doc) => ({ dni: doc.id, data: doc.data() }))
    .filter(({ data }) => {
      const rol = String(data.ROL || '').toUpperCase().trim();
      return rol === '' || rol === 'CHOFER' || rol === 'USUARIO';
    });
  // Roster completo (todos los roles) para logs legibles.
  _rosterTodos = snap.docs.map((doc) => doc.data());
  _cacheTimestamp = Date.now();
  log.info(`[empleados-cache] refresh: ${_cacheEmpleados.length} choferes (de ${todos} empleados, TTL ${_CACHE_TTL_MS}ms)`);
}

/**
 * Asegura que el cache de empleados (choferes + roster completo) esté cargado
 * y fresco (respeta el TTL). Pensado para llamarse desde el loop de polling del
 * bot, así el roster está SIEMPRE caliente para los logs de envío legibles
 * (`_quien`/`nombrePorTelefono*`). El camino de ENVÍO no dispara
 * `_resolverChofer` (que es solo para mensajes ENTRANTES), por eso sin esto el
 * cache quedaba en null en un bot que solo envía y los logs salían con el
 * número crudo (bug reportado 2026-05-22).
 */
async function asegurarCacheEmpleados(db) {
  if (!_cacheEmpleados || (Date.now() - _cacheTimestamp) > _CACHE_TTL_MS) {
    await _refrescarCacheEmpleados(db);
  }
}

async function _resolverChofer(db, fromNumber) {
  const fromDigits = String(fromNumber).replace(/\D+/g, '');
  if (!fromDigits) return null;

  // Refresh cache si nunca se cargo o si expiro el TTL.
  await asegurarCacheEmpleados(db);

  // Fix M3 (auditoria 24/7 2026-05-18): match ESTRICTO por
  // normalizacion E.164, no por sufijo. El match por sufijo de 10
  // digitos permitia spoofing entre 2 choferes con los mismos
  // ultimos 10 digitos (raro pero posible — caso real: chofer con
  // numero internacional cuyos ultimos 10 digitos coinciden con
  // un argentino). Normalizar ambos a WID canonico (5492914567890)
  // y comparar igualdad estricta.
  //
  // `normalizarTelefonoAWid` agrega prefijo pais 54 + mobile prefix 9
  // si falta, y devuelve `<digitos>@c.us`. Quitamos el sufijo `@c.us`
  // para comparar solo digitos.
  const fromWid = normalizarTelefonoAWid(fromNumber);
  const fromCanonical = fromWid ? String(fromWid).replace(/@c\.us$/, '') : null;

  for (const { dni, data } of _cacheEmpleados) {
    const tel = String(data.TELEFONO || '').replace(/\D+/g, '');
    if (!tel) continue;

    // Match #1: exacto bruto (sin normalizacion). Cubre el caso
    // donde el TELEFONO en EMPLEADOS ya esta en E.164 canonico.
    if (fromDigits === tel) {
      return { dni, data };
    }

    // Match #2: comparar normalizados a E.164. Si ambos se
    // normalizan al mismo WID, es match estricto.
    if (fromCanonical) {
      const telWid = normalizarTelefonoAWid(tel);
      if (telWid) {
        const telCanonical = String(telWid).replace(/@c\.us$/, '');
        if (fromCanonical === telCanonical) {
          return { dni, data };
        }
      }
    }
  }
  return null;
}

/**
 * Busca el doc de COLA_WHATSAPP que originó la conversación con este
 * chofer. Prioridad:
 *   1. Si la respuesta cita un mensaje (quote), buscar por
 *      `wa_message_id` exacto.
 *   2. Si no hay quote, buscar el último ENVIADO al mismo destinatario
 *      en las últimas 72h.
 *   3. Si hay más de uno reciente y la respuesta no cita, devolver
 *      `{ ambiguo: true }` para que el caller lo deje en bandeja.
 */
async function _asociarConAviso(db, chofer, msg, quotedId) {
  // 1) Por quote
  if (quotedId) {
    const q = await db
      .collection('COLA_WHATSAPP')
      .where('wa_message_id', '==', quotedId)
      .limit(1)
      .get();
    if (!q.empty) {
      return { aviso: q.docs[0], razon: 'quote' };
    }
  }

  // 2) Por contexto reciente
  const limite = admin.firestore.Timestamp.fromDate(
    new Date(Date.now() - 72 * 60 * 60 * 1000)
  );
  const recientes = await db
    .collection('COLA_WHATSAPP')
    .where('destinatario_id', '==', chofer.dni)
    .where('estado', '==', 'ENVIADO')
    .where('enviado_en', '>=', limite)
    .orderBy('enviado_en', 'desc')
    .limit(5)
    .get();

  if (recientes.empty) {
    return { aviso: null, razon: 'sin_aviso_reciente' };
  }
  if (recientes.docs.length === 1) {
    return { aviso: recientes.docs[0], razon: 'unico_reciente' };
  }
  // Múltiples avisos sin respuesta — no podemos elegir solos.
  return { aviso: null, razon: 'ambiguo', candidatos: recientes.docs };
}

/**
 * Sube la media adjunta del mensaje a Firebase Storage. wwebjs entrega
 * media como base64 — la convertimos a Buffer y delegamos al helper de
 * `firestore.js`.
 */
/**
 * Whitelist de tipos que aceptamos como comprobantes. Cualquier otro
 * formato (webp de stickers, mp4 de videos, doc/xls, exe, etc) se
 * rechaza: no se sube a Storage ni se procesa. El chofer recibe el
 * mensaje normal del bot pero sin asociacion de comprobante.
 *
 * Antes habia un fallback `'bin'` que dejaba pasar todo y los archivos
 * raros terminaban en Storage; lo sacamos para evitar ruido y
 * defensa-en-profundidad ante un mimetype falsificado.
 */
const EXTENSIONES_PERMITIDAS = ['jpg', 'png', 'pdf'];

async function _subirMedia(fs, msg, dni) {
  const media = await msg.downloadMedia();
  if (!media) return null;
  const ext = _extensionDeMime(media.mimetype);
  if (!ext || !EXTENSIONES_PERMITIDAS.includes(ext)) {
    log.warn(
      `Media rechazada por tipo no permitido: mimetype=${media.mimetype} dni=${dni}`
    );
    return null;
  }
  const ts = Date.now();
  // Defense-in-depth: aunque hoy el DNI viene de doc.id de EMPLEADOS y
  // está garantizado a ser dígitos por DigitOnlyFormatter en la app,
  // sanitizamos acá para que un DNI mal cargado (vía consola Firebase
  // u otra herramienta) no permita path traversal en Storage.
  const dniSeguro = String(dni).replace(/[^0-9]/g, '') || 'desconocido';
  const path = `RESPUESTAS_BOT/${dniSeguro}_${ts}.${ext}`;
  const bytes = Buffer.from(media.data, 'base64');
  return await fs.subirAStorage({
    path,
    bytes,
    contentType: media.mimetype,
  });
}

function _extensionDeMime(mime) {
  if (!mime) return null;
  if (mime.includes('jpeg') || mime.includes('jpg')) return 'jpg';
  if (mime.includes('png')) return 'png';
  if (mime.includes('pdf')) return 'pdf';
  // webp (stickers de WhatsApp), mp4, docx, etc -> null = rechazar.
  return null;
}

/**
 * Crea un doc en `REVISIONES` con la misma forma que las revisiones
 * que crea la app cuando el chofer las sube manualmente. El admin las
 * va a ver mezcladas en la pantalla "Revisiones Pendientes" — las del
 * bot se identifican por `origen: 'BOT_WHATSAPP'`.
 */
async function _crearRevision(db, { chofer, avisoData, urlArchivo, pathStorage, fechaIso, mensajeOriginal }) {
  await db.collection('REVISIONES').add({
    dni: chofer.dni,
    nombre_usuario: chofer.data.NOMBRE || chofer.dni,
    campo: avisoData.campo_base
      ? `VENCIMIENTO_${avisoData.campo_base}`
      : 'VENCIMIENTO_DESCONOCIDO',
    coleccion_destino: avisoData.destinatario_coleccion || 'EMPLEADOS',
    etiqueta: avisoData.campo_base || 'Documento',
    fecha_vencimiento: fechaIso,
    url_archivo: urlArchivo || '',
    path_storage: pathStorage || '',
    estado: 'PENDIENTE',
    fecha_solicitud: admin.firestore.FieldValue.serverTimestamp(),
    origen: 'BOT_WHATSAPP',
    mensaje_chofer: String(mensajeOriginal || '').slice(0, 1000),
  });
}

/**
 * Acuse automático cuando un chofer registrado responde al bot. UX
 * básica para que el chofer no sienta que está hablándole a un agujero
 * negro. Cap diario: 1 acuse por chofer por día (idempotencia con doc
 * `BOT_ACUSES/{dni}_{YYYY-MM-DD}`).
 *
 * Si la creación del doc falla por race (otro mensaje del mismo chofer
 * llegó simultáneo y ya creó el doc), simplemente no enviamos —
 * `create()` tira ALREADY_EXISTS, lo capturamos y skipiamos.
 */
async function _enviarAcuseSiCorresponde(db, wa, msg, chofer) {
  const hoy = (() => {
    const d = new Date();
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${dd}`;
  })();
  const acuseRef = db.collection('BOT_ACUSES').doc(`${chofer.dni}_${hoy}`);

  // Marcar antes de enviar — `create()` falla con ALREADY_EXISTS si
  // otro mensaje ya pasó por acá hoy. Eso garantiza atomicidad sin tx.
  try {
    await acuseRef.create({
      dni: chofer.dni,
      fecha: hoy,
      enviado_en: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (e) {
    // ALREADY_EXISTS o cualquier error → no enviamos acuse hoy.
    log.debug(`Acuse a ${chofer.dni} skipeado (ya enviado hoy o race).`);
    return;
  }

  // Variantes anti-baneo (si dos choferes responden seguido, los
  // mensajes salen distintos). Mínimo 6 alineado con el estándar de
  // los demás mensajes individuales (decisión 2026-05-09).
  const variantes = [
    'Recibí tu mensaje. Soy un sistema automático — para cualquier ' +
      'gestión o consulta, comunicate con la oficina.',
    'Hola, te aviso que soy un mensaje automático del sistema. Si ' +
      'necesitás algo, comunicate directo con la oficina.',
    'Recibido. Este es un canal automático — para gestiones ' +
      'comunicate con la oficina.',
    'Tu mensaje me llegó. Te aviso que soy un canal automático ' +
      '— cualquier consulta o gestión la maneja la oficina directo.',
    'Hola. Llegó tu mensaje, pero soy un sistema automático y no ' +
      'puedo gestionar nada por acá. Comunicate con la oficina.',
    'Listo, recibí lo que me mandaste. Acordate que esto es un ' +
      'sistema automático — para resolver cualquier tema, hablá con ' +
      'la oficina.',
  ];
  const texto = variantes[Math.floor(Math.random() * variantes.length)];

  try {
    await wa.responder(msg, texto);
    log.info(`Acuse automático enviado a ${chofer.dni}`);
  } catch (e) {
    log.warn(`No se pudo enviar acuse a ${chofer.dni}: ${e.message}`);
  }
}

/**
 * Cuando no podemos asociar la respuesta con confianza, va a una
 * bandeja para que el admin la procese manualmente. La pantalla
 * `AdminBotBandejaScreen` la lee y permite convertirla en revisión
 * eligiendo el papel.
 */
async function _crearAmbiguo(db, { chofer, msg, urlArchivo, fechaIso, razon, candidatos }) {
  await db.collection('RESPUESTAS_BOT_AMBIGUAS').add({
    dni: chofer.dni,
    nombre_usuario: chofer.data.NOMBRE || chofer.dni,
    telefono: String(msg.from || '').replace('@c.us', ''),
    mensaje_chofer: String(msg.body || '').slice(0, 1000),
    url_archivo: urlArchivo || '',
    fecha_detectada: fechaIso || null,
    razon, // 'ambiguo' | 'sin_aviso_reciente'
    candidatos: candidatos
      ? candidatos.map((d) => ({
          cola_doc_id: d.id,
          campo_base: d.data().campo_base,
          enviado_en: d.data().enviado_en,
        }))
      : [],
    estado: 'PENDIENTE',
    creado_en: admin.firestore.FieldValue.serverTimestamp(),
  });
}

/**
 * Punto de entrada. Se registra como handler del evento `message`
 * de wwebjs.
 *
 * @param {object} fs - módulo firestore.js (DB + helper de storage)
 * @param {object} wa - módulo whatsapp.js (para responder)
 */
function crearHandler(fs, wa) {
  const db = fs.inicializar();

  return async (msg) => {
    try {
      // ─── Filtros básicos ───
      if (msg.fromMe) return; // mensajes del propio bot
      if (msg.isStatus) return; // status updates
      if (msg.from && msg.from.endsWith('@g.us')) return; // grupo
      // Aceptamos @c.us (chats con contactos) y @lid (linked-id de
      // WhatsApp moderno: aparece en chats con números NO agendados).
      // En @lid, msg.from no es un número directo — el resolver de
      // commands.js hace getContact() para obtener el canónico.
      if (!msg.from) return;
      const tipoChat = msg.from.endsWith('@c.us') ? 'c.us' :
                       msg.from.endsWith('@lid') ? 'lid' : null;
      if (!tipoChat) return; // broadcast / status / unknown

      // ─── Comandos admin (early return si matchea) ───
      // Si el mensaje empieza con `/` y viene de un admin autorizado
      // (whitelist en .env: ADMIN_PHONES), lo procesamos como comando
      // y NO seguimos al flujo de Fase 3.
      const eraComando = await commands.manejarSiEsComando(msg, {
        db, fs, control, cron,
      });
      if (eraComando) return;

      // ─── Identificar al chofer (necesario para ACUSE y para Fase 3) ───
      const fromNumber = msg.from.replace('@c.us', '');
      const chofer = await _resolverChofer(db, fromNumber);
      const esAdmin = !chofer && commands._esAdmin(fromNumber);
      if (!chofer && !esAdmin) {
        log.debug(`Mensaje de número no registrado ${fromNumber}, ignoro.`);
        return;
      }

      // ─── Agente conversacional (Fase 1: consultas read-only) ───
      // Texto libre (sin foto y sin citar un aviso): si el agente está
      // encendido responde con datos reales. CHOFER ve SOLO lo suyo; ADMIN
      // puede consultar de cualquiera (las tools cambian según el rol). Si
      // está apagado, sin API key o falla, `responder` devuelve null y
      // seguimos al flujo de siempre (al chofer: acuse / Fase 3; al admin:
      // nada). El quote y la media se reservan para respuestas-a-avisos.
      const esTextoLibre =
        !msg.hasMedia &&
        !msg.hasQuotedMsg &&
        typeof msg.body === 'string' &&
        msg.body.trim().length > 0;
      if (esTextoLibre) {
        const persona = chofer
          ? {
              rol: 'CHOFER',
              dni: chofer.dni,
              nombre: chofer.data.NOMBRE,
              data: chofer.data,
            }
          : {
              rol: 'ADMIN',
              dni: null,
              nombre: nombrePorTelefonoTodos(fromNumber),
              data: {},
            };
        try {
          const respuestaAgente = await agente.responder(
            { texto: msg.body, persona, telefono: fromNumber },
            fs
          );
          if (respuestaAgente) {
            await wa.responder(msg, respuestaAgente);
            log.info(
              `Agente respondió a ${persona.rol} ${persona.dni || fromNumber}`
            );
            return;
          }
        } catch (e) {
          log.warn(`Agente no respondió (${e.message}), sigo al flujo normal`);
        }
      }

      // Si es ADMIN (no chofer), termina acá: no recibe el acuse de chofer.
      if (esAdmin) return;

      // ─── Acuse automático ───
      // Aunque la Fase 3 esté apagada, si un chofer registrado responde
      // al bot, queremos contestarle algo (UX: si no respondemos, queda
      // como agujero negro y el chofer puede sentirse ignorado).
      // Cap: 1 acuse por chofer por día — si responde 10 veces el mismo
      // día, no lo spameamos. Doc en `BOT_ACUSES/{dni}_{YYYY-MM-DD}`.
      const respuestasHabilitado =
        String(process.env.AUTO_RESPUESTAS_ENABLED || 'false').toLowerCase() === 'true';
      if (!respuestasHabilitado) {
        await _enviarAcuseSiCorresponde(db, wa, msg, chofer);
        return;
      }

      // ─── Quote del aviso original (si vino) ───
      let quotedId = null;
      if (msg.hasQuotedMsg) {
        try {
          const quoted = await msg.getQuotedMessage();
          if (quoted && quoted.id && quoted.id._serialized) {
            quotedId = quoted.id._serialized;
          }
        } catch (_) {
          // ignoramos — caemos al fallback por contexto
        }
      }

      // ─── Asociar con un aviso ───
      const asoc = await _asociarConAviso(db, chofer, msg, quotedId);
      log.info(
        `Mensaje de ${chofer.dni} asociación=${asoc.razon}` +
          (asoc.aviso ? ` (cola ${asoc.aviso.id})` : '')
      );

      // ─── Procesar media + extraer fecha ───
      let urlArchivo = null;
      let pathStorage = null;
      if (msg.hasMedia) {
        try {
          urlArchivo = await _subirMedia(fs, msg, chofer.dni);
          if (urlArchivo) {
            // El path se puede deducir de la URL pero conviene guardarlo
            // explícito para que `revision_service.finalizarRevision`
            // sepa qué borrar de Storage si rechaza la solicitud.
            pathStorage = urlArchivo
              .split('storage.googleapis.com/')
              .pop()
              .split('?')[0];
          }
        } catch (e) {
          log.error(`No se pudo subir media: ${e.message}`);
        }
      }

      const fecha = fechaExtractor.extraerFechaMasLejana(msg.body);
      const fechaIso = fechaExtractor.aIsoYMD(fecha);

      // ─── Crear el doc destino ───
      if (asoc.aviso) {
        await _crearRevision(db, {
          chofer,
          avisoData: asoc.aviso.data(),
          urlArchivo,
          pathStorage,
          fechaIso,
          mensajeOriginal: msg.body,
        });
        log.info(`Revisión creada para ${chofer.dni}`);
        try {
          await wa.responder(
            msg,
            'Recibí el comprobante. La oficina lo va a revisar en breve.'
          );
        } catch (e) {
          log.warn(`No pude acusar recibo: ${e.message}`);
        }
      } else {
        await _crearAmbiguo(db, {
          chofer,
          msg,
          urlArchivo,
          fechaIso,
          razon: asoc.razon,
          candidatos: asoc.candidatos,
        });
        log.info(
          `Mensaje de ${chofer.dni} fue a bandeja ambigua (razón: ${asoc.razon})`
        );
        try {
          await wa.responder(
            msg,
            'Recibí tu mensaje, pero no pude asociarlo automáticamente. ' +
              'La oficina lo va a revisar y te confirma.'
          );
        } catch (_) {
          // best-effort
        }
      }
    } catch (e) {
      log.error(`Error procesando mensaje entrante: ${e.stack || e.message}`);
    }
  };
}

/**
 * Resuelve un telefono a NOMBRE usando el cache de empleados YA cargado
 * (sincronico, sin tocar Firestore -- pensado para logs legibles). Devuelve
 * null si el cache no esta cargado o no hay match (ej. encargados/admins, que
 * NO estan en este cache -- es solo de CHOFER). Misma normalizacion E.164 que
 * _resolverChofer.
 */
function _buscarNombreEn(telefono, lista) {
  if (!lista || !telefono) return null;
  const digits = String(telefono).replace(/\D+/g, '');
  if (!digits) return null;
  const wid = normalizarTelefonoAWid(telefono);
  const canonical = wid ? String(wid).replace(/@c\.us$/, '') : null;
  for (const data of lista) {
    const tel = String(data.TELEFONO || '').replace(/\D+/g, '');
    if (!tel) continue;
    if (digits === tel) return data.NOMBRE || null;
    if (canonical) {
      const telWid = normalizarTelefonoAWid(tel);
      if (telWid && canonical === String(telWid).replace(/@c\.us$/, '')) {
        return data.NOMBRE || null;
      }
    }
  }
  return null;
}

function nombrePorTelefono(telefono) {
  // Solo choferes (cache filtrado) — para resolver mensajes ENTRANTES.
  return _buscarNombreEn(
    telefono, (_cacheEmpleados || []).map((e) => e.data));
}

/**
 * Igual que nombrePorTelefono pero contra TODOS los empleados (cualquier rol).
 * Para logs legibles: nombra a admins / destinatarios de resúmenes (Molina,
 * Emmanuel, Giagante...) que no son choferes. Sincrónico, sin tocar Firestore.
 */
function nombrePorTelefonoTodos(telefono) {
  return _buscarNombreEn(telefono, _rosterTodos);
}

module.exports = {
  crearHandler,
  nombrePorTelefono,
  nombrePorTelefonoTodos,
  asegurarCacheEmpleados,
  invalidarCacheEmpleados,
  // Exportados para tests:
  _resolverChofer,
  _asociarConAviso,
};
