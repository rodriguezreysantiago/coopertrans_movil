// =============================================================================
// MANTENIMIENTO — backup + bot health + wrappers vigilador jornada v2
// =============================================================================
// Extraído de index.ts el 2026-05-18 (split del archivo de 6884 LOC).
//
// Contiene crons de "salud y mantenimiento" del sistema:
//   - `backupFirestoreScheduled`     (domingo 06:00 ART) — export semanal a GCS
//   - `botHealthWatchdog`            (cada 15 min)       — detecta caídas del bot
//   - `vigiladorJornadaChofer`       (cada 5 min)        — wrapper a jornadas_v2
//   - `procesarSilenciadosExpirados` (cada 10 min)       — limpia silenciamientos
//
// Los dos primeros son cross-cutting de la plataforma. Los wrappers de
// vigilador son thin (delegan a jornadas_v2.ts) — están acá porque
// "vigilancia operativa" cae en la misma categoría de mantenimiento.

import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {
  DocumentData,
  DocumentReference,
  FieldValue,
  Timestamp,
} from "firebase-admin/firestore";
import { v1 as firestoreAdminV1 } from "@google-cloud/firestore";

import { db, BANNER_TESTING } from "./setup";
import { adquirirLockTick } from "./comun";
import * as jornadasV2 from "./jornadas_v2";
import { expiraEnMin, primerNombre } from "./helpers";
import {
  construirMensajeAlerta,
  enviarTelegram,
  evaluarAlertaExterna,
  incidenteDesdeDoc,
  incidenteHaciaDoc,
  sonIncidentesIguales,
  telegramBotToken,
  telegramChatId,
  UMBRAL_STALE_MIN,
} from "./bot_alerta_externa";

// ============================================================================
// backupFirestoreScheduled — backup automático semanal de Firestore
// ============================================================================
//
// Reemplazo cloud-side del script `scripts/backup_firestore.ps1` que era
// PC-bound (requería que Santiago ejecutara desde su Windows). Esta
// function corre en GCP, así que NO depende de ninguna PC encendida —
// mitiga el bus factor (riesgo #1 del proyecto).
//
// Schedule: domingos 06:00 ART (poco tráfico operativo). Frecuencia
// semanal alcanza para el tipo de uso de Vecchi (la flota se opera de
// L-V; los vencimientos cambian poco entre semanas). Si en el futuro se
// quiere diario, cambiar `schedule` por "0 6 * * *".
//
// Output: cada run crea un export en
// `gs://coopertrans-movil-backups/auto-{YYYY-MM-DD}_{HHMM}/` con todas
// las colecciones operativas (mismas que el script ps1 + VOLVO_SCORES_DIARIOS
// que se sumó después).
//
// Retención: NO se gestiona desde código — se setea Object Lifecycle del
// bucket vía gcloud (ver RUNBOOK sección "Backup automático"). Borra
// automáticamente exports > 30 días, gestionado por GCP, gratis.
//
// Setup operativo (one-time, vos lo corrés):
//   1. Crear bucket si no existe:
//      gcloud storage buckets create gs://coopertrans-movil-backups \
//        --project=coopertrans-movil --location=southamerica-east1 \
//        --uniform-bucket-level-access
//   2. IAM grants para la SA de Functions Gen2 (compute SA del proyecto):
//      gcloud projects add-iam-policy-binding coopertrans-movil \
//        --member="serviceAccount:808925655961-compute@developer.gserviceaccount.com" \
//        --role="roles/datastore.importExportAdmin"
//      gcloud storage buckets add-iam-policy-binding gs://coopertrans-movil-backups \
//        --member="serviceAccount:808925655961-compute@developer.gserviceaccount.com" \
//        --role="roles/storage.objectAdmin"
//   3. Lifecycle de retención (30 días) — ver comando completo en RUNBOOK
//      sección "Backup automático Firestore".
//   4. Deploy: firebase deploy --only functions:backupFirestoreScheduled
//
// Restauración (cuando un day pasa lo peor): ver RUNBOOK sección
// "Disaster recovery — restaurar Firestore desde backup".
export const backupFirestoreScheduled = onSchedule(
  {
    schedule: "0 6 * * 0",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 540,
    memory: "256MiB",
  },
  async () => {
    const projectId = process.env.GCLOUD_PROJECT || "coopertrans-movil";
    const bucketName = "coopertrans-movil-backups";

    // YYYY-MM-DD_HHMM en hora ART (Argentina). Lo lee Santiago al abrir
    // GCS Console — coherente con la regla del proyecto de NO mostrar UTC
    // al usuario. Construido manual con Intl.DateTimeFormat porque el
    // `toISOString()` nativo siempre devuelve UTC y Cloud Functions corre
    // en UTC por default.
    const ahora = new Date();
    const fmtFecha = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Argentina/Buenos_Aires",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    });
    const fmtHora = new Intl.DateTimeFormat("en-GB", {
      timeZone: "America/Argentina/Buenos_Aires",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    });
    const fechaTag = `${fmtFecha.format(ahora)}_${fmtHora.format(ahora).replace(":", "")}`;
    const outputUriPrefix = `gs://${bucketName}/auto-${fechaTag}`;

    // Mismas colecciones que scripts/backup_firestore.ps1 + VOLVO_SCORES_DIARIOS
    // que se sumó después de ese script. Si se agrega una colección nueva
    // operativa, sumarla acá Y al script ps1 (legacy de respaldo manual).
    // Auditoria 2026-05-18 (CRITICO): la lista hardcoded estaba
    // desactualizada — faltaban SITRACK_EVENTOS (base ICM YPF),
    // VIAJES_LOGISTICA, ADELANTOS_CHOFER, JORNADAS, EMPRESAS_LOGISTICA,
    // UBICACIONES_LOGISTICA, TARIFAS_LOGISTICA, ASIGNACIONES_ENGANCHE,
    // CUBIERTAS*, EMPRESAS_EMPLEADORAS, ICM_SEMANAL, BOT_EVENTOS,
    // BORRADORES_VIAJE, COUNTERS, META_AVISOS_NO_ID, ADELANTOS counter,
    // SITRACK_POSICIONES, BOT_SILENCIADOS_CHOFER. Si Firestore perdia
    // data, no habia recovery de la liquidacion/viajes/conducta.
    //
    // Se mantiene como lista explicita (no `collectionIds: []` que
    // exportaria todas) para tener control auditable + costo predecible.
    // Cualquier coleccion nueva debe sumarse aca.
    const collectionIds = [
      // Personal + Flota
      "EMPLEADOS",
      "VEHICULOS",
      "REVISIONES",
      "CHECKLISTS",
      "ASIGNACIONES_VEHICULO",
      "ASIGNACIONES_ENGANCHE",
      "EMPRESAS_EMPLEADORAS",
      // Telemetria + Volvo + Sitrack
      "TELEMETRIA_HISTORICO",
      "MANTENIMIENTOS_AVISADOS",
      "VOLVO_ALERTAS",
      "VOLVO_SCORES_DIARIOS",
      "SITRACK_POSICIONES",
      "SITRACK_EVENTOS",
      "JORNADAS",
      // Logistica + Viajes + Adelantos
      "EMPRESAS_LOGISTICA",
      "UBICACIONES_LOGISTICA",
      "TARIFAS_LOGISTICA",
      "VIAJES_LOGISTICA",
      "ADELANTOS_CHOFER",
      "BORRADORES_VIAJE",
      // Gomeria
      "CUBIERTAS_MARCAS",
      "CUBIERTAS_MODELOS",
      "CUBIERTAS",
      "CUBIERTAS_INSTALADAS",
      "CUBIERTAS_RECAPADOS",
      "CUBIERTAS_CONTROLES",
      "CUBIERTAS_POSICIONES_ACTIVAS",
      "CUBIERTAS_ACTIVAS",
      "CUBIERTAS_PROVEEDORES",
      // Bot WhatsApp + control + logs
      "COLA_WHATSAPP",
      "AVISOS_AUTOMATICOS_HISTORICO",
      "RESPUESTAS_BOT_AMBIGUAS",
      "BOT_HEALTH",
      "BOT_CONTROL",
      "BOT_EVENTOS",
      "BOT_SILENCIADOS_CHOFER",
      "META_AVISOS_NO_ID",
      "META_ALERTAS_VOLVO_NOTIFICADAS",
      "META_LOCKS",
      "CUBIERTAS_KM_PENDIENTES",
      "LOGIN_ATTEMPTS_IP",
      "PASS_CHANGE_ATTEMPTS",
      // Auditoria + sistema
      "AUDITORIA_ACCIONES",
      "LOGIN_ATTEMPTS",
      "COUNTERS",
      "STATS",
      "META",
    ];

    logger.info("[backupFirestoreScheduled] inicio", {
      outputUriPrefix,
      collectionIds,
    });

    const adminClient = new firestoreAdminV1.FirestoreAdminClient();
    const databaseName = adminClient.databasePath(projectId, "(default)");

    try {
      const [operation] = await adminClient.exportDocuments({
        name: databaseName,
        outputUriPrefix,
        collectionIds,
      });
      // exportDocuments devuelve una long-running operation: el export
      // real corre en background en GCP. La function termina apenas se
      // recibe el handle (no esperamos a que termine — sería tirar plata
      // de Cloud Functions). El estado final queda visible en:
      //   gcloud firestore operations list --project=coopertrans-movil
      logger.info("[backupFirestoreScheduled] export iniciado en background", {
        operationName: operation.name,
      });
    } catch (err) {
      // Concurrencia: si el export anterior aun no termino (poco probable
      // con schedule semanal, pero defensivo si Firestore quedo lento),
      // GCP rechaza con FAILED_PRECONDITION o RESOURCE_EXHAUSTED.
      // Auditoria 2026-05-18: skipear silencioso en lugar de fallar el
      // run — el proximo schedule lo intentara de nuevo.
      const code = (err as { code?: number | string }).code;
      const msg = (err as Error).message || "";
      const yaEnCurso =
        code === 9 || // FAILED_PRECONDITION
        code === 8 || // RESOURCE_EXHAUSTED
        msg.includes("FAILED_PRECONDITION") ||
        msg.includes("RESOURCE_EXHAUSTED") ||
        msg.includes("already") ||
        msg.includes("in progress");
      if (yaEnCurso) {
        logger.warn("[backupFirestoreScheduled] export anterior en curso, skip", {
          code,
          message: msg,
        });
        return;
      }
      logger.error("[backupFirestoreScheduled] export FALLÓ", {
        error: msg,
        stack: (err as Error).stack,
      });
      // Re-throw para que GCP marque el run como FAILED. Cloud Monitoring
      // lo ve como error rate up, podés enganchar una alerta si querés.
      throw err;
    }
  }
);

// ============================================================================
// botHealthWatchdog — registra caídas y recuperaciones del bot
// ============================================================================
//
// El bot Node.js corre en la PC de Santiago y escribe heartbeat a
// `BOT_HEALTH/main.ultimoHeartbeat` cada 60s. La pantalla "Estado del Bot"
// del admin lo muestra, pero requiere que Santiago entre a esa pantalla
// para enterarse — riesgo: el bot puede llevar horas/días caído sin que
// nadie lo note (PC apagada por reinicio de Windows, NSSM crasheado,
// etc.) y los choferes dejan de recibir avisos críticos.
//
// **Cambio 2026-05-08**: ANTES esta función mandaba un WhatsApp inmediato
// cuando detectaba la caída. Eso quedaba viejo rápido (caída a las 15:38,
// veo el aviso a las 18:10 cuando ya recuperó hace rato → ruido). Ahora
// solo REGISTRA los eventos en `BOT_EVENTOS` (caída y recuperación). El
// resumen consolidado lo manda `resumenBotDiario` al día siguiente a
// las 8 AM.
//
// **Cambio 2026-06-10**: se suma la ALERTA EXTERNA por Telegram (módulo
// `bot_alerta_externa.ts`). El aviso de "bot caído" no puede viajar por el
// propio bot caído — Telegram es el canal fuera de banda. Detecta además el
// caso "bot vivo pero sesión WhatsApp rota" (AUTH_PENDIENTE/AUTH_FALLO/
// no-LISTO sostenido), que el chequeo por heartbeat solo no veía. Con
// anti-spam (re-aviso 60 min / 6 h) y aviso de recuperación. La lógica de
// BOT_EVENTOS de abajo queda intacta (sigue alimentando el resumen diario).
//
// Esta function corre cada 15 min, compara `ultimoHeartbeat` con ahora.
// Si la diferencia es > UMBRAL_STALE_MIN (importado de bot_alerta_externa),
// escribe evento `caida`. Idempotencia: solo registra UNA vez por episodio
// (flag `notificadoCaida` en BOT_HEALTH). Cuando el bot vuelve, escribe
// evento `recuperado` con la duración total y limpia la flag.

export const botHealthWatchdog = onSchedule(
  {
    schedule: "*/15 * * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
    secrets: [telegramBotToken, telegramChatId],
  },
  async () => {
    const ref = db.collection("BOT_HEALTH").doc("main");
    const snap = await ref.get();
    if (!snap.exists) {
      logger.info("[botHealthWatchdog] BOT_HEALTH/main no existe (primer run), skip");
      return;
    }
    const data = snap.data() ?? {};
    const ultimoHb = data.ultimoHeartbeat as Timestamp | undefined;
    if (!ultimoHb) {
      logger.info("[botHealthWatchdog] sin ultimoHeartbeat aún, skip");
      return;
    }

    const minDesdeHb = (Date.now() - ultimoHb.toMillis()) / 60000;
    const yaNotificado = data.notificadoCaida === true;
    const pcId = (data.pcId ?? "desconocida").toString();

    // ── Alerta externa (Telegram) ─────────────────────────────────────
    // Corre ANTES de la lógica de BOT_EVENTOS porque esa rama tiene
    // returns tempranos. Es una capa independiente: si falla, el registro
    // histórico de abajo tiene que correr igual.
    try {
      await procesarAlertaExterna(ref, data, pcId, ultimoHb);
    } catch (e) {
      logger.error("[botHealthWatchdog] alerta externa falló", { error: String(e) });
    }

    if (minDesdeHb <= UMBRAL_STALE_MIN) {
      // Bot vivo.
      if (yaNotificado) {
        // Volvió de una caída — registrar evento `recuperado` con la
        // duración total estimada (desde la última caída detectada
        // hasta ahora).
        const caidaDetectadaEn = data.notificadoCaidaEn as Timestamp | undefined;
        const duracionMin = caidaDetectadaEn ?
          Math.round((Date.now() - caidaDetectadaEn.toMillis()) / 60000) :
          null;
        await db.collection("BOT_EVENTOS").add({
          tipo: "recuperado",
          pcId,
          detectadoEn: FieldValue.serverTimestamp(),
          duracionMin,
          caidaDetectadaEn: caidaDetectadaEn ?? null,
        });
        await ref.update({
          notificadoCaida: false,
          recuperadoEn: FieldValue.serverTimestamp(),
        });
        logger.info("[botHealthWatchdog] bot recuperado, evento registrado", {
          minDesdeUltimoHb: minDesdeHb.toFixed(1),
          duracionMin,
        });
      }
      return;
    }

    // Bot stale.
    if (yaNotificado) {
      // Ya registramos el evento de caída, no duplicar.
      logger.info("[botHealthWatchdog] bot sigue caído, evento ya registrado", {
        minDesdeUltimoHb: minDesdeHb.toFixed(1),
      });
      return;
    }

    // Primera detección de caída — registrar evento. NO mandamos
    // WhatsApp inmediato (el aviso quedaría viejo si la caída fue
    // hace varias horas). El resumen diario a las 8 AM consolida todo.
    const minutosSinHeartbeat = Math.round(minDesdeHb);
    await db.collection("BOT_EVENTOS").add({
      tipo: "caida",
      pcId,
      detectadoEn: FieldValue.serverTimestamp(),
      ultimoHeartbeatEn: ultimoHb,
      minutosSinHeartbeat,
    });

    await ref.update({
      notificadoCaida: true,
      notificadoCaidaEn: FieldValue.serverTimestamp(),
    });

    logger.warn("[botHealthWatchdog] bot caído — evento registrado para resumen diario", {
      minDesdeUltimoHb: minutosSinHeartbeat,
      pcId,
    });
  }
);

/**
 * Capa de alerta externa del watchdog: evalúa el incidente (lógica pura en
 * bot_alerta_externa.ts), manda el Telegram si corresponde y persiste el
 * estado en BOT_HEALTH/main.alertaExterna.
 *
 * Si el POST a Telegram falla, NO se persiste el avance del incidente: el
 * próximo tick (15 min) vuelve a evaluar lo mismo y reintenta el aviso.
 * Solo se conserva el tracking `noListoDesde` para no perder la medición
 * del estado sostenido.
 */
async function procesarAlertaExterna(
  ref: DocumentReference,
  data: DocumentData,
  pcId: string,
  ultimoHb: Timestamp,
): Promise<void> {
  const ahoraMs = Date.now();
  const estadoCliente = (data.estadoCliente ?? "DESCONOCIDO").toString();
  const previo = incidenteDesdeDoc(data.alertaExterna);

  const res = evaluarAlertaExterna({
    ahoraMs,
    ultimoHeartbeatMs: ultimoHb.toMillis(),
    estadoCliente,
    incidente: previo,
  });

  let aPersistir = res.incidente;
  if (res.avisar && res.clase) {
    // En la recuperación el incidente resultante viene vacío: el contexto
    // del mensaje (motivo/desde) sale del incidente previo.
    const esRecuperacion = res.clase === "recuperacion";
    const texto = construirMensajeAlerta({
      clase: res.clase,
      motivo: (esRecuperacion ? previo.motivo : res.incidente.motivo) ?? "bot_caido",
      estadoCliente,
      pcId,
      ahoraMs,
      ultimoHeartbeatMs: ultimoHb.toMillis(),
      desdeMs: esRecuperacion ? previo.desdeMs : res.incidente.desdeMs,
      avisosEnviados: res.incidente.avisosEnviados,
    });
    const enviado = await enviarTelegram(
      telegramBotToken.value(),
      telegramChatId.value(),
      texto,
    );
    if (enviado) {
      logger.info("[botHealthWatchdog] aviso Telegram enviado", {
        clase: res.clase,
        motivo: esRecuperacion ? previo.motivo : res.incidente.motivo,
        estadoCliente,
      });
    } else {
      // Reintento natural el próximo tick: no avanzar el incidente.
      aPersistir = { ...previo, noListoDesdeMs: res.incidente.noListoDesdeMs };
      logger.warn("[botHealthWatchdog] aviso Telegram NO salió, se reintenta el próximo tick", {
        clase: res.clase,
      });
    }
  }

  if (!sonIncidentesIguales(previo, aPersistir)) {
    await ref.update({ alertaExterna: incidenteHaciaDoc(aPersistir) });
  }
}

// ============================================================================
// vigiladorJornadaChofer — vigilador de jornada (v2 refactor 2026-05-15)
// ============================================================================
//
// El cron en sí es un thin wrapper sobre `tickVigiladorJornada()` del
// módulo `jornadas_v2.ts`. La lógica completa (bloques 3×4h, descanso
// 8h misma posición, veda nocturna 00:00 ART) vive en ese módulo —
// ver `functions/src/jornadas_v2.ts` para el detalle.
//
// Modelo operativo Vecchi:
//   Una jornada = 24 hs = 12 hs conducción + 12 hs descanso.
//   12 hs conducción = 3 BLOQUES de 4 hs (3h45 manejo + 15 min pausa).
//   12 hs descanso = mínimo 8 hs con camión detenido en misma posición
//                    (radio 1000 m por GPS drift).
//
// Disparadores que detienen al chofer:
//   1. Bloque actual llegó a 4h sin pausa de 15 min → bloque excedido.
//   2. Cumplió 3 bloques → cuota cumplida.
//   3. Hora ART ≥ 00:00 → veda nocturna.
//
// Colección de estado: `JORNADAS` (reemplaza a la legacy `JORNADAS_CHOFER`).
// Cada jornada lógica es 1 doc con docId `{dni}_{ts_inicio_ms}`. La
// jornada se cierra (set `jornada_fin_ts`) cuando llega 8 hs detenido.

export const vigiladorJornadaChofer = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 90,
    memory: "256MiB",
  },
  async () => {
    // Lock tick-level (auditoria 2026-05-18): al-least-once de GCP puede
    // disparar dos invocaciones casi simultaneas. Sin lock, cargarJornadaAbierta
    // + nuevaJornada NO son atomicas → dos ticks pueden ver "no hay jornada"
    // para el mismo DNI y crear 2 docs distintos → el chofer recibe avisos
    // 3h30/3h45/cuota/veda DOS VECES.
    const liberar = await adquirirLockTick(
      "vigilador_jornada",
      4 * 60 * 1000,
    );
    if (!liberar) return;
    try {
      await jornadasV2.tickVigiladorJornada();
    } finally {
      await liberar();
    }
  }
);

/**
 * Cron que detecta silencios EXPIRADOS y notifica al chofer que sus
 * notificaciones se reanudan + borra el doc de
 * `BOT_SILENCIADOS_CHOFER`.
 *
 * Pedido Santiago 2026-05-13: cuando el silencio se cumple, el
 * chofer tiene que recibir un mensaje de "notificaciones reanudadas".
 * Si no, el chofer no se entera de cuándo vuelven los avisos.
 *
 * Por qué no en el vigilador: el vigilador corre cada 5 min y es
 * tiempo-crítico (alertas de jornada). Esto puede esperar hasta 10
 * min sin problema y mantenemos las funciones desacopladas.
 *
 * Path "manual desilenciar": si el admin corre `/desilenciar DNI`
 * antes de que expire, el bot mismo encola la reanudación y borra
 * el doc — este cron nunca lo ve. Eso es OK: ambos paths terminan en
 * el mismo estado (mensaje encolado + doc borrado).
 */
export const procesarSilenciadosExpirados = onSchedule(
  {
    schedule: "every 10 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    const ahora = Timestamp.now();
    let snap;
    try {
      snap = await db
        .collection("BOT_SILENCIADOS_CHOFER")
        .where("silenciado_hasta", "<=", ahora)
        .limit(100)
        .get();
    } catch (e) {
      logger.warn("[procesarSilenciadosExpirados] query falló", {
        error: (e as Error).message,
      });
      return;
    }
    if (snap.empty) {
      logger.debug("[procesarSilenciadosExpirados] sin expirados");
      return;
    }
    let notificados = 0;
    let saltadosPermanentes = 0;
    let conservados = 0;
    for (const d of snap.docs) {
      const data = d.data();
      const dni = (data.chofer_dni || d.id).toString();

      // Idempotencia (auditoría 2026-05-22): si en un tick anterior YA
      // encolamos la reanudación pero el delete falló, el doc sigue
      // matcheando (silenciado_hasta <= ahora). En ese caso NO reencolamos
      // (evita un 2º "notificaciones reanudadas" al chofer) — solo
      // reintentamos el borrado.
      if (data.reanudacion_encolada === true) {
        try {
          await d.ref.delete();
        } catch (e) {
          logger.warn(
            "[procesarSilenciadosExpirados] retry de borrado falló",
            { dni, error: (e as Error).message }
          );
          conservados++;
        }
        continue;
      }

      let errorPermanente = false;
      let encolado = false;
      try {
        await _encolarAvisoSilencioReanudado(dni);
        notificados++;
        encolado = true;
      } catch (e) {
        const msg = (e as Error).message || "";
        // Errores PERMANENTES (no vale reintentar) → borrar igual.
        // Ej: chofer no existe en EMPLEADOS, sin TELEFONO valido,
        // ACTIVO=false. Reintentar manana no cambia nada.
        errorPermanente =
          /no existe en EMPLEADOS|sin TELEFONO|ACTIVO=false|inactivo/i.test(msg);
        if (errorPermanente) {
          logger.warn(
            "[procesarSilenciadosExpirados] no encolé reanudación (permanente)",
            { dni, error: msg }
          );
          saltadosPermanentes++;
        } else {
          // Fix M6 (auditoria 24/7 2026-05-18): error TRANSIENT (red,
          // Firestore timeout, etc.). NO borrar el doc — el proximo
          // tick (10 min) reintenta. Antes: borraba siempre → chofer
          // quedaba des-silenciado SIN aviso y sin posibilidad de
          // retry.
          logger.warn(
            "[procesarSilenciadosExpirados] no encolé reanudación " +
            "(transient, conservo doc para retry)",
            { dni, error: msg }
          );
          conservados++;
          continue; // skip el delete de abajo
        }
      }

      // Encolado OK → marcar el flag ANTES de borrar (best-effort): si el
      // delete de abajo falla, el próximo tick ve el flag y NO reencola.
      if (encolado) {
        try {
          await d.ref.update({ reanudacion_encolada: true });
        } catch (e) {
          logger.warn(
            "[procesarSilenciadosExpirados] no marqué reanudacion_encolada",
            { dni, error: (e as Error).message }
          );
        }
      }

      // Solo borrar si encolamos OK o el error fue permanente.
      try {
        await d.ref.delete();
      } catch (e) {
        logger.warn("[procesarSilenciadosExpirados] no borré doc", {
          dni,
          error: (e as Error).message,
        });
      }
    }
    logger.info("[procesarSilenciadosExpirados] OK", {
      notificados,
      saltadosPermanentes,
      conservados,
      total: snap.size,
    });
  }
);

async function _encolarAvisoSilencioReanudado(
  choferDni: string
): Promise<void> {
  const empSnap = await db.collection("EMPLEADOS").doc(choferDni).get();
  if (!empSnap.exists) {
    throw new Error(`EMPLEADOS/${choferDni} no existe`);
  }
  const empData = empSnap.data() ?? {};
  if (empData.ACTIVO === false) {
    throw new Error("empleado inactivo");
  }
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") {
    throw new Error("sin TELEFONO");
  }
  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

  const mensaje =
    `${saludo},\n\n` +
    "Se cumplió el plazo de silencio.\n\n" +
    "*Las notificaciones automáticas del bot vuelven a estar activas* " +
    "(avisos de jornada, descansos, etc.).\n\n" +
    BANNER_TESTING +
    "_Bot-On — Coopertrans Móvil_";

  await db.collection("COLA_WHATSAPP").add({
    telefono: tel,
    mensaje,
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    expira_en: expiraEnMin(60),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "silencio_reanudado",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: choferDni,
    campo_base: "BOT_SILENCIADO",
    admin_dni: "BOT",
    admin_nombre: "Bot silenciador (cron)",
  });
}
