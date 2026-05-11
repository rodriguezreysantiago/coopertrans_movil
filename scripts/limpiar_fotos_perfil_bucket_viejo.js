// Limpia el campo ARCHIVO_PERFIL de los empleados cuya URL apunta al
// bucket viejo (`logisticaapp-e539a`) — ese bucket ya no existe y las
// URLs devuelven 404, dejando el avatar gris en la planilla de
// personal.
//
// Al limpiar (setear ARCHIVO_PERFIL = '-' o borrar el campo) el
// FotoPerfilAvatar cae al ícono placeholder en lugar de intentar
// cargar una URL muerta. Bonus: ahorramos N requests fallidos cada
// vez que se abre la pantalla.
//
// Uso:
//   node scripts/limpiar_fotos_perfil_bucket_viejo.js          # dry-run (lista)
//   node scripts/limpiar_fotos_perfil_bucket_viejo.js --apply  # aplica los cambios

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

const BUCKET_VIEJO = "logisticaapp-e539a";
const apply = process.argv.includes("--apply");

(async () => {
  console.log(
    `\n=== Buscando empleados con ARCHIVO_PERFIL del bucket "${BUCKET_VIEJO}" ===\n`
  );

  const snap = await db.collection("EMPLEADOS").get();
  const candidatos = [];
  for (const doc of snap.docs) {
    const url = (doc.data().ARCHIVO_PERFIL ?? "").toString();
    if (url && url.includes(BUCKET_VIEJO)) {
      candidatos.push({
        dni: doc.id,
        nombre: doc.data().NOMBRE ?? "(sin nombre)",
        url,
      });
    }
  }

  console.log(`Encontrados: ${candidatos.length} empleado(s)\n`);
  for (const c of candidatos) {
    console.log(`  ${c.dni}  ·  ${c.nombre}`);
  }

  if (!apply) {
    console.log(`\nDRY-RUN — ningún cambio aplicado.`);
    console.log(`Para aplicar: node ${process.argv[1]} --apply\n`);
    process.exit(0);
  }

  if (candidatos.length === 0) {
    console.log(`\nNada que limpiar.`);
    process.exit(0);
  }

  console.log(`\n=== Aplicando: setear ARCHIVO_PERFIL = '-' ===\n`);
  let i = 0;
  // Batch de a 500 (límite Firestore).
  for (let off = 0; off < candidatos.length; off += 500) {
    const batch = db.batch();
    for (const c of candidatos.slice(off, off + 500)) {
      batch.update(db.collection("EMPLEADOS").doc(c.dni), {
        ARCHIVO_PERFIL: "-",
        fecha_ultima_actualizacion: admin.firestore.FieldValue.serverTimestamp(),
      });
      i++;
    }
    await batch.commit();
    console.log(`  batch commiteado: ${i}/${candidatos.length}`);
  }

  console.log(`\n✅ Listo. ${i} empleados limpiados.`);
  console.log(
    `\nPróximo paso: pedile a esos choferes que entren a "Mi Perfil" en\n` +
      `la app y suban su foto de nuevo. Las nuevas se guardan en el bucket\n` +
      `actual (coopertrans-movil) y se ven correctamente.\n`
  );
  process.exit(0);
})().catch((e) => {
  console.error("error:", e);
  process.exit(1);
});
