// Tests del builder de resumen diario "vencimientos próximos a vencer"
// que va al encargado de documentación (Giagante Guillermo).
//
// Cubre: silencio cuando no hay items, secciones que aparecen solo si
// tienen contenido, agrupado por chofer/patente/empresa, etiquetas
// "vence hoy" / "vence mañana" / "en N días".

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildResumenVencimientosProximos,
} = require('../src/aviso_vencimientos_proximos_builder');

// Decisión Santiago 2026-05-09: el contrato cambió de "devolver null
// cuando no hay items" a "siempre devolver mensaje 'sin novedades'".
// El silencio era ambiguo — confirmar con un mensaje elimina la duda.
//
// Update 2026-05-18: el mensaje ahora muestra DOS ventanas distintas:
// personal/vehiculos ≤15 dias, empresas ≤30 dias. El builder elige el
// titulo segun los items presentes.
test('sin items en ningún universo → mensaje "sin novedades"', () => {
  const m = buildResumenVencimientosProximos({
    destinatarioNombre: 'Guillermo',
    itemsPersonal: [],
    itemsVehiculos: [],
    itemsEmpresas: [],
  });
  assert.match(m, /Sin vencimientos próximos/);
  assert.match(m, /Personal y vehículos en los próximos 15 días/);
  assert.match(m, /Empresas y seguros en los próximos 30 días/);
  assert.match(m, /Hola Guillermo/);
});

test('soporta arrays nulos/undefined sin romperse', () => {
  const m = buildResumenVencimientosProximos({
    destinatarioNombre: null,
    itemsPersonal: undefined,
    itemsVehiculos: null,
    itemsEmpresas: undefined,
  });
  assert.match(m, /Sin vencimientos próximos/);
  assert.match(m, /^Hola\./m);
});

test('mensaje incluye saludo, fecha del día y total cuando hay items', () => {
  const m = buildResumenVencimientosProximos({
    destinatarioNombre: 'Guillermo',
    itemsPersonal: [
      { chofer: 'Pérez Juan', etiqueta: 'Licencia de Conducir', fecha: '2026-05-12', dias: 4 },
    ],
    itemsVehiculos: [],
    itemsEmpresas: [],
  });
  assert.ok(m.startsWith('Hola Guillermo.'));
  assert.match(m, /Resumen de vencimientos —/);
  // Solo personal/vehiculos -> titulo con "≤15 días"
  assert.match(m, /1 vencimiento próximo en personal y vehículos \(≤15 días\)/);
});

test('plural cuando hay >1 item en total', () => {
  const m = buildResumenVencimientosProximos({
    destinatarioNombre: 'Gui',
    itemsPersonal: [
      { chofer: 'A', etiqueta: 'Licencia', fecha: '2026-05-10', dias: 2 },
      { chofer: 'B', etiqueta: 'Licencia', fecha: '2026-05-11', dias: 3 },
    ],
    itemsVehiculos: [],
    itemsEmpresas: [],
  });
  assert.match(m, /2 vencimientos próximos en personal y vehículos/);
});

test('mix personal/vehiculos + empresas muestra las 2 ventanas en el titulo', () => {
  const m = buildResumenVencimientosProximos({
    destinatarioNombre: 'Gui',
    itemsPersonal: [
      { chofer: 'A', etiqueta: 'Licencia', fecha: '2026-05-10', dias: 2 },
    ],
    itemsVehiculos: [],
    itemsEmpresas: [
      { empresa: 'Vecchi', etiqueta: 'Póliza ART', fecha: '2026-05-25', dias: 17 },
    ],
  });
  assert.match(m, /personal\/vehículos ≤15 días, empresas ≤30 días/);
});

test('solo empresas muestra titulo con "≤30 días"', () => {
  const m = buildResumenVencimientosProximos({
    destinatarioNombre: null,
    itemsPersonal: [],
    itemsVehiculos: [],
    itemsEmpresas: [
      { empresa: 'Vecchi', etiqueta: 'Póliza ART', fecha: '2026-05-25', dias: 17 },
    ],
  });
  assert.match(m, /1 vencimiento próximo en empresas y seguros \(≤30 días\)/);
});

test('etiquetas de días: hoy / mañana / en N días', () => {
  const m = buildResumenVencimientosProximos({
    destinatarioNombre: null,
    itemsPersonal: [
      { chofer: 'A', etiqueta: 'X', fecha: '2026-05-08', dias: 0 },
      { chofer: 'B', etiqueta: 'Y', fecha: '2026-05-09', dias: 1 },
      { chofer: 'C', etiqueta: 'Z', fecha: '2026-05-13', dias: 5 },
    ],
    itemsVehiculos: [],
    itemsEmpresas: [],
  });
  assert.match(m, /vence hoy/);
  assert.match(m, /vence mañana/);
  assert.match(m, /en 5 días/);
});

test('secciones aparecen sólo si tienen contenido', () => {
  // Solo personal
  const m1 = buildResumenVencimientosProximos({
    destinatarioNombre: null,
    itemsPersonal: [
      { chofer: 'A', etiqueta: 'Licencia', fecha: '2026-05-10', dias: 2 },
    ],
    itemsVehiculos: [],
    itemsEmpresas: [],
  });
  assert.match(m1, /\*PERSONAL\*/);
  assert.doesNotMatch(m1, /\*VEHÍCULOS\*/);
  assert.doesNotMatch(m1, /\*EMPRESAS Y SEGUROS\*/);

  // Solo empresas
  const m2 = buildResumenVencimientosProximos({
    destinatarioNombre: null,
    itemsPersonal: [],
    itemsVehiculos: [],
    itemsEmpresas: [
      { empresa: 'Vecchi Ariel', etiqueta: 'SCVO', fecha: '2026-05-11', dias: 3 },
    ],
  });
  assert.doesNotMatch(m2, /\*PERSONAL\*/);
  assert.doesNotMatch(m2, /\*VEHÍCULOS\*/);
  assert.match(m2, /\*EMPRESAS Y SEGUROS\*/);
});

test('agrupa por chofer / patente / empresa con bullets', () => {
  const m = buildResumenVencimientosProximos({
    destinatarioNombre: null,
    itemsPersonal: [
      { chofer: 'Pérez Juan', etiqueta: 'Licencia', fecha: '2026-05-10', dias: 2 },
      { chofer: 'Pérez Juan', etiqueta: 'Preocupacional', fecha: '2026-05-12', dias: 4 },
    ],
    itemsVehiculos: [
      { patente: 'AA111BB', tipoUnidad: 'TRACTOR', etiqueta: 'RTO', fecha: '2026-05-09', dias: 1 },
      { patente: 'AA111BB', tipoUnidad: 'TRACTOR', etiqueta: 'Seguro', fecha: '2026-05-13', dias: 5 },
    ],
    itemsEmpresas: [
      { empresa: 'Vecchi Ariel', etiqueta: 'Póliza ART', fecha: '2026-05-11', dias: 3 },
      { empresa: 'Vecchi Ariel', etiqueta: 'SCVO', fecha: '2026-05-14', dias: 6 },
    ],
  });
  // Cada bloque tiene UNA cabecera (chofer/patente/empresa) y dos bullets.
  const matchesPersonal = m.match(/👤 \*Pérez Juan\*/g) || [];
  const matchesPatente = m.match(/🚛 \*AA111BB\*/g) || [];
  const matchesEmpresa = m.match(/🏢 \*Vecchi Ariel\*/g) || [];
  assert.equal(matchesPersonal.length, 1);
  assert.equal(matchesPatente.length, 1);
  assert.equal(matchesEmpresa.length, 1);
  // 6 bullets en total (2 personal + 2 vehículo + 2 empresa).
  const bullets = m.match(/   • /g) || [];
  assert.equal(bullets.length, 6);
});

test('nombre destinatario sin saludo cuando es null/vacío', () => {
  const m = buildResumenVencimientosProximos({
    destinatarioNombre: null,
    itemsPersonal: [
      { chofer: 'X', etiqueta: 'Y', fecha: '2026-05-10', dias: 2 },
    ],
    itemsVehiculos: [],
    itemsEmpresas: [],
  });
  assert.ok(m.startsWith('Hola.\n\n'));
});
