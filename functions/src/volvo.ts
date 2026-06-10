/**
 * Cloud Functions de integración con Volvo Connect.
 *
 * Extraído de index.ts (refactor split 2026-05-19). Agrupa las 5
 * functions que hablan con las APIs de Volvo + sus helpers privados:
 *   - `volvoProxy` (onCall): proxy server-side a Volvo Connect (flota /
 *     telemetría / kilometraje), credenciales en Secret Manager.
 *   - `volvoAlertasPoller` (cron 5 min): Vehicle Alerts API → VOLVO_ALERTAS.
 *   - `onAlertaVolvoCreated` (trigger): notifica al chofer alertas HIGH.
 *   - `volvoScoresPoller` (cron diario): Group Scores API → VOLVO_SCORES_DIARIOS.
 *
 * Alertas + scores comparten toda la infra de auth de Volvo (secrets +
 * VOLVO_BASE + Accept headers), por eso van en un solo módulo en lugar
 * de volvo_alertas.ts + volvo_scores.ts separados.
 *
 * Los secrets + VOLVO_BASE + ACCEPT_STATUSES se exportan porque
 * `telemetriaSnapshotScheduled` (telemetria.ts) también pega a Volvo.
 *
 * Importa los helpers compartidos de comun.ts (no de index) para evitar
 * el ciclo index↔volvo. Re-exportado desde index con `export * from "./volvo"`.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db, BANNER_TESTING } from "./setup";
import {
  ayerYmdArg,
  expiraEnMin,
  formatFechaArg,
  formatHoraArg,
  inicioDelDiaArg,
  primerNombre,
  rrPick,
} from "./helpers";
import {
  AsignacionLookup,
  cargarAsignacionesPorPatentes,
  buscarAsignacionEnFecha,
  adquirirLockTick,
  fetchWithTimeout,
  fetchConReintentos,
  esErrorTransient,
  obtenerDestinatarioDni,
  SEG_HIGIENE_DESTINATARIO_DNI,
} from "./comun";
import { estaCanalPausado } from "./canales_pausados";

// ============================================================================
// volvoProxy
// ============================================================================
// Proxy server-side a la API de Volvo Connect. Mantiene las credenciales
// (`VOLVO_USERNAME`/`VOLVO_PASSWORD`) en Secret Manager y solo permite
// invocar a admins autenticados via Firebase Auth custom token.
//
// La function recibe `{operation, params}` y traduce a un GET autenticado
// contra Volvo. Devuelve `{statusCode, data}` para que el cliente conserve
// su capacidad de hacer parsing tolerante (paths legacy, etc).
//
// Setup inicial (una sola vez):
//   firebase functions:secrets:set VOLVO_USERNAME
//   firebase functions:secrets:set VOLVO_PASSWORD
//
// Operaciones soportadas:
//   - "flota"        → GET /vehicle/vehicles
//   - "telemetria"   → GET /vehicle/vehiclestatuses?vin=X&additionalContent=VOLVOGROUPSNAPSHOT
//   - "kilometraje"  → GET /vehicle/vehiclestatuses?vin=X
//   - "estadosFlota" → GET /vehicle/vehiclestatuses (todos)

// Exportados: telemetria.ts también pega a Volvo y reusa secrets +
// VOLVO_BASE + ACCEPT_STATUSES.
export const volvoUsername = defineSecret("VOLVO_USERNAME");
export const volvoPassword = defineSecret("VOLVO_PASSWORD");

export const VOLVO_BASE = "https://api.volvotrucks.com";
const ACCEPT_VEHICLES =
  "application/x.volvogroup.com.vehicles.v1.0+json; UTF-8";
export const ACCEPT_STATUSES =
  "application/x.volvogroup.com.vehiclestatuses.v1.0+json; UTF-8";

// VIN estandar ISO 3779: 17 caracteres alfanumericos en mayuscula.
// Validamos cliente-side antes de forwardear a Volvo para cortar
// requests con VINs malformados (typos, fuzzing) sin tocar la API
// externa.
const VIN_REGEX = /^[A-Z0-9]{17}$/;
const VIN_INVALIDO_MSG = "`params.vin` no es un VIN valido (17 chars, A-Z y 0-9).";

interface VolvoProxyResult {
  statusCode: number;
  data: unknown;
}

export const volvoProxy = onCall(
  {
    secrets: [volvoUsername, volvoPassword],
    timeoutSeconds: 30,
  },
  async (request): Promise<VolvoProxyResult> => {
    // ─── Auth: solo admin logueado ─────────────────────────────────
    const rol = request.auth?.token?.rol;
    if (!request.auth || rol !== "ADMIN") {
      logger.warn("[volvoProxy] llamada sin auth ADMIN", {
        uid: request.auth?.uid ?? "no-uid",
        rol: rol ?? "no-rol",
      });
      throw new HttpsError(
        "permission-denied",
        "Solo administradores pueden consultar Volvo."
      );
    }

    // ─── Validación de input ───────────────────────────────────────
    const operation = (request.data?.operation ?? "").toString();
    const params = (request.data?.params ?? {}) as Record<string, unknown>;

    if (!operation) {
      throw new HttpsError("invalid-argument", "Falta `operation`.");
    }

    // ─── Routing por operación → URL Volvo ─────────────────────────
    let url: string;
    let accept: string;

    switch (operation) {
    case "flota": {
      url = `${VOLVO_BASE}/vehicle/vehicles`;
      accept = ACCEPT_VEHICLES;
      break;
    }
    case "telemetria": {
      const vin = (params.vin ?? "").toString().trim().toUpperCase();
      if (!vin) {
        throw new HttpsError("invalid-argument", "Falta `params.vin`.");
      }
      if (!VIN_REGEX.test(vin)) {
        throw new HttpsError("invalid-argument", VIN_INVALIDO_MSG);
      }
      const qs = new URLSearchParams({
        vin,
        latestOnly: "true",
        // contentFilter pide explícitamente todos los bloques disponibles
        // — ACCUMULATED (combustible total, distancia total),
        //   SNAPSHOT (velocidad, % combustible, GPS),
        //   UPTIME (serviceDistance, tellTaleInfo, engineCoolantTemp).
        // Sin este parámetro, según la doc Volvo deberían venir todos
        // pero algunas cuentas filtran UPTIME a menos que se pida explícito.
        contentFilter: "ACCUMULATED,SNAPSHOT,UPTIME",
        // additionalContent agrega contenido extra de Volvo Group
        // dentro del bloque snapshot (ej. estimatedDistanceToEmpty).
        additionalContent: "VOLVOGROUPSNAPSHOT",
      });
      url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;
      accept = ACCEPT_STATUSES;
      break;
    }
    case "kilometraje": {
      const vin = (params.vin ?? "").toString().trim().toUpperCase();
      if (!vin) {
        throw new HttpsError("invalid-argument", "Falta `params.vin`.");
      }
      if (!VIN_REGEX.test(vin)) {
        throw new HttpsError("invalid-argument", VIN_INVALIDO_MSG);
      }
      const qs = new URLSearchParams({
        vin,
        latestOnly: "true",
      });
      url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;
      accept = ACCEPT_STATUSES;
      break;
    }
    case "estadosFlota": {
      const qs = new URLSearchParams({
        latestOnly: "true",
        // Mismo `contentFilter` que `telemetria`: pide explícitamente
        // los 3 bloques. Necesario para que `uptimeData.serviceDistance`
        // venga en el batch de toda la flota.
        contentFilter: "ACCUMULATED,SNAPSHOT,UPTIME",
        additionalContent: "VOLVOGROUPSNAPSHOT",
      });
      url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;
      accept = ACCEPT_STATUSES;
      break;
    }
    default:
      throw new HttpsError(
        "invalid-argument",
        `Operación '${operation}' no soportada.`
      );
    }

    // ─── Llamada a Volvo ───────────────────────────────────────────
    const authHeader = "Basic " + Buffer.from(
      `${volvoUsername.value()}:${volvoPassword.value()}`
    ).toString("base64");

    try {
      const res = await fetchWithTimeout(url, {
        method: "GET",
        headers: {
          "Authorization": authHeader,
          "Accept": accept,
        },
      });

      // Volvo a veces devuelve cuerpo no-JSON ante 401/406. Toleramos.
      let body: unknown = null;
      const text = await res.text();
      if (text) {
        try {
          body = JSON.parse(text);
        } catch {
          body = { raw: text };
        }
      }

      logger.info("[volvoProxy] OK", {
        operation,
        statusCode: res.status,
      });

      return {
        statusCode: res.status,
        data: body,
      };
    } catch (e) {
      logger.error("[volvoProxy] error", {
        operation,
        error: (e as Error).message,
      });
      throw new HttpsError(
        "unavailable",
        "Error consultando Volvo. Reintentá en unos segundos."
      );
    }
  }
);


// ============================================================================
// volvoAlertasPoller
// ============================================================================
// Scheduled function que cada 5 minutos pollea la Volvo Vehicle Alerts API
// (`/alert/vehiclealerts`) y persiste cada evento nuevo en la colección
// VOLVO_ALERTAS. Las alertas son eventos discretos del vehículo (IDLING,
// DISTANCE_ALERT, PTO, OVERSPEED, TELL_TALE, ALARM, etc.) — distintos de
// los snapshots de telemetría que captura `telemetriaSnapshotScheduled`.
//
// Diseño:
//   - **Cursor por timestamp del server**: el endpoint devuelve
//     `requestServerDateTime` (UTC del server al recibir el request). Lo
//     persistimos en META/volvo_alertas_cursor y lo usamos como `starttime`
//     del próximo run. Eso garantiza no perder eventos ni duplicar (con
//     `datetype=received` que es el default).
//   - **DocId composite + idempotente**: `{vin}_{createdMs}_{tipo}`. Si
//     el mismo evento se polea dos veces (overlap del cursor, retry, etc),
//     mismo docId → mismo doc, no se duplica.
//   - **Skip de duplicados con getAll batch**: antes de escribir, hacemos
//     1 getAll por página para detectar cuáles docIds ya existen y no
//     pisar campos de gestión (`atendida`, `atendida_por`) seteados por el
//     admin desde la app.
//   - **Paginación**: el spec devuelve `moreDataAvailable` + `moreDataAvailableLink`
//     (relativo, ya con query params preservados). Lo seguimos hasta que
//     `moreDataAvailable=false` o llegamos al safety cap de páginas.
//   - **Cold start**: si no hay cursor (primer run de la function),
//     arrancamos desde "ahora menos 1h". El histórico anterior se ignora
//     en este path; si hace falta backfillear más, se hace por script
//     manual aparte.
//   - **Cross-ref VIN → patente**: el payload trae `customerVehicleName`
//     que en la cuenta de Coopertrans coincide con la patente argentina.
//     Como fallback (si viene vacío o no coincide), buscamos en VEHICULOS
//     por VIN — mismo patrón que `telemetriaSnapshotScheduled`.

const ACCEPT_ALERTS =
  "application/x.volvogroup.com.vehiclealerts.v1.1+json; UTF-8";

// Sub-objetos posibles dentro de un AlertsObject según el spec v1.1.6.
// Los copiamos al campo `detalles` solo si vienen en el payload — la
// mayoría de las alertas tiene exactamente uno (el que corresponde al
// alertType), pero el modelo permite más.
const ALERT_SUBOBJETOS = [
  "generic",
  "tachoOutOfMode",
  "geofence",
  "safetyZone",
  "overspeed",
  "idling",
  "fuelLevel",
  "catalystFuelLevel",
  "pto",
  "cargo",
  "tpm",
  "ttm",
  "das",
  "esp",
  "aebs",
  "harsh",
  "lks",
  "lcs",
  "distanceAlert",
  "unsafeLaneChange",
  "chargingStatusInfo",
  "volvoGroupChargingStatusInfo",
  "batteryPackInfo",
  "chargingConnectionStatusInfo",
  "alarmInfo",
] as const;

// Cap de páginas por run para que un cursor mal seteado no nos haga un
// loop largo. Con cadencia de 5 min y volumen real (~5 eventos/día), una
// sola página alcanza siempre. 20 páginas = hasta 2000 eventos, suficiente
// margen para cualquier escenario realista.
const MAX_PAGES_PER_RUN = 20;

// En cold start, arrancamos desde "ahora - 1h" (no backfilleamos histórico
// completo automáticamente). 1h da margen razonable de overlap si la
// function arranca después de un período de inactividad sin perder los
// eventos recientes.
const COLD_START_LOOKBACK_MS = 60 * 60 * 1000;

interface AlertsApiAlert extends Record<string, unknown> {
  vin?: string;
  alertType?: string;
  severity?: string;
  createdDateTime?: string;
  receivedDateTime?: string;
  customerVehicleName?: string;
  gnssPosition?: Record<string, unknown>;
  driverId?: Record<string, unknown>;
  hrTotalVehicleDistance?: number;
  totalEngineHours?: number;
  totalElectricMotorHours?: number;
}

interface AlertsApiResponse {
  alertsResponse?: {
    alerts?: AlertsApiAlert[];
    moreDataAvailable?: boolean;
    moreDataAvailableLink?: string;
    requestServerDateTime?: string;
  };
}

export const volvoAlertasPoller = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [volvoUsername, volvoPassword],
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async () => {
    // Lock tick (auditoria 2026-05-18): el cron es cada 5 min con timeout
    // 120s, pero un cold start + lookback puede tomar > 5 min en flotas
    // con backlog. GCP at-least-once puede disparar 2 invocaciones
    // simultaneas → ambas avanzan el cursor `ultimo_request_server_datetime`
    // y pueden saltearse eventos. Lock evita esto.
    const liberar = await adquirirLockTick(
      "volvo_alertas_poller",
      4 * 60 * 1000,
    );
    if (!liberar) return;
    try {
      logger.info("[volvoAlertasPoller] iniciando ciclo");

      // ─── 1. Cursor: desde dónde poleamos ────────────────────────────
      const cursorRef = db.collection("META").doc("volvo_alertas_cursor");
      const cursorSnap = await cursorRef.get();
      const cursorData = cursorSnap.exists ? cursorSnap.data() ?? {} : {};
      const ultimoServerTs = cursorData.ultimo_request_server_datetime as
      | Timestamp
      | undefined;
      const starttime = ultimoServerTs ?
        ultimoServerTs.toDate().toISOString() :
        new Date(Date.now() - COLD_START_LOOKBACK_MS).toISOString();
      const esColdStart = !ultimoServerTs;

      // ─── 2. Map VIN → patente desde VEHICULOS ───────────────────────
      // Soft-delete: vehiculos dados de baja NO se mapean — sus alertas
      // del API Volvo se descartan en lugar de crearse en VOLVO_ALERTAS.
      const vehiculosSnap = await db.collection("VEHICULOS").get();
      const vinToPatente = new Map<string, string>();
      for (const doc of vehiculosSnap.docs) {
        const data = doc.data();
        if (data.ACTIVO === false) continue;
        const vin = (data.VIN ?? "").toString().trim().toUpperCase();
        if (vin && vin !== "-") {
          vinToPatente.set(vin, doc.id);
        }
      }

      // ─── 3. Auth Volvo ──────────────────────────────────────────────
      const authHeader = "Basic " + Buffer.from(
        `${volvoUsername.value()}:${volvoPassword.value()}`
      ).toString("base64");

      // ─── 4. Loop de paginación ──────────────────────────────────────
      const qsInicial = new URLSearchParams({ starttime });
      let url = `${VOLVO_BASE}/alert/vehiclealerts?${qsInicial.toString()}`;
      let totalRecibidos = 0;
      let totalEscritos = 0;
      let totalDuplicados = 0;
      let totalDescartados = 0;
      let nuevoServerDateTime: string | null = null;
      let pages = 0;

      while (pages < MAX_PAGES_PER_RUN) {
        pages++;

        let res: Response;
        try {
          // 1 reintento por página (audit 2026-06-10): los AbortError
          // transient de Volvo perdían el tick entero (cursor sin avanzar).
          res = await fetchConReintentos(url, {
            method: "GET",
            headers: {
              "Authorization": authHeader,
              "Accept": ACCEPT_ALERTS,
            },
          }, { tag: "volvoAlertasPoller" });
        } catch (e) {
          // Auditoria 2026-05-24: 69 de 80 errors/7d eran AbortError
          // transient del API Volvo. Downgradeamos a WARN si es
          // transient para no inflar Sentry/Cloud Logging con ruido
          // que no es bug real.
          const transient = esErrorTransient(e);
          const log = transient ? logger.warn : logger.error;
          log("[volvoAlertasPoller] fetch falló", {
            page: pages,
            error: (e as Error).message,
            transient,
          });
          return; // No actualizamos cursor, próximo run reintenta.
        }

        if (!res.ok) {
          logger.warn("[volvoAlertasPoller] Volvo HTTP error", {
            statusCode: res.status,
            page: pages,
          });
          return; // Idem: no avanzamos cursor.
        }

        const body = (await res.json()) as AlertsApiResponse;
        const response = body.alertsResponse ?? {};
        const alerts = Array.isArray(response.alerts) ? response.alerts : [];
        const moreData = response.moreDataAvailable === true;
        const moreLink = response.moreDataAvailableLink;
        const serverTs = response.requestServerDateTime;

        // El requestServerDateTime de la PRIMER página es el que vamos a
        // persistir como cursor. Las páginas siguientes traen el mismo
        // valor o uno levemente distinto, pero usamos siempre la primera
        // para que el cursor refleje el momento del primer fetch.
        if (pages === 1 && serverTs) {
          nuevoServerDateTime = serverTs;
        }

        totalRecibidos += alerts.length;

        if (alerts.length > 0) {
          const writeResult = await persistirAlertas(
            alerts,
            vinToPatente
          );
          totalEscritos += writeResult.escritos;
          totalDuplicados += writeResult.duplicados;
          totalDescartados += writeResult.descartados;
        }

        if (!moreData || !moreLink) break;
        url = `${VOLVO_BASE}${moreLink}`;
      }

      // ─── 5. Persistir cursor ────────────────────────────────────────
      if (nuevoServerDateTime) {
        await cursorRef.set(
          {
            ultimo_request_server_datetime: Timestamp.fromDate(
              new Date(nuevoServerDateTime)
            ),
            ultimo_exito_at: FieldValue.serverTimestamp(),
            ultimo_recibidos: totalRecibidos,
            ultimo_escritos: totalEscritos,
            ultimo_duplicados: totalDuplicados,
            ultimo_descartados: totalDescartados,
            ultimo_paginas: pages,
          },
          { merge: true }
        );
      }

      logger.info("[volvoAlertasPoller] OK", {
        esColdStart,
        paginas: pages,
        recibidos: totalRecibidos,
        escritos: totalEscritos,
        duplicados: totalDuplicados,
        descartados: totalDescartados,
      });
    } finally {
      await liberar();
    }
  }
);

interface PersistirResult {
  escritos: number;
  duplicados: number;
  descartados: number;
}

/**
 * Persiste un batch de alertas en VOLVO_ALERTAS de manera idempotente.
 *
 * Estrategia:
 *   1. Construir docId compuesto `{vin}_{createdMs}_{tipo}` para cada
 *      alerta. Las que no tengan los campos required del spec
 *      (vin/alertType/createdDateTime) se descartan.
 *   2. Hacer un único `getAll` para detectar cuáles docIds ya existen
 *      en Firestore. Esos se skipean (no los pisamos para no perder
 *      campos de gestión `atendida`/`atendida_por`/`atendida_en`).
 *   3. Crear los nuevos en una sola batch.
 *
 * Costo: 1 getAll de N reads + 1 batch de M writes (M = alertas nuevas).
 */
async function persistirAlertas(
  alerts: AlertsApiAlert[],
  vinToPatente: Map<string, string>
): Promise<PersistirResult> {
  // 1. Construir docIds, descartar las inválidas
  type Pendiente = { docId: string; alert: AlertsApiAlert };
  const pendientes: Pendiente[] = [];
  let descartados = 0;

  for (const alert of alerts) {
    const vin = (alert.vin ?? "").toString().trim().toUpperCase();
    const tipo = (alert.alertType ?? "").toString();
    const createdRaw = alert.createdDateTime;
    if (!vin || !tipo || !createdRaw) {
      descartados++;
      continue;
    }
    const createdMs = new Date(createdRaw).getTime();
    if (Number.isNaN(createdMs)) {
      descartados++;
      continue;
    }
    pendientes.push({ docId: `${vin}_${createdMs}_${tipo}`, alert });
  }

  if (pendientes.length === 0) {
    return { escritos: 0, duplicados: 0, descartados };
  }

  // 2. getAll para saber cuáles ya existen
  const refs = pendientes.map((p) =>
    db.collection("VOLVO_ALERTAS").doc(p.docId)
  );
  const snaps = await db.getAll(...refs);
  const existing = new Set<string>();
  for (const snap of snaps) {
    if (snap.exists) existing.add(snap.id);
  }

  // 3. Pre-cargar asignaciones para resolver chofer-en-fecha en memoria.
  // Tomamos todas las patentes únicas presentes en los pendientes que NO
  // existían ya (los duplicados los skipeamos abajo igual). Una sola
  // query (en chunks de 30 por límite de Firestore `in`) nos da todo.
  const patentesUnicas = new Set<string>();
  for (let i = 0; i < pendientes.length; i++) {
    if (existing.has(pendientes[i].docId)) continue;
    const vin = (pendientes[i].alert.vin ?? "")
      .toString().trim().toUpperCase();
    const customerName = (pendientes[i].alert.customerVehicleName ?? "")
      .toString().trim();
    const patente = customerName || vinToPatente.get(vin);
    if (patente) patentesUnicas.add(patente);
  }
  const asignacionesPorPatente = await cargarAsignacionesPorPatentes(
    Array.from(patentesUnicas)
  );

  // 4. Batch de creación de los nuevos
  const batch = db.batch();
  let escritos = 0;
  for (let i = 0; i < pendientes.length; i++) {
    const { docId, alert } = pendientes[i];
    if (existing.has(docId)) continue;
    batch.set(
      refs[i],
      buildAlertaDoc(alert, vinToPatente, asignacionesPorPatente)
    );
    escritos++;
  }
  if (escritos > 0) {
    await batch.commit();
  }

  return {
    escritos,
    duplicados: pendientes.length - escritos,
    descartados,
  };
}


/**
 * Mapea una alerta del payload de Volvo al doc Firestore
 * (naming castellano + tipos serializables). Si hay [asignacionesPorPatente]
 * disponibles, snapshottea el chofer que estaba manejando esa patente
 * en el momento del evento (de forma que la atribución no cambie si
 * después se reasigna la unidad).
 */
function buildAlertaDoc(
  alert: AlertsApiAlert,
  vinToPatente: Map<string, string>,
  asignacionesPorPatente?: Map<string, AsignacionLookup[]>
): Record<string, unknown> {
  const vin = (alert.vin ?? "").toString().trim().toUpperCase();
  const tipo = (alert.alertType ?? "").toString();
  const severidad = (alert.severity ?? "").toString();
  const creadoMs = new Date(alert.createdDateTime as string).getTime();

  const customerName = (alert.customerVehicleName ?? "").toString().trim();
  const patente = customerName || vinToPatente.get(vin) || null;

  // TTL: `expira_en` (creado_en + 12 meses). Activar policy con:
  //   gcloud firestore fields ttls update expira_en \
  //     --collection-group=VOLVO_ALERTAS --enable-ttl \
  //     --project=coopertrans-movil
  // Las alertas son útiles para investigar incidentes recientes pero
  // no para histórico anual; 12 meses cubre auditorías y disputas
  // típicas con clientes/aseguradoras sin acumular sin tope.
  // 12 meses calendario (no 12*30 dias = 360 dias = ~11.8 meses).
  // Antes borraba ~5 dias antes del aniversario real — para auditorias
  // anuales hace falta calendario exacto. setUTCMonth evita drift.
  const ttl = new Date(creadoMs);
  ttl.setUTCMonth(ttl.getUTCMonth() + 12);
  const expiraEnMs = ttl.getTime();
  const doc: Record<string, unknown> = {
    vin,
    tipo,
    severidad,
    creado_en: Timestamp.fromMillis(creadoMs),
    polled_en: FieldValue.serverTimestamp(),
    expira_en: Timestamp.fromMillis(expiraEnMs),
    // Estado de gestión inicial. El admin lo flippa a `true` desde el
    // tablero al marcarla atendida (junto con `atendida_por` y
    // `atendida_en`). El poller solo escribe `false` en la creación
    // inicial — re-polls del mismo evento se skipean por `getAll`.
    atendida: false,
  };
  if (patente) {
    doc.patente = patente;
    // Snapshot del chofer en ese instante: usamos el log temporal
    // ASIGNACIONES_VEHICULO (no `EMPLEADOS.VEHICULO` "actual"), porque
    // si la patente rota después, la atribución del evento no debería
    // cambiar. Si no hay log para ese momento (típico en eventos de
    // antes del go-live del sistema), lo dejamos vacío — la pantalla
    // cae a "chofer asignado actual" como antes.
    const asignacion = buscarAsignacionEnFecha(
      asignacionesPorPatente?.get(patente),
      creadoMs
    );
    if (asignacion && asignacion.chofer_dni) {
      doc.chofer_dni = asignacion.chofer_dni;
      if (asignacion.chofer_nombre) {
        doc.chofer_nombre = asignacion.chofer_nombre;
      }
    }
  }

  if (alert.receivedDateTime) {
    const recibidoMs = new Date(alert.receivedDateTime).getTime();
    if (!Number.isNaN(recibidoMs)) {
      doc.recibido_en = Timestamp.fromMillis(recibidoMs);
    }
  }

  // GPS: el spec marca `latitude`/`longitude`/`positionDateTime` como
  // required dentro de gnssPosition. Si vino el sub-objeto, lo mapeamos.
  const gps = alert.gnssPosition;
  if (gps && typeof gps === "object") {
    const posicion: Record<string, unknown> = {};
    if (gps.latitude != null) posicion.lat = Number(gps.latitude);
    if (gps.longitude != null) posicion.lng = Number(gps.longitude);
    if (gps.heading != null) posicion.heading = Number(gps.heading);
    if (gps.altitude != null) posicion.altitud = Number(gps.altitude);
    if (gps.speed != null) posicion.velocidad = Number(gps.speed);
    if (gps.positionDateTime) {
      const posMs = new Date(gps.positionDateTime as string).getTime();
      if (!Number.isNaN(posMs)) posicion.timestamp = Timestamp.fromMillis(posMs);
    }
    if (Object.keys(posicion).length > 0) {
      doc.posicion_gps = posicion;
    }
  }

  // Sub-objetos del payload: copiamos el que venga (suele ser uno solo,
  // el correspondiente al alertType). Los renombramos con prefijo
  // `detalle_` para que sean obvios en consultas y no choquen con
  // campos top-level.
  for (const subKey of ALERT_SUBOBJETOS) {
    const sub = alert[subKey];
    if (sub != null) {
      doc[`detalle_${subKey}`] = sub;
    }
  }

  // Datos opcionales del vehículo en el momento del evento.
  if (alert.hrTotalVehicleDistance != null) {
    const metros = Number(alert.hrTotalVehicleDistance);
    if (!Number.isNaN(metros)) doc.distancia_total_metros = metros;
  }
  if (alert.totalEngineHours != null) {
    const horas = Number(alert.totalEngineHours);
    if (!Number.isNaN(horas)) doc.horas_motor = horas;
  }
  if (alert.totalElectricMotorHours != null) {
    const horas = Number(alert.totalElectricMotorHours);
    if (!Number.isNaN(horas)) doc.horas_motor_electrico = horas;
  }

  // Driver ID si vino. Lo guardamos crudo — la app decide qué mostrar
  // según `tachoDriverIdentification` o `oemDriverIdentification`.
  if (alert.driverId && typeof alert.driverId === "object") {
    doc.driver_id = alert.driverId;
  }

  return doc;
}

// ============================================================================
// onAlertaVolvoCreated — notificación al chofer cuando hay alerta HIGH
// ============================================================================
// Trigger Firestore que se dispara cuando `volvoAlertasPoller` escribe un
// doc nuevo en `VOLVO_ALERTAS`. Si la severidad es HIGH:
//   1. Buscamos qué chofer tiene asignada esa patente (EMPLEADOS.VEHICULO).
//   2. Si tiene TELEFONO cargado, encolamos un mensaje en COLA_WHATSAPP.
//   3. El bot Node.js (NSSM) procesa la cola respetando horarios laborales
//      (8-19 lunes a viernes, sin feriados): si la alerta es a las 23:00,
//      el doc queda PENDIENTE hasta las 8:00 del siguiente día hábil.
//
// Idempotencia: los Firestore triggers son AT LEAST ONCE — GCP puede
// reentregar el mismo evento (timeouts, rebalanceos). El poller del
// volvoAlertasPoller ya skipea duplicados con getAll a nivel del doc
// `VOLVO_ALERTAS`, pero ese mismo doc puede gatillar este trigger más
// de una vez. Sin idempotencia, el chofer recibe el mismo mensaje 2-3
// veces seguidas.
//
// Solución: claim atómico por alertId en `META_ALERTAS_VOLVO_NOTIFICADAS`
// usando `create()` (tira ALREADY_EXISTS si ya existe). Si el claim
// falla → es un retry, saltamos. Si encolar falla → borramos el claim
// para que el retry pueda reintentar.
//
// Casos donde se hace skip silencioso (log, no se manda mensaje):
//   - Severidad MEDIUM o LOW (solo HIGH gatilla notificación al instante).
//   - Patente sin chofer asignado (tractor en taller / sin uso).
//   - Chofer sin TELEFONO o con TELEFONO vacío ("-", "").
//
// Si el chofer no aparece, la alerta sigue visible en el tablero "Alertas"
// del admin y entra al resumen diario que se envía a Santiago.

const ETIQUETAS_TIPO_ALERTA: Record<string, string> = {
  DISTANCE_ALERT: "Cerca del vehículo de adelante",
  IDLING: "Motor en ralentí prolongado",
  OVERSPEED: "Exceso de velocidad",
  PTO: "Toma de fuerza activada",
  HARSH: "Aceleración / frenada brusca",
  GENERIC: "Evento genérico",
  TELL_TALE: "Luz de tablero encendida",
  FUEL: "Cambio anormal de combustible",
  CATALYST: "Cambio de nivel AdBlue",
  ALARM: "Alarma anti-robo",
  GEOFENCE: "Entrada/salida de geocerca",
  SAFETY_ZONE: "Zona de velocidad reducida",
  TPM: "Presión de neumático",
  TTM: "Temperatura de neumático",
  AEBS: "Frenado automático de emergencia",
  ESP: "Control de estabilidad",
  DAS: "Alerta de cansancio",
  LKS: "Asistente de carril",
  LCS: "Asistente de cambio de carril",
  UNSAFE_LANE_CHANGE: "Cambio de carril inseguro",
  TACHO_OUT_OF_SCOPE_MODE_CHANGE: "Tacógrafo fuera de servicio",
  CARGO: "Cambio en carga (puerta / temp)",
  ADBLUELEVEL_LOW: "AdBlue bajo",
  WITHOUT_ADBLUE: "Sin AdBlue",
  DRIVING_WITHOUT_BEING_LOGGED_IN: "Conducción sin chofer identificado",
  SEATBELT: "Cinturón de seguridad sin abrochar",
  BATTERY_PACK_HIGH_DISCHARGE: "Descarga alta de batería",
  BATTERY_PACK_CHARGING_STATUS_CHANGE: "Cambio en estado de carga",
};

export const onAlertaVolvoCreated = onDocumentCreated(
  {
    document: "VOLVO_ALERTAS/{alertId}",
    timeoutSeconds: 30,
    memory: "256MiB",
  },
  async (event) => {
    const snap = event.data;
    if (!snap) {
      logger.warn("[onAlertaVolvoCreated] event.data vacío, skip");
      return;
    }

    const data = snap.data() ?? {};
    const severidad = (data.severidad ?? "").toString().toUpperCase();
    if (severidad !== "HIGH") {
      // MEDIUM/LOW no notifican al instante — quedan en el tablero del
      // admin y entran al resumen diario.
      return;
    }

    const patenteRaw = (data.patente ?? "").toString().trim();
    const patente = patenteRaw.toUpperCase();
    const tipo = (data.tipo ?? "").toString();
    if (!patente) {
      logger.info("[onAlertaVolvoCreated] HIGH sin patente, skip", {
        alertId: event.params.alertId,
        tipo,
      });
      return;
    }

    // ─── Filtro de tipos "no para el chofer" ───────────────────────
    // Tipos / subtipos que el chofer NO puede arreglar en ruta. Van
    // solo al jefe de mantenimiento via el cron diario consolidado del
    // bot. Si los mandamos también al chofer, le spameamos sin que
    // pueda hacer nada — caso real (incidente 2026-05-07): Raul
    // recibió 6 mensajes de "Sin AdBlue" en 6 horas porque el camión
    // sigue sin AdBlue y Volvo dispara el evento cada hora.
    //
    // AdBlue (3 tipos) — operación de planta, el chofer no carga
    // AdBlue en ruta. Va al jefe de mantenimiento via cron diario.
    //   - WITHOUT_ADBLUE     ("Sin AdBlue")
    //   - ADBLUELEVEL_LOW    ("AdBlue bajo")
    //   - CATALYST           ("Cambio de nivel AdBlue")
    //
    // Otros del filtro original (legacy 2026-05-03):
    //   - TELL_TALE: testigo del tablero — un sensor intermitente
    //     puede tirar 10-15 eventos por día.
    //   - DRIVING_WITHOUT_BEING_LOGGED_IN: chofer sin loguearse al
    //     TACHÓGRAFO. Vecchi NO enforcea identificación por tacógrafo
    //     porque usa el iButton de Sitrack para identificar al chofer.
    //     El equivalente "no se identificó por iButton" se notifica
    //     desde sitrackPosicionPoller cuando detecta drift_tipo
    //     CHOFER_NO_IDENTIFICADO — usa otra fuente de datos.
    //
    // FUEL ("Cambio anormal de combustible") tampoco llega al chofer:
    // por experiencia operativa de Vecchi, los disparos son ruidosos
    // y el chofer no puede investigar (lo ve el admin en el resumen).
    const TIPOS_BLACKLIST_CHOFER = new Set([
      "WITHOUT_ADBLUE",
      "ADBLUELEVEL_LOW",
      "CATALYST",
      "FUEL",
      "TELL_TALE",
      "DRIVING_WITHOUT_BEING_LOGGED_IN",
    ]);

    // Resolver el "tipo efectivo" para los GENERIC con subtipo.
    let tipoEfectivo = tipo.toUpperCase();
    if (tipo === "GENERIC") {
      // El subtipo viene en `triggerType` (en la data real es SIEMPRE ese
      // campo) o, defensivamente, en `type`. Leemos ambos para no perder el
      // subtipo si Volvo cambia el campo. Igual criterio que
      // volvo_mantenimiento.ts y resumenes_diarios.ts.
      const dg = data.detalle_generic as Record<string, unknown> | undefined;
      const sub = (dg?.triggerType ?? dg?.type ?? "").toString().toUpperCase();
      if (sub) tipoEfectivo = sub;
    }

    if (TIPOS_BLACKLIST_CHOFER.has(tipoEfectivo)) {
      logger.info(
        "[onAlertaVolvoCreated] tipo blacklist al chofer, skip (sigue en tablero + resumen mant)",
        {
          alertId: event.params.alertId,
          patente,
          tipoEfectivo,
        }
      );
      return;
    }

    // ─── BYPASS DE SEGURIDAD (V5, 2026-05-24) ───────────────────────
    // Cuando un chofer DESACTIVA un sistema de asistencia a la
    // conducción (DAS = cansancio, LKS = carril, LCS = cambio carril,
    // AEBS = frenado de emergencia), Volvo emite un evento HIGH con
    // ese tipo. Avisarle al chofer NO sirve — él fue el que lo apagó.
    // En cambio Molina (SEG_HIGIENE) necesita verlo en tiempo real para
    // documentarlo (potencial sanción si el chofer reincide o hay un
    // siniestro). Throttle 6h por (patente, tipo) para que un mismo
    // chofer apagando DAS varias veces en el día no spamee a Molina.
    const TIPOS_BYPASS_SEGURIDAD = new Set([
      "DAS",
      "LKS",
      "LCS",
      "AEBS",
    ]);
    if (TIPOS_BYPASS_SEGURIDAD.has(tipoEfectivo)) {
      try {
        await _notificarBypassSeguridad(
          patente,
          tipoEfectivo,
          (data.chofer_dni ?? "").toString().trim(),
          (data.creado_en as Timestamp | undefined)?.toMillis() ?? Date.now(),
          event.params.alertId,
        );
      } catch (e) {
        logger.warn("[onAlertaVolvoCreated] bypass seguridad falló", {
          alertId: event.params.alertId,
          patente,
          tipoEfectivo,
          error: (e as Error).message,
        });
      }
      return; // No al chofer (él lo apagó).
    }

    // Lookup chofer: priorizamos el `chofer_dni` snapshoteado por
    // `volvoAlertasPoller` al crear la alerta (atribución del chofer del
    // MOMENTO del evento, no el chofer actual asignado). Esto es crítico
    // si el chofer rotó entre la creación de la alerta y este trigger
    // (raro pero posible si el trigger se demora por backlog/quotas).
    //
    // Fallback al lookup por VEHICULO==patente para:
    //  - Alertas viejas pre-snapshot (compatibilidad con docs legacy).
    //  - Caso defensivo si por algún motivo `chofer_dni` quedó vacío.
    //
    // Side benefit: `.doc(id).get()` es lookup por clave (lectura O(1) en
    // Firestore) vs `.where().limit(1)` que igual va a la collection y
    // matchea — la query por ID es más barata.
    const choferDniSnapshot = (data.chofer_dni ?? "").toString().trim();
    let choferDoc;
    if (choferDniSnapshot) {
      const docSnap = await db.collection("EMPLEADOS").doc(choferDniSnapshot).get();
      if (docSnap.exists) {
        choferDoc = docSnap;
      }
    }
    if (!choferDoc) {
      const empleadosSnap = await db
        .collection("EMPLEADOS")
        .where("VEHICULO", "==", patente)
        .limit(1)
        .get();
      if (empleadosSnap.empty) {
        logger.info("[onAlertaVolvoCreated] patente sin chofer asignado", {
          patente,
          tipo,
          intentadoDni: choferDniSnapshot || "(sin snapshot)",
        });
        return;
      }
      choferDoc = empleadosSnap.docs[0];
    }
    const choferData = choferDoc.data() ?? {};

    // Soft-delete: si el chofer fue dado de baja, no le mandamos.
    if (choferData.ACTIVO === false) {
      logger.info("[onAlertaVolvoCreated] chofer inactivo, skip", {
        patente,
        choferDni: choferDoc.id,
      });
      return;
    }

    const telefonoRaw = (choferData.TELEFONO ?? "").toString().trim();
    if (!telefonoRaw || telefonoRaw === "-") {
      logger.info("[onAlertaVolvoCreated] chofer sin TELEFONO", {
        patente,
        choferDni: choferDoc.id,
      });
      return;
    }

    const apodo = (choferData.APODO ?? "").toString().trim();
    const nombreFull = (choferData.NOMBRE ?? "").toString().trim();
    const saludoNombre = apodo || primerNombre(nombreFull) || "";

    const creadoMs =
      (data.creado_en as Timestamp | undefined)?.toMillis() ?? Date.now();
    const horaTxt = formatHoraArg(creadoMs);
    // Fecha explícita DD/MM en lugar de "hoy a las". El bot tiene horario
    // hábil L-V 8-20 y skip fin de semana — un evento del sábado se manda
    // el lunes y "hoy" sería mentira. Con la fecha explícita el chofer
    // siempre sabe a qué momento se refiere el aviso.
    const fechaTxt = formatFechaArg(creadoMs);

    // Nota: NO hay dedup diaria a este nivel — los eventos de manejo
    // (OVERSPEED, IDLING, HARSH, PTO, SEATBELT, etc.) son el insumo
    // principal del seguimiento del chofer. Cada uno se encola y el
    // bot Node.js los AGRUPA al enviarlos (ver `agrupador.js`): si el
    // chofer ya tiene varios PENDIENTES, los combina en un único
    // mensaje "se detectaron N eventos: 5x Exceso, 3x Ralentí...".
    // Eso resuelve el spam sin perder información.
    //
    // Los tipos repetitivos de mantenimiento (Sin AdBlue cada hora,
    // testigo de tablero parpadeante, etc.) NO llegan al chofer
    // gracias a `TIPOS_BLACKLIST_CHOFER` arriba.

    let etiqueta = ETIQUETAS_TIPO_ALERTA[tipo] ?? tipo;
    // subTipoResolvido se guarda en COLA_WHATSAPP como `alert_sub_tipo`
    // para que el agrupador del bot (agrupador.js) pueda mostrar la
    // etiqueta correcta cuando combina varios HIGH del mismo chofer
    // (ej: 3x "Cinturón..." en lugar de 3x "Evento genérico").
    let subTipoResolvido: string | null = null;
    if (tipo === "GENERIC") {
      const triggerType = (
        (data.detalle_generic as Record<string, unknown> | undefined)
          ?.triggerType ?? ""
      ).toString().toUpperCase();
      if (triggerType) {
        subTipoResolvido = triggerType;
        etiqueta =
          ETIQUETAS_TIPO_ALERTA[triggerType] ??
          `Evento genérico (${triggerType})`;
      }
    }

    // Variantes random del mensaje — anti-baneo de WhatsApp. Mandar el
    // MISMO texto a múltiples destinatarios en poco tiempo es señal
    // típica de spam y dispara bandera. Cuanto más variantes, menos
    // probable que dos mensajes consecutivos sean iguales. Pasamos de
    // 3 a 8 redacciones con mismo contenido informativo.
    const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";
    const variantes = [
      `${saludo},\n\n` +
        `Se detectó un evento de manejo en el TRACTOR ${patente} ` +
        `el ${fechaTxt} a las ${horaTxt}:\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Te pedimos ajustar tu manejo. Si hubo una situación particular, " +
        "avisanos a la oficina.\n\n" +
        BANNER_TESTING + "_Bot-On — Coopertrans Móvil_",
      `${saludo}.\n\n` +
        `Aviso desde la oficina: el ${fechaTxt} a las ${horaTxt} se ` +
        `registró un evento en el tractor ${patente}.\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Si hubo algo particular contanos en la oficina; si no, te " +
        "pedimos prestar atención al manejo.\n\n" +
        BANNER_TESTING + "_Bot-On — Coopertrans Móvil_",
      `${saludo}, te escribo desde la oficina.\n\n` +
        `Volvo registró un evento en el tractor ${patente} ` +
        `el ${fechaTxt} a las ${horaTxt}:\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Cualquier comentario sobre la situación, mejor en la oficina.\n\n" +
        BANNER_TESTING + "_Bot-On — Coopertrans Móvil_",
      `${saludo}, ¿cómo va el día?\n\n` +
        `Recibimos un aviso del tractor ${patente} ` +
        `(${fechaTxt} a las ${horaTxt}):\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Si pasó algo puntual contanos. Si no, prestá atención al " +
        "próximo tramo.\n\n" +
        BANNER_TESTING + "_Bot-On — Coopertrans Móvil_",
      `${saludo}.\n\n` +
        `Te avisamos: el tractor ${patente} disparó un evento ` +
        `el ${fechaTxt} ${horaTxt}.\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Acordate de revisar tu manejo. Cualquier cosa nos contás " +
        "en la oficina.\n\n" +
        BANNER_TESTING + "_Bot-On — Coopertrans Móvil_",
      `${saludo},\n\n` +
        `Llegó un alerta del tractor ${patente} ` +
        `(${fechaTxt}, ${horaTxt}):\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Te pedimos un manejo más cuidadoso en lo que sigue. Si hubo " +
        "una situación particular, escribinos.\n\n" +
        BANNER_TESTING + "_Bot-On — Coopertrans Móvil_",
      `${saludo}.\n\n` +
        `Saltó un evento en el TRACTOR ${patente} hoy ` +
        `${horaTxt} (${fechaTxt}):\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Si fue una maniobra obligada por el tránsito, dejame saber. " +
        "Si no, ajustá tu manejo en lo que viene.\n\n" +
        BANNER_TESTING + "_Bot-On — Coopertrans Móvil_",
      `${saludo}, te paso un aviso desde la oficina.\n\n` +
        `Detectamos un evento en el tractor ${patente} ` +
        `el ${fechaTxt} a las ${horaTxt}:\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Te pedimos ir más tranquilo. Cualquier comentario lo charlamos.\n\n" +
        BANNER_TESTING + "_Bot-On — Coopertrans Móvil_",
    ];
    const mensaje = variantes[rrPick(variantes.length)];

    // ─── Silencio del chofer (chequeo PRE-claim) ───────────────────
    // BOT_SILENCIADOS_CHOFER debe valer para TODOS los avisos
    // automáticos — si /silenciar fue aplicado, el chofer NO recibe
    // alertas Volvo HIGH. Bug-tipo "Horacio 2026-05-14" (ver
    // _encolarAvisoChoferNoIdentificado): se silencia pero seguía
    // recibiendo. Fix 2026-05-18 (Fase auditoría 24/7) — agregado
    // chequeo acá. No tomamos el claim si está silenciado: el evento
    // ya ocurrió, si el silencio se levanta más tarde no vale enviar
    // el aviso tarde.
    try {
      const silSnap = await db
        .collection("BOT_SILENCIADOS_CHOFER")
        .doc(choferDoc.id)
        .get();
      if (silSnap.exists) {
        const hasta = silSnap.data()?.silenciado_hasta;
        if (hasta && typeof hasta.toMillis === "function" &&
            hasta.toMillis() > Date.now()) {
          logger.info(
            "[onAlertaVolvoCreated] chofer silenciado, skip aviso",
            { choferDni: choferDoc.id, alertId: event.params.alertId, patente }
          );
          return;
        }
      }
    } catch (e) {
      // Si falla el read NO bloqueamos — peor caso le llega un aviso
      // que el admin pidió silenciar (UX degradada vs no avisar nada).
      logger.warn(
        "[onAlertaVolvoCreated] no pude leer BOT_SILENCIADOS_CHOFER, sigo",
        { choferDni: choferDoc.id, error: (e as Error).message }
      );
    }

    // ─── Backstop anti-rafaga (server-side) ────────────────────────
    // Si el agrupador del bot falla, este chequeo evita que un chofer
    // reciba >10 alertas Volvo HIGH por hora. Cuenta los docs
    // PENDIENTE/ENVIADO con origen=volvo_alert_high para este chofer
    // en la ultima hora. Si supera el umbral, NO encola y NO toma
    // claim (el evento queda visible en VOLVO_ALERTAS y en el
    // tablero admin, solo no se manda al chofer por WhatsApp).
    try {
      const cutoff = Timestamp.fromMillis(
        Date.now() - VOLVO_HIGH_THROTTLE_VENTANA_SEG * 1000
      );
      const recientesSnap = await db.collection("COLA_WHATSAPP")
        .where("origen", "==", "volvo_alert_high")
        .where("destinatario_id", "==", choferDoc.id)
        .where("encolado_en", ">=", cutoff)
        .count()
        .get();
      const recientes = recientesSnap.data().count;
      if (recientes >= VOLVO_HIGH_THROTTLE_HORA_MAX) {
        logger.warn(
          "[onAlertaVolvoCreated] throttle 1h alcanzado, skip aviso",
          {
            choferDni: choferDoc.id,
            alertId: event.params.alertId,
            patente,
            recientes,
            limite: VOLVO_HIGH_THROTTLE_HORA_MAX,
          }
        );
        return;
      }
    } catch (e) {
      // Si la query del throttle falla (sin indice, Firestore down),
      // NO bloqueamos. Defensa en profundidad — el agrupador del bot
      // sigue siendo defensor principal.
      logger.warn(
        "[onAlertaVolvoCreated] throttle check fallo, sigo",
        { choferDni: choferDoc.id, error: (e as Error).message }
      );
    }

    // ─── Idempotencia atómica ──────────────────────────────────────
    // Claim por alertId: si ya hay un doc con este ID, es un retry
    // de Cloud Functions sobre el mismo evento — salimos antes de
    // encolar de nuevo. Si encolar falla más abajo, borramos el
    // claim para que el retry siguiente pueda reintentar.
    const claimRef = db
      .collection("META_ALERTAS_VOLVO_NOTIFICADAS")
      .doc(event.params.alertId);
    try {
      await claimRef.create({
        tomado_en: FieldValue.serverTimestamp(),
        chofer_dni: choferDoc.id,
        patente,
        tipo,
      });
    } catch (e) {
      const msg = (e as Error).message || "";
      const code = (e as { code?: number }).code;
      if (
        code === 6 ||
        msg.includes("ALREADY_EXISTS") ||
        msg.includes("already exists")
      ) {
        logger.info(
          "[onAlertaVolvoCreated] retry de evento ya procesado, skip",
          { alertId: event.params.alertId },
        );
        return;
      }
      throw e;
    }

    try {
      const colaRef = await db.collection("COLA_WHATSAPP").add({
        telefono: telefonoRaw,
        mensaje,
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
        expira_en: expiraEnMin(TTL_VOLVO_MANEJO_MIN),
        enviado_en: null,
        error: null,
        intentos: 0,
        origen: "volvo_alert_high",
        destinatario_coleccion: "EMPLEADOS",
        destinatario_id: choferDoc.id,
        campo_base: "VOLVO_ALERT_HIGH",
        admin_dni: "BOT",
        admin_nombre: "Bot automatico",
        // Metadata para auditoria / debugging.
        alert_id: event.params.alertId,
        alert_tipo: tipo,
        // Subtipo resuelto cuando tipo === GENERIC (SEATBELT, TELL_TALE,
        // etc). Lo usa el agrupador del bot para no colapsar todos los
        // GENERIC en "Evento genérico" cuando agrupa varios eventos.
        alert_sub_tipo: subTipoResolvido,
        alert_patente: patente,
        // Timestamp del evento real (no del encolado) — usado por el
        // agrupador del bot para armar el mensaje combinado con horas
        // correctas si el chofer recibe varios eventos juntos.
        alert_creado_en: Timestamp.fromMillis(creadoMs),
      });
      logger.info("[onAlertaVolvoCreated] OK encolado para chofer", {
        alertId: event.params.alertId,
        patente,
        tipo,
        choferDni: choferDoc.id,
        colaDocId: colaRef.id,
      });
    } catch (e) {
      logger.error("[onAlertaVolvoCreated] no se pudo encolar", {
        alertId: event.params.alertId,
        patente,
        error: (e as Error).message,
      });
      // Si fallo el encolado, borrar el claim para que el retry de
      // GCF pueda reintentar (sin borrar, el retry verìa el claim y
      // saltarìa, perdiendo el aviso al chofer).
      await claimRef.delete().catch((e2) => {
        // best-effort: si no se puede borrar, el siguiente retry
        // tira ALREADY_EXISTS y skipea, pero al menos queda log.
        logger.warn("[onAlertaVolvoCreated] no se pudo borrar claim", {
          alertId: event.params.alertId,
          error: (e2 as Error).message,
        });
      });
      // No re-throw: el trigger no debe reintentar agresivamente.
      // Si el encolado falla, queda registro en el log y la alerta
      // sigue visible en el tablero del admin.
    }
  }
);

/**
 * Round-robin determinístico para elegir variantes anti-baneo.
 *
 * Antes usábamos Math.random() — en ráfagas (vigilador detecta varios
 * choferes excediendo en el mismo poll, alertas Volvo en paralelo)
 * había chance ~1/N de que dos mensajes consecutivos tocaran la
 * misma variante, patrón de spam para WhatsApp. Round-robin garantiza
 * que las primeras N llamadas tocan las N variantes distintas, sin
 * repetición predecible.
 *
 * Counter persiste en memoria del Cloud Function — Cloud Run mantiene
 * la instancia caliente entre invocaciones cercanas, así que en
 * ráfagas el counter avanza aunque sean llamadas separadas. Si la
 * instancia se enfría y arranca otra fría, vuelve a 0 — eso es OK,
 * lo importante es la diversidad dentro de la ráfaga.
 */
// _rrPick, _primerNombre, _formatHoraArg movidos a helpers.ts
// (refactor 2026-05-18). Importados arriba como rrPick / primerNombre
// / formatHoraArg.


// _formatFechaArg movido a helpers.ts (refactor 2026-05-18) como formatFechaArg.

// ============================================================================
// volvoScoresPoller — eco-driving (Volvo Group Scores API v2.0.2)
// ============================================================================
// Scheduled function que cada día a las 04:00 ART pollea la Volvo Group
// Scores API (`/score/scores`) con `starttime=ayer&stoptime=ayer` y persiste
// el score AGREGADO POR DÍA de cada vehículo + el de la flota.
//
// A diferencia de `volvoAlertasPoller` (eventos discretos en tiempo real),
// la Scores API devuelve un AGREGADO DIARIO precalculado por Volvo:
//   - 1 score "total" 0-100 por vehículo o flota.
//   - 17+ sub-scores (anticipation, braking, coasting, idling, overspeed,
//     cruiseControl, etc.) — el algoritmo es propietario de Volvo.
//   - Métricas operativas crudas (totalDistance, avgFuelConsumption,
//     totalTime, vehicleUtilization, co2Emissions).
//
// Por qué a las 04:00 ART:
//   La API espera que el día calendario haya cerrado y los datos hayan
//   llegado a la nube de Volvo. 04:00 da margen para que telemetría
//   rezagada del día anterior ya esté procesada del lado de Volvo.
//
// Idempotencia:
//   - DocId composite `{patente}_{YYYY-MM-DD}` para vehículos y
//     `_FLEET_{YYYY-MM-DD}` para el agregado de flota.
//   - Si la function corre dos veces el mismo día (retry, manual run),
//     mismo docId → sobrescribe. Sin campos de gestión humana acá, es
//     seguro sobrescribir.

const ACCEPT_SCORES =
  "application/x.volvogroup.com.scores.v2.0+json; UTF-8";

interface ScoresApiVehicleScore extends Record<string, unknown> {
  vin: string;
  scores?: Record<string, number>;
  totalTime?: number;
  avgSpeedDriving?: number;
  totalDistance?: number;
  avgFuelConsumption?: number;
  avgFuelConsumptionGaseous?: number;
  avgElectricEnergyConsumption?: number;
  vehicleUtilization?: number;
  co2Emissions?: number;
  co2Saved?: number;
}

interface ScoresApiFleetScore extends Record<string, unknown> {
  scores?: Record<string, number>;
  totalTime?: number;
  avgSpeedDriving?: number;
  totalDistance?: number;
  avgFuelConsumption?: number;
  avgFuelConsumptionGaseous?: number;
  avgElectricEnergyConsumption?: number;
  vehicleUtilization?: number;
  co2Emissions?: number;
  co2Saved?: number;
}

interface ScoresApiResponse {
  vuScoreResponse?: {
    startTime?: string;
    stopTime?: string;
    fleet?: ScoresApiFleetScore;
    vehicles?: ScoresApiVehicleScore[];
    moreDataAvailable?: boolean;
    moreDataAvailableLink?: string;
  };
}

const SCORES_MAX_PAGES_PER_RUN = 10;

export const volvoScoresPoller = onSchedule(
  {
    schedule: "0 4 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [volvoUsername, volvoPassword],
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async () => {
    // Lock tick (auditoría 2026-06-04): cron diario con timeout 120s, pero
    // un cold start + paginado de hasta 10 páginas del API Volvo puede
    // excederse. GCP at-least-once puede disparar 2 invocaciones que pisan
    // los mismos docs VOLVO_SCORES_DIARIOS con escrituras redundantes. Lock
    // 4 min evita el solapado (consistencia con los otros pollers Volvo).
    const liberar = await adquirirLockTick(
      "volvo_scores_poller",
      4 * 60 * 1000,
    );
    if (!liberar) return;
    try {
      // Calculamos "ayer" en ART. La API espera fechas YYYY-MM-DD en TZ
      // de la flota. Ejemplo: corre el 2026-05-03 04:00 ART → pedimos
      // los scores del día 2026-05-02 (cerrado).
      const fechaYmd = ayerYmdArg();

      logger.info("[volvoScoresPoller] iniciando ciclo", { fecha: fechaYmd });

      // Cross-ref VIN → patente. Mismo patrón que volvoAlertasPoller.
      // .limit(5000) defensivo — ver comentario en telemetriaSnapshotScheduled.
      const vehiculosSnap = await db.collection("VEHICULOS").limit(5000).get();
      const vinToPatente = new Map<string, string>();
      for (const doc of vehiculosSnap.docs) {
        const data = doc.data();
        const vin = (data.VIN ?? "").toString().trim().toUpperCase();
        if (vin && vin !== "-") {
          vinToPatente.set(vin, doc.id);
        }
      }

      const authHeader = "Basic " + Buffer.from(
        `${volvoUsername.value()}:${volvoPassword.value()}`
      ).toString("base64");

      const qsInicial = new URLSearchParams({
        starttime: fechaYmd,
        stoptime: fechaYmd,
        contentFilter: "FLEET,VEHICLES",
      });
      let url = `${VOLVO_BASE}/score/scores?${qsInicial.toString()}`;

      const fechaTs = Timestamp.fromDate(inicioDelDiaArg(fechaYmd));
      let totalEscritos = 0;
      let pages = 0;
      let fleetEscrita = false;

      while (pages < SCORES_MAX_PAGES_PER_RUN) {
        pages++;

        let res: Response;
        try {
          // Cron diario con timeout 120s: 2 reintentos entran holgados.
          res = await fetchConReintentos(url, {
            method: "GET",
            headers: { Authorization: authHeader, Accept: ACCEPT_SCORES },
          }, { tag: "volvoScoresPoller", intentos: 3, esperaBaseMs: 5_000 });
        } catch (e) {
          const transient = esErrorTransient(e);
          const log = transient ? logger.warn : logger.error;
          log("[volvoScoresPoller] fetch falló", {
            page: pages,
            error: (e as Error).message,
            transient,
          });
          return;
        }

        if (!res.ok) {
          logger.warn("[volvoScoresPoller] Volvo HTTP error", {
            statusCode: res.status,
            page: pages,
          });
          return;
        }

        const body = (await res.json()) as ScoresApiResponse;
        const response = body.vuScoreResponse ?? {};

        // Persistir el score de la FLOTA (solo en la primera página, no
        // se repite en páginas siguientes según el spec).
        if (!fleetEscrita && response.fleet) {
          await db
            .collection("VOLVO_SCORES_DIARIOS")
            .doc(`_FLEET_${fechaYmd}`)
            .set(
              {
                ...buildScoreFleetDoc(response.fleet, fechaYmd, fechaTs),
                polled_en: FieldValue.serverTimestamp(),
              },
              { merge: true }
            );
          fleetEscrita = true;
          totalEscritos++;
        }

        // Persistir scores por vehículo en batch.
        const vehicles = Array.isArray(response.vehicles) ?
          response.vehicles : [];
        if (vehicles.length > 0) {
          const batch = db.batch();
          let escritosEstePage = 0;
          for (const v of vehicles) {
            const vin = (v.vin ?? "").toString().trim().toUpperCase();
            if (!vin) continue;
            const patente = vinToPatente.get(vin) || vin;
            const docId = `${patente}_${fechaYmd}`;
            const ref = db.collection("VOLVO_SCORES_DIARIOS").doc(docId);
            batch.set(
              ref,
              {
                ...buildScoreVehicleDoc(v, patente, fechaYmd, fechaTs),
                polled_en: FieldValue.serverTimestamp(),
              },
              { merge: true }
            );
            escritosEstePage++;
          }
          if (escritosEstePage > 0) {
            await batch.commit();
            totalEscritos += escritosEstePage;
          }
        }

        const moreData = response.moreDataAvailable === true;
        const moreLink = response.moreDataAvailableLink;
        if (!moreData || !moreLink) break;
        url = `${VOLVO_BASE}${moreLink}`;
      }

      logger.info("[volvoScoresPoller] OK", {
        fecha: fechaYmd,
        paginas: pages,
        escritos: totalEscritos,
        fleetEscrita,
      });
    } finally {
      await liberar();
    }
  }
);

// _ayerYmdArg + _inicioDelDiaArg movidos a helpers.ts (refactor 2026-05-18)
// como ayerYmdArg / inicioDelDiaArg.

function buildScoreVehicleDoc(
  v: ScoresApiVehicleScore,
  patente: string,
  fechaYmd: string,
  fechaTs: Timestamp
): Record<string, unknown> {
  return {
    vin: (v.vin ?? "").toString().trim().toUpperCase(),
    patente,
    fecha: fechaYmd,
    fecha_ts: fechaTs,
    scores: v.scores ?? {},
    totalTime: v.totalTime ?? null,
    avgSpeedDriving: v.avgSpeedDriving ?? null,
    totalDistance: v.totalDistance ?? null,
    avgFuelConsumption: v.avgFuelConsumption ?? null,
    avgFuelConsumptionGaseous: v.avgFuelConsumptionGaseous ?? null,
    avgElectricEnergyConsumption: v.avgElectricEnergyConsumption ?? null,
    vehicleUtilization: v.vehicleUtilization ?? null,
    co2Emissions: v.co2Emissions ?? null,
    co2Saved: v.co2Saved ?? null,
  };
}

function buildScoreFleetDoc(
  f: ScoresApiFleetScore,
  fechaYmd: string,
  fechaTs: Timestamp
): Record<string, unknown> {
  return {
    es_fleet: true,
    fecha: fechaYmd,
    fecha_ts: fechaTs,
    scores: f.scores ?? {},
    totalTime: f.totalTime ?? null,
    avgSpeedDriving: f.avgSpeedDriving ?? null,
    totalDistance: f.totalDistance ?? null,
    avgFuelConsumption: f.avgFuelConsumption ?? null,
    avgFuelConsumptionGaseous: f.avgFuelConsumptionGaseous ?? null,
    avgElectricEnergyConsumption: f.avgElectricEnergyConsumption ?? null,
    vehicleUtilization: f.vehicleUtilization ?? null,
    co2Emissions: f.co2Emissions ?? null,
    co2Saved: f.co2Saved ?? null,
  };
}


// MANTENIMIENTO_DESTINATARIO_DNI + SEG_HIGIENE_DESTINATARIO_DNI movidos
// a comun.ts (split 2026-05-19).

// Vigilador de jornada del chofer — REFACTOR 2026-05-15.
//
// Modelo operativo de Vecchi (alineado con norma YPF NO_0002913 +
// excepción Rev01 firmada para carga general):
//
//   Una JORNADA = 24 hs = 12 hs conducción + 12 hs descanso.
//   12 hs conducción = 3 BLOQUES de 4 hs cada uno:
//     - Cada bloque: 3h45 manejo activo + 15 min descanso obligatorio.
//     - Total manejo neto por jornada: 11h15 min.
//   12 hs descanso entre jornadas: mínimo 8 hs con camión detenido
//   en MISMA posición (radio 1000 m, margen GPS drift).
//
// La jornada NO se mide por día calendario. Cada jornada es lógica
// y se identifica por su `jornada_inicio_ts`. La colección nueva
// `JORNADAS` reemplaza a `JORNADAS_CHOFER` (legacy, deprecated).
//
// Disparadores que detienen al chofer (cualquiera de los 3):
//   1. Cumplió 3 bloques → cuota cumplida.
//   2. Hora ART >= 00:00 → veda nocturna (política Vecchi: no se
//      maneja después de medianoche).
//   3. Bloque actual llegó a 4 hs sin pausa de 15 min → infracción.
//
// Reanudación de conducción: solo después de ≥ 8 hs detenido en misma
// posición. Eso cierra la jornada actual y abre una nueva con cuota
// fresca de 3 bloques.













// Throttle del aviso "pasá el iButton" (drift CHOFER_NO_IDENTIFICADO).
// El cron sitrackPosicionPoller corre cada 5 min — sin throttle, un
// chofer que maneja sin pasar el iButton recibe 1 mensaje cada 5 min,
// que es spam y dispara baneo de WhatsApp. Decisión Vecchi 2026-05-07:
// 1 mensaje cada 30 min como máximo por chofer.

const TTL_VOLVO_MANEJO_MIN = 120; // OVERSPEED, IDLING, HARSH, PTO
// TTL_RESUMEN_DIARIO_MIN movido a comun.ts (split 2026-05-19).
// Note: TTL_SILENCIO_REANUDADO esta inline en expiraEnMin(60)
// en el aviso `silencio_reanudado` (~linea 5370).

// Backstop anti-rafaga Volvo HIGH (Fase auditoria 24/7 2026-05-18):
// el agrupador del bot consumer-side es el defensor principal contra
// "chofer recibe 8 mensajes Volvo seguidos". Pero si el agrupador
// tiene un bug, falla, o cambia su logica, este backstop server-side
// evita que se encolen mas de N alertas Volvo HIGH por chofer/hora.
// Limite generoso (10/hora) — solo bloquea el escenario patologico,
// no afecta operacion normal (un chofer agresivo dispara 2-3 eventos
// HIGH/hora maximo).
const VOLVO_HIGH_THROTTLE_HORA_MAX = 10;
const VOLVO_HIGH_THROTTLE_VENTANA_SEG = 60 * 60; // 1h rolling

// _expiraEnMinutos movido a helpers.ts (refactor 2026-05-18) como expiraEnMin.

// ── onAlertaVolvoMantenimientoCreated ELIMINADO (auditoría 2026-05-30) ──
// Era un trigger onDocumentCreated sobre VOLVO_ALERTAS que había quedado NO-OP:
// solo logueaba. El "Parte de mantenimiento" lo arma el cron diario
// resumenMantenimientoVehiculosDiario (volvo_mantenimiento.ts), no este trigger.
// Pagaba una invocación + cold-start por CADA alerta Volvo sin hacer nada útil.
// Se quitaron también sus helpers exclusivos (_esAlertaMantenimiento,
// TIPOS_MANTENIMIENTO_DIRECTOS, SUBTIPOS_GENERIC_MANTENIMIENTO).

// ============================================================================
// Bypass de seguridad: notificar a Molina cuando un chofer desactiva un
// sistema de asistencia (DAS / LKS / LCS / AEBS). Helper privado usado
// solo por onAlertaVolvoCreated (V5, 2026-05-24).
// ============================================================================

/** Throttle entre avisos del MISMO (patente, tipo). 6h = no más de 4
 *  avisos por día por unidad y tipo. Suficiente para registrar el
 *  incidente sin spamear si el chofer apaga DAS varias veces seguidas. */
const BYPASS_SEGURIDAD_THROTTLE_HS = 6;
const TTL_BYPASS_SEGURIDAD_MIN = 60;

const ETIQUETA_BYPASS: Record<string, string> = {
  DAS: "alerta de cansancio (DAS)",
  LKS: "asistente de carril (LKS)",
  LCS: "asistente de cambio de carril (LCS)",
  AEBS: "frenado automático de emergencia (AEBS)",
};

async function _notificarBypassSeguridad(
  patente: string,
  tipoEfectivo: string,
  choferDniSnapshot: string,
  creadoMs: number,
  alertId: string,
): Promise<void> {
  // M9 — pausa por canal. Si el admin pausó este canal (testing del
  // módulo Volvo, por ejemplo), salteamos el aviso silenciosamente. La
  // pantalla pinta este canal en rojo porque silencia un aviso de
  // seguridad — usar con cuidado.
  if (await estaCanalPausado("bypassSeguridad")) {
    logger.info("[bypassSeguridad] canal pausado, skip", {
      alertId, patente, tipoEfectivo,
    });
    return;
  }

  // Throttle: clave determinística (patente, tipo) — el lock está en
  // META_BYPASS_SEGURIDAD con expira_en para que TTL Firestore lo
  // limpie solo (sin cron de purga).
  const throttleId = `${patente}_${tipoEfectivo}`;
  const throttleRef = db.collection("META_BYPASS_SEGURIDAD").doc(throttleId);
  const throttleSnap = await throttleRef.get();
  if (throttleSnap.exists) {
    const lastSentAt = throttleSnap.data()?.last_sent_at;
    if (lastSentAt && typeof lastSentAt.toMillis === "function") {
      const horasDesde = (Date.now() - lastSentAt.toMillis()) / 3600000;
      if (horasDesde < BYPASS_SEGURIDAD_THROTTLE_HS) {
        logger.info("[bypassSeguridad] throttled", {
          alertId, patente, tipoEfectivo,
          horasDesdeUltimo: horasDesde.toFixed(1),
        });
        return;
      }
    }
  }

  // Lookup destinatario seguridad e higiene (Molina por default,
  // override M5 desde Firestore).
  const seguridadDni = await obtenerDestinatarioDni(
    "bypassSeguridad", SEG_HIGIENE_DESTINATARIO_DNI,
  );
  const molinaSnap = await db
    .collection("EMPLEADOS")
    .doc(seguridadDni)
    .get();
  if (!molinaSnap.exists) {
    logger.warn("[bypassSeguridad] destinatario SEG_HIGIENE no existe", {
      dni: seguridadDni,
    });
    return;
  }
  const tel = (molinaSnap.data()?.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") {
    logger.warn("[bypassSeguridad] destinatario SEG_HIGIENE sin teléfono");
    return;
  }

  // Resolver nombre del chofer (opcional, mensaje más útil).
  let choferNombre = "(chofer no identificado)";
  if (choferDniSnapshot) {
    const empSnap = await db.collection("EMPLEADOS")
      .doc(choferDniSnapshot).get();
    if (empSnap.exists) {
      const n = (empSnap.data()?.NOMBRE ?? "").toString().trim();
      if (n) choferNombre = n;
    }
  }

  const horaTxt = formatHoraArg(creadoMs);
  const fechaTxt = formatFechaArg(creadoMs);
  const etiquetaSistema =
    ETIQUETA_BYPASS[tipoEfectivo] ?? tipoEfectivo;

  const mensaje =
    "⚠️ *Bypass de seguridad detectado*\n\n" +
    `Sistema desactivado: *${etiquetaSistema}*\n` +
    `Unidad: ${patente}\n` +
    `Chofer: ${choferNombre}\n` +
    `Cuándo: ${fechaTxt} ${horaTxt}\n\n` +
    "Cuando un chofer desactiva un sistema de asistencia, Volvo lo " +
    "reporta como evento HIGH. Documentado para revisión / sanción.\n\n" +
    BANNER_TESTING +
    "_Bot-On — Coopertrans Móvil_";

  try {
    await db.collection("COLA_WHATSAPP").add({
      telefono: tel,
      mensaje,
      estado: "PENDIENTE",
      encolado_en: FieldValue.serverTimestamp(),
      expira_en: expiraEnMin(TTL_BYPASS_SEGURIDAD_MIN),
      enviado_en: null,
      error: null,
      intentos: 0,
      origen: "bypass_seguridad",
      destinatario_coleccion: "EMPLEADOS",
      destinatario_id: seguridadDni,
      campo_base: "BYPASS_SEGURIDAD",
      admin_dni: "BOT",
      admin_nombre: "Bot Volvo",
      alert_patente: patente,
      alert_tipo: tipoEfectivo,
      alert_id: alertId,
    });
  } catch (e) {
    logger.warn("[bypassSeguridad] add a COLA falló", {
      patente, tipoEfectivo, error: (e as Error).message,
    });
    return;
  }

  // Marcar throttle: 6h hasta el próximo aviso de esta (patente, tipo).
  // `expira_en` para que el TTL de Firestore limpie el doc solo (sin cron
  // de purga) — mismo window que el throttle (BYPASS_SEGURIDAD_THROTTLE_HS).
  await throttleRef.set({
    last_sent_at: FieldValue.serverTimestamp(),
    last_patente: patente,
    last_tipo: tipoEfectivo,
    last_alert_id: alertId,
    expira_en: expiraEnMin(BYPASS_SEGURIDAD_THROTTLE_HS * 60),
  });
}
