// Diagnóstico: qué FUENTE de movimiento usaría el vigilador (Volvo vs Sitrack)
// para unas patentes. Volvo vencido = posicion_ts viejo → debería caer a
// Sitrack. Confirma si el gate de frescura descarta el Volvo congelado.
// Uso: node scripts/diag_fuente.js AC114QQ AC383OM
const path = require('path');
const fsNode = require('fs');
const admin = require('firebase-admin');
const credPath = process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
const absPath = path.resolve(credPath);
if (!fsNode.existsSync(absPath)) { console.error(`No encuentro key en ${absPath}`); process.exit(1); }
admin.initializeApp({ credential: admin.credential.cert(require(absPath)), projectId: 'coopertrans-movil' });
const db = admin.firestore();

const POLL_STALE_SEG = 10 * 60;
const patentes = process.argv.slice(2).map((s) => s.toUpperCase());
if (!patentes.length) patentes.push('AC114QQ', 'AC383OM');

const now = Date.now();
function edadMin(ms) { return ms ? Math.round((now - ms) / 60000) : null; }
function tsToMs(v) {
  if (!v) return null;
  if (typeof v.toMillis === 'function') return v.toMillis();
  if (typeof v === 'string') { const p = Date.parse(v); return Number.isFinite(p) ? p : null; }
  return null;
}

(async () => {
  for (const pat of patentes) {
    console.log(`\n════════ ${pat} ════════`);
    // VOLVO_ESTADO
    const vol = await db.collection('VOLVO_ESTADO').doc(pat).get();
    let volFresco = false;
    if (vol.exists) {
      const d = vol.data();
      const posMs = tsToMs(d.posicion_ts);
      volFresco = posMs != null && (now - posMs) / 1000 <= POLL_STALE_SEG;
      console.log(`VOLVO_ESTADO: speed_kmh=${d.speed_kmh}  posicion_ts hace ${edadMin(posMs)} min  → ${volFresco ? 'FRESCO (lo usaría)' : 'VIEJO (descarta)'}`);
      console.log(`   consultado_en hace ${edadMin(tsToMs(d.consultado_en))} min  lat=${d.lat} lng=${d.lng}`);
    } else {
      console.log('VOLVO_ESTADO: (no existe)');
    }
    // SITRACK_POSICIONES
    const sit = await db.collection('SITRACK_POSICIONES').doc(pat).get();
    let sitFresco = false;
    if (sit.exists) {
      const d = sit.data();
      const repMs = tsToMs(d.report_date);
      sitFresco = repMs != null && (now - repMs) / 1000 <= POLL_STALE_SEG;
      console.log(`SITRACK: speed=${d.speed} ignition=${d.ignition}  report_date hace ${edadMin(repMs)} min  → ${sitFresco ? 'FRESCO' : 'viejo'}`);
      console.log(`   consultado_en hace ${edadMin(tsToMs(d.consultado_en))} min  lat=${d.lat} lng=${d.lng}`);
    } else {
      console.log('SITRACK: (no existe)');
    }
    const fuente = volFresco ? 'VOLVO' : sitFresco ? 'SITRACK' : 'NINGUNA (parado fail-safe)';
    console.log(`>>> decidirManejando usaría: ${fuente}`);
  }
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
