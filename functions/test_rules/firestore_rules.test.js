// Tests de firestore.rules contra el EMULADOR (auditoría 2026-06-12, #12 —
// las rules tenían 1.500+ líneas con fixes de seguridad no triviales y CERO
// tests: cualquier regresión era silenciosa).
//
// Corre con: npm run test:rules   (levanta el emulador, corre, lo baja)
// Requiere Java (Temurin 21 instalado 2026-06-12) + firebase-tools.
//
// Modelo de auth real: custom token con uid = DNI y claim `rol` (ver
// loginConDni). Acá se simula con authenticatedContext(dni, { rol }).
//
// Invariantes cubiertos (los que protegen plata/datos/privilegios):
//   - catch-all deny (hasta para ADMIN, en colecciones sin regla)
//   - chofer: SU legajo sí / ajeno no; whitelist self-service (TELEFONO sí,
//     CONTRASEÑA NO — fix brute-force offline 2026-05-17)
//   - supervisor: no puede tocar ACTIVO/ROL/CONTRASEÑA (fix escalada de
//     privilegios: supervisor haciéndose ROL='ADMIN'), no borra empleados
//   - REGISTRO_JORNADAS: el chofer SOLO lee las suyas (transparencia v3)
//   - VIAJES_LOGISTICA / ADELANTOS_CHOFER: solo admin/supervisor (plata)
//   - GOMERIA lee EMPLEADOS (decisión 2026-06-03, bug RIOS GABRIEL) pero
//     NO logística
//   - AGENTE_CONVERSACIONES legible por admin (regresión del bug #3 de la
//     auditoría: sin regla, el dashboard moría con permission-denied)
//   - BOT_CONTROL: write SOLO admin (pausar el bot es decisión deliberada)
//   - CRON_HEALTH: read admin, write false (cron de los crons)

const { test, describe, before, after } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');
const {
  doc, getDoc, getDocs, setDoc, updateDoc, deleteDoc,
  collection, query, where,
} = require('firebase/firestore');

const RULES = fs.readFileSync(
  path.resolve(__dirname, '..', '..', 'firestore.rules'), 'utf8',
);

const DNI_CHOFER = '16969961';
const DNI_OTRO = '22222222';

let env;
const db = (dni, rol) =>
  env.authenticatedContext(dni, { rol }).firestore();
const anon = () => env.unauthenticatedContext().firestore();

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test-coopertrans',
    firestore: { rules: RULES },
  });
  // Seed con las rules deshabilitadas (Admin SDK simulado).
  await env.withSecurityRulesDisabled(async (ctx) => {
    const d = ctx.firestore();
    // OJO con el shape: la regla self-service valida
    // `request.resource.data.MAIL == null || ... is string` — si la KEY no
    // existe en el doc, el acceso falla y la regla deniega. El alta real
    // siempre escribe MAIL/ARCHIVO_PERFIL (aunque sea null), así que el
    // seed replica ese shape. Si este test rompe por un doc sin esas keys,
    // el fix correcto es endurecer la regla con `!('MAIL' in ...)`.
    await setDoc(doc(d, 'EMPLEADOS', DNI_CHOFER), {
      NOMBRE: 'CHOFER TEST', ROL: 'CHOFER', ACTIVO: true,
      TELEFONO: '+549291000000', MAIL: null, ARCHIVO_PERFIL: null,
      CONTRASEÑA: 'hash-bcrypt',
    });
    await setDoc(doc(d, 'EMPLEADOS', DNI_OTRO), {
      NOMBRE: 'OTRO CHOFER', ROL: 'CHOFER', ACTIVO: true,
      CONTRASEÑA: 'hash-bcrypt-2',
    });
    await setDoc(doc(d, 'REGISTRO_JORNADAS', `${DNI_CHOFER}_2026-06-11`), {
      chofer_dni: DNI_CHOFER, fecha: '2026-06-11', manejoNetoSeg: 3600,
    });
    await setDoc(doc(d, 'REGISTRO_JORNADAS', `${DNI_OTRO}_2026-06-11`), {
      chofer_dni: DNI_OTRO, fecha: '2026-06-11', manejoNetoSeg: 7200,
    });
    await setDoc(doc(d, 'VIAJES_LOGISTICA', 'v1'), {
      chofer_dni: DNI_CHOFER, monto_chofer: 18000, activo: true,
    });
    await setDoc(doc(d, 'ADELANTOS_CHOFER', 'a1'), {
      chofer_dni: DNI_CHOFER, monto: 50000,
    });
    await setDoc(doc(d, 'AGENTE_CONVERSACIONES', 'c1'), {
      dni: DNI_CHOFER, pregunta: '¿cuándo vence mi licencia?',
    });
    await setDoc(doc(d, 'BOT_CONTROL', 'main'), { pausado: false });
    await setDoc(doc(d, 'CRON_HEALTH', 'sitrackPosicionPoller'), {
      ultimo_ok: new Date(),
    });
    await setDoc(doc(d, 'COLA_PUSH', 'p1'), { dni: DNI_CHOFER, titulo: 'x' });
    // Credencial aislada (hardening 2026-06-13): el hash vive en la subcolección
    // con read:if false. Se seedea para que los tests de "no se puede leer"
    // sean significativos (aunque read:false falla exista o no el doc).
    await setDoc(doc(d, 'EMPLEADOS', DNI_CHOFER, 'credenciales', 'main'), {
      hash: 'hash-bcrypt', formato: 'bcrypt',
    });
  });
});

after(async () => {
  await env.cleanup();
});

describe('sin autenticar', () => {
  test('no lee EMPLEADOS', () =>
    assertFails(getDoc(doc(anon(), 'EMPLEADOS', DNI_CHOFER))));
  test('no lee una colección sin regla (catch-all)', () =>
    assertFails(getDoc(doc(anon(), 'COLECCION_INVENTADA', 'x'))));
});

describe('CHOFER — legajo propio y whitelist self-service', () => {
  test('lee SU legajo', () =>
    assertSucceeds(getDoc(doc(db(DNI_CHOFER, 'CHOFER'), 'EMPLEADOS', DNI_CHOFER))));
  test('NO lee el legajo de otro', () =>
    assertFails(getDoc(doc(db(DNI_CHOFER, 'CHOFER'), 'EMPLEADOS', DNI_OTRO))));
  test('NO crea empleados', () =>
    assertFails(setDoc(doc(db(DNI_CHOFER, 'CHOFER'), 'EMPLEADOS', '99999999'), {
      NOMBRE: 'INTRUSO',
    })));
  test('puede actualizar su TELEFONO (self-service)', () =>
    assertSucceeds(updateDoc(doc(db(DNI_CHOFER, 'CHOFER'), 'EMPLEADOS', DNI_CHOFER), {
      TELEFONO: '+549291111111',
    })));
  test('NO puede pisar su hash de CONTRASEÑA (fix 2026-05-17: el cambio de pass va por callable con validación server-side)', () =>
    assertFails(updateDoc(doc(db(DNI_CHOFER, 'CHOFER'), 'EMPLEADOS', DNI_CHOFER), {
      CONTRASEÑA: 'hash-elegido-por-el-atacante',
    })));
  test('NO puede auto-ascenderse de ROL', () =>
    assertFails(updateDoc(doc(db(DNI_CHOFER, 'CHOFER'), 'EMPLEADOS', DNI_CHOFER), {
      ROL: 'ADMIN',
    })));
  test('NO actualiza el teléfono de otro', () =>
    assertFails(updateDoc(doc(db(DNI_CHOFER, 'CHOFER'), 'EMPLEADOS', DNI_OTRO), {
      TELEFONO: '+549290000000',
    })));
});

describe('CHOFER — jornadas y plata', () => {
  test('lee SUS jornadas v3 (query por chofer_dni propio)', () =>
    assertSucceeds(getDocs(query(
      collection(db(DNI_CHOFER, 'CHOFER'), 'REGISTRO_JORNADAS'),
      where('chofer_dni', '==', DNI_CHOFER),
    ))));
  test('NO lee la jornada de otro chofer', () =>
    assertFails(getDoc(doc(db(DNI_CHOFER, 'CHOFER'),
      'REGISTRO_JORNADAS', `${DNI_OTRO}_2026-06-11`))));
  test('NO escribe jornadas (solo la CF por Admin SDK)', () =>
    assertFails(setDoc(doc(db(DNI_CHOFER, 'CHOFER'),
      'REGISTRO_JORNADAS', `${DNI_CHOFER}_2026-06-12`), { manejoNetoSeg: 0 })));
  test('NO lee VIAJES_LOGISTICA (la liquidación es de administración; si algún día se abre el portal del chofer, este test documenta el cambio)', () =>
    assertFails(getDoc(doc(db(DNI_CHOFER, 'CHOFER'), 'VIAJES_LOGISTICA', 'v1'))));
  test('NO lee ADELANTOS_CHOFER', () =>
    assertFails(getDoc(doc(db(DNI_CHOFER, 'CHOFER'), 'ADELANTOS_CHOFER', 'a1'))));
  test('NO lee las conversaciones del agente IA', () =>
    assertFails(getDoc(doc(db(DNI_CHOFER, 'CHOFER'), 'AGENTE_CONVERSACIONES', 'c1'))));
});

describe('Push — tokens de dispositivo y COLA_PUSH', () => {
  test('el chofer registra SU propio token de dispositivo (FCM)', () =>
    assertSucceeds(setDoc(
      doc(db(DNI_CHOFER, 'CHOFER'),
        'EMPLEADOS', DNI_CHOFER, 'dispositivos', 'install-1'),
      { token: 'fcm-abc', plataforma: 'android' })));
  test('el chofer NO registra un token en el legajo de otro', () =>
    assertFails(setDoc(
      doc(db(DNI_CHOFER, 'CHOFER'),
        'EMPLEADOS', DNI_OTRO, 'dispositivos', 'install-x'),
      { token: 'fcm-xyz' })));
  test('COLA_PUSH es server-only: ni el admin la lee/escribe desde el cliente',
    async () => {
      await assertFails(getDoc(doc(db('11111111', 'ADMIN'), 'COLA_PUSH', 'p1')));
      await assertFails(setDoc(doc(db('11111111', 'ADMIN'), 'COLA_PUSH', 'p2'),
        { dni: DNI_CHOFER, titulo: 'x' }));
    });
});

describe('Credenciales — hash de contraseña aislado (hardening 2026-06-13)', () => {
  // CORE del hardening: el hash vive en EMPLEADOS/{dni}/credenciales/main con
  // read:if false → NADIE lo lee desde el cliente, se cierra el brute-force
  // offline. Lectura/escritura server-side va por Admin SDK (bypassea rules).
  test('el chofer NO lee su propia credencial (read:if false)', () =>
    assertFails(getDoc(doc(db(DNI_CHOFER, 'CHOFER'),
      'EMPLEADOS', DNI_CHOFER, 'credenciales', 'main'))));
  test('el ADMIN tampoco lee la credencial (read:if false para TODOS)', () =>
    assertFails(getDoc(doc(db('11111111', 'ADMIN'),
      'EMPLEADOS', DNI_CHOFER, 'credenciales', 'main'))));
  test('el SUPERVISOR tampoco lee la credencial', () =>
    assertFails(getDoc(doc(db('55555555', 'SUPERVISOR'),
      'EMPLEADOS', DNI_CHOFER, 'credenciales', 'main'))));
  test('admin/supervisor SÍ crean la credencial inicial (alta del empleado)', () =>
    assertSucceeds(setDoc(doc(db('55555555', 'SUPERVISOR'),
      'EMPLEADOS', '77777777', 'credenciales', 'main'),
    { hash: 'h-inicial', formato: 'bcrypt' })));
  test('el chofer NO crea credenciales (ni la suya)', () =>
    assertFails(setDoc(doc(db(DNI_CHOFER, 'CHOFER'),
      'EMPLEADOS', DNI_CHOFER, 'credenciales', 'main'),
    { hash: 'elegido-por-atacante' })));
  test('NADIE actualiza la credencial desde el cliente (el cambio va por callable)', () =>
    assertFails(updateDoc(doc(db('55555555', 'SUPERVISOR'),
      'EMPLEADOS', DNI_CHOFER, 'credenciales', 'main'),
    { hash: 'pisado' })));
  test('NADIE borra la credencial desde el cliente', () =>
    assertFails(deleteDoc(doc(db('11111111', 'ADMIN'),
      'EMPLEADOS', DNI_CHOFER, 'credenciales', 'main'))));
});

describe('GOMERIA — acceso acotado a su módulo', () => {
  test('SÍ lee EMPLEADOS (decisión 2026-06-03: el hub cruza unidades con choferes — bug RIOS GABRIEL)', () =>
    assertSucceeds(getDoc(doc(db('33333333', 'GOMERIA'), 'EMPLEADOS', DNI_CHOFER))));
  test('NO lee la logística', () =>
    assertFails(getDoc(doc(db('33333333', 'GOMERIA'), 'VIAJES_LOGISTICA', 'v1'))));
  test('NO lee adelantos', () =>
    assertFails(getDoc(doc(db('33333333', 'GOMERIA'), 'ADELANTOS_CHOFER', 'a1'))));
});

describe('SEG_HIGIENE — tableros sí, gestión no', () => {
  test('lee jornadas de cualquier chofer (puedeVerVolvoTableros)', () =>
    assertSucceeds(getDoc(doc(db('44444444', 'SEG_HIGIENE'),
      'REGISTRO_JORNADAS', `${DNI_OTRO}_2026-06-11`))));
  test('NO crea empleados', () =>
    assertFails(setDoc(doc(db('44444444', 'SEG_HIGIENE'), 'EMPLEADOS', '99999999'), {
      NOMBRE: 'X',
    })));
  test('NO lee la logística', () =>
    assertFails(getDoc(doc(db('44444444', 'SEG_HIGIENE'), 'VIAJES_LOGISTICA', 'v1'))));
});

describe('SUPERVISOR — gestiona, pero sin escalada', () => {
  test('crea empleados', () =>
    assertSucceeds(setDoc(doc(db('55555555', 'SUPERVISOR'), 'EMPLEADOS', '88888888'), {
      NOMBRE: 'ALTA SUPERVISOR', ROL: 'CHOFER', ACTIVO: true,
    })));
  test('actualiza datos comunes de un empleado', () =>
    assertSucceeds(updateDoc(doc(db('55555555', 'SUPERVISOR'), 'EMPLEADOS', DNI_OTRO), {
      NOMBRE: 'OTRO CHOFER EDITADO',
    })));
  test('NO puede cambiar ROL (fix escalada: supervisor haciéndose ADMIN)', () =>
    assertFails(updateDoc(doc(db('55555555', 'SUPERVISOR'), 'EMPLEADOS', DNI_OTRO), {
      ROL: 'ADMIN',
    })));
  test('NO puede pisar CONTRASEÑA', () =>
    assertFails(updateDoc(doc(db('55555555', 'SUPERVISOR'), 'EMPLEADOS', DNI_OTRO), {
      CONTRASEÑA: 'hash-nuevo',
    })));
  test('NO puede dar de baja (ACTIVO es solo-ADMIN desde 2026-06-01)', () =>
    assertFails(updateDoc(doc(db('55555555', 'SUPERVISOR'), 'EMPLEADOS', DNI_OTRO), {
      ACTIVO: false,
    })));
  test('NO borra empleados (delete real es solo-ADMIN)', () =>
    assertFails(deleteDoc(doc(db('55555555', 'SUPERVISOR'), 'EMPLEADOS', DNI_OTRO))));
  test('lee BOT_CONTROL pero NO lo escribe (pausar el bot = decisión del responsable)', async () => {
    await assertSucceeds(getDoc(doc(db('55555555', 'SUPERVISOR'), 'BOT_CONTROL', 'main')));
    await assertFails(updateDoc(doc(db('55555555', 'SUPERVISOR'), 'BOT_CONTROL', 'main'), {
      pausado: true,
    }));
  });
});

describe('ADMIN — control total dentro de las reglas', () => {
  test('borra empleados', () =>
    assertSucceeds(deleteDoc(doc(db('11111111', 'ADMIN'), 'EMPLEADOS', '88888888'))));
  test('escribe BOT_CONTROL (kill-switch del bot)', () =>
    assertSucceeds(updateDoc(doc(db('11111111', 'ADMIN'), 'BOT_CONTROL', 'main'), {
      pausado: true,
    })));
  test('lee AGENTE_CONVERSACIONES (regresión bug #3: sin regla el dashboard moría con permission-denied)', () =>
    assertSucceeds(getDoc(doc(db('11111111', 'ADMIN'), 'AGENTE_CONVERSACIONES', 'c1'))));
  test('NO escribe AGENTE_CONVERSACIONES (solo el bot por Admin SDK)', () =>
    assertFails(setDoc(doc(db('11111111', 'ADMIN'), 'AGENTE_CONVERSACIONES', 'c2'), {
      dni: 'x',
    })));
  test('lee CRON_HEALTH pero NO lo escribe', async () => {
    await assertSucceeds(getDoc(doc(db('11111111', 'ADMIN'),
      'CRON_HEALTH', 'sitrackPosicionPoller')));
    await assertFails(setDoc(doc(db('11111111', 'ADMIN'), 'CRON_HEALTH', 'fake'), {
      ultimo_ok: new Date(),
    }));
  });
  test('el catch-all lo frena hasta a él en colecciones sin regla', () =>
    assertFails(setDoc(doc(db('11111111', 'ADMIN'), 'COLECCION_INVENTADA', 'x'), {
      a: 1,
    })));
});
