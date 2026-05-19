// =============================================================================
// Migración one-shot — re-redondeo del monto chofer POR TRAMO
// =============================================================================
//
// Cambio de regla 2026-05-19: `monto_chofer_redondeado` se calcula
// redondeando CADA TRAMO al múltiplo de 5 inferior y sumando, en lugar
// de sumar bruto y redondear al final. Diferencia típica: 0-15 pesos
// por viaje (la regla nueva es ≤ vieja).
//
// Los viajes ya creados tienen el valor VIEJO persistido en
// `monto_chofer_redondeado`. La liquidación, lista, reportes leen ese
// campo. Sin esta migración, el cambio solo aplica a viajes nuevos.
//
// REGLA DE SEGURIDAD: solo migra viajes ACTIVOS NO LIQUIDADOS. Los
// liquidados quedan tal cual (al chofer ya se le pagó con el monto
// viejo y mover ese número rompería el cuadre histórico).
//
// Uso (desde tu PC):
//   cd functions
//   node _migrar_redondeo_tramos.js          # DRY-RUN, no escribe
//   node _migrar_redondeo_tramos.js --apply  # aplica cambios real
//
// Después de migrar:
//   rm functions/_migrar_redondeo_tramos.js

const admin = require('firebase-admin');
admin.initializeApp({ projectId: 'coopertrans-movil' });
const db = admin.firestore();

const APLICAR = process.argv.includes('--apply');

// Redondeo a múltiplo de 5 inmediatamente inferior. Defensivo contra
// NaN/Infinity (auditoría 2026-05-17).
function floor5(monto) {
  if (!Number.isFinite(monto)) return 0;
  return Math.floor(monto / 5) * 5;
}

// Calcula el monto bruto del chofer en UN tramo (sin pct ni redondeo).
// Espejo de `CalculosViaje.calcularMontosBrutos` en Dart.
function brutoChoferDelTramo(tramo) {
  const ts = tramo.tarifaSnapshot || tramo.tarifa_snapshot || {};
  const unidad = (ts.unidad_tarifa || ts.unidadTarifa || '').toString();
  const tarifaChofer = Number(ts.tarifa_chofer ?? ts.tarifaChofer ?? 0);
  if (unidad === 'POR_VIAJE' || unidad === 'porViaje') {
    return tarifaChofer;
  }
  // POR_TONELADA: descargados > cargados, sino 0
  const kgD = Number(tramo.kg_descargados ?? tramo.kgDescargados ?? 0);
  const kgC = Number(tramo.kg_cargados ?? tramo.kgCargados ?? 0);
  const kg = kgD > 0 ? kgD : kgC;
  if (kg <= 0) return 0;
  return tarifaChofer * (kg / 1000);
}

const COMISION_DEFAULT_PCT = 18;

/**
 * Recalcula el monto chofer redondeado de un viaje con la NUEVA regla
 * (redondeo por tramo + suma).
 *
 * @param {Array} tramos - array de tramos persistido en el doc
 * @param {number} comisionPct - 18 por default
 * @returns {{redondeado: number, bruto: number, hayAlgunPct: boolean}}
 */
function recalcularChofer(tramos, comisionPct) {
  const pct = comisionPct ?? COMISION_DEFAULT_PCT;
  let sumaRedondeada = 0;
  let sumaBruta = 0;
  let hayAlgunPct = false;
  for (const t of tramos) {
    const ts = t.tarifaSnapshot || t.tarifa_snapshot || {};
    const fijo = ts.monto_fijo_chofer ?? ts.montoFijoChofer ?? null;
    let montoTramo;
    if (fijo !== null && fijo !== undefined) {
      montoTramo = Number(fijo);
    } else {
      const bruto = brutoChoferDelTramo(t);
      montoTramo = bruto * (pct / 100);
      hayAlgunPct = true;
    }
    sumaBruta += montoTramo;
    sumaRedondeada += floor5(montoTramo);
  }
  return { redondeado: sumaRedondeada, bruto: sumaBruta, hayAlgunPct };
}

// ─── MAIN ────────────────────────────────────────────────────────────
(async () => {
  console.log(`\n${'='.repeat(70)}`);
  console.log(`MIGRACIÓN — redondeo POR TRAMO (Santiago 2026-05-19)`);
  console.log(`Modo: ${APLICAR ? '⚠️  APPLY (escribe a Firestore)' : 'DRY-RUN (no escribe)'}`);
  console.log(`${'='.repeat(70)}\n`);

  console.log('Descargando viajes activos NO liquidados...');
  const snap = await db
    .collection('VIAJES_LOGISTICA')
    .where('activo', '==', true)
    .where('liquidado', '==', false)
    .get();
  console.log(`Encontrados: ${snap.size} viajes\n`);

  const cambios = []; // { id, antes, despues, diff, chofer, fecha }
  let sinCambios = 0;
  let saltadosLiquidados = 0; // por si pasa alguno con liquidado=true que escapó

  for (const doc of snap.docs) {
    const v = doc.data();
    if (v.liquidado === true) {
      saltadosLiquidados++;
      continue;
    }
    const tramos = Array.isArray(v.tramos) ? v.tramos : [];
    if (tramos.length === 0) {
      // Viajes legacy single-tramo (pre 2026-05-11) pueden no tener
      // array tramos[]. La factory `Viaje.fromMap` los reconstruye desde
      // campos planos. Para esta migración los saltamos — el cliente al
      // editar el viaje los actualiza solo.
      continue;
    }
    const adelanto = Number(v.adelanto_monto ?? 0);
    const gastosTotal = Number(v.gastos_total ?? 0);
    const comisionPct = Number(v.comision_chofer_pct ?? COMISION_DEFAULT_PCT);
    const actual = Number(v.monto_chofer_redondeado ?? 0);
    const { redondeado } = recalcularChofer(tramos, comisionPct);
    const diff = redondeado - actual;
    if (Math.abs(diff) < 0.01) {
      sinCambios++;
      continue;
    }
    const liquidacionNueva = redondeado - adelanto + gastosTotal;
    cambios.push({
      id: doc.id,
      antes: actual,
      despues: redondeado,
      diff,
      liqAntes: Number(v.liquidacion_chofer ?? 0),
      liqDespues: liquidacionNueva,
      chofer: (v.chofer_nombre ?? `DNI ${v.chofer_dni ?? '?'}`).toString(),
      fecha: v.fecha_carga
        ? v.fecha_carga.toDate().toISOString().slice(0, 10)
        : '?',
      tramos: tramos.length,
    });
  }

  console.log(`Sin cambios:                ${sinCambios}`);
  console.log(`Cambios (regla nueva difiere): ${cambios.length}`);
  console.log(`Saltados (liquidados):      ${saltadosLiquidados}`);
  console.log('');

  if (cambios.length === 0) {
    console.log('No hay nada que migrar. Salgo.');
    process.exit(0);
  }

  // Resumen estadístico
  const totalDiff = cambios.reduce((acc, c) => acc + c.diff, 0);
  const maxBaja = cambios.reduce(
    (acc, c) => (c.diff < acc ? c.diff : acc), 0);
  const maxSuba = cambios.reduce(
    (acc, c) => (c.diff > acc ? c.diff : acc), 0);
  console.log(`Diferencia total acumulada (chofer): $${totalDiff.toFixed(0)}`);
  console.log(`Cambio más grande hacia abajo:       $${maxBaja.toFixed(0)}`);
  console.log(`Cambio más grande hacia arriba:      $${maxSuba.toFixed(0)}`);
  console.log('');

  // Muestra los primeros 20 cambios
  console.log(`${'='.repeat(70)}`);
  console.log(`Detalle (primeros 20 de ${cambios.length}):`);
  console.log(`${'='.repeat(70)}`);
  console.log(
    `${'Fecha'.padEnd(11)}${'Chofer'.padEnd(28)}` +
    `${'Tramos'.padStart(7)} ${'Antes'.padStart(10)} ${'Después'.padStart(10)} ${'Diff'.padStart(8)}`
  );
  for (const c of cambios.slice(0, 20)) {
    console.log(
      `${c.fecha.padEnd(11)}${c.chofer.slice(0, 26).padEnd(28)}` +
      `${String(c.tramos).padStart(7)} ` +
      `${c.antes.toFixed(0).padStart(10)} ` +
      `${c.despues.toFixed(0).padStart(10)} ` +
      `${(c.diff >= 0 ? '+' : '') + c.diff.toFixed(0).padStart(7)}`
    );
  }

  if (!APLICAR) {
    console.log(`\n${'='.repeat(70)}`);
    console.log(`DRY-RUN — no se escribió nada. Para aplicar:`);
    console.log(`  node _migrar_redondeo_tramos.js --apply`);
    console.log(`${'='.repeat(70)}\n`);
    process.exit(0);
  }

  // ─── APLICAR ────────────────────────────────────────────────────────
  console.log(`\n⚠️  APLICANDO ${cambios.length} cambios a Firestore...`);
  const batchSize = 400; // safe under 500 limit
  let aplicados = 0;
  for (let i = 0; i < cambios.length; i += batchSize) {
    const batch = db.batch();
    const lote = cambios.slice(i, i + batchSize);
    for (const c of lote) {
      const ref = db.collection('VIAJES_LOGISTICA').doc(c.id);
      batch.update(ref, {
        monto_chofer_redondeado: c.despues,
        liquidacion_chofer: c.liqDespues,
        // Audit trail
        actualizado_en: admin.firestore.FieldValue.serverTimestamp(),
        migrado_redondeo_tramos_2026_05_19: true,
      });
    }
    await batch.commit();
    aplicados += lote.length;
    console.log(`  Lote ${i / batchSize + 1}: ${lote.length} viajes actualizados (acumulado: ${aplicados})`);
  }

  console.log(`\n${'='.repeat(70)}`);
  console.log(`✓ Migración completa. ${aplicados} viajes actualizados.`);
  console.log(`Después de verificar, borrá el script:`);
  console.log(`  rm functions/_migrar_redondeo_tramos.js`);
  console.log(`${'='.repeat(70)}\n`);
  process.exit(0);
})();
