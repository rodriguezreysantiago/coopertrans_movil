// Backfill one-shot del histórico de descargas (ZONA_DESCARGA_HISTORICO).
//
// Reconstruye las descargas de un rango de fechas leyendo SITRACK_EVENTOS
// (que tiene historia real) y aplicando el mismo chequeo de zonas que
// usa el cron en vivo. Sirve para tapar huecos cuando el cron
// `zonaDescargaPoller` no detectó descargas en tiempo real (caso 2026-05-28:
// bug de mismatch de campos `m.latitude` vs `m.lat` skipeaba todas las
// unidades silencioso — fix commit 47e11ff).
//
// Idempotente al docId determinístico (slug+patente+entrada_ms): correr el
// script dos veces sobre el mismo rango Y MISMA GEOMETRÍA sobreescribe los
// mismos docs sin duplicar.
//
// CUIDADO con cambios de geometría (radio o vértices): al cambiar la
// forma de la zona, la ENTRADA al predio se detecta en otro evento, así
// que el `entrada_ms` (y por ende el docId) cambia. Resultado: la misma
// descarga aparece DUPLICADA — el doc viejo con el entrada_ms anterior
// + el doc nuevo. Por eso el script por DEFECTO LIMPIA los docs
// existentes del rango+zona antes de re-armar (--no-limpiar para
// volver al comportamiento puro upsert).
//
// Marca `origen_backfill: true` para distinguir de los archivados por el
// cron en vivo.
//
// USO:
//   node scripts/backfill_descargas.js                  # AYER (default, limpia)
//   node scripts/backfill_descargas.js --dias 3         # últimos N días
//   node scripts/backfill_descargas.js --desde 2026-05-26 --hasta 2026-05-28
//   node scripts/backfill_descargas.js --dias 7 --no-limpiar   # puro upsert
//
// Requiere serviceAccountKey.json (busca en Drive primero, repo local
// como fallback — ver scripts/_lib/firebase_creds.js) + `functions/lib`
// compilado (npm run build adentro de functions/).

const path = require("path");
const fs = require("fs");

// ─── Args CLI ────────────────────────────────────────────────────
function parseArgs() {
  const args = process.argv.slice(2);
  const out = { dias: 1, desde: null, hasta: null, limpiar: true };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--dias") out.dias = parseInt(args[++i], 10);
    else if (a === "--desde") out.desde = args[++i];
    else if (a === "--hasta") out.hasta = args[++i];
    else if (a === "--limpiar") out.limpiar = true;
    else if (a === "--no-limpiar") out.limpiar = false;
  }
  return out;
}

const { dias, desde, hasta, limpiar } = parseArgs();

// ─── Init firebase-admin ─────────────────────────────────────────
// El módulo compilado `historico_descargas.js` importa transitivamente
// `setup.js` que llama `initializeApp()` SIN argumentos (Application
// Default Credentials). El helper `_lib/firebase_creds.js` setea
// GOOGLE_APPLICATION_CREDENTIALS ANTES de cargar firebase-admin,
// resolviéndolo del Drive si está disponible (política multi-PC
// 2026-05-28) o del repo local como fallback.
require('./_lib/firebase_creds');
// firebase-admin no está en el root del proyecto — vive en functions/.
// NO llamamos initializeApp() acá — lo hace `setup.js` cuando se
// carga vía require de `historico_descargas.js`.
require(
  path.join(__dirname, "..", "functions", "node_modules", "firebase-admin"),
);

// ─── Importar la lógica compilada ────────────────────────────────
// La función vive en `functions/lib/historico_descargas.js` (compilada
// por `tsc`). Si no existe, fallar con mensaje claro.
const compiladoPath = path.join(
  __dirname, "..", "functions", "lib", "historico_descargas.js",
);
if (!fs.existsSync(compiladoPath)) {
  console.error(`[backfill_descargas] falta ${compiladoPath}`);
  console.error("Compilá antes con: cd functions && npm run build");
  process.exit(1);
}
const { procesarRangoDescargas } = require(compiladoPath);

// ─── Calcular rangos a procesar ──────────────────────────────────
const UN_DIA = 24 * 60 * 60 * 1000;

function hoyAr00ArtUtc() {
  // 00:00 ART = 03:00 UTC del mismo día calendario ART.
  const ahoraArt = new Date(Date.now() - 3 * 60 * 60 * 1000);
  return new Date(Date.UTC(
    ahoraArt.getUTCFullYear(),
    ahoraArt.getUTCMonth(),
    ahoraArt.getUTCDate(),
    3, 0, 0, 0,
  ));
}

let rangos = [];

if (desde && hasta) {
  const ini = new Date(desde);
  const fin = new Date(hasta);
  if (isNaN(ini.getTime()) || isNaN(fin.getTime())) {
    console.error("[backfill_descargas] --desde/--hasta invalidos (usar YYYY-MM-DD)");
    process.exit(1);
  }
  for (let t = ini.getTime(); t < fin.getTime(); t += UN_DIA) {
    const ic = new Date(t);
    const fc = new Date(Math.min(t + UN_DIA, fin.getTime()));
    rangos.push({ ini: ic, fin: fc, label: ic.toISOString().substring(0, 10) });
  }
} else {
  if (!Number.isInteger(dias) || dias < 1 || dias > 30) {
    console.error("[backfill_descargas] --dias debe ser entero 1-30");
    process.exit(1);
  }
  const hoy = hoyAr00ArtUtc();
  for (let i = 1; i <= dias; i++) {
    const fin = new Date(hoy.getTime() - (i - 1) * UN_DIA);
    const ini = new Date(fin.getTime() - UN_DIA);
    rangos.push({ ini, fin, label: ini.toISOString().substring(0, 10) });
  }
}

console.log(
  `[backfill_descargas] procesando ${rangos.length} día(s) ` +
  `(${limpiar ? "CON LIMPIEZA previa" : "sin limpieza, upsert puro"}): ` +
  rangos.map((r) => r.label).join(", "),
);

// ─── Limpieza opcional ───────────────────────────────────────────
// Borra los docs existentes del rango cuyos `entrada_ts` caen en el
// rango. Necesario cuando cambiamos la geometría de una zona — el
// docId determinístico cambia y los docs viejos quedan duplicados
// con los nuevos. Indispensable después de cambios de radio/polígono.
const admin = require(
  path.join(__dirname, "..", "functions", "node_modules", "firebase-admin"),
);
const db = admin.firestore();

async function limpiarHistoricoRango(desde, hasta) {
  const snap = await db.collection("ZONA_DESCARGA_HISTORICO")
    .where("entrada_ts", ">=", admin.firestore.Timestamp.fromDate(desde))
    .where("entrada_ts", "<", admin.firestore.Timestamp.fromDate(hasta))
    .get();
  let borrados = 0;
  // Firestore batch limita a 500 ops; trabajamos en chunks de 400.
  for (let i = 0; i < snap.docs.length; i += 400) {
    const chunk = snap.docs.slice(i, i + 400);
    const batch = db.batch();
    for (const d of chunk) batch.delete(d.ref);
    await batch.commit();
    borrados += chunk.length;
  }
  return borrados;
}

// ─── Procesar ────────────────────────────────────────────────────
(async () => {
  let totEventos = 0;
  let totDescargas = 0;
  let totWrites = 0;
  let totBorrados = 0;
  for (const r of rangos) {
    console.log(`\n[backfill_descargas] === ${r.label} ===`);
    console.log(`  desde: ${r.ini.toISOString()}`);
    console.log(`  hasta: ${r.fin.toISOString()}`);
    try {
      if (limpiar) {
        const borrados = await limpiarHistoricoRango(r.ini, r.fin);
        console.log(`  docs viejos borrados: ${borrados}`);
        totBorrados += borrados;
      }
      const res = await procesarRangoDescargas(r.ini, r.fin);
      console.log(`  zonas activas: ${res.zonas}`);
      console.log(`  eventos analizados: ${res.eventos}`);
      console.log(`  descargas detectadas: ${res.descargas}`);
      console.log(`  docs escritos: ${res.writes}`);
      totEventos += res.eventos;
      totDescargas += res.descargas;
      totWrites += res.writes;
    } catch (e) {
      console.error(`  ERROR: ${e.message}`);
    }
  }
  console.log("\n[backfill_descargas] TOTAL:");
  if (limpiar) console.log(`  docs viejos borrados: ${totBorrados}`);
  console.log(`  eventos analizados: ${totEventos}`);
  console.log(`  descargas detectadas: ${totDescargas}`);
  console.log(`  docs escritos: ${totWrites}`);
  process.exit(0);
})();
