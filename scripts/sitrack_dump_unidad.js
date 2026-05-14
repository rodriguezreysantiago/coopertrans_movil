// Dump completo del doc SITRACK_POSICIONES/{patente} en Firestore.
// Útil para ver TODO lo que el cron poller persistió en el último
// ciclo (timestamps, ignition, speed, eventos, etc.) sin tener que
// abrir la Firestore console.
//
// USO:
//   node scripts/sitrack_dump_unidad.js <PATENTE>

const path = require('path');
const fsNode = require('fs');

const botDir = path.resolve(__dirname, '..', 'whatsapp-bot');
module.paths.unshift(path.join(botDir, 'node_modules'));
process.chdir(botDir);
require('dotenv').config({ quiet: true });

const admin = require('firebase-admin');
const credPath = process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
admin.initializeApp({
  credential: admin.credential.cert(require(path.resolve(credPath))),
  projectId: process.env.FIREBASE_PROJECT_ID || 'coopertrans-movil',
});
const db = admin.firestore();

const patente = (process.argv[2] || '').trim().toUpperCase();
if (!patente) {
  console.error('Uso: node scripts/sitrack_dump_unidad.js <PATENTE>');
  process.exit(1);
}

function fmt(v) {
  if (v && typeof v.toDate === 'function') {
    return v.toDate().toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires' });
  }
  return JSON.stringify(v);
}

async function main() {
  const snap = await db.collection('SITRACK_POSICIONES').doc(patente).get();
  if (!snap.exists) {
    console.log(`SITRACK_POSICIONES/${patente} no existe`);
    process.exit(0);
  }
  const d = snap.data();
  console.log(`\n📍 SITRACK_POSICIONES/${patente}\n`);
  const keys = Object.keys(d).sort();
  for (const k of keys) {
    console.log(`  ${k.padEnd(28)}: ${fmt(d[k])}`);
  }

  // Cálculos derivados
  console.log('\n── Derivados ──');
  if (d.consultado_en) {
    const sec = Math.floor((Date.now() - d.consultado_en.toMillis()) / 1000);
    console.log(`  consultado hace            : ${Math.floor(sec / 60)}m ${sec % 60}s`);
  }
  if (d.report_date) {
    const sec = Math.floor((Date.now() - d.report_date.toMillis()) / 1000);
    console.log(`  reportado hace             : ${Math.floor(sec / 60)}m ${sec % 60}s`);
  }
  if (d.ignition_date) {
    const sec = Math.floor((Date.now() - d.ignition_date.toMillis()) / 1000);
    console.log(`  ignition_date hace         : ${Math.floor(sec / 60)}m ${sec % 60}s`);
  }

  process.exit(0);
}

main().catch((e) => {
  console.error('❌', e.stack || e.message);
  process.exit(1);
});
