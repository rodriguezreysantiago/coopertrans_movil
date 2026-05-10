// Comandos admin por WhatsApp.
//
// Permite controlar el bot desde el celular del admin sin abrir la app
// ni la PC. El admin manda un mensaje al PROPIO número del bot que
// empieza con `/` y el bot interpreta y responde.
//
// Comandos soportados:
//   /estado          → resumen del bot (cola, último ciclo, pausa).
//   /pausar [Nh|Nd]  → pausa el bot. Opcional: duración (ej. /pausar 24h).
//   /reanudar        → quita la pausa.
//   /forzar-cron     → corre el ciclo del cron ahora (no espera 60min).
//   /ayuda           → lista de comandos.
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
 * Detecta y ejecuta un comando admin. Devuelve `true` si el mensaje
 * fue manejado como comando (haya respondido o no), `false` si NO era
 * un comando — en cuyo caso el message_handler de Fase 3 lo procesa
 * normal.
 */
async function manejarSiEsComando(msg, contextos) {
  const texto = (msg.body || '').trim();
  if (!texto.startsWith('/')) return false;

  // Resolver el número real del remitente:
  //  - Si msg.from termina en @c.us → es un teléfono directo.
  //  - Si termina en @lid (chats con números no agendados en WhatsApp
  //    moderno) → llamamos a msg.getContact() para obtener el número
  //    canónico (msg.from acá es un linked-id interno, no un teléfono).
  let fromNumber = '';
  try {
    const contacto = await msg.getContact();
    if (contacto) {
      fromNumber = contacto.number || (contacto.id && contacto.id.user) || '';
    }
  } catch (_) {
    // ignoramos — fallback al parseo del from
  }
  if (!fromNumber) {
    fromNumber = (msg.from || '').replace(/@(c\.us|lid)$/, '');
  }

  if (!_esAdmin(fromNumber)) {
    log.warn(`Comando recibido de no-admin ${fromNumber}: ${texto.slice(0, 40)}`);
    // No respondemos para no exponer la existencia del comando.
    return true;
  }

  const partes = texto.split(/\s+/);
  const comando = partes[0].toLowerCase();
  const args = partes.slice(1);

  log.info(`Comando admin recibido: ${comando} ${args.join(' ')} de ${fromNumber}`);

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
      case '/ayuda':
      case '/help':
        await _comandoAyuda(msg);
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

async function _comandoAyuda(msg) {
  const txt = [
    '*Comandos disponibles*',
    '',
    '/estado          → resumen del bot.',
    '/pausar [dur]    → pausar envíos. Ej: /pausar 24h',
    '/reanudar        → reanudar envíos.',
    '/forzar-cron     → correr el cron ahora.',
    '/test-aviso DNI  → mandar un mensaje de prueba al DNI indicado.',
    '/ayuda           → este mensaje.',
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

module.exports = {
  manejarSiEsComando,
  // Exportado para tests.
  _esAdmin,
  _adminWhitelist,
  MIN_DIGITOS_PARA_MATCH,
};
