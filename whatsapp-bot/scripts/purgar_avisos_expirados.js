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

  // Combinar where(==) + where(in) + where(<) requiere un índice
  // compuesto que no quiero crear solo para este script one-shot.
  // En su lugar: traemos todos los PENDIENTE (single-where, índice
  // automático de Firestore) y filtramos origen + encolado_en
  // client-side. Para volúmenes típicos (decenas a cientos de
  // pendientes) el costo es despreciable.
  const snap = await db
    .collection('COLA_WHATSAPP')
    .where('estado', '==', 'PENDIENTE')
    .get();

  if (snap.empty) {
    console.log('No hay PENDIENTE en COLA_WHATSAPP. Cola limpia.');
    return;
  }

  // Filtrar client-side: origen ∈ tiempo-sensibles Y encolado_en < cutoff.
  const candidatos = snap.docs.filter((d) => {
    const data = d.data();
    if (!ORIGENES_TIEMPO_SENSIBLE.has(data.origen)) return false;
    const enc = data.encolado_en;
    if (!enc || typeof enc.toMillis !== 'function') return false;
    return enc.toMillis() < cutoffMs;
  });

  if (candidatos.length === 0) {
    console.log(
      `Hay ${snap.size} PENDIENTE en total, pero ninguno calza ` +
        '(origen tiempo-sensible + más viejo que la ventana). Nada para purgar.'
    );
    return;
  }

  console.log(
    `Encontrados ${candidatos.length} candidatos ` +
      `(de ${snap.size} PENDIENTE total):`
  );
  console.log('');

  // Agrupar por origen para que el reporte sea legible.
  const porOrigen = {};
  for (const doc of candidatos) {
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
  let borrados = 0;
  for (let i = 0; i < candidatos.length; i += 500) {
    const slice = candidatos.slice(i, i + 500);
    const batch = db.batch();
    for (const d of slice) batch.delete(d.ref);
    await batch.commit();
    borrados += slice.length;
    console.log(`Borrados ${borrados}/${candidatos.length}...`);
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
