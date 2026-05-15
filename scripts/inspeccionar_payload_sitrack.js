// Inspección del payload crudo que devuelve Sitrack — confirmar qué
// campos están llegando hoy en `/v2/report` y `/files/reports`,
// especialmente los relacionados con zonas geocercadas:
//
//   areaType, cartographyLimitSpeed, gpsSpeed, zoneId, zoneName, zoneCondition.
//
// Contexto: Santiago entregó a YPF los IMEIs de los GPS de Vecchi para
// que los agregaran a su gateway Sitrack. Si YPF ya está leyendo los
// datos, esos campos deberían estar también en nuestra cuenta
// (ws41629VecchiSRL) porque vienen del MISMO dispositivo físico.
//
// USO (desde la raíz del repo, PowerShell):
//
//   cd "C:\Users\Colo Logistica\coopertrans_movil"
//   node scripts/inspeccionar_payload_sitrack.js
//
// El script:
//   1. Lee credenciales Sitrack de whatsapp-bot/.env.
//   2. Hace 1 request a /v2/report (snapshot última posición x patente).
//   3. Hace 1 request a /files/reports (eventos acumulados).
//   4. Lista los campos UNICOS encontrados en cada payload.
//   5. Reporta cuántos reportes/eventos tienen poblados los campos
//      de zonas (areaType, cartographyLimitSpeed, zoneId, zoneName,
//      zoneCondition).
//   6. Muestra 3 ejemplos de reportes con esos campos poblados
//      (si los hay) y 3 sin ellos (para comparar).

const path = require('path');
const fsNode = require('fs');
const https = require('https');

const botDir = path.resolve(__dirname, '..', 'whatsapp-bot');
const botNodeModules = path.join(botDir, 'node_modules');
if (!fsNode.existsSync(botNodeModules)) {
  console.error(
    `❌ No existe ${botNodeModules}. Correr 'npm install' en whatsapp-bot primero.`
  );
  process.exit(1);
}
module.paths.unshift(botNodeModules);
process.chdir(botDir);
require('dotenv').config({ quiet: true });

const SITRACK_USERNAME = process.env.SITRACK_USERNAME;
const SITRACK_PASSWORD = process.env.SITRACK_PASSWORD;
if (!SITRACK_USERNAME || !SITRACK_PASSWORD) {
  console.error(
    '❌ Faltan SITRACK_USERNAME / SITRACK_PASSWORD en whatsapp-bot/.env'
  );
  console.error('   (en producción viven en Secret Manager, pero para este');
  console.error('   script local usan los mismos valores del .env del bot).');
  process.exit(1);
}

const BASE_HOST = 'externalappgw.ar.sitrack.com';
const AUTH_HEADER = 'Basic ' + Buffer.from(
  `${SITRACK_USERNAME}:${SITRACK_PASSWORD}`
).toString('base64');

function get(pathName) {
  return new Promise((resolve, reject) => {
    const req = https.get(
      {
        host: BASE_HOST,
        path: pathName,
        headers: { Authorization: AUTH_HEADER, Accept: 'application/json' },
      },
      (res) => {
        let body = '';
        res.on('data', (c) => body += c);
        res.on('end', () => {
          if (res.statusCode !== 200) {
            return reject(new Error(`HTTP ${res.statusCode}: ${body.slice(0, 300)}`));
          }
          try {
            resolve(JSON.parse(body));
          } catch (e) {
            reject(new Error(`No es JSON: ${body.slice(0, 200)}`));
          }
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(30000, () => req.destroy(new Error('timeout 30s')));
  });
}

function analizarReportes(label, reportes) {
  console.log('');
  console.log('═'.repeat(70));
  console.log(`  ${label}`);
  console.log('═'.repeat(70));
  console.log(`  Total reportes: ${reportes.length}`);
  if (reportes.length === 0) {
    console.log('  (vacío)');
    return;
  }

  // ─── Listar campos UNICOS encontrados ──────────────────────────
  const camposCount = new Map();
  for (const r of reportes) {
    for (const k of Object.keys(r)) {
      camposCount.set(k, (camposCount.get(k) || 0) + 1);
    }
  }
  const camposOrdenados = [...camposCount.entries()]
    .sort((a, b) => b[1] - a[1]);
  console.log('');
  console.log(`  Campos únicos encontrados (${camposOrdenados.length}):`);
  for (const [k, c] of camposOrdenados) {
    const pct = ((c / reportes.length) * 100).toFixed(1);
    const flag = ['areaType', 'cartographyLimitSpeed', 'gpsSpeed',
      'zoneId', 'zoneName', 'zoneCondition'].includes(k) ? '⭐' : '  ';
    console.log(`    ${flag} ${k.padEnd(40)} ${c}/${reportes.length} (${pct}%)`);
  }

  // ─── Análisis de campos de zonas ───────────────────────────────
  console.log('');
  console.log('  ⭐ Análisis específico de campos de ZONAS / CARTOGRAFÍA:');
  const camposZona = [
    'areaType',
    'cartographyLimitSpeed',
    'gpsSpeed',
    'zoneId',
    'zoneName',
    'zoneCondition',
  ];
  for (const campo of camposZona) {
    const conValor = reportes.filter((r) => {
      const v = r[campo];
      return v !== undefined && v !== null && v !== '';
    });
    const pct = reportes.length > 0 ?
      ((conValor.length / reportes.length) * 100).toFixed(1) :
      '0';
    const status = conValor.length > 0 ? '✅' : '❌';
    console.log(`    ${status} ${campo.padEnd(28)} → ${conValor.length}/${reportes.length} (${pct}%) poblados`);
    if (conValor.length > 0) {
      // Mostrar 3 ejemplos de valores únicos
      const unicos = [...new Set(conValor.map((r) => String(r[campo])))]
        .slice(0, 5);
      console.log(`        Ejemplos: ${unicos.join(', ')}`);
    }
  }

  // ─── 1 ejemplo con zona, 1 sin zona ────────────────────────────
  const conZona = reportes.find((r) =>
    r.zoneName || r.zoneId || r.cartographyLimitSpeed
  );
  const sinZona = reportes.find((r) =>
    !r.zoneName && !r.zoneId && !r.cartographyLimitSpeed
  );
  if (conZona) {
    console.log('');
    console.log('  Ejemplo CON datos de zona/cartografía:');
    console.log('  ' + JSON.stringify(conZona, null, 2)
      .split('\n').join('\n  '));
  }
  if (sinZona && !conZona) {
    console.log('');
    console.log('  Ejemplo SIN datos de zona/cartografía (referencia):');
    console.log('  ' + JSON.stringify(sinZona, null, 2)
      .split('\n').slice(0, 25).join('\n  '));
  }
}

(async () => {
  console.log('');
  console.log('🔍 Inspección payload Sitrack — cuenta', SITRACK_USERNAME);

  try {
    const ultimo = await get('/v2/report');
    analizarReportes(
      'ENDPOINT /v2/report (snapshot última posición por patente)',
      Array.isArray(ultimo) ? ultimo : []
    );
  } catch (e) {
    console.error('');
    console.error(`❌ /v2/report falló: ${e.message}`);
  }

  try {
    const eventos = await get('/files/reports');
    analizarReportes(
      'ENDPOINT /files/reports (eventos acumulados)',
      Array.isArray(eventos) ? eventos : []
    );
  } catch (e) {
    console.error('');
    console.error(`❌ /files/reports falló: ${e.message}`);
  }

  console.log('');
  console.log('─'.repeat(70));
  console.log('Conclusión:');
  console.log('  - Si zoneId/zoneName/zoneCondition NO aparecen poblados en');
  console.log('    NINGÚN reporte → Sitrack NO tiene cargadas las capas de');
  console.log('    geocercas en la cuenta. Hay que pedirles que las habiliten.');
  console.log('  - Si cartographyLimitSpeed aparece poblado en una parte de');
  console.log('    los reportes → Sitrack tiene cartografía base activa (la');
  console.log('    de rutas y caminos), pero quizás faltan las capas YPF');
  console.log('    específicas (yacimientos).');
  console.log('  - Para que YPF audite contra los mismos datos: mismas');
  console.log('    capas YPF tienen que estar en `ws41629VecchiSRL`.');
  console.log('');
  process.exit(0);
})().catch((e) => {
  console.error('❌ Error inesperado:', e.stack || e.message);
  process.exit(1);
});
