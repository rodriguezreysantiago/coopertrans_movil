// Diagnóstico de un chofer: estado en EMPLEADOS (ACTIVO/rol/unidad), sus
// jornadas, y quién maneja realmente su patente (driver del iButton Sitrack).
// Uso: node scripts/diag_chofer.js VILLAVICENCIO
const path = require('path');
const fsNode = require('fs');
const admin = require('firebase-admin');
const credPath = process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
const absPath = path.resolve(credPath);
if (!fsNode.existsSync(absPath)) { console.error(`No encuentro key en ${absPath}`); process.exit(1); }
admin.initializeApp({ credential: admin.credential.cert(require(absPath)), projectId: 'coopertrans-movil' });
const db = admin.firestore();

const q = (process.argv[2] || 'VILLAVICENCIO').toUpperCase();
const tsMs = (v) => (v && v.toMillis ? v.toMillis() : null);
const fa = (v) => { const m = tsMs(v); return m ? new Date(m).toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires' }) : '—'; };
const hhmm = (s) => `${Math.floor((s || 0) / 3600)}h${String(Math.round(((s || 0) % 3600) / 60)).padStart(2, '0')}`;

(async () => {
  const emp = await db.collection('EMPLEADOS').get();
  const matches = [];
  emp.forEach((d) => { if ((d.data().NOMBRE || '').toString().toUpperCase().includes(q)) matches.push({ dni: d.id, d: d.data() }); });

  for (const { dni, d } of matches) {
    console.log(`\n══════ ${d.NOMBRE} (DNI ${dni}) ══════`);
    console.log(`  ACTIVO=${d.ACTIVO}  ROL=${d.ROL}  VEHICULO=${d.VEHICULO || '—'}  ENGANCHE=${d.ENGANCHE || '—'}`);
    const j = await db.collection('JORNADAS').where('chofer_dni', '==', dni).get();
    const docs = j.docs.map((x) => x.data()).sort((a, b) => (tsMs(b.creado_en) || 0) - (tsMs(a.creado_en) || 0));
    console.log(`  Jornadas: ${docs.length}. Más reciente:`);
    if (docs[0]) {
      const x = docs[0];
      console.log(`    estado=${x.estado}  inicio=${fa(x.jornada_inicio_ts)}  fin=${fa(x.jornada_fin_ts)}  manejo=${hhmm(x.total_manejo_seg)}  patente=${x.ultima_patente}`);
      console.log(`    cerrada_por_reparacion=${x.cerrada_por_reparacion ?? false}`);
    }
    // ¿Está en la lista de excluidos/inactivos que el vigilador respeta?
    const patente = (d.VEHICULO || d.ENGANCHE || '').toString().trim().toUpperCase();
    if (patente && patente !== '-') {
      const sit = await db.collection('SITRACK_POSICIONES').doc(patente).get();
      if (sit.exists) {
        const s = sit.data();
        console.log(`  SITRACK ${patente}: driver_dni=${s.driver_dni ?? '?'} driver=${s.driver_nombre ?? '?'} report_date=${fa(s.report_date)} speed=${s.speed} ign=${s.ignition}`);
      }
    }
  }

  // ¿Quién más tiene asignada la patente del primer match? (drift de iButton)
  const pat = (matches[0]?.d.VEHICULO || matches[0]?.d.ENGANCHE || '').toString().trim().toUpperCase();
  if (pat && pat !== '-') {
    console.log(`\n── Empleados con patente ${pat} asignada ──`);
    emp.forEach((d) => {
      const x = d.data();
      if ((x.VEHICULO || '').toUpperCase() === pat || (x.ENGANCHE || '').toUpperCase() === pat) {
        console.log(`  ${x.NOMBRE} (DNI ${d.id})  ACTIVO=${x.ACTIVO}  VEHICULO=${x.VEHICULO} ENGANCHE=${x.ENGANCHE}`);
      }
    });
  }
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
