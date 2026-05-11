// Cuantifica cuántos empleados tienen URLs de perfil del bucket viejo vs nuevo.

const path = require("path");
const botDir = path.resolve(__dirname, "..", "whatsapp-bot");
module.paths.unshift(path.join(botDir, "node_modules"));
process.chdir(botDir);
require("dotenv").config({ quiet: true });

const admin = require("firebase-admin");
const credPath = path.resolve(process.env.FIREBASE_CREDENTIALS_PATH || "../serviceAccountKey.json");
admin.initializeApp({
  credential: admin.credential.cert(require(credPath)),
  projectId: "coopertrans-movil",
});

const db = admin.firestore();

const BUCKET_VIEJO = "logisticaapp-e539a.firebasestorage.app";
const BUCKET_NUEVO = "coopertrans-movil.firebasestorage.app";

(async () => {
  console.log("Escaneando EMPLEADOS por URLs de perfil...\n");

  const snap = await db.collection("EMPLEADOS").get();
  let conBucketViejo = 0;
  let conBucketNuevo = 0;
  let sinUrl = 0;

  const ejemploViejo = [];
  const ejemploNuevo = [];

  for (const doc of snap.docs) {
    const data = doc.data();
    const dni = doc.id;
    const url = (data.ARCHIVO_PERFIL || "").toString().trim();

    if (!url || url === "-") {
      sinUrl++;
    } else if (url.includes(BUCKET_VIEJO)) {
      conBucketViejo++;
      if (ejemploViejo.length < 3) ejemploViejo.push({ dni, url: url.substring(0, 80) + "..." });
    } else if (url.includes(BUCKET_NUEVO)) {
      conBucketNuevo++;
      if (ejemploNuevo.length < 3) ejemploNuevo.push({ dni, url: url.substring(0, 80) + "..." });
    }
  }

  const total = snap.size;
  console.log(`Total empleados: ${total}`);
  console.log(`  - Sin ARCHIVO_PERFIL: ${sinUrl}`);
  console.log(`  - Con bucket VIEJO (logisticaapp-e539a): ${conBucketViejo}`);
  console.log(`  - Con bucket NUEVO (coopertrans-movil): ${conBucketNuevo}`);

  if (ejemploViejo.length > 0) {
    console.log(`\nEjemplos - bucket viejo:`);
    ejemploViejo.forEach(({ dni, url }) => console.log(`  DNI ${dni}: ${url}`));
  }

  if (ejemploNuevo.length > 0) {
    console.log(`\nEjemplos - bucket nuevo:`);
    ejemploNuevo.forEach(({ dni, url }) => console.log(`  DNI ${dni}: ${url}`));
  }

  await admin.app().delete();
  process.exit(0);
})().catch(e => {
  console.error("Error:", e);
  process.exit(1);
});
