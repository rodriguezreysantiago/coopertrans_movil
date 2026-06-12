/**
 * INVESTIGACIÓN (solo lectura) de las paradas reportadas que el v3 NO vio.
 * Para cada REPORTES_DISCREPANCIA pendiente (origen parada_reportada_auto),
 * cruza:
 *   1. lo que el chofer reportó   (PARADAS_REPORTADAS: inicio_ms, fecha)
 *   2. lo que el v3 detectó       (REGISTRO_JORNADAS: pausas[])
 *   3. lo que dice el GPS crudo   (SITRACK_EVENTOS: gap / distancia / velocidad)
 * y diagnostica POR QUÉ se perdió. NO escribe nada.
 *
 * Uso: node whatsapp-bot/scripts/investigar_paradas_v3.js
 * Lee serviceAccountKey.json de la raíz del repo.
 */
const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(require(path.join(__dirname, '..', '..', 'serviceAccountKey.json'))) });
const db = admin.firestore();

const TZ = 'America/Argentina/Buenos_Aires';
const hm = (ms) => new Date(ms).toLocaleString('es-AR', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false });
const medianocheArtDe = (ymd) => new Date(`${ymd}T03:00:00Z`);

function distM(la1, lo1, la2, lo2) {
  if ([la1, lo1, la2, lo2].some((v) => typeof v !== 'number')) return null;
  const R = 6371000, rad = (d) => (d * Math.PI) / 180;
  const dLa = rad(la2 - la1), dLo = rad(lo2 - lo1);
  const a = Math.sin(dLa / 2) ** 2 + Math.cos(rad(la1)) * Math.cos(rad(la2)) * Math.sin(dLo / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

async function eventosChoferDia(dni, ymd) {
  const desde = medianocheArtDe(ymd);
  const hasta = new Date(desde.getTime() + 32 * 60 * 60 * 1000);
  const snap = await db.collection('SITRACK_EVENTOS')
    .where('report_date', '>=', admin.firestore.Timestamp.fromDate(desde))
    .where('report_date', '<', admin.firestore.Timestamp.fromDate(hasta))
    .limit(80000).get();
  const evs = [];
  snap.forEach((doc) => {
    const e = doc.data();
    if (String(e.driver_dni || '') !== dni) return;
    const t = e.report_date && e.report_date.toDate ? e.report_date.toDate() : null;
    if (!t) return;
    evs.push({
      ms: t.getTime(),
      speed: typeof e.speed === 'number' ? e.speed : (typeof e.gps_speed === 'number' ? e.gps_speed : null),
      ign: e.ignition === 0 || e.ignition === 1 ? e.ignition : null,
      lat: typeof e.latitude === 'number' ? e.latitude : null,
      lng: typeof e.longitude === 'number' ? e.longitude : null,
    });
  });
  evs.sort((a, b) => a.ms - b.ms);
  return evs;
}

async function pausasV3(dni, ymd) {
  const snap = await db.collection('REGISTRO_JORNADAS')
    .where('chofer_dni', '==', dni).where('fecha', '==', ymd).get();
  const out = [];
  snap.forEach((d) => {
    for (const p of (d.data().pausas || [])) {
      const ini = p.inicio && p.inicio.toMillis ? p.inicio.toMillis() : 0;
      const fin = p.fin && p.fin.toMillis ? p.fin.toMillis() : 0;
      out.push({ ini, fin, durSeg: p.dur_seg || Math.round((fin - ini) / 1000), origen: p.origen || '?', conf: p.confianza || '?' });
    }
  });
  return out.sort((a, b) => a.ini - b.ini);
}

(async () => {
  // Sin where compuesto (evita índice): traigo por fecha y filtro en memoria.
  const snap = await db.collection('REPORTES_DISCREPANCIA')
    .orderBy('creado_en', 'desc').limit(120).get();
  const autos = snap.docs.filter((d) => {
    const x = d.data();
    return x.estado === 'pendiente' && x.origen === 'parada_reportada_auto' && x.parada_id;
  });
  console.log(`\nReportes pendientes auto (v3 no vio): ${autos.length}\n${'='.repeat(70)}`);

  for (const rep of autos) {
    const r = rep.data();
    const pSnap = await db.collection('PARADAS_REPORTADAS').doc(r.parada_id).get();
    if (!pSnap.exists) { console.log(`\n• ${r.chofer_nombre}: PARADA ${r.parada_id} no existe`); continue; }
    const p = pSnap.data();
    const dni = p.chofer_dni || r.chofer_dni;
    const ymd = p.fecha;
    const iniMs = typeof p.inicio_ms === 'number' ? p.inicio_ms : (p.inicio_ms && p.inicio_ms.toMillis ? p.inicio_ms.toMillis() : null);

    console.log(`\n• ${r.chofer_nombre}  (${ymd})`);
    console.log(`  REPORTÓ: parada ${p.inicio_label || '?'}${p.fin_label ? '→' + p.fin_label : ''}${p.motivo ? ' (' + p.motivo + ')' : ''}  inicio_ms=${iniMs ? hm(iniMs) : 'SIN HORA'}`);

    const pv3 = await pausasV3(dni, ymd);
    console.log(`  V3 vio: ${pv3.length ? pv3.map((x) => `${hm(x.ini)}→${hm(x.fin)}(${Math.round(x.durSeg / 60)}m,${x.origen},${x.conf})`).join('  ') : 'NINGUNA pausa'}`);

    if (!iniMs) { console.log('  → sin hora parseable, no se puede cruzar contra GPS'); continue; }

    const evs = await eventosChoferDia(dni, ymd);
    if (!evs.length) { console.log('  GPS: 0 eventos ese día (hueco total de cobertura)'); continue; }
    // Ventana ±45 min alrededor de la hora reportada.
    const W = 45 * 60 * 1000;
    const cerca = evs.filter((e) => Math.abs(e.ms - iniMs) <= W);
    console.log(`  GPS: ${evs.length} eventos en el día · ${cerca.length} dentro de ±45min de la hora reportada`);
    // Gap más grande dentro de la ventana + distancia recorrida en ese gap.
    let maxGap = null;
    for (let i = 1; i < cerca.length; i++) {
      const dt = (cerca[i].ms - cerca[i - 1].ms) / 60000;
      const dm = distM(cerca[i - 1].lat, cerca[i - 1].lng, cerca[i].lat, cerca[i].lng);
      if (!maxGap || dt > maxGap.dt) maxGap = { dt, dm, a: cerca[i - 1], b: cerca[i] };
    }
    if (maxGap) {
      console.log(`  Gap mayor cerca: ${maxGap.dt.toFixed(0)} min (${hm(maxGap.a.ms)}→${hm(maxGap.b.ms)}), se movió ${maxGap.dm == null ? '?' : Math.round(maxGap.dm) + ' m'}`);
    }
    // Velocidades cerca de la hora reportada (¿paró de verdad?).
    const vel = cerca.filter((e) => e.speed != null).map((e) => `${hm(e.ms)}:${e.speed}`);
    console.log(`  Velocidades cerca: ${vel.slice(0, 14).join('  ') || '(sin dato de velocidad)'}`);

    // Diagnóstico heurístico.
    let dx;
    if (cerca.length === 0) dx = 'HUECO GPS: no hay eventos en ±45min → v3 ciego, sin gap acotable';
    else if (maxGap && maxGap.dt >= 15 && maxGap.dm != null && maxGap.dm <= 500) dx = '⚠ HABÍA pausa encubierta (gap≥15m + ≤500m) → v3 debería haberla visto; revisar día/turno/REGISTRO';
    else if (maxGap && maxGap.dt >= 15 && maxGap.dm != null && maxGap.dm <= 1200) dx = `RADIO: gap≥15m pero se movió ${Math.round(maxGap.dm)}m (>500) → v3 lo tomó como manejo; candidato a aflojar RADIO_PAUSA`;
    else if (cerca.some((e) => e.speed != null && e.speed < 5)) dx = 'CONECTADO PARADO: hay velocidades ~0 sin gap → la parada no llegó a 15min de gap o quedó como heartbeats; revisar regla por velocidad';
    else dx = 'Sin gap≥15m ni velocidad ~0 cerca → la parada reportada no se ve en el GPS (hora mal reportada o parada <15min)';
    console.log(`  DIAGNÓSTICO: ${dx}`);
  }
  console.log(`\n${'='.repeat(70)}\nFin.`);
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
