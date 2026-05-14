// Probe del endpoint `/files/reports` de Sitrack — el que necesitamos
// para acceder a eventos acumulados (1400+ tipos de evento, ver
// docs/SITRACK-Tipos de evento_reporte). Hoy SOLO consumimos
// /v2/report (snapshot del último estado de cada unidad).
//
// Estado conocido (al armar este script): el endpoint responde 200
// con buffer vacío — está bloqueado esperando que Sitrack active la
// acumulación del lado de su backoffice (ver docs/EMAIL_SITRACK_API.md).
//
// Este script repite la prueba para confirmar el estado actual.
//
// USO (PowerShell, sin exponer credenciales en history):
//
//   cd "C:\Users\Colo Logistica\coopertrans_movil"
//   $cred = Get-Credential -Message "Sitrack API" -UserName "ws41629VecchiSRL"
//   $env:SITRACK_USERNAME = $cred.UserName
//   $env:SITRACK_PASSWORD = $cred.GetNetworkCredential().Password
//   node scripts/sitrack_probar_files_reports.js
//   Remove-Item Env:SITRACK_USERNAME, Env:SITRACK_PASSWORD
//
// Las creds reales viven SOLO en Secret Manager:
//   firebase functions:secrets:access SITRACK_USERNAME
//   firebase functions:secrets:access SITRACK_PASSWORD
//
// Diagnóstico:
//   - 200 + body con array no-vacío → ACTIVADO. Tenemos data, podemos
//     arrancar el consumer (procesa eventos + persiste).
//   - 200 + body vacío (length 0) → AMBIGUO: o no activado, o activado
//     pero sin eventos desde la última invocación. Si lo corrés en
//     horario operativo (8-18hs ART, varios choferes manejando) y
//     viene vacío, casi seguro NO está activado.
//   - 400 errorCode 120 → otra invocación en progreso (poco probable
//     desde un script puntual; lo veríamos si dejamos un poller corriendo
//     y lanzamos esta query en paralelo).
//   - 401 → credenciales mal.
//   - 403 → cuenta sin permisos sobre el endpoint.
//   - 404 → endpoint no existe en esta región (improbable).
//   - 5xx → problema servidor Sitrack.

const SITRACK_BASE = 'https://externalappgw.ar.sitrack.com';
const ENDPOINT = '/files/reports';

const user = process.env.SITRACK_USERNAME;
const pass = process.env.SITRACK_PASSWORD;

if (!user || !pass) {
  console.error('❌ Faltan SITRACK_USERNAME / SITRACK_PASSWORD en el environment.');
  console.error('   Ver bloque USO en el header del script.');
  process.exit(1);
}

const auth = 'Basic ' + Buffer.from(`${user}:${pass}`).toString('base64');

(async () => {
  console.log(`Sitrack /files/reports probe`);
  console.log(`Base   : ${SITRACK_BASE}`);
  console.log(`URL    : ${SITRACK_BASE}${ENDPOINT}`);
  console.log(`User   : ${user}  (password leída del env, no se imprime)`);
  console.log(`Hora   : ${new Date().toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires' })} ART`);
  console.log('─'.repeat(70));

  const t0 = Date.now();
  let res;
  try {
    res = await fetch(`${SITRACK_BASE}${ENDPOINT}`, {
      method: 'GET',
      headers: {
        Authorization: auth,
        Accept: 'application/json',
      },
    });
  } catch (e) {
    console.error(`❌ Error de red: ${e.message}`);
    process.exit(1);
  }
  const t1 = Date.now();

  const status = res.status;
  const contentLength = res.headers.get('content-length');
  const contentType = res.headers.get('content-type');

  console.log(`HTTP ${status} ${res.statusText}`);
  console.log(`Latencia: ${t1 - t0}ms`);
  if (contentType) console.log(`content-type   : ${contentType}`);
  if (contentLength != null) console.log(`content-length : ${contentLength} bytes`);
  for (const h of ['retry-after', 'x-ratelimit-remaining', 'www-authenticate']) {
    const v = res.headers.get(h);
    if (v) console.log(`${h.padEnd(15)}: ${v}`);
  }

  // Lectura streaming-aware: el PDF dice que NO hay que cerrar la
  // conexión hasta haber leído todos los bytes. Usamos res.text() que
  // ya consume todo el body antes de devolver.
  let body = '';
  try {
    body = await res.text();
  } catch (e) {
    console.error(`⚠ Error leyendo body: ${e.message}`);
  }

  const bodyBytes = Buffer.byteLength(body, 'utf8');
  console.log(`body leído     : ${bodyBytes} bytes`);
  console.log('');

  // ─── Diagnóstico ─────────────────────────────────────────────
  if (status === 200) {
    if (bodyBytes === 0) {
      console.log('⚠ HTTP 200 con BODY VACÍO.');
      console.log('  Significa una de dos cosas:');
      console.log('   (a) El endpoint NO está activado (Sitrack no abrió el');
      console.log('       buffer de acumulación para esta cuenta).');
      console.log('   (b) Está activado pero no hubo eventos nuevos desde la');
      console.log('       última invocación (caso normal en horario inactivo).');
      console.log('');
      console.log('  Para distinguir: correlo en horario operativo (9-18 ART,');
      console.log('  con choferes manejando). Si igual viene vacío → caso (a).');
      console.log('');
      console.log('  Próximo paso si es (a): mandar / re-mandar el mail de');
      console.log('  docs/EMAIL_SITRACK_API.md a integraciones.ar@sitrack.com.');
    } else {
      // Tratar de parsear y reportar resumen.
      let parsed = null;
      try {
        parsed = JSON.parse(body);
      } catch {
        // No JSON — el formato puede ser CSV, XML, etc., depende de
        // cómo Sitrack haya configurado la cuenta.
      }
      if (Array.isArray(parsed)) {
        console.log(`✅ ACTIVADO. Recibimos ${parsed.length} reporte(s).`);
        // Resumir tipos de evento.
        const porEvt = new Map();
        for (const r of parsed) {
          const evt = (r.eventName || `eventId:${r.eventId}` || '(sin tipo)').toString();
          porEvt.set(evt, (porEvt.get(evt) || 0) + 1);
        }
        const top = [...porEvt.entries()].sort((a, b) => b[1] - a[1]).slice(0, 15);
        console.log('  Top tipos de evento:');
        for (const [evt, count] of top) {
          console.log(`    ${count.toString().padStart(5)} × ${evt}`);
        }
        if (porEvt.size > 15) {
          console.log(`    ... y ${porEvt.size - 15} tipo(s) más.`);
        }
        // Sample del primer reporte completo.
        if (parsed.length > 0) {
          console.log('');
          console.log('  Ejemplo del primer reporte (campos):');
          const campos = Object.keys(parsed[0] || {}).slice(0, 25);
          console.log(`    ${campos.join(', ')}`);
        }
        console.log('');
        console.log('  ✓ Próximo paso: arrancar `sitrackReportesConsumer`');
        console.log('    como Cloud Function que polea cada N min y persiste.');
      } else if (parsed && typeof parsed === 'object') {
        console.log(`✅ HTTP 200 con body JSON (no array).`);
        console.log('  Body (primeros 1500 chars):');
        const s = JSON.stringify(parsed, null, 2);
        console.log(s.slice(0, 1500).split('\n').map((l) => '    ' + l).join('\n'));
      } else {
        console.log(`✅ HTTP 200 con body NO-JSON (${bodyBytes} bytes).`);
        console.log('  El formato configurado para esta cuenta NO es JSON.');
        console.log('  Posibles formatos según docs: XML, SOAP, JAX, SerialPHP, CSV.');
        console.log('  Body (primeros 1500 chars):');
        console.log(body.slice(0, 1500).split('\n').map((l) => '    ' + l).join('\n'));
      }
    }
  } else if (status === 400) {
    console.log('⚠ HTTP 400. Posibles causas:');
    console.log('   - errorCode 120: otra invocación en progreso (esperar 1+ min).');
    console.log('   - parámetro inválido.');
    console.log('  Body:');
    console.log(body.slice(0, 1500).split('\n').map((l) => '    ' + l).join('\n'));
  } else if (status === 401) {
    console.log('❌ 401 Unauthorized. Verificar credenciales contra Secret Manager:');
    console.log('   firebase functions:secrets:access SITRACK_USERNAME');
    console.log('   firebase functions:secrets:access SITRACK_PASSWORD');
  } else if (status === 403) {
    console.log('❌ 403 Forbidden. La cuenta no tiene permiso sobre /files/reports.');
    console.log('   Contactar a integraciones.ar@sitrack.com para activar.');
  } else if (status === 404) {
    console.log('❌ 404 NotFound. El endpoint no existe en esta región o cuenta.');
  } else if (status >= 500) {
    console.log('⚠ Error del servidor Sitrack. Reintentar más tarde.');
    console.log('  Body:');
    console.log(body.slice(0, 1500).split('\n').map((l) => '    ' + l).join('\n'));
  } else {
    console.log(`HTTP ${status} — código no esperado.`);
    console.log('  Body:');
    console.log(body.slice(0, 1500).split('\n').map((l) => '    ' + l).join('\n'));
  }
})().catch((e) => {
  console.error('error:', e);
  process.exit(1);
});
