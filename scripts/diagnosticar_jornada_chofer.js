// Dump completo de la jornada activa de un chofer + análisis de
// si recibió aviso falso de "12h jornada" por bug de bloques cortos.
//
// USO:
//   node scripts/diagnosticar_jornada_chofer.js <DNI>

const path = require('path');
const botDir = path.resolve(__dirname, '..', 'whatsapp-bot');
module.paths.unshift(path.join(botDir, 'node_modules'));
process.chdir(botDir);
require('dotenv').config({ quiet: true });

const admin = require('firebase-admin');
const credPath = process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
admin.initializeApp({
  credential: admin.credential.cert(require(path.resolve(credPath))),
  projectId: process.env.FIREBASE_PROJECT_ID || 'coopertrans-movil',
});
const db = admin.firestore();

const dni = (process.argv[2] || '').trim();
if (!dni) {
  console.error('Uso: node scripts/diagnosticar_jornada_chofer.js <DNI>');
  process.exit(1);
}

function fmtSeg(seg) {
  if (seg == null) return '—';
  const h = Math.floor(seg / 3600);
  const m = Math.floor((seg % 3600) / 60);
  return `${h}h${m.toString().padStart(2, '0')}min (${seg}s)`;
}

function fmtTs(ts) {
  if (!ts) return '—';
  const d = ts.toDate ? ts.toDate() : new Date(ts);
  return d.toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires' });
}

async function main() {
  console.log(`\n🔎 Jornadas del chofer ${dni}\n`);

  // 1) Jornada abierta
  const abierta = await db.collection('JORNADAS')
    .where('chofer_dni', '==', dni)
    .where('jornada_fin_ts', '==', null)
    .limit(5)
    .get();
  if (abierta.empty) {
    console.log('JORNADAS abiertas: (ninguna)');
  } else {
    for (const doc of abierta.docs) {
      console.log(`\n=== JORNADAS/${doc.id} (ABIERTA) ===`);
      const j = doc.data();
      console.log(`  jornada_inicio_ts   : ${fmtTs(j.jornada_inicio_ts)}`);
      console.log(`  ultima_actualizacion: ${fmtTs(j.ultima_actualizacion_ts)}`);
      console.log(`  estado              : ${j.estado}`);
      console.log(`  ultima_patente      : ${j.ultima_patente}`);
      console.log(``);
      console.log(`  bloques_completos        : ${j.bloques_completos}`);
      console.log(`  bloque_actual_manejo_seg : ${fmtSeg(j.bloque_actual_manejo_seg)}`);
      console.log(`  bloque_actual_pausa_seg  : ${fmtSeg(j.bloque_actual_pausa_seg)}`);
      console.log(`  total_manejo_seg         : ${fmtSeg(j.total_manejo_seg)}`);
      console.log(``);
      const totalManejoNeto = (j.total_manejo_seg || 0) + (j.bloque_actual_manejo_seg || 0);
      console.log(`  >> MANEJO NETO TOTAL: ${fmtSeg(totalManejoNeto)}`);
      console.log(``);
      console.log(`  alerta_3_30_enviada      : ${j.alerta_3_30_enviada}`);
      console.log(`  alerta_cuota_enviada     : ${j.alerta_cuota_enviada}`);
      console.log(`  alerta_veda_enviada      : ${j.alerta_veda_enviada}`);
      console.log(`  bloque_excedido          : ${j.bloque_excedido}`);
      console.log(`  cuota_excedida           : ${j.cuota_excedida}`);
      console.log(`  veda_excedida            : ${j.veda_excedida}`);
      console.log(``);
      console.log(`  descanso_segundos        : ${fmtSeg(j.descanso_segundos)}`);
      console.log(`  descanso_inicio_ts       : ${fmtTs(j.descanso_inicio_ts)}`);

      // ANÁLISIS BUG
      console.log(``);
      console.log(`--- ANÁLISIS BUG "12h sin avisos" ---`);
      if (j.alerta_cuota_enviada) {
        const bloquesPorJornadaNorma = 3;
        const manejoNetoEsperadoMin = bloquesPorJornadaNorma * (3 * 3600 + 45 * 60); // 11h15
        const cumpleNormaReal = totalManejoNeto >= 10 * 3600;
        console.log(`  Se mandó aviso "12h jornada".`);
        console.log(`  Manejo neto real: ${fmtSeg(totalManejoNeto)}`);
        console.log(`  Manejo neto esperado (3 bloques x 3h45): ${fmtSeg(manejoNetoEsperadoMin)}`);
        if (cumpleNormaReal) {
          console.log(`  ✅ Manejo neto >= 10h — el aviso era legítimo`);
        } else {
          console.log(`  🐛 BUG CONFIRMADO: manejo neto << 11h pero llegó a ${j.bloques_completos} bloques`);
          console.log(`     El chofer hizo pausas frecuentes y cortas y el sistema`);
          console.log(`     contó bloques sin validar el manejo neto real.`);
        }
      } else {
        console.log(`  alerta_cuota_enviada=false (no se mandó aviso de 12h).`);
      }
    }
  }

  // 2) Últimas jornadas cerradas (las 3 más recientes)
  const cerradas = await db.collection('JORNADAS')
    .where('chofer_dni', '==', dni)
    .where('jornada_fin_ts', '>', admin.firestore.Timestamp.fromMillis(0))
    .orderBy('jornada_fin_ts', 'desc')
    .limit(3)
    .get();
  console.log(`\n\n=== Últimas ${cerradas.size} jornadas CERRADAS ===\n`);
  for (const doc of cerradas.docs) {
    const j = doc.data();
    const totalNeto = (j.total_manejo_seg || 0) + (j.bloque_actual_manejo_seg || 0);
    console.log(`JORNADAS/${doc.id}:`);
    console.log(`  inicio: ${fmtTs(j.jornada_inicio_ts)}`);
    console.log(`  fin   : ${fmtTs(j.jornada_fin_ts)}`);
    console.log(`  bloques_completos: ${j.bloques_completos}, manejo_neto: ${fmtSeg(totalNeto)}`);
    console.log(`  alerta_cuota_enviada: ${j.alerta_cuota_enviada}, cuota_excedida: ${j.cuota_excedida}`);
    console.log(``);
  }

  // 3) COLA_WHATSAPP — todos los mensajes a este chofer hoy
  // Filtro client-side para evitar índice compuesto.
  const hoy = new Date();
  hoy.setHours(0, 0, 0, 0);
  const hoyMs = hoy.getTime();
  const msgs = await db.collection('COLA_WHATSAPP')
    .where('destinatario_id', '==', dni)
    .get();
  const msgsHoy = msgs.docs
    .filter((d) => {
      const ts = d.data().encolado_en;
      if (!ts) return false;
      return ts.toMillis() >= hoyMs;
    })
    .sort((a, b) => b.data().encolado_en.toMillis() - a.data().encolado_en.toMillis());
  console.log(`=== Mensajes en COLA_WHATSAPP a este chofer HOY (${msgsHoy.length}) ===\n`);
  for (const doc of msgsHoy) {
    const m = doc.data();
    console.log(`${fmtTs(m.encolado_en)} | ${m.origen} | ${m.estado}`);
    console.log(`  ${(m.mensaje || '').substring(0, 100).replace(/\n/g, ' | ')}...`);
    if (m.error) console.log(`  ERROR: ${m.error}`);
    console.log(``);
  }

  process.exit(0);
}

main().catch((e) => {
  console.error('❌', e.stack || e.message);
  process.exit(1);
});
