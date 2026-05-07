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
    const update: Record<string, unknown> = {
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
    const vehiculosSnap = await db.collection("VEHICULOS").get();
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
      const doc: Record<string, unknown> = {
        patente,
        vin,
        fecha: Timestamp.fromDate(fechaMidnight),
        litros_acumulados: litros,
        km,
        timestamp: FieldValue.serverTimestamp(),
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

  const doc: Record<string, unknown> = {
    vin,
    tipo,
    severidad,
    creado_en: Timestamp.fromMillis(creadoMs),
    polled_en: FieldValue.serverTimestamp(),
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

    // Filtro de subtipos GENERIC ruidosos (incidente 2026-05-03):
    // Volvo emite varios eventos GENERIC con severidad HIGH que NO son
    // urgencias del manejo y que generaban spam masivo al chofer:
    //
    // - TELL_TALE: testigo del tablero (ABS, freno de mano, AdBlue, etc.).
    //   Es problema de mantenimiento — ya va al jefe de mantenimiento via
    //   `onAlertaVolvoMantenimientoCreated`. Mandárselo TAMBIÉN al chofer
    //   no aporta (el chofer no puede arreglar un sensor del tablero) y
    //   un testigo intermitente puede generar 10-15 eventos por día.
    //
    // - DRIVING_WITHOUT_BEING_LOGGED_IN: chofer sin loguearse al tachógrafo.
    //   Decisión de Vecchi (memoria del proyecto): NO se enforcea
    //   identificación de chofer en tachógrafo. Evento de baja relevancia.
    //
    // Estos eventos siguen visibles en el tablero "Alertas Volvo" del
    // admin y se acumulan en el resumen diario (aviso_alertas_volvo_builder)
    // que se manda 1x/día al admin. Nada se pierde — solo no spameamos.
    if (tipo === "GENERIC") {
      const triggerType = (
        (data.detalle_generic as Record<string, unknown> | undefined)
          ?.triggerType ?? ""
      ).toString().toUpperCase();
      const subtiposRuidosos = ["TELL_TALE", "DRIVING_WITHOUT_BEING_LOGGED_IN"];
      if (subtiposRuidosos.includes(triggerType)) {
        logger.info(
          "[onAlertaVolvoCreated] GENERIC subtipo ruidoso, skip al chofer (sigue en tablero)",
          { alertId: event.params.alertId, patente, triggerType }
        );
        return;
      }
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
    // típica de spam y dispara bandera. Rotamos entre 3 variantes con
    // mismo contenido informativo pero distinta redacción.
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
    ];
    const mensaje = variantes[Math.floor(Math.random() * variantes.length)];

    try {
      const colaRef = await db.collection("COLA_WHATSAPP").add({
        telefono: telefonoRaw,
        mensaje,
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
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
    const vehiculosSnap = await db.collection("VEHICULOS").get();
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
    logger.info("[onAlertaVolvoMantenimientoCreated] evento registrado en VOLVO_ALERTAS — cron diario lo incluirá en resumen", {
      alertId: event.params.alertId,
      patente,
      tipo,
      etiqueta,
    });
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
// botHealthWatchdog — alerta a Santiago si el bot dejó de latir
// ============================================================================
//
// El bot Node.js corre en la PC de Santiago y escribe heartbeat a
// `BOT_HEALTH/main.ultimoHeartbeat` cada 60s. La pantalla "Estado del Bot"
// del admin lo muestra, pero requiere que Santiago entre a esa pantalla
// para enterarse — riesgo: el bot puede llevar horas/días caído sin que
// nadie lo note (PC apagada por reinicio de Windows, NSSM crasheado,
// etc.) y los choferes dejan de recibir avisos críticos.
//
// Esta function corre cada 15 min y compara `ultimoHeartbeat` con ahora.
// Si la diferencia es > UMBRAL_STALE_MIN, encola un WhatsApp a
// MANTENIMIENTO_DESTINATARIO_DNI (Santiago) con el aviso. Idempotencia:
// solo notifica cuando el bot pasa de "vivo" a "stale" — guarda flag
// `BOT_HEALTH/main.notificadoCaida` para no spamear avisos cada 15 min.
//
// Cuando el bot vuelve y manda heartbeat fresco, el siguiente run del
// watchdog limpia la flag y registra log informativo.

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

    if (minDesdeHb <= BOT_HEALTH_STALE_UMBRAL_MIN) {
      // Bot vivo. Si había flag de caída anterior, limpiarla y loguear.
      if (yaNotificado) {
        await ref.update({ notificadoCaida: false, recuperadoEn: FieldValue.serverTimestamp() });
        logger.info("[botHealthWatchdog] bot recuperado", {
          minDesdeUltimoHb: minDesdeHb.toFixed(1),
        });
      }
      return;
    }

    // Bot stale.
    if (yaNotificado) {
      // Ya avisamos antes — no spamear.
      logger.info("[botHealthWatchdog] bot sigue caído, ya notificado", {
        minDesdeUltimoHb: minDesdeHb.toFixed(1),
      });
      return;
    }

    // Primera detección de caída — notificar al admin.
    const adminDni = MANTENIMIENTO_DESTINATARIO_DNI;
    const empSnap = await db.collection("EMPLEADOS").doc(adminDni).get();
    const tel = empSnap.exists ?
      (empSnap.data()?.TELEFONO ?? "").toString().trim() :
      "";
    if (!tel) {
      logger.error("[botHealthWatchdog] admin sin TELEFONO, no se puede notificar caída del bot", {
        adminDni,
      });
      return;
    }

    const minRedondeo = Math.round(minDesdeHb);
    const fechaTxt = _formatFechaArg(ultimoHb.toMillis());
    const horaTxt = _formatHoraArg(ultimoHb.toMillis());
    const pcId = (data.pcId ?? "desconocida").toString();
    const mensaje =
      "🚨 *Bot WhatsApp caído*\n\n" +
      `Sin heartbeat desde ${fechaTxt} ${horaTxt} ` +
      `(hace ${minRedondeo} min) en PC \`${pcId}\`.\n\n` +
      "Los avisos de vencimientos y alertas Volvo están en cola pero " +
      "no se están enviando. Revisá la PC del bot o reiniciá el servicio.\n\n" +
      BANNER_TESTING +
      "_Aviso automático del watchdog. Solo se envía 1 vez por caída._";

    await db.collection("COLA_WHATSAPP").add({
      telefono: tel,
      mensaje,
      estado: "PENDIENTE",
      encolado_en: FieldValue.serverTimestamp(),
      enviado_en: null,
      error: null,
      intentos: 0,
      origen: "bot_watchdog",
      destinatario_coleccion: "EMPLEADOS",
      destinatario_id: adminDni,
      campo_base: "BOT_WATCHDOG",
      admin_dni: "BOT",
      admin_nombre: "Bot watchdog",
    });

    await ref.update({
      notificadoCaida: true,
      notificadoCaidaEn: FieldValue.serverTimestamp(),
    });

    // Paradoja del watchdog: el aviso queda en COLA_WHATSAPP, pero el
    // bot que tiene que enviarlo ESTÁ CAÍDO. ¿Cómo le llega a Santiago?
    // - Cuando el bot vuelva (al reiniciar manualmente o auto), procesa
    //   la cola y le manda el WhatsApp con el mensaje "estuviste caído".
    //   Útil como confirmación post-mortem.
    // - Para alerting REAL en tiempo real (sin depender del bot caído),
    //   lo correcto sería usar Firebase Cloud Messaging push directo a
    //   Santiago (notificación nativa del cliente Flutter), o un email
    //   via Gmail SMTP. Pendiente para futura iteración.
    logger.warn("[botHealthWatchdog] bot caído — aviso encolado para admin", {
      adminDni,
      minDesdeUltimoHb: minRedondeo,
      pcId,
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
      // Comparamos el DNI físico (Sitrack) vs el asignado por el
      // sistema. Casos:
      //   - SIN_ASIGNACION: Sitrack reporta chofer pero el sistema
      //     no tiene a nadie asignado a esa patente. Alguien manejando
      //     sin estar registrado.
      //   - CHOFER_DISTINTO: Ambos lados reportan, pero los DNIs no
      //     coinciden. Falta actualizar la asignación.
      //   - CHOFER_NO_IDENTIFICADO: ignición ON, hay asignación, pero
      //     Sitrack no reporta DNI — el chofer subió sin pasar el
      //     iButton. Si ignición OFF, no es drift (tractor parado).
      const ignitionOn = r.ignition === 1;
      const asignacion = asignacionesPorPatente.get(patente);
      let driftTipo: string | null = null;
      if (driverDni && !asignacion) {
        driftTipo = "SIN_ASIGNACION";
      } else if (driverDni && asignacion && asignacion.choferDni !== driverDni) {
        driftTipo = "CHOFER_DISTINTO";
      } else if (!driverDni && asignacion && ignitionOn) {
        driftTipo = "CHOFER_NO_IDENTIFICADO";
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

    logger.info("[sitrackPosicionPoller] OK", {
      recibidos: reports.length,
      escritos,
      descartados,
      conDrift,
    });
  }
);
