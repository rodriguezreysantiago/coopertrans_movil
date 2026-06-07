/**
 * PASO 0 (solo lectura): ¿la cuenta Sitrack de Vecchi recibe los eventos NATIVOS
 * de control de jornada/conducción/turno? Si sí, el vigilador puede consumirlos
 * en vez de reconstruir todo a mano. Cuenta, sobre toda la colección, cuántos
 * eventos hay de cada event_id "de jornada".
 */
const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(require(path.join(__dirname, '..', '..', 'serviceAccountKey.json'))) });
const db = admin.firestore();

// event_id de control de jornada / conducción / turno / descanso / actividad
const JORNADA_IDS = [
  152, 153, 154, 155, 190, 191, 513, 514, 565, 566, 904, 960, 1015,
  1239, 1242, 1243, 1244, 1245, 1246, 1020, 1022, 1028, 1030, 1038,
];
const NOMBRES = {
  152: 'Conduccion continua excedida', 153: 'Conduccion diaria excedida',
  154: 'Inicio conduccion horario no permitido', 155: 'Descanso nocturno insuficiente',
  190: 'Inicio exceso de conduccion', 191: 'Fin exceso de conduccion',
  513: 'Conduccion continua excedida (4h)', 514: 'Conduccion continua excedida (5h)',
  565: 'Inicio de turno', 566: 'Fin de turno', 904: 'Fin conduccion horario no permitido',
  960: 'Preaviso conduccion continua', 1015: 'Preaviso conduccion diaria',
  1239: 'Descanso proporcional cumplido', 1242: 'Conduccion continua excedida 1',
  1243: 'Conduccion continua excedida 2', 1244: 'Preaviso conduccion continua 1',
  1245: 'Preaviso conduccion continua 2', 1246: 'Descanso continuo cumplido',
  1020: 'Inicio hoja de ruta', 1022: 'Conduccion', 1028: 'Carga',
  1030: 'Inicia Descarga', 1038: 'Fin hoja de ruta',
};

async function main() {
  console.log('Buscando eventos de jornada en SITRACK_EVENTOS (toda la colección, ~90d TTL)...\n');
  const snap = await db.collection('SITRACK_EVENTOS').where('event_id', 'in', JORNADA_IDS).limit(10000).get();
  console.log(`Eventos de jornada encontrados: ${snap.size}\n`);
  const cuenta = {};
  const dnis = {};
  snap.forEach(d => {
    const x = d.data();
    const id = x.event_id;
    cuenta[id] = (cuenta[id] || 0) + 1;
    (dnis[id] = dnis[id] || new Set()).add(String(x.driver_dni || ''));
  });
  console.log('event_id | count | choferes | nombre');
  console.log('-'.repeat(70));
  JORNADA_IDS.sort((a, b) => a - b).forEach(id => {
    const c = cuenta[id] || 0;
    const ch = dnis[id] ? dnis[id].size : 0;
    const flag = c > 0 ? '✅' : '— ';
    console.log(`${flag} ${String(id).padStart(4)} | ${String(c).padStart(5)} | ${String(ch).padStart(3)} chof | ${NOMBRES[id] || '?'}`);
  });
  const presentes = JORNADA_IDS.filter(id => (cuenta[id] || 0) > 0);
  console.log(`\nResumen: ${presentes.length}/${JORNADA_IDS.length} tipos de jornada PRESENTES en la cuenta.`);
  console.log(presentes.length === 0
    ? '=> El modulo de jornada de Sitrack NO esta activo. Habria que pedir activarlo (palanca grande).'
    : '=> Hay eventos de jornada nativos. Evaluar consumirlos directo.');
  process.exit(0);
}
main().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
