// ============================================================================
// Vigilador de jornada — v2 (refactor 2026-05-15)
// ============================================================================
//
// Modelo operativo Vecchi (alineado con norma YPF NO_0002913 + Excepción
// Rev01 firmada ago/2025 para carga general):
//
//   Una JORNADA = 24 hs = 12 hs conducción + 12 hs descanso.
//   12 hs conducción = 3 BLOQUES de 4 hs cada uno (3h45 manejo + 15 min pausa).
//     - Total manejo neto por jornada: 11h15 min.
//   12 hs descanso entre jornadas: mínimo 8 hs con camión detenido en MISMA
//   posición (radio 1000 m, margen GPS drift).
//
// La jornada NO se mide por día calendario. Cada jornada es lógica y se
// identifica por su `jornada_inicio_ts`. La colección `JORNADAS` reemplaza
// a la legacy `JORNADAS_CHOFER` (deprecada, se borra con script aparte).
//
// Disparadores que detienen al chofer (cualquiera dispara aviso + flag):
//   1. Bloque actual llegó a 4 hs sin pausa de 15 min → bloque excedido.
//   2. Cumplió 3 bloques → cuota cumplida.
//   3. Hora ART ≥ 00:00 → veda nocturna (política Vecchi: no maneja de noche).
//
// Reanudación: solo después de ≥ 8 hs detenido en misma posición.
//
// Fuente de datos: SITRACK_POSICIONES (último snapshot por patente).

import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";

// Resolver lazy de Firestore: initializeApp() corre en index.ts antes
// de invocarse cualquier export de este módulo, pero si llamamos
// admin.firestore() al top-level se evalúa durante el import (antes
// del initializeApp). Por eso lo envolvemos en un getter.
function db(): FirebaseFirestore.Firestore {
  return admin.firestore();
}
const Timestamp = admin.firestore.Timestamp;
const FieldValue = admin.firestore.FieldValue;
type FsTimestamp = admin.firestore.Timestamp;

// ─── Constantes ─────────────────────────────────────────────────────────────

export const UMBRAL_MOVIMIENTO_KMH = 15;
export const POLL_STALE_SEGUNDOS = 10 * 60;
export const PAUSA_BLOQUE_SEGUNDOS = 10 * 60; // 10 min internos; al chofer
// le pedimos 15 min. El delta absorbe delay GPS Sitrack (~1-3 min).
export const BLOQUE_ALERTA_TEMPRANA_SEGUNDOS = 3 * 3600 + 30 * 60; // 3h30
export const BLOQUE_LIMITE_SEGUNDOS = 3 * 3600 + 45 * 60; // 3h45 (fin bloque)
export const BLOQUE_EXCEDIDO_SEGUNDOS = 4 * 3600; // 4h sin pausa = falta
export const BLOQUES_POR_JORNADA = 3;
export const DESCANSO_MIN_SEGUNDOS = 8 * 3600;
export const DESCANSO_RADIO_METROS = 1000;
export const VEDA_NOCTURNA_DESDE_HORA = 0; // 00:00 ART
export const VEDA_NOCTURNA_HASTA_HORA = 6; // 06:00 ART (no se usa para alertar,
// el descanso de 8h ya garantiza no arrancar antes)
export const DELTA_MAX_SEGUNDOS = 600;
export const COLECCION = "JORNADAS";

// Banner global de testing (mismo que el resto de avisos automáticos).
const BANNER_TESTING =
  "_⚠️ ETAPA DE TESTING: si recibís este mensaje por error o ves algo " +
  "raro, avisá a Santiago (35244439)._\n\n";

// ─── Schema del doc JORNADAS/{dni}_{jornada_inicio_ms} ──────────────────────

export interface JornadaDoc {
  chofer_dni: string;
  jornada_inicio_ts: FsTimestamp;
  jornada_fin_ts: FsTimestamp | null;

  // Estado de bloques
  bloques_completos: number; // 0..3
  bloque_actual_manejo_seg: number;
  bloque_actual_pausa_seg: number;

  // Acumulados
  total_manejo_seg: number;
  ultima_actualizacion_ts: FsTimestamp;
  ultima_patente: string;
  ultima_lat: number | null;
  ultima_lng: number | null;

  // Tracking de descanso entre jornadas (8h misma posición)
  descanso_inicio_ts: FsTimestamp | null;
  descanso_inicio_lat: number | null;
  descanso_inicio_lng: number | null;
  descanso_segundos: number;

  // Estado actual descriptivo
  estado: string; // 'manejando' | 'pausa_intra_bloque' | 'descanso_post_bloque'
  //                | 'cuota_cumplida' | 'veda_nocturna' | 'descanso_jornada'

  // Flags de "alerta enviada" (idempotencia: 1 vez por jornada)
  alerta_3_30_enviada: boolean;
  alerta_3_45_enviada: boolean;
  alerta_cuota_enviada: boolean;
  alerta_veda_enviada: boolean;

  // Flags de infracción (alimentan resumen a Molina)
  bloque_excedido: boolean;
  cuota_excedida: boolean;
  veda_excedida: boolean;

  // Auditoría
  creado_en: FsTimestamp;
}

// ─── Helpers ────────────────────────────────────────────────────────────────

/**
 * Distancia Haversine entre 2 puntos GPS en metros.
 */
export function distanciaMetros(
  lat1: number, lng1: number,
  lat2: number, lng2: number
): number {
  const R = 6371000; // radio Tierra en metros
  const toRad = (g: number) => (g * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
      Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * Hora ART (0..23) de un timestamp en ms. ART es UTC-3 fijo.
 */
export function horaArt(tsMs: number): number {
  const partes = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    hour: "2-digit",
    hour12: false,
  }).format(new Date(tsMs));
  // "00".."23"
  return parseInt(partes, 10);
}

/**
 * Primer nombre de un nombre completo "APELLIDO NOMBRE" (estilo Vecchi).
 */
function primerNombre(full: string): string {
  const tokens = full.trim().split(/\s+/);
  if (tokens.length < 2) return tokens[0] ?? "";
  // Asumimos formato "APELLIDO NOMBRE" — el primer nombre es el 2do token.
  return tokens[1] ?? "";
}

/**
 * Random pick para variantes anti-baneo de WhatsApp.
 */
function rrPick(n: number): number {
  return Math.floor(Math.random() * n);
}

/**
 * Cargar set de choferes silenciados (comando /silenciar).
 */
async function cargarSilenciados(): Promise<Set<string>> {
  try {
    const snap = await db()
      .collection("BOT_SILENCIADOS_CHOFER")
      .where("silenciado_hasta", ">", Timestamp.now())
      .limit(500)
      .get();
    const set = new Set<string>();
    for (const d of snap.docs) set.add(d.id);
    return set;
  } catch (e) {
    logger.warn("[jornadas_v2.cargarSilenciados] falló", {
      error: (e as Error).message,
    });
    return new Set();
  }
}

// ─── Avisos al chofer ───────────────────────────────────────────────────────

interface EmpleadoLite {
  tel: string;
  saludo: string;
}

async function obtenerEmpleadoLite(dni: string): Promise<EmpleadoLite | null> {
  const empSnap = await db().collection("EMPLEADOS").doc(dni).get();
  if (!empSnap.exists) return null;
  const empData = empSnap.data() ?? {};
  if (empData.ACTIVO === false) return null;
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") return null;
  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";
  return { tel, saludo };
}

async function encolarAviso3h30(
  dni: string, patente: string
): Promise<void> {
  const emp = await obtenerEmpleadoLite(dni);
  if (!emp) return;
  const variantes = [
    `${emp.saludo},\n\n` +
      "Llevás 3 h 30 min de manejo en este bloque. *Te quedan 15 min* " +
      "para parar al menos 15 min y cerrar el bloque.\n\n" +
      `Buscá un lugar seguro para frenar el ${patente} antes de las 3 h 45.\n\n` +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
    `${emp.saludo}.\n\n` +
      "Aviso: 3 h 30 manejando seguido. En 15 min cumplís el límite del " +
      "bloque (3 h 45).\n\n" +
      `Frená el ${patente} en un lugar seguro y descansá al menos 15 min ` +
      "antes de retomar.\n\n" +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
    `${emp.saludo}, atención.\n\n` +
      "Tu bloque actual llegó a 3 h 30. Te quedan 15 min para buscar " +
      "dónde parar y descansar 15 min.\n\n" +
      `Después podés arrancar el bloque siguiente con el ${patente}.\n\n` +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
  ];
  await db().collection("COLA_WHATSAPP").add({
    telefono: emp.tel,
    mensaje: variantes[rrPick(variantes.length)],
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_v2_bloque_3h30",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: dni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada v2",
    alert_patente: patente,
  });
}

async function encolarAviso3h45(
  dni: string, patente: string
): Promise<void> {
  const emp = await obtenerEmpleadoLite(dni);
  if (!emp) return;
  const variantes = [
    `${emp.saludo},\n\n` +
      "*PARÁ AHORA — fin de bloque.* Cumpliste 3 h 45 de manejo.\n\n" +
      `Buscá un lugar seguro para el ${patente} y descansá al menos ` +
      "15 min antes de seguir. Si llegás a las 4 h sin parar, queda " +
      "registrado como falta.\n\n" +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
    `${emp.saludo}.\n\n` +
      "*Fin del bloque (3 h 45).* Tenés que parar 15 min ahora.\n\n" +
      `Frená el ${patente} en un lugar seguro. Si pasás las 4 h sin pausa, ` +
      "se registra incumplimiento del descanso obligatorio.\n\n" +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
    `${emp.saludo}, urgente.\n\n` +
      "*Llegaste al límite del bloque (3 h 45 manejando).* Detené el " +
      `${patente} ya — descansá 15 min antes de retomar.\n\n` +
      "El incumplimiento de la pausa queda registrado.\n\n" +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
  ];
  await db().collection("COLA_WHATSAPP").add({
    telefono: emp.tel,
    mensaje: variantes[rrPick(variantes.length)],
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_v2_bloque_3h45",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: dni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada v2",
    alert_patente: patente,
  });
}

async function encolarAvisoCuotaCumplida(
  dni: string, patente: string
): Promise<void> {
  const emp = await obtenerEmpleadoLite(dni);
  if (!emp) return;
  const variantes = [
    `${emp.saludo},\n\n` +
      "*Cumpliste los 3 bloques de la jornada* (11 h 15 min de manejo " +
      "neto + 45 min de pausas).\n\n" +
      `Frená el ${patente} en un lugar seguro y descansá *mínimo 8 h ` +
      "sin moverte* antes de arrancar una nueva jornada.\n\n" +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
    `${emp.saludo}.\n\n` +
      "*Jornada completa — 3 bloques cumplidos.* No podés seguir " +
      "manejando hasta tener 8 h de descanso con el camión detenido.\n\n" +
      `Buscá dónde estacionar el ${patente} y cerrá la jornada.\n\n` +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
    `${emp.saludo}, atención.\n\n` +
      "*Cuota diaria cumplida (3 bloques).* La jornada se cierra ahora.\n\n" +
      `Estacioná el ${patente} en un lugar seguro y descansá 8 h en el ` +
      "mismo lugar para que arranque la próxima jornada.\n\n" +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
  ];
  await db().collection("COLA_WHATSAPP").add({
    telefono: emp.tel,
    mensaje: variantes[rrPick(variantes.length)],
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_v2_cuota_cumplida",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: dni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada v2",
    alert_patente: patente,
  });
}

async function encolarAvisoVedaNocturna(
  dni: string, patente: string
): Promise<void> {
  const emp = await obtenerEmpleadoLite(dni);
  if (!emp) return;
  const variantes = [
    `${emp.saludo},\n\n` +
      "*Entraste en veda nocturna (00:00 ART).* Por política, no se " +
      "maneja después de las 00:00.\n\n" +
      `Detené el ${patente} en un lugar seguro y descansá. El ` +
      "incumplimiento queda registrado.\n\n" +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
    `${emp.saludo}.\n\n` +
      "*00:00 ART — veda nocturna activa.* Por norma de Vecchi no " +
      "podés seguir manejando.\n\n" +
      `Frená el ${patente} ahora en un lugar seguro y descansá hasta ` +
      "completar 8 h sin moverte.\n\n" +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
    `${emp.saludo}, urgente.\n\n` +
      "*Veda nocturna iniciada (00:00 ART).* No podés conducir hasta " +
      "que tengas 8 h de descanso completo.\n\n" +
      `Estacioná el ${patente} ahora — el incumplimiento se registra ` +
      "para Seg e Higiene.\n\n" +
      BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
  ];
  await db().collection("COLA_WHATSAPP").add({
    telefono: emp.tel,
    mensaje: variantes[rrPick(variantes.length)],
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_v2_veda_nocturna",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: dni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada v2",
    alert_patente: patente,
  });
}

// ─── Helpers de jornada (load + create) ─────────────────────────────────────

/**
 * Carga la jornada abierta (jornada_fin_ts == null) de un chofer.
 * Devuelve null si no tiene jornada abierta.
 */
async function cargarJornadaAbierta(
  dni: string
): Promise<{ ref: FirebaseFirestore.DocumentReference;
            data: JornadaDoc } | null> {
  const snap = await db()
    .collection(COLECCION)
    .where("chofer_dni", "==", dni)
    .where("jornada_fin_ts", "==", null)
    .limit(1)
    .get();
  if (snap.empty) return null;
  const d = snap.docs[0];
  return { ref: d.ref, data: d.data() as JornadaDoc };
}

/**
 * Crea una jornada nueva para un chofer.
 */
function nuevaJornada(
  dni: string, patente: string, lat: number | null, lng: number | null
): { ref: FirebaseFirestore.DocumentReference; data: JornadaDoc } {
  const ahora = Timestamp.now();
  const ts = ahora.toMillis();
  const ref = db().collection(COLECCION).doc(`${dni}_${ts}`);
  const data: JornadaDoc = {
    chofer_dni: dni,
    jornada_inicio_ts: ahora,
    jornada_fin_ts: null,
    bloques_completos: 0,
    bloque_actual_manejo_seg: 0,
    bloque_actual_pausa_seg: 0,
    total_manejo_seg: 0,
    ultima_actualizacion_ts: ahora,
    ultima_patente: patente,
    ultima_lat: lat,
    ultima_lng: lng,
    descanso_inicio_ts: null,
    descanso_inicio_lat: null,
    descanso_inicio_lng: null,
    descanso_segundos: 0,
    estado: "manejando",
    alerta_3_30_enviada: false,
    alerta_3_45_enviada: false,
    alerta_cuota_enviada: false,
    alerta_veda_enviada: false,
    bloque_excedido: false,
    cuota_excedida: false,
    veda_excedida: false,
    creado_en: ahora,
  };
  return { ref, data };
}

// ─── Tick principal del vigilador ───────────────────────────────────────────

/**
 * Una corrida del cron — itera todos los SITRACK_POSICIONES y aplica
 * la lógica de bloques a cada chofer con jornada abierta o que arranca
 * una nueva.
 */
export async function tickVigiladorJornada(): Promise<void> {
  logger.info("[jornadas_v2.tick] iniciando");

  const snap = await db().collection("SITRACK_POSICIONES").limit(5000).get();
  const silenciados = await cargarSilenciados();

  // Race condition fix (auditoria 2026-05-16): si por drift de
  // CHOFER_DISTINTO un mismo DNI aparece en 2 patentes (chofer logueado
  // con su iButton + otro tractor reportando su nombre legacy), antes
  // procesabamos las 2 iteraciones y el segundo update PISABA el
  // primero. Ahora deduplicamos por DNI antes del loop — nos quedamos
  // con la patente que tiene reporte mas reciente (mejor proxy de
  // "donde realmente esta el chofer ahora").
  const choferesProcesados = new Map<string, {
    docPos: typeof snap.docs[number];
    polledMs: number;
  }>();
  for (const docPos of snap.docs) {
    const data = docPos.data();
    const dni = (data.driver_dni ?? "").toString().trim();
    if (!dni) continue;
    const polledMs =
      (data.consultado_en as FsTimestamp | undefined)?.toMillis() ?? 0;
    const previo = choferesProcesados.get(dni);
    if (!previo || polledMs > previo.polledMs) {
      choferesProcesados.set(dni, { docPos, polledMs });
    }
  }

  let evaluados = 0;
  let avisosEnviados = 0;
  let silenciadosCount = 0;
  let nuevasJornadas = 0;
  let cerradas = 0;

  for (const [dni, entry] of choferesProcesados.entries()) {
    const docPos = entry.docPos;
    const data = docPos.data();

    const patente = docPos.id;
    const speed = typeof data.speed === "number" ? data.speed : 0;
    // Default ignitionOn=FALSE (fail-closed). Antes el default era true
    // — si SITRACK_POSICIONES no traia el campo `ignition`, considerabamos
    // que el motor estaba encendido y inflabamos las jornadas con tiempo
    // de tractores parados. Mejor no contar tiempo que no podemos
    // confirmar que es manejo real.
    const ignitionOn =
      typeof data.ignition === "boolean" ? data.ignition : false;
    const lat = typeof data.lat === "number" ? data.lat : null;
    const lng = typeof data.lng === "number" ? data.lng : null;
    const polledMs = entry.polledMs;
    const polledHaceSeg =
      polledMs > 0 ? (Date.now() - polledMs) / 1000 : Infinity;
    const pollStale = polledHaceSeg > POLL_STALE_SEGUNDOS;
    const manejando = !pollStale && ignitionOn && speed > UMBRAL_MOVIMIENTO_KMH;

    evaluados++;

    try {
      // Cargar o crear jornada
      let entrada = await cargarJornadaAbierta(dni);
      if (!entrada) {
        // No hay jornada abierta. Solo creamos una si el chofer está
        // manejando ahora — sino el cron sigue silencioso.
        if (!manejando) continue;
        entrada = nuevaJornada(dni, patente, lat, lng);
        await entrada.ref.set(entrada.data);
        nuevasJornadas++;
      }

      const j = entrada.data;
      const ahora = Timestamp.now();
      const deltaSegBruto =
        (ahora.toMillis() - j.ultima_actualizacion_ts.toMillis()) / 1000;
      const deltaSeg = Math.min(
        Math.max(deltaSegBruto, 0),
        DELTA_MAX_SEGUNDOS
      );

      // Avisos a encolar después de actualizar el doc. Lista (no scalar)
      // — antes era un solo `avisoTipo` que se sobrescribia cuando se
      // cruzaban varios umbrales en mismo tick (ej. cron retrasado o
      // primer tick post-jornada vieja con 3h30 + 3h45 + cuota +
      // veda simultaneos). Solo se mandaba el ultimo, los anteriores
      // se perdian silenciosamente. Ahora encolamos TODOS los que se
      // cumplen en este tick.
      const avisosPendientes: Array<"3h30" | "3h45" | "cuota" | "veda"> = [];

      if (manejando) {
        // === Está manejando ===
        j.bloque_actual_manejo_seg += deltaSeg;
        j.bloque_actual_pausa_seg = 0;
        j.estado = "manejando";

        // Reset tracking descanso
        j.descanso_inicio_ts = null;
        j.descanso_inicio_lat = null;
        j.descanso_inicio_lng = null;
        j.descanso_segundos = 0;

        // Avisos del bloque
        if (
          j.bloque_actual_manejo_seg >= BLOQUE_ALERTA_TEMPRANA_SEGUNDOS &&
          !j.alerta_3_30_enviada
        ) {
          avisosPendientes.push("3h30");
          j.alerta_3_30_enviada = true;
        }
        if (
          j.bloque_actual_manejo_seg >= BLOQUE_LIMITE_SEGUNDOS &&
          !j.alerta_3_45_enviada
        ) {
          avisosPendientes.push("3h45");
          j.alerta_3_45_enviada = true;
        }
        if (
          j.bloque_actual_manejo_seg >= BLOQUE_EXCEDIDO_SEGUNDOS &&
          !j.bloque_excedido
        ) {
          j.bloque_excedido = true;
        }

        // Cuota cumplida (avisa al chofer 1 vez por jornada si insiste en manejar)
        if (
          j.bloques_completos >= BLOQUES_POR_JORNADA &&
          !j.alerta_cuota_enviada
        ) {
          avisosPendientes.push("cuota");
          j.alerta_cuota_enviada = true;
          j.cuota_excedida = true;
        }

        // Veda nocturna (00:00-06:00 ART)
        const hora = horaArt(ahora.toMillis());
        const enVeda =
          hora >= VEDA_NOCTURNA_DESDE_HORA && hora < VEDA_NOCTURNA_HASTA_HORA;
        if (enVeda && !j.alerta_veda_enviada) {
          avisosPendientes.push("veda");
          j.alerta_veda_enviada = true;
          j.veda_excedida = true;
        }

        if (lat != null) j.ultima_lat = lat;
        if (lng != null) j.ultima_lng = lng;
      } else {
        // === Está parado o speed bajo ===
        j.bloque_actual_pausa_seg += deltaSeg;
        j.estado = "pausa_intra_bloque";

        // Si pausa >= 15 min internos: cierra el bloque actual
        if (j.bloque_actual_pausa_seg >= PAUSA_BLOQUE_SEGUNDOS) {
          if (j.bloque_actual_manejo_seg > 0) {
            j.bloques_completos += 1;
            j.total_manejo_seg += j.bloque_actual_manejo_seg;
            j.bloque_actual_manejo_seg = 0;
            // Reset alertas del bloque para el próximo
            j.alerta_3_30_enviada = false;
            j.alerta_3_45_enviada = false;
            j.estado = "descanso_post_bloque";
          }
          // El bloque_actual_pausa_seg sigue acumulando hacia los 8h
          // de descanso de jornada (no se resetea acá).
        }

        // Tracking descanso 8h con misma posición
        if (lat != null && lng != null) {
          if (j.descanso_inicio_ts == null) {
            j.descanso_inicio_ts = ahora;
            j.descanso_inicio_lat = lat;
            j.descanso_inicio_lng = lng;
            j.descanso_segundos = 0;
          } else if (
            j.descanso_inicio_lat != null &&
            j.descanso_inicio_lng != null
          ) {
            const dist = distanciaMetros(
              j.descanso_inicio_lat, j.descanso_inicio_lng, lat, lng
            );
            if (dist > DESCANSO_RADIO_METROS) {
              // Se movió fuera del radio — reset
              j.descanso_inicio_ts = ahora;
              j.descanso_inicio_lat = lat;
              j.descanso_inicio_lng = lng;
              j.descanso_segundos = 0;
            } else {
              j.descanso_segundos += deltaSeg;
            }
          }
        }

        // Si descanso acumulado >= 8h → cierra jornada
        if (j.descanso_segundos >= DESCANSO_MIN_SEGUNDOS) {
          j.estado = "descanso_jornada";
          j.jornada_fin_ts = ahora;
          cerradas++;
        }
      }

      j.ultima_actualizacion_ts = ahora;
      j.ultima_patente = patente;

      await entrada.ref.update(j as unknown as Record<string, unknown>);

      // Encolar avisos (todos los pendientes, no solo el ultimo)
      for (const avisoTipo of avisosPendientes) {
        if (silenciados.has(dni)) {
          silenciadosCount++;
          logger.info("[jornadas_v2.tick] aviso silenciado", {
            dni, patente, tipo: avisoTipo,
          });
          continue;
        }
        if (avisoTipo === "3h30") await encolarAviso3h30(dni, patente);
        else if (avisoTipo === "3h45") await encolarAviso3h45(dni, patente);
        else if (avisoTipo === "cuota") await encolarAvisoCuotaCumplida(dni, patente);
        else if (avisoTipo === "veda") await encolarAvisoVedaNocturna(dni, patente);
        avisosEnviados++;
      }
    } catch (e) {
      logger.warn("[jornadas_v2.tick] falló para chofer", {
        dni, patente, error: (e as Error).message,
      });
    }
  }

  logger.info("[jornadas_v2.tick] OK", {
    evaluados, avisosEnviados, silenciadosCount, nuevasJornadas, cerradas,
    silenciados: silenciados.size,
  });
}

// ─── Resumen diario a Molina ────────────────────────────────────────────────

const SEG_HIGIENE_DNI = "34730329";

/**
 * Cron 8 AM ART. Lee jornadas con flags de exceso (bloque_excedido,
 * cuota_excedida, veda_excedida) que cerraron ayer o están abiertas con
 * alguno de los flags. Manda 1 WhatsApp a Molina.
 */
export async function armarResumenJornadasDiario(): Promise<void> {
  logger.info("[jornadas_v2.resumen] iniciando");

  // Rango: día calendario ART AYER.
  const ahora = new Date();
  const fechaArtAyer = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date(ahora.getTime() - 24 * 60 * 60 * 1000));
  const fechaArtHoy = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).format(ahora);
  const desdeMs = Date.parse(`${fechaArtAyer}T00:00:00-03:00`);
  const hastaMs = Date.parse(`${fechaArtHoy}T00:00:00-03:00`);

  // Query: jornadas que cerraron ayer Y tienen al menos un flag de exceso
  // O jornadas abiertas con flag (raras pero posibles si una jornada lleva
  // varios días por algún problema de datos).
  const snapCerradas = await db()
    .collection(COLECCION)
    .where("jornada_fin_ts", ">=", Timestamp.fromMillis(desdeMs))
    .where("jornada_fin_ts", "<", Timestamp.fromMillis(hastaMs))
    .get();

  interface Exceso {
    choferDni: string;
    patente: string;
    inicio: FsTimestamp;
    fin: FsTimestamp | null;
    bloquesCompletos: number;
    totalManejoSeg: number;
    bloqueExcedido: boolean;
    cuotaExcedida: boolean;
    vedaExcedida: boolean;
  }
  const excesos: Exceso[] = [];

  for (const d of snapCerradas.docs) {
    const j = d.data() as JornadaDoc;
    if (!j.bloque_excedido && !j.cuota_excedida && !j.veda_excedida) continue;
    excesos.push({
      choferDni: j.chofer_dni,
      patente: j.ultima_patente,
      inicio: j.jornada_inicio_ts,
      fin: j.jornada_fin_ts,
      bloquesCompletos: j.bloques_completos,
      totalManejoSeg: j.total_manejo_seg,
      bloqueExcedido: j.bloque_excedido,
      cuotaExcedida: j.cuota_excedida,
      vedaExcedida: j.veda_excedida,
    });
  }

  // Destinatario (Molina)
  const empSnap = await db().collection("EMPLEADOS").doc(SEG_HIGIENE_DNI).get();
  if (!empSnap.exists) {
    logger.error("[jornadas_v2.resumen] destinatario no existe", {
      dni: SEG_HIGIENE_DNI,
    });
    return;
  }
  const empData = empSnap.data() ?? {};
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") {
    logger.error("[jornadas_v2.resumen] destinatario sin TELEFONO");
    return;
  }
  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";
  const fmtFecha = fechaArtAyer.split("-").reverse().join("/");

  function fmtHm(s: number): string {
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    return `${h}:${m.toString().padStart(2, "0")}`;
  }

  if (excesos.length === 0) {
    const mensaje =
      `${saludo},\n\n` +
      `📋 *Resumen jornadas — ${fmtFecha}*\n\n` +
      "✅ Sin incidencias: ninguna jornada cerrada ayer registró " +
      "exceso de bloque, cuota o veda nocturna.\n\n" +
      BANNER_TESTING + "_Coopertrans Móvil — Aviso automático._";
    await db().collection("COLA_WHATSAPP").add({
      telefono: tel, mensaje, estado: "PENDIENTE",
      encolado_en: FieldValue.serverTimestamp(),
      enviado_en: null, error: null, intentos: 0,
      origen: "resumen_jornadas_v2", destinatario_coleccion: "EMPLEADOS",
      destinatario_id: SEG_HIGIENE_DNI, campo_base: "JORNADA",
      admin_dni: "BOT", admin_nombre: "Bot resumen jornadas v2",
    });
    logger.info("[jornadas_v2.resumen] OK (sin excesos)");
    return;
  }

  // Lookup nombres
  const nombrePorDni = new Map<string, string>();
  for (const x of excesos) {
    if (nombrePorDni.has(x.choferDni)) continue;
    try {
      const s = await db().collection("EMPLEADOS").doc(x.choferDni).get();
      const n = s.exists ? (s.data()?.NOMBRE ?? "").toString().trim() : "";
      nombrePorDni.set(x.choferDni, n);
    } catch {
      nombrePorDni.set(x.choferDni, "");
    }
  }

  const lineas = excesos.map((x) => {
    const nombre = nombrePorDni.get(x.choferDni) || `DNI ${x.choferDni}`;
    const flags: string[] = [];
    if (x.bloqueExcedido) flags.push("bloque > 4h sin pausa");
    if (x.cuotaExcedida) flags.push("manejó post-cuota cumplida");
    if (x.vedaExcedida) flags.push("circuló después de 00:00 ART");
    const incioFmt = new Intl.DateTimeFormat("es-AR", {
      timeZone: "America/Argentina/Buenos_Aires",
      day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit",
      hour12: false,
    }).format(x.inicio.toDate());
    return (
      `🚛 *${x.patente || "—"}* — ${nombre} (DNI ${x.choferDni})\n` +
      `   Jornada: arrancó ${incioFmt}, ${x.bloquesCompletos}/3 bloques, ` +
      `${fmtHm(x.totalManejoSeg)} hs manejando\n` +
      `   ⚠️ ${flags.join(", ")}`
    );
  });

  const mensaje =
    `${saludo},\n\n` +
    `📋 *Resumen jornadas — ${fmtFecha}*\n\n` +
    `${excesos.length} jornada${excesos.length === 1 ? "" : "s"} con ` +
    "incidencias:\n\n" +
    `${lineas.join("\n\n")}\n\n` +
    "_Modelo de jornada: 3 bloques de 4 hs (3 h 45 manejo + 15 min " +
    "pausa). Veda nocturna desde las 00:00 ART. La jornada se cierra " +
    "después de 8 hs con el camión detenido._\n\n" +
    BANNER_TESTING + "_Coopertrans Móvil — Aviso automático._";

  await db().collection("COLA_WHATSAPP").add({
    telefono: tel, mensaje, estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    enviado_en: null, error: null, intentos: 0,
    origen: "resumen_jornadas_v2", destinatario_coleccion: "EMPLEADOS",
    destinatario_id: SEG_HIGIENE_DNI, campo_base: "JORNADA",
    admin_dni: "BOT", admin_nombre: "Bot resumen jornadas v2",
  });

  logger.info("[jornadas_v2.resumen] OK", {
    excesos: excesos.length, destinatario: SEG_HIGIENE_DNI,
  });
}
