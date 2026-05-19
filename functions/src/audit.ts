/**
 * Cloud Function de auditoría — `auditLogWrite`.
 *
 * Extraído de index.ts (refactor split 2026-05-19). Callable que escribe
 * a `AUDITORIA_ACCIONES` con el DNI/nombre del admin tomados del JWT (no
 * del cliente), lo que permite cerrar la rule de esa colección a
 * `write: if false`. Incluye whitelist de acciones/entidades + límite de
 * tamaño de payload.
 *
 * Módulo independiente: no comparte helpers con Volvo/telemetría ni con
 * el resto. Re-exportado desde index.ts con `export * from "./audit"`.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { FieldValue } from "firebase-admin/firestore";

import { db } from "./setup";

// ============================================================================
// auditLogWrite
// ============================================================================
// Callable que escribe a AUDITORIA_ACCIONES con datos del admin tomados
// del JWT (uid + custom claim `nombre`). Permite cerrar la rule de
// AUDITORIA_ACCIONES a `write: if false` y que solo el server pueda
// escribir, eliminando la posibilidad de que un admin con la consola
// abierta forje entradas de bitácora.
//
// Diseño:
//   - **Whitelist de acciones**: el caller no puede inventar strings
//     nuevos. Si el enum AuditAccion del cliente agrega un caso, hay
//     que sumarlo acá también (es una conscious choice — la auditoría
//     no debería tener vocabulario abierto).
//   - **Sanitización de tamaño**: payload total <= 10KB para defendernos
//     de un caller que mande un detalles enorme y nos haga gastar
//     espacio.
//   - **Fire-and-forget cliente**: la function devuelve OK rápido. Si
//     algo falla, el cliente loguea y sigue; nunca bloquea al admin.

const AUDIT_ACCIONES_PERMITIDAS = new Set<string>([
  // Personal
  "CREAR_CHOFER",
  "EDITAR_CHOFER",
  "CAMBIAR_FOTO_PERFIL",
  "REEMPLAZAR_PAPEL_CHOFER",
  "DAR_DE_BAJA_EMPLEADO",
  "REACTIVAR_EMPLEADO",
  // Flota
  "CREAR_VEHICULO",
  "EDITAR_VEHICULO",
  "CAMBIAR_FOTO_VEHICULO",
  "DAR_DE_BAJA_VEHICULO",
  "REACTIVAR_VEHICULO",
  // Asignaciones
  "ASIGNAR_EQUIPO",
  "DESVINCULAR_EQUIPO",
  // Revisiones
  "APROBAR_REVISION",
  "RECHAZAR_REVISION",
  // Alertas Volvo
  "MARCAR_ALERTA_VOLVO_ATENDIDA",
  // Gomería
  "CREAR_CUBIERTA",
  "INSTALAR_CUBIERTA",
  "RETIRAR_CUBIERTA",
  "DESCARTAR_CUBIERTA",
  "ENVIAR_CUBIERTA_A_RECAPAR",
  "RECIBIR_CUBIERTA_DE_RECAPADO",
]);

/**
 * Acciones que SUPERVISOR puede registrar (además de ADMIN).
 *
 * Los flujos de gomería son operados por supervisor + AREA=GOMERIA.
 * Los de asignaciones (chofer↔tractor, tractor↔enganche) los puede
 * disparar tanto el ADMIN como un SUPERVISOR (el callsite de
 * AsignacionVehiculoService / AsignacionEngancheService no distingue).
 * Sin esta lista, el callable rechazaría con permission-denied y la
 * bitácora se quedaría sin entradas para esos flujos críticos.
 */
const AUDIT_ACCIONES_SUPERVISOR_PERMITIDAS = new Set<string>([
  // Asignaciones — supervisor puede cambiar quién maneja qué.
  "ASIGNAR_EQUIPO",
  "DESVINCULAR_EQUIPO",
  // Gomería — el supervisor de gomería opera todo el flujo.
  "CREAR_CUBIERTA",
  "INSTALAR_CUBIERTA",
  "RETIRAR_CUBIERTA",
  "DESCARTAR_CUBIERTA",
  "ENVIAR_CUBIERTA_A_RECAPAR",
  "RECIBIR_CUBIERTA_DE_RECAPADO",
]);

const AUDIT_ENTIDADES_PERMITIDAS = new Set<string>([
  "EMPLEADOS",
  "VEHICULOS",
  "REVISIONES",
  "VOLVO_ALERTAS",
  "CUBIERTAS",
]);

const AUDIT_MAX_DETALLES_BYTES = 10 * 1024; // 10KB

interface AuditLogResult {
  ok: true;
  docId: string;
}

export const auditLogWrite = onCall(
  {
    enforceAppCheck: false, // todavía no está activado App Check
  },
  async (request): Promise<AuditLogResult> => {
    // ─── Auth: ADMIN o SUPERVISOR ──────────────────────────────────
    // ADMIN puede registrar cualquier acción de la whitelist.
    // SUPERVISOR puede registrar SOLO las acciones de
    // AUDIT_ACCIONES_SUPERVISOR_PERMITIDAS (asignaciones + gomería).
    // El check fino se hace después de validar el campo accion.
    const rol = request.auth?.token?.rol;
    if (!request.auth || (rol !== "ADMIN" && rol !== "SUPERVISOR")) {
      logger.warn("[auditLog] llamada sin auth ADMIN/SUPERVISOR", {
        uid: request.auth?.uid ?? "no-uid",
        rol: rol ?? "no-rol",
      });
      throw new HttpsError(
        "permission-denied",
        "Solo admin o supervisor pueden escribir bitácora."
      );
    }

    // ─── Validación de input ───────────────────────────────────────
    const data = request.data ?? {};
    const accion = (data.accion ?? "").toString().trim();
    const entidad = (data.entidad ?? "").toString().trim();
    const entidadId = (data.entidadId ?? "").toString().trim();
    const detalles = data.detalles;

    if (!accion || !AUDIT_ACCIONES_PERMITIDAS.has(accion)) {
      throw new HttpsError(
        "invalid-argument",
        `Acción '${accion}' no está en la whitelist.`
      );
    }

    // SUPERVISOR solo puede registrar acciones de su scope reducido.
    if (rol === "SUPERVISOR" &&
        !AUDIT_ACCIONES_SUPERVISOR_PERMITIDAS.has(accion)) {
      logger.warn("[auditLog] supervisor intentó acción fuera de scope", {
        uid: request.auth.uid,
        accion,
      });
      throw new HttpsError(
        "permission-denied",
        `Acción '${accion}' está reservada para ADMIN.`
      );
    }

    if (!entidad || !AUDIT_ENTIDADES_PERMITIDAS.has(entidad)) {
      throw new HttpsError(
        "invalid-argument",
        `Entidad '${entidad}' no está en la whitelist.`
      );
    }

    if (entidadId.length > 100) {
      throw new HttpsError(
        "invalid-argument",
        "entidadId demasiado largo (máx 100 chars)."
      );
    }

    // detalles debe ser objeto plano serializable y NO vacío. Validamos
    // tamaño serializando con JSON.stringify — si tira por circular
    // references o tipos no-serializables, rechazamos.
    //
    // Bug A3 del code review: antes aceptábamos {} y null. Ahora si
    // viene `detalles` debe tener al menos una key — sino, mejor
    // omitirlo del request directamente.
    let detallesPersistir: Record<string, unknown> | null = null;
    if (detalles != null) {
      if (typeof detalles !== "object" || Array.isArray(detalles)) {
        throw new HttpsError(
          "invalid-argument",
          "`detalles` debe ser un objeto plano."
        );
      }
      const detallesObj = detalles as Record<string, unknown>;
      if (Object.keys(detallesObj).length === 0) {
        throw new HttpsError(
          "invalid-argument",
          "`detalles` no puede ser un objeto vacío."
        );
      }
      let serializados: string;
      try {
        serializados = JSON.stringify(detallesObj);
      } catch {
        throw new HttpsError(
          "invalid-argument",
          "`detalles` no es serializable."
        );
      }
      if (serializados.length > AUDIT_MAX_DETALLES_BYTES) {
        throw new HttpsError(
          "resource-exhausted",
          `\`detalles\` excede el límite (${AUDIT_MAX_DETALLES_BYTES} bytes).`
        );
      }
      detallesPersistir = detallesObj;
    }

    // ─── Datos del admin desde el JWT ──────────────────────────────
    // request.auth.uid es el DNI gracias a loginConDni que setea uid=dni.
    // request.auth.token.nombre es un custom claim también seteado en
    // loginConDni. Si por algún motivo no está, fallback a "Admin".
    const adminDni = request.auth.uid;
    const adminNombre = (request.auth.token.nombre ?? "Admin").toString();

    // ─── Escritura ─────────────────────────────────────────────────
    const doc: Record<string, unknown> = {
      accion,
      entidad,
      admin_dni: adminDni,
      admin_nombre: adminNombre,
      timestamp: FieldValue.serverTimestamp(),
    };
    if (entidadId) {
      doc.entidad_id = entidadId;
    }
    if (detallesPersistir != null) {
      doc.detalles = detallesPersistir;
    }

    try {
      const ref = await db.collection("AUDITORIA_ACCIONES").add(doc);
      logger.info("[auditLog] OK", {
        accion,
        entidad,
        entidadId: entidadId || undefined,
        adminDni,
        docId: ref.id,
      });
      return { ok: true, docId: ref.id };
    } catch (e) {
      logger.error("[auditLog] error escribiendo", {
        accion,
        entidad,
        error: (e as Error).message,
      });
      throw new HttpsError(
        "internal",
        "No se pudo registrar la acción en bitácora."
      );
    }
  }
);
