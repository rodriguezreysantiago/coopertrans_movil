// Verificación post-renombrado de un DNI de empleado.
//
// Pega los conteos de cada colección antes/después del rename para
// confirmar que la cascada de `renombrarEmpleadoDni` quedó consistente.
//
// USO (PowerShell desde la raíz del repo):
//   node scripts/verificar_renombrado_dni.js 31821422 31801915
//
// Salida esperada para un rename exitoso:
//   - EMPLEADOS/{viejo} → no existe
//   - EMPLEADOS/{nuevo} → existe + renombrado_desde = {viejo}
//   - ASIGNACIONES_VEHICULO con chofer_dni == viejo → 0
//   - ASIGNACIONES_VEHICULO con chofer_dni == nuevo → N
//   - VOLVO_ALERTAS con chofer_dni == viejo → 0
//   - VOLVO_ALERTAS con chofer_dni == nuevo → M
//   - COLA_WHATSAPP con destinatario_id == viejo → solo no-PENDIENTE
//   - COLA_WHATSAPP con destinatario_id == nuevo → K (PENDIENTE actualizados)

const path = require("path");
const fsNode = require("fs");

const botDir = path.resolve(__dirname, "..", "whatsapp-bot");
const botNodeModules = path.join(botDir, "node_modules");
if (!fsNode.existsSync(botNodeModules)) {
  console.error(
    `❌ No existe ${botNodeModules}. Corré 'npm install' en whatsapp-bot primero.`
  );
  process.exit(1);
}
module.paths.unshift(botNodeModules);
process.chdir(botDir);
require("dotenv").config({ quiet: true });

const admin = require("firebase-admin");

const credPath =
  process.env.FIREBASE_CREDENTIALS_PATH || "../serviceAccountKey.json";
const absPath = path.resolve(credPath);
if (!fsNode.existsSync(absPath)) {
  console.error(`❌ Credenciales Firebase no encontradas: ${absPath}`);
  process.exit(1);
}

admin.initializeApp({
  credential: admin.credential.cert(require(absPath)),
  projectId: process.env.FIREBASE_PROJECT_ID || "coopertrans-movil",
});

const db = admin.firestore();

// CLI parsing
const dniViejo = (process.argv[2] || "").trim();
const dniNuevo = (process.argv[3] || "").trim();
if (!dniViejo || !dniNuevo) {
  console.error("Uso: node verificar_renombrado_dni.js <dniViejo> <dniNuevo>");
  process.exit(1);
}

function bullet(label, ok, detalle) {
  const icono = ok ? "✅" : "❌";
  console.log(`  ${icono} ${label}${detalle ? `: ${detalle}` : ""}`);
}

async function chequearEmpleados() {
  console.log("\n=== EMPLEADOS ===");
  const [snapViejo, snapNuevo] = await Promise.all([
    db.collection("EMPLEADOS").doc(dniViejo).get(),
    db.collection("EMPLEADOS").doc(dniNuevo).get(),
  ]);

  bullet(`EMPLEADOS/${dniViejo} no existe`, !snapViejo.exists,
    snapViejo.exists ? "TODAVÍA EXISTE — el rename no completó" : "borrado OK");

  if (snapNuevo.exists) {
    const data = snapNuevo.data() || {};
    const desde = data.renombrado_desde;
    const tieneTraza = desde === dniViejo;
    bullet(`EMPLEADOS/${dniNuevo} existe`, true);
    bullet(`renombrado_desde === "${dniViejo}"`, tieneTraza,
      `valor actual: "${desde}"`);
    if (data.NOMBRE) {
      console.log(`     NOMBRE: ${data.NOMBRE}`);
    }
    if (data.renombrado_en) {
      console.log(`     renombrado_en: ${data.renombrado_en.toDate().toISOString()}`);
    }
    if (data.renombrado_por) {
      console.log(`     renombrado_por: ${data.renombrado_por}`);
    }
  } else {
    bullet(`EMPLEADOS/${dniNuevo} existe`, false, "NO EXISTE — el rename falló");
  }
}

async function chequearAsignaciones() {
  console.log("\n=== ASIGNACIONES_VEHICULO ===");
  const [conViejo, conNuevo] = await Promise.all([
    db.collection("ASIGNACIONES_VEHICULO").where("chofer_dni", "==", dniViejo).get(),
    db.collection("ASIGNACIONES_VEHICULO").where("chofer_dni", "==", dniNuevo).get(),
  ]);
  bullet(`Con chofer_dni == ${dniViejo}`, conViejo.size === 0,
    `${conViejo.size} doc(s)${conViejo.size > 0 ? " — quedaron sin migrar" : ""}`);
  bullet(`Con chofer_dni == ${dniNuevo}`, conNuevo.size >= 0,
    `${conNuevo.size} doc(s)`);
  if (conNuevo.size > 0) {
    conNuevo.docs.slice(0, 5).forEach(d => {
      const x = d.data();
      const desde = x.desde?.toDate?.()?.toISOString?.() || "?";
      const hasta = x.hasta?.toDate?.()?.toISOString?.() || "ACTIVA";
      console.log(`     · ${d.id} → ${x.vehiculo_id} | ${desde} → ${hasta}`);
    });
    if (conNuevo.size > 5) console.log(`     · (... ${conNuevo.size - 5} más)`);
  }
}

async function chequearVolvoAlertas() {
  console.log("\n=== VOLVO_ALERTAS ===");
  const [conViejo, conNuevo] = await Promise.all([
    db.collection("VOLVO_ALERTAS").where("chofer_dni", "==", dniViejo).get(),
    db.collection("VOLVO_ALERTAS").where("chofer_dni", "==", dniNuevo).get(),
  ]);
  bullet(`Con chofer_dni == ${dniViejo}`, conViejo.size === 0,
    `${conViejo.size} doc(s)${conViejo.size > 0 ? " — quedaron sin migrar" : ""}`);
  bullet(`Con chofer_dni == ${dniNuevo}`, conNuevo.size >= 0,
    `${conNuevo.size} doc(s)`);
}

async function chequearColaWhatsapp() {
  console.log("\n=== COLA_WHATSAPP ===");
  // Solo PENDIENTES se migran. Los enviados quedan con el DNI viejo
  // (ya viajaron así) y no es problema.
  const [pendientesViejo, todoViejo, pendientesNuevo] = await Promise.all([
    db.collection("COLA_WHATSAPP")
      .where("destinatario_id", "==", dniViejo)
      .where("estado", "==", "PENDIENTE").get(),
    db.collection("COLA_WHATSAPP")
      .where("destinatario_id", "==", dniViejo).get(),
    db.collection("COLA_WHATSAPP")
      .where("destinatario_id", "==", dniNuevo)
      .where("estado", "==", "PENDIENTE").get(),
  ]);
  bullet(`PENDIENTE con destinatario_id == ${dniViejo}`,
    pendientesViejo.size === 0,
    `${pendientesViejo.size} doc(s)${pendientesViejo.size > 0 ? " — debían migrar" : ""}`);
  console.log(`     Total docs (cualquier estado) con destinatario_id == ${dniViejo}: ${todoViejo.size} (no-PENDIENTE = histórico OK)`);
  bullet(`PENDIENTE con destinatario_id == ${dniNuevo}`,
    pendientesNuevo.size >= 0,
    `${pendientesNuevo.size} doc(s)`);
}

async function main() {
  console.log(`\nVerificando rename: ${dniViejo} → ${dniNuevo}`);
  console.log("============================================");
  await chequearEmpleados();
  await chequearAsignaciones();
  await chequearVolvoAlertas();
  await chequearColaWhatsapp();
  console.log("\nListo.");
}

main()
  .then(() => process.exit(0))
  .catch(err => { console.error("\n❌ Error:", err); process.exit(1); });
