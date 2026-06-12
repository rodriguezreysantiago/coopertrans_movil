// Backfill de km_unidad_al_montar en GOMERIA_MONTAJES (auditoría 2026-06-12).
//
// Problema: la pantalla v2 de gomería montaba cubiertas sin pasar el
// odómetro del tractor → km_unidad_al_montar quedó null y el semáforo de
// desgaste muestra "sin datos" en esos montajes. El fix de código ya
// resuelve los montajes NUEVOS; este script repara los EXISTENTES.
//
// Cómo: para cada montaje ACTIVO (hasta == null) de TRACTOR con base null,
// busca en TELEMETRIA_HISTORICO el snapshot diario de esa patente en la
// fecha del montaje (docId = {patente}_{YYYY-MM-DD}); si ese día no hay
// snapshot, prueba hasta 7 días hacia atrás (el km de unos días antes es
// una base apenas conservadora — infla el desgaste, nunca lo esconde).
// Enganches no se tocan (no tienen odómetro; el cálculo robusto por
// asignaciones ya los cubre).
//
// USO (PowerShell, desde la raíz del repo):
//
//   node scripts/backfill_km_montajes.js            # dry-run (no escribe)
//   node scripts/backfill_km_montajes.js --commit   # escribe en Firestore
//
// Credenciales: mismo patrón multi-PC que el resto (_lib/firebase_creds).

const path = require('path');
const fsNode = require('fs');

// Reusar node_modules del bot — admin SDK ya está instalado allá.
const botDir = path.resolve(__dirname, '..', 'whatsapp-bot');
const botNodeModules = path.join(botDir, 'node_modules');
if (!fsNode.existsSync(botNodeModules)) {
  console.error(
    `❌ No existe ${botNodeModules}. Corré 'npm install' en whatsapp-bot primero.`
  );
  process.exit(1);
}
module.paths.unshift(botNodeModules);

const { credPath } = require('./_lib/firebase_creds');
const admin = require('firebase-admin');

admin.initializeApp({
  credential: admin.credential.cert(require(credPath)),
});
const db = admin.firestore();

const COMMIT = process.argv.includes('--commit');
const DIAS_HACIA_ATRAS = 7;

// YYYY-MM-DD en ART para un Date (mismo formatter que usa la CF).
const fmtArt = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'America/Argentina/Buenos_Aires',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
});

async function kmTelemetriaEn(patente, fechaBase) {
  for (let i = 0; i <= DIAS_HACIA_ATRAS; i++) {
    const d = new Date(fechaBase.getTime() - i * 24 * 60 * 60 * 1000);
    const docId = `${patente}_${fmtArt.format(d)}`;
    const snap = await db.collection('TELEMETRIA_HISTORICO').doc(docId).get();
    if (snap.exists) {
      const km = snap.data().km;
      if (typeof km === 'number' && km > 0) {
        return { km, docId, diasAtras: i };
      }
    }
  }
  return null;
}

(async () => {
  console.log(COMMIT ? '🔥 MODO COMMIT — va a escribir' : '🧪 DRY-RUN (sin escrituras; --commit para aplicar)');

  const snap = await db
    .collection('GOMERIA_MONTAJES')
    .where('hasta', '==', null)
    .get();

  let candidatos = 0;
  let resueltos = 0;
  let sinTelemetria = 0;

  for (const doc of snap.docs) {
    const m = doc.data();
    if (m.unidad_tipo !== 'TRACTOR') continue;
    if (m.km_unidad_al_montar != null) continue;
    candidatos++;

    const patente = m.unidad_id;
    const desde = m.desde && m.desde.toDate ? m.desde.toDate() : null;
    if (!patente || !desde) {
      console.log(`  ⚠️  ${doc.id} sin patente o sin fecha desde — salteado`);
      continue;
    }

    const hit = await kmTelemetriaEn(patente, desde);
    if (!hit) {
      sinTelemetria++;
      console.log(
        `  ❌ ${patente} pos ${m.posicion} (${fmtArt.format(desde)}): sin ` +
        `telemetría en ${DIAS_HACIA_ATRAS + 1} días — queda null`
      );
      continue;
    }

    resueltos++;
    const nota = hit.diasAtras === 0 ? 'mismo día' : `${hit.diasAtras} día(s) antes`;
    console.log(
      `  ✅ ${patente} pos ${m.posicion} (${fmtArt.format(desde)}): ` +
      `km_unidad_al_montar = ${hit.km.toLocaleString('es-AR')} (${nota}, ${hit.docId})`
    );
    if (COMMIT) {
      await doc.ref.update({ km_unidad_al_montar: hit.km });
    }
  }

  console.log(
    `\nMontajes activos: ${snap.size} · candidatos (tractor, base null): ` +
    `${candidatos} · resueltos: ${resueltos} · sin telemetría: ${sinTelemetria}`
  );
  if (!COMMIT && resueltos > 0) {
    console.log('Re-corré con --commit para aplicar.');
  }
  process.exit(0);
})();
