// =============================================================================
// CRON DE LOS CRONS — watchdog de salud de los onSchedule (auditoría 2026-06-12)
// =============================================================================
// Cada cron registra su latido en CRON_HEALTH/{id} vía `conLatido()` (comun.ts).
// Este watchdog (cada 3 h) compara cada latido contra la cadencia ESPERADA del
// registro de abajo y avisa cuando un cron:
//   - STALE: no corre hace más de su tolerancia (Scheduler roto, deploy que lo
//     borró, crash-loop) — incluye "nunca corrió desde que se lo vigila"
//     (al primer chequeo sin doc se siembra `primer_chequeo` y se mide desde ahí).
//   - FALLANDO: su última corrida terminó en error (ultimo_error > ultimo_ok).
//
// Aviso por DOS canales: Telegram (fuera de banda — funciona aunque el bot de
// WhatsApp esté muerto) + COLA_WHATSAPP a Santiago (key M5 `mantenimientoBot`).
// Anti-spam: re-avisa por cron como mucho cada 24 h (campo `alertado_en`).
// Silencio = todo OK (convención de la casa).
//
// La lógica de decisión es PURA (`evaluarSaludCrones`) — tests en
// functions/test/cron_health.test.js sin emulador.

import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";
import {
  MANTENIMIENTO_DESTINATARIO_DNI,
  latidoCron,
  obtenerDestinatarioDni,
} from "./comun";
import { expiraEnMin } from "./helpers";
import {
  enviarTelegram,
  telegramBotToken,
  telegramChatId,
} from "./bot_alerta_externa";

const TZ = "America/Argentina/Buenos_Aires";

// ─── Registro de cadencias esperadas ─────────────────────────────────────────
// Tolerancias GENEROSAS a propósito: este watchdog detecta crons MUERTOS o
// rotos, no demoras menores. Al crear un cron nuevo: (1) envolver el handler
// con conLatido("id", ...), (2) sumarlo acá con su tolerancia.
export const REGISTRO_CRONES: Record<string, { maxStaleMin: number }> = {
  // Pollers cada 5 min
  sitrackPosicionPoller: { maxStaleMin: 180 },
  sitrackEventosPoller: { maxStaleMin: 180 },
  volvoAlertasPoller: { maxStaleMin: 180 },
  estadoVolvoPoller: { maxStaleMin: 180 },
  zonaDescargaPoller: { maxStaleMin: 180 },
  vigiladorJornadaChofer: { maxStaleMin: 180 },
  // Cada 10-30 min
  procesarSilenciadosExpirados: { maxStaleMin: 180 },
  botHealthWatchdog: { maxStaleMin: 180 },
  recomputeDashboardStats: { maxStaleMin: 240 },
  // Cada 6 h
  telemetriaSnapshotScheduled: { maxStaleMin: 13 * 60 },
  // Diarios (madrugada/8 AM) — 26 h de tolerancia
  volvoScoresPoller: { maxStaleMin: 26 * 60 },
  purgarColaWhatsappAntigua: { maxStaleMin: 26 * 60 },
  backfillDescargasDiario: { maxStaleMin: 26 * 60 },
  reconstruirHistoricoIButtonsDiario: { maxStaleMin: 26 * 60 },
  reconstruirJornadasDiario: { maxStaleMin: 26 * 60 },
  registrarJornadasV3Diario: { maxStaleMin: 26 * 60 },
  cruzarParadasReportadasV3Diario: { maxStaleMin: 26 * 60 },
  cerrarReportesJornadaDiario: { maxStaleMin: 26 * 60 },
  resumenBotDiario: { maxStaleMin: 26 * 60 },
  resumenDriftsAsignacionesDiario: { maxStaleMin: 26 * 60 },
  resumenExcesosJornadaDiario: { maxStaleMin: 26 * 60 },
  resumenConductaManejoDiario: { maxStaleMin: 26 * 60 },
  resumenMantenimientoVehiculosDiario: { maxStaleMin: 26 * 60 },
  // Diario desde 2026-06-12 (era semanal) — 26 h como los demás diarios
  backupFirestoreScheduled: { maxStaleMin: 26 * 60 },
  // Mensual (día 1, 03:30) — 33 días de tolerancia
  censoColeccionesMensual: { maxStaleMin: 33 * 24 * 60 },
};

// ─── Tipos puros ─────────────────────────────────────────────────────────────
export interface EstadoCron {
  id: string;
  ultimoOkMs: number | null;
  ultimoErrorMs: number | null;
  errorDetalle: string | null;
  primerChequeoMs: number | null;
  alertadoEnMs: number | null;
}

export interface Incidente {
  id: string;
  tipo: "stale" | "fallando";
  detalle: string;
}

const ANTI_SPAM_MS = 24 * 60 * 60 * 1000; // re-aviso por cron: cada 24 h
const ERROR_RECIENTE_MS = 13 * 60 * 60 * 1000; // error "fresco" si < 13 h

function horasTxt(ms: number): string {
  const h = ms / (60 * 60 * 1000);
  return h >= 48 ? `${Math.round(h / 24)} días` : `${Math.round(h)} h`;
}

/** Decide los incidentes a reportar. PURA: sin Firestore, sin reloj propio. */
export function evaluarSaludCrones(
  ahoraMs: number,
  estados: EstadoCron[],
  registro: Record<string, { maxStaleMin: number }> = REGISTRO_CRONES,
): Incidente[] {
  const out: Incidente[] = [];
  for (const e of estados) {
    const cfg = registro[e.id];
    if (!cfg) continue; // doc huérfano (cron retirado) — no alertar
    // Anti-spam: si ya avisamos por este cron hace < 24 h, silencio.
    if (e.alertadoEnMs != null && ahoraMs - e.alertadoEnMs < ANTI_SPAM_MS) {
      continue;
    }

    // STALE: medimos desde el último OK, o desde que empezamos a vigilarlo
    // (primer_chequeo) si nunca corrió OK. Sin ninguna de las dos marcas
    // todavía no podemos medir (el propio watchdog siembra primer_chequeo).
    const base = Math.max(e.ultimoOkMs ?? 0, e.primerChequeoMs ?? 0);
    const maxStaleMs = cfg.maxStaleMin * 60 * 1000;
    if (base > 0 && ahoraMs - base > maxStaleMs) {
      const nunca = e.ultimoOkMs == null;
      out.push({
        id: e.id,
        tipo: "stale",
        detalle: nunca ?
          `nunca corrió OK desde que se lo vigila (hace ${horasTxt(ahoraMs - base)})` :
          `sin corrida OK hace ${horasTxt(ahoraMs - base)} (tolerancia ${horasTxt(maxStaleMs)})`,
      });
      continue; // stale ya cubre el caso; no duplicar con "fallando"
    }

    // FALLANDO: la última corrida terminó en error (y es reciente).
    if (
      e.ultimoErrorMs != null &&
      e.ultimoErrorMs > (e.ultimoOkMs ?? 0) &&
      ahoraMs - e.ultimoErrorMs < ERROR_RECIENTE_MS
    ) {
      out.push({
        id: e.id,
        tipo: "fallando",
        detalle: `última corrida con ERROR hace ${horasTxt(ahoraMs - e.ultimoErrorMs)}` +
          (e.errorDetalle ? `: ${e.errorDetalle.slice(0, 120)}` : ""),
      });
    }
  }
  return out;
}

/** Arma el texto del aviso (compartido WhatsApp/Telegram-sin-HTML). PURA. */
export function construirMensajeIncidentes(incidentes: Incidente[]): string {
  const lineas = incidentes.map((i) => {
    const icono = i.tipo === "stale" ? "⛔" : "⚠️";
    return `${icono} ${i.id} — ${i.detalle}`;
  });
  return [
    "🩺 *Salud de crons* — hay procesos automáticos con problemas:",
    "",
    ...lineas,
    "",
    "Revisar Cloud Scheduler / logs de Functions.",
  ].join("\n");
}

// ─── Watchdog ────────────────────────────────────────────────────────────────
export const cronWatchdog = onSchedule(
  {
    schedule: "0 */3 * * *",
    timeZone: TZ,
    secrets: [telegramBotToken, telegramChatId],
  },
  async () => {
    const ahoraMs = Date.now();

    // 1) Leer CRON_HEALTH completa (≤ ~30 docs) + sembrar primer_chequeo
    //    de los crons registrados que todavía no tienen doc.
    const snap = await db.collection("CRON_HEALTH").get();
    const porId = new Map(snap.docs.map((d) => [d.id, d.data()]));
    const estados: EstadoCron[] = [];
    for (const id of Object.keys(REGISTRO_CRONES)) {
      const m = porId.get(id);
      if (!m) {
        await db.collection("CRON_HEALTH").doc(id).set({
          primer_chequeo: FieldValue.serverTimestamp(),
        }, { merge: true });
        continue; // recién sembrado: se evalúa a partir del próximo tick
      }
      const ts = (v: unknown) =>
        v instanceof Timestamp ? v.toMillis() : null;
      estados.push({
        id,
        ultimoOkMs: ts(m.ultimo_ok),
        ultimoErrorMs: ts(m.ultimo_error),
        errorDetalle: (m.ultimo_error_detalle as string) ?? null,
        primerChequeoMs: ts(m.primer_chequeo),
        alertadoEnMs: ts(m.alertado_en),
      });
    }

    // 2) Decidir (lógica pura).
    const incidentes = evaluarSaludCrones(ahoraMs, estados);
    if (incidentes.length === 0) {
      logger.info("[cronWatchdog] OK — todos los crons al día", {
        vigilados: estados.length,
      });
      await latidoCron("cronWatchdog", true);
      return;
    }

    const mensaje = construirMensajeIncidentes(incidentes);
    logger.warn("[cronWatchdog] incidentes detectados", {
      incidentes: incidentes.map((i) => `${i.tipo}:${i.id}`),
    });

    // 3) Telegram (fuera de banda — primario: funciona con el bot muerto).
    const html = mensaje
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/\*/g, "");
    await enviarTelegram(
      telegramBotToken.value(), telegramChatId.value(), html,
    );

    // 4) WhatsApp a Santiago (secundario — si el caído es el bot, esta pata
    //    no llega, por eso el Telegram va primero).
    try {
      const dni = await obtenerDestinatarioDni(
        "mantenimientoBot", MANTENIMIENTO_DESTINATARIO_DNI,
      );
      const emp = await db.collection("EMPLEADOS").doc(dni).get();
      const tel = (emp.data()?.TELEFONO ?? "").toString().trim();
      if (tel) {
        await db.collection("COLA_WHATSAPP").add({
          telefono: tel,
          mensaje,
          estado: "PENDIENTE",
          encolado_en: FieldValue.serverTimestamp(),
          expira_en: expiraEnMin(6 * 60),
          enviado_en: null,
          error: null,
          intentos: 0,
          origen: "cron_watchdog",
          destinatario_coleccion: "EMPLEADOS",
          destinatario_id: dni,
          campo_base: "CRON_WATCHDOG",
          admin_dni: "BOT",
          admin_nombre: "Cron watchdog",
        });
      }
    } catch (e) {
      logger.warn("[cronWatchdog] no se pudo encolar WhatsApp", {
        error: (e as Error).message,
      });
    }

    // 5) Marcar alertado_en por incidente (anti-spam 24 h).
    for (const i of incidentes) {
      await db.collection("CRON_HEALTH").doc(i.id).set({
        alertado_en: FieldValue.serverTimestamp(),
      }, { merge: true });
    }
    await latidoCron("cronWatchdog", true);
  },
);
