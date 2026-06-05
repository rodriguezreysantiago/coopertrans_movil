// Monitor del vigilador de jornada: lista las jornadas ABIERTAS (activas) con
// su manejo acumulado y MARCA las sospechosas (colgadas) — manejo > 13h o
// abiertas hace > 16h. Sirve para "medir" que el vigilador anda con Sitrack
// (sin jornadas que se inflan). Diagnóstico — NO se commitea.
// Uso: node scripts/monitor_jornadas.js
const path = require('path');
const fsNode = require('fs');
const admin = require('firebase-admin');
const credPath = process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
const absPath = path.resolve(credPath);
if (!fsNode.existsSync(absPath)) { console.error(`No encuentro key en ${absPath}`); process.exit(1); }
admin.initializeApp({ credential: admin.credential.cert(require(absPath)), projectId: 'coopertrans-movil' });
const db = admin.firestore();

const now = Date.now();
const hhmm = (s) => `${Math.floor((s || 0) / 3600)}h${String(Math.round(((s || 0) % 3600) / 60)).padStart(2, '0')}`;
const tsMs = (v) => (v && v.toMillis ? v.toMillis() : null);
const fechaArt = (v) => { const m = tsMs(v); return m ? new Date(m).toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—'; };

(async () => {
  // Nombres de chofer (EMPLEADOS, doc id = DNI).
  const nombres = {};
  (await db.collection('EMPLEADOS').get()).forEach((d) => { nombres[d.id] = (d.data().NOMBRE || '').toString(); });

  // Jornadas ABIERTAS = jornada_fin_ts == null (single-field, sin índice).
  const snap = await db.collection('JORNADAS').where('jornada_fin_ts', '==', null).get();
  const filas = snap.docs.map((d) => {
    const j = d.data();
    const manejoSeg = (j.total_manejo_seg || 0) + (j.bloque_actual_manejo_seg || 0);
    const inicioMs = tsMs(j.jornada_inicio_ts);
    const horasAbierta = inicioMs ? (now - inicioMs) / 3600000 : 0;
    const sospechosa = manejoSeg > 13 * 3600 || horasAbierta > 16;
    return {
      dni: j.chofer_dni, nombre: nombres[j.chofer_dni] || `DNI ${j.chofer_dni}`,
      manejoSeg, estado: j.estado, patente: j.ultima_patente,
      inicio: fechaArt(j.jornada_inicio_ts), ultima: fechaArt(j.ultima_actualizacion_ts),
      horasAbierta, sospechosa,
    };
  }).sort((a, b) => b.manejoSeg - a.manejoSeg);

  console.log(`\n===== JORNADAS ABIERTAS: ${filas.length} =====`);
  for (const f of filas) {
    const flag = f.sospechosa ? ' ⚠️ SOSPECHOSA' : '';
    console.log(`${f.sospechosa ? '⚠️' : '  '} ${f.nombre.padEnd(28)} ${f.patente.padEnd(8)} manejo=${hhmm(f.manejoSeg).padStart(6)} estado=${(f.estado || '').padEnd(20)} inicio=${f.inicio} (${f.horasAbierta.toFixed(1)}h abierta)${flag}`);
  }
  const susp = filas.filter((f) => f.sospechosa);
  console.log(`\nSospechosas (colgadas): ${susp.length}/${filas.length}`);
  if (susp.length) console.log('  → ' + susp.map((f) => `${f.nombre} (${hhmm(f.manejoSeg)})`).join(', '));
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
