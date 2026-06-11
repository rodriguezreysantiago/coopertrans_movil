/**
 * Cruza REPORTES_DISCREPANCIA pendientes contra REGISTRO_JORNADAS (v3) para
 * detectar cuáles ya se resuelven solos con el reconstructor a posteriori.
 *
 * Caso típico (junio 2026): el chofer reclama "paré 20 min, el sistema no lo
 * registró". El v2 efectivamente no veía la pausa (gap GSM). El v3 — que
 * combina señales de contacto/detenido + pausas encubiertas por gap+misma
 * posición — sí la captura. Este script ubica cada reporte abierto, levanta
 * el turno v3 del chofer ese día y muestra las pausas que v3 detectó.
 *
 * Heurística de veredicto (en orden):
 *   1) Si el detalle menciona una hora HH:MM y v3 detectó una pausa ≥ 15 min
 *      con inicio dentro de ±20 min de esa hora → "v3 CONFIRMA".
 *   2) Si NO hay hora explícita (caso "parado 20 min", "hace 5 min"…), pero
 *      v3 detectó una pausa ≥ 15 min que TERMINÓ entre 90 min antes y 30 min
 *      después del momento del reporte → "v3 CONFIRMA" (la pausa estaba en
 *      curso o recién había terminado cuando el chofer reportó).
 *   3) Si NADA matchea → "v3 NO CONFIRMA" (sugerencia: revisar a mano).
 *
 * Modo dry-run por default. Pasar `--aplicar` marca `estado=revisado` con
 * nota_revision = "Cerrado automático: v3 confirma <descripción>" SOLO en los
 * reportes con veredicto "v3 CONFIRMA". El resto queda pendiente.
 *
 * Uso:  node whatsapp-bot/scripts/cerrar_reportes_resueltos_por_v3.js [--aplicar]
 */
const path = require('path');
const admin = require('firebase-admin');

const APLICAR = process.argv.includes('--aplicar');
const keyPath = path.join(__dirname, '..', '..', 'serviceAccountKey.json');
admin.initializeApp({ credential: admin.credential.cert(require(keyPath)) });
const db = admin.firestore();

const TZ = { timeZone: 'America/Argentina/Buenos_Aires' };

function fechaArtIso(d) {
  // YYYY-MM-DD en ART (en-CA = ISO).
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Argentina/Buenos_Aires',
    year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(d);
}

function hhmm(d) {
  return d.toLocaleString('es-AR', { ...TZ, hour: '2-digit', minute: '2-digit' });
}

function hhmmFecha(d) {
  return d.toLocaleString('es-AR', {
    ...TZ, day: '2-digit', month: '2-digit',
    hour: '2-digit', minute: '2-digit',
  });
}

// Extrae horas HH:MM o H:MM mencionadas en un texto. Tolera puntos como
// separador ("13.50") porque los choferes a menudo escriben así.
function horasDelTexto(txt) {
  const re = /(\d{1,2})[:\.](\d{2})/g;
  const out = [];
  let m;
  while ((m = re.exec(txt || '')) !== null) {
    const h = parseInt(m[1], 10);
    const min = parseInt(m[2], 10);
    if (h >= 0 && h <= 23 && min >= 0 && min <= 59) {
      out.push({ h, min, label: `${String(h).padStart(2,'0')}:${String(min).padStart(2,'0')}` });
    }
  }
  return out;
}

// True si la pausa v3 [pInicio..pFin] cae cerca de la hora reclamada (±tolMs).
function pausaCercaDe(pInicio, claimH, claimMin, fechaArt, tolMs = 20 * 60 * 1000) {
  // Construimos el ms ART de la hora reclamada usando la fecha del turno.
  // ART = UTC-3 fijo → fecha ART YYYY-MM-DD a esa hora = `${YYYY-MM-DDT${HH:mm}:00-03:00`.
  const iso = `${fechaArt}T${String(claimH).padStart(2,'0')}:${String(claimMin).padStart(2,'0')}:00-03:00`;
  const claimMs = Date.parse(iso);
  return Math.abs(pInicio - claimMs) <= tolMs;
}

async function pausasV3DelDia(dni, fechaArt) {
  // Hay 1+ docs por (chofer, día) si hubo 2 turnos. Concatenamos pausas.
  const snap = await db.collection('REGISTRO_JORNADAS')
    .where('chofer_dni', '==', dni).where('fecha', '==', fechaArt).get();
  const pausas = [];
  for (const d of snap.docs) {
    const dat = d.data();
    for (const p of (dat.pausas || [])) {
      const inicio = p.inicio?.toMillis?.() ?? 0;
      const fin = p.fin?.toMillis?.() ?? 0;
      pausas.push({
        turnoId: d.id,
        inicio, fin,
        durSeg: p.dur_seg ?? Math.round((fin - inicio) / 1000),
        origen: p.origen,
        confianza: p.confianza,
        lat: p.lat, lng: p.lng,
        cierraBloque: p.cierra_bloque,
      });
    }
  }
  return pausas.sort((a, b) => a.inicio - b.inicio);
}

function veredicto(detalle, fechaArt, pausas, reporteMs) {
  // Solo pausas "operativamente relevantes" (≥ 15 min → cierran bloque o
  // están muy cerca del umbral del reclamo del chofer).
  const candidatas = pausas.filter((p) => p.durSeg >= 15 * 60);
  if (candidatas.length === 0) {
    return { sugerencia: 'NO_CONFIRMA', matches: [], razon: 'v3 no detectó pausas ≥15 min ese día' };
  }

  // Heurística 1 — HORA EXPLÍCITA: el chofer escribió HH:MM o H:MM en su
  // mensaje. Aceptamos una pausa que arranca dentro de ±20 min de esa hora.
  // Las pausas suelen ser únicas, así que si hay un hit fuerte, lo usamos.
  const horas = horasDelTexto(detalle);
  const matchesHora = [];
  for (const claim of horas) {
    for (const p of candidatas) {
      if (pausaCercaDe(p.inicio, claim.h, claim.min, fechaArt)) {
        matchesHora.push({ claim: claim.label, pausa: p });
      }
    }
  }
  if (matchesHora.length > 0) {
    return {
      sugerencia: 'CONFIRMA',
      via: 'hora_explícita',
      matches: matchesHora,
      notaCierre: descMatches(matchesHora),
    };
  }

  // Heurística 2 — RECIENCIA: el chofer reportó SIN escribir hora exacta
  // ("parado 20 min", "hace 5 min"…). Si v3 detectó una pausa ≥ 15 min cuyo
  // FIN cae entre 90 min antes del reporte y 30 min después → la pausa
  // estaba en curso o recién terminó al reportar. Match probable.
  const VENTANA_ANTES_MS = 90 * 60 * 1000;
  const VENTANA_DESPUES_MS = 30 * 60 * 1000;
  const matchesRec = candidatas.filter((p) => {
    const fin = p.fin;
    return fin >= reporteMs - VENTANA_ANTES_MS && fin <= reporteMs + VENTANA_DESPUES_MS;
  }).map((p) => ({ claim: '(reciencia)', pausa: p }));
  if (matchesRec.length > 0) {
    return {
      sugerencia: 'CONFIRMA',
      via: 'reciencia',
      matches: matchesRec,
      notaCierre: descMatches(matchesRec),
    };
  }

  return {
    sugerencia: 'NO_CONFIRMA',
    matches: [],
    razon: horas.length > 0
      ? 'v3 detectó pausas pero ninguna cerca de la hora reclamada (±20 min) ni del momento del reporte'
      : 'v3 detectó pausas pero ninguna cerca del momento del reporte (–90/+30 min del fin)',
  };
}

function descMatches(matches) {
  // Mismo doc/pausa puede entrar 2 veces si hay 2 claims que matchean → dedupe.
  const vistos = new Set();
  const out = [];
  for (const m of matches) {
    const k = `${m.pausa.inicio}-${m.pausa.fin}`;
    if (vistos.has(k)) continue;
    vistos.add(k);
    const p = m.pausa;
    out.push(`${hhmm(new Date(p.inicio))}→${hhmm(new Date(p.fin))} ` +
      `(${Math.round(p.durSeg / 60)} min, origen=${p.origen}, confianza=${p.confianza})`);
  }
  return out.join(' · ');
}

async function main() {
  // Sin orderBy(creado_en) en el server para no pedir un índice compuesto
  // nuevo — 6 reportes, los ordenamos en cliente.
  const snap = await db.collection('REPORTES_DISCREPANCIA')
    .where('estado', '==', 'pendiente').get();
  if (snap.empty) {
    console.log('Sin reportes pendientes.');
    return;
  }
  const docs = [...snap.docs].sort((a, b) =>
    (b.data().creado_en?.toMillis?.() ?? 0) -
    (a.data().creado_en?.toMillis?.() ?? 0)
  );
  console.log(`\nReportes pendientes: ${docs.length}\n${'═'.repeat(70)}\n`);

  const cerrar = [];
  for (const d of docs) {
    const r = d.data();
    const creadoMs = r.creado_en?.toMillis?.() ?? Date.now();
    let fechaArt = fechaArtIso(new Date(creadoMs));
    // Los reportes auto-generados (origen=parada_reportada_auto) se crean el día
    // DESPUÉS de la parada — el cron de cruce corre 07:00 sobre las paradas de la
    // noche anterior. Buscar v3 por la fecha de CREACIÓN miraría el día equivocado
    // (ej. parada del 08-06 → reporte creado 09-06 → buscaba v3 del 09); usamos la
    // fecha real de la PARADA (PARADAS_REPORTADAS/{parada_id}). Fix 2026-06-11.
    if (r.origen === 'parada_reportada_auto' && r.parada_id) {
      try {
        const pSnap = await db.collection('PARADAS_REPORTADAS').doc(r.parada_id).get();
        const pd = pSnap.exists ? pSnap.data() : null;
        if (pd?.fecha) fechaArt = pd.fecha;
        else if (pd?.inicio_ms) fechaArt = fechaArtIso(new Date(pd.inicio_ms));
      } catch (_) { /* si falla la lectura de la parada, queda la fecha de creación */ }
    }
    console.log(`━━━ ${d.id} ━━━`);
    console.log(`Chofer:  ${r.chofer_nombre || '?'} (DNI ${r.chofer_dni || '?'})`);
    console.log(`Creado:  ${hhmmFecha(new Date(creadoMs))}`);
    console.log(`Tema:    ${r.tema || '—'}`);
    console.log(`Detalle: ${r.detalle || '—'}`);

    const pausas = await pausasV3DelDia(r.chofer_dni, fechaArt);
    if (pausas.length === 0) {
      console.log(`Pausas v3 (${fechaArt}): NINGUNA — no hay turno v3 del chofer ese día.\n`);
      continue;
    }
    console.log(`Pausas v3 (${fechaArt}):`);
    for (const p of pausas) {
      const min = Math.round(p.durSeg / 60);
      console.log(`  • ${hhmm(new Date(p.inicio))}→${hhmm(new Date(p.fin))} · ${min} min · ${p.origen} · conf=${p.confianza}${p.cierraBloque ? ' · CIERRA BLOQUE' : ''}`);
    }

    const v = veredicto(r.detalle || '', fechaArt, pausas, creadoMs);
    console.log(`Veredicto: ${v.sugerencia === 'CONFIRMA' ? '✅' : '⚠️ '} ${v.sugerencia}${v.via ? ` (vía ${v.via})` : ''}`);
    if (v.sugerencia === 'CONFIRMA') {
      console.log(`  Matches: ${v.notaCierre}`);
      cerrar.push({ id: d.id, nota: v.notaCierre, chofer: r.chofer_nombre, via: v.via });
    } else {
      console.log(`  Razón: ${v.razon}`);
    }
    console.log();
  }

  console.log('═'.repeat(70));
  console.log(`Resumen: ${cerrar.length} reportes para cerrar automático` +
    `${cerrar.length > 0 ? ` (${cerrar.map((c) => c.chofer || c.id).join(', ')})` : ''}.`);
  if (!APLICAR) {
    console.log('Modo dry-run. Para aplicar, agregá --aplicar.');
    return;
  }
  if (cerrar.length === 0) return;
  for (const c of cerrar) {
    await db.collection('REPORTES_DISCREPANCIA').doc(c.id).update({
      estado: 'revisado',
      // v3 confirma la pausa reclamada → el reclamo era CIERTO. Setear el
      // veredicto (además de cerrar) dispara la devolución por WhatsApp al
      // chofer (CF onReporteDiscrepanciaRevisado) para los reclamos directos.
      veredicto: 'cierto',
      nota_revision:
        `Cerrado automático ${fechaArtIso(new Date())}: el registro v3 (a ` +
        `posteriori) ya refleja la(s) pausa(s) reclamada(s). Detalle v3: ${c.nota}.`,
      revisado_por: 'BOT_AUTO_V3',
      revisado_en: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(`✓ Cerrado: ${c.id}`);
  }
  console.log('\nListo.');
}

main().then(() => process.exit(0)).catch((e) => {
  console.error('ERROR:', e.message);
  process.exit(1);
});
