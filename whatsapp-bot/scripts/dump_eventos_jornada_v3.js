/**
 * DUMP (solo lectura) de la secuencia CRUDA de SITRACK_EVENTOS para los casos
 * reales del 06-jun usados como fixtures del vigilador v3 (Paso 1):
 *   - FERNANDEZ JOSE LUIS (DNI 26129762) — parada ~50 min en Baigorrita.
 *   - LOPEZ CARLO JERONIMO (DNI 22987952) — baño en Chinchinales.
 *
 * Imprime, por chofer y ordenado por tiempo, los campos que consume la lógica
 * pura de v3 (`EventoJornadaLite`): ms, eventId, eventName, speed, gpsSpeed,
 * ignition, lat, lng, gpsValidity. Marca los GAPS grandes entre eventos (la
 * firma de una parada sin cobertura). Pensado para copiar la secuencia a los
 * tests `functions/test/jornadas_v3.test.js`.
 *
 * NO modifica nada. Uso: node whatsapp-bot/scripts/dump_eventos_jornada_v3.js
 */
const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(require(path.join(__dirname, '..', '..', 'serviceAccountKey.json'))) });
const db = admin.firestore();

// Turno del 6/6 (ART = UTC-3). Ambos arrancaron ~07-09 ART; tomo franja amplia.
const DESDE = new Date('2026-06-06T11:00:00Z'); // 08:00 ART
const HASTA = new Date('2026-06-06T19:00:00Z'); // 16:00 ART

const CASOS = [
  { dni: '26129762', nombre: 'FERNANDEZ JOSE LUIS' },
  { dni: '22987952', nombre: 'LOPEZ CARLO JERONIMO' },
];

const artHms = (d) => d.toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });

async function main() {
  const dnis = new Set(CASOS.map((c) => c.dni));
  const ev = await db.collection('SITRACK_EVENTOS')
    .where('report_date', '>=', admin.firestore.Timestamp.fromDate(DESDE))
    .where('report_date', '<=', admin.firestore.Timestamp.fromDate(HASTA))
    .limit(40000).get();
  console.log(`total eventos en ventana 8-16 ART: ${ev.size}${ev.size >= 40000 ? ' (TRUNCADO)' : ''}`);

  const porDni = {};
  ev.forEach((doc) => {
    const e = doc.data();
    const dni = String(e.driver_dni || '');
    if (!dnis.has(dni)) return;
    const t = e.report_date && e.report_date.toDate ? e.report_date.toDate() : null;
    if (!t) return;
    (porDni[dni] = porDni[dni] || []).push({
      ms: t.getTime(),
      eventId: typeof e.event_id === 'number' ? e.event_id : null,
      eventName: e.event_name || '',
      speed: typeof e.speed === 'number' ? e.speed : null,
      gpsSpeed: typeof e.gps_speed === 'number' ? e.gps_speed : null,
      ignition: e.ignition === 0 || e.ignition === 1 ? e.ignition : null,
      lat: typeof e.latitude === 'number' ? e.latitude : null,
      lng: typeof e.longitude === 'number' ? e.longitude : null,
      gpsValidity: typeof e.gps_validity === 'number' ? e.gps_validity : null,
      location: e.location || '',
    });
  });

  for (const c of CASOS) {
    const arr = (porDni[c.dni] || []).sort((a, b) => a.ms - b.ms);
    console.log(`\n═════ ${c.nombre} (DNI ${c.dni}) — ${arr.length} eventos ═════`);
    let prevMs = null;
    arr.forEach((e) => {
      const gap = prevMs != null ? (e.ms - prevMs) / 60000 : 0;
      const gapTag = gap >= 15 ? `   ◀── GAP ${gap.toFixed(0)} min` : '';
      const t = new Date(e.ms);
      console.log(
        `${artHms(t)}  id=${String(e.eventId ?? '·').padStart(4)} ` +
        `sp=${String(e.speed ?? '·').padStart(4)} gsp=${String(e.gpsSpeed ?? '·').padStart(4)} ` +
        `ign=${e.ignition ?? '·'} val=${e.gpsValidity ?? '·'} ` +
        `(${e.lat != null ? e.lat.toFixed(5) : '·'},${e.lng != null ? e.lng.toFixed(5) : '·'}) ` +
        `${(e.eventName || '').slice(0, 22).padEnd(22)} ${(e.location || '').slice(0, 22)}${gapTag}`
      );
      prevMs = e.ms;
    });
    // Reconstrucción v3 sobre estos MISMOS eventos vivos (validación end-to-end
    // del batch puro). Si el compilado no existe, avisar (correr `npm run build`
    // en functions/). Read-only: solo imprime.
    if (arr.length) {
      try {
        // eslint-disable-next-line global-require
        const v3 = require(path.join(__dirname, '..', '..', 'functions', 'lib', 'jornadas_v3.js'));
        const reg = v3.reconstruirJornada(arr);
        const hh = (s) => `${Math.floor((s || 0) / 3600)}h${String(Math.floor(((s || 0) % 3600) / 60)).padStart(2, '0')}`;
        console.log('\n  --- RECONSTRUCCIÓN v3 ---');
        console.log(`  manejo neto=${hh(reg.manejoNetoSeg)} · pausa total=${hh(reg.pausaTotalSeg)} · bloques=${reg.bloques.length} (excedidos=${reg.bloquesExcedidos}) · confianza=${reg.confianza}`);
        reg.explicacion.forEach((l) => console.log(`    ${l}`));
      } catch (e) {
        console.log(`  (no se pudo reconstruir v3: ${e.message} — corré "npm run build" en functions/)`);
      }
    }
  }
  process.exit(0);
}
main().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
