// Itera sobre los 57 tractores VEHICULOS y para cada VIN llama al
// endpoint nuevo (que NO acepta query masiva — devuelve 503), 1-por-1.
// Reporta cobertura REAL de uptimeData / serviceDistance / tellTaleInfo
// + nuevos campos.

const path = require("path");
const fsNode = require("fs");

const botDir = path.resolve(__dirname, "..", "whatsapp-bot");
const botNodeModules = path.join(botDir, "node_modules");
module.paths.unshift(botNodeModules);
process.chdir(botDir);
require("dotenv").config({ quiet: true });

const username = process.env.VOLVO_USERNAME;
const password = process.env.VOLVO_PASSWORD;
if (!username || !password) {
  console.error("Faltan VOLVO_USERNAME / VOLVO_PASSWORD en env.");
  process.exit(1);
}

process.env.GOOGLE_APPLICATION_CREDENTIALS = path.resolve(
  __dirname, "..", "serviceAccountKey.json"
);
const admin = require("firebase-admin");
admin.initializeApp();
const db = admin.firestore();

const VOLVO_BASE = "https://api.volvotrucks.com";
const ACCEPT = "application/x.volvogroup.com.vehiclestatuses.v1.0+json; UTF-8";
const auth = "Basic " + Buffer.from(`${username}:${password}`).toString("base64");

const hasta = new Date();
const desde = new Date(hasta.getTime() - 24 * 60 * 60 * 1000); // 1 día
const stripMs = (d) => d.toISOString().replace(/\.\d{3}Z$/, "Z");

(async () => {
  const snap = await db.collection("VEHICULOS")
    .where("TIPO", "==", "TRACTOR").get();
  const tractores = snap.docs
    .map((d) => ({ patente: d.id, vin: (d.data().VIN || "").trim().toUpperCase() }))
    .filter((t) => t.vin && t.vin !== "-");
  console.log(`Tractores con VIN: ${tractores.length}/${snap.size}\n`);

  const resumen = {
    totalVins: tractores.length,
    httpOk: 0,
    http503: 0,
    httpOtro: 0,
    sinRecords: 0,
    conUptime: 0,
    conServiceDistanceRazonable: 0,  // < 200.000 km al service
    conServiceDistanceAbsurdo: 0,   // > 1.000.000 km (centinela)
    conTellTales: 0,
    conBrakePressure: 0,
  };
  const valoresSD = [];
  const camposExtraVistos = new Set();

  for (const t of tractores) {
    const qs = new URLSearchParams({
      vin: t.vin,
      datetype: "created",
      starttime: stripMs(desde),
      stoptime: stripMs(hasta),
      contentFilter: "UPTIME",
      latestOnly: "false",
    });
    const url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;
    try {
      const r = await fetch(url, {
        headers: { Authorization: auth, Accept: ACCEPT },
      });
      if (r.status === 503) { resumen.http503++; continue; }
      if (!r.ok) { resumen.httpOtro++; continue; }
      resumen.httpOk++;
      const j = await r.json();
      const arr = j.vehicleStatusResponse?.vehicleStatuses || [];
      if (arr.length === 0) { resumen.sinRecords++; continue; }

      let tieneUp = false, tieneSD = false, tieneTT = false, tieneBrake = false;
      let mejorSD = null;  // el más nuevo
      for (const rec of arr) {
        const up = rec.uptimeData;
        if (!up) continue;
        tieneUp = true;
        for (const k of Object.keys(up)) camposExtraVistos.add(k);
        if (up.serviceDistance != null) {
          mejorSD = up.serviceDistance;
        }
        if (Array.isArray(up.tellTaleInfo) && up.tellTaleInfo.length > 0) tieneTT = true;
        if (up.serviceBrakeAirPressureCircuit1 != null) tieneBrake = true;
      }
      if (tieneUp) resumen.conUptime++;
      if (tieneTT) resumen.conTellTales++;
      if (tieneBrake) resumen.conBrakePressure++;
      if (mejorSD != null) {
        const km = mejorSD / 1000;
        valoresSD.push({ patente: t.patente, km });
        if (km < 200000) resumen.conServiceDistanceRazonable++;
        else resumen.conServiceDistanceAbsurdo++;
      }
    } catch (e) {
      resumen.httpOtro++;
    }
    // Throttle suave para no martillar Volvo
    await new Promise((r) => setTimeout(r, 200));
  }

  console.log("============== RESUMEN ==============");
  console.log("Total VINs procesados:           ", resumen.totalVins);
  console.log("HTTP 200:                        ", resumen.httpOk);
  console.log("HTTP 503:                        ", resumen.http503);
  console.log("HTTP otro error:                 ", resumen.httpOtro);
  console.log("Sin records en 24h:              ", resumen.sinRecords);
  console.log("Con uptimeData:                  ", resumen.conUptime);
  console.log("Con serviceDistance RAZONABLE:   ", resumen.conServiceDistanceRazonable, "(< 200k km)");
  console.log("Con serviceDistance ABSURDO:     ", resumen.conServiceDistanceAbsurdo, "(> 200k km, centinela?)");
  console.log("Con tellTaleInfo:                ", resumen.conTellTales);
  console.log("Con serviceBrakeAirPressure:     ", resumen.conBrakePressure);

  console.log("\nCampos vistos dentro de uptimeData:");
  for (const k of [...camposExtraVistos].sort()) console.log("  -", k);

  console.log("\nValores serviceDistance (km al service):");
  valoresSD.sort((a, b) => a.km - b.km);
  for (const v of valoresSD.slice(0, 5))      console.log("  MENORES:", v.patente, v.km.toFixed(0), "km");
  for (const v of valoresSD.slice(-5))         console.log("  MAYORES:", v.patente, v.km.toFixed(0), "km");
  process.exit(0);
})().catch((e) => { console.error("\nERROR:", e.message); process.exit(1); });
