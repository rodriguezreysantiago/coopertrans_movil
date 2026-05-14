// Probe one-shot para confirmar si Vecchi tiene activado el pack
// "Driver APIs" en su contrato Volvo Connect.
//
// La Volvo Group driver APIs (v1.1.4) devuelve:
//   - GET /driver/drivers       → lista de chofers identificados (Tacho/PIN/USB)
//   - GET /driver/drivertimes   → actividad del tacógrafo (DRIVE/REST/WORK/AVAILABLE)
//                                 + forecast (cuánto le queda hasta pausa
//                                 obligatoria / descanso diario / semanal)
//                                 + dtjActivities (LOADING/UNLOADING/etc)
//
// El módulo NO siempre viene activo en el contrato — Vehicle / VehicleAlerts
// vienen por default; Scores y Driver son opcionales / pagos extra. Mismo
// patrón que `probar_volvo_scores_api.js`.
//
// Este script hace 2 GET y reporta:
//   - 200 OK con data → tienen el pack y los tractores emiten al feed.
//                       Procedemos a integrar como fuente de jornada.
//   - 200 OK con array vacío → tienen el pack pero los tractores no
//                              transmiten (hardware/configuración por unidad).
//   - 403 Forbidden → NO tienen el pack. Hay que pedirle a Volvo que lo
//                     active en el contrato (con costo o sin, depende).
//   - 401 → credenciales mal (verificar Secret Manager tras última rotación).
//   - 404 → endpoint no disponible en la región.
//
// USO (PowerShell, sin exponer creds en history ni a disco):
//
//   cd "C:\Users\Colo Logistica\coopertrans_movil"
//   $cred = Get-Credential -Message "Credenciales Volvo Connect" -UserName "018B1E992E"
//   $env:VOLVO_USERNAME = $cred.UserName
//   $env:VOLVO_PASSWORD = $cred.GetNetworkCredential().Password
//   node scripts/probar_volvo_driver_api.js
//   Remove-Item Env:VOLVO_USERNAME, Env:VOLVO_PASSWORD
//
// Get-Credential abre un prompt nativo de Windows que NO muestra la
// password en pantalla y la mantiene solo en memoria del proceso PowerShell
// hasta que `Remove-Item` la limpia. Cero exposición a disco o a logs.

const username = process.env.VOLVO_USERNAME;
const password = process.env.VOLVO_PASSWORD;
const base = process.env.VOLVO_BASE || 'https://api.volvotrucks.com';

if (!username || !password) {
  console.error('❌ Faltan VOLVO_USERNAME o VOLVO_PASSWORD en el environment.');
  console.error('   Ver el bloque USO en el header del script.');
  process.exit(1);
}

const auth = 'Basic ' + Buffer.from(`${username}:${password}`).toString('base64');

/**
 * Hace un GET a un endpoint de la Volvo Driver API y reporta status +
 * resumen del body. Devuelve true si fue 200, false en cualquier otro
 * caso (no rompe el script — seguimos con el siguiente probe).
 */
async function probe(label, url, accept) {
  console.log('');
  console.log('─'.repeat(70));
  console.log(`▶ ${label}`);
  console.log(`  GET ${url}`);
  console.log(`  Accept: ${accept}`);
  console.log('─'.repeat(70));

  let res;
  try {
    res = await fetch(url, {
      method: 'GET',
      headers: {
        Authorization: auth,
        Accept: accept,
      },
    });
  } catch (e) {
    console.error(`  ❌ Error de red: ${e.message}`);
    return false;
  }

  const status = res.status;
  let body = '';
  try {
    body = await res.text();
  } catch (e) {
    body = `(no se pudo leer body: ${e.message})`;
  }

  console.log(`  HTTP ${status} ${res.statusText}`);
  // Headers que importan para diagnóstico.
  const headersRelevantes = ['content-type', 'x-ratelimit-remaining', 'retry-after', 'www-authenticate'];
  for (const h of headersRelevantes) {
    const v = res.headers.get(h);
    if (v) console.log(`  ${h}: ${v}`);
  }

  if (status === 200) {
    console.log('  ✓ Acceso OK al endpoint.');
    // Intentar parse JSON para resumir el contenido.
    try {
      const data = JSON.parse(body);
      const resumen = JSON.stringify(data, null, 2);
      const recortado = resumen.length > 2500
        ? resumen.slice(0, 2500) + `\n  ... (truncado, body completo ${resumen.length} chars)`
        : resumen;
      console.log('  Body (parseado):');
      console.log(recortado.split('\n').map((l) => '    ' + l).join('\n'));

      // Heurísticas: ¿hay drivers / activities reales o respuesta vacía?
      const driversArr = data?.driverResponse?.drivers;
      const driverTimesArr = data?.driverTimeResponse?.driverTimes;
      if (Array.isArray(driversArr)) {
        if (driversArr.length === 0) {
          console.log('  ⚠ Acceso OK pero `drivers` vacío — el módulo está activo pero no hay');
          console.log('    chofers identificados (probable: hardware/config por unidad).');
        } else {
          console.log(`  ✓ ${driversArr.length} chofer(es) en la respuesta.`);
        }
      }
      if (Array.isArray(driverTimesArr)) {
        if (driverTimesArr.length === 0) {
          console.log('  ⚠ Acceso OK pero `driverTimes` vacío — el módulo está activo pero no hay');
          console.log('    actividades de tacógrafo (probable: tractores no transmiten o ventana sin data).');
        } else {
          console.log(`  ✓ ${driverTimesArr.length} chofer(es) con datos de tacógrafo.`);
          // Ejemplo del primer chofer.
          const primero = driverTimesArr[0];
          if (primero?.activities?.length) {
            const a = primero.activities[0];
            console.log(`    Ejemplo: workingState=${a.workingState}, source=${a.source}, ` +
              `start=${a.startTime}, vin=${a.vin || '(sin vin)'}`);
          }
          if (primero?.forecast) {
            console.log(`    Forecast 1er chofer: nextRest=${primero.forecast.nextRestType}, ` +
              `min hasta break=${primero.forecast.timeLeftToDriveUntilBreak}, ` +
              `min hasta daily rest=${primero.forecast.timeLeftToDriveUntilDailyRest}`);
          }
        }
      }
    } catch {
      // No JSON parseable.
      console.log('  Body crudo (no JSON):');
      console.log(body.slice(0, 1500).split('\n').map((l) => '    ' + l).join('\n'));
    }
    return true;
  }

  // Errores específicos.
  if (status === 401) {
    console.log('  ❌ Credenciales inválidas. Verificá VOLVO_USERNAME / VOLVO_PASSWORD');
    console.log('     contra el último valor del Secret Manager.');
  } else if (status === 403) {
    console.log('  ❌ Forbidden — el módulo Driver APIs NO está activado en el contrato Vecchi.');
    console.log('     Hay que pedirle a Volvo Connect que active el pack en la cuenta.');
  } else if (status === 404) {
    console.log('  ❌ NotFound — el endpoint no existe o no es accesible para este cliente.');
  } else if (status === 406) {
    console.log('  ❌ NotAcceptable — el header Accept es incorrecto. Revisar versión.');
  } else if (status === 429) {
    console.log('  ❌ TooManyRequests — golpeamos rate limit. Esperar y reintentar.');
  }

  console.log('  Body (primeros 1500 chars):');
  console.log(body.slice(0, 1500).split('\n').map((l) => '    ' + l).join('\n'));
  return false;
}

(async () => {
  console.log(`Volvo Driver API probe — base: ${base}`);
  console.log(`Username: ${username}  (password leída del env, no se imprime)`);

  // 1. Listar drivers identificados.
  await probe(
    'Listar drivers conocidos (GET /driver/drivers)',
    `${base}/driver/drivers`,
    'application/x.volvogroup.com.drivers.v1.0+json; UTF-8'
  );

  // 2. Última actividad de cada chofer + forecast.
  await probe(
    'Última actividad + forecast (GET /driver/drivertimes?latestOnly=true)',
    `${base}/driver/drivertimes?latestOnly=true&contentFilter=ACTIVITIES,FORECAST`,
    'application/x.volvogroup.com.drivertimes.v1.1+json; UTF-8'
  );

  // 3. Histórico de los últimos 7 días — si latestOnly viene vacío
  // pero el feed funciona, acá deberían aparecer actividades reales.
  // Si también viene vacío, confirma que no hay transmisión de
  // tacógrafo desde los tractores (problema de hardware/config).
  const ahora = new Date();
  const hace7 = new Date(ahora.getTime() - 7 * 24 * 60 * 60 * 1000);
  const startIso = hace7.toISOString();
  const stopIso = ahora.toISOString();
  await probe(
    `Histórico 7 días (GET /driver/drivertimes?starttime=${startIso}&stoptime=${stopIso})`,
    `${base}/driver/drivertimes?` +
      `starttime=${encodeURIComponent(startIso)}&` +
      `stoptime=${encodeURIComponent(stopIso)}&` +
      `contentFilter=ACTIVITIES,DTJ`,
    'application/x.volvogroup.com.drivertimes.v1.1+json; UTF-8'
  );

  console.log('');
  console.log('─'.repeat(70));
  console.log('Diagnóstico:');
  console.log('  - Si los 2 dieron 200 con drivers/driverTimes poblados → integrar.');
  console.log('  - Si dieron 200 con arrays vacíos → módulo activo, falta config por unidad.');
  console.log('  - Si dieron 403 → módulo no activado, hablar con Volvo Connect.');
  console.log('─'.repeat(70));
})();
