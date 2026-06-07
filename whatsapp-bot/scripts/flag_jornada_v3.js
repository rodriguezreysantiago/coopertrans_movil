/**
 * Kill-switch del registro de jornada v3: prende/apaga el cron
 * `registrarJornadasV3Diario` escribiendo el flag
 * `META/config_vigilador_v3.registro_batch_activo`. El cron lee este flag y, si
 * está en false, NO escribe nada (deploy dark). Efecto inmediato (sin redeploy).
 *
 * Uso:
 *   node whatsapp-bot/scripts/flag_jornada_v3.js on    # activar (default)
 *   node whatsapp-bot/scripts/flag_jornada_v3.js off   # desactivar (kill)
 */
const path = require('path');
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(require(path.join(__dirname, '..', '..', 'serviceAccountKey.json'))) });

const on = (process.argv[2] || 'on').toLowerCase() !== 'off';
admin.firestore().collection('META').doc('config_vigilador_v3').set({
  registro_batch_activo: on,
  actualizado_en: admin.firestore.FieldValue.serverTimestamp(),
}, { merge: true })
  .then(() => { console.log(`META/config_vigilador_v3.registro_batch_activo = ${on}`); process.exit(0); })
  .catch((e) => { console.error('ERROR:', e.message); process.exit(1); });
