// Prueba el endpoint que Volvo Connect Argentina sugirio en el mail del
// 2026-05-28 para activar el bloque UPTIME (que hoy traemos solo en 18/57
// tractores con `latestOnly=true`).
//
// Que prueba:
//   GET .../vehicle/vehiclestatuses
//       ?datetype=created
//       &starttime=<hace 7 dias>
//       &stoptime=<ahora>
//       &contentFilter=UPTIME
//       &additionalContent=VOLVOGROUPSNAPSHOT,VOLVOGROUPACCUMULATED
//       &triggerFilter=TIMER,TELL_TALE,DRIVER_LOGIN,IGNITION_ON,...
//       &latestOnly=false
//
// Que reporta:
//   - Cantidad total de records que llegaron
//   - Cantidad de VINs unicos
//   - Cantidad de VINs con uptimeData.serviceDistance poblado
//   - Cantidad de VINs con uptimeData.tellTaleInfo no vacio
//   - Cantidad de VINs con volvoGroupAccumulated (campos disponibles)
//   - Para los primeros 3 VINs: shape completo de los bloques nuevos
//   - Lista de triggerType vistos en la respuesta (lo que realmente
//     dispara reportes con UPTIME)
//
// USO (PowerShell, desde el root del repo):
//   cd whatsapp-bot
//   $cred = Get-Credential -Message "Volvo API" -UserName "018B1E992E"
//   $env:VOLVO_USERNAME = $cred.UserName
//   $env:VOLVO_PASSWORD = $cred.GetNetworkCredential().Password
//   node ../scripts/probar_volvo_uptime_endpoint.js
//   node ../scripts/probar_volvo_uptime_endpoint.js --days 3   # rango custom
//   Remove-Item Env:VOLVO_USERNAME, Env:VOLVO_PASSWORD

const path = require("path");
const fsNode = require("fs");

const botDir = path.resolve(__dirname, "..", "whatsapp-bot");
const botNodeModules = path.join(botDir, "node_modules");
if (!fsNode.existsSync(botNodeModules)) {
  console.error(`Falta ${botNodeModules}. Corre 'npm install' en whatsapp-bot.`);
  process.exit(1);
}
module.paths.unshift(botNodeModules);
process.chdir(botDir);
require("dotenv").config({ quiet: true });

const username = process.env.VOLVO_USERNAME;
const password = process.env.VOLVO_PASSWORD;
if (!username || !password) {
  console.error("Faltan VOLVO_USERNAME / VOLVO_PASSWORD en el env.");
  process.exit(1);
}

const VOLVO_BASE = "https://api.volvotrucks.com";
const ACCEPT_STATUSES =
  "application/x.volvogroup.com.vehiclestatuses.v1.0+json; UTF-8";
const authHeader =
  "Basic " + Buffer.from(`${username}:${password}`).toString("base64");

// --- Args ---
function getDays() {
  const i = process.argv.indexOf("--days");
  if (i === -1) return 7;
  const n = parseInt(process.argv[i + 1], 10);
  if (Number.isNaN(n) || n < 1 || n > 30) {
    console.error("--days debe ser 1..30");
    process.exit(1);
  }
  return n;
}
const dias = getDays();

// --- Rango temporal ---
const hasta = new Date();
const desde = new Date(hasta.getTime() - dias * 24 * 60 * 60 * 1000);
const stripMs = (d) => d.toISOString().replace(/\.\d{3}Z$/, "Z");

// --- Triggers (los 40+ que mando Volvo en el mail) ---
const triggers = [
  "TIMER", "TELL_TALE", "DRIVER_LOGIN", "DRIVER_LOGOUT",
  "IGNITION_ON", "IGNITION_OFF", "ENGINE_ON", "ENGINE_OFF",
  "PTO_ENABLED", "PTO_DISABLED", "DISTANCE_TRAVELLED",
  "DRIVER_1_WORKING_STATE_CHANGED", "DRIVER_2_WORKING_STATE_CHANGED",
  "GEOFENCE", "DTJ_ACTIVITY", "CARGO_DOOR", "CARGO_DEFROST",
  "DRIVING_WITHOUT_BEING_LOGGEDIN", "FUELLEVEL_CHANGED_WHILE_OFF",
  "ADBLUELEVEL_CHANGED_WHILE_OFF", "DTM", "STATUS_ON_DEMAND",
  "COLLISION_MITIGATION", "FLEET_OVERSPEED", "TACHO_OUT_OF_SCOPE_MODE",
  "IDLING", "TIRE_WARNING", "MOVEMENT", "NO_MOVEMENT",
  "TEMPERATURE_ALARM", "ADBLUELEVEL_LOW", "WITHOUT_ADBLUE",
  "BATTERY_PACK_HIGH_DISCHARGE", "BATTERY_PACK_ENERGY_USAGE",
  "BATTERY_PACK_CHARGING_STATUS_CHANGE",
  "BATTERY_PACK_CHARGING_CONNECTION_STATUS_CHANGE",
  "VEHICLE_COUPLER_UNLOCK_ALLOWED", "CLIMATE_STATUS",
  "BATTERY_PRECONDITIONING", "VEHICLE_MODE",
];

const qs = new URLSearchParams({
  datetype: "created",
  starttime: stripMs(desde),
  stoptime: stripMs(hasta),
  contentFilter: "UPTIME",
  additionalContent: "VOLVOGROUPSNAPSHOT,VOLVOGROUPACCUMULATED",
  triggerFilter: triggers.join(","),
  latestOnly: "false",
});

const url = `${VOLVO_BASE}/vehicle/vehiclestatuses?${qs.toString()}`;
console.log(`\n[probar] Llamando endpoint con rango ${dias} dia(s):`);
console.log(`  desde: ${stripMs(desde)}`);
console.log(`  hasta: ${stripMs(hasta)}`);
console.log(`  URL: ${url.substring(0, 100)}...\n`);

// --- Pagination helper: Volvo paginates con Link header ---
async function fetchAll(initialUrl) {
  const all = [];
  let url = initialUrl;
  let page = 0;
  while (url) {
    page++;
    process.stdout.write(`  pagina ${page}... `);
    const r = await fetch(url, {
      headers: { Authorization: authHeader, Accept: ACCEPT_STATUSES },
    });
    if (!r.ok) {
      const body = await r.text();
      console.error(`\nHTTP ${r.status}: ${body.substring(0, 500)}`);
      process.exit(1);
    }
    const json = await r.json();
    const arr = json.vehicleStatusResponse?.vehicleStatuses || [];
    all.push(...arr);
    process.stdout.write(`+${arr.length} records (total ${all.length})\n`);
    // Link header con rel=next
    const link = r.headers.get("link") || r.headers.get("Link") || "";
    const m = link.match(/<([^>]+)>;\s*rel="?next"?/i);
    url = m ? (m[1].startsWith("http") ? m[1] : `${VOLVO_BASE}${m[1]}`) : null;
    if (page >= 20) {
      console.log("  (cortando a 20 paginas para no abusar del API)");
      break;
    }
  }
  return all;
}

(async () => {
  const records = await fetchAll(url);
  console.log(`\n[probar] TOTAL records recibidos: ${records.length}\n`);

  // Agrupar por VIN
  const porVin = new Map();
  const triggersVistos = new Map();
  for (const r of records) {
    const vin = r.vin || "(sin vin)";
    if (!porVin.has(vin)) porVin.set(vin, []);
    porVin.get(vin).push(r);
    const tg = r.triggerType || r.type || "(sin trigger)";
    triggersVistos.set(tg, (triggersVistos.get(tg) || 0) + 1);
  }

  // Stats
  let vinsConServiceDistance = 0;
  let vinsConTellTales = 0;
  let vinsConAccumulated = 0;
  let vinsConSnapshot = 0;
  const camposAccumulated = new Map();

  for (const [vin, recs] of porVin) {
    let tieneSD = false, tieneTT = false, tieneAcc = false, tieneSnap = false;
    for (const r of recs) {
      const uptime = r.uptimeData;
      if (uptime?.serviceDistance != null) tieneSD = true;
      const tts = uptime?.tellTaleInfo;
      if (Array.isArray(tts) && tts.length > 0) tieneTT = true;
      const acc = r.snapshotData?.volvoGroupAccumulated;
      if (acc) {
        tieneAcc = true;
        for (const k of Object.keys(acc)) {
          camposAccumulated.set(k, (camposAccumulated.get(k) || 0) + 1);
        }
      }
      if (r.snapshotData?.volvoGroupSnapshot) tieneSnap = true;
    }
    if (tieneSD) vinsConServiceDistance++;
    if (tieneTT) vinsConTellTales++;
    if (tieneAcc) vinsConAccumulated++;
    if (tieneSnap) vinsConSnapshot++;
  }

  console.log("==================== RESUMEN ====================");
  console.log(`VINs unicos en la respuesta:        ${porVin.size}`);
  console.log(`VINs con uptimeData.serviceDistance: ${vinsConServiceDistance}`);
  console.log(`VINs con uptimeData.tellTaleInfo:    ${vinsConTellTales}`);
  console.log(`VINs con volvoGroupAccumulated:      ${vinsConAccumulated}`);
  console.log(`VINs con volvoGroupSnapshot:         ${vinsConSnapshot}`);

  console.log("\n=========== TRIGGERS VISTOS ==========");
  const sortedTriggers = [...triggersVistos.entries()].sort((a, b) => b[1] - a[1]);
  for (const [tg, n] of sortedTriggers) {
    console.log(`  ${tg.padEnd(40)} ${n}`);
  }

  if (camposAccumulated.size > 0) {
    console.log("\n=========== CAMPOS EN volvoGroupAccumulated ==========");
    const sortedFields = [...camposAccumulated.entries()].sort((a, b) => b[1] - a[1]);
    for (const [k, n] of sortedFields) {
      console.log(`  ${k.padEnd(40)} aparece en ${n} records`);
    }
  }

  // Muestra de shape: primeros 3 VINs con uptimeData
  console.log("\n=========== MUESTRA DE 3 VINs (con uptimeData) ==========");
  let mostrados = 0;
  for (const [vin, recs] of porVin) {
    if (mostrados >= 3) break;
    const conUp = recs.find((r) => r.uptimeData);
    if (!conUp) continue;
    mostrados++;
    console.log(`\n--- VIN ${vin} ---`);
    console.log(`  triggerType: ${conUp.triggerType || conUp.type || "?"}`);
    console.log(`  uptimeData keys: ${Object.keys(conUp.uptimeData).join(", ")}`);
    if (conUp.uptimeData.serviceDistance != null) {
      console.log(`  serviceDistance: ${conUp.uptimeData.serviceDistance} (m)`);
    }
    if (Array.isArray(conUp.uptimeData.tellTaleInfo)) {
      console.log(`  tellTaleInfo: ${conUp.uptimeData.tellTaleInfo.length} items`);
      for (const t of conUp.uptimeData.tellTaleInfo.slice(0, 3)) {
        console.log(`    - ${JSON.stringify(t)}`);
      }
    }
    if (conUp.uptimeData.engineCoolantTemperature != null) {
      console.log(`  engineCoolantTemp: ${conUp.uptimeData.engineCoolantTemperature} C`);
    }
    const acc = conUp.snapshotData?.volvoGroupAccumulated;
    if (acc) {
      console.log(`  volvoGroupAccumulated keys: ${Object.keys(acc).join(", ")}`);
      console.log(`  sample: ${JSON.stringify(acc).substring(0, 200)}`);
    }
  }

  console.log("\n[probar] OK. Cerra y pegame el output.");
  process.exit(0);
})().catch((e) => {
  console.error("\n[probar] ERROR:", e.message);
  if (e.stack) console.error(e.stack);
  process.exit(1);
});
