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

const log = require('./logger');

// Minimo de digitos para que un sufijo cuente como match. Argentina
// tiene 10 (sin codigo pais) -- un numero corto como "4567890" NO
// puede matchear con admin "5492914567890". Antes el match laxo
// permitia que cualquier numero terminado en 7 digitos del admin
// ejecute /pausar, /forzar-cron, etc.
const MIN_DIGITOS_PARA_MATCH = 10;

/**
 * Devuelve la lista de teléfonos admin autorizados (solo dígitos).
 */
function _adminWhitelist() {
  const raw = process.env.ADMIN_PHONES || '';
  return raw
    .split(',')
    .map((s) => s.trim().replace(/\D+/g, ''))
    .filter((s) => s.length >= MIN_DIGITOS_PARA_MATCH);
}

/**
 * `true` si el teléfono que envió el mensaje está autorizado.
 *
 * Acepta: igualdad estricta, o sufijo de >= MIN_DIGITOS_PARA_MATCH
 * digitos. El sufijo es necesario porque whitelist puede tener
 * "5492914567890" (con codigo pais) y el numero entrante venir como
 * "2914567890" (sin codigo pais), o viceversa. Pero NUNCA se acepta
 * un sufijo corto: "4567890" NO matchea.
 */
function _esAdmin(fromNumber) {
  const fromDigits = String(fromNumber).replace(/\D+/g, '');
  if (fromDigits.length < MIN_DIGITOS_PARA_MATCH) return false;
  const whitelist = _adminWhitelist();
  return whitelist.some((w) => {
    if (w === fromDigits) return true;
    const longer = w.length >= fromDigits.length ? w : fromDigits;
    const shorter = w.length < fromDigits.length ? w : fromDigits;
    return shorter.length >= MIN_DIGITOS_PARA_MATCH &&
      longer.endsWith(shorter);
  });
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
 * Resuelve el chofer (DNI + datos) que envía un mensaje. Intenta dos
 * estrategias en orden:
 *
 *   1. **Match por teléfono** (preferido): igualdad estricta en la
 *      representación normalizada (solo dígitos) o sufijo de
 *      >= MIN_DIGITOS_PARA_MATCH dígitos. Funciona cuando el msg viene
 *      de `@c.us` (chats con contactos guardados) o de un `@lid` en
 *      el que `getContact()` resuelve el número canónico.
 *
 *   2. **Match por pushname** (fallback): si el chofer manda desde un
 *      `@lid` y el bot no resolvió el teléfono, intentamos identificar
 *      por el nombre que el chofer puso en su perfil de WhatsApp. Esto
 *      pasó el 2026-05-14: choferes mandando `/jornada` desde números
 *      no agendados en el bot — el LID no matchea ningún teléfono y
 *      el bot quedaba en silencio. Match conservador para evitar
 *      falsos positivos:
 *        - si el `pushname` matchea EXACTO el APODO de un chofer (case-
 *          insensitive); o
 *        - si el `pushname` tiene 2+ tokens y TODOS están contenidos
 *          en el NOMBRE de UN solo chofer (apellido + nombre, ej.
 *          "Bastias Horacio" matchea "BASTIAS HORACIO RENE").
 *      Si más de 1 chofer matchea, devolvemos null (ambiguo).
 *
 * Devuelve null si:
 *   - Ningún empleado matchea por teléfono ni pushname.
 *   - El empleado matcheado no es CHOFER (admins/planta no se resuelven acá).
 *   - El empleado está marcado ACTIVO=false.
 *
 * Implementación: lee TODOS los empleados con ROL=CHOFER y filtra en
 * memoria. Para Vecchi son ~50 chofers — query baratísimo (1 read por
 * comando del chofer, no por chofer). Si la flota crece a > 500, se
 * puede pasar a un índice por sufijo de teléfono.
 */
async function _resolverChoferPorTelefono(db, fromNumber, opts = {}) {
  const pushname = (opts.pushname || '').toString().trim();
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

  // ─── 1. Match por teléfono ───
  if (fromDigits.length >= MIN_DIGITOS_PARA_MATCH) {
    for (const d of snap.docs) {
      const data = d.data() || {};
      if (data.ACTIVO === false) continue;
      const telDigits = String(data.TELEFONO || '').replace(/\D+/g, '');
      if (telDigits.length < MIN_DIGITOS_PARA_MATCH) continue;
      if (telDigits === fromDigits) return _mapChofer(d.id, data);
      const longer = telDigits.length >= fromDigits.length ?
        telDigits :
        fromDigits;
      const shorter = telDigits.length < fromDigits.length ?
        telDigits :
        fromDigits;
      if (
        shorter.length >= MIN_DIGITOS_PARA_MATCH &&
        longer.endsWith(shorter)
      ) {
        return _mapChofer(d.id, data);
      }
    }
  }

  // ─── 2. Match por pushname (fallback para @lid sin teléfono real) ───
  if (pushname.length >= 3) {
    const pushUp = pushname.toUpperCase();
    const pushTokens = pushUp.split(/\s+/).filter((t) => t.length >= 3);
    const matches = [];
    for (const d of snap.docs) {
      const data = d.data() || {};
      if (data.ACTIVO === false) continue;
      const nombre = String(data.NOMBRE || '').toUpperCase();
      const apodo = String(data.APODO || '').toUpperCase();
      // Match exacto por apodo (caso "Pipi" === "PIPI").
      if (apodo && apodo === pushUp) {
        matches.push(_mapChofer(d.id, data));
        continue;
      }
      // Match por NOMBRE conteniendo TODOS los tokens del pushname.
      // Requiere 2+ tokens para evitar falsos positivos
      // (ej. pushname="Juan" matchearía con varios JUAN ...).
      if (
        nombre &&
        pushTokens.length >= 2 &&
        pushTokens.every((t) => nombre.includes(t))
      ) {
        matches.push(_mapChofer(d.id, data));
      }
    }
    if (matches.length === 1) {
      log.info(
        `Chofer resuelto por pushname "${pushname}" → DNI ${matches[0].dni}`
      );
      return matches[0];
    }
    if (matches.length > 1) {
      log.warn(
        `Pushname "${pushname}" matchea ${matches.length} choferes — ambiguo, no resuelvo.`
      );
    }
  }

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
  // y, si no es admin, intentamos resolverlo como CHOFER (con
  // fallback por pushname si el teléfono no matchea — típico @lid).
  const esAdmin = _esAdmin(fromNumber);
  let chofer = null;
  if (!esAdmin) {
    chofer = await _resolverChoferPorTelefono(
      contextos.db,
      fromNumber,
      { pushname }
    );
  }

  if (!esAdmin && !chofer) {
    // Loggeamos pushname para que si no resolvió por dígitos veamos
    // por qué tampoco matcheó por nombre (apodo/nombre incompletos en
    // EMPLEADOS, ambiguo, o el chofer no puso su nombre real).
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

  await db.collection('BOT_CONTROL').doc('main').set(
    {
      pausado: true,
      pausado_en: new Date(),
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
  await db.collection('BOT_CONTROL').doc('main').set(
    {
      pausado: false,
      reanudado_en: new Date(),
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
 * Devuelve la fecha actual en formato YYYY-MM-DD ART. Mismo formato
 * que usa el cron `vigiladorJornadaChofer` para el doc id de
 * `JORNADAS_CHOFER` (`{dni}_{fechaArt}`).
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
 * `/jornada [DNI]` → estado del vigilador.
 *
 * Dos modos:
 *   - **Admin**: pasa DNI explícito (`/jornada 12345678`). Sin DNI =
 *     mensaje de uso. Output completo (todos los flags técnicos).
 *   - **Chofer**: tipea solo `/jornada` (sin DNI). El bot resuelve su
 *     propio DNI por su teléfono y le devuelve sus datos. Output
 *     simplificado en lenguaje natural — "manejaste 8h25 hoy, te
 *     quedan 3h35 antes del límite". Si tipea `/jornada DNI_AJENO`,
 *     el manejador del switch lo descarta (espía bloqueada) — acá
 *     siempre llega `args=[]` para chofer.
 *
 * Si no hay JORNADAS_CHOFER del día, decimos "sin actividad hoy" en
 * lugar del tecnicismo "sin doc".
 */
async function _comandoJornada(msg, { db }, args, chofer) {
  // Resolver el DNI a consultar.
  let dni;
  if (chofer) {
    // Chofer pidió su propia jornada. El switch ya nos pasó args=[]
    // pero por las dudas también ignoramos cualquier args que viniera.
    dni = chofer.dni;
  } else {
    // Admin.
    dni = (args[0] || '').replace(/\D+/g, '');
    if (!dni) {
      await msg.reply('Uso: /jornada <DNI>\nEj: /jornada 12345678');
      return;
    }
  }

  const fecha = _fechaArt();
  const docId = `${dni}_${fecha}`;

  const [empSnap, jSnap, silSnap] = await Promise.all([
    db.collection('EMPLEADOS').doc(dni).get(),
    db.collection('JORNADAS_CHOFER').doc(docId).get(),
    db.collection('BOT_SILENCIADOS_CHOFER').doc(dni).get(),
  ]);

  // ─── Modo CHOFER ─────────────────────────────────────────
  // Output amable, en lenguaje natural, sin tecnicismos.
  if (chofer) {
    return _replyJornadaChofer(msg, { chofer, jSnap, silSnap, fecha });
  }

  // ─── Modo ADMIN ──────────────────────────────────────────
  // Output técnico completo (lo que ya teníamos).
  const lineas = [`*Jornada del chofer ${dni}* (${fecha})`];

  if (empSnap.exists) {
    const e = empSnap.data() || {};
    const nombre = (e.NOMBRE || '(sin nombre)').toString();
    const vehAsignado = (e.VEHICULO || '').toString().trim();
    lineas.push(`👤 ${nombre}${vehAsignado ? ` · ${vehAsignado}` : ''}`);
  } else {
    lineas.push('⚠ DNI no figura en EMPLEADOS.');
  }

  // Estado de silencio — lo mostramos arriba del todo así no se
  // pierde scrolling.
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

  if (!jSnap.exists) {
    lineas.push('');
    lineas.push(
      'Sin doc JORNADAS_CHOFER del día — el chofer no tiene posición ' +
      'activa con su DNI o todavía no manejó hoy.'
    );
    await msg.reply(lineas.join('\n'));
    return;
  }
  const j = jSnap.data() || {};
  const totalDia = j.segundos_total_dia || 0;
  const jornadaActual = j.segundos_jornada_actual || 0;
  const continuo = j.segundos_continuo_actual || 0;
  const pausa = j.segundos_pausa_actual || 0;

  lineas.push('');
  lineas.push(`🚛 Total del día: ${_fmtSegCompacto(totalDia)}`);
  if (jornadaActual > totalDia + 60) {
    // Jornada arrancó el día anterior (cruzó medianoche).
    lineas.push(
      `🕓 Jornada actual: ${_fmtSegCompacto(jornadaActual)} ` +
      '(arrancó ayer)'
    );
  } else {
    lineas.push(`🕓 Jornada actual: ${_fmtSegCompacto(jornadaActual)}`);
  }
  lineas.push(`⏱ Continuo: ${_fmtSegCompacto(continuo)}`);
  if (pausa > 0) {
    lineas.push(`⏸ Pausa actual: ${_fmtSegCompacto(pausa)}`);
  }

  // Flags de alertas — compactas, una sola línea con las que se
  // dispararon. Compat: el campo viejo `alerta_3_45_continua_enviada`
  // (umbral 3:45h) fue reemplazado por `alerta_3_30_continua_enviada`
  // el 2026-05-13. Mostramos cualquiera que esté seteado para que
  // jornadas en curso al deploy se vean correctas.
  const flags = [];
  if (j.alerta_3_30_continua_enviada || j.alerta_3_45_continua_enviada) {
    flags.push('3:30');
  }
  if (j.alerta_4_00_continua_enviada) flags.push('4h-penalizado');
  if (j.alerta_11_30_diaria_enviada) flags.push('11:30');
  if (j.alerta_12_00_diaria_enviada) flags.push('12h-superado');
  if (j.aviso_descanso_corto_enviada) {
    const desc = j.descanso_corto_segundos
      ? ` (descanso ${_fmtSegCompacto(j.descanso_corto_segundos)})`
      : '';
    flags.push(`descanso-corto${desc}`);
  }
  if (j.alerta_arranque_temprano_enviada) {
    flags.push('arranque-temprano');
  }
  if (flags.length > 0) {
    lineas.push(`🚨 Avisos enviados: ${flags.join(', ')}`);
  } else {
    lineas.push('✓ Sin alertas hoy.');
  }

  // Si llegó a 12h, mostrar la hora mínima de arranque calculada —
  // así el operador puede chequear cuándo el chofer puede volver a
  // manejar.
  if (j.hora_min_arranque_at) {
    lineas.push(
      `🌅 Hora mín. arranque: ` +
      `${_fmtFechaHoraCompacto(j.hora_min_arranque_at)} ART`
    );
  }

  if (j.ultima_actualizacion_at) {
    lineas.push(
      `🛰 Último update: ${_fmtFechaHoraCompacto(j.ultima_actualizacion_at)} ART`
    );
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
async function _replyJornadaChofer(msg, { chofer, jSnap, silSnap, fecha }) {
  const apodo = chofer.apodo || _primerNombreDe({ NOMBRE: chofer.nombre });
  const saludo = apodo ? `Hola ${apodo}` : 'Hola';
  const lineas = [`${saludo}, esta es tu jornada de hoy (${fecha}):`];
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

  if (!jSnap.exists) {
    lineas.push('Hoy no manejaste todavía (o el sistema no detectó actividad).');
    await msg.reply(lineas.join('\n'));
    return;
  }

  const j = jSnap.data() || {};
  const jornadaActualSeg = j.segundos_jornada_actual || 0;
  const continuoSeg = j.segundos_continuo_actual || 0;
  const pausaSeg = j.segundos_pausa_actual || 0;
  const LIMITE_DIARIO_SEG = 12 * 3600;
  const LIMITE_CONTINUO_SEG = 4 * 3600;

  // Resumen general.
  lineas.push(`🚛 Llevás manejado: *${_fmtSegCompacto(jornadaActualSeg)}*`);
  const restanteDiario = LIMITE_DIARIO_SEG - jornadaActualSeg;
  if (restanteDiario > 0) {
    lineas.push(`   Te quedan ${_fmtSegCompacto(restanteDiario)} antes del límite de 12 hs.`);
  } else {
    lineas.push('   *Ya superaste las 12 hs diarias.* Tenés que parar.');
  }
  lineas.push('');

  // Manejo continuo.
  lineas.push(`⏱ Continuo sin pausa: *${_fmtSegCompacto(continuoSeg)}*`);
  const restanteContinuo = LIMITE_CONTINUO_SEG - continuoSeg;
  if (continuoSeg === 0 && pausaSeg > 0) {
    lineas.push(`   Estás en pausa (${_fmtSegCompacto(pausaSeg)}).`);
  } else if (restanteContinuo > 0) {
    lineas.push(
      `   Te quedan ${_fmtSegCompacto(restanteContinuo)} antes de tener que parar 15 min.`
    );
  } else {
    lineas.push('   *Ya superaste las 4 hs continuas.* Tenés que parar.');
  }

  // Avisos enviados hoy. Solo los que importan al chofer (no el flag
  // crudo). Lenguaje natural.
  const avisos = [];
  if (j.alerta_3_30_continua_enviada || j.alerta_3_45_continua_enviada) {
    avisos.push('🟡 Te avisamos que faltaban 30 min para tu pausa de 4 hs.');
  }
  if (j.alerta_4_00_continua_enviada) {
    avisos.push('🔴 Cumpliste 4 hs continuas sin pausa — quedaste en falta.');
  }
  if (j.alerta_11_30_diaria_enviada) {
    avisos.push('🟡 Te avisamos que faltaban 30 min para el límite diario.');
  }
  if (j.alerta_12_00_diaria_enviada) {
    avisos.push('🔴 Superaste las 12 hs diarias.');
  }
  if (j.aviso_descanso_corto_enviada) {
    const desc = j.descanso_corto_segundos ?
      _fmtSegCompacto(j.descanso_corto_segundos) :
      'menos de 8 hs';
    avisos.push(`🔴 Arrancaste con descanso corto (${desc} entre jornadas).`);
  }
  if (j.alerta_arranque_temprano_enviada) {
    avisos.push('🔴 Arrancaste antes de la hora mínima de descanso.');
  }
  if (avisos.length > 0) {
    lineas.push('');
    lineas.push('*Avisos de hoy:*');
    for (const a of avisos) {
      lineas.push(a);
    }
  } else {
    lineas.push('');
    lineas.push('✓ Hoy no recibiste avisos del vigilador.');
  }

  // Hora mínima de arranque (si ya cumplió las 12h y el sistema
  // calculó cuándo puede arrancar de nuevo).
  if (j.hora_min_arranque_at) {
    lineas.push('');
    lineas.push(
      `🌅 *No podés arrancar antes de las ` +
      `${_fmtFechaHoraCompacto(j.hora_min_arranque_at)} ART.*`
    );
  }

  await msg.reply(lineas.join('\n'));
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
        `_Mensaje automático._`,
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
              `_Mensaje automático._`,
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
  await db.collection(fs.COLECCION).add({
    telefono: tel,
    mensaje,
    estado: fs.ESTADO.pendiente,
    encolado_en: admin.firestore.FieldValue.serverTimestamp(),
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
  MIN_DIGITOS_PARA_MATCH,
};
