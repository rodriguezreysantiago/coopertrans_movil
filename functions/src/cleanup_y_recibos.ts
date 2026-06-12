// =============================================================================
// CLEANUP DE COLA + ASIGNAR NÚMERO DE RECIBO
// =============================================================================
// Extraído de index.ts el 2026-05-18 (split del archivo de 6884 LOC).
//
// Contiene 2 cloud functions independientes y autocontenidas:
//   - `asignarNumeroReciboAdelanto` (onCall): asigna número correlativo
//     de recibo a un adelanto al momento de imprimir (server-side,
//     atómico via runTransaction). Workaround del bug de runTransaction
//     en Windows desktop — el cliente NO puede transaccionar contadores.
//   - `purgarColaWhatsappAntigua` (onSchedule): cron diario 04:00 ART
//     que borra docs de COLA_WHATSAPP en estado final (ENVIADO/ERROR/
//     EXPIRADO) con > 30 días — evita que la colección crezca infinita.
//
// Ambas son trozos de bajo riesgo, sin dependencias cruzadas con el
// resto del archivo: fue la primera tanda del split para validar el
// patrón "extract module + export * from".

import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";
import { onScheduleConLatido } from "./comun";

// ============================================================================
// asignarNumeroReciboAdelanto — número correlativo atómico
// ============================================================================
// El cliente NO puede usar runTransaction en Windows desktop (bug
// conocido — ver MEMORY: "Bugs cloud_firestore en Windows desktop").
// Por eso esta callable function corre la transacción server-side:
//   1. Lee el doc del adelanto (o del viaje legacy).
//   2. Si ya tenía número, devuelve "es reimpresión" sin tocar nada.
//   3. Si no, incrementa COUNTERS/recibos_adelanto.next y asigna el
//      número al adelanto + setea recibo_impreso_en.
//
// Solo ADMIN o SUPERVISOR pueden invocarla (chequeado vía custom claim
// del JWT, NO del cliente).

interface AsignarReciboInput {
  adelantoId?: unknown;
  viajeId?: unknown;
}

interface AsignarReciboResult {
  numero: number;
  esReimpresion: boolean;
}

export const asignarNumeroReciboAdelanto = onCall(
  {
    enforceAppCheck: false,
  },
  async (request): Promise<AsignarReciboResult> => {
    // ─── Auth: ADMIN o SUPERVISOR ──────────────────────────────────
    const rol = request.auth?.token?.rol;
    if (!request.auth || (rol !== "ADMIN" && rol !== "SUPERVISOR")) {
      logger.warn("[asignarReciboAdelanto] sin auth ADMIN/SUPERVISOR", {
        uid: request.auth?.uid ?? "no-uid",
        rol: rol ?? "no-rol",
      });
      throw new HttpsError(
        "permission-denied",
        "Solo admin o supervisor pueden imprimir comprobantes."
      );
    }

    // ─── Validación de input ───────────────────────────────────────
    const data = (request.data ?? {}) as AsignarReciboInput;
    const adelantoId = (data.adelantoId ?? "").toString().trim();
    const viajeIdLegacy = (data.viajeId ?? "").toString().trim();

    if (!adelantoId && !viajeIdLegacy) {
      throw new HttpsError(
        "invalid-argument",
        "adelantoId requerido."
      );
    }
    if (adelantoId.length > 200 || viajeIdLegacy.length > 200) {
      throw new HttpsError("invalid-argument", "id inválido.");
    }

    // Modo NUEVO: adelantoId apunta a ADELANTOS_CHOFER.
    // Modo LEGACY: viajeId apunta a VIAJES_LOGISTICA (apps cliente
    // viejas que todavía leen el adelanto del viaje).
    const usaLegacy = !adelantoId && viajeIdLegacy !== "";
    const docRef = usaLegacy ?
      db.collection("VIAJES_LOGISTICA").doc(viajeIdLegacy) :
      db.collection("ADELANTOS_CHOFER").doc(adelantoId);
    const counterRef = db.collection("COUNTERS").doc("recibos_adelanto");
    const idLog = usaLegacy ? `viajeId=${viajeIdLegacy}` : `adelantoId=${adelantoId}`;

    // Nombres de campos según modo.
    const FIELD_MONTO = usaLegacy ? "adelanto_monto" : "monto";
    const FIELD_NUMERO = usaLegacy ? "numero_recibo_adelanto" : "numero_recibo";
    const FIELD_IMPRESO_EN = usaLegacy ? "recibo_impreso_en" : "impreso_en";

    try {
      const resultado = await db.runTransaction(async (tx) => {
        const docSnap = await tx.get(docRef);
        if (!docSnap.exists) {
          throw new HttpsError(
            "not-found",
            `El ${usaLegacy ? "viaje" : "adelanto"} no existe.`
          );
        }
        const docData = docSnap.data() ?? {};
        const monto = typeof docData[FIELD_MONTO] === "number" ?
          docData[FIELD_MONTO] :
          0;
        if (monto <= 0) {
          throw new HttpsError(
            "failed-precondition",
            usaLegacy ?
              "El viaje no tiene adelanto cargado." :
              "El adelanto no tiene monto válido."
          );
        }

        const yaTiene = typeof docData[FIELD_NUMERO] === "number" ?
          Math.trunc(docData[FIELD_NUMERO]) :
          null;
        if (yaTiene !== null && yaTiene > 0) {
          // Reimpresión: mismo número, no tocar el counter ni el
          // timestamp original de impresión.
          return { numero: yaTiene, esReimpresion: true };
        }

        // Primera impresión: leer+incrementar counter compartido
        // `recibos_adelanto.next` (misma serie física para legacy y
        // nuevo — los recibos se imprimen en numeración continua).
        const counterSnap = await tx.get(counterRef);
        const next = typeof counterSnap.data()?.next === "number" ?
          Math.trunc(counterSnap.data()!.next as number) :
          1;

        tx.set(
          counterRef,
          { next: next + 1, actualizado_en: FieldValue.serverTimestamp() },
          { merge: true }
        );
        tx.update(docRef, {
          [FIELD_NUMERO]: next,
          [FIELD_IMPRESO_EN]: FieldValue.serverTimestamp(),
          actualizado_en: FieldValue.serverTimestamp(),
        });

        return { numero: next, esReimpresion: false };
      });

      logger.info("[asignarReciboAdelanto] OK", {
        idLog,
        modo: usaLegacy ? "legacy" : "nuevo",
        numero: resultado.numero,
        esReimpresion: resultado.esReimpresion,
        uid: request.auth.uid,
      });
      return resultado;
    } catch (e) {
      if (e instanceof HttpsError) {
        throw e;
      }
      const err = e as Error;
      logger.error("[asignarReciboAdelanto] error", {
        idLog,
        message: err.message,
        stack: err.stack,
      });
      throw new HttpsError(
        "internal",
        "No se pudo asignar el número de recibo."
      );
    }
  }
);

// ============================================================================
// purgarColaWhatsappAntigua — limpieza periodica de COLA_WHATSAPP
// ============================================================================
//
// Fix M5 (auditoria 24/7 2026-05-18): COLA_WHATSAPP crece sin tope. Cada
// envio (~50-100/dia) queda como doc ENVIADO/ERROR/EXPIRADO permanente.
// En 1 ano son ~30K docs - degrada queries del dedup, agrupador, polling
// de PENDIENTE, y la pantalla "Cola de WhatsApp" del admin.
//
// Cron diario 04:00 ART (fuera de horario operativo): borra docs en
// estado final (ENVIADO / ERROR / EXPIRADO) con `encolado_en` > 30 dias.
// NUNCA toca PENDIENTE / PROCESANDO (operativos en curso).
//
// Cap defensivo de 5000 docs por corrida (Firestore batch tope = 500;
// hacemos 10 batches max por ejecucion). Si quedan mas, el cron al dia
// siguiente sigue limpiando.
//
// Idempotente: re-correr no rompe. Si Firestore esta caido, falla y
// el cron del dia siguiente reintenta.
export const purgarColaWhatsappAntigua = onScheduleConLatido(
  "purgarColaWhatsappAntigua",
  {
    schedule: "0 4 * * *", // 4 AM todos los dias (ART)
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 540,
    memory: "256MiB",
  },
  async () => {
    const DIAS_RETENCION = 30;
    const MAX_DOCS_POR_CORRIDA = 5000;
    const BATCH_SIZE = 500;

    const cutoff = Timestamp.fromMillis(
      Date.now() - DIAS_RETENCION * 24 * 60 * 60 * 1000
    );

    logger.info("[purgarColaWhatsappAntigua] inicio", {
      diasRetencion: DIAS_RETENCION,
      cutoff: cutoff.toDate().toISOString(),
    });

    let totalBorrados = 0;
    // Estados finales (no operativos en curso).
    const estadosFinales = ["ENVIADO", "ERROR", "EXPIRADO"];

    for (const estado of estadosFinales) {
      let restantes = MAX_DOCS_POR_CORRIDA - totalBorrados;
      if (restantes <= 0) break;

      while (restantes > 0) {
        const limit = Math.min(BATCH_SIZE, restantes);
        try {
          const snap = await db.collection("COLA_WHATSAPP")
            .where("estado", "==", estado)
            .where("encolado_en", "<", cutoff)
            .limit(limit)
            .get();

          if (snap.empty) break;

          const batch = db.batch();
          snap.docs.forEach((d: FirebaseFirestore.QueryDocumentSnapshot) =>
            batch.delete(d.ref));
          await batch.commit();
          totalBorrados += snap.size;
          restantes -= snap.size;

          logger.info(
            `[purgarColaWhatsappAntigua] batch ${estado}: ${snap.size} ` +
            `docs borrados (acumulado ${totalBorrados})`
          );

          // Si el batch trajo menos que el limit, no hay mas docs
          // viejos de este estado.
          if (snap.size < limit) break;
        } catch (e) {
          logger.error(
            `[purgarColaWhatsappAntigua] error en batch ${estado}`,
            { error: (e as Error).message }
          );
          break; // intentar siguiente estado / proximo ciclo del dia
        }
      }
    }

    logger.info("[purgarColaWhatsappAntigua] fin", {
      totalBorrados,
      cap: MAX_DOCS_POR_CORRIDA,
    });
  }
);
