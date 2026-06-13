// =============================================================================
// FAILOVER de avisos críticos cuando el bot de WhatsApp está caído
// =============================================================================
// La PC dedicada es el único camino de salida de WhatsApp (SPOF asumido). Si
// el bot cae, los avisos críticos quedan en COLA_WHATSAPP y, si expiran antes
// de que el bot vuelva, SE PIERDEN — el sistema te cuenta que perdió mensajes
// de seguridad, no los salva. Este cron (cada 10 min), MIENTRAS el incidente
// "bot caído" está activo (BOT_HEALTH/main.alertaExterna.activa):
//   1. PUSH al chofer de cada aviso crítico pendiente — canal que NO depende
//      de la dedicada. Marca `fallback_push` en el doc para no repetir.
//   2. UNA escalación a Santiago por Telegram (fuera de banda) si hubo docs
//      NUEVOS este tick. Auto-anti-spam: una vez flaggeados, no re-avisa;
//      solo vuelve a sonar si llegan avisos críticos nuevos durante la caída.
//
// El push es inerte hasta que la app registre tokens (Vertical 2 deep-links+
// push); la escalación Telegram funciona YA (Santiago se entera + actúa). Al
// recuperar el bot, procesa la cola normal — los push fueron paralelos
// best-effort; recibir ambos en un aviso crítico es redundancia aceptable.
//
// La selección (qué docs failover) es PURA — tests sin Firestore.

import * as logger from "firebase-functions/logger";

import { db } from "./setup";
import { onScheduleConLatido } from "./comun";
import { encolarPush } from "./push";
import {
  enviarTelegram,
  telegramBotToken,
  telegramChatId,
} from "./bot_alerta_externa";

const TZ = "America/Argentina/Buenos_Aires";

// Orígenes CRÍTICOS que justifican alcanzar al chofer por un canal alterno
// cuando el bot está caído (seguridad + jornada legal + turno con ventana de
// minutos). Subconjunto del ORIGENES_TIME_SENSITIVE del bot (humano.js):
// dejamos afuera confirmaciones de comandos y alertas operativas del bot.
export const ORIGENES_CRITICOS = new Set<string>([
  "jornada_v2_bloque_3h30",
  "jornada_v2_bloque_excedido",
  "jornada_v2_cuota_proxima",
  "jornada_v2_cuota_cumplida",
  "jornada_v2_veda_nocturna",
  "jornada_manual_admin",
  "volvo_alert_high",
  "bypass_seguridad",
  "sitrack_chofer_no_identificado",
  "cachatore", // turno YPF (ventana de minutos)
]);

export interface DocCola {
  id: string;
  origen?: string;
  estado?: string;
  destinatario_id?: string;
  mensaje?: string;
  fallback_push?: boolean;
}

/** De los pendientes, los que hay que failover: origen crítico, estado
 *  PENDIENTE, con destinatario_id (para resolver tokens) y sin marcar. PURA. */
export function aFailover(docs: DocCola[]): DocCola[] {
  return docs.filter((d) =>
    (d.estado ?? "PENDIENTE") === "PENDIENTE" &&
    !d.fallback_push &&
    !!d.destinatario_id &&
    !!d.origen && ORIGENES_CRITICOS.has(d.origen));
}

/** Texto de la escalación a Santiago (Telegram). PURA. */
export function construirEscalacion(items: DocCola[]): string {
  const lineas = items.slice(0, 15).map((d) =>
    `• ${d.origen} → ${d.destinatario_id}`);
  const extra = items.length > 15 ? `… y ${items.length - 15} más` : "";
  return [
    `📨 *Failover (bot caído)*: reenvié por PUSH ${items.length} ` +
      "aviso(s) crítico(s) que estaban pendientes:",
    "",
    ...lineas,
    ...(extra ? [extra] : []),
    "",
    "El bot sigue caído — revisá la dedicada.",
  ].join("\n");
}

export const failoverCriticosBot = onScheduleConLatido(
  "failoverCriticosBot",
  {
    schedule: "*/10 * * * *",
    timeZone: TZ,
    secrets: [telegramBotToken, telegramChatId],
  },
  async () => {
    // 1) ¿Bot caído? (incidente activo). Si está OK → silencio (1 read).
    const health = await db.collection("BOT_HEALTH").doc("main").get();
    const inc = health.data()?.alertaExterna as { activa?: boolean } | undefined;
    if (!inc?.activa) return;

    // 2) Pendientes críticos sin failover.
    const snap = await db.collection("COLA_WHATSAPP")
      .where("estado", "==", "PENDIENTE")
      .limit(300)
      .get();
    const docs: DocCola[] = snap.docs.map(
      (d) => ({ id: d.id, ...(d.data() as Record<string, unknown>) }),
    );
    const objetivos = aFailover(docs);
    if (objetivos.length === 0) return;

    // 3) Push + marca por doc (el push es inerte hasta que haya tokens).
    let pusheados = 0;
    for (const d of objetivos) {
      try {
        await encolarPush({
          dni: d.destinatario_id!,
          titulo: "Aviso importante",
          cuerpo: (d.mensaje ?? "").replace(/[*_]/g, "").slice(0, 180),
          destino: "home",
          origen: "failover_" + (d.origen ?? "critico"),
        });
        await db.collection("COLA_WHATSAPP").doc(d.id)
          .set({ fallback_push: true }, { merge: true });
        pusheados++;
      } catch (e) {
        logger.warn("[failoverCriticosBot] no se pudo failover un doc", {
          id: d.id, error: (e as Error).message,
        });
      }
    }

    // 4) UNA escalación a Santiago si hubo docs nuevos este tick.
    if (pusheados > 0) {
      const html = construirEscalacion(objetivos)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/\*/g, "");
      try {
        await enviarTelegram(
          telegramBotToken.value(), telegramChatId.value(), html,
        );
      } catch (e) {
        logger.warn("[failoverCriticosBot] no se pudo escalar a Telegram", {
          error: (e as Error).message,
        });
      }
      logger.info("[failoverCriticosBot] failover ejecutado", { pusheados });
    }
  },
);
