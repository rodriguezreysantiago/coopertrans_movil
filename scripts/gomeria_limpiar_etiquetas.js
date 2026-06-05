// Colapsa espacios múltiples en `modelo_etiqueta` de GOMERIA_MONTAJES y
// GOMERIA_STOCK_MOVIMIENTOS. Limpia el doble espacio que dejaron los
// placeholders DEFAULT ("DEFAULT  295/80/22.5", con modelo vacío en el medio).
//
// La raíz ya está arreglada en el código (CubiertaModelo.etiquetaCorta filtra
// vacíos); esto normaliza los snapshots YA escritos en prod.
//
// DRY-RUN por default. Con --aplicar escribe.
//
//   NODE_PATH=whatsapp-bot/node_modules node scripts/gomeria_limpiar_etiquetas.js
//   NODE_PATH=whatsapp-bot/node_modules node scripts/gomeria_limpiar_etiquetas.js --aplicar

const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(
  require(path.resolve(__dirname, '..', 'serviceAccountKey.json'))
)});
const db = admin.firestore();

const APLICAR = process.argv.includes('--aplicar');

// Colapsa cualquier secuencia de espacios en blanco a uno solo + trim.
const limpiar = (s) => String(s || '').replace(/\s+/g, ' ').trim();

async function limpiarColeccion(nombre) {
  const snap = await db.collection(nombre).get();
  const cambios = [];
  for (const d of snap.docs) {
    const actual = d.data().modelo_etiqueta;
    if (typeof actual !== 'string') continue;
    const limpio = limpiar(actual);
    if (limpio !== actual) cambios.push({ ref: d.ref, de: actual, a: limpio });
  }
  console.log(`\n${nombre}: ${snap.size} docs, ${cambios.length} a limpiar`);
  cambios.slice(0, 4).forEach((c) => console.log(`  "${c.de}" -> "${c.a}"`));
  if (cambios.length > 4) console.log(`  ... y ${cambios.length - 4} más`);

  if (APLICAR && cambios.length) {
    for (let i = 0; i < cambios.length; i += 400) {
      const batch = db.batch();
      for (const c of cambios.slice(i, i + 400)) {
        batch.update(c.ref, { modelo_etiqueta: c.a });
      }
      await batch.commit();
    }
    console.log(`  OK: ${cambios.length} actualizados.`);
  }
  return cambios.length;
}

(async () => {
  console.log(`=== LIMPIAR ETIQUETAS ${APLICAR ? '(APLICAR)' : '(DRY-RUN)'} ===`);
  let total = 0;
  total += await limpiarColeccion('GOMERIA_MONTAJES');
  total += await limpiarColeccion('GOMERIA_STOCK_MOVIMIENTOS');
  console.log(`\nTotal a limpiar: ${total}`);
  if (!APLICAR) console.log('[DRY-RUN] No se escribió nada. Para aplicar: --aplicar');
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
