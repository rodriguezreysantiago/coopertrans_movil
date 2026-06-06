# iOS — setup + release desde la Mac

Guía paso a paso para correr la app en simulador, en device real,
y subir a TestFlight + App Store. Asume **cuenta Apple Developer
aprobada** (~$99 USD/año, hecho 2026-05-14).

---

## Estado actual de la config (todo en git)

- `ios/` generado el 2026-05-04, `pod install` corrido.
- Bundle ID: `com.coopertrans.movil` (Runner).
- Target: iOS 16.0 mínimo.
- `GoogleService-Info.plist` presente (Firebase Auth/Firestore/Storage).
- Permisos `Info.plist`: cámara + fotos + agregar a fotos
  (image_picker + OCR de fechas).
- 3 build configs (Debug / Profile / Release) listas.
- Bundle de RunnerTests con string viejo
  (`com.coopertrans.logisticaAppProfesional.RunnerTests`) — no afecta
  la app ni el upload, fix opcional.

---

## Pre-requisitos en la Mac (one-time)

### 1. Toolchain

```bash
# Verificar que estén instalados
flutter --version          # 3.x+
xcode-select -p            # path de Xcode
gem --version              # Ruby (viene con Xcode CLI tools)
pod --version              # CocoaPods 1.16+
```

Si falta algo:

- **Xcode**: App Store → "Xcode" (~12 GB).
- **Xcode CLI tools**: `xcode-select --install`.
- **CocoaPods**: `sudo gem install cocoapods`.
- **Sentry CLI** (para upload de symbols, opcional): `brew install getsentry/tools/sentry-cli`.

### 2. Cuenta Apple Developer en Xcode

```
Xcode → Settings → Accounts → "+" → Apple ID
        → ingresar santiagocoopertrans@gmail.com (la que se aprobó)
        → ver que aparezca como "Coopertrans" / "Apple Developer Program"
```

### 3. Clonar el repo

```bash
cd ~
git clone https://github.com/rodriguezreysantiago/coopertrans_movil.git coopertrans_movil
cd coopertrans_movil
flutter pub get
```

### 4. Sentry (opcional, para crash reporting)

```bash
git config sentry.org coopertrans
git config sentry.project flutter
git config sentry.authtoken sntryu_...   # mismo token que Win
```

### 5. CocoaPods install (workaround Ruby 4.0)

```bash
cd ios
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install
cd ..
```

> **Por qué el workaround**: Ruby 4.0 + CocoaPods 1.16 da
> `Encoding::CompatibilityError` en `Pod::Config#installation_root`
> sin las env vars de UTF-8. Documentado en el RUNBOOK.

### 6. Setear DEVELOPMENT_TEAM en el proyecto

Apple genera un Team ID de 10 chars (ej. `ABCD123456`) cuando se
aprueba la cuenta. Para que Flutter pueda firmar:

```
Xcode → abrir ios/Runner.xcworkspace
        → Runner (target izquierdo)
        → Signing & Capabilities tab
        → Team: seleccionar tu cuenta aprobada
        → "Automatically manage signing" debe estar tildado
```

Xcode genera/elige automáticamente el provisioning profile correcto
para `com.coopertrans.movil` y lo escribe en `project.pbxproj`. Si
después corrés `git diff ios/Runner.xcodeproj/project.pbxproj`, vas
a ver el Team ID nuevo + algunos cambios menores. **Commitealo**
(es necesario para que cualquier futura Mac no tenga que volver a
configurarlo).

---

## Primer arranque en simulador

```bash
# Listar simuladores disponibles
flutter devices

# Buscar el simulador de iPhone más cercano que tengas:
open -a Simulator
# (en el menú: File → Open Simulator → iPhone 16 Pro / 15 / SE — el que tengas)

# Correr
flutter run -d "iPhone 16 Pro"   # o el nombre que aparezca en `flutter devices`
```

Verificar que el splash + login carguen bien. Login con tu user admin.

---

## Build para device real (probar en iPhone físico)

1. Conectar iPhone por USB.
2. En el iPhone: Ajustes → General → VPN y administración de
   dispositivos → confiar en el certificado de tu cuenta dev (la
   primera vez).
3. En Xcode: ver que el iPhone aparezca como destino de build.
4. Correr:

   ```bash
   flutter run -d "Nombre del iPhone"   # como aparece en `flutter devices`
   ```

---

## Build IPA + TestFlight (closed testing iOS)

```bash
# Desde la raíz del repo (después de bumpear versión si corresponde)
./scripts/release_ios.sh
```

El script hace:
1. Verifica git limpio + pusheado.
2. `flutter build ipa --release --obfuscate --split-debug-info=...`
   (genera `build/ios/ipa/coopertrans_movil.ipa`).
3. Sube symbols Dart + dSYMs a Sentry (si está configurado).
4. Imprime instrucciones para subir el IPA a App Store Connect.

### Subir el IPA a App Store Connect

**Opción A — Transporter (más simple)**:

1. App Store en la Mac → bajar **Transporter** (gratis, oficial Apple).
2. Abrir Transporter, login con `santiagocoopertrans@gmail.com`.
3. Drag & drop `build/ios/ipa/coopertrans_movil.ipa`.
4. Click "Deliver".

**Opción B — Xcode Organizer**:

```
Xcode → Window → Organizer → tab Archives
        → seleccionar el archive de hoy
        → "Distribute App" → "App Store Connect" → "Upload"
```

### Después del upload

1. Esperar 10-30 min hasta que Apple procese el build.
2. Te llega un mail de Apple cuando termina (a `santiagocoopertrans@gmail.com`).
3. https://appstoreconnect.apple.com → "Coopertrans Móvil" (o el
   nombre que se le ponga al crear la app la primera vez) → tab
   **TestFlight**.
4. **Internal Testing**: agregar el build al grupo "Internal Testers".
   Hasta 100 testers que sean parte del Apple Developer Team. Acceso
   inmediato, sin review.
5. **External Testing** (si querés que choferes prueben antes del
   App Store público): primer build pasa por **Beta Review** de Apple
   (1-2 días). Después puede tener hasta 10.000 testers.

> Nota: Igual que Android, podemos arrancar con Internal solo
> (Santiago + 1-2 personas más) hasta que valide que la app funciona
> bien en iOS, y después abrir Beta para choferes que tengan iPhone.

---

## Crear la app la PRIMERA VEZ en App Store Connect

Solo se hace una vez, antes del primer upload:

1. https://appstoreconnect.apple.com → "Mis apps" → "+"
2. Plataforma: iOS
3. Nombre: `Coopertrans Móvil`
4. Idioma principal: Español (Latinoamérica)
5. Bundle ID: seleccionar `com.coopertrans.movil` (debería aparecer
   en el dropdown una vez registrado en Apple Developer Portal —
   Xcode lo registra automáticamente al primer build con el Team ID
   seteado)
6. SKU: `coopertrans-movil-001` (cualquier string único)
7. Acceso de usuario: Acceso completo

Después de crear, Transporter / Organizer pueden subir builds para
ese Bundle ID.

---

## Listing de App Store (cuando se quiera publicar al público)

Para Closed Testing (TestFlight) NO hace falta listing completo. Para
publicación pública sí. Mismo material que armamos para Play Store
(`docs/PLAY_STORE_LISTING.md`):

- **Captura de pantallas** (6.5" + 5.5" + iPad si habilitamos):
  abrir simulador, log in, sacar 3-5 screenshots de las pantallas
  principales (`Cmd+S`).
- **Ícono 1024×1024** (sin canal alpha, sin transparencia, sin
  esquinas redondeadas — Apple las redondea solo). Lo tenemos en
  `assets/ios/AppIcon.appiconset/`.
- **Descripción**: copiar de `docs/PLAY_STORE_LISTING.md` y adaptar.
- **URLs**: política de privacidad + soporte (las mismas que Play
  Store, ya hosteadas en Firebase Hosting).

---

## Operación diaria — releases iOS

Cada vez que se hace un release nuevo en Android (vía
`scripts\release_completo.ps1` desde Windows), para hacer la versión
iOS equivalente:

```bash
# Desde la Mac, después del git pull:
git pull
cd ios && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install && cd ..
./scripts/release_ios.sh
# después: subir el IPA con Transporter
```

El número de versión / build (`pubspec.yaml`) ya viene bumpeado del
release Windows anterior, no hay que tocarlo de nuevo.

---

## Troubleshooting

### `pod install` da `Encoding::CompatibilityError`

Aplicar el workaround:

```bash
cd ios
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install
```

### Xcode tira "Provisioning profile required"

```
Xcode → Runner target → Signing & Capabilities
        → Team: tu cuenta aprobada
        → tildá "Automatically manage signing"
```

Si igual no funciona, en Xcode → Settings → Accounts → "Manage
Certificates" → "+" → Apple Development. Después rebuild.

### Apple rechaza el IPA con "Invalid Bundle"

Casi siempre es:
- Falta algún ícono en `Assets.xcassets/AppIcon.appiconset/`.
- Falta `NSCameraUsageDescription` o algún permiso (ya están en
  `Info.plist`, no debería pasar).
- Bundle ID no registrado en el portal Apple (registralo: Xcode
  build con Team ID asignado lo hace automáticamente la primera vez).

### Crashlytics no recibe symbols del build iOS

Verificar que `release_ios.sh` haya completado el upload de dSYMs.
Si dijo "WARN: upload dSYMs falló", correr a mano:

```bash
sentry-cli debug-files upload --auth-token $TOKEN --org coopertrans --project flutter build/ios/archive/Runner.xcarchive/dSYMs
```

---

## Diferencias con Android

| Cosa | Android | iOS |
|---|---|---|
| Build comando | `release_completo.ps1` (Win) | `release_ios.sh` (Mac) |
| Cuenta dev | Google Play Console (US$25 una vez) | Apple Developer (US$99/año) |
| Subida | Automática del script al Play Store closed | Manual con Transporter o Xcode |
| Closed testing | "Testers" lista de emails Gmail | TestFlight Internal (Apple ID Mac) |
| Beta review primer build | No | Sí, 1-2 días |
| Build artifact | AAB (.aab) | IPA (.ipa) |
| Auto-update en chofer | Sí, Play Store en background | Sí, App Store en background |

---

## Referencias rápidas

- Apple Developer Portal: https://developer.apple.com/account
- App Store Connect: https://appstoreconnect.apple.com
- TestFlight (chofer): aplicación gratuita en App Store, lo invitan por mail.
- Documentación oficial: https://docs.flutter.dev/deployment/ios
