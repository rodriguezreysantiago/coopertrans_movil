# WALKTHROUGH — Aplicar el nuevo ícono v2 (neón C) en Coopertrans Móvil

> **Para Claude Code.** Este paquete contiene el ícono nuevo renderizado a todos los tamaños que necesita el proyecto Flutter, con el naming exacto que ya esperan los `Contents.json`, los `mipmap-*`, el `Runner.rc` de Windows y el `web/index.html`.
>
> **No corras `flutter_launcher_icons`.** Esa herramienta sobrescribe lo que dropeamos acá con una versión re-rasterizada del PNG fuente y se pierde la fidelidad del SVG. El bloque `flutter_launcher_icons:` del `pubspec.yaml` queda para futuros cambios; nosotros copiamos los assets ya cocinados directo en su lugar.

---

## Estructura del paquete

```
handoff/iconos_v2/
├── icon-master.svg               ← Vector source. Editable. Es la fuente de verdad.
├── master-1024.png               ← Render raster del master a 1024.
├── master-2048.png               ← Render raster del master a 2048 (presentaciones).
├── playstore-512.png             ← Listo para subir al Play Console (Graphic Assets > Icon).
│
├── ios/
│   └── AppIcon.appiconset/       ← Va a ios/Runner/Assets.xcassets/
│       ├── Contents.json
│       └── Icon-*.png  (15 archivos)
│
├── macos/
│   └── AppIcon.appiconset/       ← Va a macos/Runner/Assets.xcassets/
│       ├── Contents.json
│       └── icon_*.png  (10 archivos, naming -2x como ya usa el proyecto)
│
├── android/                      ← Mirror de android/app/src/main/res/
│   ├── mipmap-mdpi/    (ic_launcher.png + ic_launcher_round.png + ic_launcher_foreground.png)
│   ├── mipmap-hdpi/    (idem)
│   ├── mipmap-xhdpi/   (idem)
│   ├── mipmap-xxhdpi/  (idem)
│   ├── mipmap-xxxhdpi/ (idem)
│   ├── mipmap-anydpi-v26/ic_launcher.xml + ic_launcher_round.xml
│   └── values/ic_launcher_background.xml   ← Define @color/ic_launcher_background = #04031A
│
├── windows/
│   └── app_icon.ico              ← Va a windows/runner/resources/app_icon.ico (16-256 px multi-res)
│
└── web/                          ← Va a web/ (raíz del web target Flutter)
    ├── icon.svg
    ├── favicon-16.png
    ├── favicon-32.png
    ├── favicon-48.png
    ├── favicon-192.png
    ├── favicon-512.png
    ├── apple-touch-icon.png
    └── site.webmanifest
```

---

## Pre-flight (1 vez)

```bash
# Verificá que estás en el root del repo
cd /ruta/a/coopertrans_movil
git status                                  # working tree limpio idealmente
git checkout -b icono-v2-neon              # rama dedicada
```

---

## 1 · iOS

**Destino:** `ios/Runner/Assets.xcassets/AppIcon.appiconset/`

Reemplazar appiconset completo (Contents.json + 15 PNGs). El naming de archivos en el paquete coincide *exactamente* con el `Contents.json` actual, así que es un swap directo.

```bash
# Backup por las dudas
cp -r ios/Runner/Assets.xcassets/AppIcon.appiconset ios/Runner/Assets.xcassets/AppIcon.appiconset.bak

# Reemplazar
rm -rf ios/Runner/Assets.xcassets/AppIcon.appiconset/*
cp -r handoff/iconos_v2/ios/AppIcon.appiconset/* ios/Runner/Assets.xcassets/AppIcon.appiconset/
```

**Verificación:** abrir `ios/Runner.xcworkspace` en Xcode → navegar a `Runner > Assets > AppIcon` → todos los slots deben mostrar el nuevo ícono neón sin warnings de tamaño/scale.

> ⚠️ `remove_alpha_ios: true` en `pubspec.yaml` ya removió el canal alpha de las imágenes nuevas (las renderizamos sobre fondo navy sólido — no hay transparencia que App Store tenga que rechazar).

---

## 2 · macOS

**Destino:** `macos/Runner/Assets.xcassets/AppIcon.appiconset/`

```bash
cp -r macos/Runner/Assets.xcassets/AppIcon.appiconset macos/Runner/Assets.xcassets/AppIcon.appiconset.bak
rm -rf macos/Runner/Assets.xcassets/AppIcon.appiconset/*
cp -r handoff/iconos_v2/macos/AppIcon.appiconset/* macos/Runner/Assets.xcassets/AppIcon.appiconset/
```

**Verificación:** abrir `macos/Runner.xcworkspace` en Xcode → Runner > Assets > AppIcon. El `Contents.json` del paquete ya usa el naming `-2x` que tu proyecto tiene; no hace falta renombrar a `@2x`.

> El render macOS lleva un ~6% de padding interior (el `cGlow` del SVG ya respeta el visual safe-area del squircle de Apple), así que se ve correcto en el Dock sin recorte.

---

## 3 · Android

**Destino:** `android/app/src/main/res/`

```bash
cp -r android/app/src/main/res android/app/src/main/res.bak

# Mipmaps por dpi (5 dirs × 3 archivos)
for dpi in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  cp handoff/iconos_v2/android/mipmap-$dpi/ic_launcher.png            android/app/src/main/res/mipmap-$dpi/
  cp handoff/iconos_v2/android/mipmap-$dpi/ic_launcher_round.png      android/app/src/main/res/mipmap-$dpi/
  cp handoff/iconos_v2/android/mipmap-$dpi/ic_launcher_foreground.png android/app/src/main/res/mipmap-$dpi/
done

# Adaptive XML (8.0+)
cp handoff/iconos_v2/android/mipmap-anydpi-v26/ic_launcher.xml       android/app/src/main/res/mipmap-anydpi-v26/
cp handoff/iconos_v2/android/mipmap-anydpi-v26/ic_launcher_round.xml android/app/src/main/res/mipmap-anydpi-v26/

# Background color del adaptive icon
cp handoff/iconos_v2/android/values/ic_launcher_background.xml       android/app/src/main/res/values/
```

> Si tu `res/values/colors.xml` ya define `<color name="ic_launcher_background">` con otro valor, **NO** copies `values/ic_launcher_background.xml`. En su lugar editá el `colors.xml` existente y cambiá ese color por `#04031A`. Si copias el archivo nuevo y ya existe el color en otro lado, Gradle tira error de duplicado.

**Verificación:**

```bash
flutter clean
flutter run -d android
```

El ícono del launcher debe mostrar el C neón. En Pixel 6+ (Android 13), revisar el themed icon: settings → Wallpaper & style → Themed icons. La C silueta debería aplicarse al color del tema.

> El `ic_launcher.xml` declara `<monochrome>` apuntando al mismo `ic_launcher_foreground` — Android 13+ lo decolora automáticamente. Como nuestra C es silueta sólida sin detalles internos finos, el monocromo se ve perfecto.

---

## 4 · Windows

**Destino:** `windows/runner/resources/app_icon.ico`

Es un único archivo `.ico` multi-resolución (16, 24, 32, 48, 64, 128, 256 px). El `Runner.rc` ya lo referencia vía `IDI_APP_ICON` — no hay que tocar código C++.

```bash
cp windows/runner/resources/app_icon.ico windows/runner/resources/app_icon.ico.bak
cp handoff/iconos_v2/windows/app_icon.ico windows/runner/resources/app_icon.ico
```

**Verificación:**

```bash
flutter clean
flutter run -d windows
```

El ícono de la ventana (esquina superior izquierda) y el de la taskbar deben mostrar el nuevo. El ícono del **shortcut del escritorio** se refresca corriendo `scripts/actualizar_icono.ps1` después de que el operador haya actualizado la app (el shortcut apunta al `.exe` instalado que lleva el ícono embebido vía Runner.rc).

### Instalador Inno Setup

Mirá `installer/coopertrans_movil.iss`. Si referencia `app_icon.ico` por ruta absoluta (no relativa al runner), actualizalo también — pero típicamente Inno Setup copia el `.ico` desde `windows/runner/resources/` así que el reemplazo de arriba ya basta. Confirmá con `grep -i icon installer/coopertrans_movil.iss`.

---

## 5 · Web (Chrome / Edge / iOS Safari)

**Destino:** `web/`

```bash
cp -r web web.bak

cp handoff/iconos_v2/web/icon.svg              web/
cp handoff/iconos_v2/web/favicon-16.png        web/
cp handoff/iconos_v2/web/favicon-32.png        web/
cp handoff/iconos_v2/web/favicon-48.png        web/
cp handoff/iconos_v2/web/favicon-192.png       web/
cp handoff/iconos_v2/web/favicon-512.png       web/
cp handoff/iconos_v2/web/apple-touch-icon.png  web/
cp handoff/iconos_v2/web/site.webmanifest      web/
```

**Editar `web/index.html`:** cambiar el `<meta name="theme-color">` de `#050505` a `#04031A` para que el splash de PWA matchee el fondo del ícono nuevo.

```diff
- <meta name="theme-color" content="#050505">
+ <meta name="theme-color" content="#04031A">
```

Los `<link>` tags ya están bien (apuntan a los mismos filenames que dropeamos). El `site.webmanifest` del paquete ya viene con `background_color` y `theme_color` actualizados a `#04031A`.

**Verificación:**

```bash
flutter build web
# Servir y abrir en Chrome
cd build/web && python -m http.server 8000
# → http://localhost:8000 → pestaña + bookmark + "Install as app" deben mostrar el nuevo ícono.
```

---

## 6 · Activos de tiendas (Play Store / App Store)

- **Google Play:** `handoff/iconos_v2/playstore-512.png` → Play Console > Grow > Store presence > Main store listing > Graphic assets > **App icon** (512×512, 32-bit PNG).
- **App Store:** `Icon-1024.png` del appiconset iOS ya cubre el slot de marketing.
- **Feature graphic / Screenshots:** sin cambios — siguen siendo `assets/playstore/feature-graphic-1024x500.png` y el resto de capturas existentes.

> Si querés que el feature graphic refleje el ícono nuevo, decímelo y lo rediseño aparte.

---

## 7 · Validación final

```bash
# Compila las 5 plataformas (rápido smoke test, no release builds)
flutter clean
flutter pub get
flutter build apk --debug
flutter build ios --no-codesign
flutter build macos --debug
flutter build windows --debug
flutter build web

# Si todo compila, instalá en device físico (al menos Android e iOS) y verificá:
# 1. El launcher icon es el nuevo
# 2. El splash screen y el ícono del app switcher también
# 3. En iOS, Settings > Coopertrans > el ícono del fondo de settings es el nuevo
```

---

## 8 · Cleanup + commit

```bash
# Borrar backups si todo se ve bien
rm -rf ios/Runner/Assets.xcassets/AppIcon.appiconset.bak
rm -rf macos/Runner/Assets.xcassets/AppIcon.appiconset.bak
rm -rf android/app/src/main/res.bak
rm    windows/runner/resources/app_icon.ico.bak
rm -rf web.bak

git add -A
git commit -m "feat(branding): icono v2 neón C — multiplataforma

- Nuevo master vectorial en iconos/v2/icon-master.svg
- Reemplazo del appiconset iOS (15 PNGs)
- Reemplazo del appiconset macOS (10 PNGs)
- Reemplazo de mipmaps Android + adaptive XML + bg color
- Nuevo windows/runner/resources/app_icon.ico (multi-res 16-256)
- Reemplazo del set web/favicon-* + site.webmanifest
- theme-color web cambiado a #04031A (matchea el fondo del ícono)

Diseño: C neón violeta-índigo sobre navy profundo, con dos pills cian
brillantes y anillo exterior tenue. Recreación vectorial fiel de la
imagen aprobada el 2026-06-04.

Paquete fuente: handoff/iconos_v2/
WALKTHROUGH: handoff/iconos_v2/WALKTHROUGH.md"
```

---

## Rollback rápido (si algo se ve mal en alguna plataforma)

```bash
# Revertir solo iOS
git checkout HEAD~1 -- ios/Runner/Assets.xcassets/AppIcon.appiconset/

# Revertir solo Android
git checkout HEAD~1 -- android/app/src/main/res/

# Revertir todo
git revert HEAD
```

El paquete `handoff/iconos_v2/` queda en el repo como referencia (no se commitea con la rama main si preferís — agregá `handoff/iconos_v2/` al `.gitignore` o movelo fuera del repo después de aplicar).

---

## Editar el ícono más adelante

1. Abrí `handoff/iconos_v2/icon-master.svg` en cualquier editor SVG (VSCode, Inkscape, Figma → import).
2. Variables clave a tocar:
   - `<radialGradient id="bg">`: color del fondo navy.
   - `<linearGradient id="cBody">`: gradiente del cuerpo de la C.
   - `<linearGradient id="ringGrad">`: gradiente del anillo exterior.
   - `<radialGradient id="eyeGrad">`: color de las pills cian.
   - El `<path d="M 248 -212 A 320 320 0 1 0 248 212">`: geometría de la C (radius 320, opening angle ±40° = abertura 80°).
3. Re-correr el proceso de export (script de render PNG en `iconos/v2/`).
4. Re-aplicar pasos 1-5 de este walkthrough.

---

## Resumen ejecutivo (versión TL;DR)

```bash
# Backup + swap todas las plataformas en una corrida
cd /ruta/a/coopertrans_movil
git checkout -b icono-v2-neon

# iOS
rm -rf ios/Runner/Assets.xcassets/AppIcon.appiconset/*
cp -r handoff/iconos_v2/ios/AppIcon.appiconset/* ios/Runner/Assets.xcassets/AppIcon.appiconset/

# macOS
rm -rf macos/Runner/Assets.xcassets/AppIcon.appiconset/*
cp -r handoff/iconos_v2/macos/AppIcon.appiconset/* macos/Runner/Assets.xcassets/AppIcon.appiconset/

# Android (mipmaps + adaptive + bg color)
for dpi in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  cp handoff/iconos_v2/android/mipmap-$dpi/*.png android/app/src/main/res/mipmap-$dpi/
done
cp handoff/iconos_v2/android/mipmap-anydpi-v26/*.xml android/app/src/main/res/mipmap-anydpi-v26/
cp handoff/iconos_v2/android/values/ic_launcher_background.xml android/app/src/main/res/values/

# Windows
cp handoff/iconos_v2/windows/app_icon.ico windows/runner/resources/app_icon.ico

# Web
cp handoff/iconos_v2/web/*.png handoff/iconos_v2/web/*.svg handoff/iconos_v2/web/site.webmanifest web/
# Editar web/index.html: theme-color → #04031A

# Build + verificar
flutter clean && flutter pub get
flutter build apk --debug && flutter build ios --no-codesign && flutter build macos --debug && flutter build windows --debug && flutter build web

git add -A && git commit -m "feat(branding): icono v2 neón C — multiplataforma"
```

---

**Punto único de contacto:** si algo no compila o no se ve bien después de aplicar, escribí en el commit del PR qué plataforma y qué viste — yo reviso el render del SVG en ese tamaño específico y ajusto si hay un edge case (típicamente el rendering a 16px puede perder el ring exterior; en ese caso uso un favicon-16/32 simplificado y los reemplazo).
