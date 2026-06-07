/**
 * Revisión rápida (solo lectura) de:
 *   1. REPORTES_DISCREPANCIA  — reclamos de choferes vía bot.
 *   2. AGENTE_CONVERSACIONES  — chats del agente WhatsApp (últimos N días).
 *
 * Uso:  node whatsapp-bot/scripts/revisar_agente_reportes.js [dias]
 *   dias = ventana para las conversaciones del agente (default 7).
 *
 * No modifica nada. Lee el serviceAccountKey.json de la raíz del repo.
 */
const path = require('path');
const admin = require('firebase-admin');

const DIAS = parseInt(process.argv[2], 10) || 7;
const keyPath = path.join(__dirname, '..', '..', 'serviceAccountKey.json');
admin.initializeApp({ credential: admin.credential.cert(require(keyPath)) });
const db = admin.firestore();

function fecha(ts) {
  if (!ts) return '—';
  const d = ts.toDate ? ts.toDate() : new Date(ts);
  return d.toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
}
const corto = (s, n) => String(s || '').replace(/\s+/g, ' ').trim().slice(0, n);

async function reportes() {
  console.log('\n══════════ REPORTES DE CHOFERES (REPORTES_DISCREPANCIA) ══════════\n');
  const snap = await db.collection('REPORTES_DISCREPANCIA').orderBy('creado_en', 'desc').limit(100).get();
  if (snap.empty) { console.log('(sin reportes registrados)'); return; }
  const porEstado = {};
  snap.forEach(doc => { const e = doc.data().estado || 'pendiente'; porEstado[e] = (porEstado[e] || 0) + 1; });
  console.log(`Total: ${snap.size}  ·  ` + Object.entries(porEstado).map(([k, v]) => `${k}: ${v}`).join('  ·  ') + '\n');
  snap.forEach(doc => {
    const d = doc.data();
    console.log(`• [${fecha(d.creado_en)}] ${d.chofer_nombre || d.chofer_dni || '?'}  [${(d.estado || 'pendiente').toUpperCase()}]`);
    console.log(`    tema:    ${corto(d.tema, 120) || '—'}`);
    console.log(`    detalle: ${corto(d.detalle, 400) || '—'}`);
    if (d.nota_revision || d.notaRevision) console.log(`    nota:    ${corto(d.nota_revision || d.notaRevision, 300)}`);
    console.log('');
  });
}

async function agente() {
  console.log(`\n══════════ AGENTE — CONVERSACIONES (últimos ${DIAS} días) ══════════\n`);
  const snap = await db.collection('AGENTE_CONVERSACIONES').orderBy('creado_en', 'desc').limit(400).get();
  const corte = Date.now() - DIAS * 24 * 60 * 60 * 1000;
  const recientes = [];
  snap.forEach(doc => {
    const d = doc.data();
    const ms = d.creado_en && d.creado_en.toMillis ? d.creado_en.toMillis() : 0;
    if (ms >= corte) recientes.push(d);
  });
  if (!recientes.length) { console.log('(sin conversaciones en la ventana)'); return; }

  const porRol = {}, porTool = {};
  let fallbacks = 0, errores = 0;
  const problemas = [];
  recientes.forEach(d => {
    porRol[d.rol || '?'] = (porRol[d.rol || '?'] || 0) + 1;
    (d.tools_usadas || []).forEach(t => { porTool[t] = (porTool[t] || 0) + 1; });
    if (d.es_fallback) fallbacks++;
    if (d.error) errores++;
    if (d.es_fallback || d.error) problemas.push(d);
  });

  console.log(`Total: ${recientes.length}  ·  fallbacks: ${fallbacks}  ·  errores: ${errores}`);
  console.log('Por rol:   ' + Object.entries(porRol).map(([k, v]) => `${k}:${v}`).join('  '));
  console.log('Tools más usadas: ' + Object.entries(porTool).sort((a, b) => b[1] - a[1]).slice(0, 12).map(([k, v]) => `${k}:${v}`).join('  '));

  console.log(`\n----- CHATS PROBLEMÁTICOS (fallback/error): ${problemas.length} -----\n`);
  problemas.forEach(d => {
    const flags = [d.es_fallback ? 'FALLBACK' : null, d.error ? 'ERR:' + d.error : null].filter(Boolean).join(' ');
    console.log(`⚠ [${fecha(d.creado_en)}] ${d.nombre || d.dni || '?'} (${d.rol})  ${flags}`);
    console.log(`    P: ${corto(d.pregunta, 220)}`);
    console.log(`    R: ${corto(d.respuesta, 220) || '(vacío)'}`);
    console.log(`    tools: ${(d.tools_usadas || []).join(',') || '—'}`);
    console.log('');
  });

  const muestra = recientes.slice(0, 35);
  console.log(`\n----- ÚLTIMOS ${muestra.length} CHATS (muestra) -----\n`);
  muestra.forEach(d => {
    console.log(`[${fecha(d.creado_en)}] ${d.nombre || d.dni || '?'} (${d.rol})  tools:${(d.tools_usadas || []).join(',') || '—'}`);
    console.log(`    P: ${corto(d.pregunta, 160)}`);
    console.log(`    R: ${corto(d.respuesta, 160)}`);
  });
}

(async () => {
  try {
    await reportes();
    await agente();
    process.exit(0);
  } catch (e) {
    console.error('ERROR:', e.message);
    process.exit(1);
  }
})();
