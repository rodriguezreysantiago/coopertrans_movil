// Idempotencia de los avisos automáticos.
//
// Antes de encolar un aviso, el cron consulta esta colección para no
// reenviar el mismo aviso en cada ciclo (cada hora). Cuando un papel
// se renueva (cambia la fecha de vencimiento), el id histórico cambia
// y los avisos del nuevo período se generan limpios.
//
// Estructura del id determinístico:
//   {coleccion}_{docId}_{campoBase}_{urgencia}_{fechaVenc}
// Ejemplo:
//   EMPLEADOS_12345678_LICENCIA_DE_CONDUCIR_7_2026-12-31

const admin = require('firebase-admin');
const log = require('./logger');

const COLECCION = 'AVISOS_AUTOMATICOS_HISTORICO';

/**
 * Niveles de urgencia que el cron puede generar. El número es el
 * umbral de días restantes — el aviso `urgente_7` se manda cuando
 * `dias <= 7 && dias > 1`, etc.
 *
 * Cada nivel `preventivo`, `recordatorio`, `urgente`, `hoy` se manda
 * UNA SOLA VEZ por (item, fecha de vencimiento). El nivel `vencido`
 * se manda **una vez por día** hasta que el papel se regularice (la
 * idempotencia del id incluye la fecha de hoy — ver `buildId`).
 *
 * Si la fecha de vencimiento cambia (papel renovado), el id es
 * distinto y los avisos se reanudan en el próximo período.
 */
const URGENCIAS = {
  preventivo: { codigo: 'preventivo', umbral: 30, minDias: 16, maxDias: 30 },
  recordatorio: { codigo: 'recordatorio', umbral: 15, minDias: 8, maxDias: 15 },
  urgente: { codigo: 'urgente', umbral: 7, minDias: 1, maxDias: 7 },
  hoy: { codigo: 'hoy', umbral: 0, minDias: 0, maxDias: 0 },
  // Vencido: el papel ya pasó el momento de renovarse. Mandamos un
  // recordatorio por día hasta que se regularice (cargue una nueva
  // fecha de vencimiento). El nivel se aplica para `dias < 0`.
  vencido: {
    codigo: 'vencido',
    umbral: -Infinity,
    minDias: -Infinity,
    maxDias: -1,
  },
};

/**
 * Devuelve la urgencia que corresponde a una cantidad de días, o
 * `null` si está demasiado lejano (>30 días).
 *
 * Si está vencido (`dias < 0`) devuelve el nivel `vencido`. Para que
 * el reminder no se mande mil veces por día, la idempotencia diaria
 * la maneja `buildId` agregando la fecha de hoy al id.
 */
function urgenciaPara(dias) {
  if (dias == null) return null;
  if (dias < 0) return URGENCIAS.vencido; // recordatorio diario
  if (dias > 30) return null; // demasiado lejano
  if (dias === 0) return URGENCIAS.hoy;
  if (dias <= 7) return URGENCIAS.urgente;
  if (dias <= 15) return URGENCIAS.recordatorio;
  if (dias <= 30) return URGENCIAS.preventivo;
  return null;
}

/**
 * Niveles de urgencia para el SERVICE preventivo de tractores. Métrica
 * en KILÓMETROS (no días) — espejo de `MantenimientoEstado` del cliente.
 *
 *   serviceDistance > 5000      → null (todavía lejos, no avisamos)
 *   serviceDistance ≤ 5000      → service_atencion
 *   serviceDistance ≤ 2500      → service_programar
 *   serviceDistance ≤ 1000      → service_urgente
 *   serviceDistance ≤ 0         → service_vencido
 */
const URGENCIAS_SERVICE = {
  service_atencion: { codigo: 'service_atencion', umbralKm: 5000 },
  service_programar: { codigo: 'service_programar', umbralKm: 2500 },
  service_urgente: { codigo: 'service_urgente', umbralKm: 1000 },
  service_vencido: { codigo: 'service_vencido', umbralKm: 0 },
};

/**
 * Devuelve la urgencia de service que corresponde a una distancia
 * restante en KM, o `null` si todavía falta mucho (>5000 km).
 */
function urgenciaServicePara(km) {
  if (km == null || isNaN(km)) return null;
  if (km <= 0) return URGENCIAS_SERVICE.service_vencido;
  if (km <= URGENCIAS_SERVICE.service_urgente.umbralKm) {
    return URGENCIAS_SERVICE.service_urgente;
  }
  if (km <= URGENCIAS_SERVICE.service_programar.umbralKm) {
    return URGENCIAS_SERVICE.service_programar;
  }
  if (km <= URGENCIAS_SERVICE.service_atencion.umbralKm) {
    return URGENCIAS_SERVICE.service_atencion;
  }
  return null;
}

/**
 * Construye el id determinístico para un aviso.
 *
 * Para los niveles "vencido" y "service_vencido" agregamos la fecha
 * de HOY al id, así el cron envía un recordatorio por día (el id es
 * distinto en cada corrida diaria). Cuando el admin actualiza la
 * fecha de vencimiento o el `ULTIMO_SERVICE_KM`, la parte base del
 * id cambia y el ciclo se reinicia limpio.
 *
 * Sanitiza caracteres no aptos para document IDs de Firestore (`/`).
 */
function buildId({ coleccion, docId, campoBase, urgencia, fechaVenc }) {
  let id = `${coleccion}_${docId}_${campoBase}_${urgencia}_${fechaVenc}`;
  if (urgencia === 'vencido' || urgencia === 'service_vencido') {
    id += `_${_fechaHoyIso()}`;
  }
  return id.replace(/\//g, '-').replace(/\s+/g, '');
}

/** YYYY-MM-DD de hoy, en hora local del bot. */
function _fechaHoyIso() {
  const d = new Date();
  const yyyy = d.getFullYear();
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}`;
}

/**
 * `true` si el aviso ya se envió alguna vez (cualquier estado, incluso
 * ERROR — si quedó en error que el admin lo reintente desde la pantalla
 * "Cola de WhatsApp" en vez del cron).
 */
async function yaSeEnvio(db, params) {
  const id = buildId(params);
  const doc = await db.collection(COLECCION).doc(id).get();
  return doc.exists;
}

/**
 * Orden de las urgencias de SERVICE de menor a mayor severidad.
 * `service_vencido` es la mas alta. Lo usa `yaSeEnvioServiceMaxUrgencia`
 * para decidir si la urgencia actual es 'igual o menor' a alguna ya
 * notificada para la misma ancla (caso rebote).
 */
const ORDEN_URGENCIAS_SERVICE = [
  'service_atencion',
  'service_programar',
  'service_urgente',
  'service_vencido',
];

/**
 * Para SERVICE: chequea si ya se envio un aviso para esta (patente, ancla)
 * con la urgencia actual O cualquier MAYOR. Util para evitar reenvio
 * cuando la urgencia rebota hacia abajo dentro del mismo ciclo (ej.
 * admin edita ULTIMO_SERVICE_KM por error y la urgencia baja de
 * service_vencido a service_urgente sin haberse hecho el service real).
 *
 * Casos:
 *   - Escalada (urgencia sube): se mando service_atencion. Ahora estamos
 *     en service_programar. Solo chequea programar/urgente/vencido. Como
 *     ninguno de esos se mando, retorna false -> se manda el aviso. OK.
 *   - Rebote (urgencia baja): se mando service_vencido. Ahora la urgencia
 *     cayo a service_urgente. Chequea urgente/vencido. service_vencido ya
 *     esta registrado -> retorna true -> skip. OK.
 *   - Nuevo ciclo (admin cambio ULTIMO_SERVICE_KM porque se hizo el
 *     service): la `ancla` cambia, las keys cambian, no se encuentra
 *     nada para la nueva ancla -> se manda el primer aviso. OK.
 *
 * Para `service_vencido` la key incluye la fecha del dia (reenvio diario).
 * Usamos query por prefijo para detectar registros de cualquier dia previo.
 */
async function yaSeEnvioServiceMaxUrgencia(db, params) {
  const idxActual = ORDEN_URGENCIAS_SERVICE.indexOf(params.urgencia);
  if (idxActual < 0) {
    // Urgencia desconocida (no es de service) -- fallback al check normal.
    return yaSeEnvio(db, params);
  }
  for (let i = idxActual; i < ORDEN_URGENCIAS_SERVICE.length; i++) {
    const u = ORDEN_URGENCIAS_SERVICE[i];
    if (u === 'service_vencido') {
      // Vencido tiene fecha del dia. Buscamos por prefijo del documentId.
      const baseSinFecha =
        `${params.coleccion}_${params.docId}_${params.campoBase}_${u}_${params.fechaVenc}_`;
      const prefix = baseSinFecha.replace(/\//g, '-').replace(/\s+/g, '');
      const snap = await db
        .collection(COLECCION)
        .where(admin.firestore.FieldPath.documentId(), '>=', prefix)
        .where(admin.firestore.FieldPath.documentId(), '<', prefix + '\uffff')
        .limit(1)
        .get();
      if (!snap.empty) return true;
    } else {
      // Sin fecha. Check directo del doc.
      const id = buildId({ ...params, urgencia: u });
      const doc = await db.collection(COLECCION).doc(id).get();
      if (doc.exists) return true;
    }
  }
  return false;
}

/**
 * Marca el aviso como ya enviado por el cron. Se guarda metadata para
 * auditoría: cuándo se generó, qué doc de COLA_WHATSAPP creó, etc.
 */
async function registrar(db, params, colaDocId) {
  const { ref, data } = prepararRegistro(db, params, colaDocId);
  await ref.set(data);
}

/**
 * Versión batch-friendly de `registrar`: devuelve `{ref, data}` para
 * que el caller los sume a un `db.batch()` propio. Útil para
 * atomizar el `add` a COLA_WHATSAPP con el registro de idempotencia
 * — sin esto, si el bot crashea entre las 2 escrituras, el aviso
 * queda encolado pero sin marcar histórico → próximo ciclo lo
 * re-encola (duplicado).
 */
function prepararRegistro(db, params, colaDocId) {
  const id = buildId(params);
  return {
    ref: db.collection(COLECCION).doc(id),
    data: {
      coleccion: params.coleccion,
      doc_id: params.docId,
      campo_base: params.campoBase,
      urgencia: params.urgencia,
      fecha_vencimiento: params.fechaVenc,
      cola_doc_id: colaDocId,
      creado_en: admin.firestore.FieldValue.serverTimestamp(),
    },
  };
}

// NOTA (auditoría 2026-05-22): se removieron 15 helpers obsoletos (3 por
// flujo × 5 flujos: service_diario, alertas_resumen, mantenimiento_diario,
// vencimientos_proximos, venc_empresas_admin). El patrón viejo era marcar
// idempotencia en AVISOS_AUTOMATICOS_HISTORICO con doc ID determinístico.
// El refactor 2026-05-18 los reemplazó por doc ID determinístico DIRECTO
// en COLA_WHATSAPP (cron.js, ver bloques `<cron>_diario_<fecha>_<dni>`),
// que regenera datos frescos si hay lag entre encolar y entregar. Ningún
// caller de cron.js los seguía usando — quedaban como código muerto exportado.

/**
 * Limpia docs viejos de AVISOS_AUTOMATICOS_HISTORICO.
 *
 * Borra los docs con `creado_en` anterior a `diasMin` días atrás
 * (default 90). Pensado para correr diariamente desde el cron — sin
 * limpieza, la colección crece indefinidamente (cada chofer + cada
 * fecha de vencimiento + cada nivel de urgencia genera 1 doc, miles
 * por año).
 *
 * Hace un batch único de hasta 500 deletes (límite de Firestore).
 * Si hay más, los siguientes ciclos del cron los eliminan.
 *
 * @returns {Promise<number>} cantidad de docs borrados.
 */
async function limpiarObsoletos(db, opciones = {}) {
  const diasMin = opciones.diasMin || 90;
  const limite = opciones.limite || 500;
  const cutoffMs = Date.now() - diasMin * 24 * 60 * 60 * 1000;
  const cutoff = admin.firestore.Timestamp.fromMillis(cutoffMs);

  let snap;
  try {
    snap = await db
      .collection(COLECCION)
      .where('creado_en', '<', cutoff)
      .limit(limite)
      .get();
  } catch (e) {
    log.warn(`limpiarObsoletos fallo al consultar: ${e.message}`);
    return 0;
  }

  if (snap.empty) return 0;

  const batch = db.batch();
  snap.forEach((doc) => batch.delete(doc.ref));
  try {
    await batch.commit();
  } catch (e) {
    log.warn(`limpiarObsoletos fallo al borrar: ${e.message}`);
    return 0;
  }
  log.info(
    `limpiarObsoletos: ${snap.size} docs borrados (creados antes de hace ${diasMin} dias).`
  );
  return snap.size;
}

module.exports = {
  COLECCION,
  URGENCIAS,
  URGENCIAS_SERVICE,
  ORDEN_URGENCIAS_SERVICE,
  urgenciaPara,
  urgenciaServicePara,
  buildId,
  yaSeEnvio,
  yaSeEnvioServiceMaxUrgencia,
  registrar,
  // Variante batch-friendly: devuelve {ref, data} para sumar a un
  // db.batch() del caller. Útil para atomizar add+registrar.
  prepararRegistro,
  limpiarObsoletos,
};
