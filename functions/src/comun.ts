/**
 * Helpers y constantes COMPARTIDOS entre múltiples módulos de Cloud
 * Functions.
 *
 * Extraído de index.ts (refactor split 2026-05-19). Antes vivían en
 * index.ts y obligaban a icm/sitrack/mantenimiento/resumenes/volvo a
 * importar de "./index" (god-hub). Además estaban físicamente
 * intercalados con las zonas Volvo, lo que impedía extraer volvo.ts
 * como rango contiguo.
 *
 * Contiene:
 *   - Asignaciones chofer↔patente: `AsignacionLookup`,
 *     `cargarAsignacionesPorPatentes`, `buscarAsignacionEnFecha`.
 *     (volvo buildAlertaDoc + resumenes_diarios)
 *   - Locks/idempotencia de crons: `adquirirIdempotenciaDiaria`,
 *     `adquirirLockTick`. (mantenimiento/sitrack/resumenes/volvo)
 *   - `fetchWithTimeout`. (volvo/sitrack/telemetria)
 *   - Destinatarios de resúmenes: `MANTENIMIENTO_DESTINATARIO_DNI`,
 *     `SEG_HIGIENE_DESTINATARIO_DNI`. (resumenes_diarios)
 *   - `TTL_RESUMEN_DIARIO_MIN`. (varios resúmenes)
 *   - `TIPOS_PELIGROSOS_SITRACK` + `TIPOS_CESVI_PUROS`. (icm/sitrack/resumenes)
 *
 * Re-exportado desde index.ts con `export * from "./comun"` — los
 * consumidores que importan de "./index" siguen funcionando. Los
 * módulos nuevos (volvo.ts, telemetria.ts) importan de "./comun" directo
 * para evitar el ciclo index↔módulo.
 */

import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";

// DNI del ADMIN que mantiene la app/bot (SANTIAGO). Recibe los resúmenes
// OPERATIVOS del sistema: caídas del bot + drifts de asignación.
// OJO: pese al nombre, NO es el jefe de mantenimiento de vehículos — ese es
// Emmanuel (ver MANTENIMIENTO_VEHICULOS_DNI). Nombre histórico, no renombrado
// por compat con resumenes_diarios.ts.
export const MANTENIMIENTO_DESTINATARIO_DNI = "35244439";

// DNI del jefe de mantenimiento de la FLOTA (CORCHETE EMMANUEL). Recibe el
// parte diario de advertencias exactas de los camiones Volvo (tell-tales en
// rojo/amarillo) + service preventivo por horas de motor. Ver
// volvo_mantenimiento.ts y project_volvo_estado_fundacion.md.
export const MANTENIMIENTO_VEHICULOS_DNI = "29820141";

// DNI del jefe de Seguridad e Higiene (MOLINA ALEJANDRA). Recibe el
// resumen diario de excesos de jornada (choferes que cruzaron 4h
// continuas o 12h diarias).
export const SEG_HIGIENE_DESTINATARIO_DNI = "34730329";

export const TTL_RESUMEN_DIARIO_MIN = 24 * 60; // resumenes diarios — vence en 24h

// ============================================================================
// DESTINATARIOS DE NOTIFICACIÓN — override desde Firestore
// ============================================================================
//
// Los DNIs hardcoded arriba son el DEFAULT — si nunca se editó nada en la
// app, las CFs los usan tal cual y todo funciona como siempre. Pero a
// partir de M5 (2026-05-24) el admin puede sobreescribir CADA destinatario
// desde la pantalla "Destinatarios de notificación" sin tocar código —
// los valores override viven en `META/destinatarios_notificacion` y este
// helper los lee con cache 5 min para no pegarle a Firestore en cada
// cron tick.
//
// Si Firestore falla / el doc no existe / la key no tiene override,
// devuelve el fallback hardcoded. Esto significa que el sistema sigue
// funcionando exactamente igual si el helper falla — defensivo.
//
// Cuando un cron consulta, el cache se chequea atómicamente — la
// primera CF dispara la lectura y las siguientes durante 5 min reusan.

let _destinatariosCache: Record<string, unknown> | null = null;
let _destinatariosCacheExpiraMs = 0;
const _destinatariosCacheTTLms = 5 * 60 * 1000; // 5 min

/**
 * Lee el doc `META/destinatarios_notificacion` con cache de 5 min.
 * Devuelve un map plano `{ key: dni }`. Si la lectura falla, devuelve
 * el cache vencido (si existe) o un map vacío — los callers ya tienen
 * fallback al hardcoded, así que un Firestore caído no rompe nada.
 */
async function _cargarDestinatarios(): Promise<Record<string, unknown>> {
  if (_destinatariosCache && Date.now() < _destinatariosCacheExpiraMs) {
    return _destinatariosCache;
  }
  try {
    const snap = await db
      .collection("META")
      .doc("destinatarios_notificacion")
      .get();
    if (snap.exists) {
      _destinatariosCache = snap.data() ?? {};
      _destinatariosCacheExpiraMs = Date.now() + _destinatariosCacheTTLms;
      return _destinatariosCache;
    }
    // El doc no existe — cacheamos un map vacío para no leer Firestore
    // en cada tick siguientes 5 min.
    _destinatariosCache = {};
    _destinatariosCacheExpiraMs = Date.now() + _destinatariosCacheTTLms;
    return _destinatariosCache;
  } catch {
    // En caso de error, devolvemos el cache viejo (aunque haya expirado)
    // o un map vacío. Mejor servir data potencialmente stale que romper.
    return _destinatariosCache ?? {};
  }
}

/**
 * Devuelve el DNI del destinatario para una key dada (ej. "serviceDiario",
 * "parteMantenimientoVolvo"). Si Firestore tiene override válido lo usa;
 * sino devuelve `fallbackHardcoded` (los `*_DESTINATARIO_DNI` exportados
 * arriba). Esto preserva el comportamiento actual si el operador nunca
 * editó nada — zero-downtime al deployar.
 *
 * Keys conocidas (alineadas con `reglasNotificacion` del bot health.js):
 *   - mantenimientoBot, driftsAsignaciones (Santiago)
 *   - parteMantenimientoVolvo, serviceDiario (Emmanuel)
 *   - excesosJornada, conductaManejo (Molina)
 *   - vencimientosProximosConsolidado (Giagante)
 *   - cachatoreEncargado (Errazu)
 *   - colaCreciente (admin del bot)
 */
export async function obtenerDestinatarioDni(
  key: string,
  fallbackHardcoded: string,
): Promise<string> {
  const map = await _cargarDestinatarios();
  const v = map[key];
  if (typeof v === "string" && v.trim().length > 0) {
    return v.trim();
  }
  return fallbackHardcoded;
}

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

// ─── Asignaciones chofer↔patente ───────────────────────────────────

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

// ─── Locks / idempotencia / fetch ──────────────────────────────────

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

/**
 * `true` si la excepción es transient (timeout / network / abort), no
 * un bug real. Sirve para distinguir en los catches de los pollers
 * (volvoAlertasPoller, sitrackEventosPoller, etc) entre:
 *   - bug: logger.error (cuenta como issue en Sentry/Cloud Logging)
 *   - transient: logger.warn (no inflama métricas, recoverable)
 *
 * Auditoria 2026-05-24: 69 de 80 errors/7d eran AbortError del API
 * Volvo (`fetch falló` por timeout 20s). Loguear como ERROR generaba
 * ruido sin actionable. Ahora se downgradan a WARN.
 */
export function esErrorTransient(e: unknown): boolean {
  if (!e) return false;
  const err = e as { name?: string; message?: string; cause?: unknown };
  const name = err.name || "";
  const msg = err.message || "";
  if (name === "AbortError" || name === "TimeoutError") return true;
  if (/abort|timeout|deadline|ECONNRESET|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|fetch failed|network|socket hang up|ECONNREFUSED/i.test(msg)) {
    return true;
  }
  // node-fetch / undici a veces anidan la causa real adentro.
  if (err.cause) return esErrorTransient(err.cause);
  return false;
}
