/**
 * Cloud Functions de Coopertrans Móvil.
 *
 * Endpoints expuestos:
 *   - `loginConDni`: emite custom token de Firebase Auth a partir de
 *     un par DNI + contraseña (con rate limit + migración bcrypt).
 *   - `volvoProxy`: llama la API de Volvo Connect en nombre del admin
 *     manteniendo las credenciales server-side (Secret Manager).
 *   - `auditLogWrite`: escribe entradas en AUDITORIA_ACCIONES con el
 *     DNI/nombre del admin tomado del JWT (no del cliente). Permite
 *     cerrar la rule de esa colección a `write: if false`.
 *   - `telemetriaSnapshotScheduled`: cron cada 6h que escribe a
 *     TELEMETRIA_HISTORICO via Admin SDK.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import {
  FieldValue,
  Timestamp,
} from "firebase-admin/firestore";

// Setup global (initializeApp + setGlobalOptions + instancias db/auth +
// constants compartidos). Importarlo PRIMERO garantiza que initializeApp
// corre antes de cualquier acceso a Firestore. Refactor 2026-05-18 —
// antes vivía inline acá. Ver setup.ts para detalle.
import { db, BANNER_TESTING } from "./setup";

// Vigilador de jornada v2 (refactor 2026-05-15). La lógica completa
// (bloques 3×4h, descanso 8h misma posición, veda nocturna 00:00 ART)
// vive en `jornadas_v2.ts` y se invoca desde `mantenimiento.ts` /
// `resumenes_diarios.ts`. Acá no se usa directo desde el refactor
// 2026-05-18 (post-split del archivo).

// Helpers compartidos con jornadas_v2.ts (antes vivían duplicados aca
// con leves diferencias - drift). Refactor 2026-05-18, ver helpers.ts
// para historia detallada.
import {
  ayerYmdArg,
  expiraEnMin,
  formatFechaArg,
  formatHoraArg,
  inicioDelDiaArg,
  primerNombre,
  rrPick,
} from "./helpers";

// ────────────────────────────────────────────────────────────────────
// Split del archivo (refactor 2026-05-18):
//   index.ts era 6884 LOC con 31 cloud functions. Partido en archivos
//   por área temática para que cada uno apunte a ~500-1500 LOC navegable.
//   Cada módulo se importa con `export *` desde acá para que Firebase
//   siga viendo los exports en el entry point oficial.
//
//   Módulos extraidos hasta acá:
//     - auth.ts              (login + passwords + roles + rename DNI + helpers)
//     - cleanup_y_recibos.ts (asignarNumeroReciboAdelanto + purgarColaWhatsappAntigua)
//     - dashboard_stats.ts   (recomputeDashboardStats + helpers)
//     - icm.ts               (recomputeIcmSemanalScheduled + helpers)
//     - mantenimiento.ts     (backup + bot_health + vigilador jornadas wrappers)
//     - sitrack.ts           (sitrackPosicionPoller + sitrackEventosPoller)
//     - resumenes_diarios.ts (4 resúmenes diarios 08:00 ART)
// ────────────────────────────────────────────────────────────────────
// auth.ts va PRIMERO: exporta `hashId`, que icm.ts y sitrack.ts importan
// vía "./index". Re-exportarlo antes evita sorpresas de orden de carga.
export * from "./auth";
export * from "./cleanup_y_recibos";
export * from "./dashboard_stats";
export * from "./icm";
export * from "./mantenimiento";
export * from "./sitrack";
export * from "./resumenes_diarios";


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

const volvoUsername = defineSecret("VOLVO_USERNAME");
const volvoPassword = defineSecret("VOLVO_PASSWORD");

const VOLVO_BASE = "https://api.volvotrucks.com";
const ACCEPT_VEHICLES =
  "application/x.volvogroup.com.vehicles.v1.0+json; UTF-8";
const ACCEPT_STATUSES =
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
// telemetriaSnapshotScheduled
// ============================================================================
// Scheduled function que cada 6 horas:
//   1) Llama Volvo `/vehicle/vehicles` con secrets server-side.
//   2) Cruza con la colección VEHICULOS para mapear VIN → patente.
//   3) Escribe un snapshot idempotente por día y patente en
//      TELEMETRIA_HISTORICO (id `{patente}_{YYYY-MM-DD}`).
//
// Reemplaza la lógica que antes corría en el cliente Flutter
// (`AutoSyncService` → `VehiculoRepository.guardarSnapshotsDiarios`).
// Vivir server-side permite:
//   - Cerrar `TELEMETRIA_HISTORICO` con `write: if false` en las rules
//     (solo Admin SDK puede escribir).
//   - Que el snapshot se capture aún cuando ningún admin tenga la app
//     abierta.
//
// Frecuencia: cada 6 horas. El doc es idempotente por día, con lo cual
// múltiples corridas se sobreescriben. La frecuencia da resiliencia
// ante fallos puntuales sin generar costos significativos (4 calls
// Volvo + 4 batch writes por día).

export const telemetriaSnapshotScheduled = onSchedule(
  {
    schedule: "every 6 hours",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [volvoUsername, volvoPassword],
    // Bajado de 120s a 45s. La function hace fetch a Volvo + batch
    // write a Firestore. Ambas operaciones nunca tardaron mas de 20s
    // en operacion normal; 45s deja margen para latencia alta sin
    // pagar 75s de invocacion innecesarios.
    timeoutSeconds: 45,
    memory: "256MiB",
  },
  async () => {
    logger.info("[telemetriaSnapshot] iniciando ciclo");

    // ─── 1. Fetch flota Volvo ──────────────────────────────────────
    const authHeader = "Basic " + Buffer.from(
      `${volvoUsername.value()}:${volvoPassword.value()}`
    ).toString("base64");

    // El endpoint `/vehicle/vehicles` NO trae telemetría (solo metadata
    // como vin/marca/modelo). Para `accumulatedData.totalFuelConsumption`
    // y `hrTotalVehicleDistance` hay que pegarle a `/vehicle/vehiclestatuses`
    // con `latestOnly=true` (devuelve el último snapshot de cada unidad
    // en una sola request).
    // Bug M5 del code review: antes el fetch a Volvo se hacía una sola
    // vez. Si fallaba transient (timeout, glitch del API, latencia)
    // perdíamos el snapshot del día. Ahora hacemos hasta 3 intentos
    // con backoff exponencial (5s, 15s) antes de abortar.
    const qs = new URLSearchParams({
      latestOnly: "true",
      contentFilter: "ACCUMULATED,SNAPSHOT,UPTIME",
      additionalContent: "VOLVOGROUPSNAPSHOT",
    });
    const url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;

    let cache: unknown[] = [];
    let intentos = 0;
    const maxIntentos = 3;

    while (intentos < maxIntentos) {
      intentos++;
      try {
        const res = await fetchWithTimeout(url, {
          method: "GET",
          headers: {
            "Authorization": authHeader,
            "Accept": ACCEPT_STATUSES,
          },
        });
        if (!res.ok) {
          logger.warn("[telemetriaSnapshot] Volvo HTTP error", {
            statusCode: res.status,
            intento: intentos,
          });
          if (intentos >= maxIntentos) return;
          await new Promise((r) => setTimeout(r, 5000 * intentos));
          continue;
        }
        const body = (await res.json()) as Record<string, unknown>;
        const statusResponse = body?.vehicleStatusResponse as
          | Record<string, unknown>
          | undefined;
        const list = statusResponse?.vehicleStatuses;
        if (Array.isArray(list)) cache = list;
        logger.info("[telemetriaSnapshot] estados recibidos", {
          recibidos: cache.length,
          intento: intentos,
          sampleKeys: cache.length > 0 ?
            Object.keys(cache[0] as object).slice(0, 20) :
            [],
        });
        break;
      } catch (e) {
        logger.warn("[telemetriaSnapshot] error consultando Volvo", {
          error: (e as Error).message,
          intento: intentos,
        });
        if (intentos >= maxIntentos) {
          logger.error("[telemetriaSnapshot] agotados los reintentos");
          return;
        }
        await new Promise((r) => setTimeout(r, 5000 * intentos));
      }
    }

    if (cache.length === 0) {
      logger.warn("[telemetriaSnapshot] flota Volvo vacía después de los reintentos, abortando");
      return;
    }

    // ─── 2. Map VIN → patente desde Firestore ──────────────────────
    // .limit(5000) defensivo: la flota Vecchi tiene ~127 vehículos
    // (57 tractores + 70 enganches), pero un cap explícito evita
    // sorpresas si en el futuro alguien duplica la colección o un
    // import malformado infla docs. 5000 = 40x growth ceiling.
    const vehiculosSnap = await db.collection("VEHICULOS").limit(5000).get();
    const vinToPatente = new Map<string, string>();
    for (const doc of vehiculosSnap.docs) {
      const data = doc.data();
      const vin = (data.VIN ?? "").toString().trim().toUpperCase();
      if (vin && vin !== "-") {
        vinToPatente.set(vin, doc.id);
      }
    }

    // ─── 3. Fecha del snapshot (midnight ARG) ──────────────────────
    // Buenos Aires es UTC-3 sin DST. Construimos la fecha en TZ ARG
    // para que `fechaTxt` y `fecha` Timestamp sean consistentes con la
    // versión cliente original (que usaba DateTime.now() local).
    const ahora = new Date();
    const fechaTxt = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Argentina/Buenos_Aires",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(ahora); // "2026-04-29"
    const [year, month, day] = fechaTxt.split("-").map(Number);
    const fechaMidnight = new Date(Date.UTC(year, month - 1, day, 3, 0, 0));

    // ─── 4. Batch write a TELEMETRIA_HISTORICO ─────────────────────
    const batch = db.batch();
    let escritos = 0;
    let saltadosVin = 0;
    let saltadosPatente = 0;
    let saltadosCeros = 0;

    for (const v of cache) {
      const vehiculo = v as Record<string, unknown>;
      const vin = (vehiculo.vin ?? "").toString().trim().toUpperCase();
      if (!vin) {
        saltadosVin++;
        continue;
      }
      const patente = vinToPatente.get(vin);
      if (!patente) {
        saltadosPatente++;
        continue;
      }

      // Litros acumulados — el endpoint vehiclestatuses lo expone como
      // `engineTotalFuelUsed` al primer nivel **en MILILITROS**. Para
      // que el campo `litros_acumulados` esté efectivamente en litros
      // (consistente con su nombre y con el reporte de consumo),
      // dividimos por 1000. Mantenemos `accumulatedData.totalFuelConsumption`
      // como fallback por si en algún tipo de unidad viene nested.
      let litrosMl = 0;
      const top = vehiculo.engineTotalFuelUsed;
      if (typeof top === "number") {
        litrosMl = top;
      } else if (top != null) {
        litrosMl = Number(top);
      } else {
        const acc = vehiculo.accumulatedData;
        if (acc && typeof acc === "object") {
          const accObj = acc as Record<string, unknown>;
          const total = accObj.totalFuelConsumption;
          if (typeof total === "number") {
            litrosMl = total;
          } else if (total != null) {
            litrosMl = Number(total);
          }
        }
      }
      if (Number.isNaN(litrosMl)) litrosMl = 0;
      const litros = litrosMl / 1000;

      // Odómetro — Volvo lo entrega en metros.
      const metros = Number(
        vehiculo.hrTotalVehicleDistance ?? vehiculo.lastKnownOdometer ?? 0
      );
      const km = metros / 1000;

      // serviceDistance — km al próximo service programado. Volvo lo
      // entrega en metros y PUEDE SER NEGATIVO (vencido). Lo guardamos
      // como `service_distance_km` para alimentar el dashboard de
      // mantenimiento preventivo.
      //
      // Path oficial según doc Volvo Group Vehicle API v1.0.6:
      //   vehicleStatuses[i].uptimeData.serviceDistance
      // (junto con tellTaleInfo, engineCoolantTemperature).
      // Probamos primero ese path y caemos a legacy si no aparece.
      let serviceMetros: number | null = null;
      const serviceCandidatos: unknown[] = [
        (vehiculo.uptimeData as Record<string, unknown> | undefined)
          ?.serviceDistance,
        vehiculo.serviceDistance,
        (vehiculo.snapshotData as Record<string, unknown> | undefined)
          ?.serviceDistance,
        ((vehiculo.snapshotData as Record<string, unknown> | undefined)
          ?.volvoGroupSnapshot as Record<string, unknown> | undefined)
          ?.serviceDistance,
      ];
      for (const c of serviceCandidatos) {
        if (c == null) continue;
        const n = typeof c === "number" ? c : Number(c);
        if (!Number.isNaN(n)) {
          serviceMetros = n;
          break;
        }
      }
      const serviceKm = serviceMetros != null ? serviceMetros / 1000 : null;

      // Sin telemetría útil no escribimos.
      if (litros === 0 && km === 0 && serviceKm == null) {
        saltadosCeros++;
        continue;
      }

      const docId = `${patente}_${fechaTxt}`;
      // TTL: el campo `expira_en` (fecha + 18 meses) marca cuándo
      // GCP debe borrar este doc automáticamente. La policy se activa
      // por separado con: `gcloud firestore fields ttls update
      // expira_en --collection-group=TELEMETRIA_HISTORICO
      // --enable-ttl --project=coopertrans-movil`. 18 meses cubre
      // reportes anuales y comparativos año-a-año sin acumular
      // indefinidamente (snapshot diario × 127 vehículos × N años).
      // 18 meses calendario (no 18*30 dias = 540 dias = ~17.7 meses).
      // Antes la cuenta erronea borraba ~8 dias antes de los 18 meses
      // reales — para data anual y comparativos año-a-año hace falta el
      // calendario exacto. Usamos setUTCMonth para evitar drift.
      const ttl = new Date(fechaMidnight);
      ttl.setUTCMonth(ttl.getUTCMonth() + 18);
      const expiraEnMs = ttl.getTime();
      const doc: Record<string, unknown> = {
        patente,
        vin,
        fecha: Timestamp.fromDate(fechaMidnight),
        litros_acumulados: litros,
        km,
        timestamp: FieldValue.serverTimestamp(),
        expira_en: Timestamp.fromMillis(expiraEnMs),
      };
      if (serviceKm != null) {
        doc.service_distance_km = serviceKm;
      }
      batch.set(db.collection("TELEMETRIA_HISTORICO").doc(docId), doc);
      escritos++;
    }

    if (escritos === 0) {
      logger.info("[telemetriaSnapshot] sin datos útiles, nada que escribir", {
        recibidos: cache.length,
        saltadosVin,
        saltadosPatente,
        saltadosCeros,
        vinesEnFirestore: vinToPatente.size,
      });
      return;
    }

    await batch.commit();
    logger.info("[telemetriaSnapshot] OK", {
      escritos,
      fechaTxt,
      recibidos: cache.length,
      saltadosVin,
      saltadosPatente,
      saltadosCeros,
    });
  }
);

// ============================================================================
// auditLogWrite
// ============================================================================
// Callable que escribe a AUDITORIA_ACCIONES con datos del admin tomados
// del JWT (uid + custom claim `nombre`). Permite cerrar la rule de
// AUDITORIA_ACCIONES a `write: if false` y que solo el server pueda
// escribir, eliminando la posibilidad de que un admin con la consola
// abierta forje entradas de bitácora.
//
// Diseño:
//   - **Whitelist de acciones**: el caller no puede inventar strings
//     nuevos. Si el enum AuditAccion del cliente agrega un caso, hay
//     que sumarlo acá también (es una conscious choice — la auditoría
//     no debería tener vocabulario abierto).
//   - **Sanitización de tamaño**: payload total <= 10KB para defendernos
//     de un caller que mande un detalles enorme y nos haga gastar
//     espacio.
//   - **Fire-and-forget cliente**: la function devuelve OK rápido. Si
//     algo falla, el cliente loguea y sigue; nunca bloquea al admin.

const AUDIT_ACCIONES_PERMITIDAS = new Set<string>([
  // Personal
  "CREAR_CHOFER",
  "EDITAR_CHOFER",
  "CAMBIAR_FOTO_PERFIL",
  "REEMPLAZAR_PAPEL_CHOFER",
  "DAR_DE_BAJA_EMPLEADO",
  "REACTIVAR_EMPLEADO",
  // Flota
  "CREAR_VEHICULO",
  "EDITAR_VEHICULO",
  "CAMBIAR_FOTO_VEHICULO",
  "DAR_DE_BAJA_VEHICULO",
  "REACTIVAR_VEHICULO",
  // Asignaciones
  "ASIGNAR_EQUIPO",
  "DESVINCULAR_EQUIPO",
  // Revisiones
  "APROBAR_REVISION",
  "RECHAZAR_REVISION",
  // Alertas Volvo
  "MARCAR_ALERTA_VOLVO_ATENDIDA",
  // Gomería
  "CREAR_CUBIERTA",
  "INSTALAR_CUBIERTA",
  "RETIRAR_CUBIERTA",
  "DESCARTAR_CUBIERTA",
  "ENVIAR_CUBIERTA_A_RECAPAR",
  "RECIBIR_CUBIERTA_DE_RECAPADO",
]);

/**
 * Acciones que SUPERVISOR puede registrar (además de ADMIN).
 *
 * Los flujos de gomería son operados por supervisor + AREA=GOMERIA.
 * Los de asignaciones (chofer↔tractor, tractor↔enganche) los puede
 * disparar tanto el ADMIN como un SUPERVISOR (el callsite de
 * AsignacionVehiculoService / AsignacionEngancheService no distingue).
 * Sin esta lista, el callable rechazaría con permission-denied y la
 * bitácora se quedaría sin entradas para esos flujos críticos.
 */
const AUDIT_ACCIONES_SUPERVISOR_PERMITIDAS = new Set<string>([
  // Asignaciones — supervisor puede cambiar quién maneja qué.
  "ASIGNAR_EQUIPO",
  "DESVINCULAR_EQUIPO",
  // Gomería — el supervisor de gomería opera todo el flujo.
  "CREAR_CUBIERTA",
  "INSTALAR_CUBIERTA",
  "RETIRAR_CUBIERTA",
  "DESCARTAR_CUBIERTA",
  "ENVIAR_CUBIERTA_A_RECAPAR",
  "RECIBIR_CUBIERTA_DE_RECAPADO",
]);

const AUDIT_ENTIDADES_PERMITIDAS = new Set<string>([
  "EMPLEADOS",
  "VEHICULOS",
  "REVISIONES",
  "VOLVO_ALERTAS",
  "CUBIERTAS",
]);

const AUDIT_MAX_DETALLES_BYTES = 10 * 1024; // 10KB

interface AuditLogResult {
  ok: true;
  docId: string;
}

export const auditLogWrite = onCall(
  {
    enforceAppCheck: false, // todavía no está activado App Check
  },
  async (request): Promise<AuditLogResult> => {
    // ─── Auth: ADMIN o SUPERVISOR ──────────────────────────────────
    // ADMIN puede registrar cualquier acción de la whitelist.
    // SUPERVISOR puede registrar SOLO las acciones de
    // AUDIT_ACCIONES_SUPERVISOR_PERMITIDAS (asignaciones + gomería).
    // El check fino se hace después de validar el campo accion.
    const rol = request.auth?.token?.rol;
    if (!request.auth || (rol !== "ADMIN" && rol !== "SUPERVISOR")) {
      logger.warn("[auditLog] llamada sin auth ADMIN/SUPERVISOR", {
        uid: request.auth?.uid ?? "no-uid",
        rol: rol ?? "no-rol",
      });
      throw new HttpsError(
        "permission-denied",
        "Solo admin o supervisor pueden escribir bitácora."
      );
    }

    // ─── Validación de input ───────────────────────────────────────
    const data = request.data ?? {};
    const accion = (data.accion ?? "").toString().trim();
    const entidad = (data.entidad ?? "").toString().trim();
    const entidadId = (data.entidadId ?? "").toString().trim();
    const detalles = data.detalles;

    if (!accion || !AUDIT_ACCIONES_PERMITIDAS.has(accion)) {
      throw new HttpsError(
        "invalid-argument",
        `Acción '${accion}' no está en la whitelist.`
      );
    }

    // SUPERVISOR solo puede registrar acciones de su scope reducido.
    if (rol === "SUPERVISOR" &&
        !AUDIT_ACCIONES_SUPERVISOR_PERMITIDAS.has(accion)) {
      logger.warn("[auditLog] supervisor intentó acción fuera de scope", {
        uid: request.auth.uid,
        accion,
      });
      throw new HttpsError(
        "permission-denied",
        `Acción '${accion}' está reservada para ADMIN.`
      );
    }

    if (!entidad || !AUDIT_ENTIDADES_PERMITIDAS.has(entidad)) {
      throw new HttpsError(
        "invalid-argument",
        `Entidad '${entidad}' no está en la whitelist.`
      );
    }

    if (entidadId.length > 100) {
      throw new HttpsError(
        "invalid-argument",
        "entidadId demasiado largo (máx 100 chars)."
      );
    }

    // detalles debe ser objeto plano serializable y NO vacío. Validamos
    // tamaño serializando con JSON.stringify — si tira por circular
    // references o tipos no-serializables, rechazamos.
    //
    // Bug A3 del code review: antes aceptábamos {} y null. Ahora si
    // viene `detalles` debe tener al menos una key — sino, mejor
    // omitirlo del request directamente.
    let detallesPersistir: Record<string, unknown> | null = null;
    if (detalles != null) {
      if (typeof detalles !== "object" || Array.isArray(detalles)) {
        throw new HttpsError(
          "invalid-argument",
          "`detalles` debe ser un objeto plano."
        );
      }
      const detallesObj = detalles as Record<string, unknown>;
      if (Object.keys(detallesObj).length === 0) {
        throw new HttpsError(
          "invalid-argument",
          "`detalles` no puede ser un objeto vacío."
        );
      }
      let serializados: string;
      try {
        serializados = JSON.stringify(detallesObj);
      } catch {
        throw new HttpsError(
          "invalid-argument",
          "`detalles` no es serializable."
        );
      }
      if (serializados.length > AUDIT_MAX_DETALLES_BYTES) {
        throw new HttpsError(
          "resource-exhausted",
          `\`detalles\` excede el límite (${AUDIT_MAX_DETALLES_BYTES} bytes).`
        );
      }
      detallesPersistir = detallesObj;
    }

    // ─── Datos del admin desde el JWT ──────────────────────────────
    // request.auth.uid es el DNI gracias a loginConDni que setea uid=dni.
    // request.auth.token.nombre es un custom claim también seteado en
    // loginConDni. Si por algún motivo no está, fallback a "Admin".
    const adminDni = request.auth.uid;
    const adminNombre = (request.auth.token.nombre ?? "Admin").toString();

    // ─── Escritura ─────────────────────────────────────────────────
    const doc: Record<string, unknown> = {
      accion,
      entidad,
      admin_dni: adminDni,
      admin_nombre: adminNombre,
      timestamp: FieldValue.serverTimestamp(),
    };
    if (entidadId) {
      doc.entidad_id = entidadId;
    }
    if (detallesPersistir != null) {
      doc.detalles = detallesPersistir;
    }

    try {
      const ref = await db.collection("AUDITORIA_ACCIONES").add(doc);
      logger.info("[auditLog] OK", {
        accion,
        entidad,
        entidadId: entidadId || undefined,
        adminDni,
        docId: ref.id,
      });
      return { ok: true, docId: ref.id };
    } catch (e) {
      logger.error("[auditLog] error escribiendo", {
        accion,
        entidad,
        error: (e as Error).message,
      });
      throw new HttpsError(
        "internal",
        "No se pudo registrar la acción en bitácora."
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
          res = await fetchWithTimeout(url, {
            method: "GET",
            headers: {
              "Authorization": authHeader,
              "Accept": ACCEPT_ALERTS,
            },
          });
        } catch (e) {
          logger.error("[volvoAlertasPoller] fetch falló", {
            page: pages,
            error: (e as Error).message,
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

export interface AsignacionLookup {
  chofer_dni: string;
  chofer_nombre: string | null;
  desde: Timestamp;
  hasta: Timestamp | null;
}

/**
 * Trae todas las asignaciones de las patentes pedidas, agrupadas por
 * patente y ordenadas por `desde` descendente. Usar
 * [buscarAsignacionEnFecha] para resolver el chofer en un momento dado.
 *
 * Firestore acepta hasta 30 valores en `where in`, así que si hay más
 * patentes (Vecchi tiene 56), partimos en chunks.
 */
export async function cargarAsignacionesPorPatentes(
  patentes: string[]
): Promise<Map<string, AsignacionLookup[]>> {
  const result = new Map<string, AsignacionLookup[]>();
  if (patentes.length === 0) return result;

  const chunks: string[][] = [];
  for (let i = 0; i < patentes.length; i += 30) {
    chunks.push(patentes.slice(i, i + 30));
  }

  for (const chunk of chunks) {
    const snap = await db
      .collection("ASIGNACIONES_VEHICULO")
      .where("vehiculo_id", "in", chunk)
      .get();
    for (const doc of snap.docs) {
      const data = doc.data();
      const patente = (data.vehiculo_id ?? "").toString();
      if (!patente) continue;
      const arr = result.get(patente) ?? [];
      arr.push({
        chofer_dni: (data.chofer_dni ?? "").toString(),
        chofer_nombre: data.chofer_nombre ?
          String(data.chofer_nombre) :
          null,
        desde: data.desde as Timestamp,
        hasta: (data.hasta as Timestamp | null) ?? null,
      });
      result.set(patente, arr);
    }
  }

  // Ordenamos cada lista por `desde` descendente. Permite buscar en
  // memoria devolviendo la primera asignación cuyo rango cubre la fecha.
  for (const arr of result.values()) {
    arr.sort((a, b) => b.desde.toMillis() - a.desde.toMillis());
  }
  return result;
}

/**
 * Encuentra la asignación que estaba vigente para una patente en un
 * instante dado (ms). Devuelve `null` si no había nadie asignado.
 */
export function buscarAsignacionEnFecha(
  asignaciones: AsignacionLookup[] | undefined,
  fechaMs: number
): AsignacionLookup | null {
  if (!asignaciones) return null;
  for (const a of asignaciones) {
    const desdeMs = a.desde.toMillis();
    const hastaMs = a.hasta ? a.hasta.toMillis() : null;
    if (desdeMs <= fechaMs && (hastaMs === null || hastaMs > fechaMs)) {
      return a;
    }
  }
  return null;
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
      const triggerType = (
        (data.detalle_generic as Record<string, unknown> | undefined)
          ?.triggerType ?? ""
      ).toString().toUpperCase();
      if (triggerType) tipoEfectivo = triggerType;
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
      await claimRef.delete().catch(() => {
        // best-effort: si no se puede borrar, el siguiente retry
        // tira ALREADY_EXISTS y skipea, pero al menos quedò log.
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

/**
 * Helper de idempotencia ATOMICA para crons diarios. Usa Firestore
 * `create()` que es atómico — tira ALREADY_EXISTS si el doc ya existe.
 *
 * Reemplaza el patron anterior `if ((await get()).exists) return; ...
 * await set(...)` que tenia una ventana de race: si GCP retry-eaba
 * entre el get y el set, el segundo run no veia el doc creado todavia
 * → encolaba el mensaje 2 veces.
 *
 * Devuelve `true` si conseguimos el lock (debe continuar el cron),
 * `false` si ya estaba tomado (skip).
 */
export async function adquirirIdempotenciaDiaria(
  histRef: FirebaseFirestore.DocumentReference,
  tipo: string,
): Promise<boolean> {
  try {
    await histRef.create({
      tipo,
      tomado_en: FieldValue.serverTimestamp(),
    });
    return true;
  } catch (e) {
    // Firestore code 6 = ALREADY_EXISTS. Mensaje también lo dice.
    const msg = (e as Error).message || "";
    const code = (e as { code?: number }).code;
    if (code === 6 || msg.includes("ALREADY_EXISTS") || msg.includes("already exists")) {
      return false;
    }
    throw e;
  }
}

/**
 * Lock de tick para crons que NO deben correr en paralelo (pollers
 * cada 5 min, vigilador, etc.). Cloud Functions tiene semantica
 * at-least-once + retries de GCP → dos invocaciones del mismo cron
 * pueden disparar simultaneamente. Sin lock, dos pollers compiten
 * por avanzar el cursor en META → eventos perdidos o duplicados.
 *
 * Estrategia:
 *   1. `create()` atomico en META_LOCKS/{nombre}.
 *   2. Si ALREADY_EXISTS + `tomado_en` < `staleMs` → otro tick activo,
 *      skip (devuelve null).
 *   3. Si ALREADY_EXISTS + `tomado_en` >= `staleMs` → lock huerfano
 *      (proceso anterior crasheo sin liberar), lo robamos.
 *   4. Devuelve una funcion `liberar()` que el caller DEBE llamar
 *      en finally para no dejar el lock tomado.
 *
 * Auditoria 2026-05-18.
 */
export async function adquirirLockTick(
  nombre: string,
  staleMs: number,
): Promise<(() => Promise<void>) | null> {
  const lockRef = db.collection("META_LOCKS").doc(nombre);
  try {
    await lockRef.create({ tomado_en: FieldValue.serverTimestamp() });
  } catch (e) {
    const code = (e as { code?: number }).code;
    const msg = (e as Error).message || "";
    const yaExiste = code === 6 || msg.includes("ALREADY_EXISTS") ||
      msg.includes("already exists");
    if (!yaExiste) throw e;
    const snap = await lockRef.get();
    const tomadoEn = (snap.data()?.tomado_en as Timestamp | undefined);
    const edadMs = tomadoEn ? Date.now() - tomadoEn.toMillis() : Infinity;
    if (edadMs < staleMs) {
      logger.info(`[${nombre}] otro tick en curso, skip`, {
        edadSeg: Math.round(edadMs / 1000),
      });
      return null;
    }
    logger.warn(`[${nombre}] lock huerfano, robando`, {
      edadSeg: Math.round(edadMs / 1000),
    });
    await lockRef.set({ tomado_en: FieldValue.serverTimestamp() });
  }
  return async () => {
    await lockRef.delete().catch(() => {
      // best-effort: si no se libera, el proximo tick lo robara
      // como huerfano tras staleMs.
    });
  };
}

/**
 * Wrapper de fetch() con AbortController + timeout. Necesario porque
 * APIs externas (Volvo Connect, Sitrack) ocasionalmente cuelgan la
 * conexión sin cerrar — el `await fetch` se quedaba hasta el
 * timeoutSeconds de la function (~60-240s), quemando billing y
 * bloqueando reintentos. Con AbortController el fetch falla rápido
 * (~20s) y el caller puede manejar la excepción / reintentar.
 *
 * Uso: igual a fetch, opcionalmente pasar `timeoutMs`.
 */
export async function fetchWithTimeout(
  url: string,
  init: RequestInit = {},
  timeoutMs = 20_000,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

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
        res = await fetchWithTimeout(url, {
          method: "GET",
          headers: { Authorization: authHeader, Accept: ACCEPT_SCORES },
        });
      } catch (e) {
        logger.error("[volvoScoresPoller] fetch falló", {
          page: pages,
          error: (e as Error).message,
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
      const vehicles = Array.isArray(response.vehicles) ? response.vehicles : [];
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

// ============================================================================
// onAlertaVolvoMantenimientoCreated — alerta de mantenimiento al jefe
// ============================================================================
// Trigger Firestore distinto y complementario a `onAlertaVolvoCreated`
// (que notifica al CHOFER cuando hay HIGH severity de manejo). Este
// notifica al JEFE DE MANTENIMIENTO cuando aparece una alerta que
// indica problema mecánico/operativo del vehículo (independiente de
// severity).
//
// Tipos cubiertos:
//   - FUEL    → cambio anormal de combustible (posible robo, fuga,
//               medidor mal calibrado).
//   - CATALYST → problema con sistema SCR / filtro AdBlue.
//   - GENERIC con sub-tipo:
//       * TELL_TALE        → testigo del tablero encendido (check
//                            engine, presión aceite, etc).
//       * ADBLUELEVEL_LOW  → AdBlue por debajo del umbral.
//       * WITHOUT_ADBLUE   → sin AdBlue (riesgo de derate).
//
// Filtramos a tipos que indican "el camión te está avisando algo" antes
// que el chofer llame del medio de la ruta. La idea: pasar de modo
// reactivo (apagar incendios) a modo predictivo (turno de taller listo).
//
// Destinatario: hardcoded al DNI 35244439 (Santiago, jefe de
// mantenimiento Vecchi 2026). Si Vecchi suma a otra persona en el
// futuro, refactorizar a una colección META o env var.
//
// Bot: encolado en COLA_WHATSAPP — respeta el horario hábil del bot
// (8-19 lunes a viernes, sin feriados). Una alerta del sábado 23:00
// se entrega el lunes 8:00 AM. Para mantenimiento NO crítico esto está
// bien (el chofer ya llamó si era urgente). El sistema es predictivo.
//
// Idempotencia: trigger `onCreate` se dispara una sola vez por docId.
// El docId composite del poller (`{vin}_{createdMs}_{tipo}`) garantiza
// que mismo evento Volvo no genera dos triggers.
//
// Sin dedupe por tipo+patente en este v1: con ~7 eventos de
// mantenimiento en 13 días reales (TELL_TALE + FUEL + CATALYST), el
// volumen es muy bajo para preocuparse por spam. Si se materializa
// (ej: testigo intermitente que dispara 50 veces por hora), agregar
// dedupe simple por (alert_tipo, alert_patente) en últimas N horas.

export const MANTENIMIENTO_DESTINATARIO_DNI = "35244439";

// DNI del jefe de Seguridad e Higiene (MOLINA ALEJANDRA). Recibe el
// resumen diario de excesos de jornada (choferes que cruzaron 4h
// continuas o 12h diarias).
export const SEG_HIGIENE_DESTINATARIO_DNI = "34730329";

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
export const TTL_RESUMEN_DIARIO_MIN = 24 * 60; // resumenes diarios — vence en 24h
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

const TIPOS_MANTENIMIENTO_DIRECTOS = new Set(["FUEL", "CATALYST"]);

const SUBTIPOS_GENERIC_MANTENIMIENTO = new Set([
  "TELL_TALE",
  "ADBLUELEVEL_LOW",
  "WITHOUT_ADBLUE",
]);

function _esAlertaMantenimiento(
  tipo: string,
  data: Record<string, unknown>
): boolean {
  if (TIPOS_MANTENIMIENTO_DIRECTOS.has(tipo)) return true;
  if (tipo !== "GENERIC") return false;
  const detalleGeneric = data.detalle_generic as
    | Record<string, unknown>
    | undefined;
  const subType = (detalleGeneric?.type ?? "").toString().toUpperCase();
  return SUBTIPOS_GENERIC_MANTENIMIENTO.has(subType);
}

export const onAlertaVolvoMantenimientoCreated = onDocumentCreated(
  {
    document: "VOLVO_ALERTAS/{alertId}",
    timeoutSeconds: 30,
    memory: "256MiB",
  },
  async (event) => {
    const snap = event.data;
    if (!snap) {
      logger.warn("[onAlertaVolvoMantenimientoCreated] event.data vacío, skip");
      return;
    }

    const data = snap.data() ?? {};
    const tipo = (data.tipo ?? "").toString().toUpperCase();

    if (!_esAlertaMantenimiento(tipo, data)) {
      return; // No es del tipo que notificamos.
    }

    const patente = (data.patente ?? "").toString().trim().toUpperCase();

    // Etiqueta legible para el log.
    let etiqueta = ETIQUETAS_TIPO_ALERTA[tipo] ?? tipo;
    if (tipo === "GENERIC") {
      const detalleGeneric = data.detalle_generic as
        | Record<string, unknown>
        | undefined;
      const subType = (detalleGeneric?.type ?? "").toString().toUpperCase();
      etiqueta = ETIQUETAS_TIPO_ALERTA[subType] ?? subType ?? "Evento genérico";
    }

    // No encolamos en COLA_WHATSAPP aquí. El cron del bot lee
    // VOLVO_ALERTAS una vez por día y manda UN mensaje consolidado con
    // todos los eventos de mantenimiento de las últimas 24h
    // (cron_mantenimiento_diario en whatsapp-bot/src/cron.js).
    // Enviar uno por evento generaba N mensajes separados al admin.
    logger.info(
      "[onAlertaVolvoMantenimientoCreated] evento registrado en " +
      "VOLVO_ALERTAS — cron diario lo incluirá en resumen",
      {
        alertId: event.params.alertId,
        patente,
        tipo,
        etiqueta,
      }
    );
  }
);



/**
 * Eventos Sitrack que disparan el resumen diario de conducta a Molina
 * (`resumenConductaManejoDiario`). Incluye los CESVI puros + alertas
 * Volvo/Mobileye que NO son parte del ICM CESVI pero que Molina sigue
 * queriendo ver en el resumen diario (salida de carril, distancia
 * frenado insuficiente, colisión, chofer sin identificar). Este set
 * es operativo, NO sirve para calcular ICM.
 *
 * Para el ICM CESVI usar [TIPOS_CESVI_PUROS] — Santiago 2026-05-19.
 */
export const TIPOS_PELIGROSOS_SITRACK = new Set<number>([
  8, 9, 66, 67, 267, 326, 383, 444, 1006, 1007,
]);

/**
 * Eventos Sitrack que CESVI/YPF cuenta para el cálculo del ICM
 * (Índice de Conducta de Manejo, homologado por CESVI Argentina).
 * Subconjunto estricto de [TIPOS_PELIGROSOS_SITRACK]:
 *   - 66  Aceleración Brusca (peso −2.8 por evento)
 *   - 67  Frenada Brusca     (peso −5.8 por evento)
 *   - 383 Giro Brusco        (peso −2.8 por evento)
 *   - 8   Inicio sobrevelocidad ┐ pareados como UN evento de
 *   - 9   Fin sobrevelocidad    ┘ sobrevelocidad con duración
 *                                  (puntaje según gravedad CESVI)
 *
 * Fatiga (-5/-10/-15 según rango 2h/3h/>4h) se aplica por bloque del
 * vigilador de jornada, NO se cuenta por event_id (los eventos
 * Sitrack 1236-1238 de fatiga NO los recibimos en nuestra cuenta —
 * verificado 2026-05-19).
 *
 * Pesos exactos en la presentación Carsync de YPF
 * (`G:/Mi unidad/REQUERIMIENTOS YPF/Presentación Avance Carsync...`).
 */
export const TIPOS_CESVI_PUROS = new Set<number>([
  8, 9, 66, 67, 383,
]);



// asignarNumeroReciboAdelanto + purgarColaWhatsappAntigua movidas a
// cleanup_y_recibos.ts (refactor 2026-05-18, primera tanda del split).
// Re-exportadas con `export * from "./cleanup_y_recibos";` arriba.

