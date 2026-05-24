// =============================================================================
// CANALES PAUSADOS — pausa temporal de categorías de notificación
// =============================================================================
//
// Lee el doc `META/canales_pausados` con cache 5 min y permite a los crons
// y triggers preguntarle "¿está pausada la categoría X?". Si sí, se saltan
// silenciosamente el envío. Sirve para "vacaciones" del receptor, testing
// de un módulo, o silenciar temporal de una categoría ruidosa.
//
// Shape del doc:
// {
//   mantenimientoBot: {
//     hasta_iso: "2026-06-01T03:00:00Z" | null,   // null = indefinido
//     motivo: "Vacaciones Santiago",              // opcional
//     pausado_en: Timestamp,
//     pausado_por_dni: "35244439",
//   },
//   ...
// }
//
// La edición vive en la pantalla "Estado del Bot" → card "Reglas de
// notificación" → botón "Pausar..." / "Reanudar" por canal.
//
// Diseño defensivo: cualquier falla de Firestore se interpreta como
// "no hay pausa" (devuelve false). Mejor mandar un mensaje de más que
// silenciar uno crítico por un fallo de red.

import * as admin from "firebase-admin";

const _db = (): admin.firestore.Firestore => admin.firestore();

const COL_META = "META";
const DOC_CANALES_PAUSADOS = "canales_pausados";

const TTL_MS = 5 * 60 * 1000;

let _cache: Record<string, unknown> | null = null;
let _cacheExpiraMs = 0;

/** Info viva de la pausa de un canal. `null` = no pausado. */
export interface InfoPausa {
  /** ISO timestamp hasta cuando dura la pausa. `null` = indefinido. */
  hastaIso: string | null;
  motivo: string | null;
  pausadoEnIso: string | null;
  pausadoPorDni: string | null;
}

async function _cargar(): Promise<Record<string, unknown>> {
  if (_cache && Date.now() < _cacheExpiraMs) return _cache;
  try {
    const snap = await _db()
      .collection(COL_META)
      .doc(DOC_CANALES_PAUSADOS)
      .get();
    if (snap.exists) {
      _cache = (snap.data() as Record<string, unknown>) ?? {};
    } else {
      _cache = {};
    }
    _cacheExpiraMs = Date.now() + TTL_MS;
    return _cache;
  } catch {
    // Falla de Firestore → "no hay pausa". Defensivo: preferimos enviar
    // un mensaje de más a silenciar uno crítico por un fallo de red.
    return _cache ?? {};
  }
}

/**
 * Devuelve la info de pausa de `key` o `null` si está activo.
 * Si la fecha `hasta_iso` ya pasó, se considera no pausado.
 */
export async function infoPausa(key: string): Promise<InfoPausa | null> {
  const map = await _cargar();
  const raw = map[key];
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const hastaIsoRaw = obj.hasta_iso;
  const hastaIso =
    typeof hastaIsoRaw === "string" && hastaIsoRaw.length > 0
      ? hastaIsoRaw
      : null;

  // Si tiene fecha hasta, verificar que no haya pasado.
  if (hastaIso) {
    const hastaMs = Date.parse(hastaIso);
    if (Number.isFinite(hastaMs) && Date.now() >= hastaMs) return null;
  }

  const motivoRaw = obj.motivo;
  const motivo =
    typeof motivoRaw === "string" && motivoRaw.trim().length > 0
      ? motivoRaw.trim()
      : null;

  const pausadoEnRaw = obj.pausado_en;
  let pausadoEnIso: string | null = null;
  if (
    pausadoEnRaw &&
    typeof pausadoEnRaw === "object" &&
    "toDate" in pausadoEnRaw &&
    typeof (pausadoEnRaw as { toDate: () => Date }).toDate === "function"
  ) {
    try {
      pausadoEnIso = (pausadoEnRaw as { toDate: () => Date })
        .toDate()
        .toISOString();
    } catch {
      pausadoEnIso = null;
    }
  }

  const pausadoPorRaw = obj.pausado_por_dni;
  const pausadoPorDni =
    typeof pausadoPorRaw === "string" && pausadoPorRaw.trim().length > 0
      ? pausadoPorRaw.trim()
      : null;

  return { hastaIso, motivo, pausadoEnIso, pausadoPorDni };
}

/**
 * Helper conveniente: `true` si el canal está pausado (no expirado).
 * Úsalo al inicio de un cron / trigger:
 *
 *     if (await estaCanalPausado("mantenimientoBot")) return;
 */
export async function estaCanalPausado(key: string): Promise<boolean> {
  return (await infoPausa(key)) !== null;
}

/** Invalida el cache (tests / mock). */
export function _invalidarCacheCanalesPausados(): void {
  _cache = null;
  _cacheExpiraMs = 0;
}
