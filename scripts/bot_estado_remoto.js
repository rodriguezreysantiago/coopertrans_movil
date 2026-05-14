// Estado del bot WhatsApp desde cualquier PC, sin acceder a la PC
// dedicada por RDP. Lee `BOT_HEALTH/main` (el heartbeat que el bot
// escribe cada 60s) + `BOT_EVENTOS` (caídas/recuperaciones del
// watchdog) + cola de COLA_WHATSAPP, y muestra un resumen claro.
//
// Pensado para correr desde la PC personal de Santiago cuando el bot
// está en una PC dedicada — sin necesidad de RDP/TeamViewer.
//
// USO:
//   node scripts/bot_estado_remoto.js                # estado actual
//   node scripts/bot_estado_remoto.js --eventos 50   # + últimos 50 eventos
//   node scripts/bot_estado_remoto.js --json         # output JSON crudo

const path = require('path');
const fsNode = require('fs');

const botDir = path.resolve(__dirname, '..', 'whatsapp-bot');
const botNodeModules = path.join(botDir, 'node_modules');
if (!fsNode.existsSync(botNodeModules)) {
  console.error(`No existe ${botNodeModules}. Correr npm install en whatsapp-bot.`);
  process.exit(1);
}
module.paths.unshift(botNodeModules);
process.chdir(botDir);
require('dotenv').config({ quiet: true });

const admin = require('firebase-admin');
const credPath =
  process.env.FIREBASE_CREDENTIALS_PATH || '../serviceAccountKey.json';
admin.initializeApp({
  credential: admin.credential.cert(require(path.resolve(credPath))),
  projectId: process.env.FIREBASE_PROJECT_ID || 'coopertrans-movil',
});
const db = admin.firestore();

const args = process.argv.slice(2);
const wantJson = args.includes('--json');
const eventosFlagIdx = args.indexOf('--eventos');
const cantEventos =
  eventosFlagIdx >= 0 ? parseInt(args[eventosFlagIdx + 1] || '20', 10) : 20;

// ─── Helpers ──────────────────────────────────────────────────────
function fmtFecha(ts) {
  if (!ts) return '(null)';
  const d = ts.toDate ? ts.toDate() : new Date(ts);
  return new Intl.DateTimeFormat('es-AR', {
    timeZone: 'America/Argentina/Buenos_Aires',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).format(d);
}

function fmtUptime(seg) {
  if (!seg) return '0s';
  const d = Math.floor(seg / 86400);
  const h = Math.floor((seg % 86400) / 3600);
  const m = Math.floor((seg % 3600) / 60);
  const s = Math.floor(seg % 60);
  const partes = [];
  if (d) partes.push(`${d}d`);
  if (h || d) partes.push(`${h}h`);
  if (m || h || d) partes.push(`${m}m`);
  partes.push(`${s}s`);
  return partes.join(' ');
}

function fmtHace(ts) {
  if (!ts) return '(nunca)';
  const ms = ts.toMillis ? ts.toMillis() : new Date(ts).getTime();
  const diffSec = Math.floor((Date.now() - ms) / 1000);
  if (diffSec < 60) return `hace ${diffSec}s`;
  if (diffSec < 3600) return `hace ${Math.floor(diffSec / 60)}m ${diffSec % 60}s`;
  if (diffSec < 86400) {
    const h = Math.floor(diffSec / 3600);
    const m = Math.floor((diffSec % 3600) / 60);
    return `hace ${h}h ${m}m`;
  }
  return `hace ${Math.floor(diffSec / 86400)}d`;
}

// Color minimalista vía códigos ANSI. Windows Terminal y PowerShell
// 5+ los soportan nativamente.
const c = {
  reset: '\x1b[0m',
  bold: '\x1b[1m',
  dim: '\x1b[2m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  cyan: '\x1b[36m',
  gray: '\x1b[90m',
};

// ─── Main ─────────────────────────────────────────────────────────
async function main() {
  const snap = await db.collection('BOT_HEALTH').doc('main').get();
  if (!snap.exists) {
    console.log(`${c.red}❌ BOT_HEALTH/main NO existe.${c.reset}`);
    console.log('   El bot nunca arrancó, o nunca escribió heartbeat.');
    process.exit(1);
  }
  const h = snap.data();

  if (wantJson) {
    console.log(JSON.stringify(h, null, 2));
    process.exit(0);
  }

  // ─── Cabecera con health overall ─────────────────────────────
  console.log('');
  console.log(`${c.bold}${c.cyan}╔══════════════════════════════════════════════════════════╗${c.reset}`);
  console.log(`${c.bold}${c.cyan}║  ESTADO DEL BOT — Coopertrans Móvil                       ║${c.reset}`);
  console.log(`${c.bold}${c.cyan}╚══════════════════════════════════════════════════════════╝${c.reset}`);
  console.log('');

  const hbMs = h.ultimoHeartbeat?.toMillis?.() ?? 0;
  const hbAgeSeg = hbMs > 0 ? (Date.now() - hbMs) / 1000 : Infinity;
  const stale = hbAgeSeg > 5 * 60; // 5 min = stale
  const veryStale = hbAgeSeg > 10 * 60; // 10 min = caído según watchdog

  const status = veryStale
    ? `${c.red}${c.bold}🔴 CAÍDO${c.reset} (${fmtHace(h.ultimoHeartbeat)})`
    : stale
    ? `${c.yellow}🟡 STALE${c.reset} (${fmtHace(h.ultimoHeartbeat)})`
    : `${c.green}🟢 VIVO${c.reset} (${fmtHace(h.ultimoHeartbeat)})`;

  console.log(`  Estado:        ${status}`);
  console.log(`  PC:            ${c.bold}${h.pcId || '?'}${c.reset}`);
  console.log(`  Cliente WA:    ${_colorEstadoCliente(h.estadoCliente)}`);
  console.log(`  Versión bot:   ${h.bot?.version || '?'} (Node ${h.bot?.nodeVersion || '?'})`);
  console.log(`  Uptime:        ${fmtUptime(h.bot?.uptimeSegundos)}`);
  console.log(`  PID:           ${h.bot?.pid || '?'}`);
  console.log('');

  // ─── Cola ────────────────────────────────────────────────────
  const cola = h.cola || {};
  const pend = cola.pendientes || 0;
  const colaColor = pend > 50 ? c.red : pend > 20 ? c.yellow : c.green;
  console.log(`${c.bold}📨 COLA WHATSAPP${c.reset}`);
  console.log(`  Pendientes:    ${colaColor}${pend}${c.reset}` +
              (cola.reintentando ? ` (${cola.reintentando} reintentando)` : ''));
  console.log(`  Procesando:    ${cola.procesando || 0}`);
  console.log(`  Con error:     ${cola.error ? c.red + cola.error + c.reset : 0}`);
  console.log('');

  // ─── Mensajes ────────────────────────────────────────────────
  const m = h.mensajes || {};
  console.log(`${c.bold}✉️  MENSAJES${c.reset}`);
  console.log(`  Hoy:           ${m.enviadosHoy || 0} ${c.gray}(${m.fechaContadorHoy || '?'})${c.reset}`);
  console.log(`  Último envío:  ${fmtHace(m.ultimoEnviado)}` +
              (m.ultimoEnviado ? ` ${c.gray}(${fmtFecha(m.ultimoEnviado)})${c.reset}` : ''));
  console.log('');

  // ─── Errores recientes ──────────────────────────────────────
  const errores = Array.isArray(h.erroresRecientes) ? h.erroresRecientes : [];
  if (errores.length > 0) {
    console.log(`${c.bold}${c.red}⚠️  ERRORES RECIENTES (${errores.length})${c.reset}`);
    for (const e of errores.slice(0, 5)) {
      console.log(`  ${c.gray}[${fmtFecha(e.en)}]${c.reset} ${c.yellow}${e.contexto}${c.reset}: ${e.mensaje}`);
    }
    if (errores.length > 5) {
      console.log(`  ${c.gray}... y ${errores.length - 5} más (usar --json para verlos todos)${c.reset}`);
    }
    console.log('');
  }

  // ─── Cron / horario hábil / config ──────────────────────────
  const cron = h.cron || {};
  const cfg = h.config || {};
  console.log(`${c.bold}⏰ CRON & CONFIG${c.reset}`);
  console.log(`  Horario hábil: ${cfg.enHorarioHabil ? c.green + 'SÍ' + c.reset : c.gray + 'NO' + c.reset} ` +
              `(${cfg.workingHoursStart}h - ${cfg.workingHoursEnd}h ${cfg.timezone?.split('/')?.pop() || ''})`);
  console.log(`  Auto avisos:   ${cfg.autoAvisos ? c.green + 'ON' + c.reset : c.gray + 'OFF' + c.reset}`);
  console.log(`  Último ciclo:  ${fmtHace(cron.ultimoCiclo)}` +
              (cron.ultimoCicloStats
                ? ` ${c.gray}(${JSON.stringify(cron.ultimoCicloStats)})${c.reset}`
                : ''));
  console.log(`  Próximo aprox: ${fmtFecha(cron.proximoCicloAprox)} ${c.gray}(cada ${cron.intervaloMinutos}m)${c.reset}`);
  console.log('');

  // ─── Eventos de caída/recuperación ──────────────────────────
  try {
    const eventosSnap = await db.collection('BOT_EVENTOS')
      .orderBy('detectadoEn', 'desc')
      .limit(cantEventos)
      .get();
    if (!eventosSnap.empty) {
      console.log(`${c.bold}📋 EVENTOS DEL WATCHDOG (últimos ${eventosSnap.size})${c.reset}`);
      eventosSnap.forEach((d) => {
        const ev = d.data();
        const icon = ev.tipo === 'recuperado' ? '✅' : '🔴';
        const dur = ev.duracionMin ? ` ${c.gray}(${ev.duracionMin} min)${c.reset}` : '';
        const tipoColor = ev.tipo === 'recuperado' ? c.green : c.red;
        console.log(`  ${icon} ${c.gray}[${fmtFecha(ev.detectadoEn)}]${c.reset} ${tipoColor}${ev.tipo.toUpperCase()}${c.reset}${dur} ${c.gray}pc=${ev.pcId || '?'}${c.reset}`);
      });
      console.log('');
    } else {
      console.log(`${c.gray}📋 No hay eventos del watchdog registrados.${c.reset}`);
      console.log('');
    }
  } catch (e) {
    console.log(`${c.gray}📋 No se pudo leer BOT_EVENTOS: ${e.message}${c.reset}`);
    console.log('');
  }

  // ─── Diagnóstico final ──────────────────────────────────────
  console.log(`${c.bold}🩺 DIAGNÓSTICO${c.reset}`);
  if (veryStale) {
    console.log(`  ${c.red}${c.bold}El bot está CAÍDO.${c.reset} Heartbeat hace ${fmtHace(h.ultimoHeartbeat)}.`);
    console.log(`     Probable causa: PC apagada, NSSM crasheado, sin internet, sesión WA caída.`);
    console.log(`     Acción: entrar por RDP/TeamViewer y revisar el servicio CoopertransMovilBot.`);
  } else if (stale) {
    console.log(`  ${c.yellow}Heartbeat lento.${c.reset} Esperado < 2 min, llegó ${fmtHace(h.ultimoHeartbeat)}.`);
    console.log(`     Probable: Firestore lento o procesando algo pesado. Reverificar en 2-3 min.`);
  } else if (h.estadoCliente !== 'LISTO') {
    console.log(`  ${c.yellow}Bot vivo pero cliente WA en estado: ${h.estadoCliente}.${c.reset}`);
    console.log(`     Si DESCONECTADO o AUTH_FALLO: hay que reescanear QR.`);
  } else if (pend > 50) {
    console.log(`  ${c.yellow}Cola creciendo (${pend} pendientes).${c.reset} El bot está vivo pero procesando lento.`);
  } else {
    console.log(`  ${c.green}✓ Todo OK.${c.reset}`);
  }
  console.log('');

  process.exit(0);
}

function _colorEstadoCliente(estado) {
  const e = (estado || 'DESCONOCIDO').toUpperCase();
  if (e === 'LISTO') return `${c.green}${e}${c.reset}`;
  if (e === 'AUTENTICADO' || e === 'INICIANDO') return `${c.yellow}${e}${c.reset}`;
  if (e === 'DESCONECTADO' || e === 'AUTH_FALLO' || e === 'AUTH_PENDIENTE')
    return `${c.red}${e}${c.reset}`;
  return e;
}

main().catch((e) => {
  console.error('❌', e.stack || e.message);
  process.exit(1);
});
