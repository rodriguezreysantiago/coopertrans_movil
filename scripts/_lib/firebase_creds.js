// Helper compartido para resolver el path de serviceAccountKey.json
// con prioridad multi-PC.
//
// Política multi-PC 2026-05-28: cualquier PC con el Drive sincronizado
// puede correr scripts admin sin pasos manuales de restauración. El
// orden de búsqueda es:
//
//   1. process.env.GOOGLE_APPLICATION_CREDENTIALS  (override explícito)
//   2. process.env.FIREBASE_CREDENTIALS_PATH       (override legacy)
//   3. Drive  G:/Mi unidad/ClaudeCodeSync/secrets/firebase/serviceAccountKey.json
//   4. Repo local  <repo>/serviceAccountKey.json
//
// Setea `process.env.GOOGLE_APPLICATION_CREDENTIALS` al path encontrado
// para que `admin.initializeApp()` lo use automáticamente. También
// exporta `credPath` por si el caller necesita el path absoluto.
//
// USO:
//   const { credPath } = require('./_lib/firebase_creds');
//   const admin = require(.../firebase-admin);
//   admin.initializeApp();   // usa GOOGLE_APPLICATION_CREDENTIALS solo

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const DRIVE_PATH = 'G:\\Mi unidad\\ClaudeCodeSync\\secrets\\firebase\\serviceAccountKey.json';

const candidatos = [
  process.env.GOOGLE_APPLICATION_CREDENTIALS,
  process.env.FIREBASE_CREDENTIALS_PATH,
  DRIVE_PATH,
  path.join(REPO_ROOT, 'serviceAccountKey.json'),
].filter((p) => p && p.trim());

let credPath = null;
for (const p of candidatos) {
  try {
    if (fs.existsSync(p)) {
      credPath = path.resolve(p);
      break;
    }
  } catch (_) { /* ignore */ }
}

if (!credPath) {
  console.error('[firebase_creds] No encuentro serviceAccountKey.json. Probé:');
  for (const p of candidatos) console.error('  - ' + p);
  console.error('Bajalo de Firebase Console > Project Settings > Service Accounts');
  console.error('y dejalo en cualquiera de esos paths (preferido: Drive).');
  process.exit(1);
}

process.env.GOOGLE_APPLICATION_CREDENTIALS = credPath;

module.exports = { credPath };
