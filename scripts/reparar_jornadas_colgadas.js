// Cierra jornadas COLGADAS: abiertas (jornada_fin_ts==null) hace más de
// UMBRAL_H horas. Arrastran de antes del fix del vigilador (2026-06-05) o son
// zombies (chofer de baja). Cerrarlas hace que el bot abra una jornada nueva
// limpia y deje de reportar manejo absurdo.
//
// DRY-RUN por default (solo lista). Para aplicar: agregar  --aplicar
// Umbral configurable:  --horas 22   (default 22h; una jornada legítima dura
// hasta ~22h de wall-clock = 12h conducción + 8h de descanso que la cierra).
//
// Uso:  node scripts/reparar_jornadas_colgadas.js            (dry-run)
//       node scripts/reparar_jornadas_colgadas.js --aplicar  (cierra)
const path = require('path');
const fsNode = require('fs');
const admin = require('firebase-admin');
const credPath = process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
const absPath = path.resolve(credPath);
if (!fsNode.existsSync(absPath)) { console.error(`No encuentro key en ${absPath}`); process.exit(1); }
admin.initializeApp({ credential: admin.credential.cert(require(absPath)), projectId: 'coopertrans-movil' });
const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;

const APLICAR = process.argv.includes('--aplicar');
const hIdx = process.argv.indexOf('--horas');
const UMBRAL_H = hIdx > 0 ? Number(process.argv[hIdx + 1]) : 22;
const now = Date.now();
const hhmm = (s) => `${Math.floor((s || 0) / 3600)}h${String(Math.round(((s || 0) % 3600) / 60)).padStart(2, '0')}`;
const tsMs = (v) => (v && v.toMillis ? v.toMillis() : null);

(async () => {
  const nombres = {};
  (await db.collection('EMPLEADOS').get()).forEach((d) => { nombres[d.id] = (d.data().NOMBRE || '').toString(); });

  const snap = await db.collection('JORNADAS').where('jornada_fin_ts', '==', null).get();
  const colgadas = [];
  for (const d of snap.docs) {
    const j = d.data();
    const inicioMs = tsMs(j.jornada_inicio_ts);
    const horas = inicioMs ? (now - inicioMs) / 3600000 : Infinity;
    if (horas > UMBRAL_H) colgadas.push({ ref: d.ref, id: d.id, j, horas });
  }
  colgadas.sort((a, b) => b.horas - a.horas);

  console.log(`\n${APLICAR ? '=== APLICANDO ===' : '=== DRY-RUN (no toca nada) ==='}  umbral > ${UMBRAL_H}h abierta`);
  console.log(`Jornadas colgadas a cerrar: ${colgadas.length}\n`);
  for (const c of colgadas) {
    const nom = nombres[c.j.chofer_dni] || `DNI ${c.j.chofer_dni}`;
    console.log(`  ${nom.padEnd(28)} ${(c.j.ultima_patente || '').padEnd(8)} manejo=${hhmm((c.j.total_manejo_seg || 0) + (c.j.bloque_actual_manejo_seg || 0)).padStart(6)} abierta ${c.horas.toFixed(1)}h  estado=${c.j.estado}`);
  }

  if (!APLICAR) {
    console.log('\n(DRY-RUN — corré con --aplicar para cerrarlas)');
    process.exit(0);
  }

  let ok = 0;
  for (const c of colgadas) {
    try {
      await c.ref.update({
        estado: 'descanso_jornada',
        jornada_fin_ts: Timestamp.now(),
        cerrada_por_reparacion: true, // auditoría: cierre manual 2026-06-05
        ultima_actualizacion_ts: Timestamp.now(),
      });
      ok++;
    } catch (e) {
      console.error(`  ERROR cerrando ${c.id}: ${e.message}`);
    }
  }
  console.log(`\nCerradas: ${ok}/${colgadas.length}. El próximo tick del vigilador abrirá jornadas nuevas limpias para los que estén manejando.`);
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
