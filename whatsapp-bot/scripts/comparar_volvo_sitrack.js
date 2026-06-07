/**
 * Compara (solo lectura) la frescura del feed VOLVO vs SITRACK para las unidades
 * de los choferes que reportaron paradas no detectadas. Objetivo: evaluar si
 * priorizar VOLVO_ESTADO ayudaría a detectar pausas (opción #3).
 *
 * VOLVO_ESTADO es un SNAPSHOT (1 doc/patente, sin histórico). SITRACK_EVENTOS
 * sí tiene secuencia. Acá miramos cuán fresco está el último punto de cada uno.
 */
const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(require(path.join(__dirname, '..', '..', 'serviceAccountKey.json'))) });
const db = admin.firestore();

const UNIDADES = [
  { pat: 'AD614JT', chofer: 'FERNANDEZ' },
  { pat: 'AG218ZR', chofer: 'WEIMANN' },
  { pat: 'AF472BO', chofer: 'CHAVEZ' },
  { pat: 'AC114PY', chofer: 'LOPEZ' },
];

const min = (ms) => (ms ? `${Math.round((Date.now() - ms) / 60000)} min` : '—');
function tsMs(v) {
  if (!v) return 0;
  if (v.toMillis) return v.toMillis();
  if (typeof v === 'string') { const t = Date.parse(v); return isNaN(t) ? 0 : t; }
  if (typeof v === 'number') return v < 1e12 ? v * 1000 : v;
  return 0;
}

async function buscar(col, pat) {
  let snap = await db.collection(col).doc(pat).get();
  if (snap.exists) return snap.data();
  for (const campo of ['patente', 'dominio', 'placa']) {
    try { const q = await db.collection(col).where(campo, '==', pat).limit(1).get(); if (!q.empty) return q.docs[0].data(); } catch (_) {}
  }
  return null;
}

async function main() {
  console.log('Hora actual:', new Date().toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires' }));
  for (const u of UNIDADES) {
    console.log(`\n═══ ${u.pat} (${u.chofer}) ═══`);
    const v = await buscar('VOLVO_ESTADO', u.pat);
    if (v) {
      console.log(`  VOLVO   · último reporte real (posicion_ts): hace ${min(tsMs(v.posicion_ts))}` +
        ` · speed_kmh=${v.speed_kmh ?? '—'} · conductor=${v.conductor_estado ?? '—'}` +
        ` · poller lo consultó hace ${min(tsMs(v.consultado_en))}`);
    } else console.log('  VOLVO   · (sin doc — unidad NO integrada a Volvo)');
    const s = await buscar('SITRACK_POSICIONES', u.pat);
    if (s) {
      console.log(`  SITRACK · último reporte real (report_date): hace ${min(tsMs(s.report_date))}` +
        ` · speed=${s.speed ?? '—'} · ignition=${s.ignition ?? '—'}` +
        ` · poller lo consultó hace ${min(tsMs(s.consultado_en))}`);
    } else console.log('  SITRACK · (sin doc)');
  }

  // Panorama global: cuántas unidades tienen Volvo y cuán fresco está en promedio.
  console.log('\n═══ PANORAMA GLOBAL VOLVO_ESTADO ═══');
  const all = await db.collection('VOLVO_ESTADO').get();
  let conPos = 0, frescos10 = 0, frescos30 = 0;
  const edades = [];
  all.forEach(d => { const ms = tsMs(d.data().posicion_ts); if (ms) { conPos++; const e = (Date.now() - ms) / 60000; edades.push(e); if (e <= 10) frescos10++; if (e <= 30) frescos30++; } });
  console.log(`  unidades con Volvo: ${all.size} · con posicion_ts: ${conPos}`);
  console.log(`  con posición ≤10min: ${frescos10} · ≤30min: ${frescos30} · >30min: ${conPos - frescos30}`);
  if (edades.length) { edades.sort((a, b) => a - b); console.log(`  mediana edad posición: ${Math.round(edades[Math.floor(edades.length / 2)])} min`); }
  process.exit(0);
}
main().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
