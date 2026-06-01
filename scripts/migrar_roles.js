// Script one-shot de migración del modelo de roles (Hito 5).
//
// Migra los empleados existentes al modelo nuevo:
//   ROL legacy 'USER' / 'USUARIO' → 'CHOFER'.
//   ROL legacy 'ADMIN'            → se mantiene 'ADMIN'.
//   AREA inexistente              → se asigna según ROL:
//     - ADMIN/SUPERVISOR  → ADMINISTRACION
//     - CHOFER            → MANEJO
//     - PLANTA            → PLANTA
//
// Después de actualizar el doc, refresca el custom claim del usuario
// con `auth.setCustomUserClaims` para que su próximo login tenga el
// rol correcto. Si el usuario nunca se logueó (no tiene Auth account),
// salteamos esa parte sin error — `loginConDni` lo setea cuando
// finalmente se loguea.
//
// IDEMPOTENTE: si un doc ya tiene ROL nuevo y AREA, lo saltea sin
// tocarlo. Podés correrlo varias veces sin riesgo.
//
// USO:
//   cd whatsapp-bot   (necesitamos sus node_modules + serviceAccountKey)
//   node ../scripts/migrar_roles.js              (dry-run, no escribe)
//   node ../scripts/migrar_roles.js --apply      (escribe los cambios)

const path = require('path');
const fsNode = require('fs');

// Reusamos los node_modules y el .env del bot. Como el script vive en
// `scripts/` (no tiene su propio node_modules), agregamos manualmente
// el path de `whatsapp-bot/node_modules` al resolver para que los
// require()s siguientes encuentren dotenv y firebase-admin.
const botDir = path.resolve(__dirname, '..', 'whatsapp-bot');
const botNodeModules = path.join(botDir, 'node_modules');
if (!fsNode.existsSync(botNodeModules)) {
  console.error(
    `❌ No existe ${botNodeModules}. Corré 'npm install' en whatsapp-bot primero.`
  );
  process.exit(1);
}
module.paths.unshift(botNodeModules);
process.chdir(botDir);
require('dotenv').config({ quiet: true });

const admin = require('firebase-admin');

const credPath =
  process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
const absPath = path.resolve(credPath);
if (!fsNode.existsSync(absPath)) {
  console.error(`❌ Credenciales no encontradas en: ${absPath}`);
  process.exit(1);
}

admin.initializeApp({
  credential: admin.credential.cert(require(absPath)),
  projectId: process.env.FIREBASE_PROJECT_ID || 'coopertrans-movil',
});

const db = admin.firestore();
const auth = admin.auth();

// OJO: esta lista DEBE incluir los 6 roles. Si falta alguno, planearMigracion
// lo degrada a CHOFER (abajo) — bug histórico: faltaban GOMERIA y SEG_HIGIENE,
// así que re-correr el script degradaba a esos roles. Mantener sincronizada con
// ROLES_VALIDOS de functions/src/auth.ts y AppRoles de la app. (fix 2026-06-01)
const ROLES_VALIDOS = ['CHOFER', 'PLANTA', 'GOMERIA', 'SEG_HIGIENE', 'SUPERVISOR', 'ADMIN'];
const AREAS_VALIDAS = [
  'MANEJO',
  'ADMINISTRACION',
  'PLANTA',
  'TALLER',
  'GOMERIA',
];

const dryRun = !process.argv.includes('--apply');

/**
 * Devuelve el rol normalizado y el área inferida para un doc legacy.
 * Si el doc ya está bien formado, devuelve `null` (no requiere migración).
 */
function planearMigracion(data) {
  const rolActual = String(data.ROL || '').toUpperCase().trim();
  const areaActual = String(data.AREA || '').toUpperCase().trim();

  // Normalización del rol.
  let rolNuevo = rolActual;
  if (rolActual === 'USER' || rolActual === 'USUARIO' || rolActual === '') {
    rolNuevo = 'CHOFER';
  }
  if (!ROLES_VALIDOS.includes(rolNuevo)) {
    rolNuevo = 'CHOFER'; // fallback conservador
  }

  // Inferencia del área si no está cargada.
  let areaNuevaInferida = areaActual;
  if (!AREAS_VALIDAS.includes(areaActual)) {
    if (rolNuevo === 'ADMIN' || rolNuevo === 'SUPERVISOR' ||
        rolNuevo === 'SEG_HIGIENE') {
      areaNuevaInferida = 'ADMINISTRACION';
    } else if (rolNuevo === 'PLANTA') {
      areaNuevaInferida = 'PLANTA';
    } else if (rolNuevo === 'GOMERIA') {
      areaNuevaInferida = 'GOMERIA';
    } else {
      areaNuevaInferida = 'MANEJO';
    }
  }

  // ¿Hace falta cambiar algo?
  const cambioRol = rolNuevo !== rolActual;
  const cambioArea = areaNuevaInferida !== areaActual;
  if (!cambioRol && !cambioArea) return null;

  return {
    rolAntes: rolActual || '(vacío)',
    rolDespues: rolNuevo,
    areaAntes: areaActual || '(vacío)',
    areaDespues: areaNuevaInferida,
    cambioRol,
    cambioArea,
  };
}

async function main() {
  console.log(`🔄 Migración de roles ${dryRun ? '(DRY-RUN)' : '(APPLY)'}`);
  console.log(`   Proyecto: ${admin.app().options.projectId}`);
  console.log('');

  const snap = await db.collection('EMPLEADOS').get();
  console.log(`📊 ${snap.size} empleados en EMPLEADOS.\n`);

  let actualizados = 0;
  let salteados = 0;
  let claimsActualizados = 0;
  let claimsSalteados = 0;

  for (const doc of snap.docs) {
    const dni = doc.id;
    const data = doc.data();
    const nombre = String(data.NOMBRE || '?');

    const plan = planearMigracion(data);
    if (!plan) {
      salteados++;
      continue;
    }

    const cambios = [];
    if (plan.cambioRol) cambios.push(`ROL: ${plan.rolAntes} → ${plan.rolDespues}`);
    if (plan.cambioArea) cambios.push(`AREA: ${plan.areaAntes} → ${plan.areaDespues}`);
    console.log(`  • ${dni}  ${nombre}`);
    cambios.forEach((c) => console.log(`      ${c}`));

    if (dryRun) continue;

    // ─── Update Firestore ─────────────────────────────────────────
    const updates = {
      fecha_migracion_roles: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (plan.cambioRol) updates.ROL = plan.rolDespues;
    if (plan.cambioArea) updates.AREA = plan.areaDespues;

    try {
      await doc.ref.update(updates);
      actualizados++;
    } catch (e) {
      console.error(`      ❌ Falló update Firestore: ${e.message}`);
      continue;
    }

    // ─── Refresh custom claim (si el user existe en Auth) ──────────
    try {
      await auth.setCustomUserClaims(dni, {
        rol: plan.rolDespues,
        area: plan.areaDespues,
        nombre,
      });
      claimsActualizados++;
    } catch (e) {
      // Caso típico: usuario que nunca se logueó. loginConDni lo
      // resuelve cuando finalmente entre.
      if ((e.code || '').toString().includes('user-not-found')) {
        claimsSalteados++;
      } else {
        console.error(`      ⚠ Claim no se pudo actualizar: ${e.message}`);
      }
    }
  }

  console.log('');
  console.log('───────────────── RESUMEN ─────────────────');
  console.log(`  Empleados procesados : ${snap.size}`);
  console.log(`  Sin cambios          : ${salteados}`);
  console.log(`  Actualizados         : ${actualizados}`);
  console.log(`  Custom claims (OK)   : ${claimsActualizados}`);
  console.log(`  Custom claims (skip) : ${claimsSalteados}  (usuarios que nunca se logueron)`);
  console.log('');

  if (dryRun) {
    console.log('ℹ️  Esto fue un DRY-RUN — no se escribió nada.');
    console.log('   Si lo que se imprimió arriba es lo esperado, corré con --apply:');
    console.log('   node ../scripts/migrar_roles.js --apply');
  } else {
    console.log('✓ Migración completa.');
  }

  process.exit(0);
}

main().catch((e) => {
  console.error('❌ Falló:', e.stack || e.message);
  process.exit(1);
});
