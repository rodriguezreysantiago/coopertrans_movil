# RUNBOOK — Secret Manager como fuente única + bootstrap multi-PC

**Qué resuelve:** los secrets del proyecto vivían como archivos sueltos sincronizados
por un Google Drive personal, sin audit log ni rotación. Ahora la **fuente única** es
**Google Cloud Secret Manager** (`coopertrans-movil`): acceso auditado, versionado
nativo (= rotación), y provisioning de una PC nueva sin depender del Drive.

Script: [`scripts/bootstrap_secretos.ps1`](../scripts/bootstrap_secretos.ps1).

---

## Modelo

- Cada **archivo-secreto** se guarda en Secret Manager **codificado en BASE64** (label
  `kind=file-b64`). Base64 garantiza round-trip **byte-exacto** de binarios (keystore,
  .p12, .mobileprovision) y de texto con encoding sensible (`.env` UTF-8 sin BOM) al
  pasar por PowerShell, donde stdin/stdout corrompen CRLF y bytes altos.
- Un **manifest** dentro del script mapea cada secret a su origen en el vault (para
  subir) y a su destino local (para restaurar), con una **categoría**.
- Los **6 secrets de VALOR** que ya consumen las Cloud Functions vía `defineSecret`
  (`SITRACK_USERNAME/PASSWORD`, `VOLVO_USERNAME/PASSWORD`, `TELEGRAM_BOT_TOKEN/CHAT_ID`)
  son **RAW** y este script **NO los toca**. Son una familia aparte: valor-en-vivo que
  lee el runtime de GCP, no archivos a materializar.

### Excepción honesta: la sesión de WhatsApp
`.wwebjs_auth` es un perfil Chromium mutante de varios MB — **no es una credencial
versionable**, así que **NO va a Secret Manager**. Sigue respaldada en el Drive por
[`scripts/backup_secrets_a_drive.ps1`](../scripts/backup_secrets_a_drive.ps1) (robocopy
/MIR nocturno). Al provisionar una PC dedicada se restaura del Drive o se re-escanea el QR.

---

## Las 21 secrets (categorías)

| Categoría | Secrets | Destino al restaurar |
|---|---|---|
| **dedicada** (runtime bot/scrapers) | `SA_FIREBASE_ADMIN`, `WHATSAPP_BOT_ENV`, `CACHATORE_CLAVES`, `CACHATORE_SERVICE_ENV` | rutas reales del repo (`serviceAccountKey.json`, `whatsapp-bot\.env`, `cachatore\…`) |
| **infra** | `FTP_DATOS`, `SENTRY_AUTH_TOKEN`, `SENTRY_CLIRC`, `FIREBASE_TOOLS_TOKEN` | `secretos_restaurados\…` (gitignored) |
| **build** | `ANDROID_KEYSTORE`, `ANDROID_KEY_PROPERTIES`, `IOS_APNS_AUTHKEY_*` (×2), `IOS_DIST_P12`, `IOS_DIST_CERT_P12_PASSWORD`, `IOS_PROVISION_*` (×3), `MACOS_P12`, `MACOS_KEY`, `MACOS_P12_PASSWORD`, `MACOS_PROVISION` | keystore→`android\`; resto→`secretos_restaurados\{ios,macos}\` |

`secretos_restaurados/` está en `.gitignore` — nunca se commitea.

---

## Operaciones

### Provisionar una PC nueva (bootstrap)
Requiere `gcloud` autenticado como owner / con `roles/secretmanager.secretAccessor`.

```powershell
# PC dedicada (bot + scrapers):
.\scripts\bootstrap_secretos.ps1 -Categoria dedicada -BotPcId dedicada
#   …después restaurar la sesión WhatsApp del Drive (o escanear QR).

# PC de desarrollo / build (firmar releases):
.\scripts\bootstrap_secretos.ps1 -Categoria build
#   …luego ubicar manualmente lo de secretos_restaurados\ios|macos según el RUNBOOK de release.
```

> **Caveat keystore Android:** el `.jks` se restaura en `android\coopertrans_movil.jks`,
> pero `android\key.properties` tiene `storeFile=` con una **ruta absoluta por-PC**
> (`C:/Users/<user>/keystores/…`). En una PC nueva el build falla con *"keystore file
> does not exist"* si no coinciden. El bootstrap **avisa** post-restauración si el
> `storeFile` no existe; resolvelo copiando el `.jks` a esa ruta o ajustando `storeFile`.

> **Config de Firebase (NO es secreto):** `android/app/google-services.json` y
> `ios/Runner/GoogleService-Info.plist` viven **en git** (son config de cliente, no
> credenciales). No están en Secret Manager a propósito; un `git clone` los trae.

```powershell

# Todo:
.\scripts\bootstrap_secretos.ps1
```

**OJO BOT_PC_ID** (el incidente que casi tumba el bot el 2026-06-01): el `.env` lleva un
`BOT_PC_ID` por-PC y el bot ABORTA si ve un heartbeat de otra PC. El bootstrap **fuerza**
`BOT_PC_ID` al valor de `-BotPcId` (default `dedicada`). En una PC que NO es la dedicada,
pasá `-BotPcId oficina` (o el que corresponda) explícitamente.

### Rotar un secret
1. Actualizá el archivo en el vault (o donde tengas el valor nuevo).
2. `\.scripts\bootstrap_secretos.ps1 -Subir` → agrega una **nueva versión** sólo a los
   que cambiaron (idempotente por hash; no genera version spam).
3. En la PC que lo consume: bootstrap de esa categoría + reiniciar el servicio.

### Agregar un secret nuevo
Agregá una fila al `$Manifest` (Secret/Vault/Target/Cat) y corré `-Subir`.

### Verificar integridad (SM vs vault)
```powershell
.\scripts\bootstrap_secretos.ps1 -Verificar   # hash SHA-256 de cada secret vs el vault
```

---

## Xcode Cloud (iOS) — espejo sincronizado

**Xcode Cloud NO puede leer Secret Manager** (corre en infra de Apple). Los 5 secrets
de firma iOS viven como **env vars del workflow** en App Store Connect (los consume
`ios/ci_scripts/ci_post_clone.sh`). Secret Manager es la **copia maestra**; Xcode Cloud
es un espejo que se sincroniza a mano cuando rota (el cert vence 1×/año; los profiles casi nunca).

| env var del workflow (Secret en ASC) | Secret Manager | nota |
|---|---|---|
| `IOS_DIST_CERT_P12_BASE64` | `IOS_DIST_P12` | base64 del .p12 (= valor a pegar) |
| `IOS_DIST_CERT_P12_PASSWORD` | `IOS_DIST_CERT_P12_PASSWORD` | password del .p12 (valor crudo, sin newline) |
| `IOS_DIST_PROFILE_BASE64` | `IOS_PROVISION_APPSTORE` | provisioning App Store |
| `IOS_ADHOC_PROFILE_BASE64` | `IOS_PROVISION_ADHOC` | provisioning Ad Hoc |
| `IOS_DEV_PROFILE_BASE64` | `IOS_PROVISION_DEV` | provisioning Development |

### Sincronizar / rotar el cert o un profile
1. Actualizá el material en el vault (regenerar cert/profile según el README de
   `secrets-ios/`) y corré `.\scripts\bootstrap_secretos.ps1 -Subir`.
2. Generá los valores listos para pegar:
   ```powershell
   .\scripts\bootstrap_secretos.ps1 -XcodeCloud
   ```
   Escribe cada env var a `secretos_restaurados\xcode_cloud\<ENVVAR>.txt` (gitignored).
3. App Store Connect → Xcode Cloud → tu workflow → **Environment Variables**: pegá cada
   `.txt` en su env var, marcando **Secret**. **No agregues newline.**
4. Dispará un build de prueba. **Borrá `secretos_restaurados\xcode_cloud\`** al terminar.

> No se automatiza vía App Store Connect API: el soporte para *escribir* secret env vars
> es limitado y requeriría una ASC API key (otro secret). Para una rotación anual, el
> paste manual es más robusto.

## Coexistencia con el Drive
El Drive **sigue** como backup (no se borró nada). `backup_secrets_a_drive.ps1` mantiene
en el Drive los secrets vivos de la dedicada (incl. la sesión WA, que SM no cubre). Secret
Manager es ahora la **fuente de verdad** para los 20 archivos-secreto; el Drive es la red.
Si rotás un secret, corré `-Subir` para que SM no quede atrás del Drive (`-Verificar` lo
detecta).

## Auditoría
`gcloud logging read 'resource.type=secretmanager.googleapis.com'` (o Cloud Console →
Secret Manager → cada secret → Logs) muestra quién accedió qué versión y cuándo — lo que
el Drive personal nunca dio.
