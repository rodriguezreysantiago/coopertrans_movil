// Comandos admin por WhatsApp.
//
// Permite controlar el bot desde el celular del admin sin abrir la app
// ni la PC. El admin manda un mensaje al PROPIO número del bot que
// empieza con `/` y el bot interpreta y responde.
//
// Comandos soportados:
//   /estado                  → resumen del bot (cola, último ciclo, pausa).
//   /pausar [Nh|Nd]          → pausa el bot. Opcional: duración.
//   /reanudar                → quita la pausa.
//   /forzar-cron             → corre el ciclo del cron ahora.
//   /test-aviso DNI          → mensaje de prueba al DNI indicado.
//   /jornada DNI             → estado del vigilador para ese chofer.
//   /silenciar DNI dur [m]   → suprime avisos del vigilador para ese
//                              chofer durante `dur` (Ns/Nm/Nh/Nd, cap 30d).
//                              Útil cuando el chofer está en taller, GPS
//                              roto, problema conocido — el bot no spamea.
//   /desilenciar DNI         → revierte un /silenciar previo.
//   /ayuda                   → lista de comandos.
//
// Seguridad:
//   - Solo responde a teléfonos en la whitelist `ADMIN_PHONES` del .env
//     (lista CSV de dígitos sin formato — ej. "5492914567890").
//   - Si llega un comando de un número no autorizado, lo ignoramos
//     silenciosamente. NO respondemos para no dar pistas a un atacante
//     que el comando existe.

const admin = require('firebase-admin');
const log = require('./logger');
const { telefonoCanonicalAr } = require('./humano');

// Minimo de digitos para que un sufijo cuente como match en lookups
// de CHOFER por TELEFONO (resolverChoferPorTelefono). El path de
// _esAdmin NO usa esta constante — usa normalización canónica con
// igualdad estricta, sin sufijos (auditoria 2026-05-17, fix CRITICO
// del bypass por sufijo).
const MIN_DIGITOS_PARA_MATCH = 10;

/**
 * Devuelve la lista de teléfonos admin autorizados, normalizados a
 * formato canónico (solo dígitos, con código país +54 9 si Argentina).
 *
 * Esperamos que el operador cargue ADMIN_PHONES con formato
 * canónico — ej. "5492914567890,5491159876543". Si carga sin código
 * país (ej. "2914567890"), se le antepone "549" para uniformar.
 */
/**
 * Canoniza un teléfono al formato AR `549<10 dígitos>` para poder comparar
 * con igualdad ESTRICTA (sin sufijos). Heurística:
 *  - 10 dígitos     → asumimos AR sin código país, anteponemos `549`.
 *  - 11 dígitos `0...` → legacy `0<área><abonado>`, quitamos el 0 + `549`.
 *  - resto          → tal cual (ya viene con código país o es no-AR).
 * Mismo criterio que _adminWhitelist / _esAdmin (que tienen la lógica
 * inline; acá se centraliza para el resolver de choferes).
 */
function _canonicalArPhone(digits) {
  const d = String(digits).replace(/\D+/g, '');
  if (d.length === 10) return `549${d}`;
  if (d.length === 11 && d.startsWith('0')) return `549${d.substring(1)}`;
  return d;
}

function _adminWhitelist() {
  const raw = process.env.ADMIN_PHONES || '';
  return raw
    .split(',')
    .map((s) => s.trim().replace(/\D+/g, ''))
    .filter((s) => s.length >= 10)
    .map((s) => {
      // Normalización defensiva: si viene sin +54 9, lo antepone.
      // 10 dígitos → área(3) + abonado(7) → asumimos AR.
      if (s.length === 10) s = `549${s}`;
      // 11 dígitos comenzando con 0 → 0(1) + área + abonado → quitar 0 + AR.
      else if (s.length === 11 && s.startsWith('0')) s = `549${s.substring(1)}`;
      // Canónico AR final: saca el "9" móvil para comparar contra el ID que
      // entrega WhatsApp (que viene sin el 9).
      return telefonoCanonicalAr(s);
    });
}

/**
 * `true` si el teléfono que envió el mensaje está autorizado.
 *
 * Auditoria 2026-05-17 (CRITICO): el match anterior por "sufijo
 * de 10 dígitos" era inseguro — cualquier número que terminara con
 * los últimos 10 dígitos del admin podía ejecutar /pausar, /silenciar,
 * etc. Ej: admin "5492944399123" y atacante "0000002944399123" — el
 * `endsWith(shorter)` matcheaba el sufijo 10 y pasaba. Argentina tiene
 * 10 dígitos sin código país pero la combinación área+abonado NO es
 * única globalmente.
 *
 * Ahora normalizamos ambos lados al MISMO canónico AR (telefonoCanonicalAr:
 * sin el "9" móvil, porque WhatsApp entrega los IDs SIN él) y exigimos
 * IGUALDAD ESTRICTA. Sin sufijos, sin endsWith. Antes _esAdmin no sacaba el
 * 9, así que un admin cargado con el 9 (la forma natural) NO matcheaba el ID
 * sin-9 que entrega WhatsApp — mismo bug que el del agente con choferes.
 */
function _esAdmin(fromNumber) {
  let fromDigits = String(fromNumber).replace(/\D+/g, '');
  if (fromDigits.length < 10) return false;
  // Normalizar igual que la whitelist.
  if (fromDigits.length === 10) fromDigits = `549${fromDigits}`;
  if (fromDigits.length === 11 && fromDigits.startsWith('0')) {
    fromDigits = `549${fromDigits.substring(1)}`;
  }
  const whitelist = _adminWhitelist();
  return whitelist.includes(telefonoCanonicalAr(fromDigits));
}

/**
 * Whitelist de comandos disponibles para CHOFERES (no admins).
 * Hoy: solo `/jornada` (ven sus propios datos) y `/ayuda` (lista
 * adaptada a su rol). Si en el futuro abrimos más, agregar acá.
 *
 * Decisión Santiago 2026-05-14: el chofer puede tipear `/jornada`
 * desde su WhatsApp y recibir cómo va su jornada del día sin
 * necesidad de pasar por el admin.
 */
const COMANDOS_PERMITIDOS_CHOFER = new Set(['/jornada', '/ayuda', '/help']);

/**
 * Resuelve el chofer (DNI + datos) que envía un mensaje, SOLO por su
 * TELÉFONO real:
 *
 *   - **Match por teléfono**: igualdad estricta en la representación
 *     canónica AR (`549<10>`). Funciona cuando el msg viene de `@c.us`
 *     (contactos guardados) o de un `@lid` en el que `getContact()`
 *     resuelve el número canónico.
 *
 * SEGURIDAD (2026-06-03): se ELIMINÓ el viejo fallback por `pushname`
 * (nombre de perfil de WhatsApp). Permitía suplantación — cualquiera que
 * pusiera como nombre de perfil el de un chofer real recibía SUS datos de
 * jornada. Mismo criterio que tomó el agente del bot. Si el teléfono no
 * matchea, el chofer no se resuelve (y el comando no responde).
 *
 * Devuelve null si:
 *   - Ningún empleado matchea por teléfono.
 *   - El empleado matcheado no es CHOFER (admins/planta no se resuelven acá).
 *   - El empleado está marcado ACTIVO=false.
 *
 * Implementación: lee TODOS los empleados con ROL=CHOFER y filtra en
 * memoria. Para Vecchi son ~50 chofers — query baratísimo (1 read por
 * comando del chofer, no por chofer). Si la flota crece a > 500, se
 * puede pasar a un índice por sufijo de teléfono.
 */
async function _resolverChoferPorTelefono(db, fromNumber, _opts = {}) {
  // `_opts.pushname` se sigue recibiendo (el caller lo loggea), pero ACÁ ya no
  // se usa para resolver: el match por pushname se descartó por inseguro
  // (2026-06-03). Solo resolvemos por TELÉFONO real.
  const fromDigits = String(fromNumber).replace(/\D+/g, '');

  let snap;
  try {
    snap = await db
      .collection('EMPLEADOS')
      .where('ROL', '==', 'CHOFER')
      .get();
  } catch (e) {
    log.warn(`No pude leer EMPLEADOS para resolver chofer: ${e.message}`);
    return null;
  }

  // ─── 1. Match por teléfono (igualdad ESTRICTA en canónico AR) ───
  // Hardening 2026-05-22: antes había un fallback `longer.endsWith(shorter)`
  // (sufijo de >=10 dígitos). Mismo patrón que el `_esAdmin` viejo, cerrado
  // por inseguro el 2026-05-17 (un chofer A con sufijo coincidente al de B
  // podía pasar como B). El riesgo en AR es chico (los últimos 10 dígitos
  // son casi únicos), pero acá los datos del que reciba el comando son del
  // CHOFER matcheado — mejor cerrarlo. Igualdad estricta sobre la forma
  // canónica `549<10>` en ambos lados. (El fallback por pushname se eliminó
  // por inseguro el 2026-06-03 — ver abajo.)
  const fromCanon = _canonicalArPhone(fromDigits);
  if (fromCanon.length >= MIN_DIGITOS_PARA_MATCH) {
    for (const d of snap.docs) {
      const data = d.data() || {};
      if (data.ACTIVO === false) continue;
      const telCanon = _canonicalArPhone(data.TELEFONO || '');
      if (telCanon.length < MIN_DIGITOS_PARA_MATCH) continue;
      if (telCanon === fromCanon) return _mapChofer(d.id, data);
    }
  }

  // ─── 2. (ELIMINADO) Match por pushname ───
  // Antes había un fallback que resolvía al chofer por el NOMBRE de su perfil
  // de WhatsApp (pushname) cuando el @lid no traía teléfono real. Se DESCARTÓ
  // por inseguro (2026-06-03, mismo criterio que en el agente): cualquiera
  // podía poner como nombre de perfil el de un chofer real y recibir SUS datos
  // de jornada (suplantación). Solo resolvemos por TELÉFONO real (match
  // estricto arriba). Si no matchea, devolvemos null y el comando no responde.
  return null;
}

function _mapChofer(docId, data) {
  return {
    dni: (data.DNI || docId).toString(),
    nombre: (data.NOMBRE || '').toString(),
    apodo: (data.APODO || '').toString(),
    telefono: (data.TELEFONO || '').toString(),
  };
}

/**
 * Detecta y ejecuta un comando. Distingue 3 tipos de remitente:
 *   1. Admin (en ADMIN_PHONES): puede ejecutar TODOS los comandos.
 *   2. Chofer (en EMPLEADOS con ROL=CHOFER, ACTIVO=true): puede
 *      ejecutar solo los de COMANDOS_PERMITIDOS_CHOFER (`/jornada`,
 *      `/ayuda`).
 *   3. Otro: silencio total (no responde nada para no exponer la
 *      existencia del comando a un atacante).
 *
 * Devuelve `true` si el mensaje fue manejado como comando (haya
 * respondido o no), `false` si NO era un comando — en cuyo caso el
 * message_handler de Fase 3 lo procesa normal.
 */
async function manejarSiEsComando(msg, contextos) {
  const texto = (msg.body || '').trim();
  if (!texto.startsWith('/')) return false;

  // Resolver el número real del remitente:
  //  - Si msg.from termina en @c.us → es un teléfono directo.
  //  - Si termina en @lid (chats con números no agendados en WhatsApp
  //    moderno) → llamamos a msg.getContact() para obtener el número
  //    canónico (msg.from acá es un linked-id interno, no un teléfono).
  //
  // También capturamos el `pushname` (nombre que el usuario puso en su
  // perfil de WhatsApp) para usarlo como fallback del resolver cuando
  // el LID no se pueda mapear a un teléfono real (caso típico de
  // choferes no agendados en el WhatsApp del bot).
  let fromNumber = '';
  let pushname = '';
  try {
    const contacto = await msg.getContact();
    if (contacto) {
      fromNumber = contacto.number || (contacto.id && contacto.id.user) || '';
      pushname = (contacto.pushname || contacto.name || '').toString();
    }
  } catch (_) {
    // ignoramos — fallback al parseo del from
  }
  if (!fromNumber) {
    fromNumber = (msg.from || '').replace(/@(c\.us|lid)$/, '');
  }

  const partes = texto.split(/\s+/);
  const comando = partes[0].toLowerCase();
  const args = partes.slice(1);

  // Roles del remitente. Primero admin (whitelist hardcoded en .env)
  // y, si no es admin, intentamos resolverlo como CHOFER SOLO por teléfono
  // real (el viejo fallback por pushname se eliminó por inseguro — 2026-06-03).
  const esAdmin = _esAdmin(fromNumber);
  let chofer = null;
  if (!esAdmin) {
    chofer = await _resolverChoferPorTelefono(
      contextos.db,
      fromNumber,
      { pushname } // solo se loggea; ya no se usa para resolver
    );
  }

  if (!esAdmin && !chofer) {
    // Loggeamos el pushname para diagnosticar por qué no resolvió por teléfono
    // (chofer no agendado / manda desde @lid sin número real / dato faltante).
    log.warn(
      `Comando recibido de no-admin ni chofer ${fromNumber} ` +
      `(pushname="${pushname}"): ${texto.slice(0, 40)}`
    );
    // No respondemos para no exponer la existencia del comando.
    return true;
  }

  // Si es CHOFER (no admin), restringir a la whitelist.
  if (!esAdmin && chofer && !COMANDOS_PERMITIDOS_CHOFER.has(comando)) {
    log.warn(`Chofer ${chofer.dni} intentó comando admin ${comando} — denegado.`);
    // Tampoco respondemos — sino el chofer aprende qué comandos hay.
    return true;
  }

  const rolLog = esAdmin ? 'admin' : `chofer:${chofer.dni}`;
  log.info(`Comando ${rolLog} recibido: ${comando} ${args.join(' ')} de ${fromNumber}`);

  try {
    switch (comando) {
      case '/estado':
        await _comandoEstado(msg, contextos);
        break;
      case '/pausar':
        await _comandoPausar(msg, contextos, args);
        break;
      case '/reanudar':
        await _comandoReanudar(msg, contextos);
        break;
      case '/forzar-cron':
        await _comandoForzarCron(msg, contextos);
        break;
      case '/test-aviso':
        await _comandoTestAviso(msg, contextos, args);
        break;
      case '/jornada':
        // Para chofer pasamos su DNI; el comando ignora args (sino el
        // chofer podría espiar a otros mandando /jornada DNI_AJENO).
        // Para admin pasa los args originales.
        await _comandoJornada(
          msg,
          contextos,
          esAdmin ? args : [],
          chofer
        );
        break;
      case '/enviar-jornada':
        await _comandoEnviarJornada(msg, contextos, args);
        break;
      case '/silenciar':
        await _comandoSilenciar(msg, contextos, args);
        break;
      case '/desilenciar':
        await _comandoDesilenciar(msg, contextos, args);
        break;
      case '/ayuda':
      case '/help':
        await _comandoAyuda(msg, esAdmin);
        break;
      default:
        await msg.reply(
          `Comando no reconocido: ${comando}\nMandá /ayuda para ver la lista.`
        );
    }
  } catch (e) {
    log.error(`Error ejecutando ${comando}: ${e.message}`);
    try {
      await msg.reply(`Error ejecutando ${comando}: ${e.message}`);
    } catch (_) {
      // ignore
    }
  }
  return true;
}

// ─── Implementación de cada comando ─────────────────────────────────

async function _comandoEstado(msg, { db, fs, control }) {
  // Cola actual
  const colRef = db.collection(fs.COLECCION);
  const pendientesSnap = await colRef
    .where('estado', '==', fs.ESTADO.pendiente)
    .get();
  const errorSnap = await colRef
    .where('estado', '==', fs.ESTADO.error)
    .get();
  const enviadosSnap = await colRef
    .where('estado', '==', fs.ESTADO.enviado)
    .get();

  const ctrl = control.ultimoEstado();
  const pausa = ctrl.pausado ? `🛑 PAUSADO${ctrl.motivo ? ` (${ctrl.motivo})` : ''}` : '✓ Operando';

  const dryRun =
    String(process.env.BOT_DRY_RUN || 'false').toLowerCase() === 'true';

  const txt = [
    `*Estado del bot*`,
    `${pausa}${dryRun ? ' [DRY-RUN]' : ''}`,
    ``,
    `📤 Enviados (total): ${enviadosSnap.size}`,
    `⏳ Pendientes: ${pendientesSnap.size}`,
    `⚠ Con error: ${errorSnap.size}`,
    ``,
    `Mandá /ayuda para ver más comandos.`,
  ].join('\n');
  await msg.reply(txt);
}

/**
 * Parsea una duración tipo "30m", "24h", "2d", "90s" a milisegundos.
 * Devuelve null si el formato es inválido.
 *
 * Cap superior: 30 días (evita pausas "eternas" por accidente al tipear
 * "30000d" — antes de este parser, cualquier cosa quedaba como string
 * en el motivo y la pausa duraba indefinidamente).
 */
function _parsearDuracion(raw) {
  if (!raw) return null;
  const m = String(raw).trim().match(/^(\d+)\s*([smhdSMHD])$/);
  if (!m) return null;
  const n = parseInt(m[1], 10);
  if (!Number.isFinite(n) || n <= 0) return null;
  const unidad = m[2].toLowerCase();
  const factor = { s: 1000, m: 60 * 1000, h: 60 * 60 * 1000, d: 24 * 60 * 60 * 1000 }[unidad];
  if (!factor) return null;
  const ms = n * factor;
  // Cap 30 días — pausas más largas son casi siempre typos.
  const maxMs = 30 * 24 * 60 * 60 * 1000;
  return Math.min(ms, maxMs);
}

async function _comandoPausar(msg, { db, control }, args) {
  // args[0] opcional: duración tipo "24h", "30m", "2d", "90s".
  // Si se especifica, calculamos `pausado_hasta` y el bot se reanuda
  // solo cuando llegue esa fecha (sin necesidad de /reanudar manual).
  const duracionRaw = args.length > 0 ? args[0] : null;
  let pausadoHasta = null;
  let motivoExtra = '';
  if (duracionRaw) {
    const ms = _parsearDuracion(duracionRaw);
    if (ms == null) {
      await msg.reply(
        `❌ Duración inválida: "${duracionRaw}".\n` +
        `Formato: Ns / Nm / Nh / Nd (ej: 30m, 24h, 2d). Cap: 30d.`
      );
      return;
    }
    pausadoHasta = new Date(Date.now() + ms);
    motivoExtra = ` por ${duracionRaw} (hasta ${pausadoHasta.toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires' })})`;
  }
  const motivo = `Pausado por admin desde WhatsApp${motivoExtra}`;

  // pausado_en con serverTimestamp para evitar drift si el reloj de la
  // PC dedicada está desfasado (Windows update mal, batería CMOS).
  // pausado_hasta queda como Date local: es un timestamp FUTURO calculado
  // sobre Date.now() local, y el bot al chequearlo también usa Date.now()
  // del mismo proceso — es internamente coherente aunque la PC esté
  // desfasada. Si en el futuro otra entidad (CF, otra PC) leyera este
  // campo, habría que migrar a serverTimestamp + offset persistido.
  await db.collection('BOT_CONTROL').doc('main').set(
    {
      pausado: true,
      pausado_en: admin.firestore.FieldValue.serverTimestamp(),
      pausado_hasta: pausadoHasta, // null = indefinido
      motivo,
      pausado_por_canal: 'WHATSAPP_COMMAND',
    },
    { merge: true }
  );
  // Invalidar cache de control.js para que el próximo `estaPausado()`
  // releya el doc fresco (sin esperar el TTL de 2s).
  if (control && typeof control.invalidarCache === 'function') {
    control.invalidarCache();
  }
  const sufijo = pausadoHasta
    ? `\n⏱ Reanudación automática: ${pausadoHasta.toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires' })}`
    : '\n\nMandá /reanudar para volver a operar.';
  await msg.reply(`🛑 Bot pausado.\nMotivo: ${motivo}${sufijo}`);
}

async function _comandoReanudar(msg, { db }) {
  // reanudado_en con serverTimestamp (mismo argumento que pausado_en).
  await db.collection('BOT_CONTROL').doc('main').set(
    {
      pausado: false,
      reanudado_en: admin.firestore.FieldValue.serverTimestamp(),
      motivo: null,
    },
    { merge: true }
  );
  await msg.reply('✓ Bot reanudado. En el próximo ciclo retoma los pendientes.');
}

async function _comandoForzarCron(msg, { cron, fs }) {
  if (!cron || typeof cron.forzarRunOnce !== 'function') {
    await msg.reply('No tengo el cron disponible para forzarlo.');
    return;
  }
  await msg.reply('▶ Forzando ciclo del cron...');
  const stats = await cron.forzarRunOnce(fs);
  if (stats) {
    await msg.reply(
      `✓ Ciclo terminado.\n` +
      `Encolados: ${stats.encolados}\n` +
      `Salteados: ${stats.salteados}\n` +
      `Errores: ${stats.errores}`
    );
  } else {
    await msg.reply('✓ Ciclo iniciado. Mandá /estado en un rato para ver los nuevos pendientes.');
  }
}

async function _comandoAyuda(msg, esAdmin) {
  // Versión chofer (más corta + lenguaje natural). Solo se muestran
  // los comandos que un chofer puede ejecutar.
  if (!esAdmin) {
    const txt = [
      '*Comandos disponibles*',
      '',
      '/jornada — ver cómo va tu jornada del día (horas manejadas, ' +
        'pausas, avisos).',
      '/ayuda — este mensaje.',
    ].join('\n');
    await msg.reply(txt);
    return;
  }
  // Versión admin completa.
  const txt = [
    '*Comandos del admin*',
    '',
    '/estado — resumen del bot.',
    '/pausar 24h — pausar envíos por 24 horas (Ns/Nm/Nh/Nd, cap 30d).',
    '/reanudar — reanudar envíos.',
    '/forzar-cron — correr el cron ahora.',
    '/test-aviso 12345678 — mandar prueba a ese DNI.',
    '/jornada 12345678 — estado del vigilador para ese chofer.',
    '/enviar-jornada 12345678 — mandarle al chofer su estado de ' +
      'jornada (el mismo que ve con /jornada).',
    '/silenciar 12345678 2h en taller — no mandar avisos por ese ' +
      'tiempo (motivo opcional).',
    '/desilenciar 12345678 — quitar el silencio.',
    '/ayuda — este mensaje.',
  ].join('\n');
  await msg.reply(txt);
}

/**
 * Encola un mensaje de prueba al DNI indicado. Útil para verificar que
 * un destinatario nuevo (ej. recién agregado a alguna env var de
 * resumen) recibe correctamente antes de cambiar configuración.
 *
 * Uso: /test-aviso 12345678
 *
 * Lo encola en COLA_WHATSAPP igual que cualquier otro mensaje — pasa
 * por el flujo normal (rate limit, horario hábil, dedup, splitting).
 */
async function _comandoTestAviso(msg, { db, fs }, args) {
  const dni = (args[0] || '').replace(/\D+/g, '');
  if (!dni) {
    await msg.reply(
      'Uso: /test-aviso <DNI>\nEj: /test-aviso 12345678'
    );
    return;
  }
  const empSnap = await db.collection('EMPLEADOS').doc(dni).get();
  if (!empSnap.exists) {
    await msg.reply(`No encontré un empleado con DNI ${dni} en EMPLEADOS.`);
    return;
  }
  const data = empSnap.data() || {};
  const tel = String(data.TELEFONO || '').trim();
  if (!tel) {
    await msg.reply(`El empleado ${dni} no tiene TELEFONO cargado.`);
    return;
  }
  const nombre = String(data.NOMBRE || dni).trim();

  const admin = require('firebase-admin');
  const ahora = new Date().toLocaleString('es-AR', {
    timeZone: 'America/Argentina/Buenos_Aires',
  });
  const colaRef = await db.collection(fs.COLECCION).add({
    telefono: tel,
    mensaje:
      `🔧 *Mensaje de prueba — Coopertrans Móvil*\n\n` +
      `Este es un mensaje de prueba para verificar que recibís ` +
      `correctamente las notificaciones del bot.\n\n` +
      `Disparado: ${ahora} ART.\n\n` +
      `Si ves este mensaje, el canal está OK. No hay que responder.`,
    estado: fs.ESTADO.pendiente,
    encolado_en: admin.firestore.FieldValue.serverTimestamp(),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: 'comando_test_aviso',
    destinatario_coleccion: 'EMPLEADOS',
    destinatario_id: dni,
    campo_base: 'TEST_AVISO',
    admin_dni: 'BOT',
    admin_nombre: 'Bot test-aviso',
  });

  await msg.reply(
    `✓ Mensaje de prueba encolado para ${nombre} (DNI ${dni}, tel ${tel}).\n` +
    `Doc cola: ${colaRef.id}\n\n` +
    `Si está fuera de horario hábil, se envía cuando reabra la ventana.`
  );
}

/**
 * Devuelve la fecha actual en formato YYYY-MM-DD ART. Usado para
 * mostrar al chofer "esta es tu jornada de hoy (FECHA)".
 *
 * Nota histórica: antes este formato era el sufijo del docId de
 * `JORNADAS_CHOFER` (legacy v1). Desde el refactor v2 (2026-05-15)
 * la jornada es lógica con docId `{dni}_{ts_inicio_ms}` y se busca
 * por query — esta fecha es solo cosmética para el mensaje.
 */
function _fechaArt() {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Argentina/Buenos_Aires',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

/**
 * Formatea segundos a "Xh YYm" — versión compacta para WhatsApp.
 * Si es < 1h, "Xm". Si es 0, "0m".
 */
function _fmtSegCompacto(seg) {
  const s = Math.max(0, Math.floor(seg || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (h === 0) return `${m}m`;
  return `${h}h ${m.toString().padStart(2, '0')}m`;
}

function _fmtFechaHoraCompacto(ts) {
  if (!ts) return null;
  const d = ts.toDate ? ts.toDate() : new Date(ts);
  return new Intl.DateTimeFormat('es-AR', {
    timeZone: 'America/Argentina/Buenos_Aires',
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(d);
}

/**
 * `/jornada [DNI]` → estado del vigilador v2 (refactor 2026-05-15).
 *
 * Lee de `JORNADAS` (nueva colección con modelo de bloques 3×4h +
 * descanso 8h misma posición). ANTES (legacy v1) leía de
 * `JORNADAS_CHOFER` con docId `{dni}_{YYYY-MM-DD}` — esa colección
 * ya no se popula, por lo que el comando devolvía SIEMPRE "sin
 * actividad" (auditoría 2026-05-17, crítico).
 *
 * Ahora busca la jornada abierta del chofer (`jornada_fin_ts == null`).
 * Si no existe → "Sin jornada activa" (chofer no manejó o jornada
 * cerrada por descanso 8h).
 *
 * Dos modos:
 *   - **Admin**: `/jornada <DNI>`. Output técnico completo.
 *   - **Chofer**: solo `/jornada`. Output amable en segunda persona.
 */
async function _comandoJornada(msg, { db }, args, chofer) {
  // Resolver el DNI a consultar.
  let dni;
  if (chofer) {
    dni = chofer.dni;
  } else {
    dni = (args[0] || '').replace(/\D+/g, '');
    if (!dni) {
      await msg.reply('Uso: /jornada <DNI>\nEj: /jornada 12345678');
      return;
    }
  }

  const fecha = _fechaArt();

  // Buscar jornada abierta (v2: chofer_dni == dni AND jornada_fin_ts == null).
  // Requiere índice compuesto `chofer_dni ASC + jornada_fin_ts ASC` que ya
  // está en firestore.indexes.json desde el refactor v2.
  const [empSnap, jQuery, silSnap] = await Promise.all([
    db.collection('EMPLEADOS').doc(dni).get(),
    db.collection('JORNADAS')
      .where('chofer_dni', '==', dni)
      .where('jornada_fin_ts', '==', null)
      .limit(1)
      .get(),
    db.collection('BOT_SILENCIADOS_CHOFER').doc(dni).get(),
  ]);

  const jSnap = jQuery.empty ? null : jQuery.docs[0];

  // ─── Modo CHOFER ─────────────────────────────────────────
  if (chofer) {
    return _replyJornadaChofer(msg, { chofer, jSnap, silSnap, fecha });
  }

  // ─── Modo ADMIN — output técnico ─────────────────────────
  const lineas = [`*Jornada del chofer ${dni}* (consulta ${fecha})`];

  if (empSnap.exists) {
    const e = empSnap.data() || {};
    const nombre = (e.NOMBRE || '(sin nombre)').toString();
    const vehAsignado = (e.VEHICULO || '').toString().trim();
    lineas.push(`👤 ${nombre}${vehAsignado ? ` · ${vehAsignado}` : ''}`);
  } else {
    lineas.push('⚠ DNI no figura en EMPLEADOS.');
  }

  if (silSnap.exists) {
    const s = silSnap.data() || {};
    const hasta = s.silenciado_hasta;
    const hastaMs = hasta && hasta.toMillis ? hasta.toMillis() : 0;
    if (hastaMs > Date.now()) {
      const motivo = (s.motivo || '(sin motivo)').toString();
      lineas.push(
        `🔕 SILENCIADO hasta ${_fmtFechaHoraCompacto(hasta)} ART · ${motivo}`
      );
    }
  }

  if (!jSnap) {
    lineas.push('');
    lineas.push(
      'Sin jornada activa — el chofer no manejó en las últimas horas, ' +
      'ya completó su descanso de 8h, o no está identificado por iButton.'
    );
    await msg.reply(lineas.join('\n'));
    return;
  }

  const j = jSnap.data() || {};
  // Campos v2 (ver `functions/src/jornadas_v2.ts:66+ JornadaDoc`).
  const totalManejo = j.total_manejo_seg || 0;
  const bloqueActualManejo = j.bloque_actual_manejo_seg || 0;
  const bloqueActualPausa = j.bloque_actual_pausa_seg || 0;
  const bloquesCompletos = j.bloques_completos || 0;
  const estado = (j.estado || '').toString();
  const descansoSeg = j.descanso_segundos || 0;
  // Manejo NETO real = total acumulado en bloques cerrados + bloque actual.
  // Este es el criterio nuevo (post Santiago 2026-05-19) para el aviso
  // de 12h jornada — antes era `bloques_completos >= 3` pero un bloque
  // se cuenta con cualquier manejo previo + pausa 15+ min, no garantiza
  // que el chofer realmente manejó 12h. Límite = 12h manejo neto (las
  // paradas obligatorias de 15 min suceden DENTRO de las 12h).
  const manejoNeto = totalManejo + bloqueActualManejo;
  const JORNADA_LIMITE_SEG = 12 * 3600;

  lineas.push('');
  lineas.push(`🚛 Manejo neto total: ${_fmtSegCompacto(manejoNeto)} / 12h ` +
    `(criterio aviso de jornada)`);
  lineas.push(`   Bloques cerrados (>=15 min pausa): ${bloquesCompletos} · ` +
    `Acumulado cerrados: ${_fmtSegCompacto(totalManejo)}`);
  lineas.push(`⏱ Bloque actual: ${_fmtSegCompacto(bloqueActualManejo)} manejo` +
    (bloqueActualPausa > 0 ?
      ` · ${_fmtSegCompacto(bloqueActualPausa)} pausa` : ''));
  lineas.push(`📍 Estado: ${estado || '—'}`);

  if (descansoSeg > 0) {
    lineas.push(`🛏 Descanso acumulado: ${_fmtSegCompacto(descansoSeg)} ` +
      '(min 8h para cerrar jornada)');
  }

  // Flags de aviso enviados / infracciones detectadas.
  const flags = [];
  if (j.alerta_3_30_enviada) flags.push('3h30 (manejo continuo)');
  if (j.alerta_3_45_enviada) flags.push('3h45 (deprecated)');
  if (j.alerta_cuota_proxima_enviada) flags.push('11h jornada (heads-up)');
  if (j.alerta_cuota_enviada) flags.push('12h jornada (límite)');
  if (j.alerta_veda_enviada) flags.push('veda-nocturna');
  if (flags.length > 0) {
    lineas.push(`🚨 Avisos enviados: ${flags.join(', ')}`);
  } else {
    lineas.push('✓ Sin alertas en esta jornada.');
  }
  const infracciones = [];
  if (j.bloque_excedido) infracciones.push('bloque excedido (>4h sin pausa)');
  if (j.cuota_excedida) infracciones.push('cuota excedida (>12h manejo neto)');
  if (j.veda_excedida) infracciones.push('manejo en veda nocturna');
  if (infracciones.length > 0) {
    lineas.push(`⚠ Infracciones: ${infracciones.join(', ')}`);
  }

  if (j.ultima_actualizacion_ts) {
    lineas.push(`🛰 Último update: ` +
      `${_fmtFechaHoraCompacto(j.ultima_actualizacion_ts)} ART`);
  }
  if (j.ultima_patente) {
    lineas.push(`🚐 Patente: ${j.ultima_patente}`);
  }

  await msg.reply(lineas.join('\n'));
}

/**
 * Output simplificado del `/jornada` para el chofer.
 *
 * Decisión de wording: tono cercano, en segunda persona, sin
 * tecnicismos. Foco en lo que le importa al chofer:
 *   - "Cuánto manejaste hoy / cuánto te queda antes del límite"
 *   - "¿Estás cerca de tener que parar continuo? (4h)"
 *   - "Si te avisamos algo, qué fue"
 *   - "Si no podés arrancar todavía, hasta cuándo descansar"
 *   - "Si te silenciamos los avisos, hasta cuándo"
 *
 * NO le mostramos: total_dia vs jornada_actual (le confunde), flags
 * raw, último update Sitrack, último doc id, etc.
 */
async function _replyJornadaChofer(msg, opts) {
  await msg.reply(_construirTextoJornadaChofer(opts));
}

/**
 * `/enviar-jornada <DNI>` (solo admin) → encola al CHOFER el mismo texto
 * que vería si tipeara `/jornada`. Santiago 2026-05-19: útil cuando el
 * admin quiere que el chofer vea su estado sin tener que pedirlo (ej.
 * discutiendo horas, recordatorio de descanso, etc.).
 *
 * Reusa `_construirTextoJornadaChofer`. Encola en COLA_WHATSAPP con
 * origen time-sensitive `jornada_manual_admin` + TTL 30 min (el estado
 * de jornada cambia con cada tick — si se entrega muy tarde estaría
 * desactualizado, mejor que expire).
 *
 * Si el chofer está silenciado, NO encola y avisa al admin (el consumer
 * lo skipearía de todos modos — mejor avisar de antemano y no generar
 * un doc fantasma).
 */
async function _comandoEnviarJornada(msg, { db, fs }, args) {
  const dni = (args[0] || '').replace(/\D+/g, '');
  if (!dni) {
    await msg.reply(
      'Uso: /enviar-jornada <DNI>\nEj: /enviar-jornada 12345678'
    );
    return;
  }

  const fecha = _fechaArt();
  const [empSnap, jQuery, silSnap] = await Promise.all([
    db.collection('EMPLEADOS').doc(dni).get(),
    db.collection('JORNADAS')
      .where('chofer_dni', '==', dni)
      .where('jornada_fin_ts', '==', null)
      .limit(1)
      .get(),
    db.collection('BOT_SILENCIADOS_CHOFER').doc(dni).get(),
  ]);

  if (!empSnap.exists) {
    await msg.reply(`No encontré un empleado con DNI ${dni} en EMPLEADOS.`);
    return;
  }
  const data = empSnap.data() || {};
  const tel = String(data.TELEFONO || '').trim();
  if (!tel) {
    await msg.reply(`El empleado ${dni} no tiene TELEFONO cargado.`);
    return;
  }
  const nombre = String(data.NOMBRE || dni).trim();

  // Si está silenciado, no encolar — avisar al admin.
  if (silSnap.exists) {
    const s = silSnap.data() || {};
    const hasta = s.silenciado_hasta;
    const hastaMs = hasta && hasta.toMillis ? hasta.toMillis() : 0;
    if (hastaMs > Date.now()) {
      await msg.reply(
        `🔕 ${nombre} (DNI ${dni}) está silenciado hasta ` +
        `${_fmtFechaHoraCompacto(hasta)} ART.\n\n` +
        `El mensaje no se enviaría. Usá /desilenciar ${dni} primero ` +
        `si querés mandarle la jornada igual.`
      );
      return;
    }
  }

  const jSnap = jQuery.empty ? null : jQuery.docs[0];
  const chofer = _mapChofer(dni, data);
  const texto = _construirTextoJornadaChofer({ chofer, jSnap, silSnap, fecha });

  // TTL 30 min: el estado de jornada es time-sensitive. Si el bot está
  // caído y se entrega tarde, el contenido estaría desactualizado.
  const admin = require('firebase-admin');
  const expiraEn = admin.firestore.Timestamp.fromMillis(
    Date.now() + 30 * 60 * 1000
  );
  const colaRef = await db.collection(fs.COLECCION).add({
    telefono: tel,
    mensaje: texto,
    estado: fs.ESTADO.pendiente,
    encolado_en: admin.firestore.FieldValue.serverTimestamp(),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: 'jornada_manual_admin',
    expira_en: expiraEn,
    destinatario_coleccion: 'EMPLEADOS',
    destinatario_id: dni,
    campo_base: 'JORNADA',
    admin_dni: 'BOT',
    admin_nombre: 'Bot /enviar-jornada',
  });

  await msg.reply(
    `✓ Jornada encolada para ${nombre} (DNI ${dni}, tel ${tel}).\n` +
    `Doc cola: ${colaRef.id}\n\n` +
    (jSnap
      ? 'El chofer recibe su estado actual de jornada.'
      : 'El chofer no tiene jornada activa — recibe ese aviso.')
  );
}

/**
 * Construye el texto del estado de jornada en 2ª persona (el mismo que
 * ve el chofer al tipear `/jornada`). Extraído de `_replyJornadaChofer`
 * para poder reusarlo desde `/enviar-jornada <DNI>` (comando admin que
 * encola este mismo texto al chat del chofer). Santiago 2026-05-19.
 *
 * Recibe `{ chofer, jSnap, silSnap, fecha }` y devuelve un string.
 */
function _construirTextoJornadaChofer({ chofer, jSnap, silSnap, fecha }) {
  const apodo = chofer.apodo || _primerNombreDe({ NOMBRE: chofer.nombre });
  const saludo = apodo ? `Hola ${apodo}` : 'Hola';
  const lineas = [`${saludo}, este es el estado de tu jornada de manejo (${fecha}):`];
  lineas.push('');

  // Aviso de silencio — útil para que el chofer entienda por qué no
  // recibe avisos del bot.
  if (silSnap.exists) {
    const s = silSnap.data() || {};
    const hasta = s.silenciado_hasta;
    const hastaMs = hasta && hasta.toMillis ? hasta.toMillis() : 0;
    if (hastaMs > Date.now()) {
      lineas.push(
        `🔕 *Tus avisos del bot están silenciados* hasta las ` +
        `${_fmtFechaHoraCompacto(hasta)} ART.`
      );
      lineas.push('');
    }
  }

  if (!jSnap) {
    lineas.push(
      'No tenés jornada activa ahora — o no manejaste en las últimas horas, ' +
      'o ya terminaste tu descanso de 8 hs.'
    );
    return lineas.join('\n');
  }

  // Modelo v2 (refactor Santiago 2026-05-19):
  // - Manejo continuo dentro de un bloque: hasta 3h45, debe pausar 15+ min.
  // - Manejo neto total por jornada: hasta 12h (límite — las paradas de
  //   15 min suceden DENTRO de las 12h).
  // - Descanso entre jornadas: 8h misma posición para cerrar.
  // Avisos al chofer basados en MANEJO NETO (no en cuenta de bloques) —
  // antes con `bloques_completos >= 3` un chofer con pausas cortas y
  // frecuentes recibía "12h jornada" con solo 7-8h manejo real.
  const j = jSnap.data() || {};
  const totalManejoSeg = j.total_manejo_seg || 0;
  const bloqueActualManejo = j.bloque_actual_manejo_seg || 0;
  const bloqueActualPausa = j.bloque_actual_pausa_seg || 0;
  const descansoSeg = j.descanso_segundos || 0;
  const estado = (j.estado || '').toString();
  const manejoNetoSeg = totalManejoSeg + bloqueActualManejo;

  const TRAMO_LIMITE_SEG = 3 * 3600 + 45 * 60; // 3h45 manejo continuo
  const JORNADA_LIMITE_SEG = 12 * 3600;         // 12h manejo neto = límite
  const DESCANSO_MIN_SEG = 8 * 3600;

  // Resumen del tramo actual.
  // Decisión Santiago 2026-05-18: NO hablamos de "bloques" con el
  // chofer. Lenguaje natural: "horas manejadas" + "12 horas de
  // jornada" + "8 horas de descanso".
  if (manejoNetoSeg >= JORNADA_LIMITE_SEG) {
    lineas.push('✅ *Llegaste al límite de tu jornada diaria (12 horas).*');
    lineas.push('   Estás en descanso obligatorio (mínimo 8 hs) antes de retomar.');
  } else {
    lineas.push(`🚛 Manejo actual sin pausar: ` +
      `*${_fmtSegCompacto(bloqueActualManejo)}*` +
      ` (límite ${_fmtSegCompacto(TRAMO_LIMITE_SEG)} antes de parar)`);
    const restanteBloque = TRAMO_LIMITE_SEG - bloqueActualManejo;
    if (restanteBloque > 0) {
      lineas.push(`   Te quedan *${_fmtSegCompacto(restanteBloque)}* antes ` +
        'de tu pausa obligatoria de 20 min.');
    } else {
      lineas.push('   *Te pasaste del límite.* Pará y descansá 20 min.');
    }
    if (bloqueActualPausa > 0) {
      lineas.push(`   ⏸ Pausa actual: ${_fmtSegCompacto(bloqueActualPausa)}.`);
    }
    lineas.push('');
    const restanteJornada = JORNADA_LIMITE_SEG - manejoNetoSeg;
    lineas.push(`🚛 Total manejado en la jornada: ${_fmtSegCompacto(manejoNetoSeg)} ` +
      `de 12 hs (te quedan *${_fmtSegCompacto(restanteJornada)}* ` +
      'antes del límite de jornada)');
  }

  // Estado de descanso (cuando está parado, mostramos progreso hacia las 8h).
  if (descansoSeg > 0 && manejoNetoSeg < JORNADA_LIMITE_SEG) {
    lineas.push('');
    lineas.push(`🛏 Descanso acumulado: ${_fmtSegCompacto(descansoSeg)} ` +
      `(necesitás ${_fmtSegCompacto(DESCANSO_MIN_SEG)} para cerrar jornada)`);
  }

  // Avisos enviados — los que importan al chofer en lenguaje natural.
  const avisos = [];
  if (j.alerta_3_30_enviada) {
    avisos.push('🟡 Te avisamos que tenés que parar a descansar 20 min.');
  }
  // Aviso 3h45 ELIMINADO 2026-05-18 (era spam — ya avisamos en 3h30).
  // alerta_3_45_enviada queda en el schema por backward-compat con
  // docs viejos pero no se muestra aca.
  if (j.bloque_excedido) {
    avisos.push('🚨 Pasaste las 4 hs de manejo continuo — registrado ' +
      'como infracción.');
  }
  if (j.alerta_cuota_proxima_enviada && !j.alerta_cuota_enviada) {
    avisos.push('🟠 Llevás 11 horas de manejo en esta jornada. ' +
      'Te queda 1 hora antes del límite.');
  }
  if (j.alerta_cuota_enviada) {
    avisos.push('🔴 Llegaste al límite de tu jornada diaria (12 horas). ' +
      'No podés manejar más hasta tener 8 hs de descanso de corrido.');
  }
  if (j.alerta_veda_enviada) {
    avisos.push('🌙 Estás manejando en horario de veda nocturna (00:00-06:00).');
  }
  if (avisos.length > 0) {
    lineas.push('');
    lineas.push('*Avisos de esta jornada:*');
    for (const a of avisos) {
      lineas.push(a);
    }
  }

  // Estado descriptivo final.
  if (estado === 'descanso_jornada') {
    lineas.push('');
    lineas.push('✅ Jornada cerrada por descanso de 8h.');
  }

  return lineas.join('\n');
}

/**
 * `/silenciar <DNI> <duración> [motivo...]` → suprime los avisos del
 * vigilador de jornada para ese chofer durante la duración indicada.
 * Útil cuando el chofer está en taller, hay GPS roto, problema
 * conocido, etc. — sino el bot lo molesta cada 5 min.
 *
 * Persiste en `BOT_SILENCIADOS_CHOFER/{dni}`. La cloud function del
 * vigilador chequea ese doc antes de encolar cada aviso (al chofer
 * y a los admins).
 *
 * Reusa `_parsearDuracion` (Ns/Nm/Nh/Nd, cap 30 días).
 */
async function _comandoSilenciar(msg, { db, fs }, args) {
  if (args.length < 2) {
    await msg.reply(
      'Uso: /silenciar <DNI> <duración> [motivo]\n' +
      'Ej: /silenciar 12345678 2h en taller\n' +
      'Duración: Ns / Nm / Nh / Nd. Cap: 30d.'
    );
    return;
  }
  const dni = (args[0] || '').replace(/\D+/g, '');
  if (!dni) {
    await msg.reply('DNI inválido. Solo dígitos.');
    return;
  }
  const ms = _parsearDuracion(args[1]);
  if (ms == null) {
    await msg.reply(
      `❌ Duración inválida: "${args[1]}".\n` +
      'Formato: Ns / Nm / Nh / Nd (ej: 30m, 2h, 1d). Cap: 30d.'
    );
    return;
  }
  const motivo = args.slice(2).join(' ').trim() || '(sin motivo)';
  const hasta = new Date(Date.now() + ms);

  // Verificar que el chofer exista — sino el silenciado queda colgado
  // sin mapeo a empleado.
  const empSnap = await db.collection('EMPLEADOS').doc(dni).get();
  if (!empSnap.exists) {
    await msg.reply(`No encontré un empleado con DNI ${dni} en EMPLEADOS.`);
    return;
  }
  const empData = empSnap.data() || {};
  const nombre = (empData.NOMBRE || dni).toString();

  const admin = require('firebase-admin');
  await db.collection('BOT_SILENCIADOS_CHOFER').doc(dni).set({
    chofer_dni: dni,
    chofer_nombre: nombre,
    silenciado_hasta: admin.firestore.Timestamp.fromDate(hasta),
    motivo,
    silenciado_at: admin.firestore.FieldValue.serverTimestamp(),
    silenciado_por_canal: 'WHATSAPP_COMMAND',
    duracion_raw: args[1],
  });

  // Avisarle al chofer que sus notificaciones del bot quedaron
  // silenciadas (pedido Santiago 2026-05-13). Útil para que el
  // chofer sepa que el vigilador no lo va a molestar mientras está
  // en taller / problema conocido.
  let avisoChoferRes = '';
  try {
    const enviado = await _encolarMensajeChofer(db, fs, {
      empData,
      dni,
      mensaje:
        `Hola ${_primerNombreDe(empData) || nombre},\n\n` +
        `Las notificaciones automáticas del bot de Coopertrans Móvil ` +
        `quedaron *silenciadas por ${args[1]}* ` +
        `(hasta ${_fmtFechaHoraCompacto(hasta)} ART).\n\n` +
        `Motivo: ${motivo}\n\n` +
        `Cuando se cumpla el plazo te aviso que se reanudan.\n\n` +
        `_Bot-On — Coopertrans Móvil_`,
      origen: 'silenciado_aviso',
      campoBase: 'BOT_SILENCIADO',
    });
    avisoChoferRes = enviado
      ? '\n📨 Aviso al chofer encolado.'
      : '\n⚠ No se pudo avisar al chofer (sin teléfono).';
  } catch (e) {
    avisoChoferRes = `\n⚠ Falló encolar aviso al chofer: ${e.message}`;
  }

  await msg.reply(
    `🔕 ${nombre} (DNI ${dni}) silenciado hasta ` +
    `${_fmtFechaHoraCompacto(hasta)} ART.\n` +
    `Motivo: ${motivo}` +
    avisoChoferRes + '\n\n' +
    'El vigilador no le manda avisos hasta esa hora. ' +
    'Para revertir antes: /desilenciar ' + dni
  );
}

/**
 * `/desilenciar <DNI>` → revierte un /silenciar previo. Borra el doc
 * de BOT_SILENCIADOS_CHOFER. Idempotente — si no estaba silenciado,
 * igual responde OK.
 *
 * Si el silencio estaba activo (no expirado), avisa al chofer que se
 * reanudaron las notificaciones — sino el chofer no se entera del
 * cambio. Si ya estaba expirado (o nunca existió), saltea el aviso
 * (la cron `procesarSilenciadosExpirados` ya lo notificó al expirar).
 */
async function _comandoDesilenciar(msg, { db, fs }, args) {
  const dni = (args[0] || '').replace(/\D+/g, '');
  if (!dni) {
    await msg.reply('Uso: /desilenciar <DNI>\nEj: /desilenciar 12345678');
    return;
  }
  const ref = db.collection('BOT_SILENCIADOS_CHOFER').doc(dni);
  const snap = await ref.get();
  let avisoChoferRes = '';

  if (snap.exists) {
    const s = snap.data() || {};
    const hastaMs = (s.silenciado_hasta && s.silenciado_hasta.toMillis)
      ? s.silenciado_hasta.toMillis()
      : 0;
    const estabaActivo = hastaMs > Date.now();
    if (estabaActivo) {
      try {
        const empSnap = await db.collection('EMPLEADOS').doc(dni).get();
        const empData = empSnap.exists ? (empSnap.data() || {}) : null;
        if (empData) {
          const enviado = await _encolarMensajeChofer(db, fs, {
            empData,
            dni,
            mensaje:
              `Hola ${_primerNombreDe(empData) || dni},\n\n` +
              `Se levantó el silencio de las notificaciones del bot ` +
              `antes del plazo previsto.\n\n` +
              `*Las notificaciones automáticas vuelven a estar activas.*\n\n` +
              `_Bot-On — Coopertrans Móvil_`,
            origen: 'desilenciado_aviso',
            campoBase: 'BOT_DESILENCIADO',
          });
          avisoChoferRes = enviado
            ? '\n📨 Aviso de reanudación encolado.'
            : '\n⚠ No se pudo avisar al chofer (sin teléfono).';
        } else {
          avisoChoferRes = '\n⚠ No encuentro EMPLEADOS/' + dni +
            ' — sin aviso.';
        }
      } catch (e) {
        avisoChoferRes = `\n⚠ Falló encolar aviso al chofer: ${e.message}`;
      }
    }
  }

  await ref.delete();
  await msg.reply(
    `✓ Silencio levantado para DNI ${dni}. ` +
    'El vigilador vuelve a operar normal con este chofer.' +
    avisoChoferRes
  );
}

/**
 * Encola un mensaje al teléfono del chofer dado en COLA_WHATSAPP.
 * Devuelve `true` si quedó encolado, `false` si el chofer está
 * inactivo o no tiene teléfono. Lanza error en fallos de Firestore.
 *
 * Centraliza el formato del doc para que `_comandoSilenciar` y
 * `_comandoDesilenciar` no dupliquen el shape.
 */
async function _encolarMensajeChofer(
  db, fs, { empData, dni, mensaje, origen, campoBase }
) {
  if (empData.ACTIVO === false) return false;
  const tel = String(empData.TELEFONO || '').trim();
  if (!tel || tel === '-') return false;

  const admin = require('firebase-admin');
  // TTL Fase 2 (2026-05-18): confirmaciones de silenciar/desilenciar
  // son time-sensitive — si la confirmacion tarda mas de 15 min, el
  // chofer ya esta operando con la suposicion equivocada. Mejor
  // silencio que confirmacion tardia.
  const expiraEn = admin.firestore.Timestamp.fromMillis(
    Date.now() + 15 * 60 * 1000
  );
  await db.collection(fs.COLECCION).add({
    telefono: tel,
    mensaje,
    estado: fs.ESTADO.pendiente,
    encolado_en: admin.firestore.FieldValue.serverTimestamp(),
    expira_en: expiraEn,
    enviado_en: null,
    error: null,
    intentos: 0,
    origen,
    destinatario_coleccion: 'EMPLEADOS',
    destinatario_id: dni,
    campo_base: campoBase,
    admin_dni: 'BOT',
    admin_nombre: 'Bot silenciador',
  });
  return true;
}

/**
 * Devuelve el primer nombre o apodo del empleado para saludarlo —
 * matching del patrón usado por los avisos del vigilador.
 */
function _primerNombreDe(empData) {
  const apodo = String(empData.APODO || '').trim();
  if (apodo) return apodo;
  const nom = String(empData.NOMBRE || '').trim();
  if (!nom) return '';
  return nom.split(/\s+/)[0] || '';
}

module.exports = {
  manejarSiEsComando,
  // Exportado para tests.
  _esAdmin,
  _adminWhitelist,
  _construirTextoJornadaChofer,
  _resolverChoferPorTelefono,
  MIN_DIGITOS_PARA_MATCH,
};
