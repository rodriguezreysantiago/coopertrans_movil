// Diagnóstico del resumen diario de excesos de jornada que llega a
// Alejandra Molina por WhatsApp. Reportado 2026-05-12: hace 3 días
// que el bot dice "ningún chofer excedió 4h continuas ni 12h diarias".
//
// Verifica:
//   1. JORNADAS_CHOFER de los últimos 3 días — qué minutos acumularon
//      cada chofer, si alguno está cerca o pasó el umbral, cuántos
//      docs hay por día (debería haber ~50 si el sistema está sano).
//   2. SITRACK_POSICIONES — última actualización por patente. Si el
//      poller dejó de pedir, todas las posiciones quedan stale y el
//      vigilador descarta los snapshots por el check de "polled_en"
//      > 10 min, lo cual hace que ningún chofer acumule jornada.
//   3. Conteo de posiciones con `driver_dni` poblado vs vacías —
//      si el chofer no se identifica, el vigilador SKIPea.
//
// Uso desde la raíz del repo:
//   node scripts/diagnosticar_jornadas_excesos.js

const path = require("path");

const botDir = path.resolve(__dirname, "..", "whatsapp-bot");
module.paths.unshift(path.join(botDir, "node_modules"));
process.chdir(botDir);
require("dotenv").config({ quiet: true });

const admin = require("firebase-admin");
const credPath = path.resolve(
  process.env.FIREBASE_CREDENTIALS_PATH || "../serviceAccountKey.json"
);
admin.initializeApp({
  credential: admin.credential.cert(require(credPath)),
  projectId: "coopertrans-movil",
});
const db = admin.firestore();

/// Devuelve YYYY-MM-DD en zona ART de un Date.
function fechaArt(date) {
  const opts = { timeZone: "America/Argentina/Buenos_Aires" };
  const partes = new Intl.DateTimeFormat("en-CA", {
    ...opts,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const y = partes.find((p) => p.type === "year").value;
  const m = partes.find((p) => p.type === "month").value;
  const d = partes.find((p) => p.type === "day").value;
  return `${y}-${m}-${d}`;
}

function formatHHMM(segundos) {
  if (!segundos || segundos < 0) return "0:00";
  const h = Math.floor(segundos / 3600);
  const m = Math.floor((segundos % 3600) / 60);
  return `${h}:${m.toString().padStart(2, "0")}`;
}

(async () => {
  // ─── 1. JORNADAS_CHOFER últimos 3 días ────────────────────────
  const hoy = new Date();
  const dias = [];
  for (let i = 0; i < 3; i++) {
    const d = new Date(hoy.getTime() - i * 24 * 3600 * 1000);
    dias.push(fechaArt(d));
  }

  console.log(`\n=== JORNADAS_CHOFER últimos 3 días ===\n`);
  for (const fecha of dias) {
    const snap = await db
      .collection("JORNADAS_CHOFER")
      .where("fecha_art", "==", fecha)
      .get();

    const docs = snap.docs;
    const totalSeg = docs.reduce(
      (a, d) => a + (d.data().segundos_total_dia ?? 0),
      0
    );
    const conMov = docs.filter(
      (d) => (d.data().segundos_total_dia ?? 0) > 60
    ).length;
    const cercaContinua = docs.filter((d) => {
      const s = d.data().segundos_continuo_actual ?? 0;
      return s >= 3 * 3600 && s < 4 * 3600;
    }).length;
    const excedioContinua = docs.filter(
      (d) => d.data().pausa_obligatoria_excedida === true
    ).length;
    const cercaDiaria = docs.filter((d) => {
      const s = d.data().segundos_total_dia ?? 0;
      return s >= 10 * 3600 && s < 12 * 3600;
    }).length;
    const excedioDiaria = docs.filter(
      (d) => d.data().jornada_diaria_excedida === true
    ).length;

    console.log(`📅 ${fecha}`);
    console.log(`   Total docs: ${docs.length}`);
    console.log(`   Choferes con > 1 min de movimiento: ${conMov}`);
    console.log(`   Suma total minutos manejados: ${formatHHMM(totalSeg)}`);
    console.log(
      `   Cerca de 4h continua (3-4h): ${cercaContinua}  |  Excedió 4h: ${excedioContinua}`
    );
    console.log(
      `   Cerca de 12h diaria (10-12h): ${cercaDiaria}  |  Excedió 12h: ${excedioDiaria}`
    );

    // Top 3 más manejaron — si son razonables (8-11h) está sano
    const top = [...docs]
      .sort(
        (a, b) =>
          (b.data().segundos_total_dia ?? 0) -
          (a.data().segundos_total_dia ?? 0)
      )
      .slice(0, 3);
    if (top.length > 0) {
      console.log(`   Top 3 del día:`);
      for (const d of top) {
        const data = d.data();
        const dni = d.id.split("_")[0];
        console.log(
          `     ${dni}: total=${formatHHMM(data.segundos_total_dia ?? 0)}  continuo=${formatHHMM(data.segundos_continuo_actual ?? 0)}`
        );
      }
    }
    console.log("");
  }

  // ─── 2. SITRACK_POSICIONES — frescura del poller ─────────────
  console.log(`\n=== SITRACK_POSICIONES — estado del poller ===\n`);
  const sitSnap = await db.collection("SITRACK_POSICIONES").get();
  const total = sitSnap.size;

  const ahora = Date.now();
  const STALE_MIN = 10;
  const buckets = {
    fresca: 0, // < 10 min
    pocoVieja: 0, // 10-60 min
    vieja: 0, // 1-24h
    muyVieja: 0, // > 24h
    sinFecha: 0,
  };
  let conSpeed = 0;
  let conDriver = 0;
  const ejemplosStale = [];
  let ultimaActualizacion = 0;

  for (const doc of sitSnap.docs) {
    const data = doc.data();
    // El poller escribe `consultado_en` (no `polled_en`). Soportamos
    // ambos por si en el futuro cambia el nombre.
    const polledEn =
      data.consultado_en?.toDate?.() ??
      data.consultado_en ??
      data.polled_en?.toDate?.() ??
      data.polled_en;
    if (!polledEn) {
      buckets.sinFecha++;
      continue;
    }
    const ageMs = ahora - polledEn.getTime();
    const ageMin = ageMs / 60000;
    if (polledEn.getTime() > ultimaActualizacion) {
      ultimaActualizacion = polledEn.getTime();
    }
    if (ageMin < STALE_MIN) buckets.fresca++;
    else if (ageMin < 60) buckets.pocoVieja++;
    else if (ageMin < 60 * 24) buckets.vieja++;
    else {
      buckets.muyVieja++;
      if (ejemplosStale.length < 3) {
        const horas = (ageMin / 60).toFixed(1);
        ejemplosStale.push(`${doc.id}: ${horas}h vieja`);
      }
    }

    const sp = data.speed ?? data.gpsSpeed;
    if (typeof sp === "number" && sp > 0) conSpeed++;
    if (data.driver_dni && String(data.driver_dni).trim() !== "") {
      conDriver++;
    }
  }

  console.log(`Total posiciones registradas: ${total}`);
  console.log(`  ✅ Frescas (< ${STALE_MIN} min):           ${buckets.fresca}`);
  console.log(`  ⚠️  Poco viejas (10-60 min):           ${buckets.pocoVieja}`);
  console.log(`  ❌ Viejas (1-24h):                     ${buckets.vieja}`);
  console.log(`  ❌ Muy viejas (> 24h):                 ${buckets.muyVieja}`);
  console.log(`  ⚠️  Sin polled_en:                     ${buckets.sinFecha}`);
  console.log("");
  console.log(`Con speed > 0 ahora:                     ${conSpeed}`);
  console.log(`Con driver_dni identificado:             ${conDriver}/${total}`);
  if (ultimaActualizacion > 0) {
    const ult = new Date(ultimaActualizacion);
    const horasAtras = (
      (ahora - ultimaActualizacion) /
      3600000
    ).toFixed(2);
    console.log(
      `Última actualización registrada:         ${ult.toISOString()} (${horasAtras}h atrás)`
    );
  }
  if (ejemplosStale.length > 0) {
    console.log(`\nEjemplos de posiciones muy viejas:`);
    ejemplosStale.forEach((e) => console.log(`  ${e}`));
  }

  // ─── 3. Diagnóstico final ────────────────────────────────────
  console.log(`\n=== DIAGNÓSTICO ===\n`);

  const horasUlt =
    ultimaActualizacion > 0 ? (ahora - ultimaActualizacion) / 3600000 : Infinity;

  if (horasUlt > 1) {
    console.log(
      `❌ El POLLER Sitrack está CAÍDO. Última actualización hace ${horasUlt.toFixed(2)}h.`
    );
    console.log(
      `   Causa probable de los reportes "sin excesos": el vigilador ve`
    );
    console.log(
      `   las posiciones como stale (>10min) y descarta los snapshots —`
    );
    console.log(
      `   ningún chofer acumula jornada → resumen siempre dice "sin excesos".`
    );
    console.log(
      `   Acción: revisar logs de sitrackPosicionPoller en Cloud Functions.`
    );
  } else if (buckets.muyVieja > total * 0.5) {
    console.log(
      `⚠️  Más del 50% de las posiciones tienen > 24h sin actualizar.`
    );
    console.log(`   El poller está corriendo pero no para todas las unidades.`);
  } else if (conSpeed === 0) {
    console.log(
      `❌ Ninguna unidad tiene speed > 0 ahora. Capaz están todos detenidos`
    );
    console.log(
      `   en este momento puntual; pero si junto con jornadas en 0:00 → bug.`
    );
  } else if (conDriver < total * 0.3) {
    console.log(
      `⚠️  Solo ${conDriver}/${total} unidades tienen driver_dni identificado.`
    );
    console.log(
      `   El vigilador skipea las que no tienen → gran porción de la flota`
    );
    console.log(`   no acumula jornada. Recordar a los choferes pasar iButton.`);
  } else {
    console.log(`✅ Poller sano. Si las jornadas siguen en 0, mirar logs del`);
    console.log(
      `   vigiladorJornadaChofer en Cloud Functions (últimas 72h) por`
    );
    console.log(`   excepciones "[vigiladorJornadaChofer] fallo procesar chofer".`);
  }

  process.exit(0);
})().catch((e) => {
  console.error("error:", e);
  process.exit(1);
});
