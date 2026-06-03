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
const { normalizarTelefonoAWid, telefonoCanonicalAr } = require('./humano');

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
// Roster completo CON dni ({dni, data}) — para resolver el ROL real de
// cualquier empleado por teléfono (no solo de los choferes).
let _rosterConId = null;

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
  _rosterConId = snap.docs.map((doc) => ({ dni: doc.id, data: doc.data() }));
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

async function _resolverChofer(db, fromNumber, fromLid = null) {
  const fromDigits = String(fromNumber).replace(/\D+/g, '');
  if (!fromDigits && !fromLid) return null;

  // Refresh cache si nunca se cargo o si expiro el TTL.
  await asegurarCacheEmpleados(db);

  // Pasada 0: match EXACTO por WA_LID memorizado. Si ya "aprendimos" el lid de
  // este chofer (la 1ª vez que resolvió por teléfono, ver _aprenderLid), lo
  // reconocemos aunque WhatsApp ya no entregue su teléfono. Gana sobre todo.
  const porLid = _buscarPorLid(fromLid, _cacheEmpleados);
  if (porLid) return { ...porLid, _via: 'lid' };

  // Resto: match por TELÉFONO. Solo aplica si llegó un teléfono real (chofer
  // AGENDADO → @c.us, o getContact() resolvió el número). Igualdad ESTRICTA
  // sobre el canónico E.164 (fix M3: nada de sufijos, evita spoofing entre dos
  // choferes con los mismos últimos 10 dígitos).
  if (!fromDigits) return null;
  const fromWid = normalizarTelefonoAWid(fromNumber);
  const fromCanonical = fromWid ? String(fromWid).replace(/@c\.us$/, '') : null;

  // Pasada 1: EXACTO (#1 bruto / #2 WID normalizado). Gana sobre el laxo.
  for (const { dni, data } of _cacheEmpleados) {
    const tel = String(data.TELEFONO || '').replace(/\D+/g, '');
    if (!tel) continue;
    if (fromDigits === tel) return { dni, data, _via: 'tel' };
    if (fromCanonical) {
      const telWid = normalizarTelefonoAWid(tel);
      if (telWid && fromCanonical === String(telWid).replace(/@c\.us$/, '')) {
        return { dni, data, _via: 'tel' };
      }
    }
  }

  // Pasada 2: LAXO (#3) — forma canónica AR, reconcilia el "9" móvil que
  // WhatsApp NO entrega (542915115568) vs el TELEFONO cargado con-9.
  for (const { dni, data } of _cacheEmpleados) {
    const tel = String(data.TELEFONO || '').replace(/\D+/g, '');
    if (!tel) continue;
    if (telefonoCanonicalAr(fromDigits) === telefonoCanonicalAr(tel)) {
      return { dni, data, _via: 'tel' };
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
      // Descartar nuestros propios mensajes (salientes). Ademas de msg.fromMe,
      // miramos el id serializado de wweb.js ("<fromMe>_<chat>_<id>", ej.
      // "true_549...@c.us_XXXX", string crudo del MsgKey): en una sesion RECIEN
      // vinculada el getter msg.fromMe a veces NO viene confiable y el bot
      // procesaba sus PROPIOS avisos como entrantes -> se AUTO-RESPONDIA con el
      // acuse, duplicando envios (agravo el ban del numero nuevo, 2026-06-03).
      const idSer = String((msg.id && msg.id._serialized) || '');
      if (msg.fromMe || idSer.startsWith('true_')) {
        // Rastro si el id lo marco propio pero el getter fromMe NO: confirma el
        // caso "sesion nueva" la proxima vez (para el fix fino si hiciera falta).
        if (!msg.fromMe && idSer.startsWith('true_')) {
          log.warn(
            `[handler] saliente propio atrapado por id (fromMe=${msg.fromMe}, ` +
            `id=${idSer.slice(0, 48)})`
          );
        }
        return;
      }
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
      // Número REAL del remitente. Para @lid (números NO agendados en el bot —
      // el caso de casi todos los choferes) msg.from es un linked-id interno,
      // NO el teléfono: hay que pedir el contacto. Sin esto el agente / acuse /
      // Fase 3 descartaban a TODOS esos choferes (solo los /comandos los
      // resolvían, porque commands.js ya hace este getContact).
      let fromNumber = msg.from.replace(/@(c\.us|lid)$/, '');
      // LID crudo del remitente (el "linked id" de WhatsApp, estable por
      // usuario). Para chats @lid es el ÚNICO identificador que llega: WhatsApp
      // ya no expone el teléfono real de números no agendados. Lo usamos para
      // reconocer EXACTO a quien ya "aprendimos" antes (ver _aprenderLid).
      const fromLid = (tipoChat === 'lid')
        ? String(fromNumber).replace(/\D+/g, '')
        : null;
      if (tipoChat === 'lid') {
        // WhatsApp moderno manda @lid y OCULTA el teléfono; lo FORZAMOS con
        // getContactLidAndPhone (recupera el número del Store interno para los
        // contactos agendados — todos los choferes lo están). Si lo logramos,
        // el match es EXACTO por teléfono.
        const telReal = await wa.obtenerTelefonoDeLid(msg.from);
        if (telReal) {
          fromNumber = telReal;
        } else {
          // Fallback: getContact() (por si alguna versión sí lo trae). Si
          // tampoco, queda el lid → caemos al match por WA_LID ya aprendido.
          try {
            const contacto = await msg.getContact();
            if (contacto) {
              fromNumber =
                  contacto.number || (contacto.id && contacto.id.user) || fromNumber;
            }
          } catch (_) {
            // si falla, seguimos con el linked-id (peor caso: no resuelve)
          }
        }
      }
      const chofer = await _resolverChofer(db, fromNumber, fromLid);
      const persona = await _resolverPersonaAgente(db, fromNumber, chofer, fromLid);
      // Aprendizaje de LID: si identificamos a la persona por TELÉFONO (match
      // estricto) y el chat vino por @lid, memorizamos su lid en EMPLEADOS para
      // reconocerla EXACTO la próxima vez aunque WhatsApp esconda el teléfono.
      // Fire-and-forget (no bloquea la respuesta).
      if (persona && persona.dni && fromLid && persona._via === 'tel') {
        _aprenderLid(db, persona.dni, fromLid);
      }
      if (!persona) {
        log.debug(`Mensaje de número no registrado ${fromNumber}, ignoro.`);
        return;
      }

      // ─── Agente conversacional ───
      // Texto libre (sin foto y sin citar un aviso): si el agente está
      // encendido responde según el ROL (CHOFER ve solo lo suyo;
      // ADMIN/SUPERVISOR consultan de cualquiera + Cachatore). Si está
      // apagado, sin API key, sin tools para ese rol, o falla, `responder`
      // devuelve null y seguimos al flujo de siempre (al chofer: acuse /
      // Fase 3; a otros roles: nada). Quote y media van a respuestas-a-avisos.
      const esAudio =
        msg.hasMedia &&
        (msg.type === 'ptt' || msg.type === 'audio') &&
        !msg.hasQuotedMsg;
      const esTextoLibre =
        !msg.hasMedia &&
        !msg.hasQuotedMsg &&
        typeof msg.body === 'string' &&
        msg.body.trim().length > 0;
      if (esTextoLibre || esAudio) {
        try {
          // Mensaje de voz: bajamos el audio y se lo pasamos al agente (solo
          // Gemini lo interpreta). Si no se puede bajar, no llamamos al agente
          // y seguimos al flujo de siempre.
          let audio = null;
          if (esAudio) {
            const media = await msg.downloadMedia();
            if (media && media.data) {
              audio = { data: media.data, mimetype: media.mimetype || 'audio/ogg' };
            }
          }
          if (!esAudio || audio) {
            const respuestaAgente = await agente.responder(
              { texto: msg.body || '', persona, telefono: fromNumber, audio },
              fs
            );
            if (respuestaAgente) {
              await wa.responder(msg, respuestaAgente);
              log.info(
                `Agente respondió a ${persona.rol} ${persona.dni || fromNumber}` +
                  (esAudio ? ' (audio)' : '')
              );
              return;
            }
          }
        } catch (e) {
          log.warn(`Agente no respondió (${e.message}), sigo al flujo normal`);
        }
      }

      // Solo los CHOFERES siguen al acuse / Fase 3. Otros roles (admin,
      // supervisor, etc.) terminan acá: no reciben el acuse de chofer.
      if (!chofer) return;

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

// ─── Resolución de rol para el agente ───

const _ROLES_VALIDOS = new Set([
  'CHOFER', 'PLANTA', 'GOMERIA', 'SEG_HIGIENE', 'SUPERVISOR', 'ADMIN',
]);

/** Espejo (JS) de AppRoles.normalizar: USUARIO→CHOFER, valida la lista. */
function _normalizarRol(rol) {
  const r = String(rol || '').toUpperCase().trim();
  if (r === 'USUARIO') return 'CHOFER';
  return _ROLES_VALIDOS.has(r) ? r : 'CHOFER';
}

/**
 * Match EXACTO de un empleado por su WA_LID memorizado (el "linked id" de
 * WhatsApp, estable por usuario). Es la forma robusta de reconocer a quien
 * escribe desde un chat @lid donde WhatsApp ya no entrega el teléfono: el lid
 * se aprende la 1ª vez que el chofer resuelve por teléfono (ver _aprenderLid).
 * Igualdad ESTRICTA sobre dígitos — sin heurísticas de nombre, sin falsos
 * positivos. (El match por pushname se descartó el 2026-06-03 por inseguro:
 * podía confundir a dos personas con nombre parecido y filtrar datos sensibles.)
 */
function _buscarPorLid(fromLid, lista) {
  const lidNorm = String(fromLid || '').replace(/\D+/g, '');
  if (!lidNorm || !lista) return null;
  for (const item of lista) {
    const waLid = String((item.data || {}).WA_LID || '').replace(/\D+/g, '');
    if (waLid && waLid === lidNorm) return item;
  }
  return null;
}

/**
 * Memoriza el WA_LID de un empleado en EMPLEADOS (merge). Se llama cuando lo
 * identificamos por TELÉFONO (match estricto) y el chat vino por @lid: así la
 * próxima vez lo reconocemos EXACTO por su lid, sin depender de que WhatsApp
 * entregue el teléfono. Idempotente; invalida el cache para tomarlo enseguida.
 * Como solo se memoriza tras un match por teléfono, el lid queda asociado al
 * chofer correcto — nunca a uno adivinado.
 */
async function _aprenderLid(db, dni, fromLid) {
  const lidNorm = String(fromLid || '').replace(/\D+/g, '');
  if (!dni || !lidNorm) return;
  try {
    await db.collection('EMPLEADOS').doc(String(dni)).set(
      { WA_LID: lidNorm },
      { merge: true }
    );
    invalidarCacheEmpleados();
    log.info(`[lid-learning] WA_LID ${lidNorm} → DNI ${dni} memorizado`);
  } catch (e) {
    log.warn(`[lid-learning] no pude guardar WA_LID de ${dni}: ${e.message}`);
  }
}

/** Busca el {dni, data} de un empleado por teléfono (E.164) en `lista`. */
function _buscarEmpleadoEn(telefono, lista) {
  if (!lista || !telefono) return null;
  const digits = String(telefono).replace(/\D+/g, '');
  if (!digits) return null;
  const wid = normalizarTelefonoAWid(telefono);
  const canonical = wid ? String(wid).replace(/@c\.us$/, '') : null;
  // Pasada 1: match EXACTO (bruto o WID). Gana siempre sobre el laxo.
  for (const item of lista) {
    const tel = String(item.data.TELEFONO || '').replace(/\D+/g, '');
    if (!tel) continue;
    if (digits === tel) return item;
    if (canonical) {
      const telWid = normalizarTelefonoAWid(tel);
      if (telWid && canonical === String(telWid).replace(/@c\.us$/, '')) {
        return item;
      }
    }
  }
  // Pasada 2: match LAXO — reconcilia el "9" móvil AR (mismo motivo que
  // _resolverChofer match #3). Solo corre si ningún exacto en la pasada 1.
  for (const item of lista) {
    const tel = String(item.data.TELEFONO || '').replace(/\D+/g, '');
    if (!tel) continue;
    if (telefonoCanonicalAr(digits) === telefonoCanonicalAr(tel)) return item;
  }
  return null;
}

/**
 * Resuelve la "persona" (con su ROL real) que escribe, para el agente:
 *   - CHOFER si `_resolverChofer` ya lo identificó.
 *   - Otro rol (SUPERVISOR / GOMERIA / ...) buscándolo en el roster completo.
 *   - ADMIN si su teléfono está en ADMIN_PHONES (gana sobre lo anterior).
 * Devuelve null si el número no pertenece a ningún empleado ni admin.
 */
async function _resolverPersonaAgente(db, fromNumber, chofer, fromLid = null) {
  // Admin gana SIEMPRE (su teléfono/lid está en ADMIN_PHONES). Va PRIMERO para
  // que nada lo degrade (vos sos el usuario crítico: no podés perder tools).
  if (commands._esAdmin(fromNumber)) {
    return {
      rol: 'ADMIN',
      dni: chofer ? chofer.dni : null,
      nombre: chofer ? chofer.data.NOMBRE : nombrePorTelefonoTodos(fromNumber),
      data: chofer ? chofer.data : {},
      _via: chofer ? chofer._via : 'admin',
    };
  }
  if (chofer) {
    return {
      rol: 'CHOFER',
      dni: chofer.dni,
      nombre: chofer.data.NOMBRE,
      data: chofer.data,
      _via: chofer._via,
    };
  }
  await asegurarCacheEmpleados(db);
  // Roles de GESTIÓN (supervisores como Molina): EXACTO por WA_LID memorizado,
  // o por teléfono. Sin heurísticas de nombre — devuelve el ROL REAL.
  const porLid = _buscarPorLid(fromLid, _rosterConId || []);
  if (porLid) {
    return {
      rol: _normalizarRol(porLid.data.ROL),
      dni: porLid.dni,
      nombre: porLid.data.NOMBRE,
      data: porLid.data,
      _via: 'lid',
    };
  }
  const emp = _buscarEmpleadoEn(fromNumber, _rosterConId || []);
  if (emp) {
    return {
      rol: _normalizarRol(emp.data.ROL),
      dni: emp.dni,
      nombre: emp.data.NOMBRE,
      data: emp.data,
      _via: 'tel',
    };
  }
  return null;
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
  _buscarEmpleadoEn,
  _buscarPorLid,
};
