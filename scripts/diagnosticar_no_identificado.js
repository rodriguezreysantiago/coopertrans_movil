// Diagnóstico del aviso "pasá el iButton" para un chofer puntual.
//
// Lee:
//   - SITRACK_POSICIONES/{patente} — ¿qué dice Sitrack del chofer?
//   - META_AVISOS_NO_ID/{dni} — throttle de 30 min del bot
//   - EMPLEADOS/{dni} — datos del chofer
//
// Útil para investigar avisos repetidos (caso Juan Flores 2026-05-13:
// 8 avisos en el día con timing irregular).
//
// USO:
//   cd whatsapp-bot
//   node ../scripts/diagnosticar_no_identificado.js <DNI_CHOFER> [PATENTE]

const path = require('path');
const fsNode = require('fs');

const botDir = path.resolve(__dirname, '..', 'whatsapp-bot');
const botNodeModules = path.join(botDir, 'node_modules');
if (!fsNode.existsSync(botNodeModules)) {
  console.error(`❌ No existe ${botNodeModules}`);
  process.exit(1);
}
module.paths.unshift(botNodeModules);
process.chdir(botDir);
require('dotenv').config({ quiet: true });

const admin = require('firebase-admin');
const credPath =
  process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
admin.initializeApp({
  credential: admin.credential.cert(require(path.resolve(credPath))),
  projectId: process.env.FIREBASE_PROJECT_ID || 'coopertrans-movil',
});
const db = admin.firestore();

const dni = (process.argv[2] || '').trim();
const patenteArg = (process.argv[3] || '').trim();
if (!dni) {
  console.error('Uso: node diagnosticar_no_identificado.js <DNI> [PATENTE]');
  process.exit(1);
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

function fmtMin(seg) {
  if (!seg) return '0s';
  const h = Math.floor(seg / 3600);
  const m = Math.floor((seg % 3600) / 60);
  const s = Math.floor(seg % 60);
  return h > 0
    ? `${h}h ${m.toString().padStart(2, '0')}m ${s.toString().padStart(2, '0')}s`
    : `${m}m ${s.toString().padStart(2, '0')}s`;
}

async function main() {
  console.log('\n🔎 DIAGNÓSTICO AVISO "PASÁ EL IBUTTON"');
  console.log('═════════════════════════════════════════');
  console.log(`  DNI : ${dni}`);
  console.log('');

  // 1) Empleado
  const empSnap = await db.collection('EMPLEADOS').doc(dni).get();
  let patente = patenteArg;
  let nombreEmpleado = '';
  let ibuttonEmpleado = '';
  if (empSnap.exists) {
    const e = empSnap.data();
    nombreEmpleado = (e.NOMBRE ?? '').toString().trim();
    ibuttonEmpleado = (e.IBUTTON ?? '').toString().trim();
    console.log('👤 EMPLEADO');
    console.log(`  Nombre   : ${e.NOMBRE ?? '(sin nombre)'}`);
    console.log(`  Vehículo : ${e.VEHICULO ?? '(sin asignar)'}`);
    console.log(`  ROL      : ${e.ROL ?? '(sin rol)'}`);
    console.log(`  IBUTTON  : ${ibuttonEmpleado || '(no cargado)'}`);
    if (!patente && e.VEHICULO && e.VEHICULO !== '-') {
      patente = String(e.VEHICULO).trim().toUpperCase();
    }
    console.log('');
  }
  if (!patente) {
    console.log('⚠ No hay patente asignada al chofer ni provista por arg.');
    process.exit(1);
  }

  // 2) ASIGNACIONES_VEHICULO activa para esa patente (la fuente de
  //    verdad que usa el cron para decidir a quién avisar).
  console.log(`🔗 ASIGNACIONES_VEHICULO (hasta=null) para ${patente}`);
  let asignacionDniCanon = '';
  let asignacionNombreCanon = '';
  try {
    const asignSnap = await db
      .collection('ASIGNACIONES_VEHICULO')
      .where('vehiculo_id', '==', patente)
      .where('hasta', '==', null)
      .limit(5)
      .get();
    if (asignSnap.empty) {
      console.log(`  (no hay asignación activa para ${patente})`);
    } else {
      for (const d of asignSnap.docs) {
        const data = d.data();
        asignacionDniCanon = (data.chofer_dni ?? '').toString().trim();
        asignacionNombreCanon = (data.chofer_nombre ?? '').toString().trim();
        console.log(`  doc ${d.id}`);
        console.log(`    chofer_dni     : ${asignacionDniCanon}`);
        console.log(`    chofer_nombre  : ${asignacionNombreCanon}`);
        console.log(`    desde          : ${fmtFecha(data.desde)}`);
      }
    }
  } catch (e) {
    console.log(`  (error consultando: ${e.message})`);
  }
  console.log('');

  // 3) Sitrack posición actual de la patente
  const sSnap = await db.collection('SITRACK_POSICIONES').doc(patente).get();
  if (!sSnap.exists) {
    console.log(`📍 SITRACK_POSICIONES/${patente} — NO existe`);
  } else {
    const s = sSnap.data();
    const driverDni = (s.driver_dni ?? '').toString().trim();
    const driverNombre = (s.driver_nombre ?? '').toString().trim();
    const driverApellido = (s.driver_apellido ?? '').toString().trim();
    const speed = s.speed ?? 0;
    const ignition = s.ignition === true;
    const driftTipo = s.drift_tipo ?? null;
    const asignDni = (s.asignacion_dni ?? '').toString().trim();
    const asignNombre = (s.asignacion_nombre ?? '').toString().trim();
    const consultadoMs = s.consultado_en?.toMillis?.() ?? 0;
    const haceSeg =
      consultadoMs > 0 ? (Date.now() - consultadoMs) / 1000 : Infinity;
    const reportMs = s.report_date?.toMillis?.() ?? 0;
    const haceReportSeg =
      reportMs > 0 ? (Date.now() - reportMs) / 1000 : Infinity;

    console.log(`📍 SITRACK_POSICIONES/${patente}`);
    console.log(`  driver_dni       : ${driverDni || '(VACÍO ← sin loguear)'}`);
    console.log(`  driver_nombre    : ${driverNombre || '(vacío)'}`);
    console.log(`  driver_apellido  : ${driverApellido || '(vacío)'}`);
    console.log(`  ignition         : ${ignition ? 'ON' : 'OFF'}`);
    console.log(`  speed            : ${speed} km/h`);
    console.log(`  drift_tipo       : ${driftTipo || '(null)'}`);
    console.log(`  asignacion_dni   : ${asignDni || '(vacío)'}`);
    console.log(`  asignacion_nombre: ${asignNombre || '(vacío)'}`);
    console.log(`  report_date      : ${fmtFecha(s.report_date)}  (hace ${fmtMin(haceReportSeg)})`);
    console.log(`  consultado_en    : ${fmtFecha(s.consultado_en)}  (hace ${fmtMin(haceSeg)})`);
    console.log('');

    // Diagnóstico automático del estado
    console.log('───────────── ESTADO ─────────────');
    if (!driverDni && !driverNombre && !driverApellido) {
      console.log('  ⚠ Sitrack no envía driver_* → SIN LOGUEAR (o sesión perdida).');
      if (!ignition) {
        console.log('     ignition=OFF → tractor parado, drift NO debería disparar.');
      } else {
        console.log('     ignition=ON → el aviso "pasá el iButton" SÍ corresponde.');
      }
    } else if (driverDni && driverDni === dni) {
      console.log(`  ✓ driver_dni = ${driverDni} = DNI consultado → LOGUEADO con este DNI.`);
      console.log('     Los avisos son FALSOS POSITIVOS. Pero como driverDni viene en');
      console.log('     SITRACK_POSICIONES, drift_tipo no debería ser CHOFER_NO_IDENTIFICADO.');
      console.log('     Si sigue avisando → ver `report_date` (Sitrack manda data stale).');
    } else if (driverDni && driverDni !== dni) {
      console.log(`  ⚠ driver_dni = ${driverDni} (otro chofer logueado en este tractor).`);
      console.log('     El cron está avisando al chofer ASIGNADO en el sistema');
      console.log(`     (${dni}) pero quien físicamente maneja es ${driverDni}.`);
      console.log('     Solución: actualizar la asignación en el sistema.');
    } else if (!driverDni && (driverNombre || driverApellido)) {
      // Caso clave: sin DNI pero con nombre. Replicamos la lógica del cron.
      const tokens = `${driverNombre} ${driverApellido}`
        .toUpperCase()
        .split(/\s+/)
        .filter((t) => t.length > 1);
      const nombreAsig = (asignNombre || asignacionNombreCanon).toUpperCase();
      const matchPorNombre =
        tokens.length > 0 && tokens.every((t) => nombreAsig.includes(t));
      console.log('  ⚠ driver_dni vacío PERO nombre/apellido SÍ vienen.');
      console.log(`     Tokens Sitrack       : [${tokens.join(', ')}]`);
      console.log(`     Nombre asignación    : "${nombreAsig}"`);
      console.log(`     ¿matchPorNombre?     : ${matchPorNombre ? '✓ SÍ → no debería avisar' : '✗ NO → cron sigue avisando'}`);
      // Dump exacto de cada string con JSON.stringify (que escapa chars
      // invisibles como ​,  , \t, etc.) y char-codes. Si los
      // strings tienen basura no-imprimible, el match falla aunque
      // visualmente parezca correcto.
      console.log('');
      console.log('     ── DUMP EXACTO (chars + códigos) ──');
      const dump = (label, s) => {
        const codes = [...s].map((c) => c.charCodeAt(0).toString(16).padStart(2, '0')).join(' ');
        console.log(`     ${label.padEnd(20)}: ${JSON.stringify(s)}  [len=${s.length}]`);
        console.log(`     ${' '.repeat(20)}  hex: ${codes}`);
      };
      dump('driver_nombre', driverNombre);
      dump('driver_apellido', driverApellido);
      dump('asignacion_nombre', asignNombre);
      tokens.forEach((t, i) => dump(`token[${i}]`, t));
      console.log('');
      if (!matchPorNombre) {
        console.log('     Causa típica: token cortado / diferencia de tildes / orden invertido.');
        console.log('     Solución: revisar campo NOMBRE en EMPLEADOS o cómo cargaron al chofer en Sitrack.');
      } else {
        console.log('     ⚠ matchPorNombre dice SÍ pero drift_tipo persistido es CHOFER_NO_IDENTIFICADO.');
        console.log('     Eso indica un BUG: la lógica del cron evaluó distinto. Posibles causas:');
        console.log('       - Sitrack mandó otros valores en este último ciclo (race condition).');
        console.log('       - Hay un report extra para esta patente con driver_* vacío que pisa.');
        console.log('       - El código deployado en GCP está desactualizado vs functions/src/.');
      }
    }
    console.log('');
  }

  // 3) Meta del throttle (campo real en código: `last_sent_at` —
  // alias histórico)
  const mSnap = await db.collection('META_AVISOS_NO_ID').doc(dni).get();
  if (!mSnap.exists) {
    console.log(`🚦 META_AVISOS_NO_ID/${dni} — NO existe (nunca se avisó)`);
  } else {
    const m = mSnap.data();
    console.log(`🚦 META_AVISOS_NO_ID/${dni}`);
    console.log('  Campos completos del doc:');
    for (const [k, v] of Object.entries(m)) {
      const display =
        v && typeof v.toMillis === 'function' ? fmtFecha(v) : String(v);
      console.log(`    ${k.padEnd(20)} : ${display}`);
    }
    const ts = m.last_sent_at;
    if (ts && typeof ts.toMillis === 'function') {
      const haceSeg = (Date.now() - ts.toMillis()) / 1000;
      console.log(`  → último envío hace ${fmtMin(haceSeg)} (throttle 30 min)`);
      if (haceSeg < 30 * 60) {
        console.log('  ✓ throttle activo, debería bloquear próximos avisos.');
      } else {
        console.log('  ⚠ throttle expirado, próximo cron va a poder avisar.');
      }
    } else {
      console.log('  ⚠ NO hay `last_sent_at` válido → el throttle no se aplica.');
    }
    console.log('');
  }

  // 4) Últimos avisos enviados en COLA_WHATSAPP de este chofer hoy.
  // Query simple por destinatario_id (índice automático single-field)
  // y filtro origen + fecha client-side para no requerir índice
  // compuesto.
  console.log(`📨 COLA_WHATSAPP — avisos no_id de ${dni} (últimos 50):`);
  try {
    const colaSnap = await db
      .collection('COLA_WHATSAPP')
      .where('destinatario_id', '==', dni)
      .limit(500)
      .get();
    const inicioHoyMs = (() => {
      const h = new Date();
      h.setHours(0, 0, 0, 0);
      return h.getTime();
    })();
    const docs = colaSnap.docs
      .map((d) => ({ id: d.id, ...d.data() }))
      .filter((d) => {
        if (d.origen !== 'sitrack_chofer_no_identificado') return false;
        const ms = d.encolado_en?.toMillis?.() ?? 0;
        return ms >= inicioHoyMs;
      })
      .sort((a, b) =>
        (a.encolado_en?.toMillis?.() ?? 0) -
        (b.encolado_en?.toMillis?.() ?? 0)
      );
    if (docs.length === 0) {
      console.log('  (sin avisos no_id encolados hoy)');
    } else {
      console.log(`  ${docs.length} aviso(s):`);
      let prevEnc = 0;
      let prevEnv = 0;
      for (const d of docs) {
        const encMs = d.encolado_en?.toMillis?.() ?? 0;
        const envMs = d.enviado_en?.toMillis?.() ?? 0;
        const enc = fmtFecha(d.encolado_en);
        const env = envMs ? fmtFecha(d.enviado_en) : '(no enviado)';
        const gapEnc = prevEnc ? ` Δenc=${fmtMin((encMs - prevEnc) / 1000)}` : '';
        const gapEnv =
          prevEnv && envMs ? ` Δenv=${fmtMin((envMs - prevEnv) / 1000)}` : '';
        console.log(
          `    [enc ${enc}] [${d.estado}] env: ${env}${gapEnc}${gapEnv}`
        );
        prevEnc = encMs;
        if (envMs) prevEnv = envMs;
      }
    }
  } catch (e) {
    console.log(`  (error consultando: ${e.message})`);
  }

  console.log('');
  process.exit(0);
}

main().catch((e) => {
  console.error('❌ Falló:', e.stack || e.message);
  process.exit(1);
});
