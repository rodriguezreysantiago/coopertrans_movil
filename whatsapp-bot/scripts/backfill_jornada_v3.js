/**
 * BACKFILL de historia del registro de jornada v3 → colección REGISTRO_JORNADAS.
 *
 * Usa la LÓGICA CANÓNICA ya deployada (`procesarVentana` de jornadas_v3_batch),
 * vía las credenciales del service account (ADC) — la misma que corre el cron y
 * el callable `backfillRegistrosV3`, sin duplicar nada. Idempotente: doc-id
 * determinístico `{dni}_{YYYY-MM-DD}`, re-ejecutar pisa sin duplicar.
 *
 * Por cada día procesa la ventana [día 00:00 ART, día+30h) para completar turnos
 * que cruzan medianoche, y persiste solo los turnos que INICIARON ese día (sin
 * fragmentos del día siguiente) — idéntico al callable.
 *
 * Uso:
 *   node whatsapp-bot/scripts/backfill_jornada_v3.js [dias]   # default 30
 *
 * Prereq: functions/lib/jornadas_v3_batch.js compilado + serviceAccountKey.json.
 */
const path = require('path');
const SAK = path.join(__dirname, '..', '..', 'serviceAccountKey.json');
// ADC para que el initializeApp() de setup.ts use estas credenciales (no hacemos
// initializeApp propio: evita el doble-init al requerir el módulo deployado).
process.env.GOOGLE_APPLICATION_CREDENTIALS = SAK;

const batch = require(path.join(__dirname, '..', '..', 'functions', 'lib', 'jornadas_v3_batch.js'));

const DIAS = Math.max(1, Math.min(85, Number(process.argv[2] || 30)));

const diaArt = (d) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Buenos_Aires', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
// Medianoche ART (00:00) de hace `diasAtras` días = 03:00 UTC del día ART.
function medianocheArt(diasAtras) {
  const ahoraArt = new Date(Date.now() - 3 * 60 * 60 * 1000);
  return new Date(Date.UTC(ahoraArt.getUTCFullYear(), ahoraArt.getUTCMonth(), ahoraArt.getUTCDate() - diasAtras, 3, 0, 0, 0));
}

async function main() {
  console.log(`Backfill REGISTRO_JORNADAS — ${DIAS} días (lógica canónica procesarVentana, idempotente)\n`);
  let totReg = 0, totPers = 0;
  for (let i = 1; i <= DIAS; i++) {
    const dia00 = medianocheArt(i);
    const fin = new Date(dia00.getTime() + 30 * 60 * 60 * 1000);
    const diaSig00 = medianocheArt(i - 1);
    const ymd = diaArt(dia00);
    try {
      const r = await batch.procesarVentana(dia00, fin, dia00.getTime(), diaSig00.getTime());
      totReg += r.registros; totPers += r.persistidos;
      console.log(`  ${ymd}: ${String(r.persistidos).padStart(3)} persistidos · ${r.registros} reg · ${r.choferes} chof · ${r.eventos} ev`);
    } catch (e) {
      console.log(`  ${ymd}: ERROR ${e.message}`);
    }
  }
  console.log(`\nTotal: ${totPers} registros persistidos (${totReg} reconstruidos) en ${DIAS} días.`);
  process.exit(0);
}
main().catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
