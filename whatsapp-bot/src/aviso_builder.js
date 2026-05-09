// Port a Node.js de `lib/features/expirations/services/aviso_vencimiento_builder.dart`.
//
// Mantener el copy y el tono alineados con el original — los avisos
// automáticos generados por el cron deben sentirse iguales a los que
// dispara manualmente el admin desde la app. Si modificás el Dart,
// modificá acá también.

// Banner que se muestra al final del mensaje mientras la app esté en
// etapa de prueba. Quitar (junto con su uso en FIRMA) cuando se pase a
// producción real con todos los choferes/admins onboardeados.
const BANNER_TESTING =
  '⚠️ *Etapa de prueba* — si ves un error o algo no encaja, avisanos. ' +
  'No tomes el contenido al 100%.\n\n';

const FIRMA =
  BANNER_TESTING +
  '_Mensaje automático del sistema de gestión Coopertrans Móvil._\n' +
  '_Para responder o gestionar el trámite, comunicate con la oficina._';

/**
 * Construye el texto del aviso de WhatsApp para un vencimiento dado.
 *
 * @param {object} args
 * @param {object} args.item       - Vencimiento a comunicar.
 * @param {string} args.item.coleccion - 'EMPLEADOS' | 'VEHICULOS'.
 * @param {string} args.item.tipoDoc - 'Licencia', 'RTO', etc.
 * @param {string} args.item.docId  - DNI o patente.
 * @param {string} args.item.titulo - Para vehículos: "TRACTOR - AB123CD".
 * @param {string} args.item.fecha  - 'YYYY-MM-DD'.
 * @param {number} args.item.dias   - Días restantes (negativo si vencido).
 * @param {string|null} args.destinatarioNombre - Primer nombre o null.
 * @returns {string}
 */
function build({ item, destinatarioNombre }) {
  // Sanitizamos el nombre antes de interpolarlo en el mensaje para
  // que un valor con saltos de línea no rompa el formato (la firma
  // automática quedaría mezclada con el cuerpo) o no inyecte texto
  // adicional. Solo permitimos letras, espacios y signos comunes.
  const nombreSeguro = destinatarioNombre
    ? String(destinatarioNombre).replace(/\s+/g, ' ').trim().slice(0, 40)
    : null;
  const saludo =
    nombreSeguro && nombreSeguro.length > 0
      ? `Hola ${nombreSeguro}`
      : 'Hola';

  const fechaFmt = formatearFecha(item.fecha);
  const esVehiculo = item.coleccion === 'VEHICULOS';
  const referencia = esVehiculo
    ? `la unidad ${extraerPatente(item.titulo) || item.docId}`
    : `tu ${String(item.tipoDoc).toLowerCase()}`;

  const cuerpo = construirCuerpo({
    item,
    saludo,
    esVehiculo,
    referencia,
    fechaFmt,
  });
  return `${cuerpo}\n\n${FIRMA}`;
}

/**
 * Elige una variante random del array `arr`. Usado por construirCuerpo
 * para que el mismo nivel de urgencia no genere siempre el mismo texto
 * — eso reduce la huella anti-baneo de WhatsApp (mensajes idénticos
 * enviados a múltiples contactos en poco tiempo es señal de spam).
 *
 * Math.random() es suficiente — no necesitamos aleatoriedad
 * criptográfica, solo distribución razonable.
 */
function _pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function construirCuerpo({ item, saludo, esVehiculo, referencia, fechaFmt }) {
  const ref = esVehiculo ? `el ${item.tipoDoc} de ${referencia}` : referencia;

  if (item.dias < 0) {
    const hace = -item.dias;
    if (hace === 1) {
      return _pick([
        `${saludo}. Te aviso desde la oficina: ${ref} venció ayer (era el ${fechaFmt}). Es importante regularizarlo cuanto antes. ¿Cuándo podés acercarte a presentar el comprobante?`,
        `${saludo}. ${ref} venció ayer (${fechaFmt}). Avisame cuándo podés pasar por la oficina con el comprobante.`,
        `${saludo}, te escribo desde la oficina. ${ref} venció ayer (${fechaFmt}). Necesitamos regularizarlo lo antes posible — ¿podés acercarte hoy o mañana?`,
        `${saludo}, atención. ${ref} se venció ayer (${fechaFmt}). Coordiná con la oficina para presentar el comprobante en el día de hoy.`,
        `${saludo}. Aviso: ${ref} cumplió plazo ayer (${fechaFmt}). Pasá por la oficina hoy para destrabar la renovación.`,
        `${saludo}, recordatorio. La fecha de ${ref} fue ayer (${fechaFmt}). Es importante que regularices cuanto antes — cualquier duda nos avisás.`,
      ]);
    }
    if (hace <= 7) {
      return _pick([
        `${saludo}. Recordatorio: ${ref} sigue vencido (venció hace ${hace} días, el ${fechaFmt}). Es importante que lo regularices cuanto antes. ¿Cuándo lo podés presentar?`,
        `${saludo}. ${ref} venció hace ${hace} días (${fechaFmt}). Pasá por la oficina con el comprobante para destrabarlo.`,
        `${saludo}, recordatorio. ${ref} venció el ${fechaFmt} (${hace} días atrás). Coordiná un pase por la oficina lo antes posible.`,
        `${saludo}, aviso. Hace ${hace} días que se venció ${ref} (${fechaFmt}). Necesitamos que pases por la oficina con la documentación renovada.`,
        `${saludo}. ${ref} lleva ${hace} días vencido (${fechaFmt}). Te pido que coordines con la oficina esta semana para regularizar.`,
        `${saludo}, te escribo desde la oficina. ${ref} venció hace ${hace} días (${fechaFmt}). Acercate con el comprobante — cuanto antes mejor.`,
      ]);
    }
    if (hace <= 30) {
      return _pick([
        `${saludo}. ATENCIÓN: ${ref} lleva ${hace} días vencido (el ${fechaFmt}). Es urgente regularizarlo — coordiná con la oficina cuanto antes para evitar problemas operativos.`,
        `${saludo}. ${ref} lleva ${hace} días vencido (${fechaFmt}). Coordiná con la oficina hoy mismo, sino se complica para asignarte trabajo.`,
        `${saludo}, situación urgente. ${ref} venció hace ${hace} días (${fechaFmt}). Pasá YA por la oficina para destrabar.`,
        `${saludo}. Te aviso con urgencia: ${ref} lleva ${hace} días sin renovar (vencía el ${fechaFmt}). Necesitamos resolverlo esta semana.`,
        `${saludo}, atención. ${ref} venció hace ${hace} días (${fechaFmt}). Si no lo regularizás, no te vamos a poder asignar viajes — coordiná con la oficina ya.`,
        `${saludo}. Aviso urgente desde la oficina: ${ref} venció hace ${hace} días (${fechaFmt}). Pasá lo antes posible para que no se complique más.`,
      ]);
    }
    return _pick([
      `${saludo}. URGENTE: ${ref} lleva más de un mes vencido (${hace} días, era el ${fechaFmt}). La situación ya es crítica. Por favor pasá HOY por la oficina para coordinar la renovación.`,
      `${saludo}. ${ref} venció hace ${hace} días (${fechaFmt}) — más de un mes. Esto es crítico. Pasá HOY por la oficina sí o sí.`,
      `${saludo}, situación crítica. ${ref} cumplió ${hace} días vencido (${fechaFmt}). Necesitamos que pases hoy por la oficina — no podemos seguir asignando viajes con esto pendiente.`,
      `${saludo}. Aviso CRÍTICO: ${ref} viene vencido hace ${hace} días (${fechaFmt}) — ya pasó el mes. Acercate hoy a la oficina para coordinar la renovación.`,
      `${saludo}, atención máxima. ${ref} lleva ${hace} días sin renovar (vencía el ${fechaFmt}). Es URGENTE pasar hoy por la oficina.`,
      `${saludo}. Te escribo con urgencia: ${ref} venció hace ${hace} días (${fechaFmt}). La situación es crítica — pasá HOY sin falta.`,
    ]);
  }

  if (item.dias === 0) {
    return _pick([
      `${saludo}. Te aviso que ${ref} vence HOY (${fechaFmt}). Por favor pasá lo antes posible por la oficina.`,
      `${saludo}. ${ref} vence HOY (${fechaFmt}). Necesitamos el comprobante hoy mismo.`,
      `${saludo}, atención. Hoy (${fechaFmt}) vence ${ref}. Pasá por la oficina antes de que cierre.`,
      `${saludo}, recordatorio. ${ref} cumple plazo HOY (${fechaFmt}). Acercate cuanto antes con el comprobante de renovación.`,
      `${saludo}. Aviso: ${ref} vence en el día de hoy (${fechaFmt}). Pasá por la oficina antes del cierre para evitar quedar vencido.`,
      `${saludo}, te escribo desde la oficina. Hoy (${fechaFmt}) es el último día de ${ref}. Necesitamos verte con el comprobante.`,
    ]);
  }

  if (item.dias <= 7) {
    const dia = `día${item.dias === 1 ? '' : 's'}`;
    return _pick([
      `${saludo}. Recordatorio importante: ${ref} vence en ${item.dias} ${dia} (el ${fechaFmt}). Si todavía no empezaste el trámite, hacelo ya.`,
      `${saludo}. ${ref} vence en ${item.dias} ${dia} (${fechaFmt}). Arrancá la renovación si todavía no la iniciaste.`,
      `${saludo}, te aviso. ${ref} se vence el ${fechaFmt} (faltan ${item.dias} ${dia}). Es importante que ya estés en el trámite.`,
      `${saludo}, atención. En ${item.dias} ${dia} vence ${ref} (${fechaFmt}). Si no lo arrancaste todavía, esta semana es clave.`,
      `${saludo}. Aviso: queda${item.dias === 1 ? '' : 'n'} ${item.dias} ${dia} para que venza ${ref} (${fechaFmt}). Acelerá la renovación.`,
      `${saludo}, recordatorio desde la oficina. ${ref} vence el ${fechaFmt} — faltan ${item.dias} ${dia}. Necesitamos que avances con la renovación esta semana.`,
    ]);
  }

  if (item.dias <= 15) {
    return _pick([
      `${saludo}. Te aviso que ${ref} vence en ${item.dias} días (${fechaFmt}). Es buen momento para empezar el trámite de renovación.`,
      `${saludo}. ${ref} vence el ${fechaFmt} (en ${item.dias} días). Conviene que arranques con la renovación.`,
      `${saludo}, recordatorio. Faltan ${item.dias} días para que venza ${ref} (${fechaFmt}). Andá iniciando el trámite.`,
      `${saludo}, te aviso. En ${item.dias} días vence ${ref} (${fechaFmt}). Si arrancás esta semana llegás cómodo con la renovación.`,
      `${saludo}. Aviso: ${ref} cumple plazo el ${fechaFmt} (faltan ${item.dias} días). Es buen momento para coordinar la renovación.`,
      `${saludo}, recordatorio desde la oficina. ${ref} vence en ${item.dias} días (${fechaFmt}). Conviene anotar la fecha y arrancar el trámite.`,
    ]);
  }

  return _pick([
    `${saludo}. Aviso preventivo: ${ref} vence el ${fechaFmt} (en ${item.dias} días). Andá viendo el trámite.`,
    `${saludo}. ${ref} vence el ${fechaFmt} (faltan ${item.dias} días). Te aviso con anticipación para que tengas margen.`,
    `${saludo}, aviso anticipado. ${ref} vence en ${item.dias} días (${fechaFmt}). Empezá a pensar en la renovación.`,
    `${saludo}. Te paso un recordatorio anticipado: ${ref} vence el ${fechaFmt} (${item.dias} días). Vas a tiempo para arrancar la renovación.`,
    `${saludo}, aviso. Faltan ${item.dias} días para que venza ${ref} (${fechaFmt}). Te aviso con anticipación así organizás el trámite con tiempo.`,
    `${saludo}, recordatorio preventivo. ${ref} cumple plazo el ${fechaFmt} (en ${item.dias} días). Andá pensando cuándo iniciar la renovación.`,
  ]);
}

/**
 * Resuelve cómo saludar a un chofer dado su doc de EMPLEADOS.
 *
 * Prioridad:
 *   1. Si tiene `APODO` cargado y no es vacío → usar APODO. Es lo que
 *      cargó el admin manualmente para casos donde el algoritmo de
 *      "segundo token" falla (dos apellidos, segundo nombre, etc).
 *   2. Sino → algoritmo `extraerPrimerNombre(NOMBRE)` (segundo token).
 *
 * Devuelve `null` si no se pudo resolver (sin apodo y NOMBRE de un
 * solo token), igual que `extraerPrimerNombre`.
 */
function resolverNombreSaludo(empleadoData) {
  if (!empleadoData) return null;
  const apodo = empleadoData.APODO;
  if (apodo && String(apodo).trim().length > 0) {
    return String(apodo).trim();
  }
  return extraerPrimerNombre(empleadoData.NOMBRE);
}


/**
 * Construye un mensaje AGRUPADO con varios vencimientos del mismo
 * chofer. Se usa cuando el cron detecta que un chofer tiene 2+ items
 * para avisar en el mismo ciclo — en lugar de mandar 2+ mensajes
 * separados (que es signal fuerte de bot ante WhatsApp), mandamos
 * uno solo con la lista completa.
 *
 * @param {object} args
 * @param {string|null} args.destinatarioNombre - Apodo o primer nombre.
 * @param {Array<object>} args.items - Cada item:
 *   - tipoDoc: 'Licencia de Conducir', 'RTO', 'Service', etc.
 *   - referencia: 'tu' | 'la unidad <patente>' | etc. (cómo introducirlo).
 *   - dias: días restantes (negativo si vencido). Para service preventivo,
 *           dias representa los KM restantes (lo formateamos distinto).
 *   - fecha: string YYYY-MM-DD para vencimientos. Para service no se usa.
 *   - tipo: 'vencimiento' (default) | 'service'.
 * @returns {string}
 */
function buildAgrupado({ destinatarioNombre, items }) {
  const nombreSeguro = destinatarioNombre
    ? String(destinatarioNombre).replace(/\s+/g, ' ').trim().slice(0, 40)
    : null;
  const saludo =
    nombreSeguro && nombreSeguro.length > 0
      ? `Hola ${nombreSeguro}`
      : 'Hola';

  // Ordenamos por urgencia: más urgente primero (vencidos hace más).
  // Eso pone al chofer la info crítica al inicio.
  const ordenados = [...items].sort((a, b) => (a.dias || 0) - (b.dias || 0));

  const lineas = ordenados.map(_lineaItem);

  // Tono del cierre según el item más grave.
  const masGrave = ordenados[0];
  let cierre;
  if (masGrave && masGrave.dias != null && masGrave.dias < 0) {
    cierre = 'Pasá por la oficina lo antes posible para regularizar.';
  } else if (masGrave && masGrave.dias != null && masGrave.dias <= 7) {
    cierre = 'Es importante que arranques con la renovación de los más próximos. Coordiná con la oficina.';
  } else {
    cierre = 'Te aviso con anticipación para que tengas margen. Coordiná con la oficina cuando puedas.';
  }

  const cuerpo =
    `${saludo}, te aviso desde la oficina que tenés varios papeles para gestionar:\n\n` +
    lineas.join('\n') +
    `\n\n${cierre}`;

  return `${cuerpo}\n\n${FIRMA}`;
}

/**
 * Arma una línea descriptiva para un item del mensaje agrupado.
 * Formato: "<emoji> <Tipo> — <detalle de fecha o km>".
 */
function _lineaItem(item) {
  const dias = item.dias;
  const tipo = item.tipo || 'vencimiento';
  const tipoDoc = item.tipoDoc || 'documento';
  const ref = item.referencia ? ` (${item.referencia})` : '';

  // Service preventivo: `dias` es KM, formato distinto.
  if (tipo === 'service') {
    const km = Math.round(dias);
    if (km <= 0) {
      return `🚨 Service${ref} — VENCIDO (${Math.abs(km)} km pasados)`;
    }
    if (km <= 1000) {
      return `⚠️ Service${ref} — urgente (faltan ${km} km)`;
    }
    return `📅 Service${ref} — faltan ${km.toLocaleString('es-AR')} km`;
  }

  // Vencimiento normal: `dias` es días, `fecha` es string ISO.
  const fechaFmt = formatearFecha(item.fecha);
  if (dias == null) {
    return `📄 ${tipoDoc}${ref} — ${fechaFmt}`;
  }
  if (dias < 0) {
    const hace = -dias;
    if (hace === 1) {
      return `🚨 ${tipoDoc}${ref} — venció ayer (${fechaFmt})`;
    }
    return `🚨 ${tipoDoc}${ref} — vencido hace ${hace} días (${fechaFmt})`;
  }
  if (dias === 0) {
    return `⚠️ ${tipoDoc}${ref} — vence HOY (${fechaFmt})`;
  }
  if (dias <= 7) {
    return `⚠️ ${tipoDoc}${ref} — vence en ${dias} día${dias === 1 ? '' : 's'} (${fechaFmt})`;
  }
  return `📅 ${tipoDoc}${ref} — vence en ${dias} días (${fechaFmt})`;
}

/**
 * Para nombres tipo "PEREZ JUAN CARLOS" devuelve "Juan" (formato
 * APELLIDO NOMBRE… que usa la app). Si solo hay un token, devuelve
 * null para evitar saludar al chofer por su apellido.
 */
function extraerPrimerNombre(nombreCompleto) {
  if (!nombreCompleto) return null;
  const partes = String(nombreCompleto).trim().split(/\s+/);
  if (partes.length < 2) return null;
  const n = partes[1];
  if (!n) return null;
  return n[0].toUpperCase() + n.slice(1).toLowerCase();
}

/**
 * Para títulos como "TRACTOR - AB123CD" devuelve "AB123CD". Si no
 * encuentra el patrón, devuelve null y el caller cae al docId.
 */
function extraerPatente(titulo) {
  if (!titulo) return null;
  const m = String(titulo).match(/-\s*([A-Z0-9]{6,})/);
  return m ? m[1] : null;
}

/**
 * Formatea una fecha cualquiera (string YYYY-MM-DD, Date, Timestamp
 * Firestore, etc.) a `DD/MM/YYYY`. Devuelve `'-'` si no se puede.
 *
 * Delegado a `aDdMmYyyyLocal` del modulo `fechas.js` que centraliza
 * el parseo anti-timezone. La funcion vieja tenia su propio fallback
 * con `new Date(str).getDate()` que sufria el bug "1 dia menos" para
 * Timestamps con UTC midnight (caso tipico de migraciones desde
 * Python o JS con `new Date("YYYY-MM-DD")`).
 */
const { aDdMmYyyyLocal } = require('./fechas');

function formatearFecha(fecha) {
  return aDdMmYyyyLocal(fecha);
}

module.exports = {
  build,
  buildAgrupado,
  extraerPrimerNombre,
  resolverNombreSaludo,
  extraerPatente,
  formatearFecha,
  FIRMA,
};
