# RUNBOOK — macOS signing en Xcode Cloud

**Estado:** ✅ RESUELTO + CONFIRMADO EN XCODE CLOUD 2026-05-28. **Build 46** (primero con el fix): `** ARCHIVE SUCCEEDED **` + `** EXPORT SUCCEEDED **` en app-store y development export, **CERO** errores de codesign. En el log se ve la firma de `Coopertrans Móvil.app/Contents/MacOS/CoopertransMovil` (binario ASCII). Causa raíz validada en Mac local (Xcode 16.4 / SDK 15.5) y confirmada en la nube. Queda confirmar que el build suba/aparezca en App Store Connect (upload = post-action; el codesign que bloqueaba ya está resuelto).

## TL;DR — qué era y cómo se arregló

**Causa raíz:** el ejecutable principal se llamaba `Coopertrans Móvil` (con tilde). El carácter no-ASCII `ó` en `CFBundleExecutable` hace que `codesign`, al sellar el bundle **sin `--deep`** (que es como lo hace Xcode), trate el binario como un subcomponente sin firmar → `code object is not signed at all`. **NO era el SDK 26.5** (la hipótesis vieja, ver más abajo) — se reproduce idéntico con SDK 15.5.

**Fix (1 línea):** en `macos/Runner/Configs/AppInfo.xcconfig`:
```
EXECUTABLE_NAME = CoopertransMovil
```
Fuerza el binario interno a ASCII. El `.app` se sigue llamando `Coopertrans Móvil.app` y `CFBundleName` mantiene la tilde — **el usuario no ve ningún cambio**. Solo `Contents/MacOS/CoopertransMovil` pasa a ASCII.

**Cómo se diagnosticó** (matriz de pruebas con `codesign --force --sign -` sin `--deep` sobre el `.app` real):

| Ejecutable | Resultado |
|---|---|
| `Coopertrans Móvil` (tilde) | ❌ FALLA |
| `Coopertrans Movil` (espacio, sin tilde) | ✅ OK |
| `CoopertransMóvil` (sin espacio, con tilde) | ❌ FALLA |
| `CoopertransMovil` (ASCII) | ✅ OK |

El binario, las dos arches (x86_64+arm64), los load commands y el deployment target están todos sanos: el mismo binario copiado a `/tmp` con nombre ASCII firma perfecto. El único factor es la tilde en el nombre del ejecutable.

> **Validación local:** `xcodebuild ... CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic build` (réplica exacta de los overrides que impone Xcode Cloud) → `** BUILD SUCCEEDED **` con el fix. Antes: `** BUILD FAILED **` en el CodeSign del `.app`.

---

## Historia del bloqueo (hipótesis vieja — REFUTADA)

> Lo de abajo quedó como registro de los 8 builds que se quemaron antes de encontrar la causa real. La hipótesis del "bug del SDK 26.5 con binarios universales" era **incorrecta**.

## Resumen del bloqueo

El archive de Xcode Cloud para macOS **falla siempre en el `CodeSign` final del `.app` raíz** con:

```
/Volumes/.../Coopertrans Móvil.app/Contents/MacOS/Coopertrans Móvil:
  code object is not signed at all
In subcomponent: /Volumes/.../Coopertrans Móvil.app/Contents/MacOS/Coopertrans Móvil
Command CodeSign failed with a nonzero exit code
** ARCHIVE FAILED **
```

El error es **patológico**: codesign reporta "código no firmado" en el `<subcomponent>` que apunta al mismo path del binary. Eso no debería pasar con un Mach-O simple universal.

Quemamos **8 builds** intentando resolverlo desde el repo:

| Build | Cambio probado | Resultado |
|---|---|---|
| 32, 38 | Setup inicial Manual Signing + secrets cargados | mismo error |
| 39 | Preparación distribución cambiada de "Ninguna" a "App Store Connect" | mismo error |
| 40 | `STRIP_INSTALLED_PRODUCT=NO` en Release.xcconfig | Strip apagó pero binary igual quedó sin firma |
| 42 | (fallido por tag inexistente Flutter 3.45.0 — ya corregido a 3.44.0) | post-clone falló |
| 43 | `OTHER_CODE_SIGN_FLAGS=--deep` en Release.xcconfig | mismo error, sin output stderr útil |
| 44 | Run Script Phase custom firmando binary manualmente con `codesign --force --sign -` | mi codesign también falló con el mismo error |
| 45 | Run Script Phase con diagnóstico verbose (file, ls, codesign -dvvv, --verbose=4) | confirmó que el bug es a nivel codesign, no del flujo |

## Lo que SÍ está configurado correctamente (no hay que repetirlo)

- ✅ Flutter SDK pineado a **3.44.0** en los 3 lugares (`ios/ci_scripts`, `macos/ci_scripts`, `.github/workflows/ci.yml`).
- ✅ Secrets cargados en App Store Connect → Xcode Cloud → workflow macOS:
  - `MACOS_DIST_CERT_P12_BASE64`
  - `MACOS_DIST_CERT_P12_PASSWORD`
  - `MACOS_DIST_PROFILE_BASE64`
- ✅ Backup completo de secrets en `G:\Mi unidad\ClaudeCodeSync\secrets\secrets-macos\` (9 archivos: csr, key, p12, base64, provisionprofile, base64, cer, pem, password).
- ✅ Cert "3rd Party Mac Developer Application" generado y registrado en Apple Developer.
- ✅ Profile "Coopertrans Movil Mac App Store" generado y descargado.
- ✅ `ci_post_clone.sh` macOS importa cert + profile OK (verificado en logs Builds 38..45: aparece `==> Manual Signing OK: cert importado + profile instalado`).
- ✅ pbxproj target Runner Release con:
  - `CODE_SIGN_STYLE = Manual`
  - `CODE_SIGN_IDENTITY[sdk=macosx*] = "3rd Party Mac Developer Application"`
  - `DEVELOPMENT_TEAM = 34NKYGL9KM`
  - `PROVISIONING_PROFILE_SPECIFIER = "Coopertrans Movil Mac App Store"`
  - `CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements`
- ✅ Workflow Xcode Cloud Archive action con "Preparación de la distribución: App Store Connect".
- ✅ `Release.entitlements` con `com.apple.security.app-sandbox` + network/camera/location + files (compatible con Mac App Store distribution).

## El root cause (hipótesis con evidencia)

Xcode Cloud **siempre** pasa estos CLI overrides al `xcodebuild archive`, en iOS Y macOS:

```
CODE_SIGN_IDENTITY=-
AD_HOC_CODE_SIGNING_ALLOWED=YES
CODE_SIGN_STYLE=Automatic
```

(Comparado contra Build 11 iOS exitoso — recibe los mismos overrides). En iOS funciona porque la cadena `link → codesign del .app raíz` no chequea firma de subcomponentes faltantes. En macOS sí.

En el Build 45 con diagnóstico, comprobamos:
- El binary universal Mach-O `Contents/MacOS/Coopertrans Móvil` **existe** después del link (1.8 MB, 2 arches).
- `codesign --force --sign -` directo sobre ese binary **falla** con "code object is not signed at all - In subcomponent: <mismo path>".
- `codesign --remove-signature` no encuentra firma previa para remover.
- `codesign --verbose=4` no agrega información útil — falla antes de imprimir algo verbose.

**Hipótesis principal**: el codesign del SDK macOS 26.5 tiene un bug con binarios universales generados con `MACOSX_DEPLOYMENT_TARGET=11.0` (gap de 5 años entre SDK y deployment target). Capaz inserta load commands o segments que el codesign valida y rechaza por incompatibilidad.

**Hipótesis secundarias** (no testadas por agotamiento de cuota):
- Path con UTF-8 (`Móvil` con `ó`) + espacios confunde a codesign internamente.
- `ARCHS` default genera slices x86_64 que ya no son soportadas correctamente por codesign macOS 26.5.

## Plan para retomar (cuando haya Mac local)

### Fase 0 — Smoke test local
```bash
cd ~/coopertrans_movil   # repo clonado en la Mac
flutter pub get
flutter build macos --release
# Ver si Flutter local puede armar el .app sin error de codesign.
# Si esto YA falla en local, el problema está en nuestro código.
# Si pasa, el problema está aislado a Xcode Cloud.
```

### Fase 1 — Codesign manual interactivo
Si `flutter build macos --release` pasó, intentar firmar manualmente:
```bash
EXE="build/macos/Build/Products/Release/Coopertrans Móvil.app/Contents/MacOS/Coopertrans Móvil"
codesign --force --sign - --verbose=4 "$EXE" 2>&1
# Ver el output completo. Si funciona en local pero no en Xcode Cloud,
# es bug específico de Xcode Cloud (reportar a Apple Developer).
# Si falla en local también, hipótesis de SDK 26.5 + deployment target gap.
```

### Fase 2 — Si Fase 1 falla en local, atacar root cause
Opciones en orden de menos→más invasivo:

1. **Subir `MACOSX_DEPLOYMENT_TARGET` a 13.0** en `Podfile` + `Runner/Configs/Warnings.xcconfig`. Cierra el gap con el SDK.
2. **Restringir `ARCHS` a `arm64` only**. Elimina la posible incompatibilidad de x86_64 slices.
3. **Renombrar `PRODUCT_NAME` a `CoopertransMovil`** (sin tilde ni espacio) en `Runner/Configs/AppInfo.xcconfig`. Elimina factor UTF-8.
4. **Actualizar Xcode a la última versión** (capaz Apple ya arregló el bug en SDK 26.6+).

### Fase 3 — Si todo lo anterior falla
Pedir ayuda a Apple Developer Technical Support con el log de Build 45 (diagnóstico verbose). Es bug de Apple, no nuestro.

### Fase 4 — Si Apple no ayuda y tampoco hay workaround
Distribuir macOS por fuera de Mac App Store usando `Developer ID Application` cert (notarized direct distribution). Requiere otro cert + otro profile + cambiar la "Preparación de la distribución" del workflow Xcode Cloud a "Developer ID". El usuario instala via DMG/PKG en lugar de Mac App Store.

## Logs guardados para referencia

- `~/Downloads/coopertrans_movil Build 32 Logs for Runner archive.zip` (primer setup)
- `~/Downloads/coopertrans_movil Build 38 Logs for Runner archive.zip` (igual)
- `~/Downloads/coopertrans_movil Build 39 Logs for Runner archive.zip` (App Store Connect preparación)
- `~/Downloads/coopertrans_movil Build 40 Logs for Runner archive.zip` (STRIP=NO)
- `~/Downloads/coopertrans_movil Build 43 Logs for Runner archive.zip` (--deep)
- `~/Downloads/coopertrans_movil Build 44 Logs for Runner archive.zip` (Run Script Phase)
- `~/Downloads/coopertrans_movil Build 45 Logs for Runner archive.zip` (diagnóstico verbose — **el más útil**)

## Commits relevantes en la historia

```
74b4402  fix(macos): STRIP_INSTALLED_PRODUCT=NO   (revertido en 307144a)
2a21fe6  fix(macos): OTHER_CODE_SIGN_FLAGS=--deep (revertido en 307144a)
307144a  fix(macos): Run Script Phase             (revertido en commit de pausa)
d611940  debug(macos): diagnostico verbose        (revertido en commit de pausa)
f8c2b01  chore: Flutter 3.45.0 → 3.44.0           (✅ mantener — es correcto)
```

## Estado del repo post-pausa

- `macos/Runner.xcodeproj/project.pbxproj`: **limpio** sin Run Script Phase custom.
- `macos/Runner/Configs/Release.xcconfig`: **limpio** sin parches experimentales.
- Flutter pin: **3.44.0** en los 3 lugares (independiente de macOS, sirve para iOS/Android/Windows).
- Tarea `#185 macOS Fase 4-6` queda `blocked: needs Mac local + Xcode interactive debug`.

## Impacto operativo

**Cero**. La app macOS no tiene demanda real:
- Todos los choferes usan Android (Play Store) o iOS (App Store).
- Los admin de logística usan Windows.
- Macs en la empresa = 0 hoy.

Cuando aparezca la primera Mac que valga la pena soportar, retomamos siguiendo este runbook. Estimado: 30 min de debug interactivo con `codesign --verbose=4` en local resuelve el bug.
