// Backfill: monta una cubierta DEFAULT (placeholder) en cada posición SIN
// cubierta de todas las unidades (tractores + enganches), salvo las ya
// ocupadas. NO descuenta stock (es un seeding de "ya tenían cubierta puesta").
//
// Idempotente: la posición ocupada se detecta por el LOCK
// (GOMERIA_POSICIONES_ACTIVAS, id `<patente>__<posicion>`). Re-correr no
// duplica ni pisa montajes reales.
//
// DRY-RUN por default. Con --aplicar escribe (vía Admin SDK, bypasa rules).
//
//   NODE_PATH=whatsapp-bot/node_modules node scripts/gomeria_backfill_cubiertas_default.js
//   NODE_PATH=whatsapp-bot/node_modules node scripts/gomeria_backfill_cubiertas_default.js --aplicar

const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(
  require(path.resolve(__dirname, '..', 'serviceAccountKey.json'))
)});
const db = admin.firestore();

// Mismo filtro de exclusión que usan todos los menús (tanques +
// tractores de los choferes tanqueros). Reusa el helper del bot — NO
// reimplementar (la lógica vive triplicada Dart/TS/JS a propósito).
const { cargarExcluidos, esExcluido } =
  require(path.resolve(__dirname, '..', 'whatsapp-bot', 'src', 'excluidos.js'));

const APLICAR = process.argv.includes('--aplicar');

// Modelos DEFAULT (creados por gomeria_crear_modelos_default.js).
const MODELO = {
  DIRECCION: 'AXQWKfCQb6hdTTWABIyP',
  TRACCION: 'nRf8zSFXe8wQZDhJMivz',
  ARRASTRE: 'iKt6YE4pTCRN6BSxEu4N',
};
const ET_DEFAULT = 'DEFAULT  295/80/22.5';

const ENGANCHES = ['BATEA', 'TOLVA', 'BIVUELCO', 'TANQUE', 'ACOPLADO'];

// Posiciones del TRACTOR (10): 2 dirección, 4 tracción (motriz), 4 arrastre
// (eje neumático). MISMOS códigos que lib/.../constants/posiciones.dart.
const POS_TRACTOR = [
  ['DIR_IZQ', 'DIRECCION'], ['DIR_DER', 'DIRECCION'],
  ['TRAC1_IZQ_EXT', 'TRACCION'], ['TRAC1_IZQ_INT', 'TRACCION'],
  ['TRAC1_DER_INT', 'TRACCION'], ['TRAC1_DER_EXT', 'TRACCION'],
  ['TRAC2_IZQ_EXT', 'ARRASTRE'], ['TRAC2_IZQ_INT', 'ARRASTRE'],
  ['TRAC2_DER_INT', 'ARRASTRE'], ['TRAC2_DER_EXT', 'ARRASTRE'],
];
// Posiciones del ENGANCHE (12): 3 ejes × 4 ruedas, todas arrastre.
const POS_ENGANCHE = [];
for (const eje of [1, 2, 3]) {
  for (const lado of ['IZQ_EXT', 'IZQ_INT', 'DER_INT', 'DER_EXT']) {
    POS_ENGANCHE.push([`ENG${eje}_${lado}`, 'ARRASTRE']);
  }
}

const esBaja = (x) =>
  x.ACTIVO === false || x.activo === false || x.BAJA === true ||
  String(x.estado || x.ESTADO || '').toUpperCase() === 'BAJA';

(async () => {
  console.log(`\n=== BACKFILL CUBIERTAS DEFAULT ${APLICAR ? '(APLICAR)' : '(DRY-RUN)'} ===\n`);

  // Locks existentes = posiciones ya ocupadas.
  const locks = await db.collection('GOMERIA_POSICIONES_ACTIVAS').get();
  const ocupadas = new Set(locks.docs.map((d) => d.id));
  console.log(`Posiciones ya ocupadas (locks): ${ocupadas.size}`);

  // Excluidos: tanques + tractores de los choferes tanqueros (igual que
  // todos los menús de la app).
  const excl = await cargarExcluidos(db);
  console.log(`Excluidos (tanques + tractores tanqueros): ${excl.patentes.size} patentes`);

  const veh = await db.collection('VEHICULOS').get();
  let nTractor = 0, nEnganche = 0, nBaja = 0, nExcl = 0;
  const aMontar = []; // {patente, unidadTipo, posicion, uso}

  for (const d of veh.docs) {
    const x = d.data();
    const patente = d.id;
    const tipo = String(x.TIPO || '').toUpperCase().trim();
    if (esBaja(x)) { nBaja++; continue; }
    if (esExcluido(excl, { patente })) { nExcl++; continue; } // tanque / tractor tanquero
    const esEnganche = ENGANCHES.includes(tipo);
    const esTractor = tipo === 'TRACTOR';
    if (!esEnganche && !esTractor) continue; // tipo desconocido
    if (esEnganche) nEnganche++; else nTractor++;
    const posiciones = esEnganche ? POS_ENGANCHE : POS_TRACTOR;
    const unidadTipo = esEnganche ? 'ENGANCHE' : 'TRACTOR';
    for (const [cod, uso] of posiciones) {
      if (ocupadas.has(`${patente}__${cod}`)) continue; // ya tiene cubierta
      aMontar.push({ patente, unidadTipo, posicion: cod, uso });
    }
  }

  console.log(`Unidades: ${nTractor} tractores + ${nEnganche} enganches` +
    ` (saltadas: ${nBaja} de baja, ${nExcl} tanques/tanqueros)`);
  const porUso = aMontar.reduce((a, m) => { a[m.uso] = (a[m.uso] || 0) + 1; return a; }, {});
  console.log(`\nMontajes DEFAULT a crear: ${aMontar.length}`);
  console.log(`  por tipo: ${JSON.stringify(porUso)}`);
  // muestra de las primeras
  console.log('\nEjemplos:');
  aMontar.slice(0, 6).forEach((m) =>
    console.log(`  ${m.patente} ${m.unidadTipo} ${m.posicion} -> DEFAULT ${m.uso}`));

  if (!APLICAR) {
    console.log('\n[DRY-RUN] No se escribio nada. Para aplicar: --aplicar');
    process.exit(0);
  }

  // Aplicar: lock + montaje por posición, en batches (<=500 ops -> <=250 pos).
  console.log('\nEscribiendo...');
  let creados = 0;
  for (let i = 0; i < aMontar.length; i += 240) {
    const batch = db.batch();
    for (const m of aMontar.slice(i, i + 240)) {
      const lockRef = db.collection('GOMERIA_POSICIONES_ACTIVAS')
        .doc(`${m.patente}__${m.posicion}`);
      batch.set(lockRef, {
        posicion: m.posicion,
        unidad_id: m.patente,
        desde: admin.firestore.FieldValue.serverTimestamp(),
      });
      const montRef = db.collection('GOMERIA_MONTAJES').doc();
      batch.set(montRef, {
        modelo_id: MODELO[m.uso],
        modelo_etiqueta: ET_DEFAULT,
        tipo_uso: m.uso,
        vida: 1,
        km_vida_estimada: null,
        unidad_id: m.patente,
        unidad_tipo: m.unidadTipo,
        posicion: m.posicion,
        desde: admin.firestore.FieldValue.serverTimestamp(),
        hasta: null,
        km_unidad_al_montar: null,
        km_unidad_al_retirar: null,
        km_recorridos: null,
        montado_por_dni: 'backfill',
        montado_por_nombre: 'Backfill inicial (DEFAULT)',
        retirado_por_dni: null,
        retirado_por_nombre: null,
        motivo_retiro: null,
        destino: null,
      });
    }
    await batch.commit();
    creados += Math.min(240, aMontar.length - i);
    console.log(`  ${creados}/${aMontar.length}...`);
  }
  console.log(`\nOK: ${aMontar.length} montajes DEFAULT creados (sin tocar stock).`);
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
