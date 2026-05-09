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
const avisoAlertasVolvo = require('./aviso_alertas_volvo_builder');
const avisoVencProx = require('./aviso_vencimientos_proximos_builder');
const hist = require('./historico');
const health = require('./health');
const fs = require('./firestore');
const { aIsoLocal } = require('./fechas');

// Banner que se muestra al final de los mensajes mientras la app esté
// en etapa de prueba. Espejo del que cada builder define localmente —
// duplicado acá para los avisos inline que no usan builder dedicado.
const BANNER_TESTING =
  '⚠️ *Etapa de prueba* — si ves un error o algo no encaja, avisanos. ' +
  'No tomes el contenido al 100%.\n\n';

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
  } catch {
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
    for (const vDoc of vehiculosSnap.docs) {
      const v = vDoc.data();
      // Soft-delete: vehiculos dados de baja NO reciben avisos.
      if (v.ACTIVO === false) continue;
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
          const v = vehiculosSnap.docs.find((d) => d.id === item.referencia.split(' ').pop());
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

      // Encolar UN solo doc en COLA_WHATSAPP.
      try {
        const colaRef = await db.collection(fs.COLECCION).add({
          telefono,
          mensaje,
          estado: fs.ESTADO.pendiente,
          encolado_en: admin.firestore.FieldValue.serverTimestamp(),
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
          await hist.registrar(db, item.params, colaRef.id);
        }

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
    const dniDestinatarioService = process.env.SERVICE_DESTINATARIO_DNI;
    if (dniDestinatarioService) {
      const yaEnviado = await hist.yaSeEnvioServiceDiario(db, dniDestinatarioService);
      if (yaEnviado) {
        log.debug(`Service diario ya enviado hoy a ${dniDestinatarioService}, skip.`);
      } else {
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
            const apodoDest = aviso.resolverNombreSaludo(empDest.data);
            const mensajeService = avisoService.buildResumenDiario({
              destinatarioNombre: apodoDest,
              tractores: tractoresConUrgencia,
            });
            try {
              const colaRef = await db.collection(fs.COLECCION).add({
                telefono: telefonoDest,
                mensaje: mensajeService,
                estado: fs.ESTADO.pendiente,
                encolado_en: admin.firestore.FieldValue.serverTimestamp(),
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
              await hist.registrarServiceDiario(db, dniDestinatarioService, {
                cantidadTractores: tractoresConUrgencia.length,
                colaDocId: colaRef.id,
              });
              stats.encolados++;
              log.info(
                `+ Encolado SERVICE DIARIO: ${dniDestinatarioService} ` +
                `(${tractoresConUrgencia.length} tractores) -> ${colaRef.id}`
              );
            } catch (e) {
              stats.errores++;
              log.error(`No se pudo encolar service diario: ${e.message}`);
            }
          }
        }
      }
    } else {
      log.debug('SERVICE_DESTINATARIO_DNI no configurado. Skip aviso service diario.');
    }

    // ─── Alertas Volvo: resumen diario al admin ─────────────────────
    // Mismo patron que service diario: 1 mensaje por dia con el listado
    // consolidado de eventos HIGH severity de las ultimas 24h. Se envia
    // al primer ciclo del dia que cae en horario habil (~8:00 ART).
    // Si no hubo eventos HIGH, NO se manda nada (silencio = nada que
    // reportar; mandar "todo OK" todos los dias seria ruido para algo
    // que ya tiene baja frecuencia).
    // El resumen diario de alertas Volvo va SOLO al jefe de Seg e
    // Higiene (Molina, DNI 34730329). Decisión Vecchi 2026-05-07: el
    // admin (Santiago) no necesita recibirlo. Hardcodeado a propósito
    // porque "Jefe de Seg e Higiene" es un rol estable; si rota la
    // persona se cambia acá. El bloque de mantenimiento más abajo
    // sigue usando `ALERTAS_RESUMEN_DESTINATARIO_DNI` y va al admin.
    const dniAlertasResumen = '34730329';
    if (dniAlertasResumen) {
      const yaEnviadoAlertas = await hist.yaSeEnvioAlertasResumen(
        db,
        dniAlertasResumen
      );
      if (yaEnviadoAlertas) {
        log.debug(
          `Alertas Volvo resumen ya enviado hoy a ${dniAlertasResumen}, skip.`
        );
      } else {
        // Mismo lookup con fallback que para SERVICE_DESTINATARIO_DNI.
        const empAlertas = await _obtenerDestinatarioConsolidado(
          db,
          dniAlertasResumen,
          empleadosByDni
        );
        if (!empAlertas) {
          log.warn(
            `Jefe Seg e Higiene DNI=${dniAlertasResumen} no existe en ` +
              `EMPLEADOS (ni en cache ni en Firestore). Resumen alertas Volvo no se envia hoy.`
          );
        } else {
          const telAlertas = empAlertas.data.TELEFONO
            ? String(empAlertas.data.TELEFONO).trim()
            : null;
          if (!telAlertas) {
            log.warn(
              `Destinatario alertas ${dniAlertasResumen} no tiene TELEFONO. ` +
                `Resumen alertas Volvo no se envia hoy.`
            );
          } else {
            // Query VOLVO_ALERTAS de las ultimas 24h con severidad HIGH.
            const desde = admin.firestore.Timestamp.fromMillis(
              Date.now() - 24 * 60 * 60 * 1000
            );
            const alertasSnap = await db
              .collection('VOLVO_ALERTAS')
              .where('severidad', '==', 'HIGH')
              .where('creado_en', '>=', desde)
              .get();
            // Tipos excluidos del resumen a Seg e Higiene — son
            // mecánicos, no de conducta. AdBlue es tema del taller,
            // no del jefe de seguridad. TELL_TALE (luz de tablero)
            // también es mecánico — el chofer no puede investigar
            // qué luz se encendió, lo evalúa el taller.
            // Si Volvo los marcó como HIGH (por riesgo de derate o
            // alguna condición crítica), igual entran al resumen de
            // mantenimiento más abajo, no a este.
            const TIPOS_EXCLUIDOS_SEG_HIGIENE = new Set([
              'ADBLUELEVEL_LOW',
              'WITHOUT_ADBLUE',
              'TELL_TALE',
            ]);
            const eventos = alertasSnap.docs
              .map((d) => {
                const data = d.data();
                const patente = String(data.patente || '—').trim();
                const tipo = String(data.tipo || '').trim();
                // Volvo Vehicle Alerts API devuelve un solo tipo "GENERIC"
                // que envuelve varios sub-eventos (SEATBELT, TELL_TALE,
                // ALERTA_FATIGA, etc.). El subtipo viene en
                // detalle_generic — pero según el endpoint puede estar
                // como `triggerType` (alertas HIGH) o como `type`
                // (alertas mantenimiento). Leemos ambos defensivamente.
                // Sin esto el resumen muestra todo como "Evento genérico"
                // sin info útil para el destinatario.
                const subTipo = (tipo === 'GENERIC')
                  ? (
                      String(data.detalle_generic?.triggerType ?? '').toUpperCase() ||
                      String(data.detalle_generic?.type ?? '').toUpperCase() ||
                      null
                    )
                  : null;
                const creadoEn = data.creado_en;
                const fechaHora = creadoEn && typeof creadoEn.toDate === 'function'
                  ? creadoEn.toDate()
                  : new Date();
                // Lookup chofer por patente (mapa ya cargado al inicio
                // del cron). Si no hay match, dejamos null y el builder
                // lo muestra como "patente sin chofer".
                const chofer = choferByPatente.get(
                  patente.toUpperCase()
                );
                const choferNombre = chofer
                  ? aviso.resolverNombreSaludo(chofer.data)
                  : null;
                return { patente, tipo, subTipo, choferNombre, fechaHora };
              })
              .filter((ev) =>
                !TIPOS_EXCLUIDOS_SEG_HIGIENE.has(ev.tipo) &&
                !TIPOS_EXCLUIDOS_SEG_HIGIENE.has(ev.subTipo)
              );

            if (eventos.length === 0) {
              log.info(
                `Resumen alertas Volvo: 0 eventos HIGH en ultimas 24h, ` +
                  `no se envia mensaje.`
              );
              // Marcamos en historico igual para que no se chequee mil
              // veces en el mismo dia. Idempotencia diaria preservada.
              await hist.registrarAlertasResumen(db, dniAlertasResumen, {
                cantidadEventos: 0,
                colaDocId: null,
              });
            } else {
              const apodoAlertas = aviso.resolverNombreSaludo(empAlertas.data);
              const mensajeAlertas = avisoAlertasVolvo.buildResumenDiario({
                destinatarioNombre: apodoAlertas,
                eventos,
              });
              if (!mensajeAlertas) {
                // No deberia pasar (eventos.length > 0 garantiza que el
                // builder devuelve string), pero defensivo.
                log.warn(
                  `Builder de resumen alertas devolvio null con ${eventos.length} ` +
                    `eventos. Skip.`
                );
              } else {
                try {
                  const colaRef = await db.collection(fs.COLECCION).add({
                    telefono: telAlertas,
                    mensaje: mensajeAlertas,
                    estado: fs.ESTADO.pendiente,
                    encolado_en: admin.firestore.FieldValue.serverTimestamp(),
                    enviado_en: null,
                    error: null,
                    intentos: 0,
                    origen: 'cron_alertas_volvo_diario',
                    destinatario_coleccion: 'EMPLEADOS',
                    destinatario_id: dniAlertasResumen,
                    campo_base: 'ALERTAS_VOLVO_DIARIO',
                    admin_dni: 'BOT',
                    admin_nombre: 'Bot automatico',
                    items_agrupados: eventos.map((e) => ({
                      tipoDoc: 'AlertaVolvo',
                      campoBase: 'ALERTAS_VOLVO',
                      coleccion: 'VOLVO_ALERTAS',
                      docId: `${e.patente}_${e.tipo}_${e.fechaHora.toISOString()}`,
                      fecha: e.fechaHora.toISOString(),
                      tipo: e.tipo,
                      chofer: e.choferNombre,
                    })),
                  });
                  await hist.registrarAlertasResumen(db, dniAlertasResumen, {
                    cantidadEventos: eventos.length,
                    colaDocId: colaRef.id,
                  });
                  stats.encolados++;
                  log.info(
                    `+ Encolado RESUMEN ALERTAS VOLVO: ${dniAlertasResumen} ` +
                      `(${eventos.length} eventos HIGH 24h) -> ${colaRef.id}`
                  );
                } catch (e) {
                  stats.errores++;
                  log.error(
                    `No se pudo encolar resumen alertas Volvo: ${e.message}`
                  );
                }
              }
            }
          }
        }
      }
    }

    // ─── Mantenimiento diario consolidado (1 msg/día al admin) ────────
    // Mismo patrón que cron_alertas_volvo_diario pero para eventos de
    // mantenimiento: FUEL, CATALYST, y GENERIC con sub-tipo TELL_TALE /
    // ADBLUELEVEL_LOW / WITHOUT_ADBLUE. La Cloud Function
    // onAlertaVolvoMantenimientoCreated ya NO encola en COLA_WHATSAPP —
    // solo persiste en VOLVO_ALERTAS. Este bloque del cron los recoge una
    // vez por día y arma UN solo mensaje consolidado para el admin.
    const TIPOS_MANT_DIRECTOS = new Set(['FUEL', 'CATALYST']);
    const SUBTIPOS_MANT_GENERIC = new Set(['TELL_TALE', 'ADBLUELEVEL_LOW', 'WITHOUT_ADBLUE']);

    const dniMantenimiento = process.env.ALERTAS_RESUMEN_DESTINATARIO_DNI;
    if (dniMantenimiento) {
      const yaEnviadoMant = await hist.yaSeEnvioMantenimientoDiario(db, dniMantenimiento);
      if (yaEnviadoMant) {
        log.debug(`Mantenimiento diario ya enviado hoy a ${dniMantenimiento}, skip.`);
      } else {
        const empMant = await _obtenerDestinatarioConsolidado(db, dniMantenimiento, empleadosByDni);
        if (!empMant) {
          log.warn(
            `ALERTAS_RESUMEN_DESTINATARIO_DNI=${dniMantenimiento} no existe en EMPLEADOS. ` +
            `Mantenimiento diario no se envía hoy.`
          );
        } else {
          const telMantRaw = empMant.data.TELEFONO;
          const telMant = normalizarTelefonoAWid(telMantRaw)
            ? String(telMantRaw).trim()
            : null;
          if (!telMant) {
            log.warn(
              `Destinatario mantenimiento ${dniMantenimiento} sin TELEFONO válido. ` +
              `Mantenimiento diario no se envía hoy.`
            );
          } else {
            const desdeMant = admin.firestore.Timestamp.fromMillis(
              Date.now() - 24 * 60 * 60 * 1000
            );
            const mantSnap = await db
              .collection('VOLVO_ALERTAS')
              .where('creado_en', '>=', desdeMant)
              .get();

            const eventosMant = [];
            for (const d of mantSnap.docs) {
              const data = d.data();
              const tipo = String(data.tipo || '').toUpperCase();
              let esMant = TIPOS_MANT_DIRECTOS.has(tipo);
              let subTipo = null;
              if (!esMant && tipo === 'GENERIC') {
                const subType = String(
                  (data.detalle_generic?.type ?? '')
                ).toUpperCase();
                if (SUBTIPOS_MANT_GENERIC.has(subType)) {
                  esMant = true;
                  subTipo = subType;
                }
              }
              if (!esMant) continue;

              const creadoEn = data.creado_en;
              const fechaHora =
                creadoEn && typeof creadoEn.toDate === 'function'
                  ? creadoEn.toDate()
                  : new Date();
              eventosMant.push({
                patente: String(data.patente || '—').trim(),
                tipo,
                subTipo,
                choferNombre: data.chofer_nombre
                  ? String(data.chofer_nombre).trim()
                  : null,
                fechaHora,
              });
            }

            const mensajeMant = avisoAlertasVolvo.buildResumenMantenimientoDiario({
              destinatarioNombre: aviso.resolverNombreSaludo(empMant.data),
              eventos: eventosMant,
            });

            if (!mensajeMant) {
              log.info(
                `Mantenimiento diario: 0 eventos en últimas 24h, no se envía.`
              );
              await hist.registrarMantenimientoDiario(db, dniMantenimiento, {
                cantidadEventos: 0,
                colaDocId: null,
              });
            } else {
              try {
                const colaRef = await db.collection(fs.COLECCION).add({
                  telefono: telMant,
                  mensaje: mensajeMant,
                  estado: fs.ESTADO.pendiente,
                  encolado_en: admin.firestore.FieldValue.serverTimestamp(),
                  enviado_en: null,
                  error: null,
                  intentos: 0,
                  origen: 'cron_mantenimiento_diario',
                  destinatario_coleccion: 'EMPLEADOS',
                  destinatario_id: dniMantenimiento,
                  campo_base: 'MANTENIMIENTO_DIARIO',
                  admin_dni: 'BOT',
                  admin_nombre: 'Bot automatico',
                  items_agrupados: eventosMant.map((e) => ({
                    tipoDoc: e.subTipo || e.tipo,
                    campoBase: 'VOLVO_ALERT_MANTENIMIENTO',
                    coleccion: 'VOLVO_ALERTAS',
                    docId: `${e.patente}_${e.tipo}`,
                    fecha: e.fechaHora.toISOString(),
                    tipo: e.tipo,
                    subTipo: e.subTipo,
                    chofer: e.choferNombre,
                  })),
                });
                await hist.registrarMantenimientoDiario(db, dniMantenimiento, {
                  cantidadEventos: eventosMant.length,
                  colaDocId: colaRef.id,
                });
                stats.encolados++;
                log.info(
                  `+ Encolado MANTENIMIENTO DIARIO: ${dniMantenimiento} ` +
                  `(${eventosMant.length} eventos) -> ${colaRef.id}`
                );
              } catch (e) {
                stats.errores++;
                log.error(`No se pudo encolar mantenimiento diario: ${e.message}`);
              }
            }
          }
        }
      }
    } else {
      log.debug(
        'ALERTAS_RESUMEN_DESTINATARIO_DNI no configurado. Skip mantenimiento diario.'
      );
    }

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
    const dniDocumentacion = process.env.DOCUMENTACION_DESTINATARIO_DNI;
    if (dniDocumentacion) {
      const yaEnviadoVencProx = await hist.yaSeEnvioVencimientosProximos(
        db,
        dniDocumentacion
      );
      if (yaEnviadoVencProx) {
        log.debug(
          `Vencimientos próximos ya enviados hoy a ${dniDocumentacion}, skip.`
        );
      } else {
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
                if (dias < 0 || dias > 7) continue;
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
              const tipo = String(v.TIPO || '').toUpperCase();
              const specs = DOCS_VEHICULO[tipo];
              if (!specs) continue;
              const patente = vDoc.id;
              for (const spec of specs) {
                const fechaStr = aIsoLocal(v[spec.campoFecha]);
                const dias = calcularDiasRestantes(fechaStr);
                if (dias == null) continue;
                if (dias < 0 || dias > 7) continue;
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
                  if (dias < 0 || dias > 7) continue;
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

            if (!mensajeVencProx) {
              log.info(
                `Vencimientos próximos: 0 items en próximos 7 días, no se envía.`
              );
              await hist.registrarVencimientosProximos(db, dniDocumentacion, {
                cantidadItems: 0,
                colaDocId: null,
              });
            } else {
              try {
                const colaRef = await db.collection(fs.COLECCION).add({
                  telefono: telDoc,
                  mensaje: mensajeVencProx,
                  estado: fs.ESTADO.pendiente,
                  encolado_en: admin.firestore.FieldValue.serverTimestamp(),
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
                await hist.registrarVencimientosProximos(db, dniDocumentacion, {
                  cantidadItems: totalItems,
                  colaDocId: colaRef.id,
                });
                stats.encolados++;
                log.info(
                  `+ Encolado VENCIMIENTOS PRÓXIMOS: ${dniDocumentacion} ` +
                    `(${itemsPersonal.length} personal, ${itemsVehiculos.length} unidades, ` +
                    `${itemsEmpresas.length} empresas) -> ${colaRef.id}`
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

    // ─── Aviso temprano al admin de docs por EMPRESA empleadora ──────
    // Umbral 30 días (más amplio que el de Giagante de 7) — el admin
    // necesita aviso temprano para coordinar la renovación con
    // contabilidad / RR.HH. antes de que se vuelva urgente.
    //
    // Reusa `MANTENIMIENTO_DESTINATARIO_DNI` que apunta al admin
    // (hardcoded en functions/src/index.ts = 35244439 = Santiago).
    // Si querés cambiarlo, env var `EMPRESA_DOCS_ADMIN_DNI`
    // tiene prioridad. Si ninguno está seteado, skip.
    const dniAdminEmpresas =
      process.env.EMPRESA_DOCS_ADMIN_DNI || '35244439';
    if (dniAdminEmpresas) {
      const yaEnviadoEmp = await hist.yaSeEnvioVencEmpresasAdmin(
        db,
        dniAdminEmpresas
      );
      if (yaEnviadoEmp) {
        log.debug(
          `Aviso docs empresa al admin ya enviado hoy a ${dniAdminEmpresas}, skip.`
        );
      } else {
        const empAdmin = await _obtenerDestinatarioConsolidado(
          db,
          dniAdminEmpresas,
          empleadosByDni
        );
        if (!empAdmin) {
          log.warn(
            `Admin docs empresa DNI=${dniAdminEmpresas} no existe en EMPLEADOS. ` +
              `Aviso no se envía hoy.`
          );
        } else {
          const telAdmin = normalizarTelefonoAWid(empAdmin.data.TELEFONO)
            ? String(empAdmin.data.TELEFONO).trim()
            : null;
          if (!telAdmin) {
            log.warn(
              `Admin docs empresa ${dniAdminEmpresas} sin TELEFONO válido. ` +
                `Aviso no se envía hoy.`
            );
          } else {
            const DOCS_EMPRESA = [
              {etiqueta: 'Póliza ART', campoFecha: 'VENCIMIENTO_POLIZA_ART'},
              {etiqueta: 'Formulario 931', campoFecha: 'VENCIMIENTO_FORMULARIO_931'},
              {etiqueta: 'SCVO', campoFecha: 'VENCIMIENTO_SCVO'},
              {
                etiqueta: 'Libre deuda sindical',
                campoFecha: 'VENCIMIENTO_LIBRE_DE_DEUDA_SINDICAL',
              },
            ];

            const items = [];
            try {
              const empSnap = await db
                .collection('EMPRESAS_EMPLEADORAS')
                .get();
              for (const eDoc of empSnap.docs) {
                const data = eDoc.data();
                const nombreEmpresa =
                  String(data.nombre || '').trim() || `CUIT ${eDoc.id}`;
                for (const docSpec of DOCS_EMPRESA) {
                  const fechaStr = aIsoLocal(data[docSpec.campoFecha]);
                  const dias = calcularDiasRestantes(fechaStr);
                  if (dias == null) continue;
                  // Umbral 30 días — aviso temprano. Incluye vencidos
                  // (dias < 0) para que el admin no se entere tarde
                  // si Giagante no actuó.
                  if (dias > 30) continue;
                  items.push({
                    empresa: nombreEmpresa,
                    etiqueta: docSpec.etiqueta,
                    fecha: fechaStr,
                    dias,
                  });
                }
              }
            } catch (e) {
              log.warn(
                `EMPRESAS_EMPLEADORAS no se pudo leer (${e.message}). Skip aviso admin.`
              );
            }

            if (items.length === 0) {
              log.info(
                'Aviso docs empresa al admin: 0 items en próximos 30 días, no se envía.'
              );
              await hist.registrarVencEmpresasAdmin(db, dniAdminEmpresas, {
                cantidadItems: 0,
                colaDocId: null,
              });
            } else {
              // Mensaje inline (no merece builder dedicado por ahora).
              const apodoAdmin = aviso.resolverNombreSaludo(empAdmin.data);
              const saludo = apodoAdmin ? `Hola ${apodoAdmin}` : 'Hola';
              items.sort((a, b) => a.dias - b.dias);
              const porEmpresa = new Map();
              for (const it of items) {
                if (!porEmpresa.has(it.empresa)) porEmpresa.set(it.empresa, []);
                porEmpresa.get(it.empresa).push(it);
              }
              const bloques = [...porEmpresa.entries()]
                .sort(([a], [b]) => a.localeCompare(b))
                .map(([empresa, list]) => {
                  const lineas = list.map((it) => {
                    const etiq = it.dias < 0
                      ? `vencido hace ${-it.dias} d`
                      : it.dias === 0
                        ? 'vence hoy'
                        : it.dias === 1
                          ? 'vence mañana'
                          : `en ${it.dias} días`;
                    return `   • ${it.etiqueta} — ${it.fecha} (${etiq})`;
                  });
                  return `🏢 *${empresa}*\n${lineas.join('\n')}`;
                });

              const mensajeAdmin =
                `${saludo}.\n\n` +
                `📋 *Aviso temprano — docs por empresa próximos a vencer (≤30 días)*\n\n` +
                `${items.length === 1 ? '1 documento' : `${items.length} documentos`} ` +
                `requieren atención de la oficina:\n\n` +
                `${bloques.join('\n\n')}\n\n` +
                BANNER_TESTING +
                '_Coordiná con Giagante (encargado de documentación) la renovación. ' +
                'Vos lo recibís 30 días antes; Giagante recibe el detalle final cuando ' +
                'queden 7 días._';

              try {
                const colaRef = await db.collection(fs.COLECCION).add({
                  telefono: telAdmin,
                  mensaje: mensajeAdmin,
                  estado: fs.ESTADO.pendiente,
                  encolado_en: admin.firestore.FieldValue.serverTimestamp(),
                  enviado_en: null,
                  error: null,
                  intentos: 0,
                  origen: 'cron_venc_empresas_admin_diario',
                  destinatario_coleccion: 'EMPLEADOS',
                  destinatario_id: dniAdminEmpresas,
                  campo_base: 'VENC_EMPRESAS_ADMIN_DIARIO',
                  admin_dni: 'BOT',
                  admin_nombre: 'Bot automatico',
                  items_agrupados: items.map((it) => ({
                    tipoDoc: it.etiqueta,
                    campoBase: 'VENC_EMPRESA_ADMIN',
                    coleccion: 'EMPRESAS_EMPLEADORAS',
                    docId: it.empresa,
                    fecha: it.fecha,
                    dias: it.dias,
                  })),
                });
                await hist.registrarVencEmpresasAdmin(db, dniAdminEmpresas, {
                  cantidadItems: items.length,
                  colaDocId: colaRef.id,
                });
                stats.encolados++;
                log.info(
                  `+ Encolado VENC EMPRESAS ADMIN: ${dniAdminEmpresas} ` +
                    `(${items.length} items) -> ${colaRef.id}`
                );
              } catch (e) {
                stats.errores++;
                log.error(`No se pudo encolar aviso docs empresa admin: ${e.message}`);
              }
            }
          }
        }
      }
    }

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

module.exports = {
  start,
  stop,
  forzarRunOnce,
  // Exportado para tests / debugging.
  calcularDiasRestantes,
};
