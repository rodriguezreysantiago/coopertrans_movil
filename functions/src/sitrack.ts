// =============================================================================
// SITRACK POLLERS — posición continua + eventos discretos
// =============================================================================
// Extraído de index.ts el 2026-05-18 (split del archivo de 6884 LOC).
//
// 2 pollers complementarios, ambos consumen la cuenta `ws41629VecchiSRL`:
//   - sitrackPosicionPoller (cada 5 min) → /v2/report (snapshot último
//     estado de cada unidad) → SITRACK_POSICIONES/{patente}.
//     Incluye drift detection (chofer físico vía iButton ≠ asignado).
//   - sitrackEventosPoller (cada 5 min) → /files/reports (stream de
//     eventos discretos drainable) → SITRACK_EVENTOS/{reportId}.
//     1400+ tipos de evento del catálogo Sitrack.

import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db, BANNER_TESTING } from "./setup";
import { adquirirLockTick, esErrorTransient, fetchWithTimeout, hashId } from "./index";
import { expiraEnMin, primerNombre, rrPick } from "./helpers";

const sitrackUsername = defineSecret("SITRACK_USERNAME");
const sitrackPassword = defineSecret("SITRACK_PASSWORD");

const SITRACK_BASE_AR = "https://externalappgw.ar.sitrack.com";

// Throttle 30 min / chofer para el aviso "pasá el iButton" — sin esto
// el cron de 5 min spamearía al chofer cada 5 min mientras siga
// manejando sin identificarse (decisión Vecchi 2026-05-07). Solo usado
// por _encolarAvisoChoferNoIdentificado abajo.
const AVISO_NO_ID_THROTTLE_SEGUNDOS = 30 * 60;
const TTL_PASA_IBUTTON_MIN = 30; // CHOFER_NO_IDENTIFICADO Sitrack

// ============================================================================
// sitrackPosicionPoller — última posición de toda la flota
// ============================================================================
//
// Toda la flota (55 tractores hoy) está en Sitrack — incluye también
// unidades sin Volvo Connect, así que es la mejor fuente para responder
// "dónde está cada tractor ahora". Volvo Vehicle Alerts solo nos dispara
// eventos puntuales (overspeed/idling/etc), no la posición continua —
// si un tractor lleva 1h sin generar evento, no sabemos dónde está. Con
// Sitrack sí.
//
// Endpoint: GET /v2/report (último reporte de cada unidad de la cuenta).
// Auth: Basic HTTPS con usuario web service. Cuota: hasta 1000 unidades
// por cuenta — sobra para Vecchi.
//
// Estrategia:
//   1. Cron cada 5 min llama al endpoint, recibe array con un item por
//      unidad activa.
//   2. Por cada item válido (con lat/lng y gpsValidity confiable),
//      mergeamos en `SITRACK_POSICIONES/{patente}` — doc id = patente,
//      no historizamos. Es snapshot del último estado.
//   3. Cursor de health en `META/sitrack_posicion_cursor` para que el
//      tablero de admin pueda detectar caídas del poller.
//
// Por qué `merge: true` y no `set` total: en algunos polls Sitrack puede
// devolver un reporte sin algunos campos opcionales (driver_dni vacío
// si el chofer todavía no se identificó); merge mantiene los últimos
// conocidos en lugar de borrarlos. La info de "frescura" del campo
// individual va via timestamps (ignition_date, report_date).

interface SitrackReportItem {
  reportId?: string;
  reportDate?: string;
  inputDate?: string;
  assetId?: string;
  assetName?: string;
  deviceId?: string;
  holderId?: string;
  eventId?: number;
  eventName?: string;
  latitude?: number;
  longitude?: number;
  location?: string;
  heading?: number;
  speed?: number;
  ignition?: 0 | 1;
  ignitionDate?: string;
  odometer?: number;
  gpsOdometer?: number;
  hourmeter?: number;
  deviceHourmeter?: number;
  driverName?: string;
  driverLastName?: string;
  driverDocumentNumber?: string;
  driverDocumentType?: string;
  // gpsValidity: 0..89 = confiable; >= 90 = no confiable.
  gpsValidity?: number;
  gpsSatellites?: number;
  gpsDop?: number;
  areaType?: string;
  // Cartografía / zonas (doc Sitrack pág 4-5):
  // - cartographyLimitSpeed: límite de velocidad de la zona (60/40 km/h
  //   en yacimientos YPF — depende del polígono cargado en Sitrack).
  // - gpsSpeed: velocidad medida por GPS (vs `speed` que puede venir de ECU).
  // - zoneId/Name/Condition: solo presentes si Sitrack tiene las capas
  //   configuradas en la cuenta. Si la cuenta tiene las capas YPF
  //   (Vaca Muerta, Loma Campana, etc), estos campos llegan en cada
  //   reporte cuando el tractor entra/sale o está dentro de una zona.
  cartographyLimitSpeed?: number;
  gpsSpeed?: number;
  zoneId?: string;
  zoneName?: string;
  zoneCondition?: string; // "input" | "output" | "inside" | "outside"
  batteryVoltage?: number;
  backupBatteryVoltage?: number;
  trailerId?: string;
  trailerName?: string;
}

export const sitrackPosicionPoller = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [sitrackUsername, sitrackPassword],
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    // Lock tick (auditoria 2026-05-18): cron cada 5 min, timeout 60s,
    // pero un fetch lento + procesado de 50 chofers puede exceder.
    // Sin lock dos ticks paralelos compiten en throttle/META_AVISOS_NO_ID.
    const liberar = await adquirirLockTick(
      "sitrack_posicion_poller",
      4 * 60 * 1000,
    );
    if (!liberar) return;
    try {
      logger.info("[sitrackPosicionPoller] iniciando ciclo");

      // ─── Auth Basic HTTPS ──────────────────────────────────────────
      const authHeader = "Basic " + Buffer.from(
        `${sitrackUsername.value()}:${sitrackPassword.value()}`
      ).toString("base64");

      // ─── Fetch ─────────────────────────────────────────────────────
      const url = `${SITRACK_BASE_AR}/v2/report`;
      let res: Response;
      try {
        res = await fetchWithTimeout(url, {
          method: "GET",
          headers: {
            "Authorization": authHeader,
            "Accept": "application/json",
          },
        });
      } catch (e) {
        const transient = esErrorTransient(e);
        const log = transient ? logger.warn : logger.error;
        log("[sitrackPosicionPoller] fetch falló", {
          error: (e as Error).message,
          transient,
        });
        return;
      }

      if (!res.ok) {
        logger.warn("[sitrackPosicionPoller] HTTP error", {
          statusCode: res.status,
        });
        return;
      }

      let reports: SitrackReportItem[];
      try {
        reports = (await res.json()) as SitrackReportItem[];
      } catch (e) {
        logger.error("[sitrackPosicionPoller] JSON parse falló", {
          error: (e as Error).message,
        });
        return;
      }

      if (!Array.isArray(reports)) {
        logger.warn("[sitrackPosicionPoller] respuesta no es array", {
          tipo: typeof reports,
        });
        return;
      }

    // ─── Drift detection: leer asignaciones activas ────────────────
    // Cargamos en memoria todas las ASIGNACIONES_VEHICULO con hasta=null
    // (~30 docs activas para una flota de 55). Por cada patente que
    // Sitrack reporta, comparamos el DNI del chofer físico (driverDoc-
    // umentNumber del iButton) con el DNI del chofer asignado por el
    // sistema. Si no coinciden, marcamos drift_tipo en el doc para que
    // la pantalla del admin lo destaque.
    interface AsignacionActiva {
      choferDni: string;
      choferNombre: string;
    }
    const asignacionesPorPatente = new Map<string, AsignacionActiva>();
    try {
      const asignSnap = await db
        .collection("ASIGNACIONES_VEHICULO")
        .where("hasta", "==", null)
        .get();
      for (const d of asignSnap.docs) {
        const data = d.data();
        const patente = (data.vehiculo_id ?? "").toString().trim().toUpperCase();
        const dni = (data.chofer_dni ?? "").toString().trim();
        const nombre = (data.chofer_nombre ?? "").toString().trim();
        if (patente && dni) {
          asignacionesPorPatente.set(patente, { choferDni: dni, choferNombre: nombre });
        }
      }
    } catch (e) {
      // Si falla, seguimos sin drift detection (no rompemos el poller).
      logger.warn("[sitrackPosicionPoller] no pude leer ASIGNACIONES_VEHICULO", {
        error: (e as Error).message,
      });
    }

    // ─── Persistir en SITRACK_POSICIONES ───────────────────────────
    // Batch único: 55 docs entran cómodos en un solo batch (límite 500).
    const batch = db.batch();
    let escritos = 0;
    let descartados = 0;
    let conDrift = 0;

    // Choferes con drift CHOFER_NO_IDENTIFICADO en este ciclo —
    // recolectamos para avisarles al final (después del batch commit)
    // que pasen el iButton de Sitrack. Vecchi NO usa el login del
    // tachógrafo Volvo; usa el iButton de Sitrack para identificar al
    // chofer. Por eso este aviso lo dispara este cron y no
    // onAlertaVolvoCreated.
    const choferesParaAvisarNoId: Array<{
      patente: string;
      choferDni: string;
    }> = [];

    for (const r of reports) {
      const patente = (r.assetId ?? "").toString().trim().toUpperCase();
      if (!patente) {
        descartados++;
        continue;
      }

      // gpsValidity >= 90 → posición no confiable (poca señal de
      // satélites). Lo dice el doc explícitamente. En esos casos el
      // doc en SITRACK_POSICIONES queda "stale" hasta el próximo
      // reporte confiable — preferimos no pisar la última posición
      // buena con una mala.
      if (typeof r.gpsValidity === "number" && r.gpsValidity >= 90) {
        descartados++;
        continue;
      }

      const lat = typeof r.latitude === "number" ? r.latitude : null;
      const lng = typeof r.longitude === "number" ? r.longitude : null;
      if (lat === null || lng === null) {
        descartados++;
        continue;
      }

      const reportTs = r.reportDate ? new Date(r.reportDate) : null;
      const ignitionTs = r.ignitionDate ? new Date(r.ignitionDate) : null;

      // Odómetro: preferimos el "principal" (de la ECU si tiene ICAN,
      // sino calculado por GPS). gpsOdometer queda como respaldo de
      // visualización.
      const odometer = typeof r.odometer === "number" ?
        r.odometer :
        typeof r.gpsOdometer === "number" ?
          r.gpsOdometer :
          null;
      const hourmeter = typeof r.hourmeter === "number" ?
        r.hourmeter :
        typeof r.deviceHourmeter === "number" ?
          r.deviceHourmeter :
          null;

      // Chofer identificado vía iButton/tarjeta: DNI es el match
      // exacto contra EMPLEADOS/{dni}. driverName/driverLastName
      // pueden venir mezclados según cómo registraron al chofer en
      // el portal Sitrack — los guardamos crudos para el cross-check.
      const driverDni = (r.driverDocumentNumber ?? "").toString().trim();
      const driverNombre = (r.driverName ?? "").toString().trim();
      const driverApellido = (r.driverLastName ?? "").toString().trim();

      // ─── Drift detection ─────────────────────────────────────────
      // Comparamos el chofer físico (Sitrack) vs el asignado por el
      // sistema. Casos:
      //   - SIN_ASIGNACION: Sitrack reporta chofer pero el sistema
      //     no tiene a nadie asignado a esa patente. Alguien manejando
      //     sin estar registrado.
      //   - CHOFER_DISTINTO: Ambos lados reportan, pero los DNIs no
      //     coinciden. Falta actualizar la asignación.
      //   - CHOFER_NO_IDENTIFICADO: ignición ON, hay asignación, pero
      //     Sitrack no reporta DNI ni nombre que matchee — el chofer
      //     subió sin pasar el iButton. Si ignición OFF, no es drift
      //     (tractor parado).
      //
      // Sitrack a veces NO manda `driverDocumentNumber` aunque el
      // chofer SÍ esté logueado físicamente con el iButton (caso real
      // 2026-05-08 con Moises en AG890AL: Sitrack mandaba `driverName`
      // y `driverLastName` con sus datos pero `driverDocumentNumber`
      // vacío). En esos casos hacemos fallback de match por nombre
      // contra la asignación — si coincide, el chofer está
      // identificado igual.
      const ignitionOn = r.ignition === 1;
      const asignacion = asignacionesPorPatente.get(patente);

      // Match por nombre: concatena driverNombre + driverApellido en
      // ambos órdenes (Sitrack a veces invierte los campos) y compara
      // con asignacion.choferNombre. Match si el nombre asignado
      // contiene TODOS los tokens del nombre del iButton (case y
      // acentos insensitive). Permite que "OSCAR MOISES PEZOA" en
      // asignación matchee con iButton "PEZOA" + "OSCAR MOISES".
      const tokensSitrack = `${driverNombre} ${driverApellido}`
        .toUpperCase()
        .split(/\s+/)
        .filter((t) => t.length > 1);
      const nombreAsignacion = asignacion ?
        asignacion.choferNombre.toUpperCase() :
        "";
      const matchPorNombre =
        !!asignacion &&
        tokensSitrack.length > 0 &&
        tokensSitrack.every((t) => nombreAsignacion.includes(t));

      let driftTipo: string | null = null;
      if (driverDni && !asignacion) {
        driftTipo = "SIN_ASIGNACION";
      } else if (driverDni && asignacion && asignacion.choferDni !== driverDni) {
        driftTipo = "CHOFER_DISTINTO";
      } else if (!driverDni && asignacion && ignitionOn && !matchPorNombre) {
        driftTipo = "CHOFER_NO_IDENTIFICADO";
        // Recolectamos para enviar aviso al chofer asignado después
        // del batch commit. La dedup se hace en
        // `_encolarAvisoChoferNoIdentificado` para no spamear cada 5min.
        choferesParaAvisarNoId.push({
          patente,
          choferDni: asignacion.choferDni,
        });
      }
      if (driftTipo) conDrift++;

      const doc: Record<string, unknown> = {
        // Identificación
        patente,
        asset_name: r.assetName ?? "",
        holder_id: (r.holderId ?? "").toString(),
        device_id: (r.deviceId ?? "").toString(),
        // Posición
        lat,
        lng,
        location: r.location ?? "",
        heading: typeof r.heading === "number" ? r.heading : null,
        speed: typeof r.speed === "number" ? r.speed : null,
        // Estado motor
        ignition: r.ignition === 1,
        ignition_date: ignitionTs ? Timestamp.fromDate(ignitionTs) : null,
        odometer,
        hourmeter,
        // Chofer (puede no haberse identificado todavía → strings vacíos)
        driver_dni: driverDni,
        driver_nombre: driverNombre,
        driver_apellido: driverApellido,
        // Drift: comparación del DNI Sitrack vs ASIGNACIONES_VEHICULO.
        // null cuando todo coincide o cuando el tractor está parado
        // sin identificar (no es drift). La pantalla del admin filtra
        // por drift_tipo != null para destacar inconsistencias.
        drift_tipo: driftTipo,
        asignacion_dni: asignacion?.choferDni ?? "",
        asignacion_nombre: asignacion?.choferNombre ?? "",
        // Evento que disparó el reporte
        event_id: typeof r.eventId === "number" ? r.eventId : null,
        event_name: r.eventName ?? "",
        // Calidad GPS
        gps_validity: typeof r.gpsValidity === "number" ? r.gpsValidity : null,
        gps_satellites: typeof r.gpsSatellites === "number" ? r.gpsSatellites : null,
        // Cartografía / zonas YPF (agregado 2026-05-15)
        // YPF audita conducta usando estos mismos campos del feed Sitrack.
        // - area_type: "urban" | "rural" | "unknown" (Sitrack lo deriva).
        // - cartography_limit_speed: limite de velocidad de la zona donde
        //   esta el camion (60/40 km/h en zonas YPF, depende del lugar).
        // - zone_id/name/condition: presentes solo si Sitrack tiene
        //   las capas de geocercas configuradas en la cuenta `ws41629VecchiSRL`.
        //   YPF tiene los mismos IMEIs en su gateway, asi que las capas
        //   deberian estar habilitadas — verificar con scripts/inspeccionar_payload_sitrack.js.
        area_type: (r.areaType ?? "").toString(),
        cartography_limit_speed:
          typeof r.cartographyLimitSpeed === "number" ?
            r.cartographyLimitSpeed :
            null,
        gps_speed: typeof r.gpsSpeed === "number" ? r.gpsSpeed : null,
        zone_id: (r.zoneId ?? "").toString(),
        zone_name: (r.zoneName ?? "").toString(),
        zone_condition: (r.zoneCondition ?? "").toString(),
        // Trailer (sensor de enganche, hoy no instalado en ningún tractor
        // — lo guardamos por si en el futuro se instala)
        trailer_id: r.trailerId ?? "",
        trailer_name: r.trailerName ?? "",
        // Timestamps
        report_date: reportTs ? Timestamp.fromDate(reportTs) : null,
        consultado_en: FieldValue.serverTimestamp(),
        // Auditoría / debugging
        report_id: r.reportId ?? "",
      };

      batch.set(
        db.collection("SITRACK_POSICIONES").doc(patente),
        doc,
        { merge: true }
      );
      escritos++;
    }

    if (escritos > 0) {
      await batch.commit();
    }

    // ─── Health cursor ─────────────────────────────────────────────
    await db.collection("META").doc("sitrack_posicion_cursor").set(
      {
        ultimo_exito_at: FieldValue.serverTimestamp(),
        ultimo_recibidos: reports.length,
        ultimo_escritos: escritos,
        ultimo_descartados: descartados,
      },
      { merge: true }
    );

    // ─── Avisar a choferes con drift CHOFER_NO_IDENTIFICADO ─────────
    // Best-effort: cada aviso es independiente, fallas se loguean y
    // no abortan el ciclo. Throttle de 30 min por chofer en
    // META_AVISOS_NO_ID — sin esto el cron de 5 min spamearía al chofer
    // cada 5 min mientras siga manejando sin pasar el iButton (decisión
    // Vecchi 2026-05-07).
    let avisosEnviados = 0;
    let avisosDedup = 0;
    for (const item of choferesParaAvisarNoId) {
      try {
        const enviado = await _encolarAvisoChoferNoIdentificado(
          item.patente,
          item.choferDni
        );
        if (enviado) {
          avisosEnviados++;
        } else {
          avisosDedup++;
        }
      } catch (e) {
        logger.warn(
          "[sitrackPosicionPoller] aviso CHOFER_NO_IDENTIFICADO falló",
          {
            patente: item.patente,
            choferDni: item.choferDni,
            error: (e as Error).message,
          }
        );
      }
    }

    logger.info("[sitrackPosicionPoller] OK", {
      recibidos: reports.length,
      escritos,
      descartados,
      conDrift,
      avisosEnviados,
      avisosDedup,
    });
    } finally {
      await liberar();
    }
  }
);

// ============================================================================
// sitrackEventosPoller — consume `/files/reports` (eventos acumulados)
// ============================================================================
//
// Sitrack tiene 1400+ tipos de evento que sus equipos generan
// (jornada, conducción peligrosa, mantenimiento, viajes, etc. — ver
// docs/SITRACK-Tipos de evento_reporte). El endpoint /files/reports
// los acumula en un buffer del lado Sitrack y los entrega en cada
// llamada (drainable). Sin consumirlos regularmente:
//   - el buffer crece y la próxima llamada baja a tasa reducida.
//   - si pasan 30 días sin consumirse, Sitrack purga el buffer.
//
// Diferencia con `sitrackPosicionPoller`:
//   - posicionPoller usa /v2/report = snapshot del último estado de
//     CADA unidad (1 doc por patente, sobrescribe).
//   - eventosPoller usa /files/reports = stream de eventos discretos
//     (1 doc por evento, append-only, persiste todo el detalle).
//
// La lógica que CONSUME estos eventos (vigilador de jornada nuevo,
// auto-poblar viajes, alertas de descarga combustible, etc.) vive en
// otras funciones que leen `SITRACK_EVENTOS`. Este poller solo
// persiste — separación de concerns.
//
// Frecuencia: cada 5 min (Sitrack permite 1 invocación/min como max).
// Si en producción vemos backpressure (eventos acumulados > X), bajar
// el intervalo a 1-2 min.

interface SitrackEventoItem extends SitrackReportItem {
  sequentialId?: string;
  cartographyLimitSpeed?: number;
  gpsSpeed?: number;
  backupBatteryChargePercentage?: number;
}

export const sitrackEventosPoller = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [sitrackUsername, sitrackPassword],
    timeoutSeconds: 240,
    memory: "512MiB",
  },
  async () => {
    // Lock tick (auditoria 2026-05-18): timeout 240s > schedule 300s,
    // edge case real. Dos ticks paralelos compiten por avanzar
    // `META/sitrack_eventos_cursor` y procesan los mismos eventos
    // (ya idempotente por sequentialId via getAll/set, pero
    // desperdicia ops y deja el cursor inconsistente).
    const liberar = await adquirirLockTick(
      "sitrack_eventos_poller",
      4 * 60 * 1000,
    );
    if (!liberar) return;
    try {
      logger.info("[sitrackEventosPoller] iniciando ciclo");

      const authHeader = "Basic " + Buffer.from(
        `${sitrackUsername.value()}:${sitrackPassword.value()}`
      ).toString("base64");

      const url = `${SITRACK_BASE_AR}/files/reports`;
      let res: Response;
      let bodyText = "";
      try {
        res = await fetchWithTimeout(url, {
          method: "GET",
          headers: {
            Authorization: authHeader,
            Accept: "application/json",
          },
        });
        // /files/reports devuelve text/plain (probablemente NDJSON o
        // array JSON). Leer todo el body antes de cerrar la conexión —
        // la doc Sitrack es explícita: si cerramos antes de leer todos
        // los bytes, en la próxima llamada se reenvía el bloque entero.
        bodyText = await res.text();
      } catch (e) {
        const transient = esErrorTransient(e);
        const log = transient ? logger.warn : logger.error;
        log("[sitrackEventosPoller] fetch falló", {
          error: (e as Error).message,
          transient,
        });
        return;
      }

      // 400 errorCode 120: otra invocación en progreso. Lo loguamos y
      // salimos — el próximo ciclo lo intenta de nuevo.
      if (res.status === 400 && bodyText.includes("\"errorCode\":120")) {
        logger.warn("[sitrackEventosPoller] otra invocación en progreso", {
          body: bodyText.slice(0, 200),
        });
        return;
      }
      if (!res.ok) {
        logger.warn("[sitrackEventosPoller] HTTP error", {
          statusCode: res.status,
          bodyHead: bodyText.slice(0, 500),
        });
        return;
      }

      const bodyBytes = Buffer.byteLength(bodyText, "utf8");
      if (bodyBytes === 0) {
      // Buffer vacío — caso normal cuando no hubo eventos nuevos.
      // Ojo: NO indica desactivación (ver script
      // sitrack_probar_files_reports.js para el matiz).
        logger.info("[sitrackEventosPoller] sin eventos nuevos");
        await db.collection("META").doc("sitrack_eventos_cursor").set({
          ultimo_exito_at: FieldValue.serverTimestamp(),
          ultimo_recibidos: 0,
          ultimo_escritos: 0,
          ultimo_descartados: 0,
          ultimo_bytes: 0,
        }, { merge: true });
        return;
      }

      // Parseo defensivo. El sample observado en pruebas mostró:
      //   {"reportId":"..."},\n{"reportId":"..."},\n...
      // No vimos `[` al inicio — por las dudas probamos 3 estrategias:
      //   1. JSON.parse del body completo (caso array JSON estándar).
      //   2. Envolver con [...] por si vienen items separados por coma.
      //   3. NDJSON: split por newline + parse cada línea.
      let eventos: SitrackEventoItem[] = [];
      let parseStrategy = "";
      try {
        const parsed = JSON.parse(bodyText);
        if (Array.isArray(parsed)) {
          eventos = parsed as SitrackEventoItem[];
          parseStrategy = "json-array";
        } else if (parsed && Array.isArray(parsed.reports)) {
          eventos = parsed.reports as SitrackEventoItem[];
          parseStrategy = "json-object-reports";
        } else if (parsed && typeof parsed === "object") {
        // Single object → array de 1.
          eventos = [parsed as SitrackEventoItem];
          parseStrategy = "json-single";
        }
      } catch {
      // Estrategia 2: envolver en array.
        try {
          const wrapped = `[${bodyText.replace(/,\s*$/, "")}]`;
          const parsed = JSON.parse(wrapped);
          if (Array.isArray(parsed)) {
            eventos = parsed as SitrackEventoItem[];
            parseStrategy = "comma-wrapped";
          }
        } catch {
        // Estrategia 3: NDJSON.
          const lineas = bodyText.split(/\r?\n/);
          for (const linea of lineas) {
            const t = linea.trim().replace(/,$/, "");
            if (!t) continue;
            try {
              eventos.push(JSON.parse(t) as SitrackEventoItem);
            } catch {
            // saltamos línea malformada
            }
          }
          parseStrategy = "ndjson-line-by-line";
        }
      }

      if (eventos.length === 0) {
        logger.warn("[sitrackEventosPoller] no se pudo parsear ningún evento", {
          bytes: bodyBytes,
          bodyHead: bodyText.slice(0, 500),
          parseStrategy,
        });
        return;
      }

      logger.info("[sitrackEventosPoller] eventos parseados", {
        cantidad: eventos.length,
        bytes: bodyBytes,
        parseStrategy,
      });

      // ─── Persistir en SITRACK_EVENTOS ─────────────────────────────
      // docId = reportId (UUID único por evento del lado Sitrack).
      // Idempotente: si por algún motivo el mismo reportId llega 2 veces,
      // sobrescribe sin duplicar (set sin merge — el evento es
      // inmutable, no hay update).
      //
      // Batches de 500 ops (límite Firestore). Si llegan > 500, hacemos
      // múltiples commits.
      const BATCH_SIZE = 500;
      let escritos = 0;
      let descartados = 0;
      let batch = db.batch();
      let opsEnBatch = 0;

      const parseTs = (s: string | undefined): Timestamp | null => {
        if (!s) return null;
        const d = new Date(s);
        return Number.isFinite(d.getTime()) ? Timestamp.fromDate(d) : null;
      };

      for (const e of eventos) {
        const reportId = (e.reportId ?? "").toString().trim();
        if (!reportId) {
          descartados++;
          continue;
        }

        // TTL 90 días (auditoría 2026-05-30): el evento CRUDO se borra 90 días
        // después de su fecha (o de ahora, si no trae fecha). La policy TTL vive
        // en firestore.indexes.json (fieldOverride SITRACK_EVENTOS.expira_en).
        // Los históricos DESTILADOS (JORNADAS, ZONA_DESCARGA_HISTORICO,
        // SITRACK_IBUTTONS_HISTORICO, VOLVO_JORNADAS_HISTORICO) son PERMANENTES;
        // estos eventos crudos solo sirven para reconstruir/auditar al detalle
        // hasta 90 días atrás. Antes la colección crecía sin tope (~3-5K docs/día).
        const reportTs = parseTs(e.reportDate);
        const baseExpira = reportTs ? reportTs.toDate() : new Date();
        const expiraEn = Timestamp.fromMillis(
          baseExpira.getTime() + 90 * 24 * 60 * 60 * 1000);

        const doc: Record<string, unknown> = {
        // Identificación
          report_id: reportId,
          sequential_id: (e.sequentialId ?? "").toString(),
          // Tiempo
          report_date: reportTs,
          input_date: parseTs(e.inputDate),
          recibido_en: FieldValue.serverTimestamp(),
          expira_en: expiraEn,
          // Activo
          asset_id: (e.assetId ?? "").toString(),
          asset_name: (e.assetName ?? "").toString(),
          device_id: (e.deviceId ?? "").toString(),
          holder_id: (e.holderId ?? "").toString(),
          // Evento
          event_id: typeof e.eventId === "number" ? e.eventId : null,
          event_name: (e.eventName ?? "").toString(),
          // Posición
          latitude: typeof e.latitude === "number" ? e.latitude : null,
          longitude: typeof e.longitude === "number" ? e.longitude : null,
          location: (e.location ?? "").toString(),
          area_type: (e.areaType ?? "").toString(),
          heading: typeof e.heading === "number" ? e.heading : null,
          speed: typeof e.speed === "number" ? e.speed : null,
          gps_speed: typeof e.gpsSpeed === "number" ? e.gpsSpeed : null,
          cartography_limit_speed:
          typeof e.cartographyLimitSpeed === "number" ?
            e.cartographyLimitSpeed :
            null,
          // Zonas / geocercas (agregado 2026-05-15)
          // Si la cuenta Sitrack tiene cargadas las capas de YPF (Vaca
          // Muerta, Loma Campana, etc), estos 3 campos llegan en eventos
          // de entrada/salida de zona. YPF audita exactamente esto.
          zone_id: (e.zoneId ?? "").toString(),
          zone_name: (e.zoneName ?? "").toString(),
          zone_condition: (e.zoneCondition ?? "").toString(),
          // Equipo
          ignition: e.ignition === 1 || e.ignition === 0 ? e.ignition : null,
          ignition_date: parseTs(e.ignitionDate),
          odometer: typeof e.odometer === "number" ? e.odometer : null,
          gps_odometer: typeof e.gpsOdometer === "number" ? e.gpsOdometer : null,
          hourmeter: typeof e.hourmeter === "number" ? e.hourmeter : null,
          device_hourmeter:
          typeof e.deviceHourmeter === "number" ? e.deviceHourmeter : null,
          // Chofer
          driver_dni: (e.driverDocumentNumber ?? "").toString(),
          driver_name: (e.driverName ?? "").toString(),
          driver_last_name: (e.driverLastName ?? "").toString(),
          // Calidad GPS
          gps_validity: typeof e.gpsValidity === "number" ? e.gpsValidity : null,
          gps_satellites:
          typeof e.gpsSatellites === "number" ? e.gpsSatellites : null,
          // Hardware
          battery_voltage:
          typeof e.batteryVoltage === "number" ? e.batteryVoltage : null,
          backup_battery_voltage:
          typeof e.backupBatteryVoltage === "number" ?
            e.backupBatteryVoltage :
            null,
          backup_battery_charge_percentage:
          typeof e.backupBatteryChargePercentage === "number" ?
            e.backupBatteryChargePercentage :
            null,
          // Trailer (en Vecchi hoy no instalado, lo dejamos por compat)
          trailer_id: (e.trailerId ?? "").toString(),
          trailer_name: (e.trailerName ?? "").toString(),
        };

        batch.set(
          db.collection("SITRACK_EVENTOS").doc(reportId),
          doc,
          { merge: false }
        );
        opsEnBatch++;
        escritos++;

        if (opsEnBatch >= BATCH_SIZE) {
          await batch.commit();
          batch = db.batch();
          opsEnBatch = 0;
        }
      }
      if (opsEnBatch > 0) {
        await batch.commit();
      }

      // ─── Health cursor ───────────────────────────────────────────
      await db.collection("META").doc("sitrack_eventos_cursor").set({
        ultimo_exito_at: FieldValue.serverTimestamp(),
        ultimo_recibidos: eventos.length,
        ultimo_escritos: escritos,
        ultimo_descartados: descartados,
        ultimo_bytes: bodyBytes,
        ultimo_parse_strategy: parseStrategy,
      }, { merge: true });

      logger.info("[sitrackEventosPoller] OK", {
        recibidos: eventos.length,
        escritos,
        descartados,
        bytes: bodyBytes,
        parseStrategy,
      });
    } finally {
      await liberar();
    }
  }
);

// Encola un aviso al chofer pidiéndole que pase el iButton de Sitrack
// para identificarse. Devuelve `true` si efectivamente encoló;
// `false` si no pudo (chofer no existe, sin teléfono, throttled, etc).
//
// Throttle 30 min por chofer (AVISO_NO_ID_THROTTLE_SEGUNDOS) — el cron
// corre cada 5 min, sin throttle el chofer recibe 1 msj cada 5 min y
// eso es spam directo (decisión Vecchi 2026-05-07). El estado del
// throttle vive en META_AVISOS_NO_ID/{choferDni} con last_sent_at
// (server timestamp). Si el chofer pasa el iButton antes de los 30
// min, el cron deja de detectar drift y no encola; el throttle
// expirado simplemente queda residual hasta el próximo drift.
async function _encolarAvisoChoferNoIdentificado(
  patente: string,
  choferDni: string
): Promise<boolean> {
  // Silencio manual via comando `/silenciar` del bot. La colección
  // BOT_SILENCIADOS_CHOFER se usaba sólo en el vigilador de jornada,
  // pero el chofer silenciado debería estarlo para TODOS los avisos
  // automáticos — sino el comando es engañoso. Bug detectado el
  // 2026-05-14 con Horacio (AC383OM): se le aplicó /silenciar y
  // siguió recibiendo el aviso del iButton porque este path no lo
  // chequeaba.
  try {
    const silSnap = await db
      .collection("BOT_SILENCIADOS_CHOFER")
      .doc(choferDni)
      .get();
    if (silSnap.exists) {
      const hasta = silSnap.data()?.silenciado_hasta;
      if (hasta && typeof hasta.toMillis === "function" &&
          hasta.toMillis() > Date.now()) {
        return false;
      }
    }
  } catch (e) {
    // Si falla el read no bloqueamos — peor caso le llega un aviso
    // que el admin pidió silenciar.
    logger.warn("[noIdentificado] no pude leer BOT_SILENCIADOS_CHOFER", {
      choferDni,
      error: (e as Error).message,
    });
  }

  // Throttle: ¿se le envió uno hace menos de 30 min?
  const throttleRef = db.collection("META_AVISOS_NO_ID").doc(choferDni);
  const throttleSnap = await throttleRef.get();
  if (throttleSnap.exists) {
    const lastSentAt = throttleSnap.data()?.last_sent_at;
    if (lastSentAt && typeof lastSentAt.toMillis === "function") {
      const segundosDesde = (Date.now() - lastSentAt.toMillis()) / 1000;
      if (segundosDesde < AVISO_NO_ID_THROTTLE_SEGUNDOS) {
        return false;
      }
    }
  }

  // Lookup chofer.
  const empSnap = await db.collection("EMPLEADOS").doc(choferDni).get();
  if (!empSnap.exists) {
    logger.warn(
      "[noIdentificado] chofer asignado no existe en EMPLEADOS",
      { choferDni, patente }
    );
    return false;
  }
  const empData = empSnap.data() ?? {};
  if (empData.ACTIVO === false) {
    return false;
  }
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") {
    return false;
  }

  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

  // Variantes para no repetir el mismo texto cada 5 min — anti-baneo
  // de WhatsApp y para que el chofer no lo perciba como auto-spam.
  // Mínimo 6 variantes (decisión 2026-05-09).
  const variantes = [
    `${saludo},\n\n` +
      `Estás manejando el TRACTOR ${patente} pero todavía no pasaste ` +
      "tu iButton de Sitrack. Por favor pasalo apenas puedas, así " +
      "quedan registrados los datos del recorrido.\n\n" +
      BANNER_TESTING +
      "_Bot-On — Coopertrans Móvil_",
    `${saludo}.\n\n` +
      `Recordatorio: el TRACTOR ${patente} está en marcha pero ` +
      "Sitrack no te detecta logueado. Pasá el iButton apenas puedas.\n\n" +
      BANNER_TESTING +
      "_Bot-On — Coopertrans Móvil_",
    `${saludo}, te avisamos desde la oficina.\n\n` +
      `Estamos viendo que manejás el ${patente} sin haber pasado ` +
      "el iButton de Sitrack. Necesitamos que te identifiques así " +
      "queda el registro del viaje.\n\n" +
      BANNER_TESTING +
      "_Bot-On — Coopertrans Móvil_",
    `${saludo}, ¿pasaste el iButton?\n\n` +
      `El ${patente} viene andando pero Sitrack no te tiene ` +
      "identificado. Pasalo apenas tengas un momento para que el " +
      "viaje quede a tu nombre.\n\n" +
      BANNER_TESTING +
      "_Bot-On — Coopertrans Móvil_",
    `${saludo}, atención.\n\n` +
      `Estamos detectando movimiento del TRACTOR ${patente} sin ` +
      "tu identificación. Pasá el iButton cuando puedas para no " +
      "perder el registro del tramo.\n\n" +
      BANNER_TESTING +
      "_Bot-On — Coopertrans Móvil_",
    `${saludo}.\n\n` +
      `Recordatorio rápido: el ${patente} está en marcha sin chofer ` +
      "logueado en Sitrack. Pasá el iButton cuando puedas — es " +
      "importante para que quede el registro completo.\n\n" +
      BANNER_TESTING +
      "_Bot-On — Coopertrans Móvil_",
  ];
  const mensaje = variantes[rrPick(variantes.length)];

  // Auditoria 2026-05-17: antes el throttle se seteaba SIEMPRE
  // (incluso si el add a COLA_WHATSAPP fallaba), lo que dejaba al
  // chofer sin recibir el aviso por 30 min. Ahora seteamos throttle
  // SOLO si el add fue exitoso — si falla, el proximo poll reintenta.
  try {
    await db.collection("COLA_WHATSAPP").add({
      telefono: tel,
      mensaje,
      estado: "PENDIENTE",
      encolado_en: FieldValue.serverTimestamp(),
      expira_en: expiraEnMin(TTL_PASA_IBUTTON_MIN),
      enviado_en: null,
      error: null,
      intentos: 0,
      origen: "sitrack_chofer_no_identificado",
      destinatario_coleccion: "EMPLEADOS",
      destinatario_id: choferDni,
      campo_base: "SITRACK_DRIFT",
      admin_dni: "BOT",
      admin_nombre: "Bot Sitrack",
      alert_patente: patente,
    });
  } catch (e) {
    logger.warn("[avisoChoferNoIdentificado] add a COLA fallo, no seteo throttle", {
      choferDniHash: hashId(choferDni),
      patente,
      error: (e as Error).message,
    });
    return false;
  }

  // Marcar throttle: 30 min hasta el próximo aviso a este chofer.
  // Set con merge:false → reemplaza el doc completo, no acumulamos basura.
  await throttleRef.set({
    last_sent_at: FieldValue.serverTimestamp(),
    last_patente: patente,
  });
  return true;
}
