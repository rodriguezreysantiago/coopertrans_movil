// Exporta todos los empleados con teléfono de Firestore a un archivo .vcf
// listo para importar en iPhone (iOS Contactos).
//
// Uso:
//   node scripts/exportar_contactos_vcf.js [archivo_salida.vcf]
//
// Por defecto guarda en: scripts/contactos.vcf

const path = require("path");
const fs = require("fs");

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

function limpiarTelefono(raw) {
  if (!raw) return null;
  // Elimina caracteres que no son dígitos ni el + inicial
  const s = raw.toString().replace(/[^\d+]/g, "");
  return s.length >= 6 ? s : null;
}

function escaparVcard(str) {
  // Escapa comas, punto y coma y saltos de línea según RFC 6350
  return str.replace(/\\/g, "\\\\").replace(/,/g, "\\,").replace(/;/g, "\\;").replace(/\n/g, "\\n");
}

(async () => {
  const outputPath = path.resolve(
    __dirname,
    process.argv[2] || "contactos.vcf"
  );

  console.log("Leyendo colección EMPLEADOS...");
  const snap = await db.collection("EMPLEADOS").get();

  const vcards = [];
  let sinTelefono = 0;

  for (const doc of snap.docs) {
    const d = doc.data();
    const nombreRaw = (d.NOMBRE || "").toString().trim();
    const telefonoRaw = d.TELEFONO?.toString() || "";
    const mailRaw = (d.MAIL || "").toString().trim();

    const telefono = limpiarTelefono(telefonoRaw);

    if (!telefono) {
      sinTelefono++;
      continue;
    }

    if (!nombreRaw) continue;

    // Separar apellido y nombre: el formato es "APELLIDO NOMBRE"
    // El primer token se toma como apellido, el resto como nombre.
    const partes = nombreRaw.split(/\s+/);
    const apellido = escaparVcard(partes[0] || "");
    const nombre = escaparVcard(partes.slice(1).join(" ") || "");
    const nombreCompleto = escaparVcard(nombreRaw);

    let vcard = `BEGIN:VCARD\r\nVERSION:3.0\r\n`;
    vcard += `N:${apellido};${nombre};;;\r\n`;
    vcard += `FN:${nombreCompleto}\r\n`;
    vcard += `TEL;TYPE=CELL:${telefono}\r\n`;
    if (mailRaw && mailRaw !== "—") {
      vcard += `EMAIL:${escaparVcard(mailRaw)}\r\n`;
    }
    vcard += `END:VCARD\r\n`;

    vcards.push(vcard);
  }

  fs.writeFileSync(outputPath, vcards.join("\r\n"), "utf8");

  console.log(`\n✓ ${vcards.length} contactos exportados → ${outputPath}`);
  console.log(`  (${sinTelefono} empleados sin teléfono omitidos)`);
  console.log("\nPara importar en iPhone:");
  console.log("  1. Enviate el archivo .vcf por mail o AirDrop");
  console.log("  2. Abrilo desde el iPhone → toca 'Agregar todos los contactos'");

  process.exit(0);
})();
