// =====================================================================
// DEPRECATED 2026-05-16 — apunta a JORNADAS_CHOFER (colección legacy).
// =====================================================================
// La colección `JORNADAS_CHOFER` fue migrada a `JORNADAS` (modelo v2
// con bloques 3x4h) el 2026-05-15. Este script ya NO sirve: o no
// encuentra docs (porque la colección vieja está vacía / limpiada
// con limpiar_jornadas_chofer_legacy.js) o borra docs equivocados.
//
// El modelo nuevo NO se "resetea" — cada jornada es un doc inmutable
// `{dni}_{ts_inicio_ms}` que el vigilador abre/cierra automáticamente
// según ignición + descanso 8h en misma posición. Si hay un bug del
// vigilador, el fix correcto es en functions/src/jornadas_v2.ts, no
// borrar docs JORNADAS desde acá.
//
// Si necesitás algo equivalente para JORNADAS, hay que armar uno
// nuevo. Mientras tanto este script abortará al principio para evitar
// que alguien lo corra sin querer.
console.error(
  "ERROR: este script apunta a JORNADAS_CHOFER (legacy). " +
    "Borrado del flujo operativo. Ver comentario al principio del archivo."
);
process.exit(1);

// Resetea el doc JORNADAS_CHOFER de un chofer del día actual.
//
// Caso de uso: el vigilador acumuló segundos erróneos (bug de
// poll stale o GPS drift) y disparó alertas falsas. Mientras el
// fix se deploya, este script resetea el doc del chofer para
// frenar las alertas y arrancar de cero el conteo.
//
// El cron del próximo ciclo va a actualizar el doc con la
// posición actual y empezar a sumar bien (con el fix que valida
// `polled_en` y umbral 15 km/h).
//
// Uso (desde la raíz del repo):
//   node scripts/resetear_jornada_chofer.js <DNI>
//   node scripts/resetear_jornada_chofer.js 12345678 --dry-run
//
// El doc se borra (delete). El cron lo recreará en el próximo ciclo
// con segundos_total_dia=0.
//
// Sin dependencias custom — usa firebase-admin de whatsapp-bot/
// node_modules (instalado por el bot). Si el bot no está instalado,
// correr `npm install firebase-admin` en la raíz del repo.

const path = require("path");
const fs = require("fs");

// Resolver firebase-admin desde whatsapp-bot/node_modules (siempre
// instalado en multi-PC). Fallback a node_modules raíz si lo
// instalaste a mano.
let admin;
try {
  admin = require(path.join(__dirname, "..", "whatsapp-bot", "node_modules", "firebase-admin"));
} catch (_) {
  try {
    admin = require("firebase-admin");
  } catch (_) {
    console.error(
      "No encuentro firebase-admin. Corré desde la raíz del repo " +
        "después de un `cd whatsapp-bot && npm install`, o " +
        "instalalo en la raíz: `npm install firebase-admin`."
    );
    process.exit(1);
  }
}

const dni = process.argv[2];
const dryRun = process.argv.includes("--dry-run");

if (!dni || /^[^\d]/.test(dni)) {
  console.error("Uso: node scripts/resetear_jornada_chofer.js <DNI> [--dry-run]");
  console.error("Ejemplo: node scripts/resetear_jornada_chofer.js 12345678");
  process.exit(1);
}

// Init Firebase Admin con service account del repo (raíz, mismo
// archivo que usa el bot y los demás scripts Python).
const credsPath = path.resolve(
  path.join(__dirname, "..", "serviceAccountKey.json")
);
if (!fs.existsSync(credsPath)) {
  console.error(`No encuentro service account en ${credsPath}`);
  process.exit(1);
}
admin.initializeApp({
  credential: admin.credential.cert(require(credsPath)),
  projectId: "coopertrans-movil",
});
const db = admin.firestore();

async function main() {
  // Fecha de hoy en TZ Argentina (mismo formato que el cron).
  const fechaArt = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());

  const docId = `${dni}_${fechaArt}`;
  const ref = db.collection("JORNADAS_CHOFER").doc(docId);
  const snap = await ref.get();

  if (!snap.exists) {
    console.log(`No hay doc ${docId} — nada que resetear.`);
    return;
  }

  const data = snap.data();
  const totalDia = data.segundos_total_dia || 0;
  const continuoActual = data.segundos_continuo_actual || 0;
  console.log(`Doc encontrado: ${docId}`);
  console.log(`  segundos_total_dia: ${totalDia}s = ${(totalDia / 3600).toFixed(2)}h`);
  console.log(`  segundos_continuo_actual: ${continuoActual}s = ${(continuoActual / 3600).toFixed(2)}h`);
  console.log(`  alerta_3_45_continua_enviada: ${data.alerta_3_45_continua_enviada}`);
  console.log(`  alerta_11_30_diaria_enviada: ${data.alerta_11_30_diaria_enviada}`);
  console.log("");

  if (dryRun) {
    console.log("DRY-RUN: no se borró nada. Para borrar: corré sin --dry-run.");
    return;
  }

  await ref.delete();
  console.log("OK. Doc borrado.");
  console.log("El próximo ciclo del cron (5 min) lo va a recrear con total=0.");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error("ERROR:", e.message);
    process.exit(1);
  });
