// Cron interno del bot — Fase 2.
//
// Cada N minutos (default 60) recorre EMPLEADOS y VEHICULOS, calcula
// urgencia de cada vencimiento, y encola avisos automáticos en
// COLA_WHATSAPP. La idempotencia se garantiza con AVISOS_AUTOMATICOS_HISTORICO
// (ver historico.js): el mismo aviso (mismo nivel de urgencia, misma
// fecha de vencimiento) se envía una sola vez.
//
// AGRUPACIÓN POR CHOFER (2026-04-30): si un mismo chofer tiene 2+
// vencimientos para avisar en el mismo ciclo, mandamos UN solo mensaje
// con la lista completa en lugar de N mensajes separados. Eso reduce
// drásticamente la huella de bot ante WhatsApp (mensajes consecutivos
// al mismo número en pocos segundos = signal fuerte de spam) y le da
// al chofer toda la info de un saque.

const admin = require('firebase-admin');
const log = require('./logger');
const { enHorarioHabil, normalizarTelefonoAWid } = require('./humano');
const aviso = require('./aviso_builder');
const avisoService = require('./aviso_service_builder');
const avisoVencProx = require('./aviso_vencimientos_proximos_builder');
const hist = require('./historico');
const health = require('./health');
const { obtenerDestinatario } = require('./destinatarios');
const fs = require('./firestore');
const { aIsoLocal } = require('./fechas');
const { cargarExcluidos } = require('./excluidos');

// Banner de etapa de prueba vaciado 2026-05-18 (decision Santiago).
// Bot opera 24/7 en produccion con choferes reales. Constante queda
// como '' para no romper concatenaciones existentes (no-op).
const BANNER_TESTING = '';

// Intervalo entre services programados de tractores Volvo, en KM.
const INTERVALO_SERVICE_KM = 50000;

// Documentos auditados de EMPLEADOS — replica del listado en
// `lib/core/constants/vencimientos_config.dart` (AppDocsEmpleado.etiquetas).
//
// 2026-05-08: ART, F. 931, Seguro de Vida (SCVO) y pago de cuota
// sindical SE SACARON. Esos docs ahora viven a nivel empresa
// empleadora (EMPRESAS_EMPLEADORAS/{cuit}) — son comunes a todos los
// empleados de la misma razón social. Mandar WhatsApp al chofer
// porque la empresa no renovó alguno de esos papeles es ruido (el
// chofer no puede hacer nada). Si en el futuro se quiere avisar a
// la oficina cuando uno por empresa está por vencer, esa notificación
// va por otro canal (consolidada al admin/RR.HH.), no individualizada
// al chofer.
const DOCS_EMPLEADO = {
  'Licencia de Conducir': 'LICENCIA_DE_CONDUCIR',
  Preocupacional: 'PREOCUPACIONAL',
  'Manejo Defensivo': 'CURSO_DE_MANEJO_DEFENSIVO',
};

/// Ventana hacia adelante para el "resumen diario de vencimientos
/// próximos" que recibe Giagante por WhatsApp.
///
/// Personal (licencia/ART/psicofísico/etc.) + Vehículos (RTO/seguro/
/// extintor) usan PERSONAL_VEH 15 días. Subido de 7 a 15 días el
/// 2026-05-12 — 7 daba muy poco margen para renovar trámites de
/// Bahía Blanca que tardan ~10-14 días hábiles.
///
/// Empresas empleadoras (Póliza ART / F. 931 / SCVO / Libre deuda
/// sindical) usan EMPRESAS 30 días, porque son trámites mas lentos
/// que requieren coordinar con contabilidad / RR.HH. / aseguradora.
/// Antes (≤2026-05-18) había un cron aparte `cron_venc_empresas_
/// admin_diario` que avisaba 30 días al admin — se unifico aca para
/// que Giagante (que es quien efectivamente trata con contabilidad
/// y la aseguradora) reciba TODO en UN solo mensaje escalonado.
const DIAS_AVISO_VENC_PERSONAL_VEH = 15;
const DIAS_AVISO_VENC_EMPRESAS = 30;
// Alias legacy mientras quedan referencias menores (puede borrarse).
const DIAS_AVISO_VENCIMIENTO_PROXIMO = DIAS_AVISO_VENC_PERSONAL_VEH;

// Vencimientos auditados de VEHICULOS por tipo. Replica de
// `lib/core/constants/vencimientos_config.dart`. Mantener sincronizado.
const DOCS_VEHICULO = {
  TRACTOR: [
    { etiqueta: 'RTO', campoFecha: 'VENCIMIENTO_RTO', campoBase: 'RTO' },
    { etiqueta: 'Seguro', campoFecha: 'VENCIMIENTO_SEGURO', campoBase: 'SEGURO' },
    { etiqueta: 'Extintor Cabina', campoFecha: 'VENCIMIENTO_EXTINTOR_CABINA', campoBase: 'EXTINTOR_CABINA' },
    { etiqueta: 'Extintor Exterior', campoFecha: 'VENCIMIENTO_EXTINTOR_EXTERIOR', campoBase: 'EXTINTOR_EXTERIOR' },
  ],
  BATEA: [
    { etiqueta: 'RTO', campoFecha: 'VENCIMIENTO_RTO', campoBase: 'RTO' },
    { etiqueta: 'Seguro', campoFecha: 'VENCIMIENTO_SEGURO', campoBase: 'SEGURO' },
  ],
  TOLVA: [
    { etiqueta: 'RTO', campoFecha: 'VENCIMIENTO_RTO', campoBase: 'RTO' },
    { etiqueta: 'Seguro', campoFecha: 'VENCIMIENTO_SEGURO', campoBase: 'SEGURO' },
  ],
  BIVUELCO: [
    { etiqueta: 'RTO', campoFecha: 'VENCIMIENTO_RTO', campoBase: 'RTO' },
    { etiqueta: 'Seguro', campoFecha: 'VENCIMIENTO_SEGURO', campoBase: 'SEGURO' },
  ],
  TANQUE: [
    { etiqueta: 'RTO', campoFecha: 'VENCIMIENTO_RTO', campoBase: 'RTO' },
    { etiqueta: 'Seguro', campoFecha: 'VENCIMIENTO_SEGURO', campoBase: 'SEGURO' },
  ],
  ACOPLADO: [
    { etiqueta: 'RTO', campoFecha: 'VENCIMIENTO_RTO', campoBase: 'RTO' },
    { etiqueta: 'Seguro', campoFecha: 'VENCIMIENTO_SEGURO', campoBase: 'SEGURO' },
  ],
};

/**
 * Calcula los días restantes hasta `fechaIso` (`YYYY-MM-DD` o ISO).
 * Negativo si la fecha ya pasó. Devuelve `null` si la fecha es inválida.
 *
 * Parseo manual de YYYY-MM-DD para evitar el shift UTC vs local que
 * `new Date("YYYY-MM-DD")` aplica (medianoche UTC = 21h del día
 * anterior en ART → días corridos para atrás).
 */
function calcularDiasRestantes(fechaIso) {
  if (!fechaIso) return null;
  const str = String(fechaIso).trim();
  let venc;
  const mIso = /^(\d{4})-(\d{2})-(\d{2})/.exec(str);
  // DD/MM/YYYY o DD-MM-YYYY — formato AR guardado antes de la migración a ISO
  const mAr = /^(\d{2})[\/\-](\d{2})[\/\-](\d{4})/.exec(str);
  if (mIso) {
    venc = new Date(parseInt(mIso[1], 10), parseInt(mIso[2], 10) - 1, parseInt(mIso[3], 10));
  } else if (mAr) {
    venc = new Date(parseInt(mAr[3], 10), parseInt(mAr[2], 10) - 1, parseInt(mAr[1], 10));
  } else {
    venc = new Date(str);
  }
  if (isNaN(venc.getTime())) return null;
  const hoy = new Date();
  const a = new Date(hoy.getFullYear(), hoy.getMonth(), hoy.getDate());
  const b = new Date(venc.getFullYear(), venc.getMonth(), venc.getDate());
  const ms = b.getTime() - a.getTime();
  return Math.round(ms / (1000 * 60 * 60 * 24));
}

/**
 * YYYY-MM-DD de hoy en timezone Argentina (ART). Usado para construir
 * IDs deterministicos de docs diarios en COLA_WHATSAPP, garantizando
 * que el "dia operativo" coincide con la jornada laboral local del
 * destinatario - independiente del timezone del proceso (la PC dedicada
 * esta en Argentina pero esto previene bugs si se moviera a un server
 * UTC en el futuro).
 *
 * 'en-CA' locale devuelve format YYYY-MM-DD nativo de Intl.
 */
function _fechaArtIso() {
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Argentina/Buenos_Aires',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
  return fmt.format(new Date());
}

/**
 * Busca al destinatario de un resumen consolidado (Emmanuel para
 * service, Santiago para alertas Volvo). Como el cron solo carga
 * empleados con ROL=CHOFER en `empleadosByDni` (regla "solo CHOFER
 * cuenta como conductor" del 2026-05-02), los destinatarios de los
 * resúmenes — que típicamente son SUPERVISOR o ADMIN — NO están en
 * ese map y hay que pedirlos directo a Firestore.
 *
 * @returns `{id, data}` o `null` si el DNI no existe.
 */
async function _obtenerDestinatarioConsolidado(db, dni, empleadosByDni) {
  const k = String(dni || '').trim();
  if (!k) return null;
  const hit = empleadosByDni.get(k);
  if (hit) return hit;
  try {
    const snap = await db.collection('EMPLEADOS').doc(k).get();
    if (!snap.exists) return null;
    return { id: snap.id, data: snap.data() || {} };
  } catch (e) {
    // Antes era catch silencioso → si Firestore fallaba (timeout, rule
    // rota), el cron skipeaba el envío sin que nadie se entere. Con la
    // garantía nueva de "siempre llega resumen" eso se manifiesta
    // rápido — pero igual queremos el log para diagnóstico.
    log.warn(`Lookup empleado ${k} fallo: ${e.message}`);
    return null;
  }
}

let _running = false;
let _timer = null;

function start(fs) {
  if (_timer) return;
  const enabled =
    String(process.env.AUTO_AVISOS_ENABLED || 'false').toLowerCase() === 'true';
  if (!enabled) {
    log.info(
      'Cron de avisos automáticos DESHABILITADO (AUTO_AVISOS_ENABLED=false). ' +
        'Habilitar en .env cuando confirmes que el bot envía bien.'
    );
    return;
  }

  const intervaloMin = parseInt(process.env.CRON_INTERVAL_MINUTES || '60', 10);
  const intervaloMs = intervaloMin * 60 * 1000;
  log.info(`Cron de avisos automáticos HABILITADO (cada ${intervaloMin} min).`);

  // Patrón setTimeout recursivo (no setInterval): el siguiente ciclo
  // solo se programa DESPUÉS de que termina el anterior. Evita brechas
  // cuando un ciclo tarda más que el intervalo (ej: cron tarda 70min
  // con intervalo de 60min → con setInterval se perdían ciclos; con
  // setTimeout recursivo el siguiente arranca a los 60min DESPUÉS de
  // que el anterior termine).
  const programarProximo = () => {
    _timer = setTimeout(async () => {
      try {
        await _runOnce(fs);
      } catch (e) {
        log.error(`Cron _runOnce no atrapado: ${e.message}`);
      } finally {
        if (_timer) programarProximo(); // si stop() corrió, _timer = null
      }
    }, intervaloMs);
  };

  // Primera corrida más rápida (30s después de arrancar) y después se
  // engancha al ciclo recursivo.
  _timer = setTimeout(async () => {
    try {
      await _runOnce(fs);
    } catch (e) {
      log.error(`Cron _runOnce inicial no atrapado: ${e.message}`);
    } finally {
      if (_timer) programarProximo();
    }
  }, 30000);
}

function stop() {
  if (_timer) {
    clearTimeout(_timer);
    _timer = null;
  }
}

async function _runOnce(fs) {
  if (_running) {
    log.warn('Cron previo todavía corriendo, salto este ciclo.');
    return;
  }
  if (!enHorarioHabil()) {
    log.debug('Cron salta — fuera de horario hábil.');
    return;
  }
  _running = true;

  const db = fs.inicializar();
  const stats = { encolados: 0, agrupados: 0, salteados: 0, errores: 0 };

  // ─── Cargar set de exclusion UNA vez al inicio del cron ───
  // Choferes asignados a enganches TANQUE + usuarios tester (Apple
  // Reviewer, Android tester). Estos NO reciben avisos automáticos del
  // bot. Ver `whatsapp-bot/src/excluidos.js` para el caso de negocio.
  // Cacheado in-memory 10 min — costo cero en runs subsiguientes del cron.
  const excluidos = await cargarExcluidos(db);

  try {
    // ─── Cleanup de historico viejo (mantenimiento de coleccion) ──
    // Borra hasta 500 docs de AVISOS_AUTOMATICOS_HISTORICO con
    // `creado_en` > 90 dias atras. Sin esto, la coleccion crece
    // indefinidamente (cada urgencia + cada chofer + cada fecha
    // genera un doc). Es barato (1 query + 1 batch) y se hace cada
    // ciclo del cron (1x por hora aprox), asi que la limpieza es
    // gradual y nunca acumula.
    try {
      await hist.limpiarObsoletos(db);
    } catch (e) {
      log.warn(`Cleanup de historico fallo: ${e.message}`);
    }

    // ─── Cargar empleados + índice patente → chofer ───
    // Solo CHOFER cuenta como conductor: admins/supervisores/planta no
    // manejan ni reciben avisos de vencimientos profesionales (licencia,
    // ART, psicofísico). Los filtramos in-memory para no dispararles
    // mensajes de WhatsApp y para no mapearlos como dueños de patentes
    // en el índice. Acepta el legacy 'USUARIO' por compatibilidad.
    const empleadosSnap = await db.collection('EMPLEADOS').get();
    const empleadosByDni = new Map();
    const choferByPatente = new Map();
    for (const doc of empleadosSnap.docs) {
      const data = doc.data();
      // Soft-delete: empleados dados de baja NO reciben avisos.
      if (data.ACTIVO === false) continue;
      // Excluidos: choferes TANQUE + testers. Saltear ANTES de mapear
      // patentes — sino el choferByPatente apuntaría a un excluido y
      // los vencimientos de su unidad le llegarían igual.
      if (excluidos.dnis.has(doc.id.trim())) continue;
      const rolRaw = String(data.ROL || '').toUpperCase().trim();
      if (rolRaw !== 'CHOFER' && rolRaw !== 'USUARIO' && rolRaw !== '') {
        // ADMIN, SUPERVISOR, PLANTA → out. Si ROL viene vacío/null lo
        // tratamos como CHOFER (datos viejos de antes del rol-split).
        continue;
      }
      const emp = { id: doc.id, data };
      empleadosByDni.set(doc.id.trim(), emp);
      const veh = String(data.VEHICULO || '').trim().toUpperCase();
      const eng = String(data.ENGANCHE || '').trim().toUpperCase();
      if (veh && veh !== '-') choferByPatente.set(veh, emp);
      if (eng && eng !== '-') choferByPatente.set(eng, emp);
    }

    // ─── Recolectar items por chofer ───
    // Map<dni, { chofer, items: [{tipo, tipoDoc, dias, fecha, referencia, params}] }>
    // `params` se usa para el registro de idempotencia individual.
    const itemsPorChofer = new Map();

    function _addItem(dni, chofer, item) {
      if (!itemsPorChofer.has(dni)) {
        itemsPorChofer.set(dni, { chofer, items: [] });
      }
      itemsPorChofer.get(dni).items.push(item);
    }

    // 1) Vencimientos personales del chofer
    for (const [dni, emp] of empleadosByDni) {
      const data = emp.data;
      // Validamos formato (no solo "no vacío") con normalizarTelefonoAWid:
      // si TELEFONO tiene basura (texto, dígitos < 10), saltamos al chofer
      // ANTES de encolar — antes esto pasaba la validación naive y recién
      // se rompía en consumer-time (index.js:250) marcando ERROR en la cola.
      if (!normalizarTelefonoAWid(data.TELEFONO)) {
        if (data.TELEFONO) {
          log.warn(`Chofer ${dni} TELEFONO inválido (${data.TELEFONO}), omitido.`);
        }
        continue;
      }
      const telefono = String(data.TELEFONO);

      for (const [etiqueta, campoBase] of Object.entries(DOCS_EMPLEADO)) {
        // Normalizamos a YYYY-MM-DD via aIsoLocal: cubre strings,
        // Timestamps de Firestore, Date objects y JSON con _seconds
        // sin sufrir el shift UTC vs ART (bug del 2026-05).
        const fechaStr = aIsoLocal(data[`VENCIMIENTO_${campoBase}`]);
        const dias = calcularDiasRestantes(fechaStr);
        if (dias == null) continue;
        const urgencia = hist.urgenciaPara(dias);
        if (!urgencia) continue;

        const params = {
          coleccion: 'EMPLEADOS',
          docId: dni,
          campoBase,
          urgencia: urgencia.codigo,
          fechaVenc: fechaStr,
        };
        if (await hist.yaSeEnvio(db, params)) {
          stats.salteados++;
          continue;
        }
        _addItem(dni, emp, {
          tipo: 'vencimiento',
          tipoDoc: etiqueta,
          dias,
          fecha: fechaStr,
          referencia: null, // personal del chofer, sin referencia a unidad
          params,
        });
      }
    }

    // 2) Vencimientos de unidades (asignadas al chofer)
    const vehiculosSnap = await db.collection('VEHICULOS').get();
    // Index por id de patente para evitar O(N) lookups en el loop de
    // envío (antes se hacía vehiculosSnap.docs.find(d => d.id === ...)
    // por cada item agrupado — N×M iteraciones).
    const vehiculosByPatente = new Map();
    for (const d of vehiculosSnap.docs) {
      vehiculosByPatente.set(d.id, d);
    }
    for (const vDoc of vehiculosSnap.docs) {
      const v = vDoc.data();
      // Soft-delete: vehiculos dados de baja NO reciben avisos.
      if (v.ACTIVO === false) continue;
      // Excluidos: enganches TANQUE + tractores asociados. NO mandar
      // vencimientos de unidades que no controlamos.
      if (excluidos.patentes.has(String(vDoc.id).toUpperCase())) continue;
      const tipo = String(v.TIPO || '').toUpperCase();
      const specs = DOCS_VEHICULO[tipo];
      if (!specs) continue;

      const patente = vDoc.id;
      const chofer = choferByPatente.get(String(patente).trim().toUpperCase());
      if (!chofer) continue;
      if (!normalizarTelefonoAWid(chofer.data.TELEFONO)) {
        if (chofer.data.TELEFONO) {
          log.warn(
            `Chofer ${chofer.id} (asignado a ${patente}) TELEFONO inválido ` +
            `(${chofer.data.TELEFONO}), omitido.`
          );
        }
        continue;
      }
      const telefono = String(chofer.data.TELEFONO);

      for (const spec of specs) {
        // Misma normalizacion que para vencimientos personales.
        const fechaStr = aIsoLocal(v[spec.campoFecha]);
        const dias = calcularDiasRestantes(fechaStr);
        if (dias == null) continue;
        const urgencia = hist.urgenciaPara(dias);
        if (!urgencia) continue;

        const params = {
          coleccion: 'VEHICULOS',
          docId: patente,
          campoBase: spec.campoBase,
          urgencia: urgencia.codigo,
          fechaVenc: fechaStr,
        };
        if (await hist.yaSeEnvio(db, params)) {
          stats.salteados++;
          continue;
        }
        _addItem(chofer.id, chofer, {
          tipo: 'vencimiento',
          tipoDoc: spec.etiqueta,
          dias,
          fecha: fechaStr,
          referencia: `${tipo} ${patente}`,
          params,
        });
      }
    }

    // 3) Service preventivo de TRACTORES
    //
    // CAMBIO 2026-05: el aviso de service ya NO se manda al chofer del
    // tractor. Va consolidado en UN solo mensaje diario al encargado
    // de mantenimiento (SERVICE_DESTINATARIO_DNI en .env, ej.
    // Emmanuel Corchete). Recolectamos aca todos los tractores con
    // urgencia y los procesamos despues del loop "por chofer", en un
    // bloque dedicado.
    const tractoresConUrgencia = [];
    for (const vDoc of vehiculosSnap.docs) {
      const v = vDoc.data();
      // Soft-delete: tractores dados de baja NO entran al resumen.
      if (v.ACTIVO === false) continue;
      // Excluidos: tractores de choferes tanqueros. Emma no se ocupa
      // del service de unidades que no controlamos.
      if (excluidos.patentes.has(String(vDoc.id).toUpperCase())) continue;
      const tipo = String(v.TIPO || '').toUpperCase();
      if (tipo !== 'TRACTOR') continue;

      const patente = vDoc.id;
      const serviceDistanceKm = _resolverServiceDistance(v);
      if (serviceDistanceKm == null) continue;
      const urgencia = hist.urgenciaServicePara(serviceDistanceKm);
      if (!urgencia) continue;

      tractoresConUrgencia.push({
        patente,
        urgencia: urgencia.codigo,
        km: serviceDistanceKm,
        marca: v.MARCA || '',
        modelo: v.MODELO || '',
      });
    }

    // ─── Encolar mensajes (agrupados por chofer) ───
    for (const [dni, { chofer, items }] of itemsPorChofer) {
      if (items.length === 0) continue;
      // Re-validamos: el set de items se acumuló pasando por validaciones
      // arriba pero defensa en profundidad — si llega aquí con TELEFONO
      // inválido, no encolamos.
      if (!normalizarTelefonoAWid(chofer.data.TELEFONO)) {
        if (chofer.data.TELEFONO) {
          log.warn(
            `Chofer ${dni} TELEFONO inválido (${chofer.data.TELEFONO}) ` +
            `al momento de encolar, omitido.`
          );
        }
        continue;
      }
      const telefono = String(chofer.data.TELEFONO).trim();
      const nombre = aviso.resolverNombreSaludo(chofer.data);

      let mensaje;
      let origen;
      if (items.length === 1) {
        // Un solo item — mensaje individual con variantes (texto más
        // natural y empático para casos sueltos).
        const item = items[0];
        if (item.tipo === 'service') {
          // Service usa builder dedicado.
          const patenteItem = item.referencia.split(' ').pop();
          const v = vehiculosByPatente.get(patenteItem);
          mensaje = avisoService.build({
            patente: item.referencia,
            marca: v ? v.data().MARCA : '',
            modelo: v ? v.data().MODELO : '',
            serviceDistanceKm: item.dias,
            destinatarioNombre: nombre,
          });
          if (!mensaje) {
            log.warn(`Service ${item.referencia}: datos inválidos, salto.`);
            continue;
          }
          origen = 'cron_aviso_service';
        } else {
          // Vencimiento normal.
          const titulo = item.referencia
            ? `${item.referencia}` // ya viene formateado "TRACTOR AB123"
            : (chofer.data.NOMBRE || dni);
          mensaje = aviso.build({
            item: {
              coleccion: item.params.coleccion,
              tipoDoc: item.tipoDoc,
              docId: item.params.docId,
              titulo,
              fecha: item.fecha,
              dias: item.dias,
            },
            destinatarioNombre: nombre,
          });
          origen = 'cron_aviso_vencimiento';
        }
      } else {
        // 2+ items — mensaje agrupado.
        mensaje = aviso.buildAgrupado({
          destinatarioNombre: nombre,
          items: items.map((it) => ({
            tipo: it.tipo,
            tipoDoc: it.tipoDoc,
            dias: it.dias,
            fecha: it.fecha,
            referencia: it.referencia,
          })),
        });
        origen = 'cron_aviso_agrupado';
        stats.agrupados++;
      }

      // Encolar UN solo doc en COLA_WHATSAPP + registrar idempotencia
      // ATÓMICAMENTE en un mismo batch. Antes hacía add() y después
      // un loop de registrar() — si el bot crashea en el medio, queda
      // encolado pero sin marcar histórico → próximo ciclo lo
      // re-encola (duplicado al chofer).
      try {
        const colaRef = db.collection(fs.COLECCION).doc();
        const batch = db.batch();
        batch.set(colaRef, {
          telefono,
          mensaje,
          estado: fs.ESTADO.pendiente,
          encolado_en: admin.firestore.FieldValue.serverTimestamp(),
          // TTL Fase 2 (2026-05-18): avisos individuales de
          // vencimientos / service vienen del cron diario. Si por
          // algun motivo el bot esta caido > 24h, el aviso ya no
          // vale (manana se regenera otro con info nueva).
          expira_en: admin.firestore.Timestamp.fromMillis(
            Date.now() + 24 * 60 * 60 * 1000
          ),
          enviado_en: null,
          error: null,
          intentos: 0,
          origen,
          destinatario_coleccion: 'EMPLEADOS',
          destinatario_id: dni,
          campo_base: items.length === 1 ? items[0].params.campoBase : 'AGRUPADO',
          admin_dni: 'BOT',
          admin_nombre: 'Bot automático',
          // Si es agrupado, guardamos también qué papeles incluyó —
          // útil para debugging y para que la pantalla de cola muestre
          // un resumen en vez de "AGRUPADO" pelado.
          items_agrupados: items.length > 1
            ? items.map((it) => ({
                tipoDoc: it.tipoDoc,
                campoBase: it.params.campoBase,
                coleccion: it.params.coleccion,
                docId: it.params.docId,
                fecha: it.fecha,
                dias: it.dias,
              }))
            : null,
        });

        // Registrar idempotencia POR ITEM (cada papel queda marcado
        // individualmente, así si mañana se suma un papel nuevo solo
        // ese se va a re-encolar — los demás ya están "marcados").
        for (const item of items) {
          const reg = hist.prepararRegistro(db, item.params, colaRef.id);
          batch.set(reg.ref, reg.data);
        }
        await batch.commit();

        stats.encolados++;
        if (items.length === 1) {
          log.info(`+ Encolado: ${dni} ${items[0].tipoDoc} → ${colaRef.id}`);
        } else {
          log.info(
            `+ Encolado AGRUPADO: ${dni} (${items.length} papeles) → ${colaRef.id}`
          );
        }
      } catch (e) {
        stats.errores++;
        log.error(`No se pudo encolar para ${dni}: ${e.message}`);
      }
    }

    // ─── Service diario consolidado (1 msj/dia al encargado) ─────
    //
    // REFACTOR 2026-05-18 — datos siempre frescos al momento de envio:
    //
    // Bug detectado: el patron anterior encolaba el mensaje en
    // COLA_WHATSAPP con doc auto-id Y marcaba idempotencia ("ya envie
    // hoy") en el MISMO batch atomico. Si entre encolar y entregar
    // pasaban horas (bot caido, backlog, anti-baneo), el mensaje
    // quedaba "frozen" con datos del cron run viejo. Emma recibia datos
    // desactualizados.
    //
    // Caso real 2026-05-18: encolado 08:23 ART, entregado 13:14 ART
    // (lag 4h51m durante la migracion a PC dedicada). Mensaje a Emma
    // con km desactualizados respecto a lo que admin habia cargado.
    //
    // Fix: doc ID DETERMINISTICO `service_diario_YYYY-MM-DD_<dni>` en
    // COLA_WHATSAPP. La idempotencia ahora vive en el ESTADO del doc:
    //   - No existe                          -> encolar fresco
    //   - Existe + estado=PENDIENTE          -> SOBREESCRIBIR con datos
    //                                           frescos (no fue entregado
    //                                           todavia)
    //   - Existe + estado=ENVIADO            -> SKIP (Emma ya recibio)
    //   - Existe + estado=ERROR              -> SOBREESCRIBIR + reintenta
    //
    // Si el bot cae entre encolar y enviar, el proximo ciclo del cron
    // regenera el mensaje con datos del momento. Garantiza que Emma
    // recibe la version mas fresca disponible al momento real del envio.
    //
    // hist.yaSeEnvioServiceDiario / hist.prepararRegistroServiceDiario
    // quedan obsoletos para este flujo (siguen exportados por compat,
    // pueden borrarse en cleanup futuro).
    // Resuelve el destinatario: primero Firestore (M5, override desde
    // la app), después env var como fallback. Cache 5 min adentro del
    // helper para no pegarle a Firestore en cada tick.
    const dniDestinatarioService = await obtenerDestinatario(
      'serviceDiario',
      process.env.SERVICE_DESTINATARIO_DNI,
    );
    if (dniDestinatarioService) {
      // Lookup con fallback a Firestore: el destinatario suele ser
      // SUPERVISOR/ADMIN y NO está en `empleadosByDni` (que tiene
      // solo CHOFERES desde el refactor del 2026-05-02).
      const empDest = await _obtenerDestinatarioConsolidado(
        db,
        dniDestinatarioService,
        empleadosByDni
      );
      if (!empDest) {
        log.warn(
          `SERVICE_DESTINATARIO_DNI=${dniDestinatarioService} no existe en EMPLEADOS ` +
          `(ni en cache ni en Firestore). Service diario no se envia hoy.`
        );
      } else {
        const telefonoDestRaw = empDest.data.TELEFONO;
        const telefonoDest = normalizarTelefonoAWid(telefonoDestRaw)
          ? String(telefonoDestRaw).trim()
          : null;
        if (!telefonoDest) {
          log.warn(
            `Destinatario service ${dniDestinatarioService} sin TELEFONO ` +
            `válido (raw: ${telefonoDestRaw ?? 'null'}). ` +
            `Service diario no se envia hoy.`
          );
        } else {
          // Calcular ID deterministico con fecha ART (no UTC).
          const hoyArtIso = _fechaArtIso();
          const idCola = `service_diario_${hoyArtIso}_${dniDestinatarioService}`;
          const colaRef = db.collection(fs.COLECCION).doc(idCola);

          try {
            // Chequear estado actual antes de decidir.
            const existing = await colaRef.get();
            if (existing.exists && existing.data().estado === fs.ESTADO.enviado) {
              log.debug(
                `Service diario ya ENTREGADO hoy a ${dniDestinatarioService}, skip.`
              );
            } else {
              // No existe, o PENDIENTE, o ERROR. En cualquier caso
              // sobreescribimos con datos frescos del cron actual.
              const apodoDest = aviso.resolverNombreSaludo(empDest.data);
              const mensajeService = avisoService.buildResumenDiario({
                destinatarioNombre: apodoDest,
                tractores: tractoresConUrgencia,
              });
              const accion = existing.exists ? 'REGENERADO' : 'ENCOLADO';
              await colaRef.set({
                telefono: telefonoDest,
                mensaje: mensajeService,
                estado: fs.ESTADO.pendiente,
                encolado_en: admin.firestore.FieldValue.serverTimestamp(),
                // TTL 36h (auditoria 2026-05-18): si el bot quedo caido
                // > 36h y vuelve, este resumen ya es info stale (datos
                // de hace 1.5+ dias). Mejor descartar que confundir.
                // Por que 36h y no 24h: caso "bot caido desde 8am hasta
                // 10am siguiente" (26h) seria falso negativo con 24h.
                // 36h cubre dia y medio — si esta caido mas, info stale.
                //
                // Caso que NO cubre el doc-determinístico (Fase 1):
                // doc encolado en dia X + bot crashea antes de procesar
                // + vuelve dias despues. El cron de X no vuelve a
                // sobrescribir porque el cron de X+1 usa otro docId
                // (incluye fecha). TTL es la red de seguridad.
                expira_en: admin.firestore.Timestamp.fromMillis(
                  Date.now() + 36 * 60 * 60 * 1000
                ),
                enviado_en: null,
                error: null,
                intentos: 0,
                origen: 'cron_service_diario',
                destinatario_coleccion: 'EMPLEADOS',
                destinatario_id: dniDestinatarioService,
                campo_base: 'SERVICE_DIARIO',
                admin_dni: 'BOT',
                admin_nombre: 'Bot automatico',
                // Lista de tractores incluidos en el reporte. La pantalla
                // "Cola de WhatsApp" puede mostrarlos desplegables
                // (mismo patron que items_agrupados de vencimientos).
                items_agrupados: tractoresConUrgencia.length > 0
                  ? tractoresConUrgencia.map((t) => ({
                      tipoDoc: 'Service',
                      campoBase: 'SERVICE',
                      coleccion: 'VEHICULOS',
                      docId: t.patente,
                      fecha: null,
                      dias: t.km,
                      urgencia: t.urgencia,
                    }))
                  : null,
              });
              stats.encolados++;
              log.info(
                `+ ${accion} SERVICE DIARIO: ${dniDestinatarioService} ` +
                `(${tractoresConUrgencia.length} tractores) -> ${idCola}`
              );
            }
          } catch (e) {
            stats.errores++;
            log.error(`No se pudo encolar service diario: ${e.message}`);
          }
        }
      }
    } else {
      log.debug('SERVICE_DESTINATARIO_DNI no configurado. Skip aviso service diario.');
    }

    // Nota: el "Resumen Alertas Volvo HIGH" diario a Molina vivía
    // acá hasta 2026-05-15. Fue REEMPLAZADO por la Cloud Function
    // `resumenConductaManejoDiario` (functions/src/index.ts), que
    // combina Sitrack (fuente primaria — lo que YPF audita) + Volvo
    // AEBS/ESP (únicos no cubiertos por Sitrack). Los duplicados que
    // recibía Molina (UNSAFE_LANE_CHANGE / LKS / LCS / DISTANCE_ALERT
    // vs Sitrack salida-de-carril 1006 + distancia 444) se eliminaron.

    // ─── Mantenimiento de tablero Volvo → MOVIDO a Cloud Function ───
    // Hasta 2026-05-22 el bot encolaba acá un "Resumen diario — Alertas de
    // mantenimiento" (origen cron_mantenimiento_diario) leyendo eventos
    // TELL_TALE / TPM / TTM / TACHO de VOLVO_ALERTAS. A Emmanuel le llegaba
    // DUPLICADO con el "Parte de mantenimiento" de la Cloud Function
    // `resumenMantenimientoVehiculosDiario` (functions/src/volvo_mantenimiento.ts):
    // ambos reportaban las luces del tablero, el Parte con el testigo EXACTO
    // y la severidad, este resumen con un genérico "Luz de tablero encendida".
    // Se eliminó este resumen; lo único que el Parte no traía (presión/temp de
    // neumático y tacógrafo) se sumó al Parte de la CF. La env var
    // ALERTAS_RESUMEN_DESTINATARIO_DNI queda obsoleta para este flujo.

    // ─── Vencimientos próximos (≤7 días) — al encargado de documentación ─
    // 1 mensaje por día consolidado con TODO lo que vence en los
    // próximos 7 días: legajo de cada chofer, papeles de cada unidad,
    // y los 4 docs de cada empresa empleadora (Póliza ART, F. 931,
    // SCVO, Libre deuda sindical). Si no hay nada en los 3 universos,
    // no se manda mensaje (silencio = nada que reportar).
    //
    // Destinatario configurable por env var para que rotar al
    // encargado no requiera cambios de código (mismo patrón que
    // SERVICE_DESTINATARIO_DNI).
    // REFACTOR 2026-05-18 — datos siempre frescos (ver service_diario arriba).
    // Resuelve destinatario con override Firestore (M5).
    const dniDocumentacion = await obtenerDestinatario(
      'vencimientosProximosConsolidado',
      process.env.DOCUMENTACION_DESTINATARIO_DNI,
    );
    if (dniDocumentacion) {
      const empDoc = await _obtenerDestinatarioConsolidado(
        db,
        dniDocumentacion,
        empleadosByDni
      );
      if (!empDoc) {
        log.warn(
          `DOCUMENTACION_DESTINATARIO_DNI=${dniDocumentacion} no existe en EMPLEADOS. ` +
            `Resumen de vencimientos próximos no se envía hoy.`
        );
      } else {
        const telDocRaw = empDoc.data.TELEFONO;
        const telDoc = normalizarTelefonoAWid(telDocRaw)
          ? String(telDocRaw).trim()
          : null;
        if (!telDoc) {
          log.warn(
            `Destinatario documentación ${dniDocumentacion} sin TELEFONO válido. ` +
              `Resumen de vencimientos próximos no se envía hoy.`
          );
        } else {
          // Doc ID deterministico: idempotencia basada en estado real.
          const hoyArtIso = _fechaArtIso();
          const idColaV = `venc_proximos_${hoyArtIso}_${dniDocumentacion}`;
          const colaRefV = db.collection(fs.COLECCION).doc(idColaV);

          // Pre-chequeo: si ya fue ENVIADO hoy, skip antes de calcular
          // items (evita 3 queries pesadas EMPLEADOS+VEHICULOS+EMPRESAS).
          const existingV = await colaRefV.get();
          if (existingV.exists && existingV.data().estado === fs.ESTADO.enviado) {
            log.debug(
              `Vencimientos próximos ya ENTREGADO hoy a ${dniDocumentacion}, skip.`
            );
          } else {
            // Etiquetas de los 4 docs por empresa — réplica de
            // AppDocsEmpresa (cliente Flutter). En el resumen al
            // encargado de documentación usamos la etiqueta TÉCNICA
            // (SCVO, no "Seguro de Vida") porque es la persona que
            // habla con la aseguradora / RR.HH.
            const DOCS_EMPRESA = [
              { etiqueta: 'Póliza ART', campoFecha: 'VENCIMIENTO_POLIZA_ART' },
              { etiqueta: 'Formulario 931', campoFecha: 'VENCIMIENTO_FORMULARIO_931' },
              { etiqueta: 'SCVO', campoFecha: 'VENCIMIENTO_SCVO' },
              {
                etiqueta: 'Libre deuda sindical',
                campoFecha: 'VENCIMIENTO_LIBRE_DE_DEUDA_SINDICAL',
              },
            ];

            const itemsPersonal = [];
            for (const [, emp] of empleadosByDni) {
              const data = emp.data;
              // Skip empleados dados de baja.
              if (data.ACTIVO === false) continue;
              const nombre =
                aviso.resolverNombreSaludo(data) ||
                String(data.NOMBRE || '').trim() ||
                emp.id;
              for (const [etiqueta, campoBase] of Object.entries(DOCS_EMPLEADO)) {
                const fechaStr = aIsoLocal(data[`VENCIMIENTO_${campoBase}`]);
                const dias = calcularDiasRestantes(fechaStr);
                if (dias == null) continue;
                if (dias < 0 || dias > DIAS_AVISO_VENC_PERSONAL_VEH) continue;
                itemsPersonal.push({ chofer: nombre, etiqueta, fecha: fechaStr, dias });
              }
            }

            const itemsVehiculos = [];
            // Reusamos el snapshot de VEHICULOS que ya cargó el cron
            // arriba (línea ~306) para vencimientos por unidad — evita
            // doble query.
            for (const vDoc of vehiculosSnap.docs) {
              const v = vDoc.data();
              if (v.ACTIVO === false) continue;
              // Excluidos: unidades tanqueras + tractores asociados.
              if (excluidos.patentes.has(String(vDoc.id).toUpperCase())) continue;
              const tipo = String(v.TIPO || '').toUpperCase();
              const specs = DOCS_VEHICULO[tipo];
              if (!specs) continue;
              const patente = vDoc.id;
              for (const spec of specs) {
                const fechaStr = aIsoLocal(v[spec.campoFecha]);
                const dias = calcularDiasRestantes(fechaStr);
                if (dias == null) continue;
                if (dias < 0 || dias > DIAS_AVISO_VENC_PERSONAL_VEH) continue;
                itemsVehiculos.push({
                  patente,
                  tipoUnidad: tipo,
                  etiqueta: spec.etiqueta,
                  fecha: fechaStr,
                  dias,
                });
              }
            }

            const itemsEmpresas = [];
            try {
              const empresasSnap = await db
                .collection('EMPRESAS_EMPLEADORAS')
                .get();
              for (const eDoc of empresasSnap.docs) {
                const data = eDoc.data();
                const nombreEmpresa =
                  String(data.nombre || '').trim() || `CUIT ${eDoc.id}`;
                for (const docSpec of DOCS_EMPRESA) {
                  const fechaStr = aIsoLocal(data[docSpec.campoFecha]);
                  const dias = calcularDiasRestantes(fechaStr);
                  if (dias == null) continue;
                  // Empresas usan ventana mas amplia (30 dias) que
                  // personal/vehiculos (15 dias) — tramites con
                  // contabilidad / aseguradora son mas lentos.
                  if (dias < 0 || dias > DIAS_AVISO_VENC_EMPRESAS) continue;
                  itemsEmpresas.push({
                    empresa: nombreEmpresa,
                    etiqueta: docSpec.etiqueta,
                    fecha: fechaStr,
                    dias,
                  });
                }
              }
            } catch (e) {
              log.warn(
                `EMPRESAS_EMPLEADORAS no se pudo leer (${e.message}). ` +
                  `Sigo con personal/vehículos.`
              );
            }

            const totalItems =
              itemsPersonal.length + itemsVehiculos.length + itemsEmpresas.length;

            const mensajeVencProx = avisoVencProx.buildResumenVencimientosProximos({
              destinatarioNombre: aviso.resolverNombreSaludo(empDoc.data),
              itemsPersonal,
              itemsVehiculos,
              itemsEmpresas,
            });

            // Encolamos SIEMPRE — el builder devuelve mensaje
            // "sin novedades" si no hay items (decisión Santiago
            // 2026-05-09: silencio es ambiguo).
            if (!mensajeVencProx) {
              // Defensivo: el builder siempre debería devolver string.
              log.warn(
                `Builder vencimientos próximos devolvio null inesperadamente. Skip.`
              );
            } else {
              try {
                const accion = existingV.exists ? 'REGENERADO' : 'ENCOLADO';
                await colaRefV.set({
                  telefono: telDoc,
                  mensaje: mensajeVencProx,
                  estado: fs.ESTADO.pendiente,
                  encolado_en: admin.firestore.FieldValue.serverTimestamp(),
                  // TTL 36h — mismo razonamiento que service_diario arriba.
                  expira_en: admin.firestore.Timestamp.fromMillis(
                    Date.now() + 36 * 60 * 60 * 1000
                  ),
                  enviado_en: null,
                  error: null,
                  intentos: 0,
                  origen: 'cron_vencimientos_proximos_diario',
                  destinatario_coleccion: 'EMPLEADOS',
                  destinatario_id: dniDocumentacion,
                  campo_base: 'VENCIMIENTOS_PROXIMOS_DIARIO',
                  admin_dni: 'BOT',
                  admin_nombre: 'Bot automatico',
                  items_agrupados: [
                    ...itemsPersonal.map((it) => ({
                      tipoDoc: it.etiqueta,
                      campoBase: 'VENC_PERSONAL',
                      coleccion: 'EMPLEADOS',
                      docId: it.chofer,
                      fecha: it.fecha,
                      dias: it.dias,
                    })),
                    ...itemsVehiculos.map((it) => ({
                      tipoDoc: it.etiqueta,
                      campoBase: 'VENC_VEHICULO',
                      coleccion: 'VEHICULOS',
                      docId: it.patente,
                      fecha: it.fecha,
                      dias: it.dias,
                    })),
                    ...itemsEmpresas.map((it) => ({
                      tipoDoc: it.etiqueta,
                      campoBase: 'VENC_EMPRESA',
                      coleccion: 'EMPRESAS_EMPLEADORAS',
                      docId: it.empresa,
                      fecha: it.fecha,
                      dias: it.dias,
                    })),
                  ],
                });
                stats.encolados++;
                log.info(
                  `+ ${accion} VENCIMIENTOS PRÓXIMOS: ${dniDocumentacion} ` +
                    `(${itemsPersonal.length} personal, ${itemsVehiculos.length} unidades, ` +
                    `${itemsEmpresas.length} empresas) -> ${idColaV}`
                );
              } catch (e) {
                stats.errores++;
                log.error(
                  `No se pudo encolar resumen vencimientos próximos: ${e.message}`
                );
              }
            }
          }
        }
      }
    } else {
      log.debug(
        'DOCUMENTACION_DESTINATARIO_DNI no configurado. Skip resumen vencimientos próximos.'
      );
    }

    // Nota: el cron `cron_venc_empresas_admin_diario` (aviso temprano
    // 30 dias al admin) vivia aca hasta 2026-05-18. Fue ELIMINADO y
    // unificado en el cron de Giagante de arriba: los docs de empresa
    // ahora usan ventana 30 dias dentro del mismo resumen
    // (DIAS_AVISO_VENC_EMPRESAS=30 vs DIAS_AVISO_VENC_PERSONAL_VEH=15).
    // Decision Santiago 2026-05-18: Giagante es quien efectivamente
    // tracta con contabilidad/aseguradora — no tiene sentido que el
    // admin reciba el aviso temprano por separado. La env var
    // EMPRESA_DOCS_ADMIN_DNI queda obsoleta (sin efecto si sigue
    // seteada en .env).

    log.info(
      `Cron ciclo cerrado: encolados=${stats.encolados} ` +
        `(de los cuales ${stats.agrupados} agrupados) ` +
        `salteados=${stats.salteados} errores=${stats.errores}`
    );
    health.registrarCicloCron(stats);
  } catch (e) {
    log.error(`Cron falló: ${e.stack || e.message}`);
    health.registrarError('cron', e.message);
  } finally {
    _running = false;
  }
}

/**
 * Calcula `serviceDistanceKm` para un doc de VEHICULOS.
 * Espejo de `_resolverServiceDistance` en el cliente Dart.
 *
 * Prioridad MANUAL: si hay ULTIMO_SERVICE_KM + KM_ACTUAL cargados,
 * usa el cálculo manual `ULTIMO_SERVICE_KM + 50.000 - KM_ACTUAL`.
 * El API Volvo (`SERVICE_DISTANCE_KM`) queda como fallback porque
 * a veces devuelve valores absurdos para vehículos sin paquete
 * UPTIME activo (caso real: AG218ZD con 642.069 km al próximo
 * service según API, pero -1.500 km según manual).
 */
function _resolverServiceDistance(v) {
  const ultimo = Number(v.ULTIMO_SERVICE_KM);
  const actual = Number(v.KM_ACTUAL);
  if (!isNaN(ultimo) && !isNaN(actual) && v.ULTIMO_SERVICE_KM != null && v.KM_ACTUAL != null) {
    return ultimo + INTERVALO_SERVICE_KM - actual;
  }

  const api = Number(v.SERVICE_DISTANCE_KM);
  if (!isNaN(api) && v.SERVICE_DISTANCE_KM != null) return api;

  return null;
}

/**
 * Fuerza una corrida del cron AHORA, ignorando el setInterval. Usado
 * por el comando admin /forzar-cron y por tests. Idempotente con
 * `_running`: si ya hay uno corriendo, sale silencioso.
 *
 * @returns {Promise<{stats: object} | {skipped: true}>}
 */
async function forzarRunOnce(fs) {
  if (_running) {
    log.info('forzarRunOnce: ya hay un ciclo en progreso, salteo.');
    return { skipped: true };
  }
  return _runOnce(fs);
}

/**
 * Indica si hay un ciclo de cron en ejecución. Lo usa el shutdown del
 * bot para esperar a que termine antes de tirar el cliente — sin esto,
 * un `_runOnce` a medio-batch.commit quedaba abortado por `process.exit`
 * y dejaba encolados sin registrar la idempotencia (próximo ciclo los
 * re-encolaba). Auditoria 2026-05-17.
 */
function isRunning() {
  return _running;
}

module.exports = {
  start,
  stop,
  forzarRunOnce,
  isRunning,
  // Exportado para tests / debugging.
  calcularDiasRestantes,
};
