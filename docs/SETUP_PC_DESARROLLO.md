# Setup de PC de desarrollo nueva

Cómo dejar una PC Windows nueva lista para **desarrollar, validar, deployar y
releasear** Coopertrans Móvil.

Este doc cubre el **toolchain**. Para la **restauración de secrets** (keystore,
tokens, creds) ver `README_RESTAURACION.md` en el Drive
(`G:\Mi unidad\ClaudeCodeSync\secrets\`).

Última verificación end-to-end: **2026-05-28** (PC nueva, user `santi`).

---

## Orden recomendado

1. Clonar repos (ver README_RESTAURACION del Drive §1).
2. Instalar el toolchain (abajo).
3. Restaurar secrets (README_RESTAURACION del Drive §2).
4. `flutter pub get` + `npm ci` en `functions/` y `whatsapp-bot/`.
5. Validar (sección **Verificación**).

---

## Toolchain

| Herramienta | Versión | Cómo | Para qué |
|---|---|---|---|
| Git (+ login GitHub) | — | push directo a `main` | repo |
| **Flutter** | **3.44.0 (pineado)** | ver nota | app Win/Android/iOS/web |
| **Node.js** | **22** (vía nvm-windows) | ver nota | Cloud Functions + bot |
| Python | 3.11+ | python.org | scripts, cachatore, scrapers |
| Firebase CLI | latest | `npm i -g firebase-tools` | deploy functions/rules/hosting |
| gcloud CLI | latest | Cloud SDK installer | deploy, scheduler, firestore |
| Visual Studio 2022 | workload **Desktop C++** | installer | build Windows |
| Android Studio | + Android SDK | installer | build Android |
| sentry-cli | latest | `npm i -g @sentry/cli` | observabilidad (FLUTTER-x, etc.) |
| Inno Setup 6 | latest | `winget install JRSoftware.InnoSetup` | instalador `.exe` Windows |
| jq | latest | `winget install jqlang.jq` | parseo JSON (opcional, cómodo) |

### Flutter — pin 3.44.0 (CRÍTICO)

Pineado en **4 lugares**: `.flutter-version`, `.github/workflows/ci.yml`,
`ios/ci_scripts/ci_post_clone.sh`, `macos/ci_scripts/ci_post_clone.sh`.

El SDK **local** (`C:\flutter`) tiene que estar en ese tag, porque el **AAB de
Android y el `.exe` de Windows se buildean LOCAL** (no en CI). Si el SDK local
difiere, podés reintroducir bugs ya arreglados (caso real **FLUTTER-H**: SIGABRT
en Android 11; se arregló subiendo el SDK a 3.44.0).

```powershell
git -C C:\flutter fetch --tags
git -C C:\flutter checkout 3.44.0   # queda en "detached HEAD" sobre el tag — es normal
flutter --version                   # re-baja el engine; debe decir 3.44.0
```
Volver al canal stable normal: `git -C C:\flutter checkout stable`.

### Node 22 — vía nvm-windows

El runtime de Cloud Functions es **nodejs22**; mantené Node 22 local para que
matchee (evita el warning `EBADENGINE` y diferencias de comportamiento en tests).

```powershell
winget install CoreyButler.NVMforWindows
# >>> REABRIR la terminal (para que entren NVM_HOME / NVM_SYMLINK al PATH) <<<
nvm install 22
nvm use 22
node -v        # v22.x
```
Gotchas observados:
- `nvm` tira `ERROR open \settings.txt` → falta `NVM_HOME` en la sesión; reabrir
  terminal (o setear `$env:NVM_HOME` a mano).
- `nvm use` actualiza el symlink `C:\nvm4w\nodejs`; **abrí una terminal nueva**
  para que el PATH lo tome (las terminales viejas siguen con el Node anterior).
- Si había un Node por MSI en `C:\Program Files\nodejs`, desinstalalo
  (`winget uninstall OpenJS.NodeJS.LTS`) para que no compita en el PATH.
- Los globals (`firebase`, `sentry-cli`) en `AppData\Roaming\npm` siguen
  funcionando con Node 22 sin reinstalar.

---

## Secrets (resumen — detalle en el Drive)

NO están en el repo. Restaurar desde
**`G:\Mi unidad\ClaudeCodeSync\secrets\README_RESTAURACION.md`** (mapa + script).
Los críticos:

- `android/coopertrans_movil.jks` + `android/key.properties` → ⚠ **IRREEMPLAZABLES**
  (sin ellos NO se puede volver a subir update a Play Store, nunca).
- `.sentryclirc` → `~\.sentryclirc`.
- `firebase/serviceAccountKey.json`, `cachatore/claves.json`, `whatsapp-bot/.env`.
- `ftp/ftp_datos.txt` → NO se copia; los scripts lo leen directo del Drive.

---

## Verificación (la PC está lista si todo esto pasa)

```powershell
flutter --version              # 3.44.0
flutter doctor                 # sin issues (Android toolchain + VS2022 OK)
node -v                        # v22.x
firebase projects:list         # muestra coopertrans-movil
gcloud auth list               # cuenta activa + ADC presente
# en el repo:
flutter analyze                # No issues found!
cd functions; npx tsc --noEmit # exit 0
npx eslint .                   # 0 errors
```

---

## Notas operativas

- **Hook pre-commit** (`.claude/scripts/validate_changes.py`): antes de cada
  `git commit` corre `tsc`+`eslint` (si tocás `functions/*.ts`) y
  `flutter analyze` (si tocás `lib/` o `test/*.dart`), y **bloquea** si fallan.
  Requiere `functions/node_modules` instalado y el SDK Flutter sano.
- **Push directo a `main`** con bypass de branch rules (flujo del proyecto, no es error).
- **Releases** los dispara Santiago (`release_completo.ps1`, etc.). El
  `build_installer.ps1` encuentra Inno aunque winget lo instale en
  `AppData\Local\Programs\Inno Setup 6\` (scope user, sin admin).
- **macOS**: frente pausado (ver `docs/RUNBOOK_macos_signing.md`). No bloquea Win/Android/iOS.

---

## Primer release completo desde PC nueva — baches resueltos (2026-05-29)

El primer `release_completo.ps1` desde la PC `santi` destapó baches que el setup
base no cubre. Todos resueltos y commiteados; desde **1.0.83+86** el release corre
**end-to-end** (Windows + AAB + iOS + Sentry symbols + web) en una sola pasada. Si
reaparecen en una migración futura:

- **Scripts `.ps1` de release: "Falta la llave de cierre"** → se editaron en la Mac
  y quedaron UTF-8 **sin BOM**; PS 5.1 los lee como Windows-1252 y rompe el parser
  con los ~400 no-ASCII (separadores `─`, acentos). Las llaves estaban balanceadas.
  Fix: reescribir con UTF-8 **con BOM**.
- **`nuget.exe not found`** en `flutter build windows` → **cosmético** (Flutter lo
  baja/cachea solo y el build completa). Igual conviene bajarlo de
  `dist.nuget.org/win-x86-commandline/latest/nuget.exe` a una carpeta del PATH
  (`C:\Users\<USER>\tools`).
- **AAB: "Inconsistent JVM-target compatibility (17) and (21)"** → la PC nueva trae
  **JDK 21** (Java en 17, Kotlin tomaba 21). Fix YA en `android/app/build.gradle.kts`
  (`kotlinOptions.jvmTarget = 17`). Si reaparece, alguien lo sacó.
- **`release_android` no encuentra `key.properties`** → secret; el backup del Drive
  trae la ruta del keystore de la PC vieja, el README de restauración ahora ajusta
  `storeFile` al user actual (README_RESTAURACION §2).
- **Web `/sistema` "salteada (sin proyecto web)"** → faltaba clonar el sitio
  (README_RESTAURACION §1: `cooper-trans.com.ar` → `web_coopertrans\sitio_nuevo` +
  copiar `_subir_sitio.py`).
- **Sentry symbols 403** → token de upload faltante (README_RESTAURACION: token
  `project:releases` → `git config sentry.authtoken`).

Warnings que quedan y son **inofensivos** (NO accionar): `DWARF unobfuscated`
(el `--strip` ROMPE el build — probado), `KGP / Built-in Kotlin` (deprecación
futura, depende de plugins de terceros). El wasm dry-run de la web se silenció con
`--no-wasm-dry-run`.
