// Crea (idempotente) la marca "DEFAULT" + 3 modelos DEFAULT (Dirección,
// Tracción, Arrastre) como PLACEHOLDERS para el backfill de cubiertas
// preexistentes: marcan "esta posición ya tenía una cubierta sin identificar".
// El gomero las reemplaza por la cubierta real a medida que la cambia.
//
// Sin km de vida (semáforo "sin datos") + no recapable (es placeholder).
// Idempotente: si ya existen, no duplica.
//
//   NODE_PATH=whatsapp-bot/node_modules node scripts/gomeria_crear_modelos_default.js

const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(
  require(path.resolve(__dirname, '..', 'serviceAccountKey.json'))
)});
const db = admin.firestore();

(async () => {
  // 1) Marca DEFAULT (crear si no existe).
  let marcaId;
  const mq = await db.collection('CUBIERTAS_MARCAS')
    .where('nombre', '==', 'DEFAULT').limit(1).get();
  if (!mq.empty) {
    marcaId = mq.docs[0].id;
    console.log('Marca DEFAULT ya existe -> ' + marcaId);
  } else {
    const r = await db.collection('CUBIERTAS_MARCAS')
      .add({ nombre: 'DEFAULT', activo: true });
    marcaId = r.id;
    console.log('Marca DEFAULT creada -> ' + marcaId);
  }

  // 2) Un modelo DEFAULT por tipo de uso (crear si no existe).
  for (const tipo of ['DIRECCION', 'TRACCION', 'ARRASTRE']) {
    const q = await db.collection('CUBIERTAS_MODELOS')
      .where('marca_id', '==', marcaId)
      .where('tipo_uso', '==', tipo).limit(1).get();
    if (!q.empty) {
      console.log('Modelo DEFAULT ' + tipo + ' ya existe -> ' + q.docs[0].id);
      continue;
    }
    const r = await db.collection('CUBIERTAS_MODELOS').add({
      activo: true,
      marca_id: marcaId,
      marca_nombre: 'DEFAULT',
      modelo: '',
      medida: '295/80/22.5',
      tipo_uso: tipo,
      km_vida_estimada_nueva: null,   // placeholder: semáforo "sin datos"
      km_vida_estimada_recapada: null,
      recapable: false,
      presion_recomendada_psi: null,
      profundidad_banda_minima_mm: null,
    });
    console.log('Modelo DEFAULT ' + tipo + ' creado -> ' + r.id);
  }

  // 3) Verificar.
  const v = await db.collection('CUBIERTAS_MODELOS')
    .where('marca_id', '==', marcaId).get();
  console.log('\\nModelos DEFAULT en el catalogo: ' + v.size);
  v.forEach((d) => {
    const x = d.data();
    console.log('  ' + d.id + ' | ' + x.tipo_uso + ' | "' +
      (x.marca_nombre + ' ' + x.modelo + ' ' + x.medida).trim() + '"');
  });
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
