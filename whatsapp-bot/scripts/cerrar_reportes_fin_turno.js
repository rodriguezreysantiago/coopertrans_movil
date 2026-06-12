/**
 * Cierra los REPORTES_DISCREPANCIA auto-pendientes que la lógica NUEVA del
 * cruce reconoce como descanso de FIN DE TURNO (o pausa v3) — los que antes del
 * fix generaban falsa alarma. Reusa la MISMA función compilada que el cron
 * (`functions/lib/paradas_reportadas.js :: cruzarUnaParada`) para no divergir.
 *
 * Cierra con estado=revisado + nota, SIN setear `veredicto` → NO dispara la
 * devolución por WhatsApp al chofer (el trigger exige veredicto cierto/no_cierto;
 * ver reportes_discrepancia.ts:50). Son alarmas viejas, no se avisa al chofer.
 *
 * Dry-run por default. `--aplicar` para cerrar de verdad.
 * Uso: node whatsapp-bot/scripts/cerrar_reportes_fin_turno.js [--aplicar]
 * Prereq: functions/lib compilado (npm run build en functions/).
 */
const path = require('path');
const admin = require('firebase-admin');
const APLICAR = process.argv.includes('--aplicar');
admin.initializeApp({ credential: admin.credential.cert(require(path.join(__dirname, '..', '..', 'serviceAccountKey.json'))) });
const db = admin.firestore();
const { cruzarUnaParada } = require(path.join(__dirname, '..', '..', 'functions', 'lib', 'paradas_reportadas.js'));

const hoyIso = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Buenos_Aires', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

async function cargarRegistro(dni, fecha) {
  const snap = await db.collection('REGISTRO_JORNADAS').where('chofer_dni', '==', dni).where('fecha', '==', fecha).get();
  const pausas = [], turnos = [];
  for (const d of snap.docs) {
    const data = d.data();
    turnos.push({ inicioMs: data.inicio_turno?.toMillis?.() ?? 0, finMs: data.fin_turno?.toMillis?.() ?? 0 });
    for (const p of (data.pausas || [])) {
      const ini = p.inicio?.toMillis?.() ?? 0, fin = p.fin?.toMillis?.() ?? 0;
      pausas.push({ inicioMs: ini, finMs: fin, durSeg: p.dur_seg ?? Math.round((fin - ini) / 1000), origen: p.origen || '?', confianza: p.confianza || 'alta', cierraBloque: p.cierra_bloque === true });
    }
  }
  pausas.sort((a, b) => a.inicioMs - b.inicioMs);
  return { pausas, turnos };
}

(async () => {
  const snap = await db.collection('REPORTES_DISCREPANCIA').where('estado', '==', 'pendiente').get();
  const docs = snap.docs.filter((d) => d.data().origen === 'parada_reportada_auto' && d.data().parada_id);
  console.log(`\nReportes auto pendientes: ${docs.length}  ·  modo ${APLICAR ? 'APLICAR' : 'DRY-RUN'}\n${'='.repeat(64)}`);
  const cerrar = [];
  for (const d of docs) {
    const r = d.data();
    const pSnap = await db.collection('PARADAS_REPORTADAS').doc(r.parada_id).get();
    if (!pSnap.exists) { console.log(`\n• ${r.chofer_nombre}: parada ${r.parada_id} no existe → salto`); continue; }
    const p = pSnap.data();
    const parada = {
      id: r.parada_id, choferDni: p.chofer_dni, choferNombre: p.chofer_nombre, fecha: p.fecha,
      inicioMs: typeof p.inicio_ms === 'number' ? p.inicio_ms : (p.inicio_ms?.toMillis?.() ?? null),
      inicioLabel: p.inicio_label ?? null, finMs: null, finLabel: p.fin_label ?? null, motivo: p.motivo ?? null,
    };
    const { pausas, turnos } = await cargarRegistro(parada.choferDni, parada.fecha);
    const v = cruzarUnaParada(parada, pausas, turnos);
    const ok = v.estado === 'confirmada_v3' || v.estado === 'confirmada_fin_turno';
    console.log(`\n• ${r.chofer_nombre} (${parada.fecha}) reportó ${p.inicio_label || '?'}  →  ${ok ? '✅' : '⚠️ '} ${v.estado}`);
    console.log(`  ${v.razon}`);
    if (ok) cerrar.push({ id: d.id, chofer: r.chofer_nombre, razon: v.razon });
  }
  console.log(`\n${'='.repeat(64)}\nPara cerrar: ${cerrar.length}${cerrar.length ? ' (' + cerrar.map((c) => c.chofer).join(', ') + ')' : ''}`);
  if (!APLICAR) { console.log('Dry-run — agregá --aplicar para cerrarlos.'); process.exit(0); }
  for (const c of cerrar) {
    await db.collection('REPORTES_DISCREPANCIA').doc(c.id).update({
      estado: 'revisado',
      // SIN veredicto a propósito → no dispara la devolución por WhatsApp.
      nota_revision: `Cerrado automático ${hoyIso()}: ${c.razon}.`,
      revisado_por: 'BOT_AUTO_V3_FINTURNO',
      revisado_en: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(`✓ Cerrado: ${c.chofer} (${c.id})`);
  }
  console.log('Listo.');
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
