// Devuelve el DNI + nombre del chofer asignado a una patente. Útil
// para arrancar otros diagnósticos (vigilador, no_id, etc.) cuando
// solo tenés la patente.
//
// USO:
//   node scripts/buscar_chofer_por_patente.js <PATENTE>

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
  console.error('Uso: node scripts/buscar_chofer_por_patente.js <PATENTE>');
  process.exit(1);
}

async function main() {
  console.log(`\n🔎 Buscando chofer para ${patente}\n`);

  // 1) Asignación activa en ASIGNACIONES_VEHICULO
  const asig = await db.collection('ASIGNACIONES_VEHICULO')
    .where('vehiculo_id', '==', patente)
    .where('hasta', '==', null)
    .get();
  if (asig.empty) {
    console.log('ASIGNACIONES_VEHICULO: (sin asignación activa)');
  } else {
    asig.docs.forEach((d) => {
      const x = d.data();
      console.log('ASIGNACIONES_VEHICULO:');
      console.log(`  chofer_dni    : ${x.chofer_dni}`);
      console.log(`  chofer_nombre : ${x.chofer_nombre}`);
    });
  }

  // 2) EMPLEADOS por VEHICULO (denormalizado)
  console.log('');
  const emp = await db.collection('EMPLEADOS')
    .where('VEHICULO', '==', patente)
    .get();
  if (emp.empty) {
    console.log('EMPLEADOS por VEHICULO: (no hay)');
  } else {
    emp.docs.forEach((d) => {
      const x = d.data();
      console.log(`EMPLEADOS/${d.id}:`);
      console.log(`  NOMBRE   : ${x.NOMBRE}`);
      console.log(`  ROL      : ${x.ROL}`);
      console.log(`  ENGANCHE : ${x.ENGANCHE || '(sin)'}`);
    });
  }

  // 3) SITRACK_POSICIONES (último driver detectado)
  console.log('');
  const sit = await db.collection('SITRACK_POSICIONES').doc(patente).get();
  if (sit.exists) {
    const x = sit.data();
    console.log(`SITRACK_POSICIONES/${patente}:`);
    console.log(`  driver_dni     : ${x.driver_dni || '(vacío)'}`);
    console.log(`  driver_nombre  : ${x.driver_nombre || '(vacío)'}`);
    console.log(`  driver_apellido: ${x.driver_apellido || '(vacío)'}`);
  } else {
    console.log(`SITRACK_POSICIONES/${patente}: (no existe)`);
  }
  process.exit(0);
}

main().catch((e) => {
  console.error('❌', e.stack || e.message);
  process.exit(1);
});
