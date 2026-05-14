/**
 * Cloud Functions de Coopertrans Móvil.
 *
 * Endpoints expuestos:
 *   - `loginConDni`: emite custom token de Firebase Auth a partir de
 *     un par DNI + contraseña (con rate limit + migración bcrypt).
 *   - `volvoProxy`: llama la API de Volvo Connect en nombre del admin
 *     manteniendo las credenciales server-side (Secret Manager).
 *   - `auditLogWrite`: escribe entradas en AUDITORIA_ACCIONES con el
 *     DNI/nombre del admin tomado del JWT (no del cliente). Permite
 *     cerrar la rule de esa colección a `write: if false`.
 *   - `telemetriaSnapshotScheduled`: cron cada 6h que escribe a
 *     TELEMETRIA_HISTORICO via Admin SDK.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { setGlobalOptions } from "firebase-functions/v2";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import {
  getFirestore,
  FieldValue,
  DocumentReference,
  Timestamp,
  Firestore,
  Transaction,
} from "firebase-admin/firestore";
import { v1 as firestoreAdminV1 } from "@google-cloud/firestore";
import * as bcrypt from "bcryptjs";
import * as crypto from "crypto";

// Inicialización del Admin SDK (una sola vez por instancia).
initializeApp();

// Configuración global: límite de instancias concurrentes para que un
// loop de login no me funda la cuenta. La region es southamerica-east1
// (São Paulo) para estar en el mismo DC que Firestore — eso elimina el
// hop us-central1 ↔ sa-east1 en cada read/write (~150ms por op).
setGlobalOptions({
  region: "southamerica-east1",
  maxInstances: 10,
  // El timeout por defecto es 60 segundos, suficiente.
});

const db = getFirestore();
const auth = getAuth();

// ============================================================================
// Configuración de rate limiting
// ============================================================================
// Después de N intentos fallidos consecutivos sobre el mismo DNI, se
// bloquea ese DNI por X minutos. Implementado server-side en la
// colección LOGIN_ATTEMPTS (clave = hash corto del DNI para no exponer
// el dato en el path del documento).
//
// El reset del contador es automático: cualquier login OK lo borra.
// Después del bloqueo, el próximo intento fallido empieza un nuevo
// ciclo desde 1.
//
// Endurecido el 2026-05-03: pasó de 5 intentos / 5 min a 3 intentos /
// 15 min. Una flota chica (~50 empleados) tiene casi cero falsos
// positivos legítimos (el chofer/admin sabe su DNI o tiene "recordar
// DNI" del login), así que 3 intentos cubre los typos genuinos.
// Fuerza bruta: con la config vieja un atacante podía probar 60 combos
// por hora; con la nueva, 12. Reducción 5x del techo de tasa.
const MAX_INTENTOS_FALLIDOS = 3;
const BLOQUEO_DURACION_MS = 15 * 60 * 1000; // 15 minutos

// Banner que se inyecta al final de cada mensaje de WhatsApp generado
// por estas funciones mientras la app esté en etapa de prueba. Quitar
// cuando se pase a producción real con todos los choferes/admins
// onboardeados (espejo del BANNER_TESTING que vive en los builders del
// bot Node.js).
const BANNER_TESTING =
  "⚠️ *Etapa de prueba* — si ves un error o algo no encaja, avisanos. " +
  "No tomes el contenido al 100%.\n\n";

// ============================================================================
// loginConDni
// ============================================================================

/**
 * Verifica un par DNI + contraseña contra `EMPLEADOS/{dni}` y devuelve
 * un custom token de Firebase Auth con UID = DNI y custom claims
 * `{ rol, nombre }`.
 *
 * Soporta dos formatos de hash en la columna `CONTRASEÑA`:
 *   - **bcrypt** (nuevo, con salt): `$2a$.../$2b$.../$2y$...`
 *   - **SHA-256** (legacy): 64 chars hex
 *
 * Si el hash era SHA-256 y la contraseña es correcta, lo reescribe a
 * bcrypt en background (migración silenciosa). Si esa migración falla,
 * el login NO falla — el usuario sigue entrando.
 *
 * Implementa rate limiting por DNI: 5 intentos fallidos consecutivos →
 * bloqueo de 15 minutos. Ver constantes arriba.
 *
 * Errores devueltos al cliente con mensaje genérico para no facilitar
 * enumeración de DNIs (un atacante no puede distinguir "DNI no existe"
 * de "password equivocado"). El logger interno sí discrimina para que
 * podamos diagnosticar.
 */
export const loginConDni = onCall(
  {
    enforceAppCheck: false, // todavía no está activado App Check
  },
  async (request) => {
    // Validación extraída a función pura (testeable sin Firebase).
    const { dni, password } = validarInputLogin(request.data);

    // ─── Lectura del legajo ────────────────────────────────────────
    const docRef = db.collection("EMPLEADOS").doc(dni);
    const docSnap = await docRef.get();

    if (!docSnap.exists) {
      logger.info("[login] DNI no existe", { dni });
      throw new HttpsError(
        "not-found",
        "El usuario no existe o el DNI es incorrecto."
      );
    }

    const empleado = docSnap.data() ?? {};

    // ─── Cuenta activa ─────────────────────────────────────────────
    const isActive = empleado.ACTIVO !== false; // default: activo si falta el campo
    if (!isActive) {
      logger.info("[login] cuenta inactiva", { dni });
      throw new HttpsError(
        "permission-denied",
        "Usuario inactivo. Contacte a administración."
      );
    }

    // ─── Rate limit: chequeo de bloqueo previo ─────────────────────
    // Si esta DNI ya está bloqueada por intentos previos, cortamos acá.
    // No verificamos password, no quemamos CPU, no damos info al
    // atacante sobre si la password actual era correcta o no.
    const intentosRef = db.collection("LOGIN_ATTEMPTS").doc(hashId(dni));
    const minBloqueo = await chequearBloqueoActivo(intentosRef);
    if (minBloqueo > 0) {
      logger.warn("[login] bloqueado por rate limit", {
        dniHash: hashId(dni),
        minutosRestantes: minBloqueo,
      });
      throw new HttpsError(
        "resource-exhausted",
        `Demasiados intentos fallidos. Reintentá en ${minBloqueo} minutos.`
      );
    }

    // ─── Verificación de contraseña ────────────────────────────────
    const storedHash = (empleado["CONTRASEÑA"] ?? "").toString();
    if (!storedHash) {
      logger.warn("[login] empleado sin hash de contraseña", { dni });
      throw new HttpsError(
        "failed-precondition",
        "El usuario no tiene contraseña configurada. Contacte a administración."
      );
    }

    const passwordOk = await verificarPassword(password, storedHash);
    if (!passwordOk) {
      // Registramos intento fallido. La transaccion atomicamente
      // incrementa el contador Y devuelve si quedo bloqueado, asi no
      // hace falta un get() suelto previo (Bug M1: el chequeo previo
      // tenia ventana de race con esta tx).
      const resultado = await registrarIntentoFallido(intentosRef);
      logger.info("[login] password incorrecto", {
        dniHash: hashId(dni),
        intentosFallidos: resultado.intentos,
        bloqueadoMinRestantes: resultado.bloqueadoMinRestantes,
      });
      if (resultado.bloqueadoMinRestantes > 0) {
        // Si justo este intento ES el que cruza el umbral, avisamos
        // al usuario explicitamente. Si ya estaba bloqueado de antes,
        // mensaje informativo.
        const recienBloqueado =
          resultado.intentos >= MAX_INTENTOS_FALLIDOS;
        const mins = resultado.bloqueadoMinRestantes;
        const msg = recienBloqueado ?
          `Contraseña incorrecta. Cuenta bloqueada temporalmente por ${mins} minutos.` :
          `Cuenta bloqueada. Reintenta en ${mins} minutos.`;
        throw new HttpsError("permission-denied", msg);
      }
      throw new HttpsError("permission-denied", "Contraseña incorrecta.");
    }

    // ─── Migración silenciosa SHA-256 → bcrypt ─────────────────────
    if (esLegacy(storedHash)) {
      // No bloqueamos el login si falla.
      try {
        const nuevoHash = await bcrypt.hash(password, 10);
        await docRef.update({
          "CONTRASEÑA": nuevoHash,
          "hash_migrado_a_bcrypt": FieldValue.serverTimestamp(),
        });
        logger.info("[login] hash migrado a bcrypt", { dniHash: hashId(dni) });
      } catch (e) {
        logger.warn("[login] migración silenciosa falló (no bloquea)", {
          dniHash: hashId(dni),
          error: (e as Error).message,
        });
      }
    }

    // ─── Reset del contador de intentos (login OK) ─────────────────
    // Si el usuario tuvo intentos fallidos previos pero al final acertó,
    // limpiamos el contador. No bloquea login si falla.
    try {
      await intentosRef.delete();
    } catch (e) {
      logger.warn("[login] no pude limpiar LOGIN_ATTEMPTS (no bloquea)", {
        dniHash: hashId(dni),
        error: (e as Error).message,
      });
    }

    // ─── Emisión del custom token ──────────────────────────────────
    // UID = DNI para que `request.auth.uid` en las rules sea el DNI.
    const nombre = (empleado.NOMBRE ?? "Usuario").toString();
    const apodo = (empleado.APODO ?? "").toString().trim();
    const area = (empleado.AREA ?? "MANEJO").toString();
    // Normalizamos roles: el legacy USUARIO se trata como CHOFER.
    // Lista válida nueva: CHOFER, PLANTA, SUPERVISOR, ADMIN.
    const rolRaw = (empleado.ROL ?? "CHOFER").toString().toUpperCase();
    const rolesValidos = ["CHOFER", "PLANTA", "SUPERVISOR", "ADMIN"];
    let rol = rolRaw;
    if (rolRaw === "USUARIO" || rolRaw === "USER") rol = "CHOFER";
    if (!rolesValidos.includes(rol)) rol = "CHOFER";

    const token = await auth.createCustomToken(dni, {
      rol,
      area,
      // Nombre como custom claim ahorra una lectura de Firestore en el
      // cliente cada vez que necesita mostrar el nombre del logueado.
      nombre,
    });

    logger.info("[login] OK", { dniHash: hashId(dni), rol, area });

    return {
      token,
      // Devolvemos también los datos básicos para que el cliente no
      // tenga que decodificar el JWT solo para mostrar el nombre.
      dni,
      nombre,
      // Apodo: el cliente lo cachea en PrefsService para mostrar el
      // saludo "Buen día, Santi" SIN tener que hacer una lectura asíncrona
      // a Firestore al renderizar el dashboard (eliminamos el flicker
      // "Bienvenido Santiago" → "Bienvenido Santi" — fix 2026-05-07).
      apodo,
      rol,
      area,
    };
  }
);

// ============================================================================
// actualizarRolEmpleado
// ============================================================================
//
// Callable que cambia el ROL y/o ÁREA de un empleado. Hace dos cosas
// que NO se pueden hacer desde el cliente:
//   1. Validar que el caller sea ADMIN (no solo SUPERVISOR).
//   2. Actualizar el custom claim del usuario afectado, para que su
//      JWT refleje el nuevo rol en su próximo `getIdToken(true)` o
//      después del expire del token (~1 hora).
//
// Si solo se actualiza AREA (que no afecta permisos), el cliente puede
// hacerlo directo a Firestore. Esta callable es para cuando hay que
// tocar ROL o ambos.

const ROLES_VALIDOS = [
  "CHOFER",
  "PLANTA",
  "GOMERIA",
  "SEG_HIGIENE",
  "SUPERVISOR",
  "ADMIN",
];
const AREAS_VALIDAS = [
  "MANEJO",
  "ADMINISTRACION",
  "PLANTA",
  "TALLER",
  "GOMERIA",
];

export const actualizarRolEmpleado = onCall(
  { timeoutSeconds: 15 },
  async (request) => {
    // ─── Auth: solo ADMIN ──────────────────────────────────────────
    const rolCaller = request.auth?.token?.rol;
    if (!request.auth || rolCaller !== "ADMIN") {
      logger.warn("[actualizarRolEmpleado] sin auth ADMIN", {
        uid: request.auth?.uid ?? "no-uid",
        rol: rolCaller ?? "no-rol",
      });
      throw new HttpsError(
        "permission-denied",
        "Solo ADMIN puede cambiar roles."
      );
    }

    // ─── Validación de input ───────────────────────────────────────
    const dni = (request.data?.dni ?? "").toString().trim();
    const rolNuevoRaw = request.data?.rol ?
      request.data.rol.toString().toUpperCase() :
      null;
    const areaNuevaRaw = request.data?.area ?
      request.data.area.toString().toUpperCase() :
      null;

    if (!dni) {
      throw new HttpsError("invalid-argument", "Falta `dni`.");
    }
    if (rolNuevoRaw === null && areaNuevaRaw === null) {
      throw new HttpsError(
        "invalid-argument",
        "Hay que pasar al menos `rol` o `area`."
      );
    }
    if (rolNuevoRaw !== null && !ROLES_VALIDOS.includes(rolNuevoRaw)) {
      throw new HttpsError(
        "invalid-argument",
        `Rol inválido: ${rolNuevoRaw}. Esperado: ${ROLES_VALIDOS.join(", ")}.`
      );
    }
    if (areaNuevaRaw !== null && !AREAS_VALIDAS.includes(areaNuevaRaw)) {
      throw new HttpsError(
        "invalid-argument",
        `Área inválida: ${areaNuevaRaw}. Esperado: ${AREAS_VALIDAS.join(", ")}.`
      );
    }

    // ─── Lectura del doc actual ────────────────────────────────────
    const empleadoRef = db.collection("EMPLEADOS").doc(dni);
    const snap = await empleadoRef.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", `Empleado ${dni} no encontrado.`);
    }
    const data = snap.data() ?? {};

    const rolFinal = rolNuevoRaw ??
      (data.ROL ?? "CHOFER").toString().toUpperCase();
    const areaFinal = areaNuevaRaw ??
      (data.AREA ?? "MANEJO").toString().toUpperCase();
    const nombre = (data.NOMBRE ?? "Usuario").toString();

    // ─── Update Firestore + custom claim ───────────────────────────
    const updates: Record<string, unknown> = {
      fecha_ultima_actualizacion: FieldValue.serverTimestamp(),
    };
    if (rolNuevoRaw !== null) updates.ROL = rolFinal;
    if (areaNuevaRaw !== null) updates.AREA = areaFinal;

    // Si después del cambio el empleado deja de ser CHOFER+MANEJO,
    // libera las unidades asignadas. Esto evita que un tractor quede
    // "atado" a alguien que ya no maneja, bloqueando que otro chofer
    // lo tome. Solo limpiamos si TENÍA algo cargado, para no crear
    // ruido en la auditoría con updates triviales.
    const yaNoManeja = rolFinal !== "CHOFER" || areaFinal !== "MANEJO";
    const teniaVehiculo = data.VEHICULO && data.VEHICULO !== "-";
    const teniaEnganche = data.ENGANCHE && data.ENGANCHE !== "-";
    if (yaNoManeja && (teniaVehiculo || teniaEnganche)) {
      updates.VEHICULO = "-";
      updates.ENGANCHE = "-";
      logger.info(
        "[actualizarRolEmpleado] liberadas unidades asignadas",
        {
          dniHash: hashId(dni),
          vehiculoAnterior: data.VEHICULO,
          engancheAnterior: data.ENGANCHE,
        }
      );
    }

    await empleadoRef.update(updates);

    // Si liberamos unidades en EMPLEADOS, también las marcamos como
    // LIBRE en VEHICULOS para que aparezcan disponibles al reasignarlas
    // a otro chofer. Si no, quedaban en estado OCUPADO sin titular.
    //
    // Updates tolerantes a 'doc no existe' (la patente vieja podría haber
    // sido eliminada): try/catch individual por update para que un
    // problema con una unidad no bloquee la otra.
    if (yaNoManeja) {
      if (teniaVehiculo) {
        try {
          await db
            .collection("VEHICULOS")
            .doc(String(data.VEHICULO))
            .update({ ESTADO: "LIBRE" });
        } catch (e) {
          logger.warn(
            "[actualizarRolEmpleado] no pude liberar VEHICULO " + data.VEHICULO,
            { error: (e as Error).message }
          );
        }
      }
      if (teniaEnganche) {
        try {
          await db
            .collection("VEHICULOS")
            .doc(String(data.ENGANCHE))
            .update({ ESTADO: "LIBRE" });
        } catch (e) {
          logger.warn(
            "[actualizarRolEmpleado] no pude liberar ENGANCHE " + data.ENGANCHE,
            { error: (e as Error).message }
          );
        }
      }
    }

    // setCustomUserClaims funciona aunque el usuario no esté logueado
    // ahora — graba el claim para el próximo getIdToken(true) o expire.
    // Si el UID no existe en Firebase Auth (caso de empleados que nunca
    // hicieron login), lanzamos pero no rompemos: el claim se setea
    // cuando hagan loginConDni la próxima vez.
    try {
      await auth.setCustomUserClaims(dni, {
        rol: rolFinal,
        area: areaFinal,
        nombre,
      });
      logger.info("[actualizarRolEmpleado] claim actualizado", {
        dniHash: hashId(dni),
        rolNuevo: rolFinal,
        areaNueva: areaFinal,
      });
    } catch (e) {
      logger.info(
        "[actualizarRolEmpleado] usuario sin Auth account, " +
          "claim se aplicará al próximo login",
        { dniHash: hashId(dni), error: (e as Error).message }
      );
    }

    return {
      ok: true,
      dni,
      rol: rolFinal,
      area: areaFinal,
    };
  }
);

// ============================================================================
// renombrarEmpleadoDni — corrige el DNI de un empleado mal cargado
// ============================================================================
//
// El DNI es el doc id de EMPLEADOS, así que NO se puede "editar" inline
// como cualquier otro campo. Renombrar implica:
//   1. Crear EMPLEADOS/{dniNuevo} copiando todos los campos.
//   2. Cascadear las referencias por chofer_dni / destinatario_id en
//      otras colecciones (asignaciones, alertas Volvo, cola WhatsApp).
//   3. Borrar EMPLEADOS/{dniViejo}.
//
// Solo ADMIN. No se permite renombrar al admin que ejecuta la operación
// (se quedaría sin sesión sin poder loguear).
//
// Cascada best-effort por colección — si una falla, la rest sigue. Las
// fallas se loguean y se devuelven en el response para que el admin
// las pueda revisar manualmente.
//
// AUDIT_LOG NO se reescribe (es histórico inmutable). Cualquier consulta
// futura va a encontrar el DNI viejo en el audit; eso es correcto, pasó
// con ese DNI en ese momento.

export const renombrarEmpleadoDni = onCall(
  { timeoutSeconds: 60 },
  async (request) => {
    // ─── Auth: solo ADMIN ──────────────────────────────────────────
    const rolCaller = request.auth?.token?.rol;
    if (!request.auth || rolCaller !== "ADMIN") {
      logger.warn("[renombrarEmpleadoDni] sin auth ADMIN", {
        uid: request.auth?.uid ?? "no-uid",
        rol: rolCaller ?? "no-rol",
      });
      throw new HttpsError(
        "permission-denied",
        "Solo ADMIN puede renombrar empleados."
      );
    }

    // ─── Validación de input ───────────────────────────────────────
    const dniViejo = (request.data?.dniViejo ?? "")
      .toString()
      .trim()
      .replace(/\D/g, "");
    const dniNuevo = (request.data?.dniNuevo ?? "")
      .toString()
      .trim()
      .replace(/\D/g, "");

    if (!dniViejo || !dniNuevo) {
      throw new HttpsError(
        "invalid-argument",
        "Hay que pasar `dniViejo` y `dniNuevo`."
      );
    }
    if (dniViejo === dniNuevo) {
      throw new HttpsError(
        "invalid-argument",
        "El DNI nuevo es igual al viejo."
      );
    }
    if (dniNuevo.length < 7 || dniNuevo.length > 8) {
      throw new HttpsError(
        "invalid-argument",
        `El DNI nuevo (${dniNuevo}) debe tener 7 u 8 dígitos.`
      );
    }
    if (request.auth.uid === dniViejo) {
      // Renombrarse a uno mismo cierra la sesión actual sin poder
      // re-loguear con el JWT viejo. Para evitar el lockout, lo
      // bloqueamos: tenés que pedírselo a otro admin.
      throw new HttpsError(
        "failed-precondition",
        "No podés renombrar tu propio DNI. Pedíselo a otro admin."
      );
    }

    // ─── Lecturas previas ──────────────────────────────────────────
    const refViejo = db.collection("EMPLEADOS").doc(dniViejo);
    const refNuevo = db.collection("EMPLEADOS").doc(dniNuevo);

    const [snapViejo, snapNuevo] = await Promise.all([
      refViejo.get(),
      refNuevo.get(),
    ]);

    if (!snapViejo.exists) {
      throw new HttpsError(
        "not-found",
        `Empleado ${dniViejo} no existe.`
      );
    }
    if (snapNuevo.exists) {
      throw new HttpsError(
        "already-exists",
        `Ya existe un empleado con DNI ${dniNuevo}. ` +
          "Para fusionar legajos, hace falta una operación distinta."
      );
    }

    const dataViejo = snapViejo.data() ?? {};

    // ─── Step 1: crear el doc nuevo copiando todo + actualizar campo
    // DNI (si existe) y agregando trazabilidad. ─────────────────────
    const dataNuevo: Record<string, unknown> = {
      ...dataViejo,
      // Si alguien tocó "DNI" inline en la ficha, ese campo ahora
      // queda alineado al doc id nuevo. Si nunca existió, lo creamos
      // por las dudas para que sea consistente.
      DNI: dniNuevo,
      // Trazabilidad de la operación.
      renombrado_desde: dniViejo,
      renombrado_en: FieldValue.serverTimestamp(),
      renombrado_por: request.auth.uid,
      fecha_ultima_actualizacion: FieldValue.serverTimestamp(),
    };
    await refNuevo.set(dataNuevo);

    // ─── Step 2: cascada — best-effort por colección ───────────────
    interface CascadaResult {
      coleccion: string;
      actualizados: number;
      error: string | null;
    }
    const cascada: CascadaResult[] = [];

    async function actualizarReferencias(
      coleccion: string,
      campo: string,
      filtroExtra?: (q: FirebaseFirestore.Query) => FirebaseFirestore.Query
    ): Promise<void> {
      try {
        let q: FirebaseFirestore.Query = db
          .collection(coleccion)
          .where(campo, "==", dniViejo);
        if (filtroExtra) q = filtroExtra(q);
        const snap = await q.get();
        if (snap.empty) {
          cascada.push({ coleccion, actualizados: 0, error: null });
          return;
        }
        // Updates en batch (límite Firestore: 500 ops por batch — más
        // que suficiente para ratios típicos). Si un día un chofer
        // tiene > 500 alertas Volvo, paginamos.
        const MAX_BATCH = 500;
        let actualizados = 0;
        for (let i = 0; i < snap.docs.length; i += MAX_BATCH) {
          const batch = db.batch();
          for (const d of snap.docs.slice(i, i + MAX_BATCH)) {
            batch.update(d.ref, { [campo]: dniNuevo });
            actualizados++;
          }
          await batch.commit();
        }
        cascada.push({ coleccion, actualizados, error: null });
      } catch (e) {
        cascada.push({
          coleccion,
          actualizados: 0,
          error: (e as Error).message,
        });
      }
    }

    // Asignaciones chofer↔vehículo: histórico completo + activas.
    await actualizarReferencias("ASIGNACIONES_VEHICULO", "chofer_dni");

    // Eventos del Volvo Vehicle Alerts API: snapshot del chofer en el
    // momento del evento. Lo actualizamos para que las consultas
    // futuras "alertas de este chofer" devuelvan los del DNI nuevo.
    await actualizarReferencias("VOLVO_ALERTAS", "chofer_dni");

    // Cola de WhatsApp: solo PENDIENTES — los enviados ya viajaron
    // con el DNI viejo y no tiene sentido reescribirlos.
    await actualizarReferencias(
      "COLA_WHATSAPP",
      "destinatario_id",
      (q) => q.where("estado", "==", "PENDIENTE")
    );

    // ─── Step 3: borrar el doc viejo ───────────────────────────────
    await refViejo.delete();

    logger.info("[renombrarEmpleadoDni] OK", {
      dniViejoHash: hashId(dniViejo),
      dniNuevoHash: hashId(dniNuevo),
      cascada,
    });

    return {
      ok: true,
      dniViejo,
      dniNuevo,
      cascada,
      mensaje: "Empleado renombrado. El chofer debe re-loguear con el " +
        "DNI nuevo (su sesión actual deja de funcionar).",
    };
  }
);

// ============================================================================
// Helpers
// ============================================================================

/**
 * Valida el input de `loginConDni` y devuelve los valores limpios.
 *
 * Tira `HttpsError("invalid-argument", ...)` con mensaje user-friendly
 * en cada caso de input invalido:
 *   - DNI o password vacios.
 *   - DNI fuera del rango 6-9 digitos (los DNIs argentinos modernos
 *     son 7-8; aceptamos 6-9 por legajos con formato distinto).
 *   - Password > 128 chars (vector de DoS contra bcrypt: si el atacante
 *     manda 1MB, bcrypt.compare procesa 1MB y bloquea el event loop).
 *
 * Devuelve un objeto con los valores ya saneados:
 *   - `dni`: solo digitos (cualquier separador / punto / espacio quitado).
 *   - `password`: trimeada en bordes.
 */
export function validarInputLogin(data: unknown): {
  dni: string;
  password: string;
} {
  const obj = (data ?? {}) as { dni?: unknown; password?: unknown };
  const dniRaw = (obj.dni ?? "").toString();
  const passwordRaw = (obj.password ?? "").toString();

  const dni = dniRaw.replace(/[^0-9]/g, "");
  const password = passwordRaw.trim();

  if (!dni || !password) {
    throw new HttpsError(
      "invalid-argument",
      "Complete todos los campos requeridos."
    );
  }
  if (dni.length < 6 || dni.length > 9) {
    throw new HttpsError(
      "invalid-argument",
      "El DNI tiene un formato inválido."
    );
  }
  if (password.length > 128) {
    throw new HttpsError(
      "invalid-argument",
      "Contraseña demasiado larga."
    );
  }

  return { dni, password };
}

/**
 * Compara una contraseña en plano con un hash en formato bcrypt o
 * SHA-256. Async porque `bcrypt.compare` (a diferencia de
 * `compareSync`) cede el event loop -- con `compareSync` y 5 logins
 * concurrentes el proceso quedaba bloqueado ~80ms por intento.
 */
export async function verificarPassword(
  password: string,
  storedHash: string
): Promise<boolean> {
  if (esBcrypt(storedHash)) {
    try {
      return await bcrypt.compare(password, storedHash);
    } catch {
      return false;
    }
  }
  // Fallback legacy: SHA-256 hex.
  return sha256Hex(password) === storedHash;
}

export function esBcrypt(hash: string): boolean {
  return (
    hash.startsWith("$2a$") ||
    hash.startsWith("$2b$") ||
    hash.startsWith("$2y$")
  );
}

export function esLegacy(hash: string): boolean {
  return !esBcrypt(hash);
}

export function sha256Hex(text: string): string {
  return crypto.createHash("sha256").update(text, "utf8").digest("hex");
}

/**
 * Hash corto y estable de un DNI para incluir en logs y como clave en
 * LOGIN_ATTEMPTS sin exponer el DNI real. NO criptográficamente seguro
 * contra enumeración (el dominio de DNIs es chico, ~10^8) — solo para
 * correlación de logs y para que el path de Firestore no contenga PII.
 */
export function hashId(text: string): string {
  return crypto
    .createHash("sha256")
    .update(text, "utf8")
    .digest("hex")
    .slice(0, 8);
}

// ============================================================================
// Rate limiting (LOGIN_ATTEMPTS)
// ============================================================================

/**
 * Devuelve los **minutos restantes de bloqueo** para esta DNI, o 0 si
 * no está bloqueada. El doc en LOGIN_ATTEMPTS tiene la siguiente
 * estructura:
 *   {
 *     intentos: number,         // contador de fallidos consecutivos
 *     ultimoIntento: timestamp, // último timestamp de fallo
 *     bloqueadoHasta?: timestamp, // existe si está bloqueado
 *   }
 */
export async function chequearBloqueoActivo(
  ref: DocumentReference
): Promise<number> {
  const snap = await ref.get();
  if (!snap.exists) return 0;
  const data = snap.data() ?? {};
  const bloqueadoHasta = data.bloqueadoHasta as Timestamp | undefined;
  if (!bloqueadoHasta) return 0;
  const restanteMs = bloqueadoHasta.toMillis() - Date.now();
  if (restanteMs <= 0) return 0;
  return Math.ceil(restanteMs / 60000); // redondeo arriba para que el mensaje no diga "0 minutos"
}

/**
 * Resultado de `registrarIntentoFallido`. La funcion devuelve toda la
 * informacion necesaria para que el caller decida que mensaje mostrar,
 * sin necesidad de un get() previo (que era vulnerable a race).
 */
interface ResultadoIntentoFallido {
  /** Contador post-incremento (o el valor previo si ya estaba bloqueado). */
  intentos: number;
  /** Minutos restantes de bloqueo (0 si NO esta bloqueado). */
  bloqueadoMinRestantes: number;
}

/**
 * Registra un intento fallido en LOGIN_ATTEMPTS y devuelve, ATOMICAMENTE
 * en la misma transaccion, si la cuenta queda bloqueada (con cuantos
 * minutos restantes). Esto cierra la ventana de race que existia con el
 * `chequearBloqueoActivo` previo (un get() suelto antes de la tx) -- Bug
 * M1 del code review.
 *
 * Caminos:
 *  - Doc ya tenia `bloqueadoHasta` futuro: NO incrementa, devuelve
 *    `{ intentos: <previo>, bloqueadoMinRestantes: <restante> }`. El
 *    caller informa al usuario que esta bloqueado.
 *  - Incrementa intentos. Si llega al MAX, marca `bloqueadoHasta` y
 *    devuelve `bloqueadoMinRestantes = duracion completa`.
 *  - Si todavia esta debajo del MAX, devuelve `bloqueadoMinRestantes = 0`.
 */
export async function registrarIntentoFallido(
  ref: DocumentReference,
  database: Firestore = db
): Promise<ResultadoIntentoFallido> {
  return await database.runTransaction(async (tx: Transaction) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? snap.data() ?? {} : {};

    // Si DENTRO de la transaccion ya vemos `bloqueadoHasta` futuro,
    // NO incrementamos y reportamos los minutos restantes. Esto cubre
    // el caso de logins paralelos donde el chequeo previo (sin tx) era
    // vulnerable a race.
    const yaBloqueado = data.bloqueadoHasta as Timestamp | undefined;
    if (yaBloqueado && yaBloqueado.toMillis() > Date.now()) {
      const intentosActuales = Number(data.intentos ?? 0);
      const restanteMs = yaBloqueado.toMillis() - Date.now();
      return {
        intentos: Number.isFinite(intentosActuales) ? intentosActuales : 0,
        bloqueadoMinRestantes: Math.ceil(restanteMs / 60000),
      };
    }

    // Bug A2 del code review: el campo `intentos` deberia ser number,
    // pero por corrupcion/migracion podria venir como string. Hacemos
    // coercion explicita y tolerante a cualquier tipo.
    const rawIntentos = data.intentos;
    const numIntentos =
      typeof rawIntentos === "number" ?
        rawIntentos :
        Number(rawIntentos ?? 0);
    const intentos = (Number.isFinite(numIntentos) ? numIntentos : 0) + 1;
    // Tipado del payload: TS 5.5+ exige que tx.update reciba
    // UpdateData<T> = `{[k: string]: FieldValue | Partial<unknown>
    // | undefined}` — con `Record<string, unknown>` falla porque
    // `unknown` no es asignable a `FieldValue | Partial<unknown>`.
    // Declarar como `any` mantiene el shape flexible que necesitamos
    // (numbers, FieldValue, Timestamp coexisten) sin engañar al
    // typechecker en otros llamadores.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const update: {[k: string]: any} = {
      intentos,
      ultimoIntento: FieldValue.serverTimestamp(),
    };
    let bloqueadoMinRestantes = 0;
    if (intentos >= MAX_INTENTOS_FALLIDOS) {
      update.bloqueadoHasta = Timestamp.fromMillis(
        Date.now() + BLOQUEO_DURACION_MS
      );
      bloqueadoMinRestantes = Math.ceil(BLOQUEO_DURACION_MS / 60000);
    }
    if (snap.exists) {
      tx.update(ref, update);
    } else {
      tx.set(ref, update);
    }
    return { intentos, bloqueadoMinRestantes };
  });
}

// ============================================================================
// volvoProxy
// ============================================================================
// Proxy server-side a la API de Volvo Connect. Mantiene las credenciales
// (`VOLVO_USERNAME`/`VOLVO_PASSWORD`) en Secret Manager y solo permite
// invocar a admins autenticados via Firebase Auth custom token.
//
// La function recibe `{operation, params}` y traduce a un GET autenticado
// contra Volvo. Devuelve `{statusCode, data}` para que el cliente conserve
// su capacidad de hacer parsing tolerante (paths legacy, etc).
//
// Setup inicial (una sola vez):
//   firebase functions:secrets:set VOLVO_USERNAME
//   firebase functions:secrets:set VOLVO_PASSWORD
//
// Operaciones soportadas:
//   - "flota"        → GET /vehicle/vehicles
//   - "telemetria"   → GET /vehicle/vehiclestatuses?vin=X&additionalContent=VOLVOGROUPSNAPSHOT
//   - "kilometraje"  → GET /vehicle/vehiclestatuses?vin=X
//   - "estadosFlota" → GET /vehicle/vehiclestatuses (todos)

const volvoUsername = defineSecret("VOLVO_USERNAME");
const volvoPassword = defineSecret("VOLVO_PASSWORD");

const VOLVO_BASE = "https://api.volvotrucks.com";
const ACCEPT_VEHICLES =
  "application/x.volvogroup.com.vehicles.v1.0+json; UTF-8";
const ACCEPT_STATUSES =
  "application/x.volvogroup.com.vehiclestatuses.v1.0+json; UTF-8";

// VIN estandar ISO 3779: 17 caracteres alfanumericos en mayuscula.
// Validamos cliente-side antes de forwardear a Volvo para cortar
// requests con VINs malformados (typos, fuzzing) sin tocar la API
// externa.
const VIN_REGEX = /^[A-Z0-9]{17}$/;
const VIN_INVALIDO_MSG = "`params.vin` no es un VIN valido (17 chars, A-Z y 0-9).";

interface VolvoProxyResult {
  statusCode: number;
  data: unknown;
}

export const volvoProxy = onCall(
  {
    secrets: [volvoUsername, volvoPassword],
    timeoutSeconds: 30,
  },
  async (request): Promise<VolvoProxyResult> => {
    // ─── Auth: solo admin logueado ─────────────────────────────────
    const rol = request.auth?.token?.rol;
    if (!request.auth || rol !== "ADMIN") {
      logger.warn("[volvoProxy] llamada sin auth ADMIN", {
        uid: request.auth?.uid ?? "no-uid",
        rol: rol ?? "no-rol",
      });
      throw new HttpsError(
        "permission-denied",
        "Solo administradores pueden consultar Volvo."
      );
    }

    // ─── Validación de input ───────────────────────────────────────
    const operation = (request.data?.operation ?? "").toString();
    const params = (request.data?.params ?? {}) as Record<string, unknown>;

    if (!operation) {
      throw new HttpsError("invalid-argument", "Falta `operation`.");
    }

    // ─── Routing por operación → URL Volvo ─────────────────────────
    let url: string;
    let accept: string;

    switch (operation) {
    case "flota": {
      url = `${VOLVO_BASE}/vehicle/vehicles`;
      accept = ACCEPT_VEHICLES;
      break;
    }
    case "telemetria": {
      const vin = (params.vin ?? "").toString().trim().toUpperCase();
      if (!vin) {
        throw new HttpsError("invalid-argument", "Falta `params.vin`.");
      }
      if (!VIN_REGEX.test(vin)) {
        throw new HttpsError("invalid-argument", VIN_INVALIDO_MSG);
      }
      const qs = new URLSearchParams({
        vin,
        latestOnly: "true",
        // contentFilter pide explícitamente todos los bloques disponibles
        // — ACCUMULATED (combustible total, distancia total),
        //   SNAPSHOT (velocidad, % combustible, GPS),
        //   UPTIME (serviceDistance, tellTaleInfo, engineCoolantTemp).
        // Sin este parámetro, según la doc Volvo deberían venir todos
        // pero algunas cuentas filtran UPTIME a menos que se pida explícito.
        contentFilter: "ACCUMULATED,SNAPSHOT,UPTIME",
        // additionalContent agrega contenido extra de Volvo Group
        // dentro del bloque snapshot (ej. estimatedDistanceToEmpty).
        additionalContent: "VOLVOGROUPSNAPSHOT",
      });
      url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;
      accept = ACCEPT_STATUSES;
      break;
    }
    case "kilometraje": {
      const vin = (params.vin ?? "").toString().trim().toUpperCase();
      if (!vin) {
        throw new HttpsError("invalid-argument", "Falta `params.vin`.");
      }
      if (!VIN_REGEX.test(vin)) {
        throw new HttpsError("invalid-argument", VIN_INVALIDO_MSG);
      }
      const qs = new URLSearchParams({
        vin,
        latestOnly: "true",
      });
      url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;
      accept = ACCEPT_STATUSES;
      break;
    }
    case "estadosFlota": {
      const qs = new URLSearchParams({
        latestOnly: "true",
        // Mismo `contentFilter` que `telemetria`: pide explícitamente
        // los 3 bloques. Necesario para que `uptimeData.serviceDistance`
        // venga en el batch de toda la flota.
        contentFilter: "ACCUMULATED,SNAPSHOT,UPTIME",
        additionalContent: "VOLVOGROUPSNAPSHOT",
      });
      url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;
      accept = ACCEPT_STATUSES;
      break;
    }
    default:
      throw new HttpsError(
        "invalid-argument",
        `Operación '${operation}' no soportada.`
      );
    }

    // ─── Llamada a Volvo ───────────────────────────────────────────
    const authHeader = "Basic " + Buffer.from(
      `${volvoUsername.value()}:${volvoPassword.value()}`
    ).toString("base64");

    try {
      const res = await fetch(url, {
        method: "GET",
        headers: {
          "Authorization": authHeader,
          "Accept": accept,
        },
      });

      // Volvo a veces devuelve cuerpo no-JSON ante 401/406. Toleramos.
      let body: unknown = null;
      const text = await res.text();
      if (text) {
        try {
          body = JSON.parse(text);
        } catch {
          body = { raw: text };
        }
      }

      logger.info("[volvoProxy] OK", {
        operation,
        statusCode: res.status,
      });

      return {
        statusCode: res.status,
        data: body,
      };
    } catch (e) {
      logger.error("[volvoProxy] error", {
        operation,
        error: (e as Error).message,
      });
      throw new HttpsError(
        "unavailable",
        "Error consultando Volvo. Reintentá en unos segundos."
      );
    }
  }
);

// ============================================================================
// telemetriaSnapshotScheduled
// ============================================================================
// Scheduled function que cada 6 horas:
//   1) Llama Volvo `/vehicle/vehicles` con secrets server-side.
//   2) Cruza con la colección VEHICULOS para mapear VIN → patente.
//   3) Escribe un snapshot idempotente por día y patente en
//      TELEMETRIA_HISTORICO (id `{patente}_{YYYY-MM-DD}`).
//
// Reemplaza la lógica que antes corría en el cliente Flutter
// (`AutoSyncService` → `VehiculoRepository.guardarSnapshotsDiarios`).
// Vivir server-side permite:
//   - Cerrar `TELEMETRIA_HISTORICO` con `write: if false` en las rules
//     (solo Admin SDK puede escribir).
//   - Que el snapshot se capture aún cuando ningún admin tenga la app
//     abierta.
//
// Frecuencia: cada 6 horas. El doc es idempotente por día, con lo cual
// múltiples corridas se sobreescriben. La frecuencia da resiliencia
// ante fallos puntuales sin generar costos significativos (4 calls
// Volvo + 4 batch writes por día).

export const telemetriaSnapshotScheduled = onSchedule(
  {
    schedule: "every 6 hours",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [volvoUsername, volvoPassword],
    // Bajado de 120s a 45s. La function hace fetch a Volvo + batch
    // write a Firestore. Ambas operaciones nunca tardaron mas de 20s
    // en operacion normal; 45s deja margen para latencia alta sin
    // pagar 75s de invocacion innecesarios.
    timeoutSeconds: 45,
    memory: "256MiB",
  },
  async () => {
    logger.info("[telemetriaSnapshot] iniciando ciclo");

    // ─── 1. Fetch flota Volvo ──────────────────────────────────────
    const authHeader = "Basic " + Buffer.from(
      `${volvoUsername.value()}:${volvoPassword.value()}`
    ).toString("base64");

    // El endpoint `/vehicle/vehicles` NO trae telemetría (solo metadata
    // como vin/marca/modelo). Para `accumulatedData.totalFuelConsumption`
    // y `hrTotalVehicleDistance` hay que pegarle a `/vehicle/vehiclestatuses`
    // con `latestOnly=true` (devuelve el último snapshot de cada unidad
    // en una sola request).
    // Bug M5 del code review: antes el fetch a Volvo se hacía una sola
    // vez. Si fallaba transient (timeout, glitch del API, latencia)
    // perdíamos el snapshot del día. Ahora hacemos hasta 3 intentos
    // con backoff exponencial (5s, 15s) antes de abortar.
    const qs = new URLSearchParams({
      latestOnly: "true",
      contentFilter: "ACCUMULATED,SNAPSHOT,UPTIME",
      additionalContent: "VOLVOGROUPSNAPSHOT",
    });
    const url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;

    let cache: unknown[] = [];
    let intentos = 0;
    const maxIntentos = 3;

    while (intentos < maxIntentos) {
      intentos++;
      try {
        const res = await fetch(url, {
          method: "GET",
          headers: {
            "Authorization": authHeader,
            "Accept": ACCEPT_STATUSES,
          },
        });
        if (!res.ok) {
          logger.warn("[telemetriaSnapshot] Volvo HTTP error", {
            statusCode: res.status,
            intento: intentos,
          });
          if (intentos >= maxIntentos) return;
          await new Promise((r) => setTimeout(r, 5000 * intentos));
          continue;
        }
        const body = (await res.json()) as Record<string, unknown>;
        const statusResponse = body?.vehicleStatusResponse as
          | Record<string, unknown>
          | undefined;
        const list = statusResponse?.vehicleStatuses;
        if (Array.isArray(list)) cache = list;
        logger.info("[telemetriaSnapshot] estados recibidos", {
          recibidos: cache.length,
          intento: intentos,
          sampleKeys: cache.length > 0 ?
            Object.keys(cache[0] as object).slice(0, 20) :
            [],
        });
        break;
      } catch (e) {
        logger.warn("[telemetriaSnapshot] error consultando Volvo", {
          error: (e as Error).message,
          intento: intentos,
        });
        if (intentos >= maxIntentos) {
          logger.error("[telemetriaSnapshot] agotados los reintentos");
          return;
        }
        await new Promise((r) => setTimeout(r, 5000 * intentos));
      }
    }

    if (cache.length === 0) {
      logger.warn("[telemetriaSnapshot] flota Volvo vacía después de los reintentos, abortando");
      return;
    }

    // ─── 2. Map VIN → patente desde Firestore ──────────────────────
    // .limit(5000) defensivo: la flota Vecchi tiene ~127 vehículos
    // (57 tractores + 70 enganches), pero un cap explícito evita
    // sorpresas si en el futuro alguien duplica la colección o un
    // import malformado infla docs. 5000 = 40x growth ceiling.
    const vehiculosSnap = await db.collection("VEHICULOS").limit(5000).get();
    const vinToPatente = new Map<string, string>();
    for (const doc of vehiculosSnap.docs) {
      const data = doc.data();
      const vin = (data.VIN ?? "").toString().trim().toUpperCase();
      if (vin && vin !== "-") {
        vinToPatente.set(vin, doc.id);
      }
    }

    // ─── 3. Fecha del snapshot (midnight ARG) ──────────────────────
    // Buenos Aires es UTC-3 sin DST. Construimos la fecha en TZ ARG
    // para que `fechaTxt` y `fecha` Timestamp sean consistentes con la
    // versión cliente original (que usaba DateTime.now() local).
    const ahora = new Date();
    const fechaTxt = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Argentina/Buenos_Aires",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(ahora); // "2026-04-29"
    const [year, month, day] = fechaTxt.split("-").map(Number);
    const fechaMidnight = new Date(Date.UTC(year, month - 1, day, 3, 0, 0));

    // ─── 4. Batch write a TELEMETRIA_HISTORICO ─────────────────────
    const batch = db.batch();
    let escritos = 0;
    let saltadosVin = 0;
    let saltadosPatente = 0;
    let saltadosCeros = 0;

    for (const v of cache) {
      const vehiculo = v as Record<string, unknown>;
      const vin = (vehiculo.vin ?? "").toString().trim().toUpperCase();
      if (!vin) {
        saltadosVin++;
        continue;
      }
      const patente = vinToPatente.get(vin);
      if (!patente) {
        saltadosPatente++;
        continue;
      }

      // Litros acumulados — el endpoint vehiclestatuses lo expone como
      // `engineTotalFuelUsed` al primer nivel **en MILILITROS**. Para
      // que el campo `litros_acumulados` esté efectivamente en litros
      // (consistente con su nombre y con el reporte de consumo),
      // dividimos por 1000. Mantenemos `accumulatedData.totalFuelConsumption`
      // como fallback por si en algún tipo de unidad viene nested.
      let litrosMl = 0;
      const top = vehiculo.engineTotalFuelUsed;
      if (typeof top === "number") {
        litrosMl = top;
      } else if (top != null) {
        litrosMl = Number(top);
      } else {
        const acc = vehiculo.accumulatedData;
        if (acc && typeof acc === "object") {
          const accObj = acc as Record<string, unknown>;
          const total = accObj.totalFuelConsumption;
          if (typeof total === "number") {
            litrosMl = total;
          } else if (total != null) {
            litrosMl = Number(total);
          }
        }
      }
      if (Number.isNaN(litrosMl)) litrosMl = 0;
      const litros = litrosMl / 1000;

      // Odómetro — Volvo lo entrega en metros.
      const metros = Number(
        vehiculo.hrTotalVehicleDistance ?? vehiculo.lastKnownOdometer ?? 0
      );
      const km = metros / 1000;

      // serviceDistance — km al próximo service programado. Volvo lo
      // entrega en metros y PUEDE SER NEGATIVO (vencido). Lo guardamos
      // como `service_distance_km` para alimentar el dashboard de
      // mantenimiento preventivo.
      //
      // Path oficial según doc Volvo Group Vehicle API v1.0.6:
      //   vehicleStatuses[i].uptimeData.serviceDistance
      // (junto con tellTaleInfo, engineCoolantTemperature).
      // Probamos primero ese path y caemos a legacy si no aparece.
      let serviceMetros: number | null = null;
      const serviceCandidatos: unknown[] = [
        (vehiculo.uptimeData as Record<string, unknown> | undefined)
          ?.serviceDistance,
        vehiculo.serviceDistance,
        (vehiculo.snapshotData as Record<string, unknown> | undefined)
          ?.serviceDistance,
        ((vehiculo.snapshotData as Record<string, unknown> | undefined)
          ?.volvoGroupSnapshot as Record<string, unknown> | undefined)
          ?.serviceDistance,
      ];
      for (const c of serviceCandidatos) {
        if (c == null) continue;
        const n = typeof c === "number" ? c : Number(c);
        if (!Number.isNaN(n)) {
          serviceMetros = n;
          break;
        }
      }
      const serviceKm = serviceMetros != null ? serviceMetros / 1000 : null;

      // Sin telemetría útil no escribimos.
      if (litros === 0 && km === 0 && serviceKm == null) {
        saltadosCeros++;
        continue;
      }

      const docId = `${patente}_${fechaTxt}`;
      // TTL: el campo `expira_en` (fecha + 18 meses) marca cuándo
      // GCP debe borrar este doc automáticamente. La policy se activa
      // por separado con: `gcloud firestore fields ttls update
      // expira_en --collection-group=TELEMETRIA_HISTORICO
      // --enable-ttl --project=coopertrans-movil`. 18 meses cubre
      // reportes anuales y comparativos año-a-año sin acumular
      // indefinidamente (snapshot diario × 127 vehículos × N años).
      const expiraEnMs = fechaMidnight.getTime() + 18 * 30 * 24 * 60 * 60 * 1000;
      const doc: Record<string, unknown> = {
        patente,
        vin,
        fecha: Timestamp.fromDate(fechaMidnight),
        litros_acumulados: litros,
        km,
        timestamp: FieldValue.serverTimestamp(),
        expira_en: Timestamp.fromMillis(expiraEnMs),
      };
      if (serviceKm != null) {
        doc.service_distance_km = serviceKm;
      }
      batch.set(db.collection("TELEMETRIA_HISTORICO").doc(docId), doc);
      escritos++;
    }

    if (escritos === 0) {
      logger.info("[telemetriaSnapshot] sin datos útiles, nada que escribir", {
        recibidos: cache.length,
        saltadosVin,
        saltadosPatente,
        saltadosCeros,
        vinesEnFirestore: vinToPatente.size,
      });
      return;
    }

    await batch.commit();
    logger.info("[telemetriaSnapshot] OK", {
      escritos,
      fechaTxt,
      recibidos: cache.length,
      saltadosVin,
      saltadosPatente,
      saltadosCeros,
    });
  }
);

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

// ============================================================================
// volvoAlertasPoller
// ============================================================================
// Scheduled function que cada 5 minutos pollea la Volvo Vehicle Alerts API
// (`/alert/vehiclealerts`) y persiste cada evento nuevo en la colección
// VOLVO_ALERTAS. Las alertas son eventos discretos del vehículo (IDLING,
// DISTANCE_ALERT, PTO, OVERSPEED, TELL_TALE, ALARM, etc.) — distintos de
// los snapshots de telemetría que captura `telemetriaSnapshotScheduled`.
//
// Diseño:
//   - **Cursor por timestamp del server**: el endpoint devuelve
//     `requestServerDateTime` (UTC del server al recibir el request). Lo
//     persistimos en META/volvo_alertas_cursor y lo usamos como `starttime`
//     del próximo run. Eso garantiza no perder eventos ni duplicar (con
//     `datetype=received` que es el default).
//   - **DocId composite + idempotente**: `{vin}_{createdMs}_{tipo}`. Si
//     el mismo evento se polea dos veces (overlap del cursor, retry, etc),
//     mismo docId → mismo doc, no se duplica.
//   - **Skip de duplicados con getAll batch**: antes de escribir, hacemos
//     1 getAll por página para detectar cuáles docIds ya existen y no
//     pisar campos de gestión (`atendida`, `atendida_por`) seteados por el
//     admin desde la app.
//   - **Paginación**: el spec devuelve `moreDataAvailable` + `moreDataAvailableLink`
//     (relativo, ya con query params preservados). Lo seguimos hasta que
//     `moreDataAvailable=false` o llegamos al safety cap de páginas.
//   - **Cold start**: si no hay cursor (primer run de la function),
//     arrancamos desde "ahora menos 1h". El histórico anterior se ignora
//     en este path; si hace falta backfillear más, se hace por script
//     manual aparte.
//   - **Cross-ref VIN → patente**: el payload trae `customerVehicleName`
//     que en la cuenta de Coopertrans coincide con la patente argentina.
//     Como fallback (si viene vacío o no coincide), buscamos en VEHICULOS
//     por VIN — mismo patrón que `telemetriaSnapshotScheduled`.

const ACCEPT_ALERTS =
  "application/x.volvogroup.com.vehiclealerts.v1.1+json; UTF-8";

// Sub-objetos posibles dentro de un AlertsObject según el spec v1.1.6.
// Los copiamos al campo `detalles` solo si vienen en el payload — la
// mayoría de las alertas tiene exactamente uno (el que corresponde al
// alertType), pero el modelo permite más.
const ALERT_SUBOBJETOS = [
  "generic",
  "tachoOutOfMode",
  "geofence",
  "safetyZone",
  "overspeed",
  "idling",
  "fuelLevel",
  "catalystFuelLevel",
  "pto",
  "cargo",
  "tpm",
  "ttm",
  "das",
  "esp",
  "aebs",
  "harsh",
  "lks",
  "lcs",
  "distanceAlert",
  "unsafeLaneChange",
  "chargingStatusInfo",
  "volvoGroupChargingStatusInfo",
  "batteryPackInfo",
  "chargingConnectionStatusInfo",
  "alarmInfo",
] as const;

// Cap de páginas por run para que un cursor mal seteado no nos haga un
// loop largo. Con cadencia de 5 min y volumen real (~5 eventos/día), una
// sola página alcanza siempre. 20 páginas = hasta 2000 eventos, suficiente
// margen para cualquier escenario realista.
const MAX_PAGES_PER_RUN = 20;

// En cold start, arrancamos desde "ahora - 1h" (no backfilleamos histórico
// completo automáticamente). 1h da margen razonable de overlap si la
// function arranca después de un período de inactividad sin perder los
// eventos recientes.
const COLD_START_LOOKBACK_MS = 60 * 60 * 1000;

interface AlertsApiAlert extends Record<string, unknown> {
  vin?: string;
  alertType?: string;
  severity?: string;
  createdDateTime?: string;
  receivedDateTime?: string;
  customerVehicleName?: string;
  gnssPosition?: Record<string, unknown>;
  driverId?: Record<string, unknown>;
  hrTotalVehicleDistance?: number;
  totalEngineHours?: number;
  totalElectricMotorHours?: number;
}

interface AlertsApiResponse {
  alertsResponse?: {
    alerts?: AlertsApiAlert[];
    moreDataAvailable?: boolean;
    moreDataAvailableLink?: string;
    requestServerDateTime?: string;
  };
}

export const volvoAlertasPoller = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [volvoUsername, volvoPassword],
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async () => {
    logger.info("[volvoAlertasPoller] iniciando ciclo");

    // ─── 1. Cursor: desde dónde poleamos ────────────────────────────
    const cursorRef = db.collection("META").doc("volvo_alertas_cursor");
    const cursorSnap = await cursorRef.get();
    const cursorData = cursorSnap.exists ? cursorSnap.data() ?? {} : {};
    const ultimoServerTs = cursorData.ultimo_request_server_datetime as
      | Timestamp
      | undefined;
    const starttime = ultimoServerTs ?
      ultimoServerTs.toDate().toISOString() :
      new Date(Date.now() - COLD_START_LOOKBACK_MS).toISOString();
    const esColdStart = !ultimoServerTs;

    // ─── 2. Map VIN → patente desde VEHICULOS ───────────────────────
    // Soft-delete: vehiculos dados de baja NO se mapean — sus alertas
    // del API Volvo se descartan en lugar de crearse en VOLVO_ALERTAS.
    const vehiculosSnap = await db.collection("VEHICULOS").get();
    const vinToPatente = new Map<string, string>();
    for (const doc of vehiculosSnap.docs) {
      const data = doc.data();
      if (data.ACTIVO === false) continue;
      const vin = (data.VIN ?? "").toString().trim().toUpperCase();
      if (vin && vin !== "-") {
        vinToPatente.set(vin, doc.id);
      }
    }

    // ─── 3. Auth Volvo ──────────────────────────────────────────────
    const authHeader = "Basic " + Buffer.from(
      `${volvoUsername.value()}:${volvoPassword.value()}`
    ).toString("base64");

    // ─── 4. Loop de paginación ──────────────────────────────────────
    const qsInicial = new URLSearchParams({ starttime });
    let url = `${VOLVO_BASE}/alert/vehiclealerts?${qsInicial.toString()}`;
    let totalRecibidos = 0;
    let totalEscritos = 0;
    let totalDuplicados = 0;
    let totalDescartados = 0;
    let nuevoServerDateTime: string | null = null;
    let pages = 0;

    while (pages < MAX_PAGES_PER_RUN) {
      pages++;

      let res: Response;
      try {
        res = await fetch(url, {
          method: "GET",
          headers: {
            "Authorization": authHeader,
            "Accept": ACCEPT_ALERTS,
          },
        });
      } catch (e) {
        logger.error("[volvoAlertasPoller] fetch falló", {
          page: pages,
          error: (e as Error).message,
        });
        return; // No actualizamos cursor, próximo run reintenta.
      }

      if (!res.ok) {
        logger.warn("[volvoAlertasPoller] Volvo HTTP error", {
          statusCode: res.status,
          page: pages,
        });
        return; // Idem: no avanzamos cursor.
      }

      const body = (await res.json()) as AlertsApiResponse;
      const response = body.alertsResponse ?? {};
      const alerts = Array.isArray(response.alerts) ? response.alerts : [];
      const moreData = response.moreDataAvailable === true;
      const moreLink = response.moreDataAvailableLink;
      const serverTs = response.requestServerDateTime;

      // El requestServerDateTime de la PRIMER página es el que vamos a
      // persistir como cursor. Las páginas siguientes traen el mismo
      // valor o uno levemente distinto, pero usamos siempre la primera
      // para que el cursor refleje el momento del primer fetch.
      if (pages === 1 && serverTs) {
        nuevoServerDateTime = serverTs;
      }

      totalRecibidos += alerts.length;

      if (alerts.length > 0) {
        const writeResult = await persistirAlertas(
          alerts,
          vinToPatente
        );
        totalEscritos += writeResult.escritos;
        totalDuplicados += writeResult.duplicados;
        totalDescartados += writeResult.descartados;
      }

      if (!moreData || !moreLink) break;
      url = `${VOLVO_BASE}${moreLink}`;
    }

    // ─── 5. Persistir cursor ────────────────────────────────────────
    if (nuevoServerDateTime) {
      await cursorRef.set(
        {
          ultimo_request_server_datetime: Timestamp.fromDate(
            new Date(nuevoServerDateTime)
          ),
          ultimo_exito_at: FieldValue.serverTimestamp(),
          ultimo_recibidos: totalRecibidos,
          ultimo_escritos: totalEscritos,
          ultimo_duplicados: totalDuplicados,
          ultimo_descartados: totalDescartados,
          ultimo_paginas: pages,
        },
        { merge: true }
      );
    }

    logger.info("[volvoAlertasPoller] OK", {
      esColdStart,
      paginas: pages,
      recibidos: totalRecibidos,
      escritos: totalEscritos,
      duplicados: totalDuplicados,
      descartados: totalDescartados,
    });
  }
);

interface PersistirResult {
  escritos: number;
  duplicados: number;
  descartados: number;
}

/**
 * Persiste un batch de alertas en VOLVO_ALERTAS de manera idempotente.
 *
 * Estrategia:
 *   1. Construir docId compuesto `{vin}_{createdMs}_{tipo}` para cada
 *      alerta. Las que no tengan los campos required del spec
 *      (vin/alertType/createdDateTime) se descartan.
 *   2. Hacer un único `getAll` para detectar cuáles docIds ya existen
 *      en Firestore. Esos se skipean (no los pisamos para no perder
 *      campos de gestión `atendida`/`atendida_por`/`atendida_en`).
 *   3. Crear los nuevos en una sola batch.
 *
 * Costo: 1 getAll de N reads + 1 batch de M writes (M = alertas nuevas).
 */
async function persistirAlertas(
  alerts: AlertsApiAlert[],
  vinToPatente: Map<string, string>
): Promise<PersistirResult> {
  // 1. Construir docIds, descartar las inválidas
  type Pendiente = { docId: string; alert: AlertsApiAlert };
  const pendientes: Pendiente[] = [];
  let descartados = 0;

  for (const alert of alerts) {
    const vin = (alert.vin ?? "").toString().trim().toUpperCase();
    const tipo = (alert.alertType ?? "").toString();
    const createdRaw = alert.createdDateTime;
    if (!vin || !tipo || !createdRaw) {
      descartados++;
      continue;
    }
    const createdMs = new Date(createdRaw).getTime();
    if (Number.isNaN(createdMs)) {
      descartados++;
      continue;
    }
    pendientes.push({ docId: `${vin}_${createdMs}_${tipo}`, alert });
  }

  if (pendientes.length === 0) {
    return { escritos: 0, duplicados: 0, descartados };
  }

  // 2. getAll para saber cuáles ya existen
  const refs = pendientes.map((p) =>
    db.collection("VOLVO_ALERTAS").doc(p.docId)
  );
  const snaps = await db.getAll(...refs);
  const existing = new Set<string>();
  for (const snap of snaps) {
    if (snap.exists) existing.add(snap.id);
  }

  // 3. Pre-cargar asignaciones para resolver chofer-en-fecha en memoria.
  // Tomamos todas las patentes únicas presentes en los pendientes que NO
  // existían ya (los duplicados los skipeamos abajo igual). Una sola
  // query (en chunks de 30 por límite de Firestore `in`) nos da todo.
  const patentesUnicas = new Set<string>();
  for (let i = 0; i < pendientes.length; i++) {
    if (existing.has(pendientes[i].docId)) continue;
    const vin = (pendientes[i].alert.vin ?? "")
      .toString().trim().toUpperCase();
    const customerName = (pendientes[i].alert.customerVehicleName ?? "")
      .toString().trim();
    const patente = customerName || vinToPatente.get(vin);
    if (patente) patentesUnicas.add(patente);
  }
  const asignacionesPorPatente = await cargarAsignacionesPorPatentes(
    Array.from(patentesUnicas)
  );

  // 4. Batch de creación de los nuevos
  const batch = db.batch();
  let escritos = 0;
  for (let i = 0; i < pendientes.length; i++) {
    const { docId, alert } = pendientes[i];
    if (existing.has(docId)) continue;
    batch.set(
      refs[i],
      buildAlertaDoc(alert, vinToPatente, asignacionesPorPatente)
    );
    escritos++;
  }
  if (escritos > 0) {
    await batch.commit();
  }

  return {
    escritos,
    duplicados: pendientes.length - escritos,
    descartados,
  };
}

interface AsignacionLookup {
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
async function cargarAsignacionesPorPatentes(
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
function buscarAsignacionEnFecha(
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

/**
 * Mapea una alerta del payload de Volvo al doc Firestore
 * (naming castellano + tipos serializables). Si hay [asignacionesPorPatente]
 * disponibles, snapshottea el chofer que estaba manejando esa patente
 * en el momento del evento (de forma que la atribución no cambie si
 * después se reasigna la unidad).
 */
function buildAlertaDoc(
  alert: AlertsApiAlert,
  vinToPatente: Map<string, string>,
  asignacionesPorPatente?: Map<string, AsignacionLookup[]>
): Record<string, unknown> {
  const vin = (alert.vin ?? "").toString().trim().toUpperCase();
  const tipo = (alert.alertType ?? "").toString();
  const severidad = (alert.severity ?? "").toString();
  const creadoMs = new Date(alert.createdDateTime as string).getTime();

  const customerName = (alert.customerVehicleName ?? "").toString().trim();
  const patente = customerName || vinToPatente.get(vin) || null;

  // TTL: `expira_en` (creado_en + 12 meses). Activar policy con:
  //   gcloud firestore fields ttls update expira_en \
  //     --collection-group=VOLVO_ALERTAS --enable-ttl \
  //     --project=coopertrans-movil
  // Las alertas son útiles para investigar incidentes recientes pero
  // no para histórico anual; 12 meses cubre auditorías y disputas
  // típicas con clientes/aseguradoras sin acumular sin tope.
  const expiraEnMs = creadoMs + 12 * 30 * 24 * 60 * 60 * 1000;
  const doc: Record<string, unknown> = {
    vin,
    tipo,
    severidad,
    creado_en: Timestamp.fromMillis(creadoMs),
    polled_en: FieldValue.serverTimestamp(),
    expira_en: Timestamp.fromMillis(expiraEnMs),
    // Estado de gestión inicial. El admin lo flippa a `true` desde el
    // tablero al marcarla atendida (junto con `atendida_por` y
    // `atendida_en`). El poller solo escribe `false` en la creación
    // inicial — re-polls del mismo evento se skipean por `getAll`.
    atendida: false,
  };
  if (patente) {
    doc.patente = patente;
    // Snapshot del chofer en ese instante: usamos el log temporal
    // ASIGNACIONES_VEHICULO (no `EMPLEADOS.VEHICULO` "actual"), porque
    // si la patente rota después, la atribución del evento no debería
    // cambiar. Si no hay log para ese momento (típico en eventos de
    // antes del go-live del sistema), lo dejamos vacío — la pantalla
    // cae a "chofer asignado actual" como antes.
    const asignacion = buscarAsignacionEnFecha(
      asignacionesPorPatente?.get(patente),
      creadoMs
    );
    if (asignacion && asignacion.chofer_dni) {
      doc.chofer_dni = asignacion.chofer_dni;
      if (asignacion.chofer_nombre) {
        doc.chofer_nombre = asignacion.chofer_nombre;
      }
    }
  }

  if (alert.receivedDateTime) {
    const recibidoMs = new Date(alert.receivedDateTime).getTime();
    if (!Number.isNaN(recibidoMs)) {
      doc.recibido_en = Timestamp.fromMillis(recibidoMs);
    }
  }

  // GPS: el spec marca `latitude`/`longitude`/`positionDateTime` como
  // required dentro de gnssPosition. Si vino el sub-objeto, lo mapeamos.
  const gps = alert.gnssPosition;
  if (gps && typeof gps === "object") {
    const posicion: Record<string, unknown> = {};
    if (gps.latitude != null) posicion.lat = Number(gps.latitude);
    if (gps.longitude != null) posicion.lng = Number(gps.longitude);
    if (gps.heading != null) posicion.heading = Number(gps.heading);
    if (gps.altitude != null) posicion.altitud = Number(gps.altitude);
    if (gps.speed != null) posicion.velocidad = Number(gps.speed);
    if (gps.positionDateTime) {
      const posMs = new Date(gps.positionDateTime as string).getTime();
      if (!Number.isNaN(posMs)) posicion.timestamp = Timestamp.fromMillis(posMs);
    }
    if (Object.keys(posicion).length > 0) {
      doc.posicion_gps = posicion;
    }
  }

  // Sub-objetos del payload: copiamos el que venga (suele ser uno solo,
  // el correspondiente al alertType). Los renombramos con prefijo
  // `detalle_` para que sean obvios en consultas y no choquen con
  // campos top-level.
  for (const subKey of ALERT_SUBOBJETOS) {
    const sub = alert[subKey];
    if (sub != null) {
      doc[`detalle_${subKey}`] = sub;
    }
  }

  // Datos opcionales del vehículo en el momento del evento.
  if (alert.hrTotalVehicleDistance != null) {
    const metros = Number(alert.hrTotalVehicleDistance);
    if (!Number.isNaN(metros)) doc.distancia_total_metros = metros;
  }
  if (alert.totalEngineHours != null) {
    const horas = Number(alert.totalEngineHours);
    if (!Number.isNaN(horas)) doc.horas_motor = horas;
  }
  if (alert.totalElectricMotorHours != null) {
    const horas = Number(alert.totalElectricMotorHours);
    if (!Number.isNaN(horas)) doc.horas_motor_electrico = horas;
  }

  // Driver ID si vino. Lo guardamos crudo — la app decide qué mostrar
  // según `tachoDriverIdentification` o `oemDriverIdentification`.
  if (alert.driverId && typeof alert.driverId === "object") {
    doc.driver_id = alert.driverId;
  }

  return doc;
}

// ============================================================================
// onAlertaVolvoCreated — notificación al chofer cuando hay alerta HIGH
// ============================================================================
// Trigger Firestore que se dispara cuando `volvoAlertasPoller` escribe un
// doc nuevo en `VOLVO_ALERTAS`. Si la severidad es HIGH:
//   1. Buscamos qué chofer tiene asignada esa patente (EMPLEADOS.VEHICULO).
//   2. Si tiene TELEFONO cargado, encolamos un mensaje en COLA_WHATSAPP.
//   3. El bot Node.js (NSSM) procesa la cola respetando horarios laborales
//      (8-19 lunes a viernes, sin feriados): si la alerta es a las 23:00,
//      el doc queda PENDIENTE hasta las 8:00 del siguiente día hábil.
//
// Idempotencia: el trigger `onCreate` se dispara UNA SOLA VEZ por docId.
// Como el docId composite es `{vin}_{createdMs}_{tipo}` y el poller skipea
// duplicados con getAll, el mismo evento NO genera dos triggers.
//
// Casos donde se hace skip silencioso (log, no se manda mensaje):
//   - Severidad MEDIUM o LOW (solo HIGH gatilla notificación al instante).
//   - Patente sin chofer asignado (tractor en taller / sin uso).
//   - Chofer sin TELEFONO o con TELEFONO vacío ("-", "").
//
// Si el chofer no aparece, la alerta sigue visible en el tablero "Alertas"
// del admin y entra al resumen diario que se envía a Santiago.

const ETIQUETAS_TIPO_ALERTA: Record<string, string> = {
  DISTANCE_ALERT: "Cerca del vehículo de adelante",
  IDLING: "Motor en ralentí prolongado",
  OVERSPEED: "Exceso de velocidad",
  PTO: "Toma de fuerza activada",
  HARSH: "Aceleración / frenada brusca",
  GENERIC: "Evento genérico",
  TELL_TALE: "Luz de tablero encendida",
  FUEL: "Cambio anormal de combustible",
  CATALYST: "Cambio de nivel AdBlue",
  ALARM: "Alarma anti-robo",
  GEOFENCE: "Entrada/salida de geocerca",
  SAFETY_ZONE: "Zona de velocidad reducida",
  TPM: "Presión de neumático",
  TTM: "Temperatura de neumático",
  AEBS: "Frenado automático de emergencia",
  ESP: "Control de estabilidad",
  DAS: "Alerta de cansancio",
  LKS: "Asistente de carril",
  LCS: "Asistente de cambio de carril",
  UNSAFE_LANE_CHANGE: "Cambio de carril inseguro",
  TACHO_OUT_OF_SCOPE_MODE_CHANGE: "Tacógrafo fuera de servicio",
  CARGO: "Cambio en carga (puerta / temp)",
  ADBLUELEVEL_LOW: "AdBlue bajo",
  WITHOUT_ADBLUE: "Sin AdBlue",
  DRIVING_WITHOUT_BEING_LOGGED_IN: "Conducción sin chofer identificado",
  SEATBELT: "Cinturón de seguridad sin abrochar",
  BATTERY_PACK_HIGH_DISCHARGE: "Descarga alta de batería",
  BATTERY_PACK_CHARGING_STATUS_CHANGE: "Cambio en estado de carga",
};

export const onAlertaVolvoCreated = onDocumentCreated(
  {
    document: "VOLVO_ALERTAS/{alertId}",
    timeoutSeconds: 30,
    memory: "256MiB",
  },
  async (event) => {
    const snap = event.data;
    if (!snap) {
      logger.warn("[onAlertaVolvoCreated] event.data vacío, skip");
      return;
    }

    const data = snap.data() ?? {};
    const severidad = (data.severidad ?? "").toString().toUpperCase();
    if (severidad !== "HIGH") {
      // MEDIUM/LOW no notifican al instante — quedan en el tablero del
      // admin y entran al resumen diario.
      return;
    }

    const patenteRaw = (data.patente ?? "").toString().trim();
    const patente = patenteRaw.toUpperCase();
    const tipo = (data.tipo ?? "").toString();
    if (!patente) {
      logger.info("[onAlertaVolvoCreated] HIGH sin patente, skip", {
        alertId: event.params.alertId,
        tipo,
      });
      return;
    }

    // ─── Filtro de tipos "no para el chofer" ───────────────────────
    // Tipos / subtipos que el chofer NO puede arreglar en ruta. Van
    // solo al jefe de mantenimiento via el cron diario consolidado del
    // bot. Si los mandamos también al chofer, le spameamos sin que
    // pueda hacer nada — caso real (incidente 2026-05-07): Raul
    // recibió 6 mensajes de "Sin AdBlue" en 6 horas porque el camión
    // sigue sin AdBlue y Volvo dispara el evento cada hora.
    //
    // AdBlue (3 tipos) — operación de planta, el chofer no carga
    // AdBlue en ruta. Va al jefe de mantenimiento via cron diario.
    //   - WITHOUT_ADBLUE     ("Sin AdBlue")
    //   - ADBLUELEVEL_LOW    ("AdBlue bajo")
    //   - CATALYST           ("Cambio de nivel AdBlue")
    //
    // Otros del filtro original (legacy 2026-05-03):
    //   - TELL_TALE: testigo del tablero — un sensor intermitente
    //     puede tirar 10-15 eventos por día.
    //   - DRIVING_WITHOUT_BEING_LOGGED_IN: chofer sin loguearse al
    //     TACHÓGRAFO. Vecchi NO enforcea identificación por tacógrafo
    //     porque usa el iButton de Sitrack para identificar al chofer.
    //     El equivalente "no se identificó por iButton" se notifica
    //     desde sitrackPosicionPoller cuando detecta drift_tipo
    //     CHOFER_NO_IDENTIFICADO — usa otra fuente de datos.
    //
    // FUEL ("Cambio anormal de combustible") tampoco llega al chofer:
    // por experiencia operativa de Vecchi, los disparos son ruidosos
    // y el chofer no puede investigar (lo ve el admin en el resumen).
    const TIPOS_BLACKLIST_CHOFER = new Set([
      "WITHOUT_ADBLUE",
      "ADBLUELEVEL_LOW",
      "CATALYST",
      "FUEL",
      "TELL_TALE",
      "DRIVING_WITHOUT_BEING_LOGGED_IN",
    ]);

    // Resolver el "tipo efectivo" para los GENERIC con subtipo.
    let tipoEfectivo = tipo.toUpperCase();
    if (tipo === "GENERIC") {
      const triggerType = (
        (data.detalle_generic as Record<string, unknown> | undefined)
          ?.triggerType ?? ""
      ).toString().toUpperCase();
      if (triggerType) tipoEfectivo = triggerType;
    }

    if (TIPOS_BLACKLIST_CHOFER.has(tipoEfectivo)) {
      logger.info(
        "[onAlertaVolvoCreated] tipo blacklist al chofer, skip (sigue en tablero + resumen mant)",
        {
          alertId: event.params.alertId,
          patente,
          tipoEfectivo,
        }
      );
      return;
    }

    // Lookup chofer: priorizamos el `chofer_dni` snapshoteado por
    // `volvoAlertasPoller` al crear la alerta (atribución del chofer del
    // MOMENTO del evento, no el chofer actual asignado). Esto es crítico
    // si el chofer rotó entre la creación de la alerta y este trigger
    // (raro pero posible si el trigger se demora por backlog/quotas).
    //
    // Fallback al lookup por VEHICULO==patente para:
    //  - Alertas viejas pre-snapshot (compatibilidad con docs legacy).
    //  - Caso defensivo si por algún motivo `chofer_dni` quedó vacío.
    //
    // Side benefit: `.doc(id).get()` es lookup por clave (lectura O(1) en
    // Firestore) vs `.where().limit(1)` que igual va a la collection y
    // matchea — la query por ID es más barata.
    const choferDniSnapshot = (data.chofer_dni ?? "").toString().trim();
    let choferDoc;
    if (choferDniSnapshot) {
      const docSnap = await db.collection("EMPLEADOS").doc(choferDniSnapshot).get();
      if (docSnap.exists) {
        choferDoc = docSnap;
      }
    }
    if (!choferDoc) {
      const empleadosSnap = await db
        .collection("EMPLEADOS")
        .where("VEHICULO", "==", patente)
        .limit(1)
        .get();
      if (empleadosSnap.empty) {
        logger.info("[onAlertaVolvoCreated] patente sin chofer asignado", {
          patente,
          tipo,
          intentadoDni: choferDniSnapshot || "(sin snapshot)",
        });
        return;
      }
      choferDoc = empleadosSnap.docs[0];
    }
    const choferData = choferDoc.data() ?? {};

    // Soft-delete: si el chofer fue dado de baja, no le mandamos.
    if (choferData.ACTIVO === false) {
      logger.info("[onAlertaVolvoCreated] chofer inactivo, skip", {
        patente,
        choferDni: choferDoc.id,
      });
      return;
    }

    const telefonoRaw = (choferData.TELEFONO ?? "").toString().trim();
    if (!telefonoRaw || telefonoRaw === "-") {
      logger.info("[onAlertaVolvoCreated] chofer sin TELEFONO", {
        patente,
        choferDni: choferDoc.id,
      });
      return;
    }

    const apodo = (choferData.APODO ?? "").toString().trim();
    const nombreFull = (choferData.NOMBRE ?? "").toString().trim();
    const saludoNombre = apodo || _primerNombre(nombreFull) || "";

    const creadoMs =
      (data.creado_en as Timestamp | undefined)?.toMillis() ?? Date.now();
    const horaTxt = _formatHoraArg(creadoMs);
    // Fecha explícita DD/MM en lugar de "hoy a las". El bot tiene horario
    // hábil L-V 8-20 y skip fin de semana — un evento del sábado se manda
    // el lunes y "hoy" sería mentira. Con la fecha explícita el chofer
    // siempre sabe a qué momento se refiere el aviso.
    const fechaTxt = _formatFechaArg(creadoMs);

    // Nota: NO hay dedup diaria a este nivel — los eventos de manejo
    // (OVERSPEED, IDLING, HARSH, PTO, SEATBELT, etc.) son el insumo
    // principal del seguimiento del chofer. Cada uno se encola y el
    // bot Node.js los AGRUPA al enviarlos (ver `agrupador.js`): si el
    // chofer ya tiene varios PENDIENTES, los combina en un único
    // mensaje "se detectaron N eventos: 5x Exceso, 3x Ralentí...".
    // Eso resuelve el spam sin perder información.
    //
    // Los tipos repetitivos de mantenimiento (Sin AdBlue cada hora,
    // testigo de tablero parpadeante, etc.) NO llegan al chofer
    // gracias a `TIPOS_BLACKLIST_CHOFER` arriba.

    let etiqueta = ETIQUETAS_TIPO_ALERTA[tipo] ?? tipo;
    // subTipoResolvido se guarda en COLA_WHATSAPP como `alert_sub_tipo`
    // para que el agrupador del bot (agrupador.js) pueda mostrar la
    // etiqueta correcta cuando combina varios HIGH del mismo chofer
    // (ej: 3x "Cinturón..." en lugar de 3x "Evento genérico").
    let subTipoResolvido: string | null = null;
    if (tipo === "GENERIC") {
      const triggerType = (
        (data.detalle_generic as Record<string, unknown> | undefined)
          ?.triggerType ?? ""
      ).toString().toUpperCase();
      if (triggerType) {
        subTipoResolvido = triggerType;
        etiqueta =
          ETIQUETAS_TIPO_ALERTA[triggerType] ??
          `Evento genérico (${triggerType})`;
      }
    }

    // Variantes random del mensaje — anti-baneo de WhatsApp. Mandar el
    // MISMO texto a múltiples destinatarios en poco tiempo es señal
    // típica de spam y dispara bandera. Cuanto más variantes, menos
    // probable que dos mensajes consecutivos sean iguales. Pasamos de
    // 3 a 8 redacciones con mismo contenido informativo.
    const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";
    const variantes = [
      `${saludo},\n\n` +
        `Se detectó un evento de manejo en el TRACTOR ${patente} ` +
        `el ${fechaTxt} a las ${horaTxt}:\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Te pedimos ajustar tu manejo. Si hubo una situación particular, " +
        "avisanos a la oficina.\n\n" +
        BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
      `${saludo}.\n\n` +
        `Aviso desde la oficina: el ${fechaTxt} a las ${horaTxt} se ` +
        `registró un evento en el tractor ${patente}.\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Si hubo algo particular contanos en la oficina; si no, te " +
        "pedimos prestar atención al manejo.\n\n" +
        BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
      `${saludo}, te escribo desde la oficina.\n\n` +
        `Volvo registró un evento en el tractor ${patente} ` +
        `el ${fechaTxt} a las ${horaTxt}:\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Cualquier comentario sobre la situación, mejor en la oficina.\n\n" +
        BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
      `${saludo}, ¿cómo va el día?\n\n` +
        `Recibimos un aviso del tractor ${patente} ` +
        `(${fechaTxt} a las ${horaTxt}):\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Si pasó algo puntual contanos. Si no, prestá atención al " +
        "próximo tramo.\n\n" +
        BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
      `${saludo}.\n\n` +
        `Te avisamos: el tractor ${patente} disparó un evento ` +
        `el ${fechaTxt} ${horaTxt}.\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Acordate de revisar tu manejo. Cualquier cosa nos contás " +
        "en la oficina.\n\n" +
        BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
      `${saludo},\n\n` +
        `Llegó un alerta del tractor ${patente} ` +
        `(${fechaTxt}, ${horaTxt}):\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Te pedimos un manejo más cuidadoso en lo que sigue. Si hubo " +
        "una situación particular, escribinos.\n\n" +
        BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
      `${saludo}.\n\n` +
        `Saltó un evento en el TRACTOR ${patente} hoy ` +
        `${horaTxt} (${fechaTxt}):\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Si fue una maniobra obligada por el tránsito, dejame saber. " +
        "Si no, ajustá tu manejo en lo que viene.\n\n" +
        BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
      `${saludo}, te paso un aviso desde la oficina.\n\n` +
        `Detectamos un evento en el tractor ${patente} ` +
        `el ${fechaTxt} a las ${horaTxt}:\n\n` +
        `⚠️ ${etiqueta}\n\n` +
        "Te pedimos ir más tranquilo. Cualquier comentario lo charlamos.\n\n" +
        BANNER_TESTING + "_Coopertrans Móvil — Mensaje automático._",
    ];
    const mensaje = variantes[_rrPick(variantes.length)];

    try {
      const colaRef = await db.collection("COLA_WHATSAPP").add({
        telefono: telefonoRaw,
        mensaje,
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
        expira_en: _expiraEnMinutos(TTL_VOLVO_MANEJO_MIN),
        enviado_en: null,
        error: null,
        intentos: 0,
        origen: "volvo_alert_high",
        destinatario_coleccion: "EMPLEADOS",
        destinatario_id: choferDoc.id,
        campo_base: "VOLVO_ALERT_HIGH",
        admin_dni: "BOT",
        admin_nombre: "Bot automatico",
        // Metadata para auditoria / debugging.
        alert_id: event.params.alertId,
        alert_tipo: tipo,
        // Subtipo resuelto cuando tipo === GENERIC (SEATBELT, TELL_TALE,
        // etc). Lo usa el agrupador del bot para no colapsar todos los
        // GENERIC en "Evento genérico" cuando agrupa varios eventos.
        alert_sub_tipo: subTipoResolvido,
        alert_patente: patente,
        // Timestamp del evento real (no del encolado) — usado por el
        // agrupador del bot para armar el mensaje combinado con horas
        // correctas si el chofer recibe varios eventos juntos.
        alert_creado_en: Timestamp.fromMillis(creadoMs),
      });
      logger.info("[onAlertaVolvoCreated] OK encolado para chofer", {
        alertId: event.params.alertId,
        patente,
        tipo,
        choferDni: choferDoc.id,
        colaDocId: colaRef.id,
      });
    } catch (e) {
      logger.error("[onAlertaVolvoCreated] no se pudo encolar", {
        alertId: event.params.alertId,
        patente,
        error: (e as Error).message,
      });
      // No re-throw: el trigger no debe reintentar agresivamente.
      // Si el encolado falla, queda registro en el log y la alerta
      // sigue visible en el tablero del admin.
    }
  }
);

/**
 * Round-robin determinístico para elegir variantes anti-baneo.
 *
 * Antes usábamos Math.random() — en ráfagas (vigilador detecta varios
 * choferes excediendo en el mismo poll, alertas Volvo en paralelo)
 * había chance ~1/N de que dos mensajes consecutivos tocaran la
 * misma variante, patrón de spam para WhatsApp. Round-robin garantiza
 * que las primeras N llamadas tocan las N variantes distintas, sin
 * repetición predecible.
 *
 * Counter persiste en memoria del Cloud Function — Cloud Run mantiene
 * la instancia caliente entre invocaciones cercanas, así que en
 * ráfagas el counter avanza aunque sean llamadas separadas. Si la
 * instancia se enfría y arranca otra fría, vuelve a 0 — eso es OK,
 * lo importante es la diversidad dentro de la ráfaga.
 */
let _rrCounter = 0;
function _rrPick(len: number): number {
  if (len <= 0) return 0;
  const idx = _rrCounter % len;
  _rrCounter = (_rrCounter + 1) | 0; // wrap a int32 para no inflar
  return idx;
}

/**
 * Devuelve el segundo token capitalizado de un nombre tipo
 * "APELLIDO NOMBRE …", o "" si no se puede determinar.
 * Espejo del helper que usa el panel admin del cliente.
 */
function _primerNombre(full: string): string {
  const partes = full.trim().split(/\s+/);
  if (partes.length < 2) return "";
  const n = partes[1];
  if (!n) return "";
  return n[0].toUpperCase() + n.slice(1).toLowerCase();
}

/**
 * Formatea HH:MM en TZ Argentina a partir de millis UTC. Independiente
 * de la TZ del runtime (Cloud Functions corre en UTC).
 */
function _formatHoraArg(millis: number): string {
  const fmt = new Intl.DateTimeFormat("es-AR", {
    timeZone: "America/Argentina/Buenos_Aires",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  return fmt.format(new Date(millis));
}

/**
 * Formatea DD/MM en TZ Argentina a partir de millis UTC. Usado en los
 * mensajes al chofer para que la fecha del evento sea explícita
 * (no "hoy" — el bot puede demorar el envío al lunes si el evento ocurrió
 * el fin de semana).
 */
function _formatFechaArg(millis: number): string {
  const fmt = new Intl.DateTimeFormat("es-AR", {
    timeZone: "America/Argentina/Buenos_Aires",
    day: "2-digit",
    month: "2-digit",
  });
  return fmt.format(new Date(millis));
}

// ============================================================================
// volvoScoresPoller — eco-driving (Volvo Group Scores API v2.0.2)
// ============================================================================
// Scheduled function que cada día a las 04:00 ART pollea la Volvo Group
// Scores API (`/score/scores`) con `starttime=ayer&stoptime=ayer` y persiste
// el score AGREGADO POR DÍA de cada vehículo + el de la flota.
//
// A diferencia de `volvoAlertasPoller` (eventos discretos en tiempo real),
// la Scores API devuelve un AGREGADO DIARIO precalculado por Volvo:
//   - 1 score "total" 0-100 por vehículo o flota.
//   - 17+ sub-scores (anticipation, braking, coasting, idling, overspeed,
//     cruiseControl, etc.) — el algoritmo es propietario de Volvo.
//   - Métricas operativas crudas (totalDistance, avgFuelConsumption,
//     totalTime, vehicleUtilization, co2Emissions).
//
// Por qué a las 04:00 ART:
//   La API espera que el día calendario haya cerrado y los datos hayan
//   llegado a la nube de Volvo. 04:00 da margen para que telemetría
//   rezagada del día anterior ya esté procesada del lado de Volvo.
//
// Idempotencia:
//   - DocId composite `{patente}_{YYYY-MM-DD}` para vehículos y
//     `_FLEET_{YYYY-MM-DD}` para el agregado de flota.
//   - Si la function corre dos veces el mismo día (retry, manual run),
//     mismo docId → sobrescribe. Sin campos de gestión humana acá, es
//     seguro sobrescribir.

const ACCEPT_SCORES =
  "application/x.volvogroup.com.scores.v2.0+json; UTF-8";

interface ScoresApiVehicleScore extends Record<string, unknown> {
  vin: string;
  scores?: Record<string, number>;
  totalTime?: number;
  avgSpeedDriving?: number;
  totalDistance?: number;
  avgFuelConsumption?: number;
  avgFuelConsumptionGaseous?: number;
  avgElectricEnergyConsumption?: number;
  vehicleUtilization?: number;
  co2Emissions?: number;
  co2Saved?: number;
}

interface ScoresApiFleetScore extends Record<string, unknown> {
  scores?: Record<string, number>;
  totalTime?: number;
  avgSpeedDriving?: number;
  totalDistance?: number;
  avgFuelConsumption?: number;
  avgFuelConsumptionGaseous?: number;
  avgElectricEnergyConsumption?: number;
  vehicleUtilization?: number;
  co2Emissions?: number;
  co2Saved?: number;
}

interface ScoresApiResponse {
  vuScoreResponse?: {
    startTime?: string;
    stopTime?: string;
    fleet?: ScoresApiFleetScore;
    vehicles?: ScoresApiVehicleScore[];
    moreDataAvailable?: boolean;
    moreDataAvailableLink?: string;
  };
}

const SCORES_MAX_PAGES_PER_RUN = 10;

export const volvoScoresPoller = onSchedule(
  {
    schedule: "0 4 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [volvoUsername, volvoPassword],
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async () => {
    // Calculamos "ayer" en ART. La API espera fechas YYYY-MM-DD en TZ
    // de la flota. Ejemplo: corre el 2026-05-03 04:00 ART → pedimos
    // los scores del día 2026-05-02 (cerrado).
    const fechaYmd = _ayerYmdArg();

    logger.info("[volvoScoresPoller] iniciando ciclo", { fecha: fechaYmd });

    // Cross-ref VIN → patente. Mismo patrón que volvoAlertasPoller.
    // .limit(5000) defensivo — ver comentario en telemetriaSnapshotScheduled.
    const vehiculosSnap = await db.collection("VEHICULOS").limit(5000).get();
    const vinToPatente = new Map<string, string>();
    for (const doc of vehiculosSnap.docs) {
      const data = doc.data();
      const vin = (data.VIN ?? "").toString().trim().toUpperCase();
      if (vin && vin !== "-") {
        vinToPatente.set(vin, doc.id);
      }
    }

    const authHeader = "Basic " + Buffer.from(
      `${volvoUsername.value()}:${volvoPassword.value()}`
    ).toString("base64");

    const qsInicial = new URLSearchParams({
      starttime: fechaYmd,
      stoptime: fechaYmd,
      contentFilter: "FLEET,VEHICLES",
    });
    let url = `${VOLVO_BASE}/score/scores?${qsInicial.toString()}`;

    const fechaTs = Timestamp.fromDate(_inicioDelDiaArg(fechaYmd));
    let totalEscritos = 0;
    let pages = 0;
    let fleetEscrita = false;

    while (pages < SCORES_MAX_PAGES_PER_RUN) {
      pages++;

      let res: Response;
      try {
        res = await fetch(url, {
          method: "GET",
          headers: { Authorization: authHeader, Accept: ACCEPT_SCORES },
        });
      } catch (e) {
        logger.error("[volvoScoresPoller] fetch falló", {
          page: pages,
          error: (e as Error).message,
        });
        return;
      }

      if (!res.ok) {
        logger.warn("[volvoScoresPoller] Volvo HTTP error", {
          statusCode: res.status,
          page: pages,
        });
        return;
      }

      const body = (await res.json()) as ScoresApiResponse;
      const response = body.vuScoreResponse ?? {};

      // Persistir el score de la FLOTA (solo en la primera página, no
      // se repite en páginas siguientes según el spec).
      if (!fleetEscrita && response.fleet) {
        await db
          .collection("VOLVO_SCORES_DIARIOS")
          .doc(`_FLEET_${fechaYmd}`)
          .set(
            {
              ...buildScoreFleetDoc(response.fleet, fechaYmd, fechaTs),
              polled_en: FieldValue.serverTimestamp(),
            },
            { merge: true }
          );
        fleetEscrita = true;
        totalEscritos++;
      }

      // Persistir scores por vehículo en batch.
      const vehicles = Array.isArray(response.vehicles) ? response.vehicles : [];
      if (vehicles.length > 0) {
        const batch = db.batch();
        let escritosEstePage = 0;
        for (const v of vehicles) {
          const vin = (v.vin ?? "").toString().trim().toUpperCase();
          if (!vin) continue;
          const patente = vinToPatente.get(vin) || vin;
          const docId = `${patente}_${fechaYmd}`;
          const ref = db.collection("VOLVO_SCORES_DIARIOS").doc(docId);
          batch.set(
            ref,
            {
              ...buildScoreVehicleDoc(v, patente, fechaYmd, fechaTs),
              polled_en: FieldValue.serverTimestamp(),
            },
            { merge: true }
          );
          escritosEstePage++;
        }
        if (escritosEstePage > 0) {
          await batch.commit();
          totalEscritos += escritosEstePage;
        }
      }

      const moreData = response.moreDataAvailable === true;
      const moreLink = response.moreDataAvailableLink;
      if (!moreData || !moreLink) break;
      url = `${VOLVO_BASE}${moreLink}`;
    }

    logger.info("[volvoScoresPoller] OK", {
      fecha: fechaYmd,
      paginas: pages,
      escritos: totalEscritos,
      fleetEscrita,
    });
  }
);

/**
 * Devuelve la fecha "ayer" en TZ Argentina como YYYY-MM-DD.
 * Independiente del runtime (Cloud Functions corre en UTC).
 */
function _ayerYmdArg(): string {
  const ahora = new Date();
  const ymdHoy = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(ahora);
  // Construimos hoy ART y restamos 1 día.
  const hoyArg = new Date(`${ymdHoy}T00:00:00-03:00`);
  const ayer = new Date(hoyArg.getTime() - 24 * 60 * 60 * 1000);
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(ayer);
}

function _inicioDelDiaArg(ymd: string): Date {
  return new Date(`${ymd}T00:00:00-03:00`);
}

function buildScoreVehicleDoc(
  v: ScoresApiVehicleScore,
  patente: string,
  fechaYmd: string,
  fechaTs: Timestamp
): Record<string, unknown> {
  return {
    vin: (v.vin ?? "").toString().trim().toUpperCase(),
    patente,
    fecha: fechaYmd,
    fecha_ts: fechaTs,
    scores: v.scores ?? {},
    totalTime: v.totalTime ?? null,
    avgSpeedDriving: v.avgSpeedDriving ?? null,
    totalDistance: v.totalDistance ?? null,
    avgFuelConsumption: v.avgFuelConsumption ?? null,
    avgFuelConsumptionGaseous: v.avgFuelConsumptionGaseous ?? null,
    avgElectricEnergyConsumption: v.avgElectricEnergyConsumption ?? null,
    vehicleUtilization: v.vehicleUtilization ?? null,
    co2Emissions: v.co2Emissions ?? null,
    co2Saved: v.co2Saved ?? null,
  };
}

function buildScoreFleetDoc(
  f: ScoresApiFleetScore,
  fechaYmd: string,
  fechaTs: Timestamp
): Record<string, unknown> {
  return {
    es_fleet: true,
    fecha: fechaYmd,
    fecha_ts: fechaTs,
    scores: f.scores ?? {},
    totalTime: f.totalTime ?? null,
    avgSpeedDriving: f.avgSpeedDriving ?? null,
    totalDistance: f.totalDistance ?? null,
    avgFuelConsumption: f.avgFuelConsumption ?? null,
    avgFuelConsumptionGaseous: f.avgFuelConsumptionGaseous ?? null,
    avgElectricEnergyConsumption: f.avgElectricEnergyConsumption ?? null,
    vehicleUtilization: f.vehicleUtilization ?? null,
    co2Emissions: f.co2Emissions ?? null,
    co2Saved: f.co2Saved ?? null,
  };
}

// ============================================================================
// onAlertaVolvoMantenimientoCreated — alerta de mantenimiento al jefe
// ============================================================================
// Trigger Firestore distinto y complementario a `onAlertaVolvoCreated`
// (que notifica al CHOFER cuando hay HIGH severity de manejo). Este
// notifica al JEFE DE MANTENIMIENTO cuando aparece una alerta que
// indica problema mecánico/operativo del vehículo (independiente de
// severity).
//
// Tipos cubiertos:
//   - FUEL    → cambio anormal de combustible (posible robo, fuga,
//               medidor mal calibrado).
//   - CATALYST → problema con sistema SCR / filtro AdBlue.
//   - GENERIC con sub-tipo:
//       * TELL_TALE        → testigo del tablero encendido (check
//                            engine, presión aceite, etc).
//       * ADBLUELEVEL_LOW  → AdBlue por debajo del umbral.
//       * WITHOUT_ADBLUE   → sin AdBlue (riesgo de derate).
//
// Filtramos a tipos que indican "el camión te está avisando algo" antes
// que el chofer llame del medio de la ruta. La idea: pasar de modo
// reactivo (apagar incendios) a modo predictivo (turno de taller listo).
//
// Destinatario: hardcoded al DNI 35244439 (Santiago, jefe de
// mantenimiento Vecchi 2026). Si Vecchi suma a otra persona en el
// futuro, refactorizar a una colección META o env var.
//
// Bot: encolado en COLA_WHATSAPP — respeta el horario hábil del bot
// (8-19 lunes a viernes, sin feriados). Una alerta del sábado 23:00
// se entrega el lunes 8:00 AM. Para mantenimiento NO crítico esto está
// bien (el chofer ya llamó si era urgente). El sistema es predictivo.
//
// Idempotencia: trigger `onCreate` se dispara una sola vez por docId.
// El docId composite del poller (`{vin}_{createdMs}_{tipo}`) garantiza
// que mismo evento Volvo no genera dos triggers.
//
// Sin dedupe por tipo+patente en este v1: con ~7 eventos de
// mantenimiento en 13 días reales (TELL_TALE + FUEL + CATALYST), el
// volumen es muy bajo para preocuparse por spam. Si se materializa
// (ej: testigo intermitente que dispara 50 veces por hora), agregar
// dedupe simple por (alert_tipo, alert_patente) en últimas N horas.

const MANTENIMIENTO_DESTINATARIO_DNI = "35244439";

// DNI del jefe de Seguridad e Higiene (MOLINA ALEJANDRA). Recibe el
// resumen diario de excesos de jornada (choferes que cruzaron 4h
// continuas o 12h diarias).
const SEG_HIGIENE_DESTINATARIO_DNI = "34730329";

// Vigilador de jornada del chofer — parámetros operativos.
// Decisión Vecchi 2026-05-07 (umbral revisado 2026-05-08):
//   - El chofer se considera "manejando" cuando speed > 15 km/h.
//     Antes era 10; subido a 15 porque GPS drift de un camión parado
//     puede reportar 11-14 km/h falsos en SITRACK, sumando tiempo
//     erróneo. 15 km/h descarta el drift sin perder casos reales —
//     un camión en ruta nunca va a < 20 km/h salvo en peajes y
//     entradas a acopios (que se cuentan como pausa, no como manejo).
//   - 10 min sin movimiento resetean el "continuo" (pausa válida
//     INTERNA — al chofer se le piden 15 min en los avisos, los 5
//     extra son margen para el delay GPS).
//   - Aviso a las 3:45h continuas (faltan 15 min para el límite 4h).
//   - Aviso a las 11:30h totales del día (faltan 30 min para 12h).
const VIGILADOR_UMBRAL_MOVIMIENTO_KMH = 15;
// Si el último poll de SITRACK_POSICIONES es más viejo que esto,
// no sumamos tiempo a la jornada — el dato `speed` puede estar
// stale (camión apagado, sin señal, poll caído). Sin esto, un
// chofer que paró a las 23:30 con speed=80 en su último poll
// sigue acumulando "horas manejando" hasta que vuelve a haber
// señal. Decisión 2026-05-08.
const VIGILADOR_POLL_STALE_SEGUNDOS = 10 * 60;
// Pausa válida para resetear el continuo. Ajustado de 15 a 10 min
// el 2026-05-13 a pedido de Santiago tras un caso real: Sebas Chavez
// (DNI 24861891) paró 12:05-12:20 (15 min cronómetro en mano) pero
// el sistema le mandó la alerta de 3:45 igual porque vio solo
// ~10-12 min de pausa.
// Diagnóstico: el GPS de Sitrack tiene un delay de 1-3 min entre que
// el chofer físicamente se detiene/arranca y el sample lo refleja;
// ese delay se come una buena parte del umbral de 15 min cuando la
// pausa es justo de ese largo. Con 10 min, una pausa real de 12-13
// min ya cuenta. Sigue siendo más estricto que la norma Mercosur
// (30 min cada 4h 30m).
const VIGILADOR_PAUSA_RESET_SEGUNDOS = 10 * 60;
// Aviso preventivo continuo: 30 min antes del límite de 4h. Antes era
// 3:45 (15 min antes) — bumpeado a 3:30 (30 min antes) el 2026-05-13
// a pedido de Santiago: "le quedan 30 min para buscar lugar seguro".
const VIGILADOR_CONTINUO_ALERTA_SEGUNDOS = 3 * 3600 + 30 * 60;
// Límite duro de manejo continuo. A los 4h se manda un aviso fuerte
// "penalizado por falta de descanso obligatorio" — la flag
// `pausa_obligatoria_excedida` ya hace que aparezca en el resumen
// diario de Seg e Higiene (Molina) sin necesidad de WhatsApp directo.
const VIGILADOR_CONTINUO_LIMITE_SEGUNDOS = 4 * 3600;
const VIGILADOR_DIARIO_ALERTA_SEGUNDOS = 11 * 3600 + 30 * 60;
const VIGILADOR_DIARIO_LIMITE_SEGUNDOS = 12 * 3600;
// Hora mínima fija desde la que se permite arrancar después de cumplir
// 12h diarias. La regla operativa de Vecchi (Santiago 2026-05-13):
// "no se maneja después de las 00:00 y no se arranca antes de las 6
// AM ART, mínimo 8h de descanso ya garantizado por la noche". La
// fórmula final es `max(6 AM ART próximo, fin_jornada + 8h)` — lo
// segundo cubre el caso borde donde fin_jornada cae de madrugada y
// 6 AM no alcanzaría a cubrir las 8h legales.
const VIGILADOR_HORA_MIN_ARRANQUE_HORA_ART = 6;
// Pausa larga que cierra una jornada y abre una nueva (descanso entre
// jornadas). Resetea `segundos_jornada_actual` y los flags de alerta
// diaria. 8h = mínimo Argentina (Ley 24653 art. 53). Mercosur pide 11h
// pero respetamos el mínimo legal local. Sin esta lógica, un chofer
// que cruza medianoche se ve como "2 jornadas separadas" — antes del
// fix 2026-05-13 perdíamos las jornadas nocturnas en el resumen.
const VIGILADOR_DESCANSO_JORNADA_SEGUNDOS = 8 * 3600;
// Pausa mínima para considerar que fue "descanso entre jornadas" (vs
// pausa intra-jornada tipo almuerzo o espera de carga). Por debajo
// de 4h asumimos que es pausa operativa normal y NO avisamos por
// descanso corto. Entre 4h y 8h: descanso entre jornadas insuficiente
// → avisar al chofer y sumarlo al resumen de Molina.
const VIGILADOR_PAUSA_MIN_PARA_DESCANSO_SEGUNDOS = 4 * 3600;
// Cap para evitar deltas locos si el cron estuvo caído mucho tiempo.
// 10 min = 2 ciclos completos del cron de 5 min.
const VIGILADOR_DELTA_MAX_SEGUNDOS = 600;

// Aviso nocturno "fin de jornada próxima" — activado 2026-05-14
// (Santiago). El bot opera con horario hábil que cubre las 23:30 ART
// (WORKING_HOURS_END=24), entonces el mensaje sale en el momento.
// Decisión Vecchi: choferes no pueden conducir 00:00–06:00, así que
// el aviso a las 23:30 les da 30 min para buscar un lugar seguro
// donde estacionar y dormir.
const AVISO_NOCTURNO_ACTIVO = true;

// Throttle del aviso "pasá el iButton" (drift CHOFER_NO_IDENTIFICADO).
// El cron sitrackPosicionPoller corre cada 5 min — sin throttle, un
// chofer que maneja sin pasar el iButton recibe 1 mensaje cada 5 min,
// que es spam y dispara baneo de WhatsApp. Decisión Vecchi 2026-05-07:
// 1 mensaje cada 30 min como máximo por chofer.
const AVISO_NO_ID_THROTTLE_SEGUNDOS = 30 * 60;

// TTL de avisos tiempo-sensibles en COLA_WHATSAPP. Si el bot está
// apagado por horas (fines de semana, mantenimiento, multi-PC sin
// arrancar), al volver procesa todo lo pendiente — incluso avisos
// que ya perdieron sentido (ej. "te quedan 15 min para parar"
// llegando 14 horas después). Solución: setear `expira_en` al
// encolar, y el bot borra los expirados sin enviar (decisión Vecchi
// 2026-05-08). Los resúmenes diarios y vencimientos NO usan TTL —
// llegan cuando llegan.
const TTL_PAUSA_CONTINUA_MIN = 60; // 3h45 chofer
const TTL_LIMITE_DIARIO_MIN = 120; // 11h30 chofer
const TTL_JORNADA_EXCEDIDA_MIN = 60; // 12h chofer (excedió límite legal)
const TTL_DESCANSO_CORTO_MIN = 60; // arrancó con < 8h descanso entre jornadas
const TTL_FIN_NOCTURNO_MIN = 60; // 23:30 chofer (cuando se active)
const TTL_VOLVO_MANEJO_MIN = 120; // OVERSPEED, IDLING, HARSH, PTO
const TTL_PASA_IBUTTON_MIN = 30; // CHOFER_NO_IDENTIFICADO Sitrack

function _expiraEnMinutos(minutos: number): Timestamp {
  return Timestamp.fromMillis(Date.now() + minutos * 60 * 1000);
}

const TIPOS_MANTENIMIENTO_DIRECTOS = new Set(["FUEL", "CATALYST"]);

const SUBTIPOS_GENERIC_MANTENIMIENTO = new Set([
  "TELL_TALE",
  "ADBLUELEVEL_LOW",
  "WITHOUT_ADBLUE",
]);

function _esAlertaMantenimiento(
  tipo: string,
  data: Record<string, unknown>
): boolean {
  if (TIPOS_MANTENIMIENTO_DIRECTOS.has(tipo)) return true;
  if (tipo !== "GENERIC") return false;
  const detalleGeneric = data.detalle_generic as
    | Record<string, unknown>
    | undefined;
  const subType = (detalleGeneric?.type ?? "").toString().toUpperCase();
  return SUBTIPOS_GENERIC_MANTENIMIENTO.has(subType);
}

export const onAlertaVolvoMantenimientoCreated = onDocumentCreated(
  {
    document: "VOLVO_ALERTAS/{alertId}",
    timeoutSeconds: 30,
    memory: "256MiB",
  },
  async (event) => {
    const snap = event.data;
    if (!snap) {
      logger.warn("[onAlertaVolvoMantenimientoCreated] event.data vacío, skip");
      return;
    }

    const data = snap.data() ?? {};
    const tipo = (data.tipo ?? "").toString().toUpperCase();

    if (!_esAlertaMantenimiento(tipo, data)) {
      return; // No es del tipo que notificamos.
    }

    const patente = (data.patente ?? "").toString().trim().toUpperCase();

    // Etiqueta legible para el log.
    let etiqueta = ETIQUETAS_TIPO_ALERTA[tipo] ?? tipo;
    if (tipo === "GENERIC") {
      const detalleGeneric = data.detalle_generic as
        | Record<string, unknown>
        | undefined;
      const subType = (detalleGeneric?.type ?? "").toString().toUpperCase();
      etiqueta = ETIQUETAS_TIPO_ALERTA[subType] ?? subType ?? "Evento genérico";
    }

    // No encolamos en COLA_WHATSAPP aquí. El cron del bot lee
    // VOLVO_ALERTAS una vez por día y manda UN mensaje consolidado con
    // todos los eventos de mantenimiento de las últimas 24h
    // (cron_mantenimiento_diario en whatsapp-bot/src/cron.js).
    // Enviar uno por evento generaba N mensajes separados al admin.
    logger.info(
      "[onAlertaVolvoMantenimientoCreated] evento registrado en " +
      "VOLVO_ALERTAS — cron diario lo incluirá en resumen",
      {
        alertId: event.params.alertId,
        patente,
        tipo,
        etiqueta,
      }
    );
  }
);

// ============================================================================
// backupFirestoreScheduled — backup automático semanal de Firestore
// ============================================================================
//
// Reemplazo cloud-side del script `scripts/backup_firestore.ps1` que era
// PC-bound (requería que Santiago ejecutara desde su Windows). Esta
// function corre en GCP, así que NO depende de ninguna PC encendida —
// mitiga el bus factor (riesgo #1 del proyecto).
//
// Schedule: domingos 06:00 ART (poco tráfico operativo). Frecuencia
// semanal alcanza para el tipo de uso de Vecchi (la flota se opera de
// L-V; los vencimientos cambian poco entre semanas). Si en el futuro se
// quiere diario, cambiar `schedule` por "0 6 * * *".
//
// Output: cada run crea un export en
// `gs://coopertrans-movil-backups/auto-{YYYY-MM-DD}_{HHMM}/` con todas
// las colecciones operativas (mismas que el script ps1 + VOLVO_SCORES_DIARIOS
// que se sumó después).
//
// Retención: NO se gestiona desde código — se setea Object Lifecycle del
// bucket vía gcloud (ver RUNBOOK sección "Backup automático"). Borra
// automáticamente exports > 30 días, gestionado por GCP, gratis.
//
// Setup operativo (one-time, vos lo corrés):
//   1. Crear bucket si no existe:
//      gcloud storage buckets create gs://coopertrans-movil-backups \
//        --project=coopertrans-movil --location=southamerica-east1 \
//        --uniform-bucket-level-access
//   2. IAM grants para la SA de Functions Gen2 (compute SA del proyecto):
//      gcloud projects add-iam-policy-binding coopertrans-movil \
//        --member="serviceAccount:808925655961-compute@developer.gserviceaccount.com" \
//        --role="roles/datastore.importExportAdmin"
//      gcloud storage buckets add-iam-policy-binding gs://coopertrans-movil-backups \
//        --member="serviceAccount:808925655961-compute@developer.gserviceaccount.com" \
//        --role="roles/storage.objectAdmin"
//   3. Lifecycle de retención (30 días) — ver comando completo en RUNBOOK
//      sección "Backup automático Firestore".
//   4. Deploy: firebase deploy --only functions:backupFirestoreScheduled
//
// Restauración (cuando un day pasa lo peor): ver RUNBOOK sección
// "Disaster recovery — restaurar Firestore desde backup".
export const backupFirestoreScheduled = onSchedule(
  {
    schedule: "0 6 * * 0",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 540,
    memory: "256MiB",
  },
  async () => {
    const projectId = process.env.GCLOUD_PROJECT || "coopertrans-movil";
    const bucketName = "coopertrans-movil-backups";

    // YYYY-MM-DD_HHMM en hora ART (Argentina). Lo lee Santiago al abrir
    // GCS Console — coherente con la regla del proyecto de NO mostrar UTC
    // al usuario. Construido manual con Intl.DateTimeFormat porque el
    // `toISOString()` nativo siempre devuelve UTC y Cloud Functions corre
    // en UTC por default.
    const ahora = new Date();
    const fmtFecha = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Argentina/Buenos_Aires",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    });
    const fmtHora = new Intl.DateTimeFormat("en-GB", {
      timeZone: "America/Argentina/Buenos_Aires",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    });
    const fechaTag = `${fmtFecha.format(ahora)}_${fmtHora.format(ahora).replace(":", "")}`;
    const outputUriPrefix = `gs://${bucketName}/auto-${fechaTag}`;

    // Mismas colecciones que scripts/backup_firestore.ps1 + VOLVO_SCORES_DIARIOS
    // que se sumó después de ese script. Si se agrega una colección nueva
    // operativa, sumarla acá Y al script ps1 (legacy de respaldo manual).
    const collectionIds = [
      "EMPLEADOS",
      "VEHICULOS",
      "REVISIONES",
      "CHECKLISTS",
      "COLA_WHATSAPP",
      "AVISOS_AUTOMATICOS_HISTORICO",
      "RESPUESTAS_BOT_AMBIGUAS",
      "AUDITORIA_ACCIONES",
      "TELEMETRIA_HISTORICO",
      "MANTENIMIENTOS_AVISADOS",
      "BOT_HEALTH",
      "BOT_CONTROL",
      "LOGIN_ATTEMPTS",
      "ASIGNACIONES_VEHICULO",
      "VOLVO_ALERTAS",
      "VOLVO_SCORES_DIARIOS",
      "META",
    ];

    logger.info("[backupFirestoreScheduled] inicio", {
      outputUriPrefix,
      collectionIds,
    });

    const adminClient = new firestoreAdminV1.FirestoreAdminClient();
    const databaseName = adminClient.databasePath(projectId, "(default)");

    try {
      const [operation] = await adminClient.exportDocuments({
        name: databaseName,
        outputUriPrefix,
        collectionIds,
      });
      // exportDocuments devuelve una long-running operation: el export
      // real corre en background en GCP. La function termina apenas se
      // recibe el handle (no esperamos a que termine — sería tirar plata
      // de Cloud Functions). El estado final queda visible en:
      //   gcloud firestore operations list --project=coopertrans-movil
      logger.info("[backupFirestoreScheduled] export iniciado en background", {
        operationName: operation.name,
      });
    } catch (err) {
      logger.error("[backupFirestoreScheduled] export FALLÓ", {
        error: (err as Error).message,
        stack: (err as Error).stack,
      });
      // Re-throw para que GCP marque el run como FAILED. Cloud Monitoring
      // lo ve como error rate up, podés enganchar una alerta si querés.
      throw err;
    }
  }
);

// ============================================================================
// botHealthWatchdog — registra caídas y recuperaciones del bot
// ============================================================================
//
// El bot Node.js corre en la PC de Santiago y escribe heartbeat a
// `BOT_HEALTH/main.ultimoHeartbeat` cada 60s. La pantalla "Estado del Bot"
// del admin lo muestra, pero requiere que Santiago entre a esa pantalla
// para enterarse — riesgo: el bot puede llevar horas/días caído sin que
// nadie lo note (PC apagada por reinicio de Windows, NSSM crasheado,
// etc.) y los choferes dejan de recibir avisos críticos.
//
// **Cambio 2026-05-08**: ANTES esta función mandaba un WhatsApp inmediato
// cuando detectaba la caída. Eso quedaba viejo rápido (caída a las 15:38,
// veo el aviso a las 18:10 cuando ya recuperó hace rato → ruido). Ahora
// solo REGISTRA los eventos en `BOT_EVENTOS` (caída y recuperación). El
// resumen consolidado lo manda `resumenBotDiario` al día siguiente a
// las 8 AM.
//
// Esta function corre cada 15 min, compara `ultimoHeartbeat` con ahora.
// Si la diferencia es > UMBRAL_STALE_MIN, escribe evento `caida`.
// Idempotencia: solo registra UNA vez por episodio (flag
// `notificadoCaida` en BOT_HEALTH). Cuando el bot vuelve, escribe evento
// `recuperado` con la duración total y limpia la flag.

const BOT_HEALTH_STALE_UMBRAL_MIN = 10;

export const botHealthWatchdog = onSchedule(
  {
    schedule: "*/15 * * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    const ref = db.collection("BOT_HEALTH").doc("main");
    const snap = await ref.get();
    if (!snap.exists) {
      logger.info("[botHealthWatchdog] BOT_HEALTH/main no existe (primer run), skip");
      return;
    }
    const data = snap.data() ?? {};
    const ultimoHb = data.ultimoHeartbeat as Timestamp | undefined;
    if (!ultimoHb) {
      logger.info("[botHealthWatchdog] sin ultimoHeartbeat aún, skip");
      return;
    }

    const minDesdeHb = (Date.now() - ultimoHb.toMillis()) / 60000;
    const yaNotificado = data.notificadoCaida === true;
    const pcId = (data.pcId ?? "desconocida").toString();

    if (minDesdeHb <= BOT_HEALTH_STALE_UMBRAL_MIN) {
      // Bot vivo.
      if (yaNotificado) {
        // Volvió de una caída — registrar evento `recuperado` con la
        // duración total estimada (desde la última caída detectada
        // hasta ahora).
        const caidaDetectadaEn = data.notificadoCaidaEn as Timestamp | undefined;
        const duracionMin = caidaDetectadaEn ?
          Math.round((Date.now() - caidaDetectadaEn.toMillis()) / 60000) :
          null;
        await db.collection("BOT_EVENTOS").add({
          tipo: "recuperado",
          pcId,
          detectadoEn: FieldValue.serverTimestamp(),
          duracionMin,
          caidaDetectadaEn: caidaDetectadaEn ?? null,
        });
        await ref.update({
          notificadoCaida: false,
          recuperadoEn: FieldValue.serverTimestamp(),
        });
        logger.info("[botHealthWatchdog] bot recuperado, evento registrado", {
          minDesdeUltimoHb: minDesdeHb.toFixed(1),
          duracionMin,
        });
      }
      return;
    }

    // Bot stale.
    if (yaNotificado) {
      // Ya registramos el evento de caída, no duplicar.
      logger.info("[botHealthWatchdog] bot sigue caído, evento ya registrado", {
        minDesdeUltimoHb: minDesdeHb.toFixed(1),
      });
      return;
    }

    // Primera detección de caída — registrar evento. NO mandamos
    // WhatsApp inmediato (el aviso quedaría viejo si la caída fue
    // hace varias horas). El resumen diario a las 8 AM consolida todo.
    const minutosSinHeartbeat = Math.round(minDesdeHb);
    await db.collection("BOT_EVENTOS").add({
      tipo: "caida",
      pcId,
      detectadoEn: FieldValue.serverTimestamp(),
      ultimoHeartbeatEn: ultimoHb,
      minutosSinHeartbeat,
    });

    await ref.update({
      notificadoCaida: true,
      notificadoCaidaEn: FieldValue.serverTimestamp(),
    });

    logger.warn("[botHealthWatchdog] bot caído — evento registrado para resumen diario", {
      minDesdeUltimoHb: minutosSinHeartbeat,
      pcId,
    });
  }
);

// ============================================================================
// resumenBotDiario — resumen consolidado de eventos del bot (8 AM diario)
// ============================================================================
//
// Lee `BOT_EVENTOS` de las últimas 24h y arma un resumen con caídas y
// recuperaciones del bot. Lo manda al admin (Santiago) por WhatsApp.
// Si NO hubo eventos, NO se manda nada (silencio = todo OK).
//
// Reemplaza el aviso inmediato del watchdog (decisión 2026-05-08): mandar
// alerta cuando se detecta la caída quedaba viejo (por el cron cada 15
// min, tarda en detectar; cuando llega al user puede haber pasado horas
// y ya recuperó). Mejor consolidar al día siguiente.

export const resumenBotDiario = onSchedule(
  {
    schedule: "0 8 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    logger.info("[resumenBotDiario] iniciando");

    // Idempotencia diaria.
    const hoyKey = _formatFechaArg(Date.now()).replace(/\//g, "-");
    const histRef = db
      .collection("AVISOS_AUTOMATICOS_HISTORICO")
      .doc(`bot_resumen_${hoyKey}_${MANTENIMIENTO_DESTINATARIO_DNI}`);
    const histSnap = await histRef.get();
    if (histSnap.exists) {
      logger.info("[resumenBotDiario] ya enviado hoy, skip");
      return;
    }

    // Eventos de las últimas 24h.
    const desde = Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);
    const evSnap = await db
      .collection("BOT_EVENTOS")
      .where("detectadoEn", ">=", desde)
      .orderBy("detectadoEn", "asc")
      .get();

    // Lookup destinatario.
    const adminDni = MANTENIMIENTO_DESTINATARIO_DNI;
    const empSnap = await db.collection("EMPLEADOS").doc(adminDni).get();
    const tel = empSnap.exists ?
      (empSnap.data()?.TELEFONO ?? "").toString().trim() :
      "";
    if (!tel) {
      logger.error("[resumenBotDiario] admin sin TELEFONO", {
        adminDni,
      });
      return;
    }

    // Sin eventos: mandamos "todo OK" igual (decisión Santiago
    // 2026-05-09: silencio = ambiguo, un mensaje confirma que el cron
    // corrió y el bot estuvo sano las últimas 24h).
    if (evSnap.empty) {
      const fechaTxt = _formatFechaArg(Date.now());
      const mensajeOk =
        `🤖 *Resumen del bot — ${fechaTxt}*\n\n` +
        "✅ Sin caídas ni eventos en las últimas 24 h.\n\n" +
        BANNER_TESTING +
        "_Si dejaras de recibir este resumen a las 8 AM, " +
        "verificá que la Cloud Function `resumenBotDiario` esté activa._";
      const colaRef = await db.collection("COLA_WHATSAPP").add({
        telefono: tel,
        mensaje: mensajeOk,
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
        enviado_en: null,
        error: null,
        intentos: 0,
        origen: "cron_bot_resumen_diario",
        destinatario_coleccion: "EMPLEADOS",
        destinatario_id: adminDni,
        campo_base: "BOT_RESUMEN_DIARIO",
        admin_dni: "BOT",
        admin_nombre: "Bot watchdog",
      });
      await histRef.set({
        tipo: "bot_resumen_diario",
        destinatario_dni: MANTENIMIENTO_DESTINATARIO_DNI,
        fecha: hoyKey,
        cantidad_eventos: 0,
        cola_doc_id: colaRef.id,
        creado_en: FieldValue.serverTimestamp(),
      });
      logger.info("[resumenBotDiario] OK (sin eventos)", { colaDocId: colaRef.id });
      return;
    }

    // Armar mensaje.
    const lineas: string[] = [];
    let totalCaidas = 0;
    let totalRecuperaciones = 0;
    let minutosCaidoTotal = 0;

    for (const doc of evSnap.docs) {
      const d = doc.data();
      const tipo = String(d.tipo ?? "");
      const detectadoEn = d.detectadoEn as Timestamp | undefined;
      if (!detectadoEn) continue;
      const horaTxt = _formatHoraArg(detectadoEn.toMillis());
      const fechaTxt = _formatFechaArg(detectadoEn.toMillis());
      const pcId = (d.pcId ?? "?").toString();

      if (tipo === "caida") {
        totalCaidas++;
        const minSinHb = d.minutosSinHeartbeat ?? "?";
        lineas.push(
          `🔴 *Caída detectada* — ${fechaTxt} ${horaTxt} (PC \`${pcId}\`, ` +
          `${minSinHb} min sin heartbeat al detectar)`
        );
      } else if (tipo === "recuperado") {
        totalRecuperaciones++;
        const dur = typeof d.duracionMin === "number" ? d.duracionMin : null;
        if (dur !== null) minutosCaidoTotal += dur;
        const durTxt = dur !== null ? `${dur} min` : "?";
        lineas.push(
          `🟢 *Recuperado* — ${fechaTxt} ${horaTxt} (PC \`${pcId}\`, ` +
          `caído ~${durTxt})`
        );
      } else {
        lineas.push(`• ${tipo} ${fechaTxt} ${horaTxt}`);
      }
    }

    const titulo =
      totalCaidas === 0 && totalRecuperaciones > 0 ?
        "🤖 *Resumen del bot — recuperaciones de caídas previas*" :
        totalCaidas > 0 ?
          `🤖 *Resumen del bot — ${totalCaidas} ` +
          `caída${totalCaidas !== 1 ? "s" : ""} en últimas 24h*` :
          "🤖 *Resumen del bot — eventos del día*";

    const subtotal = minutosCaidoTotal > 0 ?
      `\n\nTiempo total caído estimado: ${minutosCaidoTotal} min.` :
      "";

    const mensaje =
      titulo + "\n\n" +
      lineas.join("\n") +
      subtotal + "\n\n" +
      BANNER_TESTING +
      "_Si hubo caídas que no detectaste, verificá el servicio (NSSM " +
      "del bot) en la PC correspondiente._";

    // Encolar.
    const colaRef = await db.collection("COLA_WHATSAPP").add({
      telefono: tel,
      mensaje,
      estado: "PENDIENTE",
      encolado_en: FieldValue.serverTimestamp(),
      enviado_en: null,
      error: null,
      intentos: 0,
      origen: "cron_bot_resumen_diario",
      destinatario_coleccion: "EMPLEADOS",
      destinatario_id: adminDni,
      campo_base: "BOT_RESUMEN_DIARIO",
      admin_dni: "BOT",
      admin_nombre: "Bot watchdog",
    });

    await histRef.set({
      tipo: "bot_resumen_diario",
      destinatario_dni: adminDni,
      fecha: hoyKey,
      cantidad_eventos: evSnap.size,
      cantidad_caidas: totalCaidas,
      cantidad_recuperaciones: totalRecuperaciones,
      minutos_caido_total: minutosCaidoTotal,
      cola_doc_id: colaRef.id,
      creado_en: FieldValue.serverTimestamp(),
    });

    logger.info("[resumenBotDiario] OK", {
      eventos: evSnap.size,
      caidas: totalCaidas,
      recuperaciones: totalRecuperaciones,
      minutosCaidoTotal,
      colaDocId: colaRef.id,
    });
  }
);

// ============================================================================
// sitrackPosicionPoller — última posición de toda la flota
// ============================================================================
//
// Toda la flota (55 tractores hoy) está en Sitrack — incluye también
// unidades sin Volvo Connect, así que es la mejor fuente para responder
// "dónde está cada tractor ahora". Volvo Vehicle Alerts solo nos dispara
// eventos puntuales (overspeed/idling/etc), no la posición continua —
// si un tractor lleva 1h sin generar evento, no sabemos dónde está. Con
// Sitrack sí.
//
// Endpoint: GET /v2/report (último reporte de cada unidad de la cuenta).
// Auth: Basic HTTPS con usuario web service. Cuota: hasta 1000 unidades
// por cuenta — sobra para Vecchi.
//
// Estrategia:
//   1. Cron cada 5 min llama al endpoint, recibe array con un item por
//      unidad activa.
//   2. Por cada item válido (con lat/lng y gpsValidity confiable),
//      mergeamos en `SITRACK_POSICIONES/{patente}` — doc id = patente,
//      no historizamos. Es snapshot del último estado.
//   3. Cursor de health en `META/sitrack_posicion_cursor` para que el
//      tablero de admin pueda detectar caídas del poller.
//
// Por qué `merge: true` y no `set` total: en algunos polls Sitrack puede
// devolver un reporte sin algunos campos opcionales (driver_dni vacío
// si el chofer todavía no se identificó); merge mantiene los últimos
// conocidos en lugar de borrarlos. La info de "frescura" del campo
// individual va via timestamps (ignition_date, report_date).

const sitrackUsername = defineSecret("SITRACK_USERNAME");
const sitrackPassword = defineSecret("SITRACK_PASSWORD");

const SITRACK_BASE_AR = "https://externalappgw.ar.sitrack.com";

interface SitrackReportItem {
  reportId?: string;
  reportDate?: string;
  inputDate?: string;
  assetId?: string;
  assetName?: string;
  deviceId?: string;
  holderId?: string;
  eventId?: number;
  eventName?: string;
  latitude?: number;
  longitude?: number;
  location?: string;
  heading?: number;
  speed?: number;
  ignition?: 0 | 1;
  ignitionDate?: string;
  odometer?: number;
  gpsOdometer?: number;
  hourmeter?: number;
  deviceHourmeter?: number;
  driverName?: string;
  driverLastName?: string;
  driverDocumentNumber?: string;
  driverDocumentType?: string;
  // gpsValidity: 0..89 = confiable; >= 90 = no confiable.
  gpsValidity?: number;
  gpsSatellites?: number;
  gpsDop?: number;
  areaType?: string;
  batteryVoltage?: number;
  backupBatteryVoltage?: number;
  trailerId?: string;
  trailerName?: string;
}

export const sitrackPosicionPoller = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [sitrackUsername, sitrackPassword],
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    logger.info("[sitrackPosicionPoller] iniciando ciclo");

    // ─── Auth Basic HTTPS ──────────────────────────────────────────
    const authHeader = "Basic " + Buffer.from(
      `${sitrackUsername.value()}:${sitrackPassword.value()}`
    ).toString("base64");

    // ─── Fetch ─────────────────────────────────────────────────────
    const url = `${SITRACK_BASE_AR}/v2/report`;
    let res: Response;
    try {
      res = await fetch(url, {
        method: "GET",
        headers: {
          "Authorization": authHeader,
          "Accept": "application/json",
        },
      });
    } catch (e) {
      logger.error("[sitrackPosicionPoller] fetch falló", {
        error: (e as Error).message,
      });
      return;
    }

    if (!res.ok) {
      logger.warn("[sitrackPosicionPoller] HTTP error", {
        statusCode: res.status,
      });
      return;
    }

    let reports: SitrackReportItem[];
    try {
      reports = (await res.json()) as SitrackReportItem[];
    } catch (e) {
      logger.error("[sitrackPosicionPoller] JSON parse falló", {
        error: (e as Error).message,
      });
      return;
    }

    if (!Array.isArray(reports)) {
      logger.warn("[sitrackPosicionPoller] respuesta no es array", {
        tipo: typeof reports,
      });
      return;
    }

    // ─── Drift detection: leer asignaciones activas ────────────────
    // Cargamos en memoria todas las ASIGNACIONES_VEHICULO con hasta=null
    // (~30 docs activas para una flota de 55). Por cada patente que
    // Sitrack reporta, comparamos el DNI del chofer físico (driverDoc-
    // umentNumber del iButton) con el DNI del chofer asignado por el
    // sistema. Si no coinciden, marcamos drift_tipo en el doc para que
    // la pantalla del admin lo destaque.
    interface AsignacionActiva {
      choferDni: string;
      choferNombre: string;
    }
    const asignacionesPorPatente = new Map<string, AsignacionActiva>();
    try {
      const asignSnap = await db
        .collection("ASIGNACIONES_VEHICULO")
        .where("hasta", "==", null)
        .get();
      for (const d of asignSnap.docs) {
        const data = d.data();
        const patente = (data.vehiculo_id ?? "").toString().trim().toUpperCase();
        const dni = (data.chofer_dni ?? "").toString().trim();
        const nombre = (data.chofer_nombre ?? "").toString().trim();
        if (patente && dni) {
          asignacionesPorPatente.set(patente, { choferDni: dni, choferNombre: nombre });
        }
      }
    } catch (e) {
      // Si falla, seguimos sin drift detection (no rompemos el poller).
      logger.warn("[sitrackPosicionPoller] no pude leer ASIGNACIONES_VEHICULO", {
        error: (e as Error).message,
      });
    }

    // ─── Persistir en SITRACK_POSICIONES ───────────────────────────
    // Batch único: 55 docs entran cómodos en un solo batch (límite 500).
    const batch = db.batch();
    let escritos = 0;
    let descartados = 0;
    let conDrift = 0;

    // Choferes con drift CHOFER_NO_IDENTIFICADO en este ciclo —
    // recolectamos para avisarles al final (después del batch commit)
    // que pasen el iButton de Sitrack. Vecchi NO usa el login del
    // tachógrafo Volvo; usa el iButton de Sitrack para identificar al
    // chofer. Por eso este aviso lo dispara este cron y no
    // onAlertaVolvoCreated.
    const choferesParaAvisarNoId: Array<{
      patente: string;
      choferDni: string;
    }> = [];

    for (const r of reports) {
      const patente = (r.assetId ?? "").toString().trim().toUpperCase();
      if (!patente) {
        descartados++;
        continue;
      }

      // gpsValidity >= 90 → posición no confiable (poca señal de
      // satélites). Lo dice el doc explícitamente. En esos casos el
      // doc en SITRACK_POSICIONES queda "stale" hasta el próximo
      // reporte confiable — preferimos no pisar la última posición
      // buena con una mala.
      if (typeof r.gpsValidity === "number" && r.gpsValidity >= 90) {
        descartados++;
        continue;
      }

      const lat = typeof r.latitude === "number" ? r.latitude : null;
      const lng = typeof r.longitude === "number" ? r.longitude : null;
      if (lat === null || lng === null) {
        descartados++;
        continue;
      }

      const reportTs = r.reportDate ? new Date(r.reportDate) : null;
      const ignitionTs = r.ignitionDate ? new Date(r.ignitionDate) : null;

      // Odómetro: preferimos el "principal" (de la ECU si tiene ICAN,
      // sino calculado por GPS). gpsOdometer queda como respaldo de
      // visualización.
      const odometer = typeof r.odometer === "number" ?
        r.odometer :
        typeof r.gpsOdometer === "number" ?
          r.gpsOdometer :
          null;
      const hourmeter = typeof r.hourmeter === "number" ?
        r.hourmeter :
        typeof r.deviceHourmeter === "number" ?
          r.deviceHourmeter :
          null;

      // Chofer identificado vía iButton/tarjeta: DNI es el match
      // exacto contra EMPLEADOS/{dni}. driverName/driverLastName
      // pueden venir mezclados según cómo registraron al chofer en
      // el portal Sitrack — los guardamos crudos para el cross-check.
      const driverDni = (r.driverDocumentNumber ?? "").toString().trim();
      const driverNombre = (r.driverName ?? "").toString().trim();
      const driverApellido = (r.driverLastName ?? "").toString().trim();

      // ─── Drift detection ─────────────────────────────────────────
      // Comparamos el chofer físico (Sitrack) vs el asignado por el
      // sistema. Casos:
      //   - SIN_ASIGNACION: Sitrack reporta chofer pero el sistema
      //     no tiene a nadie asignado a esa patente. Alguien manejando
      //     sin estar registrado.
      //   - CHOFER_DISTINTO: Ambos lados reportan, pero los DNIs no
      //     coinciden. Falta actualizar la asignación.
      //   - CHOFER_NO_IDENTIFICADO: ignición ON, hay asignación, pero
      //     Sitrack no reporta DNI ni nombre que matchee — el chofer
      //     subió sin pasar el iButton. Si ignición OFF, no es drift
      //     (tractor parado).
      //
      // Sitrack a veces NO manda `driverDocumentNumber` aunque el
      // chofer SÍ esté logueado físicamente con el iButton (caso real
      // 2026-05-08 con Moises en AG890AL: Sitrack mandaba `driverName`
      // y `driverLastName` con sus datos pero `driverDocumentNumber`
      // vacío). En esos casos hacemos fallback de match por nombre
      // contra la asignación — si coincide, el chofer está
      // identificado igual.
      const ignitionOn = r.ignition === 1;
      const asignacion = asignacionesPorPatente.get(patente);

      // Match por nombre: concatena driverNombre + driverApellido en
      // ambos órdenes (Sitrack a veces invierte los campos) y compara
      // con asignacion.choferNombre. Match si el nombre asignado
      // contiene TODOS los tokens del nombre del iButton (case y
      // acentos insensitive). Permite que "OSCAR MOISES PEZOA" en
      // asignación matchee con iButton "PEZOA" + "OSCAR MOISES".
      const tokensSitrack = `${driverNombre} ${driverApellido}`
        .toUpperCase()
        .split(/\s+/)
        .filter((t) => t.length > 1);
      const nombreAsignacion = asignacion ?
        asignacion.choferNombre.toUpperCase() :
        "";
      const matchPorNombre =
        !!asignacion &&
        tokensSitrack.length > 0 &&
        tokensSitrack.every((t) => nombreAsignacion.includes(t));

      let driftTipo: string | null = null;
      if (driverDni && !asignacion) {
        driftTipo = "SIN_ASIGNACION";
      } else if (driverDni && asignacion && asignacion.choferDni !== driverDni) {
        driftTipo = "CHOFER_DISTINTO";
      } else if (!driverDni && asignacion && ignitionOn && !matchPorNombre) {
        driftTipo = "CHOFER_NO_IDENTIFICADO";
        // Recolectamos para enviar aviso al chofer asignado después
        // del batch commit. La dedup se hace en
        // `_encolarAvisoChoferNoIdentificado` para no spamear cada 5min.
        choferesParaAvisarNoId.push({
          patente,
          choferDni: asignacion.choferDni,
        });
      }
      if (driftTipo) conDrift++;

      const doc: Record<string, unknown> = {
        // Identificación
        patente,
        asset_name: r.assetName ?? "",
        holder_id: (r.holderId ?? "").toString(),
        device_id: (r.deviceId ?? "").toString(),
        // Posición
        lat,
        lng,
        location: r.location ?? "",
        heading: typeof r.heading === "number" ? r.heading : null,
        speed: typeof r.speed === "number" ? r.speed : null,
        // Estado motor
        ignition: r.ignition === 1,
        ignition_date: ignitionTs ? Timestamp.fromDate(ignitionTs) : null,
        odometer,
        hourmeter,
        // Chofer (puede no haberse identificado todavía → strings vacíos)
        driver_dni: driverDni,
        driver_nombre: driverNombre,
        driver_apellido: driverApellido,
        // Drift: comparación del DNI Sitrack vs ASIGNACIONES_VEHICULO.
        // null cuando todo coincide o cuando el tractor está parado
        // sin identificar (no es drift). La pantalla del admin filtra
        // por drift_tipo != null para destacar inconsistencias.
        drift_tipo: driftTipo,
        asignacion_dni: asignacion?.choferDni ?? "",
        asignacion_nombre: asignacion?.choferNombre ?? "",
        // Evento que disparó el reporte
        event_id: typeof r.eventId === "number" ? r.eventId : null,
        event_name: r.eventName ?? "",
        // Calidad GPS
        gps_validity: typeof r.gpsValidity === "number" ? r.gpsValidity : null,
        gps_satellites: typeof r.gpsSatellites === "number" ? r.gpsSatellites : null,
        // Trailer (sensor de enganche, hoy no instalado en ningún tractor
        // — lo guardamos por si en el futuro se instala)
        trailer_id: r.trailerId ?? "",
        trailer_name: r.trailerName ?? "",
        // Timestamps
        report_date: reportTs ? Timestamp.fromDate(reportTs) : null,
        consultado_en: FieldValue.serverTimestamp(),
        // Auditoría / debugging
        report_id: r.reportId ?? "",
      };

      batch.set(
        db.collection("SITRACK_POSICIONES").doc(patente),
        doc,
        { merge: true }
      );
      escritos++;
    }

    if (escritos > 0) {
      await batch.commit();
    }

    // ─── Health cursor ─────────────────────────────────────────────
    await db.collection("META").doc("sitrack_posicion_cursor").set(
      {
        ultimo_exito_at: FieldValue.serverTimestamp(),
        ultimo_recibidos: reports.length,
        ultimo_escritos: escritos,
        ultimo_descartados: descartados,
      },
      { merge: true }
    );

    // ─── Avisar a choferes con drift CHOFER_NO_IDENTIFICADO ─────────
    // Best-effort: cada aviso es independiente, fallas se loguean y
    // no abortan el ciclo. Throttle de 30 min por chofer en
    // META_AVISOS_NO_ID — sin esto el cron de 5 min spamearía al chofer
    // cada 5 min mientras siga manejando sin pasar el iButton (decisión
    // Vecchi 2026-05-07).
    let avisosEnviados = 0;
    let avisosDedup = 0;
    for (const item of choferesParaAvisarNoId) {
      try {
        const enviado = await _encolarAvisoChoferNoIdentificado(
          item.patente,
          item.choferDni
        );
        if (enviado) {
          avisosEnviados++;
        } else {
          avisosDedup++;
        }
      } catch (e) {
        logger.warn(
          "[sitrackPosicionPoller] aviso CHOFER_NO_IDENTIFICADO falló",
          {
            patente: item.patente,
            choferDni: item.choferDni,
            error: (e as Error).message,
          }
        );
      }
    }

    logger.info("[sitrackPosicionPoller] OK", {
      recibidos: reports.length,
      escritos,
      descartados,
      conDrift,
      avisosEnviados,
      avisosDedup,
    });
  }
);

// ============================================================================
// sitrackEventosPoller — consume `/files/reports` (eventos acumulados)
// ============================================================================
//
// Sitrack tiene 1400+ tipos de evento que sus equipos generan
// (jornada, conducción peligrosa, mantenimiento, viajes, etc. — ver
// docs/SITRACK-Tipos de evento_reporte). El endpoint /files/reports
// los acumula en un buffer del lado Sitrack y los entrega en cada
// llamada (drainable). Sin consumirlos regularmente:
//   - el buffer crece y la próxima llamada baja a tasa reducida.
//   - si pasan 30 días sin consumirse, Sitrack purga el buffer.
//
// Diferencia con `sitrackPosicionPoller`:
//   - posicionPoller usa /v2/report = snapshot del último estado de
//     CADA unidad (1 doc por patente, sobrescribe).
//   - eventosPoller usa /files/reports = stream de eventos discretos
//     (1 doc por evento, append-only, persiste todo el detalle).
//
// La lógica que CONSUME estos eventos (vigilador de jornada nuevo,
// auto-poblar viajes, alertas de descarga combustible, etc.) vive en
// otras funciones que leen `SITRACK_EVENTOS`. Este poller solo
// persiste — separación de concerns.
//
// Frecuencia: cada 5 min (Sitrack permite 1 invocación/min como max).
// Si en producción vemos backpressure (eventos acumulados > X), bajar
// el intervalo a 1-2 min.

interface SitrackEventoItem extends SitrackReportItem {
  sequentialId?: string;
  cartographyLimitSpeed?: number;
  gpsSpeed?: number;
  backupBatteryChargePercentage?: number;
}

export const sitrackEventosPoller = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    secrets: [sitrackUsername, sitrackPassword],
    timeoutSeconds: 240,
    memory: "512MiB",
  },
  async () => {
    logger.info("[sitrackEventosPoller] iniciando ciclo");

    const authHeader = "Basic " + Buffer.from(
      `${sitrackUsername.value()}:${sitrackPassword.value()}`
    ).toString("base64");

    const url = `${SITRACK_BASE_AR}/files/reports`;
    let res: Response;
    let bodyText = "";
    try {
      res = await fetch(url, {
        method: "GET",
        headers: {
          Authorization: authHeader,
          Accept: "application/json",
        },
      });
      // /files/reports devuelve text/plain (probablemente NDJSON o
      // array JSON). Leer todo el body antes de cerrar la conexión —
      // la doc Sitrack es explícita: si cerramos antes de leer todos
      // los bytes, en la próxima llamada se reenvía el bloque entero.
      bodyText = await res.text();
    } catch (e) {
      logger.error("[sitrackEventosPoller] fetch falló", {
        error: (e as Error).message,
      });
      return;
    }

    // 400 errorCode 120: otra invocación en progreso. Lo loguamos y
    // salimos — el próximo ciclo lo intenta de nuevo.
    if (res.status === 400 && bodyText.includes("\"errorCode\":120")) {
      logger.warn("[sitrackEventosPoller] otra invocación en progreso", {
        body: bodyText.slice(0, 200),
      });
      return;
    }
    if (!res.ok) {
      logger.warn("[sitrackEventosPoller] HTTP error", {
        statusCode: res.status,
        bodyHead: bodyText.slice(0, 500),
      });
      return;
    }

    const bodyBytes = Buffer.byteLength(bodyText, "utf8");
    if (bodyBytes === 0) {
      // Buffer vacío — caso normal cuando no hubo eventos nuevos.
      // Ojo: NO indica desactivación (ver script
      // sitrack_probar_files_reports.js para el matiz).
      logger.info("[sitrackEventosPoller] sin eventos nuevos");
      await db.collection("META").doc("sitrack_eventos_cursor").set({
        ultimo_exito_at: FieldValue.serverTimestamp(),
        ultimo_recibidos: 0,
        ultimo_escritos: 0,
        ultimo_descartados: 0,
        ultimo_bytes: 0,
      }, { merge: true });
      return;
    }

    // Parseo defensivo. El sample observado en pruebas mostró:
    //   {"reportId":"..."},\n{"reportId":"..."},\n...
    // No vimos `[` al inicio — por las dudas probamos 3 estrategias:
    //   1. JSON.parse del body completo (caso array JSON estándar).
    //   2. Envolver con [...] por si vienen items separados por coma.
    //   3. NDJSON: split por newline + parse cada línea.
    let eventos: SitrackEventoItem[] = [];
    let parseStrategy = "";
    try {
      const parsed = JSON.parse(bodyText);
      if (Array.isArray(parsed)) {
        eventos = parsed as SitrackEventoItem[];
        parseStrategy = "json-array";
      } else if (parsed && Array.isArray(parsed.reports)) {
        eventos = parsed.reports as SitrackEventoItem[];
        parseStrategy = "json-object-reports";
      } else if (parsed && typeof parsed === "object") {
        // Single object → array de 1.
        eventos = [parsed as SitrackEventoItem];
        parseStrategy = "json-single";
      }
    } catch {
      // Estrategia 2: envolver en array.
      try {
        const wrapped = `[${bodyText.replace(/,\s*$/, "")}]`;
        const parsed = JSON.parse(wrapped);
        if (Array.isArray(parsed)) {
          eventos = parsed as SitrackEventoItem[];
          parseStrategy = "comma-wrapped";
        }
      } catch {
        // Estrategia 3: NDJSON.
        const lineas = bodyText.split(/\r?\n/);
        for (const linea of lineas) {
          const t = linea.trim().replace(/,$/, "");
          if (!t) continue;
          try {
            eventos.push(JSON.parse(t) as SitrackEventoItem);
          } catch {
            // saltamos línea malformada
          }
        }
        parseStrategy = "ndjson-line-by-line";
      }
    }

    if (eventos.length === 0) {
      logger.warn("[sitrackEventosPoller] no se pudo parsear ningún evento", {
        bytes: bodyBytes,
        bodyHead: bodyText.slice(0, 500),
        parseStrategy,
      });
      return;
    }

    logger.info("[sitrackEventosPoller] eventos parseados", {
      cantidad: eventos.length,
      bytes: bodyBytes,
      parseStrategy,
    });

    // ─── Persistir en SITRACK_EVENTOS ─────────────────────────────
    // docId = reportId (UUID único por evento del lado Sitrack).
    // Idempotente: si por algún motivo el mismo reportId llega 2 veces,
    // sobrescribe sin duplicar (set sin merge — el evento es
    // inmutable, no hay update).
    //
    // Batches de 500 ops (límite Firestore). Si llegan > 500, hacemos
    // múltiples commits.
    const BATCH_SIZE = 500;
    let escritos = 0;
    let descartados = 0;
    let batch = db.batch();
    let opsEnBatch = 0;

    const parseTs = (s: string | undefined): Timestamp | null => {
      if (!s) return null;
      const d = new Date(s);
      return Number.isFinite(d.getTime()) ? Timestamp.fromDate(d) : null;
    };

    for (const e of eventos) {
      const reportId = (e.reportId ?? "").toString().trim();
      if (!reportId) {
        descartados++;
        continue;
      }

      const doc: Record<string, unknown> = {
        // Identificación
        report_id: reportId,
        sequential_id: (e.sequentialId ?? "").toString(),
        // Tiempo
        report_date: parseTs(e.reportDate),
        input_date: parseTs(e.inputDate),
        recibido_en: FieldValue.serverTimestamp(),
        // Activo
        asset_id: (e.assetId ?? "").toString(),
        asset_name: (e.assetName ?? "").toString(),
        device_id: (e.deviceId ?? "").toString(),
        holder_id: (e.holderId ?? "").toString(),
        // Evento
        event_id: typeof e.eventId === "number" ? e.eventId : null,
        event_name: (e.eventName ?? "").toString(),
        // Posición
        latitude: typeof e.latitude === "number" ? e.latitude : null,
        longitude: typeof e.longitude === "number" ? e.longitude : null,
        location: (e.location ?? "").toString(),
        area_type: (e.areaType ?? "").toString(),
        heading: typeof e.heading === "number" ? e.heading : null,
        speed: typeof e.speed === "number" ? e.speed : null,
        gps_speed: typeof e.gpsSpeed === "number" ? e.gpsSpeed : null,
        cartography_limit_speed:
          typeof e.cartographyLimitSpeed === "number" ?
            e.cartographyLimitSpeed :
            null,
        // Equipo
        ignition: e.ignition === 1 || e.ignition === 0 ? e.ignition : null,
        ignition_date: parseTs(e.ignitionDate),
        odometer: typeof e.odometer === "number" ? e.odometer : null,
        gps_odometer: typeof e.gpsOdometer === "number" ? e.gpsOdometer : null,
        hourmeter: typeof e.hourmeter === "number" ? e.hourmeter : null,
        device_hourmeter:
          typeof e.deviceHourmeter === "number" ? e.deviceHourmeter : null,
        // Chofer
        driver_dni: (e.driverDocumentNumber ?? "").toString(),
        driver_name: (e.driverName ?? "").toString(),
        driver_last_name: (e.driverLastName ?? "").toString(),
        // Calidad GPS
        gps_validity: typeof e.gpsValidity === "number" ? e.gpsValidity : null,
        gps_satellites:
          typeof e.gpsSatellites === "number" ? e.gpsSatellites : null,
        // Hardware
        battery_voltage:
          typeof e.batteryVoltage === "number" ? e.batteryVoltage : null,
        backup_battery_voltage:
          typeof e.backupBatteryVoltage === "number" ?
            e.backupBatteryVoltage :
            null,
        backup_battery_charge_percentage:
          typeof e.backupBatteryChargePercentage === "number" ?
            e.backupBatteryChargePercentage :
            null,
        // Trailer (en Vecchi hoy no instalado, lo dejamos por compat)
        trailer_id: (e.trailerId ?? "").toString(),
        trailer_name: (e.trailerName ?? "").toString(),
      };

      batch.set(
        db.collection("SITRACK_EVENTOS").doc(reportId),
        doc,
        { merge: false }
      );
      opsEnBatch++;
      escritos++;

      if (opsEnBatch >= BATCH_SIZE) {
        await batch.commit();
        batch = db.batch();
        opsEnBatch = 0;
      }
    }
    if (opsEnBatch > 0) {
      await batch.commit();
    }

    // ─── Health cursor ───────────────────────────────────────────
    await db.collection("META").doc("sitrack_eventos_cursor").set({
      ultimo_exito_at: FieldValue.serverTimestamp(),
      ultimo_recibidos: eventos.length,
      ultimo_escritos: escritos,
      ultimo_descartados: descartados,
      ultimo_bytes: bodyBytes,
      ultimo_parse_strategy: parseStrategy,
    }, { merge: true });

    logger.info("[sitrackEventosPoller] OK", {
      recibidos: eventos.length,
      escritos,
      descartados,
      bytes: bodyBytes,
      parseStrategy,
    });
  }
);

// Encola un aviso al chofer pidiéndole que pase el iButton de Sitrack
// para identificarse. Devuelve `true` si efectivamente encoló;
// `false` si no pudo (chofer no existe, sin teléfono, throttled, etc).
//
// Throttle 30 min por chofer (AVISO_NO_ID_THROTTLE_SEGUNDOS) — el cron
// corre cada 5 min, sin throttle el chofer recibe 1 msj cada 5 min y
// eso es spam directo (decisión Vecchi 2026-05-07). El estado del
// throttle vive en META_AVISOS_NO_ID/{choferDni} con last_sent_at
// (server timestamp). Si el chofer pasa el iButton antes de los 30
// min, el cron deja de detectar drift y no encola; el throttle
// expirado simplemente queda residual hasta el próximo drift.
async function _encolarAvisoChoferNoIdentificado(
  patente: string,
  choferDni: string
): Promise<boolean> {
  // Silencio manual via comando `/silenciar` del bot. La colección
  // BOT_SILENCIADOS_CHOFER se usaba sólo en el vigilador de jornada,
  // pero el chofer silenciado debería estarlo para TODOS los avisos
  // automáticos — sino el comando es engañoso. Bug detectado el
  // 2026-05-14 con Horacio (AC383OM): se le aplicó /silenciar y
  // siguió recibiendo el aviso del iButton porque este path no lo
  // chequeaba.
  try {
    const silSnap = await db
      .collection("BOT_SILENCIADOS_CHOFER")
      .doc(choferDni)
      .get();
    if (silSnap.exists) {
      const hasta = silSnap.data()?.silenciado_hasta;
      if (hasta && typeof hasta.toMillis === "function" &&
          hasta.toMillis() > Date.now()) {
        return false;
      }
    }
  } catch (e) {
    // Si falla el read no bloqueamos — peor caso le llega un aviso
    // que el admin pidió silenciar.
    logger.warn("[noIdentificado] no pude leer BOT_SILENCIADOS_CHOFER", {
      choferDni,
      error: (e as Error).message,
    });
  }

  // Throttle: ¿se le envió uno hace menos de 30 min?
  const throttleRef = db.collection("META_AVISOS_NO_ID").doc(choferDni);
  const throttleSnap = await throttleRef.get();
  if (throttleSnap.exists) {
    const lastSentAt = throttleSnap.data()?.last_sent_at;
    if (lastSentAt && typeof lastSentAt.toMillis === "function") {
      const segundosDesde = (Date.now() - lastSentAt.toMillis()) / 1000;
      if (segundosDesde < AVISO_NO_ID_THROTTLE_SEGUNDOS) {
        return false;
      }
    }
  }

  // Lookup chofer.
  const empSnap = await db.collection("EMPLEADOS").doc(choferDni).get();
  if (!empSnap.exists) {
    logger.warn(
      "[noIdentificado] chofer asignado no existe en EMPLEADOS",
      { choferDni, patente }
    );
    return false;
  }
  const empData = empSnap.data() ?? {};
  if (empData.ACTIVO === false) {
    return false;
  }
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") {
    return false;
  }

  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || _primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

  // Variantes para no repetir el mismo texto cada 5 min — anti-baneo
  // de WhatsApp y para que el chofer no lo perciba como auto-spam.
  // Mínimo 6 variantes (decisión 2026-05-09).
  const variantes = [
    `${saludo},\n\n` +
      `Estás manejando el TRACTOR ${patente} pero todavía no pasaste ` +
      "tu iButton de Sitrack. Por favor pasalo apenas puedas, así " +
      "quedan registrados los datos del recorrido.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      `Recordatorio: el TRACTOR ${patente} está en marcha pero ` +
      "Sitrack no te detecta logueado. Pasá el iButton apenas puedas.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, te avisamos desde la oficina.\n\n` +
      `Estamos viendo que manejás el ${patente} sin haber pasado ` +
      "el iButton de Sitrack. Necesitamos que te identifiques así " +
      "queda el registro del viaje.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, ¿pasaste el iButton?\n\n` +
      `El ${patente} viene andando pero Sitrack no te tiene ` +
      "identificado. Pasalo apenas tengas un momento para que el " +
      "viaje quede a tu nombre.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, atención.\n\n` +
      `Estamos detectando movimiento del TRACTOR ${patente} sin ` +
      "tu identificación. Pasá el iButton cuando puedas para no " +
      "perder el registro del tramo.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      `Recordatorio rápido: el ${patente} está en marcha sin chofer ` +
      "logueado en Sitrack. Pasá el iButton cuando puedas — es " +
      "importante para que quede el registro completo.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
  ];
  const mensaje = variantes[_rrPick(variantes.length)];

  await db.collection("COLA_WHATSAPP").add({
    telefono: tel,
    mensaje,
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    expira_en: _expiraEnMinutos(TTL_PASA_IBUTTON_MIN),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "sitrack_chofer_no_identificado",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: choferDni,
    campo_base: "SITRACK_DRIFT",
    admin_dni: "BOT",
    admin_nombre: "Bot Sitrack",
    alert_patente: patente,
  });

  // Marcar throttle: 30 min hasta el próximo aviso a este chofer.
  // Set con merge:false → reemplaza el doc completo, no acumulamos basura.
  await throttleRef.set({
    last_sent_at: FieldValue.serverTimestamp(),
    last_patente: patente,
  });
  return true;
}

// ============================================================================
// resumenDriftsAsignacionesDiario
// ============================================================================
//
// Cron L-V 19:00 ART que arma un resumen de los tractores con drift
// detectado (chofer físico vía iButton ≠ chofer asignado en el sistema)
// y lo encola como WhatsApp para el admin (Santiago, definido en
// MANTENIMIENTO_DESTINATARIO_DNI).
//
// Source: SITRACK_POSICIONES filtrado por `drift_tipo != null/empty`.
// El campo lo popula el cron `sitrackPosicionPoller` cada 5 min con
// uno de tres valores: SIN_ASIGNACION, CHOFER_DISTINTO,
// CHOFER_NO_IDENTIFICADO.
//
// Si no hay drifts, no se encola mensaje (silent log). Si hay > 20
// drifts, agrupamos por tipo y solo listamos el detalle de los primeros
// 10 — para no saturar el WhatsApp del admin con un texto interminable.
//
// Idempotencia: cron schedule corre 1x/día, no hay flag de "ya enviado"
// — si el cron se dispara dos veces el mismo día por algún glitch de
// GCP (raro), llegan dos mensajes idénticos. Aceptable.

const ETIQUETAS_DRIFT: Record<string, string> = {
  CHOFER_DISTINTO: "Chofer distinto al asignado",
  SIN_ASIGNACION: "Sin asignación en sistema",
  CHOFER_NO_IDENTIFICADO: "Chofer no se identificó (iButton)",
};

export const resumenDriftsAsignacionesDiario = onSchedule(
  {
    // 8:00 AM ART todos los días — Vecchi prefiere los resúmenes a la
    // mañana siguiente (con el bot ya arrancado y el admin en la
    // oficina) en lugar de la noche del día anterior.
    schedule: "0 8 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    logger.info("[resumenDriftsAsignacionesDiario] iniciando");

    // ─── Leer drifts actuales ──────────────────────────────────────
    // Filtramos por drift_tipo != null en código (Firestore no tiene
    // operador "IS NOT NULL" — `where("drift_tipo", "!=", null)` no
    // matchea docs sin el campo). Levantamos toda la colección (~55
    // docs, batch única) y filtramos. .limit(5000) defensivo: la
    // colección tiene 1 doc por patente, no debería crecer mucho.
    const snap = await db.collection("SITRACK_POSICIONES").limit(5000).get();
    const drifts = snap.docs
      .map((d) => ({ patente: d.id, data: d.data() }))
      .filter((x) => {
        const tipo = (x.data.drift_tipo ?? "").toString();
        return tipo.length > 0;
      });

    // ─── Lookup teléfono del admin ─────────────────────────────────
    const adminDni = MANTENIMIENTO_DESTINATARIO_DNI;
    const empSnap = await db.collection("EMPLEADOS").doc(adminDni).get();
    const tel = empSnap.exists ?
      (empSnap.data()?.TELEFONO ?? "").toString().trim() :
      "";
    if (!tel) {
      logger.error(
        "[resumenDriftsAsignacionesDiario] admin sin TELEFONO, no se puede notificar",
        { adminDni, driftsCount: drifts.length }
      );
      return;
    }

    // ─── Armar mensaje ─────────────────────────────────────────────
    const fechaTxt = _formatFechaArg(Date.now());

    // Sin drifts: mandamos "todo OK" igual (decisión Santiago
    // 2026-05-09: silencio = ambiguo, un mensaje confirma que el cron
    // corrió y todas las asignaciones están alineadas con el chofer
    // físico que reporta Sitrack).
    if (drifts.length === 0) {
      const mensajeOk =
        `📋 *Resumen drifts asignaciones — ${fechaTxt}*\n\n` +
        "✅ Sin drifts: todas las asignaciones coinciden con el " +
        "chofer físico de Sitrack.\n\n" +
        BANNER_TESTING +
        "_Coopertrans Móvil — Aviso automático._";
      await db.collection("COLA_WHATSAPP").add({
        telefono: tel,
        mensaje: mensajeOk,
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
        enviado_en: null,
        error: null,
        intentos: 0,
        origen: "resumen_drifts_asignaciones",
        destinatario_coleccion: "EMPLEADOS",
        destinatario_id: adminDni,
        campo_base: "DRIFTS_ASIGNACIONES_DIARIO",
        admin_dni: "BOT",
        admin_nombre: "Bot resumen diario",
      });
      logger.info("[resumenDriftsAsignacionesDiario] OK (sin drifts)");
      return;
    }

    // Conteo por tipo (para el header).
    const conteoPorTipo: Record<string, number> = {};
    for (const x of drifts) {
      const tipo = (x.data.drift_tipo ?? "").toString();
      conteoPorTipo[tipo] = (conteoPorTipo[tipo] ?? 0) + 1;
    }
    const breakdown = Object.entries(conteoPorTipo)
      .map(([tipo, n]) => `${n}× ${ETIQUETAS_DRIFT[tipo] ?? tipo}`)
      .join(", ");

    // Listar detalle, máx 10 ítems para no inflar el mensaje.
    const MAX_DETALLE = 10;
    const sorted = [...drifts].sort((a, b) =>
      a.patente.localeCompare(b.patente)
    );
    const aMostrar = sorted.slice(0, MAX_DETALLE);
    const restantes = sorted.length - aMostrar.length;

    const bloques = aMostrar.map((x) => {
      const tipo = (x.data.drift_tipo ?? "").toString();
      const sitDni = (x.data.driver_dni ?? "").toString();
      const sitApe = (x.data.driver_apellido ?? "").toString();
      const asigDni = (x.data.asignacion_dni ?? "").toString();
      const asigNom = (x.data.asignacion_nombre ?? "").toString();

      const fisico = sitDni ?
        (sitApe ? `${sitApe} (DNI ${sitDni})` : `DNI ${sitDni}`) :
        "(no se identificó)";
      const asignado = asigDni ?
        (asigNom ? `${asigNom} (DNI ${asigDni})` : `DNI ${asigDni}`) :
        "(sin asignación)";

      return `🚛 *${x.patente}*\n` +
        `   Sistema: ${asignado}\n` +
        `   Físico (iButton): ${fisico}\n` +
        `   ⚠️ ${ETIQUETAS_DRIFT[tipo] ?? tipo}`;
    });

    const cantidad = drifts.length;
    const cabecera =
      `🔍 *Drift de asignaciones — ${fechaTxt}*\n\n` +
      `${cantidad} ` +
      (cantidad === 1 ? "inconsistencia" : "inconsistencias") +
      ` chofer físico vs sistema (${breakdown}):\n\n`;

    const cola = restantes > 0 ?
      `\n\n_Y ${restantes} más. Resolvé desde Personal → ficha del chofer._` :
      "\n\n_Resolvé desde Personal → ficha del chofer._";

    const mensaje =
      cabecera +
      bloques.join("\n\n") +
      cola +
      "\n\n" +
      BANNER_TESTING +
      "_Aviso automático diario de drift — Coopertrans Móvil._";

    // ─── Encolar en COLA_WHATSAPP ──────────────────────────────────
    await db.collection("COLA_WHATSAPP").add({
      telefono: tel,
      mensaje,
      estado: "PENDIENTE",
      encolado_en: FieldValue.serverTimestamp(),
      enviado_en: null,
      error: null,
      intentos: 0,
      origen: "drift_diario",
      destinatario_coleccion: "EMPLEADOS",
      destinatario_id: adminDni,
      campo_base: "DRIFT_ASIGNACIONES",
      admin_dni: "BOT",
      admin_nombre: "Cron resumen drifts",
    });

    logger.info("[resumenDriftsAsignacionesDiario] encolado", {
      adminDni,
      driftsCount: cantidad,
      mostrados: aMostrar.length,
      restantes,
    });
  }
);

// ============================================================================
// vigiladorJornadaChofer — alertas de tiempo continuo + diario de manejo
// ============================================================================
//
// Cron cada 5 min que trackea el tiempo de manejo de cada chofer y
// dispara avisos cuando se acerca al límite legal (4h continuas / 12h
// diarias).
//
// Fuente de datos: SITRACK_POSICIONES, último snapshot por patente.
// "Manejando" se define como `speed > 15 km/h` — el motor encendido
// en pausa NO cuenta (caso real Vecchi: choferes paran a descansar
// pero dejan el motor prendido para A/C).
//
// Lógica del reset por pausa:
//   - Internamente el sistema considera "pausa válida" a 10 min de
//     speed ≤ 15 sin movimiento (ver VIGILADOR_PAUSA_RESET_SEGUNDOS).
//   - Al chofer le PEDIMOS 15 min de pausa en los avisos (las 6
//     variantes del aviso lo dicen explícito). El margen entre los
//     10 min internos y los 15 min pedidos al chofer compensa el
//     delay GPS típico de Sitrack (1-3 min al frenar + 1-3 min al
//     arrancar). Sin ese margen, un chofer que para exactos 15 min
//     puede no llegar al umbral interno (caso real reportado por
//     Sebas Chavez 2026-05-13).
//
// Estado por chofer en JORNADAS_CHOFER/{dni}_{YYYY-MM-DD}:
//   - segundos_total_dia       (acumulado del día, suma de todos los
//                                tramos > 15 km/h).
//   - segundos_continuo_actual (acumulado desde el último reset por
//                                pausa válida ≥ 10 min).
//   - segundos_pausa_actual    (tiempo seguido con speed ≤ 10 km/h).
//   - flags de alerta enviada (para no repetir en el mismo ciclo).
//   - flags de exceso (para el resumen diario al jefe de Seg).
//
// Las alertas se encolan en COLA_WHATSAPP igual que las demás. El bot
// las procesa y manda; los pendientes del mismo origen+chofer pueden
// agruparse via agrupador.js (no agregamos estos origenes a la lista
// agrupable porque los avisos son distintos en contenido — uno por
// continuo y otro por diario, máximo uno de cada por día).

export const vigiladorJornadaChofer = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 90,
    memory: "256MiB",
  },
  async () => {
    logger.info("[vigiladorJornadaChofer] iniciando");

    // Leer SITRACK_POSICIONES para el snapshot actual de cada patente.
    // .limit(5000) defensivo — 1 doc por patente, no debería crecer.
    const snap = await db.collection("SITRACK_POSICIONES").limit(5000).get();

    // Set de choferes silenciados (comando /silenciar via WhatsApp).
    // Una sola query al iniciar el ciclo — el set se consulta luego
    // antes de encolar cada aviso. ~50 choferes potenciales, en
    // general 0-2 silenciados a la vez.
    const silenciadosSet = await _cargarSilenciadosVigilador();

    const fechaArt = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Argentina/Buenos_Aires",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(new Date());

    const ahora = Timestamp.now();
    let alertasContinuoEnviadas = 0;
    let alertasDiarioEnviadas = 0;
    let alertasSilenciadas = 0;
    let choferesEvaluados = 0;

    for (const d of snap.docs) {
      const data = d.data();
      const driverDni = (data.driver_dni ?? "").toString().trim();
      if (!driverDni) continue; // sin chofer identificado → no trackeable

      const speed = typeof data.speed === "number" ? data.speed : 0;
      const patente = d.id;

      // Validar frescura del poll. Si el poller de SITRACK_POSICIONES
      // no actualizó este doc en los últimos N min, el `speed` puede
      // estar stale (camión apagado, sin señal, poll caído). Tratamos
      // ese caso como "no manejando" — no sumamos delta. Sin esto un
      // chofer que paró con speed=80 en su último poll seguía
      // sumando horas falsas hasta que vuelva a haber señal.
      //
      // Bug fixeado 2026-05-13: este check antes leía `data.polled_en`
      // pero el `sitrackPosicionPoller` escribe el campo como
      // `consultado_en` (línea ~3745). El mismatch hacía que el
      // timestamp leído fuera SIEMPRE undefined → polledHaceSegundos
      // = Infinity → pollStale = true para TODOS los snapshots →
      // speedEfectivo = 0 para TODOS los choferes → nadie acumulaba
      // jornada. Resultado: el resumen diario decía "0 excesos" hace
      // ~5 días (desde el commit `8dbb675` 2026-05-08 que introdujo
      // este check). Reportado por Santiago 2026-05-13.
      const polledEnMs =
        (data.consultado_en as Timestamp | undefined)?.toMillis() ?? 0;
      const polledHaceSegundos =
        polledEnMs > 0 ? (Date.now() - polledEnMs) / 1000 : Infinity;
      const pollStale = polledHaceSegundos > VIGILADOR_POLL_STALE_SEGUNDOS;
      const speedEfectivo = pollStale ? 0 : speed;

      choferesEvaluados++;

      const refJornada = db
        .collection("JORNADAS_CHOFER")
        .doc(`${driverDni}_${fechaArt}`);

      try {
        const result = await db.runTransaction(async (tx) => {
          const snapJ = await tx.get(refJornada);

          // Estado base — se hidrata si hay doc del día anterior con
          // jornada en curso (caso típico: chofer cruzó medianoche
          // manejando, doc del día NUEVO arranca como continuación
          // del anterior, no en cero). Sin esto, se perdían las
          // jornadas nocturnas: el doc del 13 quedaba con 2h y el
          // del 14 arrancaba en 0, ningún día llegaba a 11h30 →
          // ninguna alerta + resumen subestimado. Fix 2026-05-13.
          let segundosTotalDia = 0;
          let segundosJornadaActual = 0;
          let segundosContinuoActual = 0;
          let segundosPausaActual = 0;
          let alerta330Enviada = false;
          let alerta400Enviada = false;
          let alerta1130Enviada = false;
          let alerta1200Enviada = false;
          let avisoDescansoCortoEnviada = false;
          let descansoCortoSegundos = 0;
          let pausaObligatoriaExcedida = false;
          let jornadaDiariaExcedida = false;
          // Nuevo 2026-05-13: cuando se alcanza 12h diarias, registramos
          // el timestamp + la hora mínima de arranque calculada
          // (max(6 AM ART, fin+8h)). Usados para detectar "arranque
          // temprano" en polls posteriores y para el wording del aviso
          // de 11:30 que dice al chofer hasta qué hora frenar.
          let finJornadaAt: Timestamp | null = null;
          let horaMinArranqueAt: Timestamp | null = null;
          let alertaArranqueTempranoEnviada = false;
          let arranqueTempranoExcedido = false;
          let alerta330At: Timestamp | null = null;
          let alerta400At: Timestamp | null = null;
          let alerta1130At: Timestamp | null = null;
          let alerta1200At: Timestamp | null = null;
          let alertaArranqueTempranoAt: Timestamp | null = null;
          let avisoDescansoCortoAt: Timestamp | null = null;

          if (!snapJ.exists) {
            // Primer poll del día para este chofer. Mirar el doc del
            // día anterior — si la jornada estaba en curso, hidratar.
            const refAyer = db
              .collection("JORNADAS_CHOFER")
              .doc(`${driverDni}_${_fechaArtPrevia(fechaArt)}`);
            const snapAyer = await tx.get(refAyer);
            if (snapAyer.exists) {
              const dA = snapAyer.data() ?? {};
              segundosJornadaActual =
                (dA.segundos_jornada_actual as number) ?? 0;
              segundosContinuoActual =
                (dA.segundos_continuo_actual as number) ?? 0;
              segundosPausaActual =
                (dA.segundos_pausa_actual as number) ?? 0;
              // Compat: el campo viejo era `alerta_3_45_continua_enviada`
              // (umbral 3:45). Desde 2026-05-13 el nuevo umbral es 3:30
              // y se llama `alerta_3_30_continua_enviada`. Hidratamos
              // del nuevo si existe, sino caemos al viejo (jornadas en
              // curso al hacer el deploy no pierden el flag).
              alerta330Enviada =
                (dA.alerta_3_30_continua_enviada as boolean) ??
                (dA.alerta_3_45_continua_enviada as boolean) ?? false;
              alerta400Enviada =
                (dA.alerta_4_00_continua_enviada as boolean) ?? false;
              alerta1130Enviada =
                (dA.alerta_11_30_diaria_enviada as boolean) ?? false;
              alerta1200Enviada =
                (dA.alerta_12_00_diaria_enviada as boolean) ?? false;
              avisoDescansoCortoEnviada =
                (dA.aviso_descanso_corto_enviada as boolean) ?? false;
              descansoCortoSegundos =
                (dA.descanso_corto_segundos as number) ?? 0;
              pausaObligatoriaExcedida =
                (dA.pausa_obligatoria_excedida as boolean) ?? false;
              jornadaDiariaExcedida =
                (dA.jornada_diaria_excedida as boolean) ?? false;
              finJornadaAt =
                (dA.fin_jornada_at as Timestamp | null) ?? null;
              horaMinArranqueAt =
                (dA.hora_min_arranque_at as Timestamp | null) ?? null;
              alertaArranqueTempranoEnviada =
                (dA.alerta_arranque_temprano_enviada as boolean) ?? false;
              arranqueTempranoExcedido =
                (dA.arranque_temprano_excedido as boolean) ?? false;
            }
            tx.set(refJornada, {
              chofer_dni: driverDni,
              fecha_art: fechaArt,
              segundos_total_dia: 0,
              segundos_jornada_actual: segundosJornadaActual,
              segundos_continuo_actual: segundosContinuoActual,
              segundos_pausa_actual: segundosPausaActual,
              ultima_actualizacion_at: ahora,
              ultima_patente: patente,
              alerta_3_30_continua_enviada: alerta330Enviada,
              alerta_4_00_continua_enviada: alerta400Enviada,
              alerta_11_30_diaria_enviada: alerta1130Enviada,
              alerta_12_00_diaria_enviada: alerta1200Enviada,
              aviso_descanso_corto_enviada: avisoDescansoCortoEnviada,
              descanso_corto_segundos: descansoCortoSegundos,
              alerta_3_30_continua_at: null,
              alerta_4_00_continua_at: null,
              alerta_11_30_diaria_at: null,
              alerta_12_00_diaria_at: null,
              aviso_descanso_corto_at: null,
              alerta_arranque_temprano_at: null,
              alerta_arranque_temprano_enviada: alertaArranqueTempranoEnviada,
              arranque_temprano_excedido: arranqueTempranoExcedido,
              fin_jornada_at: finJornadaAt,
              hora_min_arranque_at: horaMinArranqueAt,
              pausa_obligatoria_excedida: pausaObligatoriaExcedida,
              jornada_diaria_excedida: jornadaDiariaExcedida,
              creado_en: ahora,
            });
            // No acumulamos en este poll (no hay delta), próximo sí.
            return {
              alertContinuo: false,
              alertContinuoLimite: false,
              alertDiario: false,
              alertDiarioLimite: false,
              alertDescansoCorto: false,
              alertArranqueTemprano: false,
              descansoCortoSegundos: 0,
              horaMinArranqueAt: null as Timestamp | null,
            };
          }

          const docJ = snapJ.data() ?? {};

          // Delta desde la última actualización, capeado para evitar
          // sumar horas si el cron estuvo caído mucho tiempo.
          const ultimaAtMs = (docJ.ultima_actualizacion_at as Timestamp)
            .toMillis();
          const deltaSegundosBruto = (ahora.toMillis() - ultimaAtMs) / 1000;
          const deltaSegundos = Math.min(
            Math.max(deltaSegundosBruto, 0),
            VIGILADOR_DELTA_MAX_SEGUNDOS
          );

          segundosTotalDia = (docJ.segundos_total_dia as number) ?? 0;
          segundosJornadaActual =
            (docJ.segundos_jornada_actual as number) ?? 0;
          segundosContinuoActual =
            (docJ.segundos_continuo_actual as number) ?? 0;
          segundosPausaActual =
            (docJ.segundos_pausa_actual as number) ?? 0;
          // Compat: leer nuevo campo `alerta_3_30_continua_enviada`
          // (umbral 3:30) o caer al viejo `alerta_3_45_continua_enviada`
          // si la jornada estaba en curso al hacer deploy.
          alerta330Enviada =
            (docJ.alerta_3_30_continua_enviada as boolean) ??
            (docJ.alerta_3_45_continua_enviada as boolean) ?? false;
          alerta400Enviada =
            (docJ.alerta_4_00_continua_enviada as boolean) ?? false;
          alerta1130Enviada =
            (docJ.alerta_11_30_diaria_enviada as boolean) ?? false;
          alerta1200Enviada =
            (docJ.alerta_12_00_diaria_enviada as boolean) ?? false;
          avisoDescansoCortoEnviada =
            (docJ.aviso_descanso_corto_enviada as boolean) ?? false;
          descansoCortoSegundos =
            (docJ.descanso_corto_segundos as number) ?? 0;
          pausaObligatoriaExcedida =
            (docJ.pausa_obligatoria_excedida as boolean) ?? false;
          jornadaDiariaExcedida =
            (docJ.jornada_diaria_excedida as boolean) ?? false;
          finJornadaAt =
            (docJ.fin_jornada_at as Timestamp | null) ?? null;
          horaMinArranqueAt =
            (docJ.hora_min_arranque_at as Timestamp | null) ?? null;
          alertaArranqueTempranoEnviada =
            (docJ.alerta_arranque_temprano_enviada as boolean) ?? false;
          arranqueTempranoExcedido =
            (docJ.arranque_temprano_excedido as boolean) ?? false;
          alerta330At =
            (docJ.alerta_3_30_continua_at as Timestamp | null) ??
            (docJ.alerta_3_45_continua_at as Timestamp | null) ?? null;
          alerta400At =
            (docJ.alerta_4_00_continua_at as Timestamp | null) ?? null;
          alerta1130At =
            (docJ.alerta_11_30_diaria_at as Timestamp | null) ?? null;
          alerta1200At =
            (docJ.alerta_12_00_diaria_at as Timestamp | null) ?? null;
          alertaArranqueTempranoAt =
            (docJ.alerta_arranque_temprano_at as Timestamp | null) ?? null;
          avisoDescansoCortoAt =
            (docJ.aviso_descanso_corto_at as Timestamp | null) ?? null;

          // Bandera local: este poll dispara el aviso de descanso
          // corto (chofer arrancó tras < 8 h de pausa, ≥ 4 h).
          let alertDescansoCorto = false;
          // Bandera local: chofer arrancó antes de la hora_min_arranque
          // calculada al cumplir 12h (regla "descansar hasta máx(6 AM,
          // fin+8h)" — Santiago 2026-05-13).
          let alertArranqueTemprano = false;
          if (speedEfectivo > VIGILADOR_UMBRAL_MOVIMIENTO_KMH) {
            // Manejando ahora.

            // Detección descanso corto (< 8 h legal Argentina): si
            // veníamos de una pausa larga (≥ 4 h, lo suficiente como
            // para ser "descanso entre jornadas" y no almuerzo) pero
            // menor al mínimo legal, avisar al chofer + sumar al
            // resumen de Molina. Solo una vez por jornada (flag
            // `aviso_descanso_corto_enviada`).
            //
            // ⚠️ Importante: chequear ANTES de los resets que ponen
            // `segundosPausaActual = 0`.
            if (
              segundosPausaActual >=
                VIGILADOR_PAUSA_MIN_PARA_DESCANSO_SEGUNDOS &&
              segundosPausaActual < VIGILADOR_DESCANSO_JORNADA_SEGUNDOS &&
              !avisoDescansoCortoEnviada
            ) {
              alertDescansoCorto = true;
              avisoDescansoCortoEnviada = true;
              descansoCortoSegundos = Math.floor(segundosPausaActual);
            }

            // Detección arranque temprano (post 12h): si la jornada
            // anterior llegó al límite de 12h y el chofer arranca
            // antes de la hora mínima calculada (max 6 AM ART /
            // fin+8h), aviso al chofer "descanso insuficiente" + sumar
            // a Molina vía flag `arranque_temprano_excedido`. Solo
            // una vez por evento (flag) — sino cada poll cada 5 min
            // sería spam.
            //
            // Ojo: chequear ANTES del reset por 8h, sino cuando el
            // chofer recién arranca tras 7h59min de descanso, el
            // segundosPausaActual viene con valor real y queremos
            // detectarlo. (Si ya cumplió 8h, el reset abajo limpia
            // horaMinArranqueAt y este chequeo no aplica.)
            if (
              horaMinArranqueAt != null &&
              !alertaArranqueTempranoEnviada &&
              ahora.toMillis() < horaMinArranqueAt.toMillis()
            ) {
              alertArranqueTemprano = true;
              alertaArranqueTempranoEnviada = true;
              arranqueTempranoExcedido = true;
            }

            // Reset del CONTINUO: pausa de 10 min sin movimiento.
            if (segundosPausaActual >= VIGILADOR_PAUSA_RESET_SEGUNDOS) {
              segundosContinuoActual = 0;
              alerta330Enviada = false;
              alerta400Enviada = false;
            }
            // Reset de la JORNADA: pausa de 8h (descanso entre
            // jornadas, mínimo Argentina). Resetea jornada_actual y
            // todas las flags de alerta diaria + el flag de exceso
            // continuo + flag/segundos de descanso corto + datos de
            // post-jornada (la jornada nueva arranca con todo limpio).
            if (segundosPausaActual >= VIGILADOR_DESCANSO_JORNADA_SEGUNDOS) {
              segundosJornadaActual = 0;
              alerta1130Enviada = false;
              alerta1200Enviada = false;
              avisoDescansoCortoEnviada = false;
              descansoCortoSegundos = 0;
              jornadaDiariaExcedida = false;
              pausaObligatoriaExcedida = false;
              finJornadaAt = null;
              horaMinArranqueAt = null;
              alertaArranqueTempranoEnviada = false;
              arranqueTempranoExcedido = false;
            }
            segundosPausaActual = 0;
            segundosContinuoActual += deltaSegundos;
            segundosTotalDia += deltaSegundos;
            segundosJornadaActual += deltaSegundos;
          } else {
            // Parado o moviéndose lento (< umbral).
            segundosPausaActual += deltaSegundos;
            // continuo, jornada y total NO se mueven.
          }

          // Chequear umbrales de alerta. `alertDescansoCorto` y
          // `alertArranqueTemprano` ya vienen seteados del bloque
          // speed>umbral.
          let alertContinuo = false;
          let alertContinuoLimite = false;
          let alertDiario = false;
          let alertDiarioLimite = false;

          // Aviso preventivo a 3:30h (faltan 30 min para el límite 4h).
          if (
            segundosContinuoActual >= VIGILADOR_CONTINUO_ALERTA_SEGUNDOS &&
            !alerta330Enviada
          ) {
            alertContinuo = true;
            alerta330Enviada = true;
          }
          // Aviso fuerte a 4h continuas (límite legal alcanzado, debió
          // haber parado). Va al chofer + flag `pausa_obligatoria_excedida`
          // que ya levanta el resumen de Molina sin necesidad de WhatsApp
          // directo (Santiago 2026-05-13).
          if (
            segundosContinuoActual >= VIGILADOR_CONTINUO_LIMITE_SEGUNDOS &&
            !alerta400Enviada
          ) {
            alertContinuoLimite = true;
            alerta400Enviada = true;
          }
          if (segundosContinuoActual >= VIGILADOR_CONTINUO_LIMITE_SEGUNDOS) {
            pausaObligatoriaExcedida = true;
          }

          // Las alertas diarias evalúan contra `segundos_jornada_actual`
          // (no contra `segundos_total_dia`). El total_dia es solo para
          // el resumen del día calendario; la jornada_actual es lo que
          // realmente importa para las alertas legales (puede cruzar
          // medianoche).
          if (
            segundosJornadaActual >= VIGILADOR_DIARIO_ALERTA_SEGUNDOS &&
            !alerta1130Enviada
          ) {
            alertDiario = true;
            alerta1130Enviada = true;
          }
          if (
            segundosJornadaActual >= VIGILADOR_DIARIO_LIMITE_SEGUNDOS &&
            !alerta1200Enviada
          ) {
            alertDiarioLimite = true;
            alerta1200Enviada = true;
          }
          if (segundosJornadaActual >= VIGILADOR_DIARIO_LIMITE_SEGUNDOS) {
            jornadaDiariaExcedida = true;
            // Primer poll que detecta las 12h: registramos el fin de
            // jornada y la hora mínima de arranque (max 6 AM ART /
            // fin+8h). Estos campos los usa el aviso 11:30 (en realidad
            // recalculamos ahí con la fecha actual + 30 min) y la
            // detección de arranque temprano del próximo poll.
            if (finJornadaAt == null) {
              finJornadaAt = ahora;
              const horaMinArranque = _calcularHoraMinArranque(
                ahora.toDate()
              );
              horaMinArranqueAt = Timestamp.fromDate(horaMinArranque);
            }
          }

          tx.update(refJornada, {
            segundos_total_dia: segundosTotalDia,
            segundos_jornada_actual: segundosJornadaActual,
            segundos_continuo_actual: segundosContinuoActual,
            segundos_pausa_actual: segundosPausaActual,
            ultima_actualizacion_at: ahora,
            ultima_patente: patente,
            alerta_3_30_continua_enviada: alerta330Enviada,
            alerta_4_00_continua_enviada: alerta400Enviada,
            alerta_11_30_diaria_enviada: alerta1130Enviada,
            alerta_12_00_diaria_enviada: alerta1200Enviada,
            aviso_descanso_corto_enviada: avisoDescansoCortoEnviada,
            alerta_arranque_temprano_enviada: alertaArranqueTempranoEnviada,
            arranque_temprano_excedido: arranqueTempranoExcedido,
            descanso_corto_segundos: descansoCortoSegundos,
            alerta_3_30_continua_at: alertContinuo ? ahora : alerta330At,
            alerta_4_00_continua_at: alertContinuoLimite ? ahora : alerta400At,
            alerta_11_30_diaria_at: alertDiario ? ahora : alerta1130At,
            alerta_12_00_diaria_at: alertDiarioLimite ? ahora : alerta1200At,
            aviso_descanso_corto_at: alertDescansoCorto ?
              ahora :
              avisoDescansoCortoAt,
            alerta_arranque_temprano_at: alertArranqueTemprano ?
              ahora :
              alertaArranqueTempranoAt,
            fin_jornada_at: finJornadaAt,
            hora_min_arranque_at: horaMinArranqueAt,
            pausa_obligatoria_excedida: pausaObligatoriaExcedida,
            jornada_diaria_excedida: jornadaDiariaExcedida,
          });

          return {
            alertContinuo,
            alertContinuoLimite,
            alertDiario,
            alertDiarioLimite,
            alertDescansoCorto,
            alertArranqueTemprano,
            descansoCortoSegundos,
            horaMinArranqueAt,
          };
        });

        // Si el chofer está silenciado (comando /silenciar via
        // WhatsApp) NO encolamos los avisos — pero la jornada SÍ
        // se sigue acumulando arriba (la transacción ya se commiteó
        // con los nuevos segundos). El flag de "alerta enviada" del
        // doc tampoco se toca para este path silenciado, así si se
        // levanta el silencio antes del descanso de 8h igual le
        // llega cuando vuelva a cruzar el umbral en otro poll.
        const estaSilenciado = silenciadosSet.has(driverDni);
        const hayAlgunaAlerta = result.alertContinuo ||
          result.alertContinuoLimite || result.alertDiario ||
          result.alertDiarioLimite || result.alertDescansoCorto ||
          result.alertArranqueTemprano;
        if (estaSilenciado && hayAlgunaAlerta) {
          alertasSilenciadas++;
          logger.info("[vigiladorJornadaChofer] aviso silenciado", {
            driverDni,
            patente,
            tipos: [
              result.alertContinuo ? "continuo330" : null,
              result.alertContinuoLimite ? "continuo400" : null,
              result.alertDiario ? "diario1130" : null,
              result.alertDiarioLimite ? "diario1200" : null,
              result.alertDescansoCorto ? "descansoCorto" : null,
              result.alertArranqueTemprano ? "arranqueTemprano" : null,
            ].filter(Boolean),
          });
        } else {
          if (result.alertContinuo) {
            await _encolarAvisoPausaContinua(driverDni, patente);
            alertasContinuoEnviadas++;
          }
          if (result.alertContinuoLimite) {
            await _encolarAvisoLimiteContinuo(driverDni, patente);
            alertasContinuoEnviadas++;
          }
          if (result.alertDiario) {
            await _encolarAvisoLimiteDiario(
              driverDni, patente, result.horaMinArranqueAt
            );
            alertasDiarioEnviadas++;
          }
          if (result.alertDiarioLimite) {
            await _encolarAvisoJornadaExcedida(driverDni, patente);
            alertasDiarioEnviadas++;
          }
          if (result.alertDescansoCorto) {
            await _encolarAvisoDescansoCorto(
              driverDni,
              patente,
              result.descansoCortoSegundos
            );
            alertasDiarioEnviadas++;
          }
          if (result.alertArranqueTemprano) {
            await _encolarAvisoArranqueTemprano(
              driverDni, patente, result.horaMinArranqueAt
            );
            alertasDiarioEnviadas++;
          }
        }
      } catch (e) {
        logger.warn("[vigiladorJornadaChofer] fallo procesar chofer", {
          driverDni,
          patente,
          error: (e as Error).message,
        });
      }
    }

    logger.info("[vigiladorJornadaChofer] OK", {
      choferesEvaluados,
      alertasContinuoEnviadas,
      alertasDiarioEnviadas,
      alertasSilenciadas,
      silenciadosCount: silenciadosSet.size,
    });
  }
);

/**
 * Lee `BOT_SILENCIADOS_CHOFER` y devuelve el set de DNIs que están
 * actualmente silenciados (silenciado_hasta > now). Pensado para
 * llamarse 1 vez al iniciar el ciclo del vigilador.
 *
 * Si la query falla, devuelve set vacío (no rompemos el vigilador
 * por un fallo de read — peor caso seguimos mandando avisos).
 */
async function _cargarSilenciadosVigilador(): Promise<Set<string>> {
  try {
    const ahora = Timestamp.now();
    const snap = await db
      .collection("BOT_SILENCIADOS_CHOFER")
      .where("silenciado_hasta", ">", ahora)
      .limit(500)
      .get();
    const set = new Set<string>();
    for (const d of snap.docs) {
      set.add(d.id);
    }
    return set;
  } catch (e) {
    logger.warn("[vigiladorJornadaChofer] no pude cargar silenciados", {
      error: (e as Error).message,
    });
    return new Set();
  }
}

/**
 * Cron que detecta silencios EXPIRADOS y notifica al chofer que sus
 * notificaciones se reanudan + borra el doc de
 * `BOT_SILENCIADOS_CHOFER`.
 *
 * Pedido Santiago 2026-05-13: cuando el silencio se cumple, el
 * chofer tiene que recibir un mensaje de "notificaciones reanudadas".
 * Si no, el chofer no se entera de cuándo vuelven los avisos.
 *
 * Por qué no en el vigilador: el vigilador corre cada 5 min y es
 * tiempo-crítico (alertas de jornada). Esto puede esperar hasta 10
 * min sin problema y mantenemos las funciones desacopladas.
 *
 * Path "manual desilenciar": si el admin corre `/desilenciar DNI`
 * antes de que expire, el bot mismo encola la reanudación y borra
 * el doc — este cron nunca lo ve. Eso es OK: ambos paths terminan en
 * el mismo estado (mensaje encolado + doc borrado).
 */
export const procesarSilenciadosExpirados = onSchedule(
  {
    schedule: "every 10 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    const ahora = Timestamp.now();
    let snap;
    try {
      snap = await db
        .collection("BOT_SILENCIADOS_CHOFER")
        .where("silenciado_hasta", "<=", ahora)
        .limit(100)
        .get();
    } catch (e) {
      logger.warn("[procesarSilenciadosExpirados] query falló", {
        error: (e as Error).message,
      });
      return;
    }
    if (snap.empty) {
      logger.debug("[procesarSilenciadosExpirados] sin expirados");
      return;
    }
    let notificados = 0;
    let saltados = 0;
    for (const d of snap.docs) {
      const data = d.data();
      const dni = (data.chofer_dni || d.id).toString();
      try {
        await _encolarAvisoSilencioReanudado(dni);
        notificados++;
      } catch (e) {
        logger.warn("[procesarSilenciadosExpirados] no encolé reanudación", {
          dni,
          error: (e as Error).message,
        });
        saltados++;
        // Igual borramos el doc — sino el cron lo ve infinitas veces.
        // Si el chofer no tiene teléfono o está inactivo, el aviso no
        // tiene a dónde ir y reintentar no ayuda.
      }
      try {
        await d.ref.delete();
      } catch (e) {
        logger.warn("[procesarSilenciadosExpirados] no borré doc", {
          dni,
          error: (e as Error).message,
        });
      }
    }
    logger.info("[procesarSilenciadosExpirados] OK", {
      notificados,
      saltados,
      total: snap.size,
    });
  }
);

async function _encolarAvisoSilencioReanudado(
  choferDni: string
): Promise<void> {
  const empSnap = await db.collection("EMPLEADOS").doc(choferDni).get();
  if (!empSnap.exists) {
    throw new Error(`EMPLEADOS/${choferDni} no existe`);
  }
  const empData = empSnap.data() ?? {};
  if (empData.ACTIVO === false) {
    throw new Error("empleado inactivo");
  }
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") {
    throw new Error("sin TELEFONO");
  }
  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || _primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

  const mensaje =
    `${saludo},\n\n` +
    "Se cumplió el plazo de silencio.\n\n" +
    "*Las notificaciones automáticas del bot vuelven a estar activas* " +
    "(avisos de jornada, descansos, etc.).\n\n" +
    BANNER_TESTING +
    "_Coopertrans Móvil — Mensaje automático._";

  await db.collection("COLA_WHATSAPP").add({
    telefono: tel,
    mensaje,
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    expira_en: _expiraEnMinutos(60),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "silencio_reanudado",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: choferDni,
    campo_base: "BOT_SILENCIADO",
    admin_dni: "BOT",
    admin_nombre: "Bot silenciador (cron)",
  });
}

// Encola aviso preventivo al chofer cuando lleva 3:30h continuas de
// manejo (faltan 30 min para el límite de 4h). Antes era a las 3:45h
// con 15 min de margen — Santiago bumpeó el aviso a 3:30 (30 min de
// margen) el 2026-05-13 para que el chofer tenga tiempo real de
// buscar un lugar seguro donde parar.
async function _encolarAvisoPausaContinua(
  choferDni: string,
  patente: string
): Promise<void> {
  const empSnap = await db.collection("EMPLEADOS").doc(choferDni).get();
  if (!empSnap.exists) return;
  const empData = empSnap.data() ?? {};
  if (empData.ACTIVO === false) return;
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") return;

  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || _primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

  // Mínimo 6 variantes anti-baneo (decisión 2026-05-09).
  const variantes = [
    `${saludo},\n\n` +
      "Llevás 3 horas y 30 minutos manejando. Tenés 30 min para " +
      "buscar un lugar seguro y descansar al menos 15 min.\n\n" +
      `Buscá dónde parar el ${patente} y tomate la pausa antes de ` +
      "que se cumplan las 4 h continuas.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      "Aviso: a 3:30h de manejo continuo. En 30 min llega el límite " +
      "de 4 h — tenés tiempo para buscar dónde parar.\n\n" +
      `Frená el ${patente} en un lugar seguro y descansá mínimo ` +
      "15 min antes de seguir.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, atención.\n\n` +
      "Tu manejo continuo llegó a 3:30. Te quedan 30 min para " +
      "buscar un lugar seguro donde parar al menos 15 min.\n\n" +
      `Estacioná el ${patente} y descansá antes de retomar.\n\n` +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      "Te paso un aviso desde la oficina: tenés 30 min antes de " +
      "cumplir las 4 horas continuas. Buscá un lugar seguro para parar.\n\n" +
      `Frená el ${patente} y descansá mínimo 15 min — después podés ` +
      "seguir.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, te aviso.\n\n` +
      "Estás a 3:30 de manejo continuo. En media hora se cumple el " +
      "tope de 4 h.\n\n" +
      `Buscá dónde estacionar el ${patente} y descansá al menos ` +
      "15 min.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      "Por norma, cada 4 h continuas hay que parar. Llevás 3:30 — " +
      "tenés 30 min para buscar un lugar seguro.\n\n" +
      `Frená el ${patente} mínimo 15 min antes de retomar.\n\n` +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
  ];
  const mensaje = variantes[_rrPick(variantes.length)];

  await db.collection("COLA_WHATSAPP").add({
    telefono: tel,
    mensaje,
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    expira_en: _expiraEnMinutos(TTL_PAUSA_CONTINUA_MIN),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_pausa_continua",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: choferDni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada",
    alert_patente: patente,
  });
}

// Encola aviso fuerte al chofer cuando alcanzó las 4h continuas sin
// pausa — ya está incumpliendo, lo penaliza el resumen de Molina vía
// flag `pausa_obligatoria_excedida`. Pedido Santiago 2026-05-13.
async function _encolarAvisoLimiteContinuo(
  choferDni: string,
  patente: string
): Promise<void> {
  const empSnap = await db.collection("EMPLEADOS").doc(choferDni).get();
  if (!empSnap.exists) return;
  const empData = empSnap.data() ?? {};
  if (empData.ACTIVO === false) return;
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") return;

  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || _primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

  const variantes = [
    `${saludo},\n\n` +
      "Cumpliste las *4 horas de manejo continuo* sin pausa.\n\n" +
      "*Penalizado por falta de descanso obligatorio.*\n\n" +
      `Frená el ${patente} ahora en un lugar seguro y descansá mínimo ` +
      "15 min antes de seguir — el incumplimiento queda registrado.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      "Atención: superaste las 4 h continuas al volante sin parar.\n\n" +
      "*Quedó registrado como falta de descanso obligatorio.*\n\n" +
      `Estacioná el ${patente} ahora y descansá al menos 15 min ` +
      "antes de retomar el viaje.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, importante.\n\n` +
      "Llegaste a las 4 h continuas de manejo. Por norma debés parar.\n\n" +
      "*Penalizado por incumplimiento del descanso obligatorio.*\n\n" +
      `Frená el ${patente} en un lugar seguro y tomate la pausa.\n\n` +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
  ];
  const mensaje = variantes[_rrPick(variantes.length)];

  await db.collection("COLA_WHATSAPP").add({
    telefono: tel,
    mensaje,
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    expira_en: _expiraEnMinutos(TTL_PAUSA_CONTINUA_MIN),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_limite_continuo",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: choferDni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada",
    alert_patente: patente,
  });
}

// Encola aviso al chofer cuando llega a 11:30h de manejo en la
// jornada actual. Calcula dinámicamente hasta qué hora tiene que
// frenar — `max(6 AM ART próximo, fin_jornada + 8h)`. La hora se
// inserta en el mensaje para que el chofer sepa cuándo puede arrancar
// de nuevo (Santiago 2026-05-13). El parámetro horaMinArranqueAt
// puede ser null si la transacción no lo precalculó (caso borde:
// llegó a 11:30 pero todavía no a 12h, así que no tenemos fin_jornada
// real); en ese caso lo calculamos asumiendo que cumple las 12h en 30
// min (fin = ahora + 30 min).
async function _encolarAvisoLimiteDiario(
  choferDni: string,
  patente: string,
  horaMinArranqueAt: Timestamp | null
): Promise<void> {
  const empSnap = await db.collection("EMPLEADOS").doc(choferDni).get();
  if (!empSnap.exists) return;
  const empData = empSnap.data() ?? {};
  if (empData.ACTIVO === false) return;
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") return;

  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || _primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

  // Si la transacción no nos pasó horaMinArranque (todavía no llegó
  // a 12h, pero estamos en 11:30), proyectamos el fin como ahora+30min
  // y calculamos. Así el chofer ya sabe cuál sería su hora de arranque
  // si sigue manejando hasta el límite.
  const finProyectado = horaMinArranqueAt != null ?
    null :
    new Date(Date.now() + 30 * 60 * 1000);
  const horaMinArranque = horaMinArranqueAt != null ?
    horaMinArranqueAt.toDate() :
    _calcularHoraMinArranque(finProyectado!);
  const horaFmt = _fmtHoraArt(horaMinArranque);

  // Mínimo 6 variantes anti-baneo (decisión 2026-05-09).
  const variantes = [
    `${saludo},\n\n` +
      "Llevás 11 h y 30 min de manejo en la jornada. En 30 min llegás " +
      "al límite de 12 h.\n\n" +
      `Buscá un lugar seguro para parar el ${patente}. ` +
      `*Tenés que descansar hasta las ${horaFmt} ART como mínimo.*\n\n` +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      "Aviso: estás cerca del límite diario de 12 h de manejo. Te " +
      "quedan 30 min.\n\n" +
      `Frená el ${patente} en un lugar seguro y descansá hasta las ` +
      `*${horaFmt} ART* mínimo (8 h o hasta la mañana, lo que sea más).\n\n` +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, atención.\n\n` +
      "Tu jornada llegó a 11:30 al volante. En 30 min cumplís el tope " +
      "de 12 h.\n\n" +
      `Estacioná el ${patente} en un lugar seguro — descansá hasta ` +
      `las *${horaFmt} ART* y retomás después.\n\n` +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      "Aviso de jornada: 30 min para llegar al máximo diario de 12 h.\n\n" +
      `Buscá dónde parar el ${patente} y descansá hasta las ` +
      `*${horaFmt} ART* mínimo.\n\n` +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, recordatorio.\n\n` +
      "Llevás 11h30 hoy. En 30 min llegás al máximo permitido por " +
      "jornada.\n\n" +
      `Frená el ${patente} en un lugar seguro. *No podés volver a ` +
      `arrancar antes de las ${horaFmt} ART.*\n\n` +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      "Por norma, después de 12 h en la jornada hay que parar. Te " +
      "quedan 30 min.\n\n" +
      `Buscá un lugar seguro para el ${patente}. *Hora mínima de ` +
      `arranque: ${horaFmt} ART.*\n\n` +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
  ];
  const mensaje = variantes[_rrPick(variantes.length)];

  await db.collection("COLA_WHATSAPP").add({
    telefono: tel,
    mensaje,
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    expira_en: _expiraEnMinutos(TTL_LIMITE_DIARIO_MIN),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_limite_diario",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: choferDni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada",
    alert_patente: patente,
    hora_min_arranque_at: Timestamp.fromDate(horaMinArranque),
  });
}

/**
 * Encola el aviso "ya excediste el límite diario de 12 horas" — se
 * dispara cuando `segundos_jornada_actual` cruza las 12h. Antes solo
 * había aviso a las 11h30 ("te quedan 30 min") y el flag de exceso
 * para el resumen diario; al pasar las 12h el chofer NO recibía
 * nada en el momento, solo Molina al día siguiente.
 *
 * Diseño:
 *   - 6 variantes anti-baneo, igual que las otras alertas al chofer.
 *   - Tono más firme que el aviso 11:30 (ya es exceso, no faltan
 *     minutos).
 *   - TTL corto (60 min): si el bot estaba caído y se manda 1h
 *     después, igual sigue vigente; si está caído más, el aviso
 *     pierde sentido (el chofer ya está descansando o sigue
 *     manejando en exceso y no hace falta el avisado tardío).
 */
async function _encolarAvisoJornadaExcedida(
  choferDni: string,
  patente: string
): Promise<void> {
  const empSnap = await db.collection("EMPLEADOS").doc(choferDni).get();
  if (!empSnap.exists) return;
  const empData = empSnap.data() ?? {};
  if (empData.ACTIVO === false) return;
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") return;

  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || _primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

  // Wording reforzado el 2026-05-13: "superadas las 12h de conducción
  // diaria por favor detenerse para evitar penalizaciones más graves"
  // (pedido textual de Santiago).
  const variantes = [
    `${saludo},\n\n` +
      "*Superadas las 12 h de conducción diaria.* Por favor detené el " +
      `${patente} en un lugar seguro para evitar penalizaciones más ` +
      "graves.\n\n" +
      "La jornada ya terminó — tenés que descansar hasta cumplir el " +
      "mínimo legal antes de retomar.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      "Aviso urgente: *superaste las 12 h diarias al volante*. Detené " +
      `el ${patente} ya en un lugar seguro para evitar penalizaciones ` +
      "más graves.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, atención.\n\n` +
      "*Llegaste al máximo diario de 12 h de conducción.* Estacioná el " +
      `${patente} en un lugar seguro — cualquier kilómetro de más ` +
      "queda registrado como falta.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      "*Excediste las 12 h diarias permitidas.* Es obligatorio parar y " +
      "descansar para evitar penalizaciones más graves.\n\n" +
      `Buscá dónde estacionar el ${patente} y cerrá la jornada.\n\n` +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
  ];
  const mensaje = variantes[_rrPick(variantes.length)];

  await db.collection("COLA_WHATSAPP").add({
    telefono: tel,
    mensaje,
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    expira_en: _expiraEnMinutos(TTL_JORNADA_EXCEDIDA_MIN),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_excedida",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: choferDni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada",
    alert_patente: patente,
  });
}

/**
 * Encola aviso "descanso insuficiente — arrancaste antes de la hora
 * mínima permitida". Se dispara cuando el chofer cumplió 12h en la
 * jornada anterior y vuelve a manejar antes de `hora_min_arranque`
 * (= max(6 AM ART próximo, fin_jornada + 8h)). Pedido Santiago
 * 2026-05-13: la regla operativa de Vecchi es que si cerrás 12h, no
 * podés arrancar antes de las 6 AM (o más tarde si las 6 AM no
 * cubren las 8h legales).
 *
 * El flag `arranque_temprano_excedido` que setea la transacción es
 * leído por `resumenExcesosJornadaDiario` y aparece en el reporte de
 * Molina al día siguiente.
 */
async function _encolarAvisoArranqueTemprano(
  choferDni: string,
  patente: string,
  horaMinArranqueAt: Timestamp | null
): Promise<void> {
  const empSnap = await db.collection("EMPLEADOS").doc(choferDni).get();
  if (!empSnap.exists) return;
  const empData = empSnap.data() ?? {};
  if (empData.ACTIVO === false) return;
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") return;

  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || _primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

  const horaFmt = horaMinArranqueAt != null ?
    _fmtHoraArt(horaMinArranqueAt.toDate()) :
    "(sin calcular)";

  const variantes = [
    `${saludo},\n\n` +
      "*Descanso insuficiente.* Cerraste tu jornada de 12 h y arrancaste " +
      "antes de la hora mínima permitida.\n\n" +
      `Hora mínima de arranque: *${horaFmt} ART*. Frená el ${patente} ` +
      "y descansá hasta esa hora.\n\n" +
      "El incumplimiento queda registrado en el resumen diario.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      "*Aviso: estás manejando sin haber completado el descanso " +
      "obligatorio.*\n\n" +
      `No podías volver a arrancar hasta las *${horaFmt} ART*.\n\n` +
      `Detené el ${patente} cuanto antes en un lugar seguro — el ` +
      "incumplimiento ya está registrado.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, atención.\n\n` +
      "Arrancaste antes de cumplir el descanso mínimo después de las " +
      "12 h de la jornada anterior.\n\n" +
      `Hora mínima: *${horaFmt} ART*. Frená el ${patente} y descansá ` +
      "hasta esa hora — la falta queda registrada para Seg e Higiene.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
  ];
  const mensaje = variantes[_rrPick(variantes.length)];

  await db.collection("COLA_WHATSAPP").add({
    telefono: tel,
    mensaje,
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    expira_en: _expiraEnMinutos(60),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_arranque_temprano",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: choferDni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada",
    alert_patente: patente,
    hora_min_arranque_at: horaMinArranqueAt,
  });
}

/**
 * Calcula la hora mínima de arranque después de cumplir 12h diarias.
 * Regla operativa Vecchi (Santiago 2026-05-13):
 *   `max(próximo 6 AM ART, fin_jornada + 8 h legales)`
 *
 * Casos:
 *   - Fin a las 20:00 ART → 6 AM del día siguiente (10h descansando ≥ 8h).
 *   - Fin a las 02:00 ART → 10:00 ART del mismo día (8h después; no
 *     alcanzan las 6 AM porque solo serían 4h de descanso).
 *
 * ART es UTC-3 fijo (sin DST en Argentina desde 2009), así que no
 * hace falta una librería de TZ — basta con offset estático.
 */
function _calcularHoraMinArranque(finJornadaAt: Date): Date {
  const ART_OFFSET_MS = 3 * 3600 * 1000; // ART = UTC-3
  // Día calendario ART de fin_jornada (representado como UTC).
  const finArt = new Date(finJornadaAt.getTime() - ART_OFFSET_MS);
  // {VIGILADOR_HORA_MIN_ARRANQUE_HORA_ART}:00 ART de ese día calendario
  // (default 06:00).
  const seisAmArtMs = Date.UTC(
    finArt.getUTCFullYear(),
    finArt.getUTCMonth(),
    finArt.getUTCDate(),
    VIGILADOR_HORA_MIN_ARRANQUE_HORA_ART, 0, 0, 0
  );
  // Convertir 6 AM ART a UTC real (sumar offset).
  let proximo6AmUtc = seisAmArtMs + ART_OFFSET_MS;
  // Si ya pasaron las 6 AM ART de ese día, saltar al día siguiente.
  if (proximo6AmUtc <= finJornadaAt.getTime()) {
    proximo6AmUtc += 24 * 3600 * 1000;
  }
  const finMas8h = finJornadaAt.getTime() + 8 * 3600 * 1000;
  return new Date(Math.max(proximo6AmUtc, finMas8h));
}

/**
 * Formatea HH:MM ART de un Date UTC. Usado en los avisos al chofer
 * para mostrar la hora límite de arranque calculada por
 * `_calcularHoraMinArranque`. Si la hora cae mañana, agregamos
 * sufijo " (mañana)" para evitar confusión cuando el chofer recibe
 * el mensaje a las 23:50 y la hora es 06:00.
 */
function _fmtHoraArt(d: Date): string {
  const fmt = new Intl.DateTimeFormat("es-AR", {
    timeZone: "America/Argentina/Buenos_Aires",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const horaStr = fmt.format(d);
  // ¿Es de mañana relativo a "ahora"? Si la diferencia es > 12h o
  // la fecha calendario ART es distinta a la de hoy, agregamos "(mañana)".
  const diaArtTarget = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).format(d);
  const diaArtHoy = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date());
  if (diaArtTarget !== diaArtHoy) {
    return `${horaStr} (${diaArtTarget})`;
  }
  return horaStr;
}

/**
 * Encola el aviso "arrancaste con menos de 8 h de descanso entre
 * jornadas" — se dispara la primera vez que el chofer maneja tras
 * una pausa de [4 h, 8 h). El mínimo legal Argentina (Ley 24653
 * art. 53) son 8 h; si Sebas terminó ayer a las 23:00 y arrancó hoy
 * a las 04:00 (5 h de descanso) cae en ese rango.
 *
 * Pausas más cortas que 4 h se consideran intra-jornada (almuerzo
 * largo, espera de carga) y no disparan este aviso. Pausas mayores
 * a 8 h ya son descanso válido entre jornadas.
 */
async function _encolarAvisoDescansoCorto(
  choferDni: string,
  patente: string,
  descansoSegundos: number
): Promise<void> {
  const empSnap = await db.collection("EMPLEADOS").doc(choferDni).get();
  if (!empSnap.exists) return;
  const empData = empSnap.data() ?? {};
  if (empData.ACTIVO === false) return;
  const tel = (empData.TELEFONO ?? "").toString().trim();
  if (!tel || tel === "-") return;

  const apodo = (empData.APODO ?? "").toString().trim();
  const nombreFull = (empData.NOMBRE ?? "").toString().trim();
  const saludoNombre = apodo || _primerNombre(nombreFull) || "";
  const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

  const horas = Math.floor(descansoSegundos / 3600);
  const minutos = Math.floor((descansoSegundos % 3600) / 60);
  const descansoStr = `${horas}h ${minutos.toString().padStart(2, "0")}m`;

  // 6 variantes anti-baneo igual que los otros avisos al chofer.
  const variantes = [
    `${saludo},\n\n` +
      `Arrancaste la jornada con ${descansoStr} de descanso desde la ` +
      "última vez que manejaste. El mínimo legal son 8 horas.\n\n" +
      "Tenelo en cuenta para hoy — si te sentís cansado, parar a " +
      "descansar.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      `Aviso: tu descanso entre jornadas fue de ${descansoStr}. La ` +
      "norma legal pide 8 h mínimo.\n\n" +
      `Manejá con precaución el ${patente}, sobre todo en las ` +
      "primeras horas.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, atención.\n\n` +
      `Estás arrancando la jornada con ${descansoStr} desde la ` +
      "anterior — menos de 8 horas. Por norma, el descanso " +
      "obligatorio entre jornadas es 8 horas como mínimo.\n\n" +
      "Si te sentís cansado, frená a descansar.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      `Tu descanso entre jornadas fue de ${descansoStr}. El mínimo ` +
      "legal son 8 h — estás por debajo.\n\n" +
      `Manejá con precaución el ${patente}. Si necesitás parar, ` +
      "buscá un lugar seguro y descansá.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}, recordatorio.\n\n` +
      `Arrancaste la jornada con ${descansoStr} de descanso. La ley ` +
      "pide 8 h entre jornadas — quedaste corto.\n\n" +
      `Tomalo en cuenta hoy con el ${patente}. Si te sentís cansado, ` +
      "parar.\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
    `${saludo}.\n\n` +
      "Por norma de manejo, entre jornadas hay que descansar 8 horas " +
      `mínimo. Vos descansaste ${descansoStr}.\n\n` +
      `Cuidado con el ${patente} hoy — si te sentís cansado, frená.\n\n` +
      BANNER_TESTING +
      "_Coopertrans Móvil — Mensaje automático._",
  ];
  const mensaje = variantes[_rrPick(variantes.length)];

  await db.collection("COLA_WHATSAPP").add({
    telefono: tel,
    mensaje,
    estado: "PENDIENTE",
    encolado_en: FieldValue.serverTimestamp(),
    expira_en: _expiraEnMinutos(TTL_DESCANSO_CORTO_MIN),
    enviado_en: null,
    error: null,
    intentos: 0,
    origen: "jornada_descanso_corto",
    destinatario_coleccion: "EMPLEADOS",
    destinatario_id: choferDni,
    campo_base: "JORNADA",
    admin_dni: "BOT",
    admin_nombre: "Bot vigilador jornada",
    alert_patente: patente,
    descanso_segundos: descansoSegundos,
  });
}

/**
 * Devuelve la fecha ART del día anterior a la fecha dada
 * (formato YYYY-MM-DD). Usada para hidratar el doc nuevo de
 * `JORNADAS_CHOFER` desde el doc del día anterior cuando una
 * jornada cruza medianoche.
 */
function _fechaArtPrevia(fechaArt: string): string {
  // Parseamos como UTC para evitar offsets locales. La hora 12:00 da
  // margen contra cualquier corrimiento de timezone al restar 1 día.
  const d = new Date(`${fechaArt}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  const yyyy = d.getUTCFullYear().toString();
  const mm = (d.getUTCMonth() + 1).toString().padStart(2, "0");
  const dd = d.getUTCDate().toString().padStart(2, "0");
  return `${yyyy}-${mm}-${dd}`;
}

// ============================================================================
// avisoFinJornadaNocturna — aviso 23:30 "buscá lugar para descansar"
// ============================================================================
//
// Cron diario a las 23:30 ART. Avisa a todos los choferes con ignición
// activa (manejando) que la jornada está por terminar — los choferes
// no pueden conducir 00:00–06:00 (decisión operativa Vecchi).
//
// ACTIVADO el 2026-05-14 (Santiago). El bot tiene WORKING_HOURS_END=24
// que cubre las 23:30 ART, así que el mensaje sale en el momento.
// El TTL es 60 min — si por algún motivo el bot está caído, el aviso
// expira a las 00:30 y no se manda fuera de tiempo.
//
// Filtros defensivos:
//   - ignition === true (chofer está manejando ahora).
//   - driverDni no vacío (chofer identificado por iButton).
//   - poll Sitrack reciente (consultado_en hace ≤ 10 min, sino el
//     snapshot puede estar stale y mandar avisos a choferes que ya
//     pararon hace rato).
//   - empleado activo + con TELEFONO.
//
// Anti-baneo: 6 variantes de mensaje rotadas con _rrPick. WhatsApp
// detecta envíos masivos del mismo texto a múltiples destinatarios
// como spam → ban risk si todos reciben el mismo string.

export const avisoFinJornadaNocturna = onSchedule(
  {
    schedule: "30 23 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    if (!AVISO_NOCTURNO_ACTIVO) {
      logger.info("[avisoFinJornadaNocturna] flag apagado, skip");
      return;
    }

    const snap = await db.collection("SITRACK_POSICIONES").get();
    let avisados = 0;
    let descartadosPollStale = 0;

    for (const d of snap.docs) {
      const data = d.data();
      const ignition = data.ignition === true;
      const driverDni = (data.driver_dni ?? "").toString().trim();
      if (!ignition || !driverDni) continue;

      // Check de poll stale: si el último poll Sitrack es viejo (> 10
      // min), no podemos confiar en `ignition === true` — el chofer
      // puede haber apagado hace rato. Mismo umbral que el vigilador
      // jornada (VIGILADOR_POLL_STALE_SEGUNDOS).
      const polledEnMs =
        (data.consultado_en as Timestamp | undefined)?.toMillis() ?? 0;
      const polledHaceSegundos =
        polledEnMs > 0 ? (Date.now() - polledEnMs) / 1000 : Infinity;
      if (polledHaceSegundos > VIGILADOR_POLL_STALE_SEGUNDOS) {
        descartadosPollStale++;
        continue;
      }

      const patente = d.id;
      const empSnap = await db.collection("EMPLEADOS").doc(driverDni).get();
      if (!empSnap.exists) continue;
      const empData = empSnap.data() ?? {};
      if (empData.ACTIVO === false) continue;
      const tel = (empData.TELEFONO ?? "").toString().trim();
      if (!tel || tel === "-") continue;

      const apodo = (empData.APODO ?? "").toString().trim();
      const nombreFull = (empData.NOMBRE ?? "").toString().trim();
      const saludoNombre = apodo || _primerNombre(nombreFull) || "";
      const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

      // 6 variantes anti-baneo (decisión 2026-05-09).
      const variantes = [
        `${saludo},\n\n` +
          "Faltan 30 min para las 00:00. *Recordá que no podés seguir " +
          "conduciendo entre las 00:00 y las 06:00.*\n\n" +
          `Buscá un lugar seguro para parar el ${patente} ahora y ` +
          "descansá hasta mañana.\n\n" +
          BANNER_TESTING +
          "_Coopertrans Móvil — Mensaje automático._",
        `${saludo}.\n\n` +
          "Fin de jornada próximo: en 30 min se cumple la medianoche y " +
          "no se puede manejar hasta las 06:00 ART.\n\n" +
          `Estacioná el ${patente} en un lugar seguro y cortá la jornada.\n\n` +
          BANNER_TESTING +
          "_Coopertrans Móvil — Mensaje automático._",
        `${saludo}, atención.\n\n` +
          "Quedan 30 min para las 00:00. Después de esa hora la " +
          "conducción no está permitida hasta las 06:00.\n\n" +
          `Frená el ${patente} en un lugar seguro y descansá. Mañana ` +
          "retomás.\n\n" +
          BANNER_TESTING +
          "_Coopertrans Móvil — Mensaje automático._",
        `${saludo}.\n\n` +
          "Te paso el aviso de jornada nocturna: en 30 min son las " +
          "00:00 — hora límite para detener el camión.\n\n" +
          `Buscá dónde parar el ${patente} y descansá hasta las 06:00 ` +
          "como mínimo.\n\n" +
          BANNER_TESTING +
          "_Coopertrans Móvil — Mensaje automático._",
        `${saludo}, recordatorio.\n\n` +
          "Estás cerca del corte nocturno (00:00 hs). Te quedan 30 min " +
          "para encontrar un lugar seguro.\n\n" +
          `Frená el ${patente} antes de la medianoche y arrancás ` +
          "después de las 06:00.\n\n" +
          BANNER_TESTING +
          "_Coopertrans Móvil — Mensaje automático._",
        `${saludo}.\n\n` +
          "Por norma operativa, entre las 00:00 y las 06:00 no se " +
          "puede manejar. Faltan 30 min.\n\n" +
          `Estacioná el ${patente} en un lugar seguro ahora y cortá ` +
          "la jornada.\n\n" +
          BANNER_TESTING +
          "_Coopertrans Móvil — Mensaje automático._",
      ];
      const mensaje = variantes[_rrPick(variantes.length)];

      await db.collection("COLA_WHATSAPP").add({
        telefono: tel,
        mensaje,
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
        expira_en: _expiraEnMinutos(TTL_FIN_NOCTURNO_MIN),
        enviado_en: null,
        error: null,
        intentos: 0,
        origen: "jornada_fin_nocturna",
        destinatario_coleccion: "EMPLEADOS",
        destinatario_id: driverDni,
        campo_base: "JORNADA",
        admin_dni: "BOT",
        admin_nombre: "Bot vigilador jornada",
        alert_patente: patente,
      });
      avisados++;
    }

    logger.info("[avisoFinJornadaNocturna] OK", {
      avisados,
      descartadosPollStale,
    });
  }
);

// ============================================================================
// resumenExcesosJornadaDiario — al jefe de Seguridad e Higiene
// ============================================================================
//
// Cron diario a las 23:55 ART. Lee JORNADAS_CHOFER del día y arma un
// resumen de los choferes que cruzaron alguno de los límites (4h
// continuas o 12h diarias). Va al jefe de Seg e Higiene
// (SEG_HIGIENE_DESTINATARIO_DNI = MOLINA ALEJANDRA).
//
// Si no hay excesos, no se manda nada (silent log).

export const resumenExcesosJornadaDiario = onSchedule(
  {
    // 8:00 AM ART todos los días — leemos las jornadas de AYER (lo que
    // pasó el día anterior). Vecchi prefiere los resúmenes a la mañana
    // siguiente cuando el bot ya está activo y la oficina ya empezó.
    schedule: "0 8 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    logger.info("[resumenExcesosJornadaDiario] iniciando");

    // Leemos las JORNADAS_CHOFER de AYER (no de hoy). El cron corre
    // a las 8 AM y el día calendario que nos interesa terminó hace 8h.
    const ayer = new Date(Date.now() - 24 * 60 * 60 * 1000);
    const fechaArt = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Argentina/Buenos_Aires",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(ayer);

    const snap = await db
      .collection("JORNADAS_CHOFER")
      .where("fecha_art", "==", fechaArt)
      .get();

    interface ExcesoChofer {
      choferDni: string;
      patente: string;
      segundosTotal: number;
      segundosJornadaActual: number;
      segundosContinuoMax: number;
      excedio4hContinua: boolean;
      excedio12hDiaria: boolean;
      descansoCortoSegundos: number;
      // Arranque temprano post-12h: agregado 2026-05-13. True si el
      // chofer cerró 12h y volvió a manejar antes de hora_min_arranque
      // (max 6 AM ART / fin+8h).
      arranqueTempranoExcedido: boolean;
    }

    const excesos: ExcesoChofer[] = [];
    for (const d of snap.docs) {
      const data = d.data();
      const excedio4h = data.pausa_obligatoria_excedida === true;
      const excedio12h = data.jornada_diaria_excedida === true;
      const descansoCorto =
        (data.descanso_corto_segundos as number) ?? 0;
      const arranqueTemprano = data.arranque_temprano_excedido === true;
      // Incluir choferes que excedieron continuo/diario O que
      // arrancaron con descanso < 8h O que arrancaron antes de la
      // hora mínima post-12h. Cualquiera de los 4 califica.
      if (!excedio4h && !excedio12h && descansoCorto <= 0 &&
          !arranqueTemprano) continue;
      excesos.push({
        choferDni: (data.chofer_dni ?? "").toString(),
        patente: (data.ultima_patente ?? "").toString(),
        segundosTotal: (data.segundos_total_dia as number) ?? 0,
        // segundos_jornada_actual mide la jornada lógica (puede cruzar
        // medianoche y ser > segundos_total_dia cuando la jornada
        // empezó el día anterior). Lo agregamos al reporte para que
        // Molina vea la jornada real, no solo el slice del día
        // calendario. Si fueron iguales, la jornada se cerró dentro
        // del día.
        segundosJornadaActual:
          (data.segundos_jornada_actual as number) ?? 0,
        segundosContinuoMax:
          (data.segundos_continuo_actual as number) ?? 0,
        excedio4hContinua: excedio4h,
        excedio12hDiaria: excedio12h,
        descansoCortoSegundos: descansoCorto,
        arranqueTempranoExcedido: arranqueTemprano,
      });
    }

    // Lookup destinatario.
    const empSnap = await db
      .collection("EMPLEADOS")
      .doc(SEG_HIGIENE_DESTINATARIO_DNI)
      .get();
    if (!empSnap.exists) {
      logger.error(
        "[resumenExcesosJornadaDiario] destinatario no existe en EMPLEADOS",
        { dni: SEG_HIGIENE_DESTINATARIO_DNI }
      );
      return;
    }
    const empData = empSnap.data() ?? {};
    const tel = (empData.TELEFONO ?? "").toString().trim();
    if (!tel || tel === "-") {
      logger.error(
        "[resumenExcesosJornadaDiario] destinatario sin TELEFONO",
        { dni: SEG_HIGIENE_DESTINATARIO_DNI }
      );
      return;
    }

    // Sin excesos: mandamos "todo OK" igual (decisión Santiago
    // 2026-05-09: silencio = ambiguo, un mensaje confirma que el cron
    // corrió y ningún chofer cruzó los límites de jornada ayer).
    if (excesos.length === 0) {
      const fmtFechaOk = `${fechaArt.split("-").reverse().join("/")}`;
      const apodo = (empData.APODO ?? "").toString().trim();
      const nombreFull = (empData.NOMBRE ?? "").toString().trim();
      const saludoNombre = apodo || _primerNombre(nombreFull) || "";
      const saludoOk = saludoNombre ? `Hola ${saludoNombre}` : "Hola";
      // No usar "ayer" en el texto: si el bot estuvo apagado fin de
      // semana, los mensajes acumulados se entregan días después y
      // "ayer" resulta confuso (ej. mensaje sale el lunes diciendo
      // "ayer" pero la jornada es del viernes). La fecha explícita
      // en el título ya identifica el día sin ambigüedad.
      const mensajeOk =
        `${saludoOk},\n\n` +
        `📋 *Resumen excesos de jornada — ${fmtFechaOk}*\n\n` +
        "✅ Sin incidencias: ningún chofer cruzó las 4 h continuas, " +
        "las 12 h diarias, arrancó con menos de 8 h de descanso ni " +
        "arrancó temprano después de cumplir 12 h ese día.\n\n" +
        BANNER_TESTING +
        "_Coopertrans Móvil — Aviso automático._";
      await db.collection("COLA_WHATSAPP").add({
        telefono: tel,
        mensaje: mensajeOk,
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
        enviado_en: null,
        error: null,
        intentos: 0,
        origen: "resumen_excesos_jornada",
        destinatario_coleccion: "EMPLEADOS",
        destinatario_id: SEG_HIGIENE_DESTINATARIO_DNI,
        campo_base: "EXCESOS_JORNADA_DIARIO",
        admin_dni: "BOT",
        admin_nombre: "Bot resumen diario",
      });
      logger.info("[resumenExcesosJornadaDiario] OK (sin excesos)");
      return;
    }

    // Lookup nombres de los choferes (1 query por chofer, ~pocos
    // típicamente).
    const nombrePorDni = new Map<string, string>();
    for (const x of excesos) {
      try {
        const eS = await db.collection("EMPLEADOS").doc(x.choferDni).get();
        const n = eS.exists ?
          (eS.data()?.NOMBRE ?? "").toString().trim() :
          "";
        nombrePorDni.set(x.choferDni, n);
      } catch {
        nombrePorDni.set(x.choferDni, "");
      }
    }

    // Formato HH:MM de un total de segundos.
    function fmtHm(s: number): string {
      const h = Math.floor(s / 3600);
      const m = Math.floor((s % 3600) / 60);
      return `${h}:${m.toString().padStart(2, "0")}`;
    }

    const fmtFecha = `${fechaArt.split("-").reverse().join("/")}`;

    const lineas = excesos.map((x) => {
      const nombre = nombrePorDni.get(x.choferDni) || `DNI ${x.choferDni}`;
      const flags: string[] = [];
      if (x.excedio4hContinua) flags.push("4h continuas");
      if (x.excedio12hDiaria) flags.push("12h diarias");
      if (x.descansoCortoSegundos > 0) {
        flags.push(
          `descanso corto (${fmtHm(x.descansoCortoSegundos)} entre jornadas)`
        );
      }
      if (x.arranqueTempranoExcedido) {
        flags.push("arranque temprano post-12h");
      }
      // Si la jornada (que puede cruzar medianoche) es mayor que el
      // total del día calendario, mostramos AMBOS para que Molina vea
      // que la jornada empezó el día anterior. Sin esto el resumen
      // subestima jornadas nocturnas (problema histórico antes del
      // fix 2026-05-13).
      const lineaJornada =
        x.segundosJornadaActual > x.segundosTotal + 60 ?
          `   Jornada total: ${fmtHm(x.segundosJornadaActual)} hs (empezó día anterior)\n` :
          "";
      return (
        `🚛 *${x.patente || "—"}* — ${nombre} (DNI ${x.choferDni})\n` +
        `   Total día calendario: ${fmtHm(x.segundosTotal)} hs\n` +
        lineaJornada +
        `   Continuo máx: ${fmtHm(x.segundosContinuoMax)} hs\n` +
        `   ⚠️ ${flags.join(", ")}`
      );
    });

    const apodo = (empData.APODO ?? "").toString().trim();
    const nombreFull = (empData.NOMBRE ?? "").toString().trim();
    const saludoNombre = apodo || _primerNombre(nombreFull) || "";
    const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";

    const mensaje =
      `${saludo},\n\n` +
      `📋 *Resumen excesos de jornada — ${fmtFecha}*\n\n` +
      `${excesos.length} chofer${excesos.length === 1 ? "" : "es"} ` +
      "con incidencias de jornada:\n\n" +
      `${lineas.join("\n\n")}\n\n` +
      "_Datos calculados por el vigilador (Sitrack speed > 15 km/h, " +
      "pausa válida 10 min, jornada nueva tras 8 h de descanso, " +
      "descanso entre jornadas mínimo legal 8 h)._\n\n" +
      BANNER_TESTING +
      "_Coopertrans Móvil — Aviso automático._";

    await db.collection("COLA_WHATSAPP").add({
      telefono: tel,
      mensaje,
      estado: "PENDIENTE",
      encolado_en: FieldValue.serverTimestamp(),
      enviado_en: null,
      error: null,
      intentos: 0,
      origen: "resumen_excesos_jornada",
      destinatario_coleccion: "EMPLEADOS",
      destinatario_id: SEG_HIGIENE_DESTINATARIO_DNI,
      campo_base: "JORNADA",
      admin_dni: "BOT",
      admin_nombre: "Bot vigilador jornada",
    });

    logger.info("[resumenExcesosJornadaDiario] OK", {
      excesos: excesos.length,
      destinatario: SEG_HIGIENE_DESTINATARIO_DNI,
    });
  }
);

// ============================================================================
// DASHBOARD STATS — agregaciones server-side para admin_panel
// ============================================================================
//
// Antes admin_panel hacía 3 StreamBuilders (EMPLEADOS, VEHICULOS, REVISIONES)
// y calculaba KPIs O(N×M) client-side en cada snapshot push. Funcionaba con
// flotas chicas (~177 docs) pero la deuda escalaba: cada cambio en cualquier
// doc gatillaba recalc completo en cada cliente admin abierto.
//
// Ahora: una scheduled function recalcula y persiste el agregado en
// `STATS/dashboard`. La app lee 1 doc en lugar de N+M+R. Stale máx ~5 min,
// totalmente aceptable para un dashboard administrativo.
//
// Schema del doc `STATS/dashboard` (ver `lib/features/admin_dashboard/...`):
//   {
//     v: 1,
//     choferes_activos, unidades_total, unidades_asignadas,
//     revisiones_pendientes, vencidos, proximos_7, proximos_30,
//     actualizado_en: Timestamp,
//     duracion_ms, docs_leidos
//   }
//
// Helpers replicados de Dart cliente (ver
// `lib/core/constants/{app_constants,vencimientos_config}.dart` +
// `lib/shared/utils/formatters.dart`). Si cambia la lógica de un lado,
// CAMBIAR EL OTRO. Tests E2E manualmente: cargar empleado nuevo, esperar
// ≤5 min, verificar que choferes_activos sube en el dashboard.

const DASHBOARD_STATS_SCHEMA_VERSION = 1;

// Roles cuyos miembros tienen vehículo asignable y por ende cuentan
// como "choferes activos". Espejo de `AppRoles.tieneVehiculo` en Dart.
const ROLES_CON_VEHICULO = new Set<string>(["CHOFER", "USUARIO"]);

// Estados que indican que un vehículo está asignado a un chofer.
// Espejo de la lógica en `_Stats.from()` cliente.
const ESTADOS_VEHICULO_OCUPADO = new Set<string>(["OCUPADO", "ASIGNADO"]);

// Sufijos de `VENCIMIENTO_*` para EMPLEADOS. Espejo de
// `AppDocsEmpleado.etiquetas` en Dart. Los 4 docs laborales (ART, F.931,
// SCVO, sindical) NO van acá — son por empresa, no por empleado.
const VENCIMIENTOS_EMPLEADO_SUFIJOS = [
  "LICENCIA_DE_CONDUCIR",
  "PREOCUPACIONAL",
  "CURSO_DE_MANEJO_DEFENSIVO",
];

// Sufijos `VENCIMIENTO_*` para TRACTOR/CHASIS. Espejo de
// `AppVencimientos.tractor` en Dart.
const VENCIMIENTOS_TRACTOR_SUFIJOS = [
  "RTO",
  "SEGURO",
  "EXTINTOR_CABINA",
  "EXTINTOR_EXTERIOR",
];

// Sufijos `VENCIMIENTO_*` para ENGANCHE (resto de tipos). Espejo de
// `AppVencimientos.enganche`.
const VENCIMIENTOS_ENGANCHE_SUFIJOS = ["RTO", "SEGURO"];

/**
 * `true` si el doc NO está dado de baja. Espejo de `AppActivo.esActivo`:
 *   - ACTIVO=true → true (alta explícita).
 *   - ACTIVO=null/ausente → true (default; doc viejo pre-soft-delete).
 *   - ACTIVO=false → false (baja).
 */
function _statsEsActivo(data: Record<string, unknown>): boolean {
  return data.ACTIVO !== false;
}

/**
 * Normaliza un rol al canónico (USUARIO legacy → CHOFER). Espejo de
 * `AppRoles.normalizar`.
 */
function _statsNormalizarRol(rol: unknown): string {
  const r = String(rol ?? "").toUpperCase();
  if (r === "USUARIO") return "CHOFER";
  return r;
}

/**
 * Calcula días restantes hasta una fecha. Acepta Timestamp, Date, ISO
 * string (YYYY-MM-DD), AR string (DD/MM/YYYY o DD-MM-YYYY). Devuelve
 * `null` si no se puede parsear (consistente con
 * `AppFormatters.calcularDiasRestantes` cliente — el caller cuenta esos
 * como "vencidos" en el peor caso).
 */
function _statsCalcularDiasRestantes(fecha: unknown): number | null {
  if (fecha === null || fecha === undefined || fecha === "") return null;
  let d: Date | null = null;
  if (fecha instanceof Date) {
    d = fecha;
  } else if (
    typeof (fecha as { toDate?: () => Date }).toDate === "function"
  ) {
    // Firestore Timestamp.
    d = (fecha as { toDate: () => Date }).toDate();
  } else {
    const s = String(fecha).trim();
    if (s === "" || s === "---" || s.toLowerCase() === "nan") return null;
    // Limpiar parte de hora si vino "YYYY-MM-DD HH:MM:SS"
    const soloFecha = s.split("T")[0].split(" ")[0];
    const f = soloFecha.replace(/\//g, "-");
    const partes = f.split("-");
    if (partes.length !== 3) return null;
    let yyyy: number;
    let mm: number;
    let dd: number;
    if (partes[0].length === 4) {
      // ISO YYYY-MM-DD.
      yyyy = parseInt(partes[0], 10);
      mm = parseInt(partes[1], 10);
      dd = parseInt(partes[2], 10);
    } else {
      // AR DD-MM-YYYY.
      dd = parseInt(partes[0], 10);
      mm = parseInt(partes[1], 10);
      yyyy = parseInt(partes[2], 10);
    }
    if (
      Number.isNaN(yyyy) || Number.isNaN(mm) || Number.isNaN(dd) ||
      mm < 1 || mm > 12 || dd < 1 || dd > 31
    ) {
      return null;
    }
    d = new Date(yyyy, mm - 1, dd);
  }
  if (!d || Number.isNaN(d.getTime())) return null;
  // Normalizar a midnight (mismo cálculo que cliente).
  const vto = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const ahora = new Date();
  const hoy = new Date(ahora.getFullYear(), ahora.getMonth(), ahora.getDate());
  const diffMs = vto.getTime() - hoy.getTime();
  return Math.floor(diffMs / (24 * 60 * 60 * 1000));
}

interface DashboardCounters {
  choferes_activos: number;
  unidades_total: number;
  unidades_asignadas: number;
  revisiones_pendientes: number;
  vencidos: number;
  proximos_7: number;
  proximos_30: number;
}

/**
 * Cuenta una fecha contra los buckets vencidos / proximos_7 / proximos_30.
 * Mismo criterio que `_Stats.from` cliente: null/no-parseable → vencido
 * (peor caso, para que el admin se entere si hay un campo corrupto).
 */
function _statsContarFecha(fecha: unknown, c: DashboardCounters): void {
  if (fecha === null || fecha === undefined || fecha === "") return;
  const dias = _statsCalcularDiasRestantes(fecha);
  if (dias === null || dias < 0) {
    c.vencidos++;
  } else if (dias <= 7) {
    c.proximos_7++;
  } else if (dias <= 30) {
    c.proximos_30++;
  }
}

/**
 * Recalcula los KPIs desde cero leyendo EMPLEADOS + VEHICULOS +
 * REVISIONES. Mismo cálculo que `_Stats.from` cliente. Llamada por el
 * scheduled cada 5 min y por el callable de force-refresh (futuro).
 */
async function _statsRecomputeDashboard(): Promise<DashboardCounters & { docs_leidos: number }> {
  const counters: DashboardCounters = {
    choferes_activos: 0,
    unidades_total: 0,
    unidades_asignadas: 0,
    revisiones_pendientes: 0,
    vencidos: 0,
    proximos_7: 0,
    proximos_30: 0,
  };

  // Empleados con vehículo (.limit(5000) defensivo, igual que cliente).
  const empleadosSnap = await db.collection("EMPLEADOS").limit(5000).get();
  for (const doc of empleadosSnap.docs) {
    const data = doc.data();
    if (!_statsEsActivo(data)) continue;
    const rol = _statsNormalizarRol(data.ROL);
    if (!ROLES_CON_VEHICULO.has(rol)) continue;
    const estado = String(data.estado_cuenta ?? "ACTIVO").toUpperCase();
    if (estado === "ACTIVO") counters.choferes_activos++;
    for (const sufijo of VENCIMIENTOS_EMPLEADO_SUFIJOS) {
      _statsContarFecha(data[`VENCIMIENTO_${sufijo}`], counters);
    }
  }

  // Vehículos.
  const vehiculosSnap = await db.collection("VEHICULOS").limit(5000).get();
  for (const doc of vehiculosSnap.docs) {
    const data = doc.data();
    if (!_statsEsActivo(data)) continue;
    counters.unidades_total++;
    const estado = String(data.ESTADO ?? "").toUpperCase();
    if (ESTADOS_VEHICULO_OCUPADO.has(estado)) {
      counters.unidades_asignadas++;
    }
    const tipo = String(data.TIPO ?? "").toUpperCase();
    const esTractor = tipo === "TRACTOR" || tipo === "CHASIS";
    const sufijos = esTractor ?
      VENCIMIENTOS_TRACTOR_SUFIJOS :
      VENCIMIENTOS_ENGANCHE_SUFIJOS;
    for (const sufijo of sufijos) {
      _statsContarFecha(data[`VENCIMIENTO_${sufijo}`], counters);
    }
  }

  // Revisiones pendientes. Las aprobadas/rechazadas se borran del
  // collection en condiciones normales, pero filtramos por
  // estado=PENDIENTE defensivamente — si algún día queda basura
  // sin borrar, el contador no se infla. Además mantiene el
  // semántico claro (no contar todo lo que esté en la colección).
  const revisionesSnap = await db
    .collection("REVISIONES")
    .where("estado", "==", "PENDIENTE")
    .limit(500)
    .get();
  counters.revisiones_pendientes = revisionesSnap.size;

  return {
    ...counters,
    docs_leidos: empleadosSnap.size + vehiculosSnap.size + revisionesSnap.size,
  };
}

/**
 * Scheduled cada 5 min. Recalcula KPIs y los persiste en
 * `STATS/dashboard`. Stale máximo 5 min — aceptable para dashboard admin.
 *
 * Costo: 3 reads × ~177 docs cada 5 min = ~150k reads/mes. Despreciable
 * vs. el costo de tener N admins simultáneos haciendo lo mismo client-side.
 */
export const recomputeDashboardStats = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    const inicio = Date.now();
    try {
      const stats = await _statsRecomputeDashboard();
      const duracionMs = Date.now() - inicio;
      await db.collection("STATS").doc("dashboard").set({
        v: DASHBOARD_STATS_SCHEMA_VERSION,
        ...stats,
        actualizado_en: FieldValue.serverTimestamp(),
        duracion_ms: duracionMs,
        computed_by: "scheduled",
      });
      logger.info("[recomputeDashboardStats] OK", {
        ...stats,
        duracion_ms: duracionMs,
      });
    } catch (e) {
      const err = e as Error;
      logger.error("[recomputeDashboardStats] error", {
        message: err.message,
        stack: err.stack,
      });
      // No re-throw — siguiente ciclo reintenta. El dashboard cliente
      // seguirá leyendo el último STATS/dashboard exitoso (stale).
    }
  }
);

// ============================================================================
// asignarNumeroReciboAdelanto
// ============================================================================
// Asigna número correlativo al recibo de adelanto. Atómico server-side,
// idempotente.
//
// **Refactor 2026-05-13**: ahora trabaja sobre `ADELANTOS_CHOFER` (la
// nueva colección de adelantos independientes de viajes — Santiago
// quería poder dar adelantos de sueldo sin crear un viaje vacío). El
// counter sigue siendo el MISMO `COUNTERS/recibos_adelanto.next` para
// no reiniciar la serie física de recibos. Compat retro: si el caller
// pasa `viajeId` (esquema viejo donde el adelanto vivía en el viaje),
// lo seguimos soportando para no romper apps cliente desactualizadas.
//
// **Por qué server-side**: el cliente Windows desktop tiene un bug
// conocido en `cloud_firestore` (plugin) que crashea con `abort()` C++
// cuando se combina `runTransaction` + `tx.set(merge: true)` +
// `FieldValue.serverTimestamp()` (ver `feedback_windows_cloud_firestore_bugs.md`).
// El Admin SDK acá no tiene ese bug y la transacción corre limpia.
//
// **Diseño**:
//   - Counter en `COUNTERS/recibos_adelanto.next` (arranca en 1 si no
//     existe).
//   - Si el adelanto ya tiene `numero_recibo`, devolvemos el mismo
//     número sin incrementar (idempotente: reimprimir no quema un
//     correlativo nuevo).
//   - Si no tiene, leemos+incrementamos el counter y lo asignamos
//     dentro de la misma transaction.
//   - Requiere ADMIN o SUPERVISOR.
//
// Input (cualquiera de los 2): `{ adelantoId: string }` (nuevo) o
//   `{ viajeId: string }` (legacy compat).
// Output: `{ numero: number, esReimpresion: boolean }`

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
