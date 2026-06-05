// Vuelca el doc JORNADAS (vigilador v2) de uno o más choferes, tal cual lo
// calculó la Cloud Function. Diagnóstico — NO se commitea.
// Uso (desde raíz, con NODE_PATH a whatsapp-bot/node_modules):
//   node scripts/leer_jornada.js LAINA BASTIAS
const path = require('path');
const fsNode = require('fs');
const admin = require('firebase-admin');

const credPath = process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
const absPath = path.resolve(credPath);
if (!fsNode.existsSync(absPath)) { console.error(`No encuentro key en ${absPath}`); process.exit(1); }
admin.initializeApp({ credential: admin.credential.cert(require(absPath)), projectId: 'coopertrans-movil' });
const db = admin.firestore();

const nombresBuscados = process.argv.slice(2).map((s) => s.toUpperCase());
if (nombresBuscados.length === 0) nombresBuscados.push('LAINA');

function fmt(v) {
  if (v == null) return 'null';
  if (v && typeof v.toDate === 'function') {
    return v.toDate().toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires' });
  }
  if (Array.isArray(v)) return `[${v.length}] ` + JSON.stringify(v.map((x) => (x && x.toDate ? x.toDate().toISOString() : x)));
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

function volcar(id, data) {
  console.log(`\n──────── JORNADAS/${id} ────────`);
  for (const k of Object.keys(data).sort()) console.log(`  ${k}: ${fmt(data[k])}`);
}

(async () => {
  // 1) DNIs por nombre (EMPLEADOS, doc id = DNI).
  const emp = await db.collection('EMPLEADOS').get();
  const dnis = [];
  emp.forEach((d) => {
    const nom = (d.data().NOMBRE || '').toString().toUpperCase();
    if (nombresBuscados.some((b) => nom.includes(b))) dnis.push({ dni: d.id, nombre: nom });
  });
  console.log(`Choferes encontrados: ${dnis.map((x) => `${x.nombre}(${x.dni})`).join(', ') || 'NINGUNO'}`);

  // 2) Para cada DNI: todas sus jornadas, ordenadas client-side por creado_en
  // desc; muestro las 2 más recientes (la activa del 4-jun + la anterior).
  const hhmm = (seg) => `${Math.floor((seg || 0) / 3600)}h ${Math.round(((seg || 0) % 3600) / 60)}m`;
  for (const { dni, nombre } of dnis) {
    const q = await db.collection('JORNADAS').where('chofer_dni', '==', dni).get();
    if (q.empty) { console.log(`\n(sin jornadas para ${nombre} ${dni})`); continue; }
    const docs = q.docs.map((d) => ({ id: d.id, data: d.data() }));
    docs.sort((a, b) => (b.data.creado_en && b.data.creado_en.toMillis ? b.data.creado_en.toMillis() : 0)
      - (a.data.creado_en && a.data.creado_en.toMillis ? a.data.creado_en.toMillis() : 0));
    console.log(`\n##### ${nombre} (${dni}) — ${docs.length} jornadas totales, las 2 más recientes #####`);
    for (const { id, data } of docs.slice(0, 2)) {
      volcar(id, data);
      console.log(`  >>> total_manejo = ${hhmm(data.total_manejo_seg)} | descanso = ${hhmm(data.descanso_segundos)} | bloque_pausa = ${hhmm(data.bloque_actual_pausa_seg)}`);
    }
  }
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
