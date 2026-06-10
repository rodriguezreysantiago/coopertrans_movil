// =============================================================================
// BOT ALERTA EXTERNA — canal Telegram para incidentes del bot WhatsApp
// =============================================================================
//
// PROBLEMA QUE RESUELVE (auditoría 2026-06-10): todos los avisos del sistema
// viajan por el bot de WhatsApp que corre en la PC dedicada. Cuando el que se
// rompe es EL PROPIO BOT (PC apagada, NSSM muerto, Meta revocó la sesión y
// pide QR), el aviso de "bot caído" no tiene por dónde salir:
//   - `botHealthWatchdog` registraba el evento en BOT_EVENTOS y el resumen
//     salía a las 8 AM... por el bot caído.
//   - El caso "bot vivo pero sesión WhatsApp rota" (AUTH_PENDIENTE) ni
//     siquiera se detectaba: el heartbeat sigue latiendo.
// Resultado: el sistema de avisos podía quedar mudo horas/días sin que nadie
// se entere (salvo que Santiago abriera la pantalla "Estado del Bot").
//
// SOLUCIÓN: `botHealthWatchdog` (Cloud Function, corre en GCP independiente
// de la PC) evalúa dos señales sobre BOT_HEALTH/main y dispara un mensaje de
// Telegram — canal 100% fuera de banda — al chat de Santiago:
//
//   Señal A `bot_caido`:     ultimoHeartbeat stale > UMBRAL_STALE_MIN.
//   Señal B `whatsapp_roto`: heartbeat fresco pero el cliente WhatsApp no
//                            está sano: AUTH_PENDIENTE / AUTH_FALLO alertan
//                            INMEDIATO (pedir QR no se arregla solo);
//                            cualquier otro estado ≠ LISTO sostenido más de
//                            UMBRAL_NO_LISTO_MIN alerta también (cubre
//                            DESCONECTADO que no reconecta y el caso
//                            "clavado en INICIANDO" por Chromium roto, sin
//                            falsa alarma por blips de reconexión).
//
// CICLO DE INCIDENTE (anti-spam): primer aviso al detectar; re-aviso a los
// 60 min; después cada 6 h; aviso 🟢 de recuperación (solo cuando vuelve a
// LISTO con latido fresco) con la duración total. El estado vive en el campo
// `alertaExterna` de BOT_HEALTH/main — el heartbeat del bot escribe con
// set+merge y no lo toca. Si el POST a Telegram falla, NO se persiste el
// avance: el próximo tick (15 min) reintenta solo.
//
// Esta capa NO reemplaza a BOT_EVENTOS: ese registro sigue alimentando el
// resumen diario de las 8 AM tal cual estaba.
//
// SETUP (one-time):
//   1. Crear bot en Telegram con @BotFather → token.
//   2. Santiago le manda un mensaje al bot (sin eso el bot no puede
//      escribirle) y se obtiene el chat_id con GET /getUpdates.
//   3. firebase functions:secrets:set TELEGRAM_BOT_TOKEN
//      firebase functions:secrets:set TELEGRAM_CHAT_ID
//   4. firebase deploy --only functions:botHealthWatchdog

import * as logger from "firebase-functions/logger";
import { defineSecret } from "firebase-functions/params";
import { Timestamp } from "firebase-admin/firestore";

import { fetchWithTimeout } from "./comun";
import { formatFechaArg, formatHoraArg } from "./helpers";

export const telegramBotToken = defineSecret("TELEGRAM_BOT_TOKEN");
export const telegramChatId = defineSecret("TELEGRAM_CHAT_ID");

// Minutos sin heartbeat para considerar el bot caído. (El heartbeat real es
// cada 60s; 10 min absorbe blips de Firestore/red de la dedicada.)
export const UMBRAL_STALE_MIN = 10;
// Minutos sostenidos en estado ≠ LISTO (con heartbeat fresco) para alertar.
// El bot se auto-reconecta en ~1-3 min; 30 min sostenido ya no es un blip.
export const UMBRAL_NO_LISTO_MIN = 30;
// Backoff de re-avisos de un incidente abierto: el 2º aviso sale a los
// 60 min del 1º; del 3º en adelante, cada 6 h.
export const REAVISO_TEMPRANO_MIN = 60;
export const REAVISO_TARDIO_MIN = 360;

// Estados del cliente que alertan sin esperar el sostenido: pedir QR o
// fallar la auth no se resuelven solos, cada minuto cuenta.
// (Catálogo completo de estados en whatsapp-bot/src/whatsapp.js:
// INICIANDO, AUTH_PENDIENTE, AUTENTICADO, AUTH_FALLO, LISTO, DESCONECTADO.)
const ESTADOS_ROTOS_INMEDIATOS = new Set(["AUTH_PENDIENTE", "AUTH_FALLO"]);

export type MotivoIncidente = "bot_caido" | "whatsapp_roto";
export type ClaseAviso = "apertura" | "cambio" | "reaviso" | "recuperacion";

/** Estado del incidente que se persiste en BOT_HEALTH/main.alertaExterna. */
export interface IncidenteExterno {
  activa: boolean;
  motivo: MotivoIncidente | null;
  /** estadoCliente al momento del último aviso (contexto del mensaje). */
  detalle: string | null;
  desdeMs: number | null;
  ultimoAvisoEnMs: number | null;
  avisosEnviados: number;
  /** Desde cuándo el cliente está en estado ≠ LISTO (con latido fresco). */
  noListoDesdeMs: number | null;
}

export function incidenteVacio(): IncidenteExterno {
  return {
    activa: false,
    motivo: null,
    detalle: null,
    desdeMs: null,
    ultimoAvisoEnMs: null,
    avisosEnviados: 0,
    noListoDesdeMs: null,
  };
}

export interface EvalAlertaInput {
  ahoraMs: number;
  ultimoHeartbeatMs: number;
  estadoCliente: string;
  /** Estado previo del incidente (leído de BOT_HEALTH/main.alertaExterna). */
  incidente: IncidenteExterno;
}

export interface EvalAlertaResultado {
  avisar: boolean;
  clase: ClaseAviso | null;
  /** Estado nuevo del incidente, a persistir si el aviso salió (o no hubo). */
  incidente: IncidenteExterno;
}

/**
 * Decide qué hacer en este tick del watchdog. Función PURA (sin Firestore ni
 * Telegram) — toda la máquina de estados del incidente vive acá y se testea
 * en test/bot_alerta_externa.test.js.
 */
export function evaluarAlertaExterna(input: EvalAlertaInput): EvalAlertaResultado {
  const { ahoraMs, ultimoHeartbeatMs, estadoCliente, incidente } = input;
  const stale = (ahoraMs - ultimoHeartbeatMs) / 60000 > UMBRAL_STALE_MIN;

  // Tracking de "no LISTO sostenido". Solo corre con heartbeat fresco: sin
  // latido no sabemos el estado real del cliente, así que se congela.
  let noListoDesdeMs: number | null;
  if (stale) {
    noListoDesdeMs = incidente.noListoDesdeMs;
  } else if (estadoCliente === "LISTO") {
    noListoDesdeMs = null;
  } else {
    noListoDesdeMs = incidente.noListoDesdeMs ?? ahoraMs;
  }

  let motivo: MotivoIncidente | null = null;
  if (stale) {
    motivo = "bot_caido";
  } else if (ESTADOS_ROTOS_INMEDIATOS.has(estadoCliente)) {
    motivo = "whatsapp_roto";
  } else if (
    estadoCliente !== "LISTO" &&
    noListoDesdeMs !== null &&
    ahoraMs - noListoDesdeMs >= UMBRAL_NO_LISTO_MIN * 60000
  ) {
    motivo = "whatsapp_roto";
  }

  // Estado base: el previo con el tracking actualizado.
  const base: IncidenteExterno = { ...incidente, noListoDesdeMs };

  if (motivo) {
    if (!incidente.activa) {
      return {
        avisar: true,
        clase: "apertura",
        incidente: {
          activa: true,
          motivo,
          detalle: estadoCliente,
          desdeMs: ahoraMs,
          ultimoAvisoEnMs: ahoraMs,
          avisosEnviados: 1,
          noListoDesdeMs,
        },
      };
    }
    if (incidente.motivo !== motivo) {
      // El incidente mutó (típico: QR pedido → operador baja el servicio
      // para arreglar → heartbeat stale). Avisar sin esperar el backoff.
      return {
        avisar: true,
        clase: "cambio",
        incidente: {
          ...base,
          motivo,
          detalle: estadoCliente,
          ultimoAvisoEnMs: ahoraMs,
          avisosEnviados: incidente.avisosEnviados + 1,
        },
      };
    }
    const ultimoAvisoMs = incidente.ultimoAvisoEnMs ?? incidente.desdeMs ?? ahoraMs;
    const umbralMin =
      incidente.avisosEnviados <= 1 ? REAVISO_TEMPRANO_MIN : REAVISO_TARDIO_MIN;
    if (ahoraMs - ultimoAvisoMs >= umbralMin * 60000) {
      return {
        avisar: true,
        clase: "reaviso",
        incidente: {
          ...base,
          detalle: estadoCliente,
          ultimoAvisoEnMs: ahoraMs,
          avisosEnviados: incidente.avisosEnviados + 1,
        },
      };
    }
    return { avisar: false, clase: null, incidente: base };
  }

  // Sin señal mala.
  if (incidente.activa) {
    if (estadoCliente === "LISTO") {
      // Recuperado de verdad (latido fresco + cliente operativo).
      return { avisar: true, clase: "recuperacion", incidente: incidenteVacio() };
    }
    // En recuperación (p.ej. INICIANDO tras reinicio del servicio): mantener
    // el incidente abierto sin re-avisar, cerrar recién al ver LISTO.
    return { avisar: false, clase: null, incidente: base };
  }
  return { avisar: false, clase: null, incidente: base };
}

/** "47 min" / "3 h 12 min" — para los textos de los avisos. */
export function duracionHumana(ms: number): string {
  const totalMin = Math.max(0, Math.round(ms / 60000));
  if (totalMin < 60) return `${totalMin} min`;
  const horas = Math.floor(totalMin / 60);
  const min = totalMin % 60;
  return min === 0 ? `${horas} h` : `${horas} h ${min} min`;
}

export interface ContextoMensaje {
  clase: ClaseAviso;
  motivo: MotivoIncidente;
  estadoCliente: string;
  pcId: string;
  ahoraMs: number;
  ultimoHeartbeatMs: number;
  /** Inicio del incidente (para duración en reavisos/recuperación). */
  desdeMs: number | null;
  /** Número de este aviso dentro del incidente (1 = apertura). */
  avisosEnviados: number;
}

/**
 * Arma el texto del aviso (HTML simple de Telegram: solo <b>). En español y
 * sin jerga de sistemas — el destinatario está apagando un incendio.
 */
export function construirMensajeAlerta(ctx: ContextoMensaje): string {
  const cuandoHb =
    `${formatFechaArg(ctx.ultimoHeartbeatMs)} ${formatHoraArg(ctx.ultimoHeartbeatMs)}hs`;

  if (ctx.clase === "recuperacion") {
    const duracion = ctx.desdeMs !== null ? duracionHumana(ctx.ahoraMs - ctx.desdeMs) : null;
    return [
      "🟢 <b>Bot WhatsApp recuperado</b>",
      `El cliente está LISTO de nuevo (PC: ${ctx.pcId}).` +
        (duracion ? ` El incidente duró ${duracion}.` : ""),
      "Los avisos que quedaron encolados durante la caída salen ahora.",
    ].join("\n");
  }

  const prefijoCambio = ctx.clase === "cambio" ? "🟠 <b>Cambio en el incidente del bot</b>\n" : "";
  const sufijoAviso = ctx.clase === "reaviso" ? ` (aviso ${ctx.avisosEnviados})` : "";

  if (ctx.motivo === "bot_caido") {
    const titulo = ctx.clase === "reaviso" ?
      `🔴 <b>El bot de WhatsApp sigue caído</b>${sufijoAviso}` :
      "🔴 <b>Bot de WhatsApp caído</b>";
    return [
      prefijoCambio + titulo,
      `Sin latido desde el ${cuandoHb} ` +
        `(hace ${duracionHumana(ctx.ahoraMs - ctx.ultimoHeartbeatMs)}). PC: ${ctx.pcId}.`,
      "La cola de avisos de WhatsApp está detenida hasta que el bot vuelva.",
    ].join("\n");
  }

  // whatsapp_roto
  const titulo = ctx.clase === "reaviso" ?
    `🔴 <b>La sesión de WhatsApp del bot sigue rota</b>${sufijoAviso}` :
    "🔴 <b>Sesión de WhatsApp del bot rota</b>";
  let detalle: string;
  if (ctx.estadoCliente === "AUTH_PENDIENTE") {
    detalle =
      "Está pidiendo QR: hay que escanearlo desde el celular del número de " +
      "Coopertrans (WhatsApp → Dispositivos vinculados → Vincular un dispositivo).";
  } else if (ctx.estadoCliente === "AUTH_FALLO") {
    detalle = "Falló la autenticación de la sesión — probablemente haya que re-vincular con QR.";
  } else {
    const sostenido = ctx.desdeMs !== null ? duracionHumana(ctx.ahoraMs - ctx.desdeMs) : "rato";
    detalle =
      `No llega a LISTO hace ${sostenido} — puede estar trabado reiniciando ` +
      "(Chromium/red de la dedicada).";
  }
  return [
    prefijoCambio + titulo,
    `El bot está vivo (PC: ${ctx.pcId}) pero el cliente está en ${ctx.estadoCliente}.`,
    detalle,
  ].join("\n");
}

/**
 * POST a la API de Telegram. Nunca lanza: devuelve false y loguea (la alerta
 * jamás debe romper el watchdog). No loguear la URL: contiene el token.
 */
export async function enviarTelegram(
  token: string,
  chatId: string,
  html: string,
): Promise<boolean> {
  if (!token || !chatId) {
    logger.error("[alertaExterna] TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID vacíos — no puedo avisar");
    return false;
  }
  try {
    const resp = await fetchWithTimeout(
      `https://api.telegram.org/bot${token}/sendMessage`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: chatId,
          text: html,
          parse_mode: "HTML",
          disable_web_page_preview: true,
        }),
      },
      10_000,
    );
    if (!resp.ok) {
      const cuerpo = await resp.text().catch(() => "(sin cuerpo)");
      logger.error("[alertaExterna] Telegram devolvió error", {
        status: resp.status,
        cuerpo: cuerpo.slice(0, 300),
      });
      return false;
    }
    return true;
  } catch (e) {
    logger.error("[alertaExterna] falló el envío a Telegram", { error: String(e) });
    return false;
  }
}

// ─── (De)serialización del campo `alertaExterna` de BOT_HEALTH/main ─────────
// La lógica pura trabaja en millis; en Firestore guardamos Timestamps como el
// resto del doc. Lectura tolerante: doc viejo sin el campo → incidente vacío.

function aMillis(v: unknown): number | null {
  if (v instanceof Timestamp) return v.toMillis();
  return null;
}

export function incidenteDesdeDoc(raw: unknown): IncidenteExterno {
  if (!raw || typeof raw !== "object") return incidenteVacio();
  const r = raw as Record<string, unknown>;
  const motivo = r.motivo === "bot_caido" || r.motivo === "whatsapp_roto" ? r.motivo : null;
  return {
    activa: r.activa === true,
    motivo,
    detalle: typeof r.detalle === "string" ? r.detalle : null,
    desdeMs: aMillis(r.desde),
    ultimoAvisoEnMs: aMillis(r.ultimoAvisoEn),
    avisosEnviados: typeof r.avisosEnviados === "number" ? r.avisosEnviados : 0,
    noListoDesdeMs: aMillis(r.noListoDesde),
  };
}

export function incidenteHaciaDoc(inc: IncidenteExterno): Record<string, unknown> {
  return {
    activa: inc.activa,
    motivo: inc.motivo,
    detalle: inc.detalle,
    desde: inc.desdeMs !== null ? Timestamp.fromMillis(inc.desdeMs) : null,
    ultimoAvisoEn:
      inc.ultimoAvisoEnMs !== null ? Timestamp.fromMillis(inc.ultimoAvisoEnMs) : null,
    avisosEnviados: inc.avisosEnviados,
    noListoDesde:
      inc.noListoDesdeMs !== null ? Timestamp.fromMillis(inc.noListoDesdeMs) : null,
  };
}

/** Para persistir solo cuando algo cambió (evita un write por tick). */
export function sonIncidentesIguales(a: IncidenteExterno, b: IncidenteExterno): boolean {
  return a.activa === b.activa &&
    a.motivo === b.motivo &&
    a.detalle === b.detalle &&
    a.desdeMs === b.desdeMs &&
    a.ultimoAvisoEnMs === b.ultimoAvisoEnMs &&
    a.avisosEnviados === b.avisosEnviados &&
    a.noListoDesdeMs === b.noListoDesdeMs;
}
