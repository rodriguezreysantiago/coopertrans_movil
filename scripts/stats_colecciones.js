// Censo de Firestore — cuenta documentos por colección RAÍZ (read-only).
//
// Para qué: dimensionar las colecciones reales de producción (cuáles
// crecen sin límite, cuáles son chicas) y alimentar decisiones de
// retención/TTL/costos. Nació en la auditoría total del 2026-06-11.
//
// USO (PowerShell, desde la raíz del repo):
//
//   node scripts/stats_colecciones.js
//
// Usa aggregate count() — cuesta 1 lectura por cada 1000 docs contados,
// no descarga documentos. Credenciales: mismo patrón multi-PC que el
// resto de scripts (_lib/firebase_creds).

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

(async () => {
  const cols = await db.listCollections();
  const filas = [];
  for (const c of cols) {
    try {
      const snap = await c.count().get();
      filas.push({ id: c.id, n: snap.data().count });
    } catch (e) {
      filas.push({ id: c.id, n: -1, err: e.message });
    }
  }
  filas.sort((a, b) => b.n - a.n);

  const ancho = Math.max(...filas.map((f) => f.id.length));
  let total = 0;
  console.log(`\nColecciones raíz: ${filas.length}\n`);
  for (const f of filas) {
    if (f.n >= 0) {
      total += f.n;
      console.log(`${f.id.padEnd(ancho)}  ${f.n.toLocaleString('es-AR')}`);
    } else {
      console.log(`${f.id.padEnd(ancho)}  ERROR: ${f.err}`);
    }
  }
  console.log(`\nTOTAL (solo raíz, sin subcolecciones): ${total.toLocaleString('es-AR')}`);
  process.exit(0);
})();
