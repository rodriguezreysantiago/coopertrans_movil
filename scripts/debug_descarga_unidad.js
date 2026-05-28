// Diagnóstico de descargas para una patente:
//   - última posición conocida (lat/lng/staleness/motor)
//   - para cada zona activa: si la unidad cae adentro
//   - si está actualmente en ZONA_DESCARGA_COLA
//
// USO:
//   node scripts/debug_descarga_unidad.js AH628EI
//
// Útil cuando una unidad debería aparecer en la cola y no aparece —
// el output te dice si es por geometría (afuera del polígono), por
// staleness de posición, por motor apagado, etc.
const path = require("path");

// Resolver credenciales (Drive > env > repo local) y setear
// GOOGLE_APPLICATION_CREDENTIALS antes de cargar admin.
require('./_lib/firebase_creds');
const admin = require(
  path.join(__dirname, "..", "functions", "node_modules", "firebase-admin"),
);
admin.initializeApp();
const db = admin.firestore();

const PATENTE = (process.argv[2] || "AH628EI").toUpperCase();

function distMts(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
      Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

function puntoEnPoligono(lat, lng, vertices) {
  let dentro = false;
  for (let i = 0, j = vertices.length - 1; i < vertices.length; j = i++) {
    const xi = vertices[i].lng;
    const yi = vertices[i].lat;
    const xj = vertices[j].lng;
    const yj = vertices[j].lat;
    const intersect = ((yi > lat) !== (yj > lat)) &&
      (lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi);
    if (intersect) dentro = !dentro;
  }
  return dentro;
}

(async () => {
  console.log(`\n=== POSICIÓN ACTUAL DE ${PATENTE} ===`);
  const posDoc = await db.collection("SITRACK_POSICIONES").doc(PATENTE).get();
  if (!posDoc.exists) {
    console.log(`❌ No existe doc para ${PATENTE} en SITRACK_POSICIONES.`);
    process.exit(0);
  }
  const pos = posDoc.data();
  console.log(`  lat: ${pos.lat}`);
  console.log(`  lng: ${pos.lng}`);
  console.log(`  ignition: ${pos.ignition}`);
  const reportTs = pos.report_date ? pos.report_date.toDate() : null;
  console.log(`  report_date: ${reportTs ? reportTs.toISOString() : "null"}`);
  if (reportTs) {
    const minAgo = Math.round((Date.now() - reportTs.getTime()) / 60000);
    const stale = minAgo > 15;
    console.log(`  → hace ${minAgo} min ${stale ? "(STALE > 15 min → cron skip)" : "(fresca)"}`);
  }
  console.log(`  driver_dni: ${pos.driver_dni}`);
  console.log(`  driver_nombre: ${pos.driver_nombre}`);

  console.log(`\n=== ZONAS ACTIVAS ===`);
  const zonasSnap = await db.collection("ZONAS_DESCARGA")
    .where("activo", "==", true).get();
  for (const z of zonasSnap.docs) {
    const m = z.data();
    const dentroPoligono = m.shape === "poligono" && Array.isArray(m.vertices) ?
      puntoEnPoligono(pos.lat, pos.lng, m.vertices) : null;
    const distCirc = m.shape === "circulo" && m.centro && m.radio_mts ?
      distMts(pos.lat, pos.lng, m.centro.lat, m.centro.lng) : null;
    console.log(`\n  Zona: ${m.nombre} (slug=${m.slug || z.id})`);
    console.log(`    shape: ${m.shape}`);
    console.log(`    estadia_min_min: ${m.estadia_min_min}`);
    if (m.shape === "circulo") {
      console.log(`    centro: ${m.centro?.lat}, ${m.centro?.lng}`);
      console.log(`    radio_mts: ${m.radio_mts}`);
      console.log(`    distancia ${PATENTE}: ${Math.round(distCirc)} m`);
      console.log(`    → ${distCirc <= m.radio_mts ? "DENTRO" : "FUERA"}`);
    } else if (m.shape === "poligono") {
      console.log(`    vertices (${m.vertices.length}):`);
      for (const v of m.vertices) {
        console.log(`      ${v.lat}, ${v.lng}`);
      }
      console.log(`    → ${dentroPoligono ? "DENTRO" : "FUERA"}`);
    }
  }

  console.log(`\n=== COLA ACTUAL ===`);
  const colaSnap = await db.collection("ZONA_DESCARGA_COLA").get();
  console.log(`  Total docs en cola: ${colaSnap.size}`);
  const mias = colaSnap.docs.filter((d) =>
    (d.data().patente || "").toUpperCase() === PATENTE);
  console.log(`  Docs para ${PATENTE}: ${mias.length}`);
  for (const d of mias) {
    console.log(`    docId: ${d.id}`);
    console.log(`    ${JSON.stringify(d.data())}`);
  }

  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
