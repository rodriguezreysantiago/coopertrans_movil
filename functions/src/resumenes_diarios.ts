// =============================================================================
// RESÚMENES DIARIOS — 4 crons que corren 8 AM ART
// =============================================================================
// Extraído de index.ts el 2026-05-18 (split del archivo de 6884 LOC).
//
// Los 4 resúmenes:
//   - resumenBotDiario              → al admin (caídas del bot ult 24h)
//   - resumenDriftsAsignacionesDiario → al admin (chofer físico ≠ asignado)
//   - resumenExcesosJornadaDiario   → al jefe Seg e Higiene (vigilador v2)
//   - resumenConductaManejoDiario   → al jefe Seg e Higiene (Sitrack + Volvo
//                                      AEBS/ESP + sobrevelocidad cartográfica)
//
// Todos comparten:
//   - Schedule 08:00 ART (con sus respectivos timeouts/memoria).
//   - Idempotencia ATOMICA con `adquirirIdempotenciaDiaria` (lock en
//     AVISOS_AUTOMATICOS_HISTORICO).
//   - TTL en COLA_WHATSAPP = 24h (TTL_RESUMEN_DIARIO_MIN) — si el bot
//     está caído > 24h se descarta el resumen del día (mejor silencio
//     que info stale).
//   - Lock liberable en `finally` si la encolada falla (auditoria
//     2026-05-18) — sino el resumen del día NO se reintenta.

import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db, BANNER_TESTING } from "./setup";
import {
  adquirirIdempotenciaDiaria,
  buscarAsignacionEnFecha,
  cargarAsignacionesPorPatentes,
  MANTENIMIENTO_DESTINATARIO_DNI,
  obtenerDestinatarioDni,
  SEG_HIGIENE_DESTINATARIO_DNI,
  TIPOS_PELIGROSOS_SITRACK,
  TTL_RESUMEN_DIARIO_MIN,
} from "./index";
import { expiraEnMin, formatFechaArg, formatHoraArg, primerNombre } from "./helpers";
import * as jornadasV3Batch from "./jornadas_v3_batch";
import { cargarExcluidos } from "./excluidos";
import { estaCanalPausado } from "./canales_pausados";

// ============================================================================
// resumenBotDiario — resumen consolidado de eventos del bot (8 AM diario)
// ============================================================================
//
// Lee `BOT_EVENTOS` de las últimas 24h y arma un resumen con caídas y
// recuperaciones del bot. Lo manda al admin (Santiago) por WhatsApp.
// Si NO hubo eventos, NO se manda nada (silencio = todo OK).
//
// Reemplaza el aviso inmediato del watchdog (decisión 2026-05-08): mandar
// alerta cuando se detecta la caída quedaba viejo (por el cron cada 15
// min, tarda en detectar; cuando llega al user puede haber pasado horas
// y ya recuperó). Mejor consolidar al día siguiente.

/** Un evento del watchdog del bot (caída / recuperación / otro). */
export interface BotEvento {
  tipo: string;
  detectadoEnMs: number;
  pcId: string;
  minutosSinHeartbeat?: number | string;
  duracionMin?: number;
}

export interface ResumenBotResult {
  mensaje: string;
  totalCaidas: number;
  totalRecuperaciones: number;
  minutosCaidoTotal: number;
}

/**
 * Construye el resumen diario del bot (caídas / recuperaciones de las
 * últimas 24h) para el admin. PURA — separada de `resumenBotDiario` para
 * testear el formato sin Firestore. Si `eventos` está vacío devuelve el
 * mensaje "todo OK" (decisión Santiago: silencio = ambiguo).
 */
export function construirResumenBot(
  eventos: BotEvento[],
  ahoraMs: number,
): ResumenBotResult {
  if (eventos.length === 0) {
    const fechaTxt = formatFechaArg(ahoraMs);
    return {
      mensaje:
        `🤖 *Resumen del bot — ${fechaTxt}*\n\n` +
        "✅ Sin caídas ni eventos en las últimas 24 h.\n\n" +
        BANNER_TESTING +
        "_Si dejaras de recibir este resumen a las 8 AM, " +
        "verificá que la Cloud Function `resumenBotDiario` esté activa._",
      totalCaidas: 0,
      totalRecuperaciones: 0,
      minutosCaidoTotal: 0,
    };
  }

  const lineas: string[] = [];
  let totalCaidas = 0;
  let totalRecuperaciones = 0;
  let minutosCaidoTotal = 0;

  for (const e of eventos) {
    const horaTxt = formatHoraArg(e.detectadoEnMs);
    const fechaTxt = formatFechaArg(e.detectadoEnMs);
    const pcId = e.pcId || "?";
    if (e.tipo === "caida") {
      totalCaidas++;
      const minSinHb = e.minutosSinHeartbeat ?? "?";
      lineas.push(
        `🔴 *Caída detectada* — ${fechaTxt} ${horaTxt} (PC \`${pcId}\`, ` +
        `${minSinHb} min sin heartbeat al detectar)`
      );
    } else if (e.tipo === "recuperado") {
      totalRecuperaciones++;
      const dur = typeof e.duracionMin === "number" ? e.duracionMin : null;
      if (dur !== null) minutosCaidoTotal += dur;
      const durTxt = dur !== null ? `${dur} min` : "?";
      lineas.push(
        `🟢 *Recuperado* — ${fechaTxt} ${horaTxt} (PC \`${pcId}\`, ` +
        `caído ~${durTxt})`
      );
    } else {
      lineas.push(`• ${e.tipo} ${fechaTxt} ${horaTxt}`);
    }
  }

  const titulo =
    totalCaidas === 0 && totalRecuperaciones > 0 ?
      "🤖 *Resumen del bot — recuperaciones de caídas previas*" :
      totalCaidas > 0 ?
        `🤖 *Resumen del bot — ${totalCaidas} ` +
        `caída${totalCaidas !== 1 ? "s" : ""} en últimas 24h*` :
        "🤖 *Resumen del bot — eventos del día*";

  const subtotal = minutosCaidoTotal > 0 ?
    `\n\nTiempo total caído estimado: ${minutosCaidoTotal} min.` :
    "";

  const mensaje =
    titulo + "\n\n" +
    lineas.join("\n") +
    subtotal + "\n\n" +
    BANNER_TESTING +
    "_Si hubo caídas que no detectaste, verificá el servicio (NSSM " +
    "del bot) en la PC correspondiente._";

  return { mensaje, totalCaidas, totalRecuperaciones, minutosCaidoTotal };
}

export const resumenBotDiario = onSchedule(
  {
    schedule: "0 8 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    logger.info("[resumenBotDiario] iniciando");

    // M9 — pausa por canal. Si el admin pausó esta categoría (vacaciones,
    // testing), salteamos el envío sin consumir el lock de idempotencia
    // para que mañana el cron del día siguiente reintente normal.
    if (await estaCanalPausado("mantenimientoBot")) {
      logger.info("[resumenBotDiario] canal pausado, skip");
      return;
    }

    // Idempotencia diaria ATOMICA (auditoria 2026-05-17): el patron viejo
    // era get + skip + set al final, que tenia race con retry de GCP
    // entre el get y el set → mensaje duplicado. Ahora `create()` es
    // atomico: si ya existe tira ALREADY_EXISTS y el helper devuelve false.
    //
    // El docId de idempotencia usa el DNI RESUELTO (desde Firestore o
    // hardcoded) — si el admin cambia el destinatario, el cron del día
    // siguiente va a otro doc → no duplica al nuevo ni re-envía al viejo.
    const adminDni = await obtenerDestinatarioDni(
      "mantenimientoBot", MANTENIMIENTO_DESTINATARIO_DNI,
    );
    const hoyKey = formatFechaArg(Date.now()).replace(/\//g, "-");
    const histRef = db
      .collection("AVISOS_AUTOMATICOS_HISTORICO")
      .doc(`bot_resumen_${hoyKey}_${adminDni}`);
    if (!(await adquirirIdempotenciaDiaria(histRef, "bot_resumen_diario"))) {
      logger.info("[resumenBotDiario] ya enviado hoy, skip");
      return;
    }
    // ALTO (auditoria 2026-05-18): si la encolada a COLA_WHATSAPP falla
    // mas abajo (Firestore down, quota, etc), sin try/finally el lock
    // queda tomado y el resumen del dia NO se reintenta → Santiago no
    // recibe el resumen y solo se entera al notar la falta.
    let exitoCron = false;
    try {

      // Eventos de las últimas 24h.
      const desde = Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);
      const evSnap = await db
        .collection("BOT_EVENTOS")
        .where("detectadoEn", ">=", desde)
        .orderBy("detectadoEn", "asc")
        .get();

      // Lookup destinatario (DNI ya resuelto arriba para idempotencia).
      const empSnap = await db.collection("EMPLEADOS").doc(adminDni).get();
      const tel = empSnap.exists ?
        (empSnap.data()?.TELEFONO ?? "").toString().trim() :
        "";
      if (!tel) {
        logger.error("[resumenBotDiario] admin sin TELEFONO", {
          adminDni,
        });
        return;
      }

      // Normalizar eventos + construir mensaje (PURO, testeable).
      // Sin eventos: la pura devuelve "todo OK" igual (decisión Santiago
      // 2026-05-09: silencio = ambiguo, un mensaje confirma que el cron
      // corrió y el bot estuvo sano las últimas 24h).
      const eventos: BotEvento[] = [];
      for (const doc of evSnap.docs) {
        const d = doc.data();
        const detectadoEn = d.detectadoEn as Timestamp | undefined;
        if (!detectadoEn) continue;
        eventos.push({
          tipo: String(d.tipo ?? ""),
          detectadoEnMs: detectadoEn.toMillis(),
          pcId: (d.pcId ?? "?").toString(),
          minutosSinHeartbeat: d.minutosSinHeartbeat,
          duracionMin: typeof d.duracionMin === "number" ?
            d.duracionMin :
            undefined,
        });
      }

      const r = construirResumenBot(eventos, Date.now());

      const colaRef = await db.collection("COLA_WHATSAPP").add({
        telefono: tel,
        mensaje: r.mensaje,
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
        expira_en: expiraEnMin(TTL_RESUMEN_DIARIO_MIN),
        enviado_en: null,
        error: null,
        intentos: 0,
        origen: "cron_bot_resumen_diario",
        destinatario_coleccion: "EMPLEADOS",
        destinatario_id: adminDni,
        campo_base: "BOT_RESUMEN_DIARIO",
        admin_dni: "BOT",
        admin_nombre: "Bot watchdog",
      });

      // Update metadata sobre el lock que ya tomamos al inicio.
      await histRef.update({
        cantidad_eventos: eventos.length,
        cantidad_caidas: r.totalCaidas,
        cantidad_recuperaciones: r.totalRecuperaciones,
        minutos_caido_total: r.minutosCaidoTotal,
        cola_doc_id: colaRef.id,
      });

      logger.info("[resumenBotDiario] OK", {
        eventos: eventos.length,
        caidas: r.totalCaidas,
        recuperaciones: r.totalRecuperaciones,
        minutosCaidoTotal: r.minutosCaidoTotal,
        colaDocId: colaRef.id,
      });
      exitoCron = true;
    } finally {
      if (!exitoCron) {
        // Liberar el lock para que el proximo run intente de nuevo.
        // Sin esto, una falla a mitad-cron dejaba el lock tomado y el
        // resumen no se reenviaba hasta el dia siguiente.
        await histRef.delete().catch(() => {
          logger.warn("[resumenBotDiario] no pude liberar lock tras fallo");
        });
      }
    }
  }
);


// ============================================================================
// resumenDriftsAsignacionesDiario
// ============================================================================
//
// Cron L-V 19:00 ART que arma un resumen de los tractores con drift
// detectado (chofer físico vía iButton ≠ chofer asignado en el sistema)
// y lo encola como WhatsApp para el admin (Santiago, definido en
// MANTENIMIENTO_DESTINATARIO_DNI).
//
// Source: SITRACK_POSICIONES filtrado por `drift_tipo != null/empty`.
// El campo lo popula el cron `sitrackPosicionPoller` cada 5 min con
// uno de tres valores: SIN_ASIGNACION, CHOFER_DISTINTO,
// CHOFER_NO_IDENTIFICADO.
//
// Si no hay drifts, no se encola mensaje (silent log). Si hay > 20
// drifts, agrupamos por tipo y solo listamos el detalle de los primeros
// 10 — para no saturar el WhatsApp del admin con un texto interminable.
//
// Idempotencia: hay gate atómico (`adquirirIdempotenciaDiaria` sobre un
// doc determinístico `drifts_<fecha>_<dni>` en AVISOS_AUTOMATICOS_HISTORICO).
// Si GCP re-dispara el cron el mismo día (retry / double trigger en la
// sliding window de las 8AM), el segundo tick salta en lugar de mandar el
// resumen 2 veces. El lock se libera si la encolada falla.

const ETIQUETAS_DRIFT: Record<string, string> = {
  CHOFER_DISTINTO: "Chofer distinto al asignado",
  SIN_ASIGNACION: "Sin asignación en sistema",
  CHOFER_NO_IDENTIFICADO: "Chofer no se identificó (iButton)",
};

/** Un drift chofer físico (iButton) ≠ asignado en sistema. */
export interface DriftAsignacion {
  patente: string;
  driftTipo: string;
  fisicoDni: string;
  fisicoApellido: string;
  asignadoDni: string;
  asignadoNombre: string;
}

/**
 * Construye el resumen diario de drifts de asignación para el admin.
 * PURA — separada de `resumenDriftsAsignacionesDiario` para testear el
 * formato sin Firestore. Sin drifts devuelve "todo OK". Con drifts lista
 * hasta 10 (el resto se cuenta en "Y N más").
 */
export function construirMensajeDrifts(
  drifts: DriftAsignacion[],
  fechaTxt: string,
): string {
  if (drifts.length === 0) {
    return (
      `📋 *Resumen drifts asignaciones — ${fechaTxt}*\n\n` +
      "✅ Sin drifts: todas las asignaciones coinciden con el " +
      "chofer físico de Sitrack.\n\n" +
      BANNER_TESTING +
      "_Bot-On — Coopertrans Móvil_"
    );
  }

  const conteoPorTipo: Record<string, number> = {};
  for (const x of drifts) {
    conteoPorTipo[x.driftTipo] = (conteoPorTipo[x.driftTipo] ?? 0) + 1;
  }
  const breakdown = Object.entries(conteoPorTipo)
    .map(([tipo, n]) => `${n}× ${ETIQUETAS_DRIFT[tipo] ?? tipo}`)
    .join(", ");

  const MAX_DETALLE = 10;
  const sorted = [...drifts].sort((a, b) => a.patente.localeCompare(b.patente));
  const aMostrar = sorted.slice(0, MAX_DETALLE);
  const restantes = sorted.length - aMostrar.length;

  const bloques = aMostrar.map((x) => {
    const fisico = x.fisicoDni ?
      (x.fisicoApellido ?
        `${x.fisicoApellido} (DNI ${x.fisicoDni})` :
        `DNI ${x.fisicoDni}`) :
      "(no se identificó)";
    const asignado = x.asignadoDni ?
      (x.asignadoNombre ?
        `${x.asignadoNombre} (DNI ${x.asignadoDni})` :
        `DNI ${x.asignadoDni}`) :
      "(sin asignación)";
    return `🚛 *${x.patente}*\n` +
      `   Sistema: ${asignado}\n` +
      `   Físico (iButton): ${fisico}\n` +
      `   ⚠️ ${ETIQUETAS_DRIFT[x.driftTipo] ?? x.driftTipo}`;
  });

  const cantidad = drifts.length;
  const cabecera =
    `🔍 *Drift de asignaciones — ${fechaTxt}*\n\n` +
    `${cantidad} ` +
    (cantidad === 1 ? "inconsistencia" : "inconsistencias") +
    ` chofer físico vs sistema (${breakdown}):\n\n`;
  const cola = restantes > 0 ?
    `\n\n_Y ${restantes} más. Resolvé desde Personal → ficha del chofer._` :
    "\n\n_Resolvé desde Personal → ficha del chofer._";

  return (
    cabecera +
    bloques.join("\n\n") +
    cola +
    "\n\n" +
    BANNER_TESTING +
    "_Bot-On — Coopertrans Móvil_"
  );
}

export const resumenDriftsAsignacionesDiario = onSchedule(
  {
    // 8:00 AM ART todos los días — Vecchi prefiere los resúmenes a la
    // mañana siguiente (con el bot ya arrancado y el admin en la
    // oficina) en lugar de la noche del día anterior.
    schedule: "0 8 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    logger.info("[resumenDriftsAsignacionesDiario] iniciando");

    // M9 — pausa por canal (ver resumenBotDiario).
    if (await estaCanalPausado("driftsAsignaciones")) {
      logger.info("[resumenDriftsAsignacionesDiario] canal pausado, skip");
      return;
    }

    // Idempotencia diaria. Si GCP re-dispara el cron (retry, double
    // trigger en la sliding window de las 8AM), saltamos en lugar de
    // mandar el mismo resumen 2 veces a Santiago. Antes faltaba este
    // gate y los 3 crons que corren a las 8:00 podian generar mensajes
    // duplicados ante cualquier reintento.
    const adminDni = await obtenerDestinatarioDni(
      "driftsAsignaciones", MANTENIMIENTO_DESTINATARIO_DNI,
    );
    const hoyKey = formatFechaArg(Date.now()).replace(/\//g, "-");
    const histRef = db
      .collection("AVISOS_AUTOMATICOS_HISTORICO")
      .doc(`drifts_${hoyKey}_${adminDni}`);
    if (!(await adquirirIdempotenciaDiaria(histRef, "drifts_asignaciones"))) {
      logger.info("[resumenDriftsAsignacionesDiario] ya enviado hoy, skip");
      return;
    }
    // Liberar lock si la encolada falla (auditoria 2026-05-18).
    let exitoCron = false;
    try {

      // ─── Leer drifts actuales ──────────────────────────────────────
      // Filtramos por drift_tipo != null en código (Firestore no tiene
      // operador "IS NOT NULL" — `where("drift_tipo", "!=", null)` no
      // matchea docs sin el campo). Levantamos toda la colección (~55
      // docs, batch única) y filtramos. .limit(5000) defensivo: la
      // colección tiene 1 doc por patente, no debería crecer mucho.
      const excluidos = await cargarExcluidos(db);
      const snap = await db.collection("SITRACK_POSICIONES").limit(5000).get();
      // Audit 2026-05-24: aviso si nos acercamos al límite — flota actual
      // ~55 patentes, muy lejos del cap 5000. Si algún día crece y este
      // log dispara, paginar con cursor antes de quemar memoria.
      if (snap.size >= 4500) {
        logger.warn(
          "[resumenDriftsAsignacionesDiario] SITRACK_POSICIONES cerca del límite 5000",
          { size: snap.size },
        );
      }
      const drifts: DriftAsignacion[] = snap.docs
        .map((d) => ({ patente: d.id, data: d.data() }))
        .filter((x) => {
          // Skip patentes excluidas (tanques + tractores combustibles).
          if (excluidos.patentes.has(x.patente.toUpperCase())) return false;
          // Skip si el chofer fisico es excluido (raro pero defensivo
          // — un chofer combustibles manejando un tractor normal).
          const driverDni = (x.data.driver_dni ?? "").toString().trim();
          if (driverDni && excluidos.dnis.has(driverDni)) return false;
          const tipo = (x.data.drift_tipo ?? "").toString();
          return tipo.length > 0;
        })
        .map((x) => ({
          patente: x.patente,
          driftTipo: (x.data.drift_tipo ?? "").toString(),
          fisicoDni: (x.data.driver_dni ?? "").toString(),
          fisicoApellido: (x.data.driver_apellido ?? "").toString(),
          asignadoDni: (x.data.asignacion_dni ?? "").toString(),
          asignadoNombre: (x.data.asignacion_nombre ?? "").toString(),
        }));

      // ─── Lookup teléfono del admin (DNI ya resuelto arriba) ──────
      const empSnap = await db.collection("EMPLEADOS").doc(adminDni).get();
      const tel = empSnap.exists ?
        (empSnap.data()?.TELEFONO ?? "").toString().trim() :
        "";
      if (!tel) {
        logger.error(
          "[resumenDriftsAsignacionesDiario] admin sin TELEFONO, no se puede notificar",
          { adminDni, driftsCount: drifts.length }
        );
        return;
      }

      // ─── Armar mensaje ─────────────────────────────────────────────
      const fechaTxt = formatFechaArg(Date.now());

      // Sin drifts: mandamos "todo OK" igual (decisión Santiago
      // 2026-05-09: silencio = ambiguo, un mensaje confirma que el cron
      // corrió y todas las asignaciones están alineadas con el chofer
      // físico que reporta Sitrack).
      if (drifts.length === 0) {
        const mensajeOk = construirMensajeDrifts(drifts, fechaTxt);
        await db.collection("COLA_WHATSAPP").add({
          telefono: tel,
          mensaje: mensajeOk,
          estado: "PENDIENTE",
          encolado_en: FieldValue.serverTimestamp(),
          expira_en: expiraEnMin(TTL_RESUMEN_DIARIO_MIN),
          enviado_en: null,
          error: null,
          intentos: 0,
          origen: "resumen_drifts_asignaciones",
          destinatario_coleccion: "EMPLEADOS",
          destinatario_id: adminDni,
          campo_base: "DRIFTS_ASIGNACIONES_DIARIO",
          admin_dni: "BOT",
          admin_nombre: "Bot resumen diario",
        });
        logger.info("[resumenDriftsAsignacionesDiario] OK (sin drifts)");
        exitoCron = true;
        return;
      }

      // Construcción del mensaje (PURA, testeable sin Firestore).
      const cantidad = drifts.length;
      const mensaje = construirMensajeDrifts(drifts, fechaTxt);

      // ─── Encolar en COLA_WHATSAPP ──────────────────────────────────
      await db.collection("COLA_WHATSAPP").add({
        telefono: tel,
        mensaje,
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
        expira_en: expiraEnMin(TTL_RESUMEN_DIARIO_MIN),
        enviado_en: null,
        error: null,
        intentos: 0,
        origen: "drift_diario",
        destinatario_coleccion: "EMPLEADOS",
        destinatario_id: adminDni,
        campo_base: "DRIFT_ASIGNACIONES",
        admin_dni: "BOT",
        admin_nombre: "Cron resumen drifts",
      });

      // Marcar como enviado hoy (idempotencia — bloquea retries de GCP).
      // Update metadata sobre el lock que ya tomamos al inicio.
      await histRef.update({
        drifts_count: cantidad,
      });

      logger.info("[resumenDriftsAsignacionesDiario] encolado", {
        adminDni,
        driftsCount: cantidad,
        mostrados: Math.min(cantidad, 10),
        restantes: Math.max(0, cantidad - 10),
      });
      exitoCron = true;
    } finally {
      if (!exitoCron) {
        await histRef.delete().catch(() => {
          logger.warn(
            "[resumenDriftsAsignacionesDiario] no pude liberar lock tras fallo",
          );
        });
      }
    }
  }
);


// ============================================================================
// resumenExcesosJornadaDiario — al jefe Seg e Higiene (Molina)
// ============================================================================
//
// Cron diario 8 AM ART. Reporta jornadas LÓGICAS cerradas el día
// anterior con incidencias (bloque > 4h sin pausa, manejo post-cuota,
// circulación en veda nocturna 00:00 ART).
//
// La lógica vive en jornadas_v2.ts. Este cron es solo el wrapper que
// dispara la function exportada. Mismo destinatario que antes
// (Molina, DNI 34730329 vía env var ALERTAS_SEG_HIGIENE_DESTINATARIO_DNI).

export const resumenExcesosJornadaDiario = onSchedule(
  {
    schedule: "0 8 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    // M9 — pausa por canal.
    if (await estaCanalPausado("excesosJornada")) {
      logger.info("[resumenExcesosJornadaDiario] canal pausado, skip");
      return;
    }
    // Idempotencia diaria (gate compartido para evitar duplicados ante
    // retry de GCP). El destinatario real lo resuelve el modulo
    // jornadas_v2 — usamos un docId generico por dia.
    const hoyKey = formatFechaArg(Date.now()).replace(/\//g, "-");
    const histRef = db
      .collection("AVISOS_AUTOMATICOS_HISTORICO")
      .doc(`excesos_jornada_${hoyKey}`);
    if (!(await adquirirIdempotenciaDiaria(histRef, "excesos_jornada"))) {
      logger.info("[resumenExcesosJornadaDiario] ya enviado hoy, skip");
      return;
    }
    // Liberar lock si la encolada del modulo jornadas_v2 falla (auditoria
    // 2026-05-18) — sino Molina no recibe el resumen del dia.
    let exitoCron = false;
    try {
      // Paso 4 — fuente oficial v3: el resumen a Molina pasa a calcularse del
      // registro a posteriori (REGISTRO_JORNADAS, preciso) en vez de los flags
      // del tick en vivo del v2. El v2 (`armarResumenJornadasDiario`) queda como
      // fallback de rollback (revertir = volver a llamarlo acá).
      await jornadasV3Batch.armarResumenJornadasV3Diario();
      exitoCron = true;
    } finally {
      if (!exitoCron) {
        await histRef.delete().catch(() => {
          logger.warn(
            "[resumenExcesosJornadaDiario] no pude liberar lock tras fallo",
          );
        });
      }
    }
  }
);

// ============================================================================
// resumenConductaManejoDiario — Conducta de manejo al jefe Seg e Higiene
// ============================================================================
//
// Cron diario 8 AM ART. Combina eventos peligrosos del día anterior
// desde SITRACK (fuente primaria — lo que YPF audita en su tablero ICM)
// + VOLVO (solo AEBS y ESP, que Sitrack no cubre por hardware). Agrupa
// por par chofer+unidad para que Molina pueda dialogar con el responsable.
//
// REEMPLAZA al "Resumen Alertas Volvo HIGH" que vivía en whatsapp-bot/src/cron.js
// — se eliminó el 2026-05-15 porque mandaba duplicado lo que ya llegaba vía
// Sitrack (UNSAFE_LANE_CHANGE, LKS, LCS, DISTANCE_ALERT). La info Volvo
// queda restringida a los eventos únicos del sistema Volvo (AEBS = frenado
// automático de emergencia, ESP = control de estabilidad).
//
// Si no hubo eventos: igual manda "Sin eventos" — con 60 camiones 0 eventos
// es raro, el silencio sería ambiguo, y el mensaje confirma que el cron corrió.
//
// Resolución de chofer (cuando Sitrack no trae driver_dni porque el chofer
// no se logueó):
//   1. Si el evento trae driver_dni → ese.
//   2. Si no → buscar en ASIGNACIONES_VEHICULO la asignación vigente para
//      esa patente en el timestamp del evento. Si existe, atribuir al chofer
//      asignado y marcar el bloque con asterisco (*) en el mensaje.
//   3. Si no hay asignación cubriendo el momento → "CHOFER NO IDENTIFICADO"
//      con la patente solamente.

// Tipos VOLVO_ALERTAS conservados en el resumen a Molina.
// El resto ya está cubierto por Sitrack (salida carril, distancia, etc).
// AEBS y ESP son sistemas internos de Volvo que Sitrack no ve.
const TIPOS_VOLVO_CONSERVADOS_SEG_HIGIENE = new Set<string>(["AEBS", "ESP"]);

/** Un grupo (chofer+patente) con sus eventos de conducta del día. */
export interface GrupoConducta {
  keyChoferDni: string;
  patente: string;
  atribuido: boolean;
  sitrack: Map<string, number>;
  volvo: Map<string, number>;
  maxSobreLimite: { sobre: number; gpsSpeed: number; cartLimit: number } | null;
}

/**
 * Construye el resumen diario de conducta de manejo para Molina (Seg e
 * Higiene). PURA — separada de `resumenConductaManejoDiario` para testear
 * el formato sin Firestore. Ordena (identificados alfabético → no
 * identificados), mergea Sitrack + Volvo por chofer/unidad y resalta la
 * peor sobrevelocidad. Sin grupos devuelve "sin eventos".
 */
export function construirMensajeConducta(
  grupos: GrupoConducta[],
  nombrePorDni: Map<string, string>,
  saludo: string,
  fmtFecha: string,
): string {
  if (grupos.length === 0) {
    return (
      `${saludo},\n\n` +
      `🚧 *Conducta de manejo — ${fmtFecha}*\n\n` +
      "✅ Sin eventos: ningún tractor registró eventos de conducta " +
      "peligrosa ayer.\n\n" +
      BANNER_TESTING +
      "_Bot-On — Coopertrans Móvil_"
    );
  }

  // Ordenar: identificados (alfabético por nombre) → no identificados.
  const gruposOrdenados = [...grupos].sort((a, b) => {
    const aIsId = a.keyChoferDni !== "NO_ID";
    const bIsId = b.keyChoferDni !== "NO_ID";
    if (aIsId && !bIsId) return -1;
    if (!aIsId && bIsId) return 1;
    if (!aIsId && !bIsId) return a.patente.localeCompare(b.patente);
    const an = (nombrePorDni.get(a.keyChoferDni) || "").toUpperCase();
    const bn = (nombrePorDni.get(b.keyChoferDni) || "").toUpperCase();
    return an.localeCompare(bn);
  });

  // Sitrack ya viene con event_name en español; Volvo llega como sigla.
  const ETIQUETAS_LEGIBLES: Record<string, string> = {
    AEBS: "Frenado automático de emergencia",
    ESP: "Control de estabilidad",
  };
  const traducir = (tipo: string): string =>
    ETIQUETAS_LEGIBLES[tipo] ?? tipo;

  let huboAtribuidos = false;
  const bloques = gruposOrdenados.map((g) => {
    const lineas: string[] = [];
    let titulo: string;
    if (g.keyChoferDni === "NO_ID") {
      titulo = `*CHOFER NO IDENTIFICADO* · ${g.patente}`;
    } else {
      const nombre = nombrePorDni.get(g.keyChoferDni) ||
        `DNI ${g.keyChoferDni}`;
      const marca = g.atribuido ? " *" : "";
      titulo = `*${nombre}*${marca} · ${g.patente}`;
      if (g.atribuido) huboAtribuidos = true;
    }
    lineas.push(titulo);
    // Merge Sitrack + Volvo (para Molina es info de seguridad, no importa
    // de qué sistema vino).
    const todosLosEventos = new Map<string, number>();
    for (const [t, c] of g.sitrack.entries()) {
      const etiqueta = traducir(t);
      todosLosEventos.set(etiqueta, (todosLosEventos.get(etiqueta) ?? 0) + c);
    }
    for (const [t, c] of g.volvo.entries()) {
      const etiqueta = traducir(t);
      todosLosEventos.set(etiqueta, (todosLosEventos.get(etiqueta) ?? 0) + c);
    }
    const ordTipos = [...todosLosEventos.entries()].sort((x, y) => y[1] - x[1]);
    for (const [t, c] of ordTipos) {
      lineas.push(`  • ${t}: ${c}`);
    }
    if (g.maxSobreLimite !== null) {
      const m = g.maxSobreLimite;
      lineas.push(
        `    ↳ Peor exceso: ${m.gpsSpeed.toFixed(0)} km/h ` +
        `(límite ${m.cartLimit.toFixed(0)} km/h, +${m.sobre.toFixed(0)})`
      );
    }
    return lineas.join("\n");
  });

  const cantGrupos = grupos.length;
  let mensaje =
    `${saludo},\n\n` +
    `🚧 *Conducta de manejo — ${fmtFecha}*\n\n` +
    `${cantGrupos} chofer${cantGrupos === 1 ? "" : "es"}/` +
    `unidad${cantGrupos === 1 ? "" : "es"} con eventos:\n\n` +
    bloques.join("\n\n") +
    "\n\n";
  if (huboAtribuidos) {
    mensaje +=
      "_* atribuido por asignación: el evento no traía login activo, " +
      "se asignó al chofer que tenía la unidad en ese momento._\n\n";
  }
  mensaje += BANNER_TESTING + "_Bot-On — Coopertrans Móvil_";
  return mensaje;
}

export const resumenConductaManejoDiario = onSchedule(
  {
    schedule: "0 8 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async () => {
    logger.info("[resumenConductaManejoDiario] iniciando");

    // M9 — pausa por canal.
    if (await estaCanalPausado("conductaManejo")) {
      logger.info("[resumenConductaManejoDiario] canal pausado, skip");
      return;
    }

    // Idempotencia diaria — si GCP re-dispara el cron Molina recibe el
    // mismo resumen 2 veces. Lock ATOMICO con `adquirirIdempotenciaDiaria`
    // — el create() es atomico, no hay ventana de race entre get y set.
    const hoyKey = formatFechaArg(Date.now()).replace(/\//g, "-");
    const histRefIdem = db
      .collection("AVISOS_AUTOMATICOS_HISTORICO")
      .doc(`conducta_manejo_${hoyKey}`);
    if (!(await adquirirIdempotenciaDiaria(histRefIdem, "conducta_manejo_diario"))) {
      logger.info("[resumenConductaManejoDiario] ya enviado hoy, skip");
      return;
    }
    // ALTO (auditoria 2026-05-18): liberar lock si la encolada falla,
    // sino Molina no recibe el resumen del dia.
    let exitoCron = false;
    try {
      // Cargar excluidos UNA vez (cacheado 10 min). Skip eventos de los
      // 3 choferes/3 tanques de combustibles líquidos (ver excluidos.ts).
      const excluidos = await cargarExcluidos(db);

      // ─── Rango: día calendario AYER en ART ────────────────────────
      const ahora = new Date();
      const fechaArtAyer = new Intl.DateTimeFormat("en-CA", {
        timeZone: "America/Argentina/Buenos_Aires",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
      }).format(new Date(ahora.getTime() - 24 * 60 * 60 * 1000));
      const fechaArtHoy = new Intl.DateTimeFormat("en-CA", {
        timeZone: "America/Argentina/Buenos_Aires",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
      }).format(ahora);
      // ART = UTC-3 todo el año (no tiene DST). Construimos el offset
      // explícito para que el rango sea independiente del TZ del runtime.
      const desdeMs = Date.parse(`${fechaArtAyer}T00:00:00-03:00`);
      const hastaMs = Date.parse(`${fechaArtHoy}T00:00:00-03:00`);

    interface EventoConducta {
      patente: string;
      driverDni: string;
      tsMs: number;
      tipoLabel: string;
      origen: "sitrack" | "volvo";
      // Si es evento de sobrevelocidad (event_id 8/9) y trae los campos
      // cartográficos, calculamos el exceso real (gpsSpeed - cartLimit).
      // Sirve para mostrar a Molina la peor sobrevelocidad del día por chofer.
      sobreLimiteKmh?: number;
      gpsSpeed?: number;
      cartLimit?: number;
    }
    const eventos: EventoConducta[] = [];

    // ─── SITRACK_EVENTOS del día anterior ─────────────────────────
    // Limit defensivo 50000: SITRACK ingesta ~1400 tipos de evento × 56
    // patentes ≈ varios miles/día en pico. 50K nos da 10x de margen
    // (jamás vimos > 5000/día). Si se cruza, loggeamos warn — alerta
    // temprana de algo raro (Sitrack mandando ruido masivo).
    // Auditoría 2026-05-18.
    const LIMIT_SITRACK_DIA = 50000;
    const sitrackSnap = await db
      .collection("SITRACK_EVENTOS")
      .where("report_date", ">=", Timestamp.fromMillis(desdeMs))
      .where("report_date", "<", Timestamp.fromMillis(hastaMs))
      .limit(LIMIT_SITRACK_DIA)
      .get();
    if (sitrackSnap.size >= LIMIT_SITRACK_DIA) {
      logger.warn(
        "[resumenConductaManejoDiario] SITRACK_EVENTOS query " +
        `alcanzó el limit (${LIMIT_SITRACK_DIA}). Datos del resumen ` +
        "pueden estar incompletos. Investigar volumen.",
      );
    }
    for (const doc of sitrackSnap.docs) {
      const d = doc.data();
      const eventId = d.event_id;
      if (
        typeof eventId !== "number" ||
        !TIPOS_PELIGROSOS_SITRACK.has(eventId)
      ) {
        continue;
      }
      const patente = (d.asset_id ?? "").toString().trim().toUpperCase();
      // Skip eventos excluidos (combustibles líquidos).
      if (excluidos.patentes.has(patente)) continue;
      const driverDniRaw = (d.driver_dni ?? "").toString().trim();
      if (driverDniRaw && excluidos.dnis.has(driverDniRaw)) continue;
      const ts = d.report_date as Timestamp | undefined;
      const tsMs = ts?.toMillis?.() ?? 0;
      // Sobrevelocidad detectada (event_id 8 = inicio, 9 = fin):
      // calcular exceso vs cartografía Sitrack (que ES la cartografía YPF).
      const gpsSpeed = typeof d.gps_speed === "number" ? d.gps_speed : null;
      const cartLimit = typeof d.cartography_limit_speed === "number" ?
        d.cartography_limit_speed :
        null;
      const sobreLimiteKmh =
        (eventId === 8 || eventId === 9) &&
        gpsSpeed !== null && cartLimit !== null && cartLimit > 0 ?
          Math.max(0, gpsSpeed - cartLimit) :
          undefined;
      eventos.push({
        patente,
        driverDni: (d.driver_dni ?? "").toString().trim(),
        tsMs,
        tipoLabel: (d.event_name ?? `Evento ${eventId}`).toString(),
        origen: "sitrack",
        sobreLimiteKmh,
        gpsSpeed: gpsSpeed ?? undefined,
        cartLimit: cartLimit ?? undefined,
      });
    }

    // ─── VOLVO_ALERTAS del día anterior (solo AEBS / ESP) ─────────
    // Limit defensivo 10000: Volvo genera ~50-200 alertas/día normales,
    // 10K nos da margen 50x. Mismo warn pattern.
    const LIMIT_VOLVO_DIA = 10000;
    const volvoSnap = await db
      .collection("VOLVO_ALERTAS")
      .where("creado_en", ">=", Timestamp.fromMillis(desdeMs))
      .where("creado_en", "<", Timestamp.fromMillis(hastaMs))
      .limit(LIMIT_VOLVO_DIA)
      .get();
    if (volvoSnap.size >= LIMIT_VOLVO_DIA) {
      logger.warn(
        "[resumenConductaManejoDiario] VOLVO_ALERTAS query alcanzó " +
        `el limit (${LIMIT_VOLVO_DIA}). Investigar volumen.`,
      );
    }
    for (const doc of volvoSnap.docs) {
      const d = doc.data();
      const tipo = (d.tipo ?? "").toString().toUpperCase();
      // Volvo a veces envuelve sub-eventos en `tipo=GENERIC` con
      // detalle_generic.triggerType o .type. Chequeamos ambos.
      const detalleGeneric = (d.detalle_generic ?? {}) as Record<string, unknown>;
      const subTipo = (
        detalleGeneric.triggerType ?? detalleGeneric.type ?? ""
      ).toString().toUpperCase();
      const tipoUsado = TIPOS_VOLVO_CONSERVADOS_SEG_HIGIENE.has(tipo) ?
        tipo :
        TIPOS_VOLVO_CONSERVADOS_SEG_HIGIENE.has(subTipo) ?
          subTipo :
          null;
      if (!tipoUsado) continue;
      const patente = (d.patente ?? "").toString().trim().toUpperCase();
      // Skip patentes excluidas (combustibles líquidos).
      if (excluidos.patentes.has(patente)) continue;
      const driverDniRaw = (d.chofer_dni ?? "").toString().trim();
      if (driverDniRaw && excluidos.dnis.has(driverDniRaw)) continue;
      const ts = d.creado_en as Timestamp | undefined;
      const tsMs = ts?.toMillis?.() ?? 0;
      eventos.push({
        patente,
        driverDni: (d.chofer_dni ?? "").toString().trim(),
        tsMs,
        tipoLabel: tipoUsado,
        origen: "volvo",
      });
    }

    // ─── Bulk load asignaciones para resolver choferes ─────────────
    const patentesSet = new Set<string>();
    for (const e of eventos) if (e.patente) patentesSet.add(e.patente);
    const asignaciones = await cargarAsignacionesPorPatentes([...patentesSet]);

    // ─── Resolver chofer + agrupar por (DNI, patente) ─────────────
    const grupos = new Map<string, GrupoConducta>();
    for (const e of eventos) {
      let dni = e.driverDni;
      let atribuidoPorAsig = false;
      if (!dni && e.patente && e.tsMs) {
        const a = buscarAsignacionEnFecha(
          asignaciones.get(e.patente),
          e.tsMs
        );
        if (a?.chofer_dni) {
          dni = a.chofer_dni;
          atribuidoPorAsig = true;
        }
      }
      const keyDni = dni || "NO_ID";
      const key = `${keyDni}|${e.patente || "—"}`;
      let g = grupos.get(key);
      if (!g) {
        g = {
          keyChoferDni: keyDni,
          patente: e.patente || "—",
          atribuido: atribuidoPorAsig,
          sitrack: new Map(),
          volvo: new Map(),
          maxSobreLimite: null,
        };
        grupos.set(key, g);
      } else if (!atribuidoPorAsig && keyDni !== "NO_ID") {
        // Si llega aunque sea 1 evento con login directo en este par
        // chofer+patente, el bloque deja de ser "atribuido".
        g.atribuido = false;
      }
      if (e.origen === "sitrack") {
        g.sitrack.set(e.tipoLabel, (g.sitrack.get(e.tipoLabel) ?? 0) + 1);
      } else {
        g.volvo.set(e.tipoLabel, (g.volvo.get(e.tipoLabel) ?? 0) + 1);
      }
      // Trackeamos la peor sobrevelocidad para mostrarla resaltada.
      if (
        e.sobreLimiteKmh !== undefined &&
        e.gpsSpeed !== undefined &&
        e.cartLimit !== undefined &&
        e.sobreLimiteKmh > 0 &&
        (g.maxSobreLimite === null ||
          e.sobreLimiteKmh > g.maxSobreLimite.sobre)
      ) {
        g.maxSobreLimite = {
          sobre: e.sobreLimiteKmh,
          gpsSpeed: e.gpsSpeed,
          cartLimit: e.cartLimit,
        };
      }
    }

    // ─── Lookup destinatario (Molina por default, override M5) ─────
    const seguridadDni = await obtenerDestinatarioDni(
      "conductaManejo", SEG_HIGIENE_DESTINATARIO_DNI,
    );
    const empSnap = await db
      .collection("EMPLEADOS")
      .doc(seguridadDni)
      .get();
    if (!empSnap.exists) {
      logger.error(
        "[resumenConductaManejoDiario] destinatario no existe",
        { dni: seguridadDni }
      );
      return;
    }
    const empData = empSnap.data() ?? {};
    const tel = (empData.TELEFONO ?? "").toString().trim();
    if (!tel || tel === "-") {
      logger.error(
        "[resumenConductaManejoDiario] destinatario sin TELEFONO",
        { dni: seguridadDni }
      );
      return;
    }
    const apodo = (empData.APODO ?? "").toString().trim();
    const nombreFull = (empData.NOMBRE ?? "").toString().trim();
    const saludoNombre = apodo || primerNombre(nombreFull) || "";
    const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";
    const fmtFecha = fechaArtAyer.split("-").reverse().join("/");

    // ─── Lookup nombres de choferes identificados ──────────────────
    // (la construcción del mensaje, incluido el caso "sin eventos", vive
    //  en `construirMensajeConducta` — pura, testeable.)
    // Fix M2 (auditoria 24/7 2026-05-18): antes era loop serial de
    // `db.collection("EMPLEADOS").doc(dni).get()` con `await` adentro
    // del for — N+1 queries (60 reads serializados con flota grande).
    // Ahora usa `getAll(...refs)` en una sola RPC. Misma cantidad de
    // documentos leidos pero 1 round-trip de red vs N.
    const dnis = new Set<string>();
    for (const g of grupos.values()) {
      if (g.keyChoferDni !== "NO_ID") dnis.add(g.keyChoferDni);
    }
    const nombrePorDni = new Map<string, string>();
    if (dnis.size > 0) {
      try {
        const refs = [...dnis].map(
          (dni) => db.collection("EMPLEADOS").doc(dni)
        );
        const snaps = await db.getAll(...refs);
        for (const s of snaps) {
          const n = s.exists ?
            (s.data()?.NOMBRE ?? "").toString().trim() :
            "";
          nombrePorDni.set(s.id, n);
        }
      } catch (e) {
        // Si falla el batch, fallback a strings vacios (no rompe el
        // resumen — solo aparece "DNI XXXX" en lugar de "Nombre").
        logger.warn(
          "[resumenConductaManejoDiario] getAll EMPLEADOS fallo",
          { error: (e as Error).message }
        );
        for (const dni of dnis) {
          nombrePorDni.set(dni, "");
        }
      }
    }

    // ─── Construcción del mensaje (PURA, testeable sin Firestore) ──
    const mensaje = construirMensajeConducta(
      [...grupos.values()], nombrePorDni, saludo, fmtFecha
    );

    await db.collection("COLA_WHATSAPP").add({
      telefono: tel,
      mensaje,
      estado: "PENDIENTE",
      encolado_en: FieldValue.serverTimestamp(),
      expira_en: expiraEnMin(TTL_RESUMEN_DIARIO_MIN),
      enviado_en: null,
      error: null,
      intentos: 0,
      origen: "resumen_conducta_manejo_diario",
      destinatario_coleccion: "EMPLEADOS",
      destinatario_id: seguridadDni,
      campo_base: "CONDUCTA_MANEJO_DIARIO",
      admin_dni: "BOT",
      admin_nombre: "Bot resumen conducta",
    });

    // Update metadata sobre el lock que ya tomamos al inicio.
    await histRefIdem.update({
      grupos: grupos.size,
      eventos: eventos.length,
    });

    logger.info("[resumenConductaManejoDiario] OK", {
      grupos: grupos.size,
      eventos: eventos.length,
      destinatario: SEG_HIGIENE_DESTINATARIO_DNI,
    });
    exitoCron = true;
    } finally {
      if (!exitoCron) {
        await histRefIdem.delete().catch(() => {
          logger.warn(
            "[resumenConductaManejoDiario] no pude liberar lock tras fallo",
          );
        });
      }
    }
  }
);
