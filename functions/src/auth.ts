/**
 * Cloud Functions de autenticación + gestión de empleados.
 *
 * Extraído de index.ts (refactor split 2026-05-19). Contiene:
 *   - `loginConDni`: emite custom token de Firebase Auth a partir de un
 *     par DNI + contraseña (rate limit por DNI e IP + migración
 *     silenciosa SHA-256 → bcrypt).
 *   - `cambiarContrasenaChofer` / `resetearContrasenaEmpleadoAdmin`
 *   - `actualizarRolEmpleado` / `renombrarEmpleadoDni`
 *   - Helpers puros de password (`validarInputLogin`, `verificarPassword`,
 *     `esBcrypt`, `esLegacy`, `sha256Hex`, `hashId`) + rate-limit por DNI
 *     e IP (`chequearBloqueoIp`, `registrarIntentoFallido*`).
 *
 * Re-exportado desde index.ts con `export * from "./auth"` para que
 * Firebase vea los endpoints en el entry point oficial. `hashId` lo
 * consumen icm.ts y sitrack.ts (importan de "./index", que re-exporta).
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {
  FieldValue,
  DocumentReference,
  Timestamp,
  Firestore,
  Transaction,
} from "firebase-admin/firestore";
import * as bcrypt from "bcryptjs";
import * as crypto from "crypto";

import { db, auth, MAX_INTENTOS_FALLIDOS, BLOQUEO_DURACION_MS } from "./setup";

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

    // ─── Rate limit por IP (auditoria 2026-05-18) ──────────────────
    // Suplemento al rate limit por DNI: sin esto, un atacante podia
    // probar 3 passwords sobre N DNIs distintos (cada uno con cuota
    // propia de 3) y nunca quedar bloqueado por la IP origen. Ventana
    // deslizante de 5 min, max 10 intentos fallidos por IP.
    const ipRaw =
      ((request.rawRequest?.ip ?? "") as string).toString() || "unknown";
    const ipHash = hashId(ipRaw);
    const ipBloqueoMin = await chequearBloqueoIp(ipHash);
    if (ipBloqueoMin > 0) {
      logger.warn("[login] IP bloqueada por rate limit", {
        ipHash,
        minutosRestantes: ipBloqueoMin,
      });
      throw new HttpsError(
        "resource-exhausted",
        `Demasiados intentos desde tu red. Reintentá en ${ipBloqueoMin} minutos.`,
      );
    }

    // ─── Lectura del legajo ────────────────────────────────────────
    const docRef = db.collection("EMPLEADOS").doc(dni);
    const docSnap = await docRef.get();

    if (!docSnap.exists) {
      logger.info("[login] DNI no existe", { dni });
      // ALTO (auditoria 2026-05-18): antes devolvia `not-found` con
      // "El usuario no existe" — eso permitia enumerar qué DNIs son
      // empleados activos sin gastar el rate limit (que solo cuenta
      // password fallido por DNI existente). Ahora respuesta
      // indistinguible de "password incorrecto" → atacante no puede
      // separar "DNI valido" de "DNI invalido + password valido".
      // Tambien contamos contra el rate limit por IP — sino enumerar
      // DNIs no costaba nada.
      await registrarIntentoFallidoIp(ipHash);
      throw new HttpsError("permission-denied", "Usuario o contraseña incorrectos.");
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
      await registrarIntentoFallidoIp(ipHash);
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
      // Mismo mensaje que cuando el DNI no existe — anti-enumeracion.
      throw new HttpsError("permission-denied", "Usuario o contraseña incorrectos.");
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
    // CRITICO (auditoria 2026-05-18): antes la lista local era
    // ["CHOFER","PLANTA","SUPERVISOR","ADMIN"] — faltaban GOMERIA y
    // SEG_HIGIENE. Los empleados con esos roles eran DEGRADADOS
    // silenciosamente a CHOFER en el JWT → perdian acceso a gomeria,
    // ICM, modulos admin segun capabilities. Reusamos ROLES_VALIDOS
    // (la lista canonica usada por actualizarRolEmpleado).
    const rolRaw = (empleado.ROL ?? "CHOFER").toString().toUpperCase();
    let rol = rolRaw;
    if (rolRaw === "USUARIO" || rolRaw === "USER") rol = "CHOFER";
    if (!ROLES_VALIDOS.includes(rol)) rol = "CHOFER";

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
// cambiarContrasenaChofer — cambio self-service con validacion server-side
// ============================================================================
//
// El chofer cambia su clave desde "Mi Perfil". Server-side validamos:
//   1. Caller esta autenticado (request.auth.uid existe).
//   2. La contraseña ACTUAL coincide con el hash bcrypt almacenado
//      en EMPLEADOS/{uid}.CONTRASEÑA — sin esto, atacante con device
//      fisico podria cambiar la pass sin saber la actual.
//   3. La nueva tiene minimo 6 caracteres (mismo umbral que alta).
//
// Antes el cliente Flutter hacia el `update({'CONTRASEÑA': nuevoHash})`
// directo via Firestore SDK. La rule lo permitia (CONTRASEÑA estaba
// en hasOnly self-update). Auditoria 2026-05-17: CRITICO porque la
// validacion de pass actual estaba SOLO en cliente (PasswordHasher.verify)
// y podia bypassearse con DevTools. Ahora la rule rechaza el update de
// CONTRASEÑA — solo este callable (Admin SDK) escribe el campo.

export const cambiarContrasenaChofer = onCall(
  { timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sin sesion activa.");
    }
    const actual = (request.data?.actual ?? "").toString();
    const nueva = (request.data?.nueva ?? "").toString();
    if (actual.length === 0 || nueva.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "Faltan campos 'actual' o 'nueva'.",
      );
    }
    if (nueva.length < 6) {
      throw new HttpsError(
        "invalid-argument",
        "La nueva contrasena debe tener al menos 6 caracteres.",
      );
    }
    // Auditoria 2026-05-18: defensa contra "cambio a la misma pass" —
    // accidental o intencional. Bcrypt no permite chequear igualdad sin
    // verificar contra el hash, asi que el check real va abajo.
    // Tambien rechazamos new == old en texto plano (mismo string).
    if (nueva === actual) {
      throw new HttpsError(
        "invalid-argument",
        "La nueva contrasena no puede ser igual a la actual.",
      );
    }

    // Throttle anti-bruteforce de la pass actual (auditoria 2026-05-18).
    // Reusa los mismos helpers de LOGIN_ATTEMPTS pero en una coleccion
    // separada para no contaminar el rate limit del login. Sin esto, un
    // device hostil con sesion activa podia probar 1000 passwords sin
    // penalidad (bcrypt cost 10 ≈ 100ms/intento).
    const intentosPassRef =
      db.collection("PASS_CHANGE_ATTEMPTS").doc(hashId(uid));
    const minBloqueoPass = await chequearBloqueoActivo(intentosPassRef);
    if (minBloqueoPass > 0) {
      logger.warn("[cambiarContrasenaChofer] bloqueado por rate limit", {
        uidHash: hashId(uid),
        minutosRestantes: minBloqueoPass,
      });
      throw new HttpsError(
        "resource-exhausted",
        `Demasiados intentos fallidos. Reintentá en ${minBloqueoPass} minutos.`,
      );
    }

    // Leer doc del propio chofer.
    const ref = db.collection("EMPLEADOS").doc(uid);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Legajo no encontrado.");
    }
    const data = snap.data() ?? {};
    const hashActualRaw = data["CONTRASEÑA"];
    const hashActual = typeof hashActualRaw === "string" ? hashActualRaw : "";
    if (hashActual.length === 0) {
      throw new HttpsError(
        "failed-precondition",
        "El legajo no tiene contrasena cargada — contacta al admin.",
      );
    }

    // Verificar la contrasena actual server-side con bcrypt/SHA legacy.
    const ok = await verificarPassword(actual, hashActual);
    if (!ok) {
      const resultado = await registrarIntentoFallido(intentosPassRef);
      logger.info("[cambiarContrasenaChofer] pass actual incorrecta", {
        uidHash: hashId(uid),
        intentosFallidos: resultado.intentos,
        bloqueadoMinRestantes: resultado.bloqueadoMinRestantes,
      });
      if (resultado.bloqueadoMinRestantes > 0) {
        throw new HttpsError(
          "permission-denied",
          `Demasiados intentos. Reintentá en ${resultado.bloqueadoMinRestantes} minutos.`,
        );
      }
      throw new HttpsError(
        "permission-denied",
        "La contrasena actual es incorrecta.",
      );
    }

    // Hashear la nueva con bcrypt cost 10 y persistir.
    const nuevoHash = await bcrypt.hash(nueva, 10);
    await ref.update({
      "CONTRASEÑA": nuevoHash,
      "fecha_ultima_actualizacion": FieldValue.serverTimestamp(),
    });
    // Reset del contador de intentos tras cambio exitoso (best-effort).
    try {
      await intentosPassRef.delete();
    } catch (e) {
      logger.warn(
        "[cambiarContrasenaChofer] no pude limpiar PASS_CHANGE_ATTEMPTS",
        { uidHash: hashId(uid), error: (e as Error).message },
      );
    }
    logger.info("[cambiarContrasenaChofer] OK", { uidHash: hashId(uid) });
    return { ok: true };
  },
);

// ============================================================================
// resetearContrasenaEmpleadoAdmin — admin resetea pass de otro empleado
// ============================================================================
//
// Caso de uso real: el chofer olvido la contraseña y no la puede recuperar
// (no tiene email vinculado, no recuerda la actual). Antes del 2026-05-17
// el admin no podia ayudarlo desde la app: la rule de EMPLEADOS rechaza
// el update del campo CONTRASEÑA (lo escribe solo este callable y el
// `cambiarContrasenaChofer`), y `cambiarContrasenaChofer` exige la actual.
// Workaround manual: editar el doc Firestore desde la consola Web pegando
// un hash bcrypt generado a mano — frictivo y peligroso (typo del hash =
// chofer queda con clave invalida y nadie sabe).
//
// Auth: solo ADMIN o SUPERVISOR (los unicos que tienen capacidad de
// gestionar empleados). El callable:
//   1. Valida que el caller tenga rol admitido.
//   2. Hashea la nueva pass con bcrypt cost 10 (mismo que self-service).
//   3. Actualiza EMPLEADOS/{dni}.CONTRASEÑA via Admin SDK (sortea la rule).
//   4. Revoca refresh tokens del afectado para forzar re-login.
//   5. Loguea con dniHash (no DNI plano) para auditoria sin PII.
//
// El admin le pasa al chofer la nueva pass por canal seguro (en mano,
// WhatsApp privado). El chofer puede cambiarla despues con `cambiarContrasenaChofer`.
export const resetearContrasenaEmpleadoAdmin = onCall(
  { timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    const rolCaller = request.auth?.token?.rol;
    if (!request.auth || (rolCaller !== "ADMIN" && rolCaller !== "SUPERVISOR")) {
      logger.warn("[resetearContrasenaEmpleadoAdmin] sin auth admin/supervisor", {
        uid: request.auth?.uid ?? "no-uid",
        rol: rolCaller ?? "no-rol",
      });
      throw new HttpsError(
        "permission-denied",
        "Solo ADMIN o SUPERVISOR pueden resetear contrasenas.",
      );
    }

    const dni = (request.data?.dni ?? "").toString().trim();
    const nueva = (request.data?.nueva ?? "").toString();
    if (!dni) {
      throw new HttpsError("invalid-argument", "Falta `dni`.");
    }
    if (nueva.length < 6) {
      throw new HttpsError(
        "invalid-argument",
        "La nueva contrasena debe tener al menos 6 caracteres.",
      );
    }

    const ref = db.collection("EMPLEADOS").doc(dni);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", `Empleado ${dni} no encontrado.`);
    }

    const nuevoHash = await bcrypt.hash(nueva, 10);
    await ref.update({
      "CONTRASEÑA": nuevoHash,
      "fecha_ultima_actualizacion": FieldValue.serverTimestamp(),
    });

    // Revocar tokens del afectado para forzar re-login con la pass nueva.
    // Si el usuario nunca tuvo Auth account (raro pero pasa con empleados
    // nuevos sin login), revokeRefreshTokens tira — capturamos sin
    // romper porque el reset igual sirve para el proximo login.
    try {
      await auth.revokeRefreshTokens(dni);
    } catch (e) {
      logger.info("[resetearContrasenaEmpleadoAdmin] sin Auth account, OK", {
        dniHash: hashId(dni),
        error: (e as Error).message,
      });
    }

    logger.info("[resetearContrasenaEmpleadoAdmin] OK", {
      adminHash: hashId(request.auth.uid),
      dniHash: hashId(dni),
    });
    return { ok: true };
  },
);

// ============================================================================
// revocarSesionEmpleado
// ============================================================================
//
// Revoca los refresh tokens de un empleado para CORTARLE la sesión activa al
// instante (sin esperar a que su ID token expire, ~1h). La usa el flujo de
// "dar de baja" (despido): tras setear ACTIVO=false, el AuthGuard del cliente
// del afectado detecta el token revocado en su próximo getIdToken(true) y lo
// desloguea. Solo ADMIN — dar de baja es acción solo-admin (2026-06-01).
export const revocarSesionEmpleado = onCall(
  { timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    const rolCaller = request.auth?.token?.rol;
    if (!request.auth || rolCaller !== "ADMIN") {
      logger.warn("[revocarSesionEmpleado] sin auth admin", {
        uid: request.auth?.uid ?? "no-uid",
        rol: rolCaller ?? "no-rol",
      });
      throw new HttpsError(
        "permission-denied",
        "Solo ADMIN puede revocar sesiones.",
      );
    }
    const dni = (request.data?.dni ?? "").toString().trim();
    if (!dni) {
      throw new HttpsError("invalid-argument", "Falta `dni`.");
    }
    try {
      await auth.revokeRefreshTokens(dni);
      logger.info("[revocarSesionEmpleado] OK", {
        adminHash: hashId(request.auth.uid),
        dniHash: hashId(dni),
      });
      return { ok: true, revocado: true };
    } catch (e) {
      // El empleado puede no tener Auth account (nunca logueó): no hay
      // sesión que cortar. No es error fatal.
      logger.info("[revocarSesionEmpleado] sin Auth account / no se pudo", {
        dniHash: hashId(dni),
        error: (e as Error).message,
      });
      return { ok: true, revocado: false };
    }
  },
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
    // Hardening (auditoria 2026-05-18): si el caller manda `rol: 0` /
    // `rol: false` / `rol: null` con tipos raros, antes
    // `request.data.rol.toString()` crasheaba (TypeError) y el callable
    // devolvia "internal" en lugar de "invalid-argument". Coercion
    // explicita con `String(... ?? '')`.
    const dni = String(request.data?.dni ?? "").trim();
    const rolRawStr = String(request.data?.rol ?? "").trim().toUpperCase();
    const areaRawStr = String(request.data?.area ?? "").trim().toUpperCase();
    const rolNuevoRaw = rolRawStr.length > 0 ? rolRawStr : null;
    const areaNuevaRaw = areaRawStr.length > 0 ? areaRawStr : null;

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
    // `propagacionOk`: true si el cambio se propaga ya (sesión revocada o
    // sin sesión activa). false SOLO si hay una sesión viva que no pudimos
    // cortar → el cliente avisa que el afectado debe re-loguear.
    let propagacionOk = false;
    try {
      await auth.setCustomUserClaims(dni, {
        rol: rolFinal,
        area: areaFinal,
        nombre,
      });
      // FIX seguridad (auditoria 2026-05-16): sin esto, el cliente
      // afectado seguia usando su JWT viejo (con el rol anterior) hasta
      // la rotacion natural (~1 hora) o hasta que se relogueara. Si el
      // admin BAJO de rol a alguien (ej. SUPERVISOR -> CHOFER), durante
      // esa ventana el usuario seguia accediendo a rutas admin via las
      // rules que validan el JWT.
      // revokeRefreshTokens invalida los refresh tokens del usuario —
      // el cliente recibe error en el siguiente getIdToken() y tiene
      // que re-loguear (donde recibe el JWT nuevo con el claim correcto).
      // Disruptivo (corta sesion activa) pero correcto: el cambio de
      // rol debe propagarse inmediato, no dejar que el usuario siga con
      // privilegios obsoletos.
      try {
        await auth.revokeRefreshTokens(dni);
        propagacionOk = true;
        logger.info("[actualizarRolEmpleado] tokens revocados, usuario debera re-loguear", {
          dniHash: hashId(dni),
        });
      } catch (e) {
        logger.warn("[actualizarRolEmpleado] no se pudo revocar tokens", {
          dniHash: hashId(dni),
          error: (e as Error).message,
        });
      }
      logger.info("[actualizarRolEmpleado] claim actualizado", {
        dniHash: hashId(dni),
        rolNuevo: rolFinal,
        areaNueva: areaFinal,
      });
    } catch (e) {
      // Sin Auth account (nunca logueó): no hay sesión que cortar, el rol
      // aplica en el próximo login → estado consistente.
      propagacionOk = true;
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
      propagacionOk,
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

    // Eventos Sitrack: snapshot del chofer en cada evento. Sin esto, el
    // modulo ICM, el resumen Molina y la actividad del chofer veian
    // data huerfana del DNI viejo. (Auditoria 2026-05-16.)
    await actualizarReferencias("SITRACK_EVENTOS", "driver_dni");

    // Jornadas v2 (vigilador de manejo). El cron cargarJornadaAbierta
    // busca por chofer_dni — sin esta cascada, el chofer renombrado
    // pierde su jornada abierta y el vigilador arranca una nueva al
    // instante con cuota a cero.
    await actualizarReferencias("JORNADAS", "chofer_dni");

    // Adelantos al chofer. Sin esto el recibo se desasocia del nuevo
    // legajo y el chofer ve "cero adelantos" en su perfil mientras los
    // viejos siguen aplicados a otro DNI.
    await actualizarReferencias("ADELANTOS_CHOFER", "chofer_dni");

    // Throttle del aviso "pasá el iButton". Si la usa el cron sin
    // updatear, el chofer renombrado vuelve a recibir spam cada 30 min
    // como si fuera nuevo en el sistema.
    await actualizarReferencias("META_AVISOS_NO_ID", "dni");

    // BOT_SILENCIADOS_CHOFER: el docId es el DNI mismo (no un campo).
    // Si el chofer estaba silenciado por el bot, hay que mover el doc.
    try {
      const silRef = db.collection("BOT_SILENCIADOS_CHOFER").doc(dniViejo);
      const silSnap = await silRef.get();
      if (silSnap.exists) {
        await db.collection("BOT_SILENCIADOS_CHOFER")
          .doc(dniNuevo)
          .set(silSnap.data() ?? {});
        await silRef.delete();
        cascada.push({
          coleccion: "BOT_SILENCIADOS_CHOFER", actualizados: 1, error: null,
        });
      } else {
        cascada.push({
          coleccion: "BOT_SILENCIADOS_CHOFER", actualizados: 0, error: null,
        });
      }
    } catch (e) {
      cascada.push({
        coleccion: "BOT_SILENCIADOS_CHOFER",
        actualizados: 0,
        error: (e as Error).message,
      });
    }

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
// ──────────────────────────────────────────────────────────────────────────
// Rate limit por IP (auditoria 2026-05-18)
// ──────────────────────────────────────────────────────────────────────────
// Suplemento al rate limit por DNI. Ventana DESLIZANTE de 5 min, max 10
// intentos fallidos por IP. Si supera el max, bloquea 5 min adicionales.
//
// Diferencia con el throttle por DNI:
//  - Por DNI: cuenta intentos CONSECUTIVOS a un DNI especifico (3 → 15 min).
//  - Por IP: cuenta intentos en una VENTANA de tiempo, sin importar qué DNI.
//
// Threshold mas alto (10 vs 3) porque la IP puede ser compartida (NAT, oficina
// con varios choferes) y queremos minimizar falsos positivos en operaciones
// legitimas.
const MAX_INTENTOS_IP = 10;
const VENTANA_IP_MS = 5 * 60 * 1000;
const BLOQUEO_IP_MS = 5 * 60 * 1000;

async function chequearBloqueoIp(ipHash: string): Promise<number> {
  const ref = db.collection("LOGIN_ATTEMPTS_IP").doc(ipHash);
  const snap = await ref.get();
  if (!snap.exists) return 0;
  const data = snap.data() ?? {};
  const bloqueadoHasta = data.bloqueadoHasta as Timestamp | undefined;
  if (!bloqueadoHasta) return 0;
  const restanteMs = bloqueadoHasta.toMillis() - Date.now();
  if (restanteMs <= 0) return 0;
  return Math.ceil(restanteMs / 60000);
}

async function registrarIntentoFallidoIp(ipHash: string): Promise<void> {
  const ref = db.collection("LOGIN_ATTEMPTS_IP").doc(ipHash);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? snap.data() ?? {} : {};
    const ahora = Date.now();
    const ventanaInicio = data.ventanaInicio as Timestamp | undefined;
    const intentosPrevios = Number(data.intentos ?? 0);
    let intentos: number;
    let ventanaInicioNueva: Timestamp;
    if (!ventanaInicio || ahora - ventanaInicio.toMillis() > VENTANA_IP_MS) {
      // Nueva ventana
      intentos = 1;
      ventanaInicioNueva = Timestamp.fromMillis(ahora);
    } else {
      intentos = (Number.isFinite(intentosPrevios) ? intentosPrevios : 0) + 1;
      ventanaInicioNueva = ventanaInicio;
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const update: { [k: string]: any } = {
      intentos,
      ventanaInicio: ventanaInicioNueva,
      ultimoIntento: FieldValue.serverTimestamp(),
    };
    if (intentos >= MAX_INTENTOS_IP) {
      update.bloqueadoHasta = Timestamp.fromMillis(ahora + BLOQUEO_IP_MS);
    }
    if (snap.exists) {
      tx.update(ref, update);
    } else {
      tx.set(ref, update);
    }
  });
}

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
