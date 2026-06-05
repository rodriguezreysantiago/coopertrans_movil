// Validación rápida de las tools nuevas del agente contra datos REALES:
// replica las queries de adelantos_pendientes y listar_empleados_por_rol para
// confirmar que los campos/filtros son correctos (no vacío por nombre de campo
// mal). NO escribe nada.
const path = require('path');
const fsNode = require('fs');
const admin = require('firebase-admin');
const credPath = process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
const absPath = path.resolve(credPath);
if (!fsNode.existsSync(absPath)) { console.error(`No encuentro key en ${absPath}`); process.exit(1); }
admin.initializeApp({ credential: admin.credential.cert(require(absPath)), projectId: 'coopertrans-movil' });
const db = admin.firestore();

(async () => {
  // Desglose crudo de ADELANTOS_CHOFER para entender el campo `pagado`.
  const all = await db.collection('ADELANTOS_CHOFER').get();
  const cnt = { total: all.size, pagadoFalse: 0, pagadoTrue: 0, pagadoAusente: 0, eliminado: 0 };
  const tipos = {};
  all.forEach((d) => {
    const a = d.data();
    tipos[typeof a.pagado] = (tipos[typeof a.pagado] || 0) + 1;
    if (a.eliminado === true) cnt.eliminado++;
    if (a.pagado === true) cnt.pagadoTrue++;
    else if (a.pagado === false) cnt.pagadoFalse++;
    else cnt.pagadoAusente++;
  });
  console.log('=== DESGLOSE ADELANTOS_CHOFER ===');
  console.log(JSON.stringify(cnt), '  typeof pagado:', JSON.stringify(tipos));
  // Muestra de 5 docs (campos clave) para ver la forma real.
  all.docs.slice(0, 5).forEach((d) => {
    const a = d.data();
    console.log(`  ${a.chofer_nombre || a.chofer_dni}: pagado=${JSON.stringify(a.pagado)} eliminado=${JSON.stringify(a.eliminado)} monto=${a.monto}`);
  });

  // Los 6 con pagado=false (crudo): ver su `eliminado`.
  console.log('\n-- docs con pagado===false (del .get general) --');
  all.docs.map((d) => d.data()).filter((a) => a.pagado === false).forEach((a) => {
    console.log(`  ${a.chofer_nombre || a.chofer_dni}: eliminado=${JSON.stringify(a.eliminado)} monto=${a.monto}`);
  });

  // adelantos_pendientes: where pagado==false, filtrar eliminado.
  const snap = await db.collection('ADELANTOS_CHOFER').where('pagado', '==', false).get();
  console.log(`\nwhere('pagado','==',false) trajo: ${snap.docs.length} docs (antes de filtrar eliminado)`);
  const pend = snap.docs.map((d) => d.data()).filter((a) => a.eliminado !== true);
  let total = 0; for (const a of pend) total += Number(a.monto) || 0;
  console.log(`\n=== adelantos_pendientes ===`);
  console.log(`Pendientes: ${pend.length}  total $${total.toLocaleString('es-AR')}`);
  pend.slice(0, 8).forEach((a) => console.log(`  ${(a.chofer_nombre || a.chofer_dni)} — $${(Number(a.monto) || 0).toLocaleString('es-AR')}`));

  // listar_empleados_por_rol: where ROL==X, filtrar ACTIVO.
  for (const rol of ['ADMIN', 'SUPERVISOR']) {
    const e = await db.collection('EMPLEADOS').where('ROL', '==', rol).get();
    const nombres = e.docs.map((d) => d.data()).filter((x) => x.ACTIVO !== false).map((x) => x.NOMBRE).sort();
    console.log(`\n=== listar_empleados_por_rol(${rol}) ===  ${nombres.length}`);
    console.log('  ' + nombres.join(', '));
  }
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
