// Builder del resumen DIARIO de vencimientos próximos a vencer (≤7
// días) que va al ENCARGADO DE DOCUMENTACIÓN — Giagante Guillermo.
//
// Cubre 3 universos:
//   1. PERSONAL  — Licencia, Preocupacional, Manejo Defensivo de cada
//                  chofer activo.
//   2. VEHÍCULOS — RTO, Seguro, Extintor cabina/exterior según TIPO
//                  (tractores tienen extintores, enganches no).
//   3. EMPRESAS  — Póliza ART, Formulario 931, SCVO y Libre deuda
//                  sindical de cada empresa empleadora.
//
// Si no hay nada en los 3, no se manda nada (silencio = nada que
// reportar; mismo criterio que `aviso_alertas_volvo_builder`).

const { aDdMmYyyyLocal } = require('./fechas');

const BANNER_TESTING =
  '⚠️ *Etapa de prueba* — si ves un error o algo no encaja, avisanos. ' +
  'No tomes el contenido al 100%.\n\n';

const FIRMA =
  BANNER_TESTING +
  '_Mensaje automático del sistema de gestión Coopertrans Móvil._\n' +
  '_Detalle completo en la app → Vencimientos._';

/**
 * Formatea los días restantes en una etiqueta legible.
 *   0  → "vence hoy"
 *   1  → "vence mañana"
 *   N  → "en N días"
 */
function _etiquetaDias(dias) {
  if (dias === 0) return 'vence hoy';
  if (dias === 1) return 'vence mañana';
  return `en ${dias} días`;
}

/**
 * Construye el mensaje resumen diario de vencimientos próximos.
 *
 * @param {object} args
 * @param {string|null} args.destinatarioNombre - Apodo o primer nombre.
 * @param {Array<{
 *   chofer: string,
 *   etiqueta: string,
 *   fecha: string,
 *   dias: number,
 * }>} args.itemsPersonal - Vencimientos personales (uno por chofer/doc).
 * @param {Array<{
 *   patente: string,
 *   tipoUnidad: string,
 *   etiqueta: string,
 *   fecha: string,
 *   dias: number,
 * }>} args.itemsVehiculos - Vencimientos de unidades.
 * @param {Array<{
 *   empresa: string,
 *   etiqueta: string,
 *   fecha: string,
 *   dias: number,
 * }>} args.itemsEmpresas - Vencimientos de docs por empresa.
 * @returns {string|null} Mensaje listo, o null si no hay items.
 */
function buildResumenVencimientosProximos({
  destinatarioNombre,
  itemsPersonal,
  itemsVehiculos,
  itemsEmpresas,
}) {
  const personal = Array.isArray(itemsPersonal) ? itemsPersonal : [];
  const vehiculos = Array.isArray(itemsVehiculos) ? itemsVehiculos : [];
  const empresas = Array.isArray(itemsEmpresas) ? itemsEmpresas : [];

  const nombre = destinatarioNombre
    ? String(destinatarioNombre).replace(/\s+/g, ' ').trim().slice(0, 40)
    : null;
  const saludo = nombre ? `Hola ${nombre}` : 'Hola';
  const fecha = aDdMmYyyyLocal(new Date());

  if (personal.length === 0 && vehiculos.length === 0 && empresas.length === 0) {
    // Sin items: mandamos "todo OK" igual (decisión Santiago 2026-05-09:
    // silencio = ambiguo; un mensaje confirma que el cron corrió y no
    // hay vencimientos próximos).
    return (
      `${saludo}.\n\n` +
      `📋 Resumen vencimientos próximos (${fecha})\n\n` +
      `✅ Sin vencimientos próximos:\n` +
      `   • Personal y vehículos en los próximos 15 días.\n` +
      `   • Empresas y seguros en los próximos 30 días.\n\n` +
      `${FIRMA}`
    );
  }
  const total = personal.length + vehiculos.length + empresas.length;
  // Las ventanas son distintas por tipo (15d personal/veh + 30d empresas):
  // si hay items SOLO de un universo, mostramos esa ventana; si hay mix,
  // mostramos las dos por claridad.
  const tituloTotal = (() => {
    const esSingular = total === 1;
    const sust = esSingular ? 'vencimiento' : 'vencimientos';
    const adj = esSingular ? 'próximo' : 'próximos';
    const hayPersonalVeh = personal.length > 0 || vehiculos.length > 0;
    const hayEmpresas = empresas.length > 0;
    if (hayPersonalVeh && hayEmpresas) {
      return `${total} ${sust} ${adj} (personal/vehículos ≤15 días, empresas ≤30 días):`;
    }
    if (hayEmpresas) {
      return `${total} ${sust} ${adj} en empresas y seguros (≤30 días):`;
    }
    return `${total} ${sust} ${adj} en personal y vehículos (≤15 días):`;
  })();

  const bloques = [];

  // ─── Personal ───
  if (personal.length > 0) {
    // Agrupamos por chofer para que cada uno ocupe un bloque visual.
    const porChofer = new Map();
    for (const it of personal) {
      const key = String(it.chofer || '—').trim();
      if (!porChofer.has(key)) porChofer.set(key, []);
      porChofer.get(key).push(it);
    }
    const choferesOrd = [...porChofer.keys()].sort();
    const lineas = choferesOrd.map((chofer) => {
      const items = porChofer.get(chofer).sort((a, b) => a.dias - b.dias);
      const detalle = items
        .map((it) => `   • ${it.etiqueta} — ${it.fecha} (${_etiquetaDias(it.dias)})`)
        .join('\n');
      return `👤 *${chofer}*\n${detalle}`;
    });
    bloques.push(`*PERSONAL*\n\n${lineas.join('\n\n')}`);
  }

  // ─── Vehículos ───
  if (vehiculos.length > 0) {
    const porPatente = new Map();
    for (const it of vehiculos) {
      const key = String(it.patente || '—').trim().toUpperCase();
      if (!porPatente.has(key)) porPatente.set(key, []);
      porPatente.get(key).push(it);
    }
    const patentesOrd = [...porPatente.keys()].sort();
    const lineas = patentesOrd.map((patente) => {
      const items = porPatente.get(patente).sort((a, b) => a.dias - b.dias);
      const tipoUnidad = items[0].tipoUnidad || '';
      const cabecera = tipoUnidad
        ? `🚛 *${patente}* (${tipoUnidad})`
        : `🚛 *${patente}*`;
      const detalle = items
        .map((it) => `   • ${it.etiqueta} — ${it.fecha} (${_etiquetaDias(it.dias)})`)
        .join('\n');
      return `${cabecera}\n${detalle}`;
    });
    bloques.push(`*VEHÍCULOS*\n\n${lineas.join('\n\n')}`);
  }

  // ─── Empresas empleadoras ───
  if (empresas.length > 0) {
    const porEmpresa = new Map();
    for (const it of empresas) {
      const key = String(it.empresa || '—').trim();
      if (!porEmpresa.has(key)) porEmpresa.set(key, []);
      porEmpresa.get(key).push(it);
    }
    const empresasOrd = [...porEmpresa.keys()].sort();
    const lineas = empresasOrd.map((empresa) => {
      const items = porEmpresa.get(empresa).sort((a, b) => a.dias - b.dias);
      const detalle = items
        .map((it) => `   • ${it.etiqueta} — ${it.fecha} (${_etiquetaDias(it.dias)})`)
        .join('\n');
      return `🏢 *${empresa}*\n${detalle}`;
    });
    bloques.push(`*EMPRESAS Y SEGUROS*\n\n${lineas.join('\n\n')}`);
  }

  return (
    `${saludo}.\n\n` +
    `📋 Resumen de vencimientos — ${fecha}\n\n` +
    `${tituloTotal}\n\n` +
    `${bloques.join('\n\n━━━━━━━━━━━━━━━\n\n')}\n\n` +
    `${FIRMA}`
  );
}

module.exports = {
  buildResumenVencimientosProximos,
  FIRMA,
};
