// Import del Excel "VACACIONES <anio>" a la coleccion Firestore VACACIONES.
//
// DRY-RUN por default (no escribe nada): arma los docs y los muestra.
// Con --aplicar escribe via Admin SDK (bypasea rules) en un batch.
//
//   NODE_PATH=whatsapp-bot/node_modules node scripts/vacaciones_import.js [xlsx] [anio]
//   NODE_PATH=whatsapp-bot/node_modules node scripts/vacaciones_import.js [xlsx] [anio] --aplicar
//
// Reglas de armado (acordado con Santiago):
//   - dni/nombre/empresa/area: de EMPLEADOS (fuente de verdad), match por CUIL.
//   - diasCorresponden: el valor YA cargado en el Excel (col G), diasAuto=false
//     (es dato historico cargado a mano; el calculo auto se usa de 2026 en mas).
//   - periodos: los 4 pares inicio/fin del Excel (J/K, L/M, N/O, P/Q).
//   - tomados/restan: derivados.

const path = require('path');
const fs = require('node:fs');
const os = require('node:os');
const { execSync } = require('node:child_process');
const admin = require('firebase-admin');

const XLSX = process.argv[2] && !process.argv[2].startsWith('--')
  ? process.argv[2] : 'C:/Users/santi/Downloads/VACACIONES 2025.xlsx';
const ANIO = parseInt(
  (process.argv.find((a) => /^\d{4}$/.test(a)) || '2025'), 10);
const APLICAR = process.argv.includes('--aplicar');

admin.initializeApp({ credential: admin.credential.cert(
  require(path.resolve(__dirname, '..', 'serviceAccountKey.json'))
)});
const db = admin.firestore();

function leerExcel() {
  const py = path.join(os.tmpdir(), 'leer_vac_full.py');
  fs.writeFileSync(py, [
    'import openpyxl, json',
    `wb = openpyxl.load_workbook(r"${XLSX}", data_only=True)`,
    'ws = wb[wb.sheetnames[0]]',  // la hoja madre es la primera
    'def iso(c):',
    '    return c.isoformat()[:10] if hasattr(c, "isoformat") else None',
    'out = []',
    'for r in range(2, ws.max_row+1):',
    '    nombre = ws.cell(r,3).value',
    '    if not nombre: continue',
    '    cuil = "".join(ch for ch in str(ws.cell(r,2).value or "") if ch.isdigit())',
    '    pares = [(10,11),(12,13),(14,15),(16,17)]',
    '    periodos = []',
    '    for (ci,cf) in pares:',
    '        i = iso(ws.cell(r,ci).value); f = iso(ws.cell(r,cf).value)',
    '        if i and f: periodos.append([i,f])',
    '    out.append({',
    '        "cuil": cuil,',
    '        "nombre": str(nombre).strip(),',
    '        "ingreso": iso(ws.cell(r,4).value),',
    '        "dias_g": ws.cell(r,7).value,',
    '        "tomados_h": ws.cell(r,8).value,',
    '        "periodos": periodos,',
    '    })',
    'print(json.dumps(out, ensure_ascii=False))',
  ].join('\n'), 'utf8');
  return JSON.parse(execSync(`python "${py}"`, { encoding: 'utf8', maxBuffer: 50 * 1024 * 1024 }));
}

const norm = (s) => String(s).toUpperCase().replace(/\s+/g, ' ').trim();
const diasEntre = (iso1, iso2) => {
  const a = new Date(iso1 + 'T00:00:00Z');
  const b = new Date(iso2 + 'T00:00:00Z');
  return Math.round((b - a) / 86400000) + 1;
};

(async () => {
  console.log(`\n=== IMPORT VACACIONES ${ANIO} ${APLICAR ? '(APLICAR)' : '(DRY-RUN)'} ===`);
  console.log(`Excel: ${XLSX}\n`);

  const excel = leerExcel();
  console.log(`Filas en el Excel: ${excel.length}`);

  // EMPLEADOS -> mapas por CUIL y por nombre
  const snap = await db.collection('EMPLEADOS').get();
  const porCuil = new Map();
  const porNombre = new Map();
  for (const d of snap.docs) {
    const x = d.data();
    const cuil = String(x.CUIL || '').replace(/\D/g, '');
    const emp = {
      dni: d.id,
      nombre: String(x.NOMBRE || x.nombre || x.APELLIDO_NOMBRE || '').trim(),
      empresa: String(x.EMPRESA || x.empresa || '').trim(),
      area: String(x.AREA || x.area || '').trim(),
    };
    if (cuil) porCuil.set(cuil, emp);
    if (emp.nombre) porNombre.set(norm(emp.nombre), emp);
  }

  const docs = [];
  const problemas = [];
  for (const e of excel) {
    const emp = (e.cuil && porCuil.get(e.cuil)) || porNombre.get(norm(e.nombre));
    if (!emp) { problemas.push(`SIN MATCH: ${e.nombre} (cuil ${e.cuil || '—'})`); continue; }

    const periodos = e.periodos.map(([i, f]) => ({
      inicio: admin.firestore.Timestamp.fromDate(new Date(i + 'T00:00:00Z')),
      fin: admin.firestore.Timestamp.fromDate(new Date(f + 'T00:00:00Z')),
      dias: diasEntre(i, f),
    }));
    const tomados = periodos.reduce((a, p) => a + p.dias, 0);
    const diasCorresponden = Number(e.dias_g) || 0;
    const restan = diasCorresponden - tomados;

    docs.push({
      id: `${ANIO}_${emp.dni}`,
      data: {
        dni: emp.dni,
        nombre: emp.nombre || e.nombre,
        anio: ANIO,
        empresa: emp.empresa,
        area: emp.area,
        diasCorresponden,
        diasAuto: false,
        periodos,
        tomados,
        restan,
        actualizadoEn: admin.firestore.FieldValue.serverTimestamp(),
        actualizadoPorDni: 'import_excel',
      },
      _dbg: { nombre: emp.nombre || e.nombre, diasCorresponden, tomados, restan,
        nperiodos: periodos.length, tomados_h: e.tomados_h, area: emp.area },
    });
  }

  // Reporte
  console.log(`Docs a crear: ${docs.length}\n`);
  console.log('Nombre                         Corr Tom Rest P  Area           Flags');
  console.log('-'.repeat(86));
  let flagNeg = 0, flagMismatch = 0;
  for (const d of docs.sort((a, b) => a._dbg.nombre.localeCompare(b._dbg.nombre))) {
    const g = d._dbg;
    const flags = [];
    if (g.restan < 0) { flags.push('RESTAN<0'); flagNeg++; }
    if (g.tomados_h != null && Number(g.tomados_h) !== g.tomados) {
      flags.push(`tomados!=H(${g.tomados_h})`); flagMismatch++;
    }
    console.log(
      `${g.nombre.slice(0, 30).padEnd(30)} ${String(g.diasCorresponden).padStart(4)} ` +
      `${String(g.tomados).padStart(3)} ${String(g.restan).padStart(4)} ${String(g.nperiodos).padStart(2)}  ` +
      `${(g.area || '(sin area)').slice(0, 14).padEnd(14)} ${flags.join(' ')}`
    );
  }
  console.log('-'.repeat(86));
  console.log(`Total: ${docs.length} | restan<0: ${flagNeg} | tomados!=H del Excel: ${flagMismatch}`);
  if (problemas.length) {
    console.log(`\nPROBLEMAS (${problemas.length}):`);
    problemas.forEach((p) => console.log('  ' + p));
  }

  if (!APLICAR) {
    console.log('\n[DRY-RUN] No se escribio nada. Para aplicar: agregar --aplicar');
    process.exit(0);
  }

  // Aplicar en batches de 400
  console.log('\nEscribiendo...');
  let i = 0;
  while (i < docs.length) {
    const batch = db.batch();
    for (const d of docs.slice(i, i + 400)) {
      batch.set(db.collection('VACACIONES').doc(d.id), d.data);
    }
    await batch.commit();
    i += 400;
  }
  console.log(`OK: ${docs.length} docs escritos en VACACIONES.`);
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e); process.exit(1); });
