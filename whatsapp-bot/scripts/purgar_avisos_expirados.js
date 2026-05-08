// Purga avisos PENDIENTE en COLA_WHATSAPP que perdieron sentido
// temporal (vigilador de jornada, eventos Volvo de manejo, "pasá el
// iButton") encolados antes de que existiera el campo `expira_en`.
//
// Cuándo correr esto:
//   - Una sola vez después del deploy del feature de TTL (2026-05-08)
//     para limpiar lo que quedó de antes.
//   - Después de tener el bot apagado por más tiempo del que cubren
//     los TTLs (raro, los bots nuevos ya borran solos al procesar).
//
// Uso (desde la carpeta whatsapp-bot/):
//   node scripts/purgar_avisos_expirados.js              # dry-run, lista
//   node scripts/purgar_avisos_expirados.js --apply       # borra
//
// Por defecto sin --apply solo lista qué se borraría sin tocar nada.
//
// Criterio de purga: estado=PENDIENTE Y origen tiempo-sensible Y
// encolado_en > 1 hora atrás (suficiente para tipos con TTL <= 2h).

require('dotenv').config();

const path = require('path');
const fs = require('fs');
const admin = require('firebase-admin');

// ─── Tipos tiempo-sensibles. Mismo conjunto que el del feature TTL. ─
const ORIGENES_TIEMPO_SENSIBLE = new Set([
  'jornada_pausa_continua', // 3h45 chofer
  'jornada_limite_diario', // 11h30 chofer
  'jornada_fin_nocturna', // 23:30 chofer
  'volvo_alert_high', // OVERSPEED, IDLING, HARSH, PTO al chofer
  'sitrack_chofer_no_identificado', // pasá el iButton
]);

// Cualquier doc PENDIENTE de ese tipo más viejo que esto se considera
// expirado. 1 hora es seguro: el TTL más largo es 2h (límite diario)
// pero esto se usa para purgar lo viejo de antes del feature, no
// para reemplazar al check del bot.
const VENTANA_HORAS = 1;

// ─── Init Firebase Admin (mismo patrón que el bot). ─
const credsPath = path.resolve(
  process.env.FIREBASE_CREDENTIALS_PATH ||
    '../serviceAccountKey.json'
);
if (!fs.existsSync(credsPath)) {
  console.error(`ERROR: no existe el service account en ${credsPath}`);
  console.error('Setear FIREBASE_CREDENTIALS_PATH en .env si está en otra ruta.');
  process.exit(1);
}
admin.initializeApp({
  credential: admin.credential.cert(require(credsPath)),
  projectId:
    process.env.FIREBASE_PROJECT_ID || 'coopertrans-movil',
});
const db = admin.firestore();

const APPLY = process.argv.includes('--apply');

async function main() {
  const cutoffMs = Date.now() - VENTANA_HORAS * 60 * 60 * 1000;
  const cutoffTs = admin.firestore.Timestamp.fromMillis(cutoffMs);

  console.log(`Modo: ${APPLY ? 'APPLY (borra)' : 'DRY-RUN (solo lista)'}`);
  console.log(`Ventana: encolado_en < ${new Date(cutoffMs).toISOString()}`);
  console.log(`Origenes target: ${[...ORIGENES_TIEMPO_SENSIBLE].join(', ')}`);
  console.log('');

  // Firestore no permite IN con > 30 valores ni filtros >= en otro
  // campo simultáneamente sin índice. Estamos en 5 valores y 1 where
  // de timestamp, va sobre índice automático. OK.
  const snap = await db
    .collection('COLA_WHATSAPP')
    .where('estado', '==', 'PENDIENTE')
    .where('origen', 'in', [...ORIGENES_TIEMPO_SENSIBLE])
    .where('encolado_en', '<', cutoffTs)
    .get();

  if (snap.empty) {
    console.log('No hay docs candidatos a purgar. Cola limpia.');
    return;
  }

  console.log(`Encontrados ${snap.size} docs candidatos:`);
  console.log('');

  // Agrupar por origen para que el reporte sea legible.
  const porOrigen = {};
  for (const doc of snap.docs) {
    const data = doc.data();
    const origen = data.origen || '(sin origen)';
    if (!porOrigen[origen]) porOrigen[origen] = [];
    porOrigen[origen].push({
      id: doc.id,
      destinatario: data.destinatario_id || '?',
      patente: data.alert_patente || '-',
      encolado_en: data.encolado_en?.toDate
        ? data.encolado_en.toDate().toISOString()
        : '?',
    });
  }

  for (const [origen, items] of Object.entries(porOrigen)) {
    console.log(`  ${origen}: ${items.length} doc(s)`);
    for (const it of items.slice(0, 5)) {
      console.log(
        `    - ${it.id} → DNI ${it.destinatario} ` +
          `patente=${it.patente} encolado=${it.encolado_en}`
      );
    }
    if (items.length > 5) {
      console.log(`    ... y ${items.length - 5} más`);
    }
  }
  console.log('');

  if (!APPLY) {
    console.log(
      'DRY-RUN: no se borró nada. Para borrar correr con --apply.'
    );
    return;
  }

  // Borrar en batches de 500 (límite de Firestore batch).
  const docs = snap.docs;
  let borrados = 0;
  for (let i = 0; i < docs.length; i += 500) {
    const slice = docs.slice(i, i + 500);
    const batch = db.batch();
    for (const d of slice) batch.delete(d.ref);
    await batch.commit();
    borrados += slice.length;
    console.log(`Borrados ${borrados}/${docs.length}...`);
  }
  console.log('');
  console.log(`OK. ${borrados} docs purgados de COLA_WHATSAPP.`);
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error('ERROR:', e.message);
    console.error(e.stack);
    process.exit(1);
  });
