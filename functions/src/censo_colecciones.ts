// =============================================================================
// CENSO MENSUAL DE COLECCIONES — tamaño real de la base, mes a mes
// =============================================================================
// Nació como scripts/stats_colecciones.js (auditoría 2026-06-12, corrido a
// mano: 61 colecciones / ~197.600 docs). Cloud-first (preferencia multi-PC):
// el día 1 de cada mes cuenta los docs de TODAS las colecciones raíz con
// aggregate count() (1 read por cada 1000 docs contados — el censo entero
// cuesta ~200 reads), persiste el snapshot en STATS y compara contra el mes
// anterior:
//   - colección NUEVA → para clasificar (¿backup? ¿TTL? ¿rules?).
//   - crecimiento > +40% → puede ser orgánico o un accidente silencioso
//     (poller en loop, trigger amplificando writes) — mirar antes de que
//     sea factura.
// El resumen va SIEMPRE por WhatsApp (es mensual, barato y visible); las
// anomalías van resaltadas adentro.
//
// Lógica de comparación PURA — tests en test/censo_colecciones.test.js.

import * as logger from "firebase-functions/logger";
import { FieldValue } from "firebase-admin/firestore";

import { db } from "./setup";
import {
  adquirirIdempotenciaDiaria,
  liberarLockConReintentos,
  MANTENIMIENTO_DESTINATARIO_DNI,
  obtenerDestinatarioDni,
  onScheduleConLatido,
} from "./comun";
import { expiraEnMin } from "./helpers";

const TZ = "America/Argentina/Buenos_Aires";
export const UMBRAL_CRECIMIENTO_PCT = 40;

// ─── Lógica pura ─────────────────────────────────────────────────────────────

export interface DiffCenso {
  nuevas: { id: string; docs: number }[];
  crecimientos: { id: string; antes: number; ahora: number; pct: number }[];
  totalDocs: number;
  totalColecciones: number;
}

/** Compara el censo actual contra el anterior (null si es el primero). */
export function compararCensos(
  actual: Record<string, number>,
  anterior: Record<string, number> | null,
  umbralPct: number = UMBRAL_CRECIMIENTO_PCT,
): DiffCenso {
  const nuevas: DiffCenso["nuevas"] = [];
  const crecimientos: DiffCenso["crecimientos"] = [];
  let totalDocs = 0;
  for (const [id, ahora] of Object.entries(actual)) {
    totalDocs += ahora;
    const antes = anterior?.[id];
    if (antes == null) {
      if (anterior != null) nuevas.push({ id, docs: ahora });
      continue;
    }
    // Dos disparadores de "crecimiento sospechoso":
    //  (a) RELATIVO: >umbral% con piso de 500 docs (que un contador chico
    //      pase de 10 a 20 no es señal).
    //  (b) ABSOLUTO: explosión ≥10× llegando a >2000 docs — atrapa una
    //      colección que arranca chica y se dispara (poller en loop sobre
    //      una colección nueva) aunque el piso relativo no la agarre.
    const relativo = antes >= 500 && ahora > antes * (1 + umbralPct / 100);
    const absoluto = ahora >= 10 * Math.max(antes, 1) && ahora > 2000;
    if (relativo || absoluto) {
      crecimientos.push({
        id, antes, ahora,
        pct: Math.round(((ahora - antes) / Math.max(antes, 1)) * 100),
      });
    }
  }
  nuevas.sort((a, b) => b.docs - a.docs);
  crecimientos.sort((a, b) => b.pct - a.pct);
  return {
    nuevas, crecimientos,
    totalDocs,
    totalColecciones: Object.keys(actual).length,
  };
}

const fmt = (n: number) => n.toLocaleString("es-AR");

/** Resumen mensual para WhatsApp. */
export function construirMensajeCenso(
  mesKey: string,
  actual: Record<string, number>,
  diff: DiffCenso,
): string {
  const top = Object.entries(actual)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5)
    .map(([id, n]) => `• ${id}: ${fmt(n)}`);
  const partes = [
    `📊 *Censo Firestore — ${mesKey}*`,
    `${diff.totalColecciones} colecciones · ${fmt(diff.totalDocs)} docs`,
    "",
    "Top 5:",
    ...top,
  ];
  if (diff.crecimientos.length > 0) {
    partes.push("", "⚠️ Crecimiento fuerte (>+" +
      `${UMBRAL_CRECIMIENTO_PCT}% en el mes):`);
    for (const c of diff.crecimientos) {
      partes.push(`• ${c.id}: ${fmt(c.antes)} → ${fmt(c.ahora)} (+${c.pct}%)`);
    }
  }
  if (diff.nuevas.length > 0) {
    partes.push("", "🆕 Colecciones nuevas (clasificar: ¿backup/TTL/rules?):");
    for (const n of diff.nuevas) {
      partes.push(`• ${n.id} (${fmt(n.docs)} docs)`);
    }
  }
  if (diff.crecimientos.length === 0 && diff.nuevas.length === 0) {
    partes.push("", "Sin novedades — crecimiento normal.");
  }
  return partes.join("\n");
}

/** "2026-06" del mes ANTERIOR al ahora dado, en ART (el censo corre el día
 *  1 y retrata el mes que acaba de cerrar). */
export function mesKeyAnteriorArt(ahoraMs: number): string {
  const hoy = new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ, year: "numeric", month: "2-digit",
  }).format(new Date(ahoraMs)); // "YYYY-MM"
  const [y, m] = hoy.split("-").map(Number);
  const prevY = m === 1 ? y - 1 : y;
  const prevM = m === 1 ? 12 : m - 1;
  return `${prevY}-${String(prevM).padStart(2, "0")}`;
}

// ─── Cron ────────────────────────────────────────────────────────────────────

export const censoColeccionesMensual = onScheduleConLatido(
  "censoColeccionesMensual",
  {
    schedule: "30 3 1 * *", // día 1, 03:30 ART (fuera de los crons de 8 AM)
    timeZone: TZ,
    timeoutSeconds: 300,
  },
  async () => {
    const mesKey = mesKeyAnteriorArt(Date.now());

    // 1) Contar todas las colecciones raíz.
    const cols = await db.listCollections();
    const actual: Record<string, number> = {};
    for (const c of cols) {
      try {
        const snap = await c.count().get();
        actual[c.id] = snap.data().count;
      } catch (e) {
        logger.warn(`[censo] no se pudo contar ${c.id}`, {
          error: (e as Error).message,
        });
      }
    }

    // 2) Leer el censo del mes anterior (si existe) y comparar.
    const prevKey = mesKeyAnteriorArt(
      Date.now() - 28 * 24 * 60 * 60 * 1000,
    );
    const prevSnap = await db.collection("STATS")
      .doc(`censo_${prevKey}`).get();
    const anterior = prevSnap.exists ?
      (prevSnap.data()?.conteos as Record<string, number>) ?? null : null;
    const diff = compararCensos(actual, anterior);

    // 3) Persistir el snapshot del mes.
    await db.collection("STATS").doc(`censo_${mesKey}`).set({
      mes: mesKey,
      conteos: actual,
      total_docs: diff.totalDocs,
      total_colecciones: diff.totalColecciones,
      generado_en: FieldValue.serverTimestamp(),
    });
    logger.info("[censo] snapshot persistido", {
      mes: mesKey,
      colecciones: diff.totalColecciones,
      docs: diff.totalDocs,
      crecimientos: diff.crecimientos.length,
      nuevas: diff.nuevas.length,
    });

    // 4) Idempotencia del envío (mismo patrón que los 4 resúmenes diarios):
    //    un retry/double-trigger de Cloud Scheduler no debe mandar el censo
    //    dos veces el mismo mes. El write de STATS de arriba puede correr n
    //    veces (set idempotente); solo gateamos el WhatsApp.
    const histRef = db
      .collection("AVISOS_AUTOMATICOS_HISTORICO")
      .doc(`censo_mensual_${mesKey}`);
    if (!(await adquirirIdempotenciaDiaria(histRef, "censo_mensual"))) {
      logger.info("[censo] ya enviado este mes, skip", { mes: mesKey });
      return;
    }

    let exitoCron = false;
    try {
      // 5) Resumen por WhatsApp (mensual: va siempre).
      const dni = await obtenerDestinatarioDni(
        "mantenimientoBot", MANTENIMIENTO_DESTINATARIO_DNI,
      );
      const emp = await db.collection("EMPLEADOS").doc(dni).get();
      const tel = (emp.data()?.TELEFONO ?? "").toString().trim();
      if (!tel) {
        // ERROR (no warn): sin teléfono el censo NUNCA llega y, salvo que se
        // mire el log, pasa desapercibido. El finally libera el lock para
        // reintentar al re-deployar el destinatario.
        logger.error("[censo] destinatario sin TELEFONO — censo no enviado", {
          dni,
        });
        return;
      }
      await db.collection("COLA_WHATSAPP").add({
        telefono: tel,
        mensaje: construirMensajeCenso(mesKey, actual, diff),
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
        expira_en: expiraEnMin(24 * 60),
        enviado_en: null,
        error: null,
        intentos: 0,
        origen: "censo_mensual",
        destinatario_coleccion: "EMPLEADOS",
        destinatario_id: dni,
        campo_base: "CENSO_FIRESTORE",
        admin_dni: "BOT",
        admin_nombre: "Censo mensual",
      });
      exitoCron = true;
    } finally {
      // Si el envío falló (o no había teléfono), liberamos el lock para que
      // un retry / próxima corrida pueda completarlo.
      if (!exitoCron) {
        await liberarLockConReintentos(histRef, "censoColeccionesMensual");
      }
    }
  },
);
