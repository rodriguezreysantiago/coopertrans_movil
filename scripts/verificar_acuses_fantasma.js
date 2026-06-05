// Verificacion final post-fix (15e3a2e, push 12:26 ART). Campos correctos.

const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(
  require(path.resolve(__dirname, '..', 'serviceAccountKey.json'))
)});
const db = admin.firestore();

const HOY = new Date().toISOString().slice(0, 10);
const FIX = new Date('2026-06-05T15:26:04Z'); // 12:26 ART
const fmt = (d) => new Date(d.getTime() - 3 * 3600 * 1000)
  .toISOString().replace('T', ' ').slice(0, 19);

(async () => {
  console.log(`HOY=${HOY}  FIX=${fmt(FIX)} ART  AHORA=${fmt(new Date())} ART\n`);

  // 1) BOT_ACUSES de hoy — ya vimos: ultimo a las 11:47, ninguno post-fix.
  const acusesHoy = await db.collection('BOT_ACUSES')
    .where('enviado_en', '>=', admin.firestore.Timestamp.fromDate(new Date(`${HOY}T03:00:00Z`)))
    .orderBy('enviado_en', 'desc').get();
  const postFix = acusesHoy.docs.filter((d) => d.data().enviado_en.toDate() > FIX);
  console.log(`[1] BOT_ACUSES hoy: ${acusesHoy.size} total  /  post-fix: ${postFix.length}`);
  if (acusesHoy.size > 0) {
    const ult = acusesHoy.docs[0].data();
    console.log(`    ultimo: ${fmt(ult.enviado_en.toDate())} ART (DNI ${ult.dni})`);
  }

  // 2) WHATSAPP_HISTORICO — mensajes entregados hoy. Campos: registrado_en, mensaje.
  const hist = await db.collection('WHATSAPP_HISTORICO')
    .where('registrado_en', '>=', admin.firestore.Timestamp.fromDate(new Date(`${HOY}T03:00:00Z`)))
    .orderBy('registrado_en', 'desc').limit(1000).get();
  console.log(`\n[2] WHATSAPP_HISTORICO hoy: ${hist.size} mensajes`);

  // Clasificar: acuses (texto = 'canal automatico'), avisos del vigilador, otros
  const acusesHist = [];
  const avisosVigPost = [];
  const avisosVigPre = [];
  for (const d of hist.docs) {
    const x = d.data();
    const ts = x.registrado_en.toDate();
    const m = String(x.mensaje || '');
    if (/canal autom|Tu mensaje me lleg|sistema autom|mensaje autom/i.test(m)) {
      acusesHist.push({ ts, m, x });
    }
    if (/manejando seguido|descans[áa] un m[íi]nimo/i.test(m)) {
      if (ts > FIX) avisosVigPost.push({ ts, m, x });
      else avisosVigPre.push({ ts, m, x });
    }
  }
  console.log(`    acuses automaticos hoy: ${acusesHist.length}  (post-fix: ${
    acusesHist.filter((a) => a.ts > FIX).length})`);
  console.log(`    avisos vigilador hoy : pre-fix=${avisosVigPre.length}  post-fix=${avisosVigPost.length}`);

  // 3) Mostrar avisos del vigilador post-fix (con destinatario)
  if (avisosVigPost.length > 0) {
    console.log('\n[3] Avisos del vigilador POST-FIX (a quien le llego):');
    for (const a of avisosVigPost.slice(0, 10)) {
      const dest = a.x.destinatario_id || a.x.telefono || '?';
      console.log(`    ${fmt(a.ts)} -> ${String(dest).padEnd(18)} "${a.m.slice(0, 70).replace(/\n/g, ' ')}..."`);
    }
  }

  // 4) Mensajes salientes del bot post-fix (cualquiera) — ver si el bot mando algo
  const todos = hist.docs.filter((d) => d.data().registrado_en.toDate() > FIX);
  console.log(`\n[4] Mensajes (salientes/entrantes) post-fix: ${todos.length}`);
  for (const d of todos.slice(0, 8)) {
    const x = d.data();
    const ts = fmt(x.registrado_en.toDate());
    const dest = x.destinatario_id || x.telefono || '?';
    const m = String(x.mensaje || '').slice(0, 60).replace(/\n/g, ' ');
    const origen = x.origen || '?';
    console.log(`    ${ts}  ${origen.padEnd(28)} -> ${String(dest).padEnd(14)} "${m}..."`);
  }

  // VEREDICTO
  console.log('\n=== VEREDICTO ===');
  if (avisosVigPost.length > 0 && acusesHist.filter((a) => a.ts > FIX).length === 0) {
    console.log(`OK FUERTE: ${avisosVigPost.length} avisos del vigilador post-fix, 0 acuses fantasma.`);
    console.log('El fix esta funcionando en vivo.');
  } else if (avisosVigPost.length === 0 && todos.length === 0) {
    console.log('No hubo trafico saliente del bot post-fix -> el fix esta DESPLEGADO');
    console.log('pero no se pudo probar contra el patron exacto del bug. El bot pulla');
    console.log('cada <=5min y reinicia si tocaste whatsapp-bot/** -> a las 12:31 ART');
    console.log('a mas tardar el servicio NSSM ya tenia el fix.');
  } else if (avisosVigPost.length === 0 && todos.length > 0) {
    console.log(`Hubo ${todos.length} mensajes post-fix pero ningun aviso del vigilador.`);
    console.log('No prueba el patron exacto del bug, pero tampoco hubo acuses fantasma.');
  } else {
    const acPF = acusesHist.filter((a) => a.ts > FIX);
    console.log(`REGRESION: ${acPF.length} acuses POST-FIX:`);
    acPF.forEach((a) => console.log(`   ${fmt(a.ts)} -> ${a.x.destinatario_id}`));
  }
  process.exit(0);
})().catch((e) => { console.error('ERROR:', e); process.exit(1); });
