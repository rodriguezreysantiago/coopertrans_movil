// Probe de los módulos del API Volvo que NO consumimos hoy y que
// podrían aportar valor:
//
//   1. Messaging API (api.volvotrucks.com)
//      → mensajería al display HMI del camión.
//      → endpoints: /users, /channels, /channels/{id}/messages.
//
//   2. Tachograph Files API (api.volvotrucks.com/tacho)
//      → descarga de archivos .DDD legales firmados digitalmente.
//      → endpoint: /tachofiles?starttime=...&contentFilter=...
//
// Mismo patrón que probar_volvo_scores_api.js / probar_volvo_driver_api.js:
// credenciales solo via env vars cargadas con Get-Credential de PowerShell,
// cero exposición a disco/history.
//
// USO (PowerShell):
//
//   cd "C:\Users\Colo Logistica\coopertrans_movil"
//   $cred = Get-Credential -Message "Credenciales Volvo Connect" -UserName "018B1E992E"
//   $env:VOLVO_USERNAME = $cred.UserName
//   $env:VOLVO_PASSWORD = $cred.GetNetworkCredential().Password
//   node scripts/probar_volvo_modulos_no_usados.js
//   Remove-Item Env:VOLVO_USERNAME, Env:VOLVO_PASSWORD
//
// Salida esperada:
//   - 200 OK con data → módulo activo, podemos integrar.
//   - 200 OK con array vacío → módulo activo pero sin uso (a configurar).
//   - 401 → credenciales mal.
//   - 403 → módulo no incluido en el contrato (hay que pedirlo a Volvo).
//   - 404 → endpoint inaccesible para este cliente.

const username = process.env.VOLVO_USERNAME;
const password = process.env.VOLVO_PASSWORD;
const base = process.env.VOLVO_BASE || 'https://api.volvotrucks.com';

if (!username || !password) {
  console.error('❌ Faltan VOLVO_USERNAME o VOLVO_PASSWORD en el environment.');
  console.error('   Ver el bloque USO en el header del script.');
  process.exit(1);
}

const auth = 'Basic ' + Buffer.from(`${username}:${password}`).toString('base64');

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
      headers: { Authorization: auth, Accept: accept },
    });
  } catch (e) {
    console.error(`  ❌ Error de red: ${e.message}`);
    return { ok: false, status: 0 };
  }

  const status = res.status;
  let body = '';
  try { body = await res.text(); } catch { /* ignore */ }

  console.log(`  HTTP ${status} ${res.statusText}`);
  for (const h of ['content-type', 'x-ratelimit-remaining', 'retry-after', 'www-authenticate']) {
    const v = res.headers.get(h);
    if (v) console.log(`  ${h}: ${v}`);
  }

  if (status === 200) {
    console.log('  ✓ Acceso OK al endpoint.');
    let data = null;
    try { data = JSON.parse(body); } catch { /* not json */ }
    if (data) {
      const resumen = JSON.stringify(data, null, 2);
      const recortado = resumen.length > 2500
        ? resumen.slice(0, 2500) + `\n  ... (truncado, body completo ${resumen.length} chars)`
        : resumen;
      console.log('  Body (parseado):');
      console.log(recortado.split('\n').map((l) => '    ' + l).join('\n'));
    } else {
      console.log('  Body crudo (no JSON):');
      console.log(body.slice(0, 1500).split('\n').map((l) => '    ' + l).join('\n'));
    }
    return { ok: true, status, data };
  }

  if (status === 401) {
    console.log('  ❌ 401 — Credenciales inválidas.');
  } else if (status === 403) {
    console.log('  ❌ 403 — Módulo NO activado en el contrato Vecchi.');
    console.log('     Hay que pedirle a Volvo Connect que active el pack.');
  } else if (status === 404) {
    console.log('  ❌ 404 — Endpoint no disponible para este cliente.');
  } else if (status === 406) {
    console.log('  ❌ 406 — Header Accept incorrecto. Revisar versión.');
  } else if (status === 429) {
    console.log('  ❌ 429 — Rate limit. Esperar y reintentar.');
  }
  console.log('  Body (primeros 1500 chars):');
  console.log(body.slice(0, 1500).split('\n').map((l) => '    ' + l).join('\n'));
  return { ok: false, status };
}

(async () => {
  console.log(`Volvo APIs probe — base: ${base}`);
  console.log(`Username: ${username}  (password leída del env, no se imprime)`);

  // ═══════════════════════════════════════════════════════════════
  // MESSAGING API
  // ═══════════════════════════════════════════════════════════════
  console.log('');
  console.log('═'.repeat(70));
  console.log('  MESSAGING API — mensajes al HMI del camión');
  console.log('═'.repeat(70));

  // 1.1 Listar usuarios de la flota (con currentVehicle si están manejando).
  const messUsers = await probe(
    'Listar usuarios de la flota (GET /users)',
    `${base}/users?limit=100&offset=1`,
    'application/x.volvogroup.com.users.v1.0+json; UTF-8'
  );

  // 1.2 Listar canales existentes — útil para ver si ya hay conversaciones.
  await probe(
    'Listar canales del usuario (GET /channels)',
    `${base}/channels?limit=20&offset=1`,
    'application/x.volvogroup.com.channels.v1.0+json; UTF-8'
  );

  // ═══════════════════════════════════════════════════════════════
  // TACHOGRAPH FILES API
  // ═══════════════════════════════════════════════════════════════
  console.log('');
  console.log('═'.repeat(70));
  console.log('  TACHOGRAPH FILES API — backup legal de archivos .DDD');
  console.log('═'.repeat(70));

  // 2. Listar archivos disponibles de los últimos 90 días — SIN descargar
  // contenido (includeFileContent=false) para no traer megas en el probe.
  // Si hay archivos, los nombres + receivedDateTime ya nos dicen qué hay.
  const ahora = new Date();
  const hace90 = new Date(ahora.getTime() - 90 * 24 * 60 * 60 * 1000);
  const startIso = hace90.toISOString();
  const stopIso = ahora.toISOString();
  await probe(
    `Listar archivos .DDD últimos 90 días (GET /tacho/tachofiles)`,
    `${base}/tacho/tachofiles?` +
      `starttime=${encodeURIComponent(startIso)}&` +
      `stoptime=${encodeURIComponent(stopIso)}&` +
      `contentFilter=DRIVERCARDFILE,TACHOFILE&` +
      `includeFileContent=false`,
    'application/x.volvogroup.com.tachofiles.v1.0+json; UTF-8'
  );

  // ═══════════════════════════════════════════════════════════════
  // RESUMEN
  // ═══════════════════════════════════════════════════════════════
  console.log('');
  console.log('═'.repeat(70));
  console.log('  Diagnóstico:');
  console.log('  - 200 con users/channels poblados → Messaging activo.');
  console.log('  - 200 con tachofiles poblados   → Tachograph Files activo,');
  console.log('    podemos arrancar backup legal mensual a Cloud Storage.');
  console.log('  - 200 con arrays vacíos → módulo activo pero sin uso aún.');
  console.log('  - 403 → módulo no en contrato, pedirlo a Volvo.');
  console.log('═'.repeat(70));

  // Hint extra: si users trajo gente con `currentVehicle`, el bot podría
  // saber inmediatamente qué chofer está en cada VIN sin esperar al cruce
  // de iButton de Sitrack. Útil para validación cruzada.
  if (messUsers.ok && messUsers.data?.users) {
    const conVehiculo = messUsers.data.users.filter((u) => u.currentVehicle);
    if (conVehiculo.length > 0) {
      console.log('');
      console.log('💡 Hint: Messaging /users devuelve `currentVehicle` para choferes');
      console.log('   que están manejando ahora. Esto es identificación real-time');
      console.log('   alternativa al iButton — útil como fallback cruzado.');
      console.log(`   Choferes con currentVehicle ahora: ${conVehiculo.length}`);
    }
  }
})();
