/**
 * PASO 0 del plan vigilador v3 (solo lectura): cataloga los tipos de evento de
 * SITRACK_EVENTOS para saber qué señales de parada/arranque/ignición tenemos y
 * cuán confiables son. Agrupa por event_id y muestra, por tipo: conteo,
 * event_name, % con motor encendido/apagado, % en movimiento, % con posición y
 * % con geocerca (zona YPF).
 *
 * Uso: node whatsapp-bot/scripts/catalogo_eventos_sitrack.js [limite]
 */
const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(require(path.join(__dirname, '..', '..', 'serviceAccountKey.json'))) });
const db = admin.firestore();

const LIMIT = parseInt(process.argv[2], 10) || 30000;
const artHora = (ms) => new Date(ms).toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires' });

async function main() {
  console.log(`Leyendo últimos ${LIMIT} eventos de SITRACK_EVENTOS...`);
  const snap = await db.collection('SITRACK_EVENTOS').orderBy('report_date', 'desc').limit(LIMIT).get();
  console.log(`Leídos: ${snap.size}`);

  const cat = {};
  let minTs = Infinity, maxTs = 0;
  const dnis = new Set();
  snap.forEach(d => {
    const x = d.data();
    const id = x.event_id == null ? '(null)' : x.event_id;
    const c = cat[id] || (cat[id] = { names: {}, count: 0, ign1: 0, ign0: 0, mov: 0, quieto: 0, latlng: 0, zona: 0, hm: 0 });
    c.count++;
    const nm = (x.event_name || '').toString().trim() || '(sin nombre)';
    c.names[nm] = (c.names[nm] || 0) + 1;
    if (x.ignition === 1) c.ign1++; else if (x.ignition === 0) c.ign0++;
    const sp = typeof x.speed === 'number' ? x.speed : (typeof x.gps_speed === 'number' ? x.gps_speed : null);
    if (sp != null) { if (sp > 15) c.mov++; else c.quieto++; }
    if (typeof x.latitude === 'number' && typeof x.longitude === 'number') c.latlng++;
    if ((x.zone_name || '').toString().trim()) c.zona++;
    if (typeof x.hourmeter === 'number' && x.hourmeter > 0) c.hm++;
    const ms = x.report_date && x.report_date.toMillis ? x.report_date.toMillis() : 0;
    if (ms) { if (ms < minTs) minTs = ms; if (ms > maxTs) maxTs = ms; }
    if (x.driver_dni) dnis.add(String(x.driver_dni));
  });

  console.log(`Rango: ${minTs !== Infinity ? artHora(minTs) + ' → ' + artHora(maxTs) : '?'}  ·  choferes distintos: ${dnis.size}\n`);
  const pct = (n, t) => (t ? Math.round(100 * n / t) + '%' : '-');
  const filas = Object.entries(cat).sort((a, b) => b[1].count - a[1].count);
  console.log('event_id |  count | %motorON %motorOFF | %mov %quieto | %pos %zona %horóm | event_name');
  console.log('-'.repeat(118));
  filas.forEach(([id, c]) => {
    const nm = Object.entries(c.names).sort((a, b) => b[1] - a[1])[0][0];
    console.log(
      `${String(id).padEnd(8)} | ${String(c.count).padStart(6)} | ` +
      `${pct(c.ign1, c.count).padStart(7)} ${pct(c.ign0, c.count).padStart(8)} | ` +
      `${pct(c.mov, c.count).padStart(4)} ${pct(c.quieto, c.count).padStart(6)} | ` +
      `${pct(c.latlng, c.count).padStart(4)} ${pct(c.zona, c.count).padStart(4)} ${pct(c.hm, c.count).padStart(6)} | ${nm}`
    );
  });
  process.exit(0);
}
main().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
