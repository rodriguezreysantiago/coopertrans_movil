// =====================================================================
// DEPRECATED 2026-05-16 — apunta a JORNADAS_CHOFER (colección legacy).
// =====================================================================
// La colección `JORNADAS_CHOFER` fue migrada a `JORNADAS` (modelo v2
// con bloques 3x4h) el 2026-05-15. Este script ya NO sirve: o no
// encuentra docs (porque la colección vieja está vacía) o reporta
// "todo OK" mientras el v2 sí tiene problemas, llevando a
// conclusiones erróneas.
//
// Para auditar el modelo nuevo, hay que armar un script que lea de
// JORNADAS con el shape v2 (bloques + km + descanso).
console.error(
  "ERROR: este script apunta a JORNADAS_CHOFER (legacy). " +
    "Borrado del flujo operativo. Ver comentario al principio del archivo."
);
process.exit(1);

// Audita todas las JORNADAS_CHOFER de un día (default: hoy en TZ
// Argentina) y muestra cuáles parecen sospechosas — total_dia
// desproporcionado para la hora actual.
//
// Modo --apply: borra los docs sospechosos en bulk. El cron del
// próximo ciclo los recrea con total=0 y empieza a sumar correctamente.
//
// Uso (desde la raíz del repo):
//   node scripts/auditar_jornadas_dia.js                # solo lista, no toca
//   node scripts/auditar_jornadas_dia.js --apply        # borra los sospechosos
//   node scripts/auditar_jornadas_dia.js --umbral=6     # ajusta el umbral
//                                                        de "sospechoso" en
//                                                        horas (default 6)
//
// Criterio "sospechoso" por default: total_dia > umbral horas Y la
// hora actual ART es < (umbral + 2) horas. O sea, si son las 12:00
// y un chofer tiene > 6h de manejo total, es sospechoso (no llegó a
// manejar 6h reales tan temprano).
//
// Ajustá el umbral según la hora del día y el riesgo:
//   - A las 10:00 ART → umbral 4 (poca actividad esperable)
//   - A las 14:00 ART → umbral 7
//   - A las 18:00 ART → umbral 10
//   - A las 20:00 ART → umbral 12 (cualquiera puede haber ya hecho jornada)
//
// El script imprime el listado con detalle. Verificá visualmente
// antes de --apply.

const path = require("path");
const fs = require("fs");

// firebase-admin desde whatsapp-bot/node_modules.
let admin;
try {
  admin = require(path.join(__dirname, "..", "whatsapp-bot", "node_modules", "firebase-admin"));
} catch (_) {
  try {
    admin = require("firebase-admin");
  } catch (_) {
    console.error("No encuentro firebase-admin.");
    process.exit(1);
  }
}

// ─── Args ─────────────────────────────────────────────────────────
const apply = process.argv.includes("--apply");
const umbralArg = process.argv.find((a) => a.startsWith("--umbral="));
const UMBRAL_HORAS = umbralArg
  ? parseFloat(umbralArg.split("=")[1])
  : 6;
const UMBRAL_SEGUNDOS = UMBRAL_HORAS * 3600;

// ─── Init ─────────────────────────────────────────────────────────
const credsPath = path.resolve(
  path.join(__dirname, "..", "serviceAccountKey.json")
);
if (!fs.existsSync(credsPath)) {
  console.error(`No encuentro service account en ${credsPath}`);
  process.exit(1);
}
admin.initializeApp({
  credential: admin.credential.cert(require(credsPath)),
  projectId: "coopertrans-movil",
});
const db = admin.firestore();

// ─── Main ─────────────────────────────────────────────────────────
async function main() {
  const fechaArt = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());

  const horaArt = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Argentina/Buenos_Aires",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date());

  console.log(`Modo: ${apply ? "APPLY (borra)" : "DRY-RUN (solo lista)"}`);
  console.log(`Fecha (ART): ${fechaArt}`);
  console.log(`Hora ahora:  ${horaArt} ART`);
  console.log(`Umbral sospechoso: total_dia > ${UMBRAL_HORAS}h`);
  console.log("");

  const snap = await db
    .collection("JORNADAS_CHOFER")
    .where("fecha_art", "==", fechaArt)
    .get();

  if (snap.empty) {
    console.log("No hay JORNADAS_CHOFER del día.");
    return;
  }

  // Cargar nombres de empleados para mostrar legible.
  const empSnap = await db.collection("EMPLEADOS").get();
  const nombrePorDni = {};
  for (const d of empSnap.docs) {
    nombrePorDni[d.id] = (d.data().NOMBRE || "?").toString();
  }

  const sospechosos = [];
  const ok = [];

  for (const doc of snap.docs) {
    const d = doc.data();
    const dni = (d.chofer_dni || "?").toString();
    const total = d.segundos_total_dia || 0;
    const continuo = d.segundos_continuo_actual || 0;
    const alerta3 = d.alerta_3_45_continua_enviada === true;
    const alerta11 = d.alerta_11_30_diaria_enviada === true;
    const nombre = nombrePorDni[dni] || "(sin nombre)";

    const linea = {
      docId: doc.id,
      dni,
      nombre,
      totalH: (total / 3600).toFixed(2),
      continuoH: (continuo / 3600).toFixed(2),
      alerta3,
      alerta11,
      total,
    };

    if (total > UMBRAL_SEGUNDOS) {
      sospechosos.push(linea);
    } else {
      ok.push(linea);
    }
  }

  console.log(`Total docs del día: ${snap.size}`);
  console.log(`  ✅ OK (total ≤ ${UMBRAL_HORAS}h):  ${ok.length}`);
  console.log(`  ⚠️ Sospechosos (total > ${UMBRAL_HORAS}h): ${sospechosos.length}`);
  console.log("");

  if (sospechosos.length > 0) {
    console.log("⚠️ Choferes con jornada sospechosa:");
    sospechosos.sort((a, b) => b.total - a.total);
    for (const s of sospechosos) {
      const flags = [
        s.alerta3 ? "alerta3h45✓" : "",
        s.alerta11 ? "alerta11h30✓" : "",
      ].filter(Boolean).join(" ");
      console.log(
        `  DNI ${s.dni} (${s.nombre}) — total: ${s.totalH}h, continuo: ${s.continuoH}h ${flags}`
      );
    }
    console.log("");
  }

  if (ok.length > 0 && !apply) {
    console.log("✅ Choferes OK (no se tocan):");
    for (const o of ok) {
      const flags = [
        o.alerta3 ? "alerta3h45✓" : "",
        o.alerta11 ? "alerta11h30✓" : "",
      ].filter(Boolean).join(" ");
      console.log(
        `  DNI ${o.dni} (${o.nombre}) — total: ${o.totalH}h, continuo: ${o.continuoH}h ${flags}`
      );
    }
    console.log("");
  }

  if (sospechosos.length === 0) {
    console.log("Nada para borrar. Cola limpia.");
    return;
  }

  if (!apply) {
    console.log(
      "DRY-RUN: no se borró nada. Para borrar los sospechosos: " +
        "corré con --apply."
    );
    console.log(
      "Ojo: los choferes que realmente sí manejaron > umbral horas " +
        "se borrarían también. Verificá la lista de sospechosos antes."
    );
    return;
  }

  // --apply: borrar en batches de 500.
  console.log(`🚀 Borrando ${sospechosos.length} doc(s)...`);
  for (let i = 0; i < sospechosos.length; i += 500) {
    const slice = sospechosos.slice(i, i + 500);
    const batch = db.batch();
    for (const s of slice) {
      batch.delete(db.collection("JORNADAS_CHOFER").doc(s.docId));
    }
    await batch.commit();
    console.log(`  Borrados ${Math.min(i + 500, sospechosos.length)}/${sospechosos.length}`);
  }
  console.log("");
  console.log(
    "✅ Listo. El próximo ciclo del cron (5 min) recrea los docs " +
      "con total=0 y empieza a sumar bien con el fix deployado."
  );
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error("ERROR:", e.message);
    process.exit(1);
  });
