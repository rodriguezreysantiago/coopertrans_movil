/**
 * VALIDACIÓN (solo lectura) del registro de jornada v3 contra el v2, sobre los
 * casos REALES en disputa (buzón REPORTES_DISCREPANCIA). NO deploya ni escribe
 * nada: corre la reconstrucción v3 (lógica pura ya compilada en
 * functions/lib/jornadas_v3.js) contra los SITRACK_EVENTOS de Firestore y la
 * compara, lado a lado, con lo que registró el vigilador v2 (colección JORNADAS).
 *
 * Objetivo (Paso 2 "validar primero"): ver con datos reales si el v3 le da la
 * razón al chofer en los casos donde el v2 falló, ANTES de deployar o exponer
 * nada al chofer.
 *
 * Uso:
 *   node whatsapp-bot/scripts/validar_jornada_v3.js          # casos en disputa
 *   node whatsapp-bot/scripts/validar_jornada_v3.js 26129762 # un DNI puntual
 *
 * Prereq: functions/lib/jornadas_v3.js compilado (`npm run build` en functions/).
 */
const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(require(path.join(__dirname, '..', '..', 'serviceAccountKey.json'))) });
const db = admin.firestore();

// Lógica pura v3 (NO toca la red ni initializeApp — seguro de requerir acá).
const v3 = require(path.join(__dirname, '..', '..', 'functions', 'lib', 'jornadas_v3.js'));

const DNI_ARG = process.argv[2] || null;

const art = (ts) => { if (!ts) return '—'; const d = ts.toDate ? ts.toDate() : new Date(ts); return d.toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }); };
const hh = (s) => `${Math.floor((s || 0) / 3600)}h${String(Math.floor(((s || 0) % 3600) / 60)).padStart(2, '0')}`;
// YYYY-MM-DD en ART de un Date.
const diaArt = (d) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Buenos_Aires', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
// Medianoche ART (00:00) de un 'YYYY-MM-DD' → Date UTC (00:00 ART = 03:00 UTC).
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
  };
}

// Lee SITRACK_EVENTOS de un día ART (00:00 → +32h para captar cruce de medianoche)
// y devuelve, por DNI, los eventos mapeados a EventoJornadaLite.
async function eventosDelDiaPorDni(ymd, dnis) {
  const desde = medianocheArtDe(ymd);
  const hasta = new Date(desde.getTime() + 32 * 60 * 60 * 1000);
  const snap = await db.collection('SITRACK_EVENTOS')
    .where('report_date', '>=', admin.firestore.Timestamp.fromDate(desde))
    .where('report_date', '<', admin.firestore.Timestamp.fromDate(hasta))
    .limit(60000).get();
  const porDni = {};
  snap.forEach((doc) => {
    const e = doc.data();
    const dni = String(e.driver_dni || '');
    if (dnis && !dnis.has(dni)) return;
    const ev = mapEvento(e);
    if (!ev) return;
    (porDni[dni] = porDni[dni] || []).push(ev);
  });
  return { porDni, total: snap.size };
}

// Jornada(s) v2 del DNI activas en el día (jornada_inicio dentro de [día-12h, día+1]).
async function jornadasV2(dni, ymd) {
  const desde = medianocheArtDe(ymd).getTime() - 12 * 3600 * 1000;
  const hasta = medianocheArtDe(ymd).getTime() + 32 * 3600 * 1000;
  let snap;
  try { snap = await db.collection('JORNADAS').where('chofer_dni', '==', dni).get(); }
  catch (e) { return []; }
  const out = [];
  snap.forEach((d) => {
    const j = d.data();
    const ms = j.jornada_inicio_ts && j.jornada_inicio_ts.toMillis ? j.jornada_inicio_ts.toMillis() : 0;
    if (ms >= desde && ms <= hasta) out.push(j);
  });
  return out.sort((a, b) => (a.jornada_inicio_ts.toMillis()) - (b.jornada_inicio_ts.toMillis()));
}

function imprimirV3(reg) {
  if (!reg || reg.inicioTurnoMs == null) { console.log('    v3: (sin jornada de manejo)'); return; }
  console.log(`    v3 → manejo neto=${hh(reg.manejoNetoSeg)} · pausa=${hh(reg.pausaTotalSeg)} · bloques=${reg.bloques.length} (excedidos=${reg.bloquesExcedidos}) · confianza=${reg.confianza}`);
  reg.pausas.forEach((p) => {
    const tag = p.cierraBloque ? 'CIERRA BLOQUE' : 'corta';
    console.log(`        pausa ${art(p.inicioMs)}–${art(p.finMs)} (${hh(p.durSeg)}) ${p.origen} [${tag}] conf=${p.confianza}`);
  });
}

function imprimirV2(js) {
  if (!js.length) { console.log('    v2: (sin jornada registrada ese día)'); return; }
  js.forEach((j) => {
    console.log(`    v2 → inicio ${art(j.jornada_inicio_ts)} · estado=${j.estado} · bloques_completos=${j.bloques_completos} · total_manejo=${hh(j.total_manejo_seg)} · bloque_excedido=${j.bloque_excedido} · últ.act=${art(j.ultima_actualizacion_ts)}`);
  });
}

// Veredicto simple: ¿el v3 detectó una pausa que CIERRA BLOQUE el día del reporte
// que el v2 no reflejó (o el v2 marcó manejo excesivo/bloque excedido)?
function veredicto(reg, js) {
  if (!reg || reg.inicioTurnoMs == null) return 'sin datos v3';
  const pausasReales = reg.pausas.filter((p) => p.cierraBloque);
  const v2Excedido = js.some((j) => j.bloque_excedido);
  const v2ManejoAlto = js.some((j) => (j.total_manejo_seg || 0) >= 12 * 3600);
  if (pausasReales.length > 0 && (v2Excedido || v2ManejoAlto || true)) {
    return `v3 detecta ${pausasReales.length} pausa(s) ≥15min que cierran bloque (la(s) que el chofer reclamaba)`;
  }
  return 'v3 no detecta pausas ≥15min en el turno';
}

async function main() {
  // 1) Determinar los casos a validar.
  let casos = [];
  if (DNI_ARG) {
    // Un DNI puntual: validar HOY y los últimos días con eventos.
    const hoy = diaArt(new Date());
    casos.push({ dni: DNI_ARG, nombre: DNI_ARG, ymd: hoy, detalle: '(modo DNI puntual, día de hoy ART)', tema: '-' });
  } else {
    const rep = await db.collection('REPORTES_DISCREPANCIA').orderBy('creado_en', 'desc').limit(20).get();
    rep.forEach((doc) => {
      const x = doc.data();
      const creado = x.creado_en && x.creado_en.toDate ? x.creado_en.toDate() : null;
      if (!creado) return;
      casos.push({
        dni: String(x.chofer_dni || ''),
        nombre: x.chofer_nombre || '?',
        ymd: diaArt(creado),
        detalle: String(x.detalle || '').slice(0, 180),
        tema: x.tema || '-',
        hora: art(x.creado_en),
      });
    });
  }
  if (!casos.length) { console.log('No hay casos para validar.'); process.exit(0); }

  // 2) Agrupar por día para leer eventos una vez por día.
  const porDia = {};
  casos.forEach((c) => { (porDia[c.ymd] = porDia[c.ymd] || []).push(c); });

  let resumen = { total: 0, v3Vindica: 0 };
  for (const ymd of Object.keys(porDia).sort()) {
    const grupo = porDia[ymd];
    const dnis = new Set(grupo.map((c) => c.dni));
    console.log(`\n████ DÍA ${ymd} (ART) — ${grupo.length} caso(s) ████`);
    const { porDni, total } = await eventosDelDiaPorDni(ymd, dnis);
    console.log(`  (SITRACK_EVENTOS leídos en ventana 00:00→+32h: ${total})`);

    for (const c of grupo) {
      resumen.total++;
      console.log(`\n  ═══ ${c.nombre} (DNI ${c.dni})${c.hora ? ` — reportó ${c.hora} [${c.tema}]` : ''} ═══`);
      if (c.detalle) console.log(`    reclamo: "${c.detalle}"`);
      const evs = porDni[c.dni] || [];
      if (!evs.length) { console.log('    (sin eventos Sitrack propios ese día — no se puede reconstruir)'); continue; }
      // Elegir el turno v3 que solapa el día del reporte (el de inicio ese día ART).
      const turnos = v3.reconstruirJornadas(evs);
      const reg = turnos.find((t) => diaArt(new Date(t.inicioTurnoMs)) === ymd) || turnos[0] || null;
      const js = await jornadasV2(c.dni, ymd);
      imprimirV2(js);
      imprimirV3(reg);
      const v = veredicto(reg, js);
      console.log(`    ⇒ VEREDICTO: ${v}`);
      if (reg && reg.pausas.some((p) => p.cierraBloque)) resumen.v3Vindica++;
      if (reg) { console.log('    explicación v3 al chofer:'); reg.explicacion.forEach((l) => console.log(`        · ${l}`)); }
    }
  }

  console.log(`\n████ RESUMEN ████`);
  console.log(`  casos validados: ${resumen.total}`);
  console.log(`  con pausa ≥15min detectada por v3 (cierra bloque): ${resumen.v3Vindica}`);
  console.log(`\n  NOTA: el v2 a menudo muestra total_manejo inflado porque la jornada quedó`);
  console.log(`  ABIERTA (no cerró por descanso) y arrastró horas; el v3 reconstruye el turno`);
  console.log(`  real con sus pausas. Read-only: NO se escribió nada.`);
  process.exit(0);
}
main().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
