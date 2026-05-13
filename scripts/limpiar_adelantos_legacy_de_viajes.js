// Script one-shot para BORRAR los campos legacy de adelanto que vivían
// embebidos en los viajes (`VIAJES_LOGISTICA`) antes del refactor del
// 2026-05-13.
//
// CONTEXTO: hasta esa fecha, cada viaje tenía:
//   - adelanto_monto
//   - adelanto_fecha
//   - adelanto_observacion
//   - numero_recibo_adelanto
//   - recibo_impreso_en
//
// Después del refactor, los adelantos pasaron a una colección propia
// (`ADELANTOS_CHOFER`) y esos campos quedaron como dead data — el
// código cliente NO los lee para cálculos, pero ocupan espacio en los
// docs viejos. Como Santiago confirmó que los adelantos pre-refactor
// son data de testeo y NO se contabilizan, los borramos.
//
// QUÉ HACE:
//   Para cada viaje en VIAJES_LOGISTICA, si tiene CUALQUIERA de los 5
//   campos legacy seteado (no null), lo borra con `FieldValue.delete()`
//   en un único update por doc.
//
// IDEMPOTENTE: si un viaje ya no tiene ningún campo legacy, se saltea.
// Podés correrlo varias veces sin riesgo.
//
// SAFETY:
//   - Dry-run por default. Con --apply escribe.
//   - Procesa en batches de 400 docs (límite Firestore = 500 ops por
//     write batch, dejamos margen).
//   - NO borra los viajes — solo limpia campos sueltos. El viaje
//     entero queda intacto (chofer, tramos, montos, gastos, etc.).
//
// USO:
//   cd whatsapp-bot   (necesitamos sus node_modules + serviceAccountKey)
//   node ../scripts/limpiar_adelantos_legacy_de_viajes.js              (dry-run)
//   node ../scripts/limpiar_adelantos_legacy_de_viajes.js --apply      (escribe)

const path = require('path');
const fsNode = require('fs');

// Reusamos los node_modules y .env del bot.
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

const COL_VIAJES = 'VIAJES_LOGISTICA';

// Los 5 campos legacy a borrar. Si en el futuro aparecen otros
// (típicamente snake_case mal serializados desde el cliente Dart),
// agregarlos acá.
const CAMPOS_LEGACY = [
  'adelanto_monto',
  'adelanto_fecha',
  'adelanto_observacion',
  'numero_recibo_adelanto',
  'recibo_impreso_en',
];

const BATCH_SIZE = 400;
const dryRun = !process.argv.includes('--apply');

function tieneAlgunCampoLegacy(data) {
  return CAMPOS_LEGACY.some((k) => data[k] !== undefined && data[k] !== null);
}

function camposPresentesEn(data) {
  return CAMPOS_LEGACY.filter(
    (k) => data[k] !== undefined && data[k] !== null
  );
}

async function main() {
  console.log(
    `🧹 Limpieza de campos legacy de adelanto en ${COL_VIAJES} ${dryRun ? '(DRY-RUN)' : '(APPLY)'}`
  );
  console.log(`   Proyecto: ${admin.app().options.projectId}`);
  console.log(`   Campos a borrar: ${CAMPOS_LEGACY.join(', ')}`);
  console.log('');

  const snap = await db.collection(COL_VIAJES).get();
  console.log(`📊 ${snap.size} viajes leídos.\n`);

  let conLegacy = 0;
  let limpios = 0;
  let actualizados = 0;
  const errores = [];

  // Acumulamos updates en batches para minimizar round-trips.
  let batch = db.batch();
  let pendingInBatch = 0;

  async function flushBatch() {
    if (pendingInBatch === 0) return;
    if (dryRun) {
      pendingInBatch = 0;
      batch = db.batch();
      return;
    }
    try {
      await batch.commit();
      actualizados += pendingInBatch;
    } catch (e) {
      errores.push({ batchSize: pendingInBatch, error: e.message });
      console.error(`      ❌ Falló batch de ${pendingInBatch}: ${e.message}`);
    }
    pendingInBatch = 0;
    batch = db.batch();
  }

  for (const doc of snap.docs) {
    const viajeId = doc.id;
    const data = doc.data();

    if (!tieneAlgunCampoLegacy(data)) {
      limpios++;
      continue;
    }

    conLegacy++;
    const presentes = camposPresentesEn(data);
    console.log(`  • ${viajeId}  (campos: ${presentes.join(', ')})`);

    if (dryRun) continue;

    const update = {};
    for (const campo of presentes) {
      update[campo] = admin.firestore.FieldValue.delete();
    }
    batch.update(doc.ref, update);
    pendingInBatch++;

    if (pendingInBatch >= BATCH_SIZE) {
      await flushBatch();
    }
  }

  // Último batch parcial.
  await flushBatch();

  console.log('');
  console.log('───────────────── RESUMEN ─────────────────');
  console.log(`  Viajes procesados            : ${snap.size}`);
  console.log(`  Ya estaban limpios (saltados): ${limpios}`);
  console.log(`  Con campos legacy            : ${conLegacy}`);
  if (!dryRun) {
    console.log(`  Actualizados con éxito       : ${actualizados}`);
    console.log(`  Errores                      : ${errores.length}`);
  }
  console.log('');

  if (dryRun) {
    console.log('ℹ️  Esto fue un DRY-RUN — no se escribió nada.');
    console.log('   Si el listado de arriba es el esperado, corré con --apply:');
    console.log('   node ../scripts/limpiar_adelantos_legacy_de_viajes.js --apply');
  } else {
    console.log('✓ Limpieza completa.');
    if (errores.length > 0) {
      console.log('');
      console.log('⚠ Batches que fallaron:');
      errores.forEach((e) =>
        console.log(`   - batch de ${e.batchSize} viajes: ${e.error}`)
      );
    }
  }

  process.exit(0);
}

main().catch((e) => {
  console.error('❌ Falló:', e.stack || e.message);
  process.exit(1);
});
