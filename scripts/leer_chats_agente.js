// Lee las últimas conversaciones del agente IA (AGENTE_CONVERSACIONES) para
// revisarlas a mano. Herramienta de análisis — NO se commitea.
//
// Uso (desde scripts/):  node leer_chats_agente.js [--n 50] [--rol CHOFER]
// Requiere serviceAccountKey.json en la raíz (mismo patrón que los demás scripts).

const path = require('path');
const fsNode = require('fs');
const admin = require('firebase-admin');

const credPath =
  process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
const absPath = path.resolve(credPath);
if (!fsNode.existsSync(absPath)) {
  console.error(`No encuentro serviceAccountKey en ${absPath}.`);
  process.exit(1);
}
admin.initializeApp({
  credential: admin.credential.cert(require(absPath)),
  projectId: process.env.FIREBASE_PROJECT_ID || 'coopertrans-movil',
});
const db = admin.firestore();

const nIdx = process.argv.indexOf('--n');
const N = nIdx > 0 ? parseInt(process.argv[nIdx + 1], 10) : 50;
const rolIdx = process.argv.indexOf('--rol');
const ROL = rolIdx > 0 ? process.argv[rolIdx + 1] : null;

function fechaArt(ts) {
  if (!ts) return '--';
  const d = ts.toDate ? ts.toDate() : new Date(ts);
  return d.toLocaleString('es-AR', {
    timeZone: 'America/Argentina/Buenos_Aires',
    day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
  });
}

function corto(s, max = 320) {
  if (s == null) return '(vacío)';
  s = String(s).replace(/\s+/g, ' ').trim();
  return s.length > max ? s.slice(0, max) + ' […]' : s;
}

(async () => {
  let q = db.collection('AGENTE_CONVERSACIONES').orderBy('creado_en', 'desc').limit(N);
  const snap = await q.get();
  let docs = snap.docs.map((d) => d.data());
  if (ROL) docs = docs.filter((d) => (d.rol || '').toUpperCase() === ROL.toUpperCase());

  if (docs.length === 0) {
    console.log('Sin conversaciones.');
    process.exit(0);
  }

  // Cronológico ascendente para leerlo como un hilo.
  docs.reverse();

  console.log(`\n===== ${docs.length} conversaciones del agente (más nuevas abajo) =====`);
  console.log(`Campos del doc: ${Object.keys(docs[docs.length - 1]).join(', ')}\n`);

  const porRol = {};
  let fallbacks = 0;
  const erroresMap = {};
  const toolsMap = {};

  for (const d of docs) {
    const rol = d.rol || '?';
    porRol[rol] = (porRol[rol] || 0) + 1;
    const tools = Array.isArray(d.tools_usadas) ? d.tools_usadas : [];
    for (const t of tools) toolsMap[t] = (toolsMap[t] || 0) + 1;
    if (d.es_fallback) {
      fallbacks++;
      const e = d.error || 'sin_error';
      erroresMap[e] = (erroresMap[e] || 0) + 1;
    }

    const quien = `${rol}${d.nombre ? ' · ' + d.nombre : ''}`;
    console.log(`[${fechaArt(d.creado_en)}] ${quien}  (${d.proveedor || '?'})`);
    console.log(`  👤 ${corto(d.pregunta, 400)}`);
    if (d.es_fallback) {
      console.log(`  ⚠️ FALLBACK [${d.error || 's/e'}]: ${corto(d.respuesta)}`);
    } else {
      console.log(`  🤖 ${corto(d.respuesta)}`);
    }
    if (tools.length) console.log(`  🔧 ${tools.join(', ')}`);
    console.log('');
  }

  console.log('===== RESUMEN =====');
  console.log(`Total: ${docs.length}  |  rango: ${fechaArt(docs[0].creado_en)} → ${fechaArt(docs[docs.length - 1].creado_en)}`);
  console.log(`Por rol: ${Object.entries(porRol).map(([k, v]) => `${k}=${v}`).join('  ')}`);
  console.log(`Fallbacks: ${fallbacks}/${docs.length} (${Math.round((fallbacks / docs.length) * 100)}%)`);
  if (Object.keys(erroresMap).length)
    console.log(`Errores: ${Object.entries(erroresMap).map(([k, v]) => `${k}=${v}`).join('  ')}`);
  const topTools = Object.entries(toolsMap).sort((a, b) => b[1] - a[1]).slice(0, 12);
  if (topTools.length)
    console.log(`Tools más usadas: ${topTools.map(([k, v]) => `${k}(${v})`).join('  ')}`);
  process.exit(0);
})().catch((e) => {
  console.error('ERROR:', e.message);
  process.exit(1);
});
