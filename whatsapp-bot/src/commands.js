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
      case '/jornada':
        await _comandoJornada(msg, contextos, args);
        break;
      case '/silenciar':
        await _comandoSilenciar(msg, contextos, args);
        break;
      case '/desilenciar':
        await _comandoDesilenciar(msg, contextos, args);
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
    '/estado                → resumen del bot.',
    '/pausar [dur]          → pausar envíos. Ej: /pausar 24h',
    '/reanudar              → reanudar envíos.',
    '/forzar-cron           → correr el cron ahora.',
    '/test-aviso DNI        → mensaje de prueba al DNI.',
    '/jornada DNI           → estado del vigilador para ese chofer.',
    '/silenciar DNI dur [m] → no mandar avisos a ese chofer. Ej: ' +
      '/silenciar 12345678 2h taller',
    '/desilenciar DNI       → revertir silenciado.',
    '/ayuda                 → este mensaje.',
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
 * `/jornada <DNI>` → estado del vigilador para ese chofer en el día
 * actual ART. Es la versión "para WhatsApp" de
 * `scripts/diagnosticar_vigilador_chofer.js` — más compacta, sin
 * detalles de Sitrack stale.
 *
 * Mostramos:
 *   - Nombre + patente actual del chofer.
 *   - Total del día / jornada actual / continuo / pausa actual.
 *   - Flags de alertas del día (3:45, 11:30, 12:00, descanso corto).
 *   - Estado de silenciado (si aplica) — útil para que Santiago se
 *     acuerde si el chofer está mute.
 *   - Última actualización del poll Sitrack.
 *
 * Si no hay JORNADAS_CHOFER del día (chofer no manejó hoy o el cron
 * no lo vio), lo decimos explícito.
 */
async function _comandoJornada(msg, { db }, args) {
  const dni = (args[0] || '').replace(/\D+/g, '');
  if (!dni) {
    await msg.reply('Uso: /jornada <DNI>\nEj: /jornada 12345678');
    return;
  }
  const fecha = _fechaArt();
  const docId = `${dni}_${fecha}`;

  const [empSnap, jSnap, silSnap] = await Promise.all([
    db.collection('EMPLEADOS').doc(dni).get(),
    db.collection('JORNADAS_CHOFER').doc(docId).get(),
    db.collection('BOT_SILENCIADOS_CHOFER').doc(dni).get(),
  ]);

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
