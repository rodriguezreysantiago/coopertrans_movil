// Diagnóstico de descargas por (patente, fecha, zona):
//   - lista todos los eventos Sitrack de la patente en el día ART
//   - marca cuáles caen DENTRO de cada zona activa (o de una zona puntual)
//   - reconstruye las ventanas continuas (entradas/salidas/durac) por zona
//   - dice por qué quedaron descartadas (estadía mínima, gap, etc.)
//
// USO:
//   node scripts/debug_descarga_dia.js AF301ZO 2026-05-25
//   node scripts/debug_descarga_dia.js AF301ZO 2026-05-25 ypf_planta_anelo
//
// Si no pasás slug, recorre todas las zonas activas.

const path = require("path");

const PATENTE = (process.argv[2] || "").toUpperCase();
const FECHA = process.argv[3] || ""; // YYYY-MM-DD ART
const SLUG_FILTRO = (process.argv[4] || "").toLowerCase();

if (!PATENTE || !FECHA) {
  console.error("USO: node scripts/debug_descarga_dia.js PATENTE YYYY-MM-DD [slug_zona]");
  process.exit(1);
}

// Resolver credenciales (Drive > env > repo local) y setear
// GOOGLE_APPLICATION_CREDENTIALS antes de cargar admin.
require('./_lib/firebase_creds');
const admin = require(
  path.join(__dirname, "..", "functions", "node_modules", "firebase-admin"),
);
admin.initializeApp();
const db = admin.firestore();

const GAP_MAX_MS = 30 * 60 * 1000;

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
    const xi = vertices[i].lng, yi = vertices[i].lat;
    const xj = vertices[j].lng, yj = vertices[j].lat;
    const intersect = ((yi > lat) !== (yj > lat)) &&
      (lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi);
    if (intersect) dentro = !dentro;
  }
  return dentro;
}

function dentroDeZona(lat, lng, z) {
  if (z.shape === "circulo" && z.centro && z.radio_mts) {
    return distMts(lat, lng, z.centro.lat, z.centro.lng) <= z.radio_mts;
  }
  if (z.shape === "poligono" && Array.isArray(z.vertices) && z.vertices.length >= 3) {
    return puntoEnPoligono(lat, lng, z.vertices);
  }
  return false;
}

function fmtTs(d) {
  return d.toISOString().substring(11, 19);
}

(async () => {
  // Rango día ART → UTC
  const desde = new Date(`${FECHA}T03:00:00.000Z`);
  const hasta = new Date(desde.getTime() + 24 * 60 * 60 * 1000);

  console.log(`\nPatente: ${PATENTE}`);
  console.log(`Día ART: ${FECHA}`);
  console.log(`Rango UTC: ${desde.toISOString()} → ${hasta.toISOString()}\n`);

  // Zonas activas
  const zonasSnap = await db.collection("ZONAS_DESCARGA")
    .where("activo", "==", true).get();
  let zonas = zonasSnap.docs.map((d) => ({ ...d.data(), _id: d.id }));
  if (SLUG_FILTRO) {
    zonas = zonas.filter((z) => (z.slug || z._id).toLowerCase() === SLUG_FILTRO);
    if (zonas.length === 0) {
      console.log(`No hay zona activa con slug "${SLUG_FILTRO}"`);
      process.exit(0);
    }
  }
  console.log(`Zonas a evaluar: ${zonas.map((z) => z.slug || z._id).join(", ")}\n`);

  // Eventos del día — query por rango de fecha (índice nativo) y
  // filtrado por patente en memoria. Evita necesitar un índice compuesto
  // (asset_id, report_date) que solo usa este script de debug.
  const snap = await db.collection("SITRACK_EVENTOS")
    .where("report_date", ">=", admin.firestore.Timestamp.fromDate(desde))
    .where("report_date", "<", admin.firestore.Timestamp.fromDate(hasta))
    .get();

  const eventos = snap.docs.map((d) => d.data())
    .filter((m) => (m.asset_id || "").toString().toUpperCase() === PATENTE)
    .sort((a, b) => a.report_date.toMillis() - b.report_date.toMillis());

  console.log(`Eventos del día (total ${snap.size}, filtrados ${PATENTE}: ${eventos.length})\n`);

  if (eventos.length === 0) {
    console.log(`❌ Sitrack no reporta eventos para ${PATENTE} ese día.`);
    console.log("   Verificar: patente exacta en SITRACK_EVENTOS.asset_id,");
    console.log("   fecha ART correcta, equipo encendido durante el día.");
    process.exit(0);
  }

  // Stats globales
  const conCoords = eventos.filter((e) =>
    typeof e.latitude === "number" && typeof e.longitude === "number" &&
    !(e.latitude === 0 && e.longitude === 0));
  console.log(`  con lat/lng válido: ${conCoords.length}/${eventos.length}`);
  if (conCoords.length > 0) {
    const primero = conCoords[0];
    const ultimo = conCoords[conCoords.length - 1];
    console.log(`  primer reporte: ${fmtTs(primero.report_date.toDate())} UTC en ${primero.latitude},${primero.longitude}`);
    console.log(`  último reporte: ${fmtTs(ultimo.report_date.toDate())} UTC en ${ultimo.latitude},${ultimo.longitude}`);
  }

  // Por zona
  for (const z of zonas) {
    const slug = z.slug || z._id;
    const estadiaMinMs = (typeof z.estadia_min_min === "number" ? z.estadia_min_min : 5) * 60 * 1000;
    console.log(`\n=== Zona ${slug} (${z.nombre}, shape=${z.shape}, estadia_min=${z.estadia_min_min}min) ===`);

    let adentro = 0;
    const eventosDentro = [];
    for (const e of conCoords) {
      if (dentroDeZona(e.latitude, e.longitude, z)) {
        adentro++;
        eventosDentro.push(e);
      }
    }
    console.log(`  eventos DENTRO de la zona: ${adentro}`);

    if (adentro === 0) {
      // Mostrar el evento más cercano para diagnóstico geométrico
      let mejor = null;
      let mejorDist = Infinity;
      for (const e of conCoords) {
        if (z.shape === "circulo" && z.centro) {
          const d = distMts(e.latitude, e.longitude, z.centro.lat, z.centro.lng);
          if (d < mejorDist) { mejorDist = d; mejor = e; }
        }
      }
      if (mejor && z.shape === "circulo") {
        console.log(`  evento más cercano: ${fmtTs(mejor.report_date.toDate())} UTC a ${Math.round(mejorDist)}m del centro (radio = ${z.radio_mts}m)`);
        console.log(`    pos: ${mejor.latitude}, ${mejor.longitude}`);
      }
      continue;
    }

    // Reconstruir ventanas
    console.log(`\n  Reconstruyendo ventanas:`);
    let entrada = null;
    let ultDentro = null;
    let count = 0;
    const ventanas = [];
    const cerrar = () => {
      if (entrada && ultDentro) {
        const durMs = ultDentro.report_date.toMillis() - entrada.report_date.toMillis();
        const valida = durMs >= estadiaMinMs;
        ventanas.push({ entrada, salida: ultDentro, durMs, count, valida });
      }
      entrada = null; ultDentro = null; count = 0;
    };
    for (const e of eventosDentro) {
      if (!entrada) {
        entrada = e; ultDentro = e; count = 1;
      } else {
        const gap = e.report_date.toMillis() - ultDentro.report_date.toMillis();
        if (gap > GAP_MAX_MS) {
          cerrar();
          entrada = e; ultDentro = e; count = 1;
        } else {
          ultDentro = e; count++;
        }
      }
    }
    if (entrada) cerrar();

    for (const v of ventanas) {
      const minDur = Math.round(v.durMs / 60000);
      const flag = v.valida ? "✓ ARCHIVADA" :
        `✗ DESCARTADA (${minDur}min < ${z.estadia_min_min}min)`;
      console.log(`    ${fmtTs(v.entrada.report_date.toDate())} → ${fmtTs(v.salida.report_date.toDate())} UTC | ${minDur}min | ${v.count}ev | ${flag}`);
    }
    if (ventanas.length === 0) console.log("    (ninguna)");
  }

  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
