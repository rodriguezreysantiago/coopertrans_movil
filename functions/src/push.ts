// =============================================================================
// PUSH FCM — envío de notificaciones push + cola multi-productor
// =============================================================================
// Vertical 2 de la feature deep-links+push (2026-06-13). Complementa los
// avisos de WhatsApp con push nativo para lo que NO puede depender de la PC
// dedicada: turno YPF del cachatore (ventana de minutos), failover de avisos
// críticos cuando el bot está caído, y cambio de rol/sesión.
//
// Diseño en COLA (igual que COLA_WHATSAPP) para que productores en CUALQUIER
// lenguaje escriban: las CF (TS) usan `encolarPush()` y el cachatore (Python)
// hace su `.add()` a COLA_PUSH; el trigger `procesarColaPush` resuelve los
// tokens del destinatario y envía por FCM, podando los tokens muertos.
//
// Tokens: EMPLEADOS/{dni}/dispositivos/{installId} { token, plataforma,
// actualizado_en } — los escribe la app (client SDK, rule isSelf). Sin
// tokens (app no actualizada todavía) el envío es no-op silencioso, así que
// esto se puede deployar y encolar ANTES del release sin efectos.
//
// La lógica pura (qué tokens podar) está testeada sin SDK.

import { onDocumentCreated } from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import { FieldValue } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";

import { db } from "./setup";
import { expiraEnMin } from "./helpers";

// ─── Lógica pura ─────────────────────────────────────────────────────────────

export interface RespuestaEnvio {
  exito: boolean;
  codigoError?: string;
}

// Códigos de FCM que significan "este token ya no sirve" → podarlo del
// dispositivo. NO podamos por errores transitorios (unavailable, internal):
// el token sigue siendo válido, reintentamos en el próximo envío.
const CODIGOS_TOKEN_MUERTO = new Set<string>([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
  "messaging/invalid-argument",
]);

/** Dado el resultado del multicast (alineado por índice con `tokens`),
 *  devuelve los tokens a BORRAR (muertos). PURA. */
export function tokensAPodar(
  tokens: string[],
  respuestas: RespuestaEnvio[],
): string[] {
  const out: string[] = [];
  for (let i = 0; i < tokens.length; i++) {
    const r = respuestas[i];
    if (r && !r.exito && r.codigoError &&
      CODIGOS_TOKEN_MUERTO.has(r.codigoError)) {
      out.push(tokens[i]);
    }
  }
  return out;
}

// ─── Envío ───────────────────────────────────────────────────────────────────

export interface OpcionesPush {
  titulo: string;
  cuerpo: string;
  /** keyword de destino (mismo vocabulario que los deep links) → la app lo
   *  usa para abrir la pantalla al tappear el push. */
  destino?: string;
  data?: Record<string, string>;
}

export interface ResultadoPush {
  tokens: number;
  enviados: number;
  podados: number;
}

/** Resuelve los tokens del dni, envía el push por FCM y poda los muertos.
 *  Sin tokens → no-op (tokens:0). Lo usa el trigger de la cola. */
export async function enviarPush(
  dni: string,
  opts: OpcionesPush,
): Promise<ResultadoPush> {
  const dispSnap = await db
    .collection("EMPLEADOS").doc(dni)
    .collection("dispositivos").get();
  const docs = dispSnap.docs
    .map((d) => ({ ref: d.ref, token: (d.data().token ?? "").toString() }))
    .filter((x) => x.token.length > 0);
  if (docs.length === 0) {
    return { tokens: 0, enviados: 0, podados: 0 };
  }

  const tokens = docs.map((x) => x.token);
  const data: Record<string, string> = { ...(opts.data ?? {}) };
  if (opts.destino) data.destino = opts.destino;

  const resp = await getMessaging().sendEachForMulticast({
    tokens,
    notification: { title: opts.titulo, body: opts.cuerpo },
    data,
    android: { priority: "high" },
    apns: { headers: { "apns-priority": "10" } },
  });

  const respuestas: RespuestaEnvio[] = resp.responses.map((r) => ({
    exito: r.success,
    codigoError: r.error?.code,
  }));
  const podar = new Set(tokensAPodar(tokens, respuestas));
  let podados = 0;
  for (const x of docs) {
    if (podar.has(x.token)) {
      await x.ref.delete().catch(() => {/* best-effort */});
      podados++;
    }
  }
  return { tokens: tokens.length, enviados: resp.successCount, podados };
}

/** Encola un push (lo usan las CF productoras; el cachatore Python escribe
 *  el doc directo con su propio helper). TTL 7 días para que COLA_PUSH no
 *  crezca. */
export async function encolarPush(input: {
  dni: string;
  titulo: string;
  cuerpo: string;
  destino?: string;
  origen: string;
  data?: Record<string, string>;
}): Promise<void> {
  await db.collection("COLA_PUSH").add({
    dni: input.dni,
    titulo: input.titulo,
    cuerpo: input.cuerpo,
    destino: input.destino ?? null,
    data: input.data ?? null,
    origen: input.origen,
    estado: "PENDIENTE",
    creado_en: FieldValue.serverTimestamp(),
    expira_en: expiraEnMin(7 * 24 * 60),
  });
}

// ─── Trigger de la cola ──────────────────────────────────────────────────────

export const procesarColaPush = onDocumentCreated(
  "COLA_PUSH/{id}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const d = snap.data();
    const dni = (d.dni ?? "").toString();
    const titulo = (d.titulo ?? "").toString();
    const cuerpo = (d.cuerpo ?? "").toString();

    if (!dni || !titulo) {
      await snap.ref.set({
        estado: "INVALIDO",
        procesado_en: FieldValue.serverTimestamp(),
      }, { merge: true });
      return;
    }

    // Guard de idempotencia: si un retry de GCP re-dispara el onCreate y el
    // doc ya se procesó, no re-enviamos.
    const fresh = await snap.ref.get();
    if ((fresh.data()?.estado ?? "PENDIENTE") !== "PENDIENTE") return;

    try {
      const r = await enviarPush(dni, {
        titulo,
        cuerpo,
        destino: d.destino ? d.destino.toString() : undefined,
        data: d.data && typeof d.data === "object" ?
          (d.data as Record<string, string>) : undefined,
      });
      await snap.ref.set({
        estado: r.tokens === 0 ? "SIN_TOKENS" : "ENVIADO",
        enviados: r.enviados,
        podados: r.podados,
        tokens: r.tokens,
        procesado_en: FieldValue.serverTimestamp(),
      }, { merge: true });
      logger.info("[procesarColaPush] OK", {
        dni, origen: d.origen, ...r,
      });
    } catch (e) {
      logger.error("[procesarColaPush] error", {
        dni, error: (e as Error).message,
      });
      await snap.ref.set({
        estado: "ERROR",
        error: (e as Error).message.slice(0, 300),
        procesado_en: FieldValue.serverTimestamp(),
      }, { merge: true });
    }
  },
);
