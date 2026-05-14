// Silencia el aviso "pasá el iButton" para un chofer puntual hasta
// la fecha que se le pase. Setea `last_sent_at` en el doc
// META_AVISOS_NO_ID/{dni} a un timestamp futuro — el cron del aviso
// usa `(Date.now() - last_sent_at) / 1000 < AVISO_NO_ID_THROTTLE_SEGUNDOS`
// para deduplicar; un last_sent_at futuro hace siempre verdadera la
// dedup, bloqueando todos los avisos hasta que vuelva al pasado.
//
// USO:
//   node scripts/silenciar_aviso_no_id.js <DNI> <horas>
//
// EJEMPLO (silenciar 24h):
//   node scripts/silenciar_aviso_no_id.js 31272549 24
//
// REVERTIR (volver a hoy):
//   node scripts/silenciar_aviso_no_id.js 31272549 0
//
// Acción reversible — no toca código ni asignaciones, solo el doc
// del throttle.

const path = require('path');
const fsNode = require('fs');

const botDir = path.resolve(__dirname, '..', 'whatsapp-bot');
const botNodeModules = path.join(botDir, 'node_modules');
if (!fsNode.existsSync(botNodeModules)) {
  console.error(`❌ No existe ${botNodeModules}`);
  process.exit(1);
}
module.paths.unshift(botNodeModules);
process.chdir(botDir);
require('dotenv').config({ quiet: true });

const admin = require('firebase-admin');
const credPath =
  process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
admin.initializeApp({
  credential: admin.credential.cert(require(path.resolve(credPath))),
  projectId: process.env.FIREBASE_PROJECT_ID || 'coopertrans-movil',
});
const db = admin.firestore();

const dni = (process.argv[2] || '').trim();
const horasArg = process.argv[3];
if (!dni || horasArg === undefined) {
  console.error('Uso: node scripts/silenciar_aviso_no_id.js <DNI> <horas>');
  console.error('  Pasá horas=0 para REVERTIR (vuelve a hoy y desbloquea).');
  process.exit(1);
}
const horas = parseFloat(horasArg);
if (Number.isNaN(horas)) {
  console.error('horas debe ser número');
  process.exit(1);
}

async function main() {
  const ms = horas * 3600 * 1000;
  const objetivo = new Date(Date.now() + ms);
  const ts = admin.firestore.Timestamp.fromDate(objetivo);

  const ref = db.collection('META_AVISOS_NO_ID').doc(dni);
  await ref.set(
    {
      last_sent_at: ts,
      last_patente: 'SILENCIADO_MANUAL',
      silenciado_hasta_iso: objetivo.toISOString(),
    },
    { merge: true }
  );

  console.log(`✓ META_AVISOS_NO_ID/${dni} actualizado.`);
  console.log(`  last_sent_at = ${objetivo.toLocaleString('es-AR')} (UTC ${objetivo.toISOString()})`);
  if (horas > 0) {
    console.log(`  → bloquea avisos durante ~${horas}h.`);
    console.log(`  → revertir: node scripts/silenciar_aviso_no_id.js ${dni} 0`);
  } else {
    console.log('  → REVERTIDO. El próximo cron puede avisar de nuevo si hay drift.');
  }
  process.exit(0);
}

main().catch((e) => {
  console.error('❌ Falló:', e.stack || e.message);
  process.exit(1);
});
