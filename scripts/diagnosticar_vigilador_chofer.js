// Diagnóstico del vigilador de jornada para un chofer puntual.
//
// Lee:
//   - JORNADAS_CHOFER/{dni}_{YYYY-MM-DD ART} — estado actual del
//     vigilador (acumulados del día, último update, flags de alerta).
//   - SITRACK_POSICIONES/{patente} — última posición conocida del
//     tractor del chofer.
//
// Útil para investigar por qué el bot mandó (o NO mandó) una alerta:
// se ven los segundos acumulados, el último delta sumado, si hubo
// reset por pausa, etc.
//
// El histórico de polls de Sitrack NO se persiste (decisión de costos),
// así que este script solo muestra el snapshot ACTUAL. Si el caso es
// del pasado, hay que mirar los logs de la Cloud Function en GCP
// directamente.
//
// USO:
//   cd whatsapp-bot
//   node ../scripts/diagnosticar_vigilador_chofer.js <DNI>

const path = require('path');
const fsNode = require('fs');

const botDir = path.resolve(__dirname, '..', 'whatsapp-bot');
const botNodeModules = path.join(botDir, 'node_modules');
if (!fsNode.existsSync(botNodeModules)) {
  console.error(
    `❌ No existe ${botNodeModules}. Corré 'npm install' en whatsapp-bot primero.`
  );
  process.exit(1);
}
module.paths.unshift(botNodeModules);
process.chdir(botDir);
require('dotenv').config({ quiet: true });

const admin = require('firebase-admin');

const credPath =
  process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
const absPath = path.resolve(credPath);
admin.initializeApp({
  credential: admin.credential.cert(require(absPath)),
  projectId: process.env.FIREBASE_PROJECT_ID || 'coopertrans-movil',
});
const db = admin.firestore();

const dni = (process.argv[2] || '').trim();
if (!dni) {
  console.error('Uso: node diagnosticar_vigilador_chofer.js <DNI>');
  process.exit(1);
}

function fechaArt() {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Argentina/Buenos_Aires',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

function fmtSeg(seg) {
  if (!seg) return '0s';
  const h = Math.floor(seg / 3600);
  const m = Math.floor((seg % 3600) / 60);
  const s = Math.floor(seg % 60);
  return `${h}h ${m.toString().padStart(2, '0')}m ${s.toString().padStart(2, '0')}s`;
}

function fmtFecha(ts) {
  if (!ts) return '(null)';
  const d = ts.toDate ? ts.toDate() : new Date(ts);
  return new Intl.DateTimeFormat('es-AR', {
    timeZone: 'America/Argentina/Buenos_Aires',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).format(d);
}

async function main() {
  const fecha = fechaArt();
  const docId = `${dni}_${fecha}`;
  console.log('');
  console.log('🔎 DIAGNÓSTICO VIGILADOR DE JORNADA');
  console.log('═════════════════════════════════════════');
  console.log(`  DNI         : ${dni}`);
  console.log(`  Fecha ART   : ${fecha}`);
  console.log(`  Doc id      : JORNADAS_CHOFER/${docId}`);
  console.log('');

  // 1) Datos del chofer
  const empSnap = await db.collection('EMPLEADOS').doc(dni).get();
  if (empSnap.exists) {
    const e = empSnap.data();
    console.log('👤 EMPLEADO');
    console.log(`  Nombre      : ${e.NOMBRE ?? '(sin nombre)'}`);
    console.log(`  Vehículo    : ${e.VEHICULO ?? '(sin asignar)'}`);
    console.log(`  Rol         : ${e.ROL ?? '(sin rol)'}`);
    console.log('');
  } else {
    console.log('⚠️  No existe el doc EMPLEADOS/' + dni);
    console.log('');
  }

  // 2) Jornada del chofer
  const jSnap = await db.collection('JORNADAS_CHOFER').doc(docId).get();
  if (!jSnap.exists) {
    console.log('📋 JORNADAS_CHOFER');
    console.log('  (no existe — el cron todavía no lo vio hoy, o el chofer');
    console.log('   no tiene posición activa con su DNI en SITRACK_POSICIONES)');
    console.log('');
  } else {
    const j = jSnap.data();
    const totalDia = j.segundos_total_dia ?? 0;
    const jornadaActual = j.segundos_jornada_actual ?? 0;
    const continuo = j.segundos_continuo_actual ?? 0;
    const pausa = j.segundos_pausa_actual ?? 0;
    console.log('📋 JORNADAS_CHOFER');
    console.log(`  Total día calend.  : ${fmtSeg(totalDia)}    (${totalDia}s)`);
    console.log(`  Jornada actual     : ${fmtSeg(jornadaActual)}    (${jornadaActual}s)  ← desde último descanso ≥ 8 h`);
    console.log(`  Continuo actual    : ${fmtSeg(continuo)}    (${continuo}s)`);
    console.log(`  Pausa actual       : ${fmtSeg(pausa)}    (${pausa}s)`);
    console.log(`  Última patente     : ${j.ultima_patente ?? '(?)'}`);
    console.log(`  Última actualiz.   : ${fmtFecha(j.ultima_actualizacion_at)}`);
    console.log('  Flags:');
    console.log(`    Alerta 3:45 enviada       : ${j.alerta_3_45_continua_enviada ? 'SÍ' : 'no'} ${j.alerta_3_45_continua_at ? `(${fmtFecha(j.alerta_3_45_continua_at)})` : ''}`);
    console.log(`    Alerta 11:30 enviada      : ${j.alerta_11_30_diaria_enviada ? 'SÍ' : 'no'} ${j.alerta_11_30_diaria_at ? `(${fmtFecha(j.alerta_11_30_diaria_at)})` : ''}`);
    console.log(`    Alerta 12:00 enviada      : ${j.alerta_12_00_diaria_enviada ? 'SÍ' : 'no'} ${j.alerta_12_00_diaria_at ? `(${fmtFecha(j.alerta_12_00_diaria_at)})` : ''}`);
    console.log(`    Descanso corto enviada    : ${j.aviso_descanso_corto_enviada ? 'SÍ' : 'no'} ${j.aviso_descanso_corto_at ? `(${fmtFecha(j.aviso_descanso_corto_at)})` : ''} ${j.descanso_corto_segundos ? `→ ${fmtSeg(j.descanso_corto_segundos)} de descanso` : ''}`);
    console.log(`    Pausa obligatoria excedida (>4h)  : ${j.pausa_obligatoria_excedida ? 'SÍ' : 'no'}`);
    console.log(`    Jornada diaria excedida (>12h)    : ${j.jornada_diaria_excedida ? 'SÍ' : 'no'}`);
    if (jornadaActual > totalDia + 60) {
      console.log(`  ↪ La jornada arrancó el día anterior (jornada > total_dia)`);
    }
    console.log('');

    // 3) Última posición de la patente
    const pat = j.ultima_patente;
    if (pat) {
      const sSnap = await db.collection('SITRACK_POSICIONES').doc(pat).get();
      if (sSnap.exists) {
        const s = sSnap.data();
        console.log(`📍 SITRACK_POSICIONES/${pat}`);
        console.log(`  Velocidad ahora    : ${s.speed ?? '(sin speed)'} km/h`);
        console.log(`  driver_dni         : ${s.driver_dni ?? '(sin chofer)'}`);
        console.log(`  consultado_en      : ${fmtFecha(s.consultado_en)}`);
        if (s.position_at) {
          console.log(`  position_at (GPS)  : ${fmtFecha(s.position_at)}`);
        }
        const polledMs = s.consultado_en?.toMillis?.() ?? 0;
        const haceSeg = polledMs > 0 ? (Date.now() - polledMs) / 1000 : Infinity;
        console.log(`  Hace               : ${fmtSeg(haceSeg)} (stale si > 10m)`);
        console.log('');
      } else {
        console.log(`📍 SITRACK_POSICIONES/${pat} — NO existe`);
        console.log('');
      }
    }
  }

  // 4) Resumen / diagnóstico automático
  if (jSnap.exists) {
    const j = jSnap.data();
    console.log('───────────── INTERPRETACIÓN ─────────────');
    const continuo = j.segundos_continuo_actual ?? 0;
    const pausa = j.segundos_pausa_actual ?? 0;
    if (continuo === 0 && pausa > 0) {
      console.log('  ✓ El chofer está en pausa actualmente — continuo en 0.');
    } else if (continuo > 3 * 3600 + 45 * 60) {
      console.log('  ⚠ El chofer ya superó 3h45 de manejo continuo.');
      console.log('     Si Sebas dice que pausó 15 min y el sistema no reseteó,');
      console.log('     la pausa registrada (segundos_pausa_actual) tendría que');
      console.log('     haber llegado a ≥ 900s en algún ciclo para gatillar el');
      console.log('     reset al volver a manejar.');
    }
    console.log('');
  }

  process.exit(0);
}

main().catch((e) => {
  console.error('❌ Falló:', e.stack || e.message);
  process.exit(1);
});
