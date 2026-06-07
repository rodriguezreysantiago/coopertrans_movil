/**
 * AUDITORÍA (solo lectura) de la reconstrucción v3 sobre TODA la flota y varios
 * días reales, para destapar casos borde / bugs antes de deployar nada. Corre la
 * lógica pura (functions/lib/jornadas_v3.js) contra los SITRACK_EVENTOS de
 * Firestore y lista ANOMALÍAS + una distribución global. NO escribe nada.
 *
 * Anomalías que busca:
 *   - DRIFT multi-patente: un DNI con eventos de 2+ patentes SOLAPADAS en el
 *     tiempo (el v2 filtra esto con `patenteEsperada`; v3 hoy no → mezclaría
 *     dos camiones). Lo más peligroso.
 *   - manejo neto absurdo (>= 14h) → turno mal cortado / arrastre.
 *   - turno muy largo (span wall-clock > 18h).
 *   - >= 8h de manejo SIN una sola pausa (sospechoso o infracción real).
 *   - DNI con eventos pero registro vacío (nunca "manejó" según v3).
 *
 * Uso:
 *   node whatsapp-bot/scripts/auditar_jornada_v3.js          # últimos 4 días
 *   node whatsapp-bot/scripts/auditar_jornada_v3.js 7        # últimos 7 días
 *
 * Prereq: functions/lib/jornadas_v3.js compilado (`npm run build` en functions/).
 */
const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(require(path.join(__dirname, '..', '..', 'serviceAccountKey.json'))) });
const db = admin.firestore();
const v3 = require(path.join(__dirname, '..', '..', 'functions', 'lib', 'jornadas_v3.js'));

const DIAS = Math.max(1, Math.min(31, Number(process.argv[2] || 4)));

const hh = (s) => `${Math.floor((s || 0) / 3600)}h${String(Math.floor(((s || 0) % 3600) / 60)).padStart(2, '0')}`;
const artHm = (ms) => new Date(ms).toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false });
const diaArt = (d) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Buenos_Aires', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
const medianocheArtDe = (ymd) => new Date(`${ymd}T03:00:00Z`);

function mapEvento(e) {
  const t = e.report_date && e.report_date.toDate ? e.report_date.toDate() : null;
  if (!t) return null;
  return {
    ms: t.getTime(),
    eventId: typeof e.event_id === 'number' ? e.event_id : null,
    eventName: e.event_name || '',
    speed: typeof e.speed === 'number' ? e.speed : null,
    gpsSpeed: typeof e.gps_speed === 'number' ? e.gps_speed : null,
    ignition: e.ignition === 0 || e.ignition === 1 ? e.ignition : null,
    lat: typeof e.latitude === 'number' ? e.latitude : null,
    lng: typeof e.longitude === 'number' ? e.longitude : null,
    gpsValidity: typeof e.gps_validity === 'number' ? e.gps_validity : null,
    _patente: (e.asset_id || '').toString().trim().toUpperCase() || null,
    _nombre: `${e.driver_last_name || ''} ${e.driver_name || ''}`.trim(),
  };
}

// ¿Las patentes de un DNI se solapan en el tiempo? (drift CHOFER_DISTINTO vs
// simple cambio de unidad secuencial). Devuelve el solapamiento máx en minutos.
function solapamientoPatentes(evs) {
  const rangos = {};
  for (const e of evs) {
    if (!e._patente) continue;
    const r = rangos[e._patente] || (rangos[e._patente] = { min: e.ms, max: e.ms });
    if (e.ms < r.min) r.min = e.ms;
    if (e.ms > r.max) r.max = e.ms;
  }
  const pats = Object.keys(rangos);
  if (pats.length < 2) return { patentes: pats, solapeMin: 0 };
  let solapeMax = 0;
  for (let i = 0; i < pats.length; i++) {
    for (let j = i + 1; j < pats.length; j++) {
      const a = rangos[pats[i]]; const b = rangos[pats[j]];
      const ov = Math.min(a.max, b.max) - Math.max(a.min, b.min);
      if (ov > solapeMax) solapeMax = ov;
    }
  }
  return { patentes: pats, solapeMin: Math.round(solapeMax / 60000) };
}

async function eventosDelDia(ymd) {
  const desde = medianocheArtDe(ymd);
  const hasta = new Date(desde.getTime() + 32 * 60 * 60 * 1000);
  const snap = await db.collection('SITRACK_EVENTOS')
    .where('report_date', '>=', admin.firestore.Timestamp.fromDate(desde))
    .where('report_date', '<', admin.firestore.Timestamp.fromDate(hasta))
    .limit(80000).get();
  const porDni = {};
  snap.forEach((doc) => {
    const e = doc.data();
    const dni = String(e.driver_dni || '');
    if (!dni) return;
    const ev = mapEvento(e);
    if (ev) (porDni[dni] = porDni[dni] || []).push(ev);
  });
  return { porDni, total: snap.size, truncado: snap.size >= 80000 };
}

// Modo detalle: imprime la línea de tiempo (segmentos) de un chofer-día para
// entender por qué el turno no se parte. Uso: ... detalle <DNI> <YYYY-MM-DD>
async function detalle(dni, ymd) {
  const desde = medianocheArtDe(ymd);
  const hasta = new Date(desde.getTime() + 32 * 60 * 60 * 1000);
  const snap = await db.collection('SITRACK_EVENTOS')
    .where('report_date', '>=', admin.firestore.Timestamp.fromDate(desde))
    .where('report_date', '<', admin.firestore.Timestamp.fromDate(hasta))
    .limit(80000).get();
  const evs = [];
  snap.forEach((doc) => { const e = doc.data(); if (String(e.driver_dni || '') === dni) { const m = mapEvento(e); if (m) evs.push(m); } });
  evs.sort((a, b) => a.ms - b.ms);
  // Cross-check de inflado: distancia total del recorrido ÷ horas de manejo.
  // Si ≈ velocidad crucero (~70-80), el manejo es REAL; si << , estaría inflado.
  let kmTot = 0;
  for (let k = 1; k < evs.length; k++) {
    const dm = distM(evs[k - 1].lat, evs[k - 1].lng, evs[k].lat, evs[k].lng);
    if (dm != null) kmTot += dm / 1000;
  }
  console.log(`${dni} ${ymd}: ${evs.length} eventos · recorrido ${kmTot.toFixed(0)} km`);
  const turnos = v3.reconstruirJornadas(evs);
  const manejoTot = turnos.reduce((s, r) => s + r.manejoNetoSeg, 0) / 3600;
  if (manejoTot > 0) console.log(`  manejo total ${manejoTot.toFixed(1)}h → velocidad implícita ${(kmTot / manejoTot).toFixed(0)} km/h (≈crucero ⇒ manejo real; <<crucero ⇒ inflado)`);
  console.log(`turnos: ${turnos.length}`);
  turnos.forEach((r, i) => {
    const dp = r.descansoPrevioSeg == null ? '—' : hh(r.descansoPrevioSeg) + (r.descansoInsuficiente ? ' INSUF' : '');
    console.log(`\n── turno ${i + 1}: ${artHm(r.inicioTurnoMs)}→${artHm(r.finTurnoMs)} manejo=${hh(r.manejoNetoSeg)} pausa=${hh(r.pausaTotalSeg)} descansoPrevio=${dp} conf=${r.confianza} exc=${r.jornadaExcedida}`);
    r.segmentos.forEach((s) => {
      const tag = s.tipo === 'pausa' ? `PAUSA ${s.origen}` : 'manejo';
      console.log(`   ${artHm(s.inicioMs)}→${artHm(s.finMs)} ${hh(s.durSeg)} ${tag} ${s.confianza}${s.motivoBaja ? ' ('+s.motivoBaja+')' : ''}`);
    });
  });
  process.exit(0);
}

// Histograma de duraciones de PAUSA (pre-split) sobre la flota, para elegir el
// umbral de "descanso = frontera de turno" en el valle entre breaks y descansos.
async function histograma(dias) {
  const buckets = { '0-1h': 0, '1-2h': 0, '2-3h': 0, '3-4h': 0, '4-5h': 0, '5-6h': 0, '6-7h': 0, '7-8h': 0, '8-9h': 0, '9-10h': 0, '10-12h': 0, '12h+': 0 };
  const bucketDe = (h) => h < 1 ? '0-1h' : h < 2 ? '1-2h' : h < 3 ? '2-3h' : h < 4 ? '3-4h' : h < 5 ? '4-5h' : h < 6 ? '5-6h' : h < 7 ? '6-7h' : h < 8 ? '7-8h' : h < 9 ? '8-9h' : h < 10 ? '9-10h' : h < 12 ? '10-12h' : '12h+';
  const hoyArt = new Date(Date.now() - 3 * 3600 * 1000);
  for (let i = 1; i <= dias; i++) {
    const d = new Date(Date.UTC(hoyArt.getUTCFullYear(), hoyArt.getUTCMonth(), hoyArt.getUTCDate() - i, 12, 0, 0));
    const { porDni } = await eventosDelDia(diaArt(d));
    for (const dni of Object.keys(porDni)) {
      const segs = v3.lineaDeTiempo(porDni[dni]);
      for (const s of segs) {
        if (s.tipo === 'pausa') buckets[bucketDe(s.durSeg / 3600)]++;
      }
    }
  }
  console.log(`Histograma de pausas (pre-split, ${dias} días):`);
  for (const k of Object.keys(buckets)) console.log(`  ${k.padStart(6)}: ${'█'.repeat(Math.min(60, buckets[k]))} ${buckets[k]}`);
  process.exit(0);
}

// Haversine inline (no importar jornadas_v2 para no arrastrar firebase-admin).
function distM(aLat, aLng, bLat, bLng) {
  if (aLat == null || aLng == null || bLat == null || bLng == null) return null;
  const R = 6371000, toRad = (g) => g * Math.PI / 180;
  const dLat = toRad(bLat - aLat), dLng = toRad(bLng - aLng);
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(aLat)) * Math.cos(toRad(bLat)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

// Analiza los GAPS "con desplazamiento" (los que hoy se cuentan enteros como
// manejo): velocidad promedio + simula cuánto manejo se DESCONTARÍA estimando el
// tiempo de manejo como distancia/crucero. Calibra el descuento de inflado.
async function gaps(dias) {
  const GAP_MIN_S = 30 * 60, RADIO = 500;
  const vbuckets = { '<20': 0, '20-40': 0, '40-55': 0, '55-70': 0, '70-85': 0, '85+': 0 };
  const bucketV = (v) => v < 20 ? '<20' : v < 40 ? '20-40' : v < 55 ? '40-55' : v < 70 ? '55-70' : v < 85 ? '70-85' : '85+';
  let gapDurTotal = 0; // seg actualmente contados como manejo en gaps con despl.
  const cruceros = [50, 60, 70];
  const desc = { 50: 0, 60: 0, 70: 0 }; // seg que se descontarían con cada crucero
  let nGaps = 0;
  const hoyArt = new Date(Date.now() - 3 * 3600 * 1000);
  for (let i = 1; i <= dias; i++) {
    const d = new Date(Date.UTC(hoyArt.getUTCFullYear(), hoyArt.getUTCMonth(), hoyArt.getUTCDate() - i, 12, 0, 0));
    const { porDni } = await eventosDelDia(diaArt(d));
    for (const dni of Object.keys(porDni)) {
      const evs = porDni[dni].sort((a, b) => a.ms - b.ms);
      for (let k = 1; k < evs.length; k++) {
        const a = evs[k - 1], b = evs[k];
        const dur = (b.ms - a.ms) / 1000;
        if (dur < GAP_MIN_S) continue;
        const va = Math.max(a.speed ?? -1, a.gpsSpeed ?? -1), vb = Math.max(b.speed ?? -1, b.gpsSpeed ?? -1);
        if (va <= 15 || vb <= 15) continue; // ambos en movimiento (gap de manejo)
        const dm = distM(a.lat, a.lng, b.lat, b.lng);
        if (dm == null || dm <= RADIO) continue; // con desplazamiento
        const vAvg = (dm / 1000) / (dur / 3600);
        vbuckets[bucketV(vAvg)]++;
        gapDurTotal += dur;
        nGaps++;
        for (const c of cruceros) {
          const manejoEst = Math.min(dur, (dm / 1000) / c * 3600);
          desc[c] += dur - manejoEst; // tiempo parado estimado
        }
      }
    }
  }
  console.log(`Gaps "con desplazamiento" (≥30min, ambos en movimiento), ${dias} días: ${nGaps} gaps`);
  console.log('Velocidad PROMEDIO del gap (km/h):');
  for (const k of Object.keys(vbuckets)) console.log(`  ${k.padStart(6)}: ${'█'.repeat(Math.min(60, vbuckets[k]))} ${vbuckets[k]}`);
  console.log(`\nTiempo en estos gaps (hoy todo manejo): ${hh(gapDurTotal)}`);
  for (const c of cruceros) console.log(`  con crucero ${c} km/h se descontaría (parado estimado): ${hh(desc[c])} (${(100 * desc[c] / gapDurTotal).toFixed(0)}% del tiempo de gaps)`);
  process.exit(0);
}

async function main() {
  if (process.argv[2] === 'detalle') { await detalle(process.argv[3], process.argv[4]); return; }
  if (process.argv[2] === 'histograma') { await histograma(Math.max(1, Math.min(31, Number(process.argv[3] || 6)))); return; }
  if (process.argv[2] === 'gaps') { await gaps(Math.max(1, Math.min(31, Number(process.argv[3] || 6)))); return; }
  const anomalias = [];
  const dist = { turnos: 0, alta: 0, media: 0, baja: 0, excedidaJornada: 0, excedidaBloque: 0, descansoInsuf: 0, dnis: 0 };
  const hoyArt = new Date(Date.now() - 3 * 3600 * 1000);

  for (let i = 1; i <= DIAS; i++) {
    const d = new Date(Date.UTC(hoyArt.getUTCFullYear(), hoyArt.getUTCMonth(), hoyArt.getUTCDate() - i, 12, 0, 0));
    const ymd = diaArt(d);
    let res;
    try { res = await eventosDelDia(ymd); }
    catch (e) { console.log(`  ${ymd}: error leyendo eventos (${e.message})`); continue; }
    const dnis = Object.keys(res.porDni);
    dist.dnis += dnis.length;
    console.log(`\n████ ${ymd} — ${dnis.length} choferes con eventos · ${res.total} eventos${res.truncado ? ' (TRUNCADO)' : ''}`);

    for (const dni of dnis) {
      const evs = res.porDni[dni].sort((a, b) => a.ms - b.ms);
      const nombre = (evs.find((e) => e._nombre)?._nombre) || dni;
      const sol = solapamientoPatentes(evs);

      // DRIFT: 2+ patentes solapadas > 10 min en el tiempo.
      if (sol.solapeMin > 10) {
        anomalias.push(`[DRIFT ${ymd}] ${nombre} (${dni}): patentes ${sol.patentes.join('+')} solapan ${sol.solapeMin} min → v3 mezclaría 2 camiones`);
      }

      const turnos = v3.reconstruirJornadas(evs).filter((t) => diaArt(new Date(t.inicioTurnoMs)) === ymd);
      if (turnos.length === 0 && evs.length > 30) {
        // muchos eventos pero ningún turno de manejo el día → revisar.
        const movs = evs.filter((e) => (e.speed ?? 0) > 15).length;
        if (movs > 10) anomalias.push(`[SIN-TURNO ${ymd}] ${nombre} (${dni}): ${evs.length} ev (${movs} en movimiento) pero v3 no arma turno`);
      }

      for (const r of turnos) {
        dist.turnos++;
        dist[r.confianza]++;
        if (r.jornadaExcedida) dist.excedidaJornada++;
        if (r.bloquesExcedidos > 0) dist.excedidaBloque++;
        if (r.descansoInsuficiente) {
          dist.descansoInsuf++;
          const hIni = Number(new Intl.DateTimeFormat('en-GB', { timeZone: 'America/Argentina/Buenos_Aires', hour: '2-digit', hour12: false }).format(new Date(r.inicioTurnoMs)));
          anomalias.push(`[DESC-INSUF ${ymd}] ${nombre} (${dni}): descanso ${hh(r.descansoPrevioSeg)} → turno arranca ${artHm(r.inicioTurnoMs)}${(hIni >= 4 && hIni <= 9) ? ' (nocturno OK)' : ' ⚠REVISAR (no madrugada)'}`);
        }
        const spanH = (r.finTurnoMs - r.inicioTurnoMs) / 3600000;

        if (r.manejoNetoSeg >= 14 * 3600) {
          anomalias.push(`[MANEJO-ABSURDO ${ymd}] ${nombre} (${dni}): manejo neto ${hh(r.manejoNetoSeg)} (turno ${artHm(r.inicioTurnoMs)}→${artHm(r.finTurnoMs)})`);
        }
        if (spanH > 18) {
          anomalias.push(`[TURNO-LARGO ${ymd}] ${nombre} (${dni}): span ${spanH.toFixed(1)}h (${artHm(r.inicioTurnoMs)}→${artHm(r.finTurnoMs)}) manejo ${hh(r.manejoNetoSeg)}`);
        }
        if (r.manejoNetoSeg >= 8 * 3600 && r.pausas.length === 0) {
          anomalias.push(`[SIN-PAUSAS ${ymd}] ${nombre} (${dni}): ${hh(r.manejoNetoSeg)} de manejo y 0 pausas`);
        }
      }
    }
  }

  console.log(`\n████ ANOMALÍAS (${anomalias.length}) ████`);
  if (!anomalias.length) console.log('  (ninguna)');
  else anomalias.forEach((a) => console.log('  ⚠ ' + a));

  console.log(`\n████ DISTRIBUCIÓN ████`);
  console.log(`  choferes-día con eventos: ${dist.dnis} · turnos reconstruidos: ${dist.turnos}`);
  console.log(`  confianza → alta:${dist.alta}  media:${dist.media}  baja:${dist.baja}`);
  console.log(`  jornada excedida (>12h): ${dist.excedidaJornada} · con bloque >4h: ${dist.excedidaBloque} · descanso previo <8h: ${dist.descansoInsuf}`);
  console.log(`\n  Read-only: NO se escribió nada.`);
  process.exit(0);
}
main().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
