// Builder del resumen DIARIO de Alertas del Vehicle Alerts API de Volvo.
//
// Espejo conceptual de `aviso_service_builder.js → buildResumenDiario`,
// pero con la metrica "eventos HIGH severity de las ultimas 24h" en
// vez de "tractores con urgencia de service".
//
// Una sola persona (definida por ALERTAS_RESUMEN_DESTINATARIO_DNI en
// .env, normalmente el admin) recibe UN mensaje por dia con el listado
// completo de eventos criticos detectados. Si no hubo eventos en las
// 24h, NO se manda nada (a diferencia del resumen de service que avisa
// "todo OK" — para alertas de manejo el silencio significa "nada que
// reportar" y mandar un mensaje vacio seria ruido).

const { aDdMmYyyyLocal, aLocalTime } = require('./fechas');

// Banner que se muestra al final del mensaje mientras la app esté en
// etapa de prueba. Quitar (junto con su uso en FIRMA) cuando se pase a
// producción real con todos los choferes/admins onboardeados.
const BANNER_TESTING =
  '⚠️ *Etapa de prueba* — si ves un error o algo no encaja, avisanos. ' +
  'No tomes el contenido al 100%.\n\n';

const FIRMA =
  BANNER_TESTING +
  '_Mensaje automático del sistema de gestión Coopertrans Móvil._\n' +
  '_Detalle completo en la app → Alertas._';

// Mapa de alertType (Vehicle Alerts API) a etiqueta legible en
// castellano. Espejo del que vive en el cliente Flutter
// (`admin_volvo_alertas_screen.dart → _etiquetaTipo`). Si aparece un
// tipo nuevo de Volvo, cae al codigo crudo.
const ETIQUETAS_TIPO = {
  DISTANCE_ALERT: 'Cerca del vehículo de adelante',
  IDLING: 'Motor en ralentí',
  OVERSPEED: 'Exceso de velocidad',
  PTO: 'Toma de fuerza activada',
  HARSH: 'Aceleración / frenada brusca',
  GENERIC: 'Evento genérico',
  TELL_TALE: 'Luz de tablero encendida',
  FUEL: 'Cambio anormal de combustible',
  CATALYST: 'Cambio de nivel AdBlue',
  ALARM: 'Alarma anti-robo',
  GEOFENCE: 'Entrada/salida de geocerca',
  SAFETY_ZONE: 'Zona de velocidad reducida',
  TPM: 'Presión de neumático',
  TTM: 'Temperatura de neumático',
  AEBS: 'Frenado automático de emergencia',
  ESP: 'Control de estabilidad',
  DAS: 'Alerta de cansancio',
  LKS: 'Asistente de carril',
  LCS: 'Asistente de cambio de carril',
  UNSAFE_LANE_CHANGE: 'Cambio de carril inseguro',
  TACHO_OUT_OF_SCOPE_MODE_CHANGE: 'Tacógrafo fuera de servicio',
  CARGO: 'Cambio en carga (puerta / temp)',
  ADBLUELEVEL_LOW: 'AdBlue bajo',
  WITHOUT_ADBLUE: 'Sin AdBlue',
  DRIVING_WITHOUT_BEING_LOGGED_IN: 'Conducción sin chofer identificado',
  SEATBELT: 'Cinturón de seguridad sin abrochar',
};

/**
 * Construye el mensaje resumen diario de alertas HIGH de Volvo.
 *
 * @param {object} args
 * @param {string|null} args.destinatarioNombre - Apodo o primer nombre.
 * @param {Array<{
 *   patente: string,
 *   tipo: string,
 *   subTipo: string|null,
 *   choferNombre: string|null,
 *   fechaHora: Date,
 * }>} args.eventos - Eventos HIGH de las ultimas 24h. Si `tipo === 'GENERIC'`
 *   y `subTipo` esta presente, se muestra el subtipo (ej. SEATBELT,
 *   TELL_TALE) en lugar de "Evento generico" — sino el reporte se
 *   convierte en una lista de "Evento generico" sin info util para el
 *   destinatario.
 * @returns {string|null} Mensaje listo para encolar, o null si no hay
 *   eventos (caller decide no encolar).
 */
// Lista negra de alertTypes que NO se incluyen en el resumen HIGH
// del Jefe de Seg e Higiene. Decisión Ale 2026-05-11:
// "Conducción sin chofer identificado" aparece en casi todos los
// choferes de la flota (cuando arrancan el día antes de pasar el
// iButton) y ensucia el reporte sin aportar valor real para Seg e
// Higiene — para ese tema ya hay throttle de "pasá el iButton" en
// el bot. La alerta sigue persistiéndose en VOLVO_ALERTAS y se ve
// en el tablero admin, solo se filtra del resumen WhatsApp.
//
// Si en el futuro hay que sumar más tipos a filtrar, agregar acá +
// documentar el motivo.
const TIPOS_EXCLUIDOS_DEL_RESUMEN = new Set([
  'DRIVING_WITHOUT_BEING_LOGGED_IN',
]);

/**
 * Devuelve el "tipo efectivo" del evento para agrupar/filtrar.
 * Si tipo == GENERIC y hay subTipo (ej. SEATBELT, TELL_TALE), usa
 * el subTipo; sino usa el tipo crudo. Mismo criterio que el `porTipo`
 * de abajo.
 */
function _tipoEfectivo(ev) {
  return (ev.tipo === 'GENERIC' && ev.subTipo) ? ev.subTipo : ev.tipo;
}

function buildResumenDiario({ destinatarioNombre, eventos }) {
  const eventosArr = (Array.isArray(eventos) ? eventos : [])
    .filter((ev) => !TIPOS_EXCLUIDOS_DEL_RESUMEN.has(_tipoEfectivo(ev)));
  const nombre = destinatarioNombre
    ? String(destinatarioNombre).replace(/\s+/g, ' ').trim().slice(0, 40)
    : null;
  const saludo = nombre ? `Hola ${nombre}` : 'Hola';

  // Sin eventos: mandamos mensaje "todo OK" igual. Decisión Santiago
  // 2026-05-09: el silencio es ambiguo (¿no había nada o falló el
  // cron?). Confirmar con un mensaje cierra esa duda.
  if (eventosArr.length === 0) {
    const fechaTxt = aDdMmYyyyLocal(new Date());
    return (
      `${saludo}.\n\n` +
      `📊 Resumen diario — Alertas HIGH (${fechaTxt})\n\n` +
      `✅ Sin eventos críticos en las últimas 24h.\n\n` +
      `${FIRMA}`
    );
  }
  // A partir de acá, eventosArr.length > 0.

  // Agrupamos por patente para que cada unidad ocupe un bloque visual
  // y dentro listamos los eventos cronologicamente. Ordenamos las
  // patentes alfabeticamente para consistencia entre dias.
  const porPatente = new Map();
  for (const ev of eventosArr) {
    const key = String(ev.patente || '—').trim().toUpperCase();
    if (!porPatente.has(key)) porPatente.set(key, []);
    porPatente.get(key).push(ev);
  }
  const patentesOrd = [...porPatente.keys()].sort();

  const bloques = patentesOrd.map((patente) => {
    const eventosUnidad = porPatente.get(patente);
    const choferNombre = eventosUnidad
      .map((e) => e.choferNombre)
      .find((n) => n && String(n).trim().length > 0);
    const titulo = choferNombre
      ? `🚛 *${patente}* (${choferNombre})`
      : `🚛 *${patente}*`;

    // Eventos ordenados cronologicamente.
    const ordenados = [...eventosUnidad].sort(
      (a, b) => a.fechaHora.getTime() - b.fechaHora.getTime()
    );

    // Si hay varios eventos del mismo tipo, los condensamos:
    //   "2x Exceso de velocidad (14:23 / 17:08)"
    // Sino:
    //   "Exceso de velocidad (14:23)"
    //
    // Para los GENERIC con subtipo conocido (SEATBELT, TELL_TALE, etc.)
    // agrupamos por subtipo en lugar del tipo crudo. Sino el reporte
    // queda lleno de "Evento genérico" sin diferenciar el problema real.
    const porTipo = new Map();
    for (const ev of ordenados) {
      const key = (ev.tipo === 'GENERIC' && ev.subTipo) ? ev.subTipo : ev.tipo;
      if (!porTipo.has(key)) porTipo.set(key, []);
      porTipo.get(key).push(ev);
    }

    const lineas = [...porTipo.entries()].map(([key, evs]) => {
      const etiqueta = ETIQUETAS_TIPO[key] || key;
      const horas = evs.map((e) => aLocalTime(e.fechaHora)).join(' / ');
      const prefijo = evs.length > 1 ? `${evs.length}x ` : '';
      return `   • ${prefijo}${etiqueta} (${horas})`;
    });

    return `${titulo}\n${lineas.join('\n')}`;
  });

  const cantidad = eventosArr.length;
  const titulo =
    cantidad === 1
      ? '1 evento crítico en las últimas 24h:'
      : `${cantidad} eventos críticos en las últimas 24h:`;

  const fecha = aDdMmYyyyLocal(new Date());
  return (
    `${saludo}.\n\n` +
    `📊 Resumen diario — Alertas HIGH (${fecha})\n\n` +
    `${titulo}\n\n` +
    `${bloques.join('\n\n')}\n\n` +
    `${FIRMA}`
  );
}

/**
 * Construye el mensaje resumen diario de alertas de MANTENIMIENTO (FUEL,
 * CATALYST, TELL_TALE, ADBLUELEVEL_LOW, WITHOUT_ADBLUE) de las últimas 24h.
 *
 * @param {object} args
 * @param {string|null} args.destinatarioNombre
 * @param {Array<{
 *   patente: string,
 *   tipo: string,
 *   subTipo: string|null,
 *   choferNombre: string|null,
 *   fechaHora: Date,
 * }>} args.eventos
 * @returns {string|null}
 */
function buildResumenMantenimientoDiario({ destinatarioNombre, eventos }) {
  const eventosArr = Array.isArray(eventos) ? eventos : [];
  const nombre = destinatarioNombre
    ? String(destinatarioNombre).replace(/\s+/g, ' ').trim().slice(0, 40)
    : null;
  const saludo = nombre ? `Hola ${nombre}` : 'Hola';
  const fecha = aDdMmYyyyLocal(new Date());

  // Sin alertas: mandamos mensaje "todo OK" igual (decisión Santiago
  // 2026-05-09: silencio = ambiguo; un mensaje confirma que el cron
  // corrió y no hubo nada para reportar).
  if (eventosArr.length === 0) {
    return (
      `${saludo}.\n\n` +
      `🔧 Resumen diario — Alertas de mantenimiento (${fecha})\n\n` +
      `✅ Sin alertas mecánicas en las últimas 24h.\n\n` +
      `${FIRMA}`
    );
  }

  const porPatente = new Map();
  for (const ev of eventosArr) {
    const key = String(ev.patente || '—').trim().toUpperCase();
    if (!porPatente.has(key)) porPatente.set(key, []);
    porPatente.get(key).push(ev);
  }
  const patentesOrd = [...porPatente.keys()].sort();

  const bloques = patentesOrd.map((patente) => {
    const evs = porPatente.get(patente);
    const choferNombre = evs.map((e) => e.choferNombre).find((n) => n && String(n).trim());
    const titulo = choferNombre
      ? `🔧 *${patente}* (${choferNombre})`
      : `🔧 *${patente}*`;

    const ordenados = [...evs].sort((a, b) => a.fechaHora.getTime() - b.fechaHora.getTime());

    // Agrupar por tipo mostrado (subTipo para GENERIC, tipo para el resto).
    const porTipoMost = new Map();
    for (const ev of ordenados) {
      const tipoKey = ev.subTipo || ev.tipo;
      if (!porTipoMost.has(tipoKey)) porTipoMost.set(tipoKey, []);
      porTipoMost.get(tipoKey).push(ev);
    }

    const lineas = [...porTipoMost.entries()].map(([tipoKey, evList]) => {
      const etiqueta = ETIQUETAS_TIPO[tipoKey] || tipoKey;
      const horas = evList.map((e) => aLocalTime(e.fechaHora)).join(' / ');
      const prefijo = evList.length > 1 ? `${evList.length}x ` : '';
      return `   • ${prefijo}${etiqueta} (${horas})`;
    });

    return `${titulo}\n${lineas.join('\n')}`;
  });

  const cantidad = eventosArr.length;
  return (
    `${saludo}.\n\n` +
    `🔧 Resumen diario — Alertas de mantenimiento (${fecha})\n\n` +
    `${cantidad === 1 ? '1 alerta' : `${cantidad} alertas`} de mantenimiento detectadas:\n\n` +
    `${bloques.join('\n\n')}\n\n` +
    `${FIRMA}`
  );
}

module.exports = {
  buildResumenDiario,
  buildResumenMantenimientoDiario,
  ETIQUETAS_TIPO,
  FIRMA,
};
