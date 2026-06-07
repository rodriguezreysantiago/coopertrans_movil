/**
 * INVESTIGACIÓN (solo lectura) del bug "paradas no detectadas" en el vigilador
 * de jornada. Cruza, para cada chofer que reportó discrepancia:
 *   - su JORNADA del día del reporte (qué registró el sistema)
 *   - los SITRACK_EVENTOS de ese chofer en la ventana del reporte (qué pasó
 *     realmente con la posición/velocidad)
 *   - salud global del feed de eventos esa franja (conteo por hora → gaps)
 *
 * NO modifica nada. Uso: node whatsapp-bot/scripts/investigar_jornada_paradas.js
 */
const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(require(path.join(__dirname, '..', '..', 'serviceAccountKey.json'))) });
const db = admin.firestore();

// Ventana del 6/6 (ART = UTC-3). Reportes fueron 13:20–14:20 ART → tomo franja amplia.
const FEED_DESDE = new Date('2026-06-06T14:00:00Z'); // 11:00 ART
const FEED_HASTA = new Date('2026-06-06T18:30:00Z'); // 15:30 ART
const DIA_DESDE_MS = new Date('2026-06-06T03:00:00Z').getTime(); // 6/6 00:00 ART

const art = (ts) => { if (!ts) return '—'; const d = ts.toDate ? ts.toDate() : new Date(ts); return d.toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires', day: '2-digit', hour: '2-digit', minute: '2-digit' }); };
const hhmm = (s) => `${Math.floor((s || 0) / 3600)}h${String(Math.floor(((s || 0) % 3600) / 60)).padStart(2, '0')}`;
const horaArt = (d) => d.toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires', hour: '2-digit', minute: '2-digit' });

async function main() {
  // 1) Reportes → choferes
  const rep = await db.collection('REPORTES_DISCREPANCIA').orderBy('creado_en', 'desc').limit(20).get();
  const choferes = [];
  rep.forEach(doc => { const x = doc.data(); choferes.push({ dni: String(x.chofer_dni || ''), nombre: x.chofer_nombre || '?', tema: x.tema, hora: art(x.creado_en), detalle: x.detalle }); });

  // 2) Jornada del día por chofer
  for (const c of choferes) {
    console.log(`\n═════ ${c.nombre} (DNI ${c.dni}) — reportó ${c.hora} [${c.tema}] ═════`);
    console.log(`  "${String(c.detalle || '').slice(0, 170)}"`);
    let js;
    try { js = await db.collection('JORNADAS').where('chofer_dni', '==', c.dni).get(); }
    catch (e) { console.log(`  (error leyendo JORNADAS: ${e.message})`); continue; }
    const dia = [];
    js.forEach(d => { const j = d.data(); const ms = j.jornada_inicio_ts && j.jornada_inicio_ts.toMillis ? j.jornada_inicio_ts.toMillis() : 0; if (ms >= DIA_DESDE_MS && ms <= DIA_DESDE_MS + 24 * 3600 * 1000) dia.push(j); });
    if (!dia.length) { console.log('  (sin jornada el 6/6)'); }
    dia.forEach(j => {
      console.log(`  ▸ inicio ${art(j.jornada_inicio_ts)} · estado=${j.estado} · bloques_completos=${j.bloques_completos}`);
      console.log(`    manejo bloque=${hhmm(j.bloque_actual_manejo_seg)} · pausa bloque=${hhmm(j.bloque_actual_pausa_seg)} · total manejo=${hhmm(j.total_manejo_seg)}`);
      console.log(`    últ. actualización=${art(j.ultima_actualizacion_ts)} · patente=${j.ultima_patente} · bloque_excedido=${j.bloque_excedido}`);
    });
  }

  // 3) Feed SITRACK_EVENTOS en la ventana — salud global + por chofer
  console.log(`\n═════ FEED SITRACK_EVENTOS (6/6 11:00–15:30 ART) ═════`);
  let ev;
  try {
    ev = await db.collection('SITRACK_EVENTOS')
      .where('report_date', '>=', admin.firestore.Timestamp.fromDate(FEED_DESDE))
      .where('report_date', '<=', admin.firestore.Timestamp.fromDate(FEED_HASTA))
      .limit(40000).get();
  } catch (e) { console.log(`  (error leyendo SITRACK_EVENTOS: ${e.message})`); process.exit(0); }
  console.log(`  total eventos en ventana: ${ev.size}${ev.size >= 40000 ? ' (TRUNCADO)' : ''}`);

  const dnis = new Set(choferes.map(c => c.dni));
  const porHoraMin = {}; // "HH:MM" cada 5 min bucket → conteo (para ver gaps)
  const evChofer = {};
  ev.forEach(doc => {
    const e = doc.data();
    const t = e.report_date && e.report_date.toDate ? e.report_date.toDate() : null;
    if (!t) return;
    const hm = horaArt(t).slice(0, 4) + '0'; // bucket de 10 min aprox
    porHoraMin[hm] = (porHoraMin[hm] || 0) + 1;
    const edni = String(e.driver_dni || e.dni || e.chofer_dni || '');
    if (dnis.has(edni)) { (evChofer[edni] = evChofer[edni] || []).push({ t, speed: Number(e.speed ?? e.gps_speed ?? -1), tipo: e.eventId ?? e.event_id ?? e.tipo ?? '' }); }
  });
  const buckets = Object.keys(porHoraMin).sort();
  console.log('  actividad por franja (~10min): ' + buckets.map(b => `${b}:${porHoraMin[b]}`).join('  '));

  console.log('\n  --- eventos propios de cada chofer en la ventana ---');
  for (const c of choferes) {
    const arr = (evChofer[c.dni] || []).sort((a, b) => a.t - b.t);
    if (!arr.length) { console.log(`  ${c.nombre}: SIN eventos propios (no aparece en el feed esta franja)`); continue; }
    const movs = arr.filter(e => e.speed > 15).length;
    const quietos = arr.filter(e => e.speed >= 0 && e.speed <= 15).length;
    // gap más grande entre eventos consecutivos (min)
    let maxGap = 0;
    for (let i = 1; i < arr.length; i++) { const g = (arr[i].t - arr[i - 1].t) / 60000; if (g > maxGap) maxGap = g; }
    console.log(`  ${c.nombre}: ${arr.length} ev (mov:${movs} quieto:${quietos}) ${horaArt(arr[0].t)}→${horaArt(arr[arr.length - 1].t)} · gap máx ${maxGap.toFixed(0)}min`);
  }
  process.exit(0);
}
main().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
