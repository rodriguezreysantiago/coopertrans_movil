// Trae el último report de UNA patente puntual desde el endpoint
// `/v2/report` de Sitrack — el mismo que consume el cron
// `sitrackPosicionPoller`. Sirve para diagnosticar diferencias
// entre lo que Sitrack manda en el JSON crudo y lo que persistimos
// en SITRACK_POSICIONES.
//
// USO (PowerShell):
//   $cred = Get-Credential -Message "Sitrack API" -UserName "ws41629VecchiSRL"
//   $env:SITRACK_USERNAME = $cred.UserName
//   $env:SITRACK_PASSWORD = $cred.GetNetworkCredential().Password
//   node scripts/sitrack_ver_report_unidad.js AC383OM
//   Remove-Item Env:SITRACK_USERNAME, Env:SITRACK_PASSWORD
//
// El script muestra:
//   - cantidad total de reports recibidos (debe ser 1 por unidad)
//   - reports duplicados para la patente buscada (si Sitrack manda varios)
//   - JSON crudo de los driver_* + ignition + reportDate de cada uno
//   - simulación local de matchPorNombre con cada report

const SITRACK_BASE = 'https://externalappgw.ar.sitrack.com';
const ENDPOINT = '/v2/report';

const user = process.env.SITRACK_USERNAME;
const pass = process.env.SITRACK_PASSWORD;
if (!user || !pass) {
  console.error('❌ Faltan SITRACK_USERNAME / SITRACK_PASSWORD en el environment.');
  console.error('   Ver header del script para el patrón PowerShell.');
  process.exit(1);
}

const patenteArg = (process.argv[2] || '').trim().toUpperCase();
if (!patenteArg) {
  console.error('Uso: node scripts/sitrack_ver_report_unidad.js <PATENTE>');
  process.exit(1);
}

async function main() {
  const auth = 'Basic ' + Buffer.from(`${user}:${pass}`).toString('base64');
  const url = `${SITRACK_BASE}${ENDPOINT}`;

  console.log(`\n📡 GET ${url}\n`);
  const res = await fetch(url, {
    method: 'GET',
    headers: { 'Authorization': auth, 'Accept': 'application/json' },
  });
  console.log(`HTTP ${res.status} ${res.statusText}`);
  if (!res.ok) {
    console.error('Body:', await res.text());
    process.exit(1);
  }
  const reports = await res.json();
  if (!Array.isArray(reports)) {
    console.error('La respuesta NO es un array:', typeof reports);
    process.exit(1);
  }
  console.log(`Total reports recibidos: ${reports.length}\n`);

  // Filtramos por patente (assetId == patente)
  const filtrados = reports.filter(
    (r) => (r.assetId ?? '').toString().trim().toUpperCase() === patenteArg
  );
  console.log(`Reports para ${patenteArg}: ${filtrados.length}\n`);
  if (filtrados.length === 0) {
    console.log('No hay ningún report para esa patente.');
    process.exit(0);
  }
  if (filtrados.length > 1) {
    console.log('⚠ Sitrack mandó MÚLTIPLES reports para la misma patente.');
    console.log('  Esto es relevante porque el cron itera y SOBRESCRIBE el doc:');
    console.log('  el último iterado gana, pudiendo pisar drift_tipo.\n');
  }

  filtrados.forEach((r, i) => {
    console.log(`══════════ REPORT [${i}] ══════════`);
    const driverDni = (r.driverDocumentNumber ?? '').toString().trim();
    const driverNombre = (r.driverName ?? '').toString().trim();
    const driverApellido = (r.driverLastName ?? '').toString().trim();
    const ign = r.ignition;
    const rdt = r.reportDate;

    console.log(`reportDate           : ${rdt}`);
    console.log(`ignition             : ${ign}`);
    console.log(`speed                : ${r.speed}`);
    console.log(`gpsValidity          : ${r.gpsValidity}`);
    console.log(`driverDocumentNumber : ${JSON.stringify(r.driverDocumentNumber)}  → trim "${driverDni}"`);
    console.log(`driverName           : ${JSON.stringify(r.driverName)}  → trim "${driverNombre}"`);
    console.log(`driverLastName       : ${JSON.stringify(r.driverLastName)}  → trim "${driverApellido}"`);
    if (r.eventName) console.log(`eventName            : ${r.eventName}`);
    if (r.eventId) console.log(`eventId              : ${r.eventId}`);
    console.log('');

    // Simulación local de la lógica del cron
    const tokens = `${driverNombre} ${driverApellido}`
      .toUpperCase()
      .split(/\s+/)
      .filter((t) => t.length > 1);
    console.log(`Tokens calculados    : [${tokens.map((t) => JSON.stringify(t)).join(', ')}]`);
    console.log('(asumiendo asignación "BASTIAS HORACIO RENE" / DNI 31272549)');
    const nombreAsig = 'BASTIAS HORACIO RENE';
    const matchPorNombre =
      tokens.length > 0 && tokens.every((t) => nombreAsig.includes(t));
    console.log(`matchPorNombre       : ${matchPorNombre}`);

    let drift = null;
    const ignOn = ign === 1;
    if (driverDni && driverDni !== '31272549') {
      drift = 'CHOFER_DISTINTO';
    } else if (!driverDni && ignOn && !matchPorNombre) {
      drift = 'CHOFER_NO_IDENTIFICADO';
    }
    console.log(`drift_tipo simulado  : ${drift || '(null → no avisar)'}`);
    console.log('');
  });
}

main().catch((e) => {
  console.error('❌ Error:', e.stack || e.message);
  process.exit(1);
});
