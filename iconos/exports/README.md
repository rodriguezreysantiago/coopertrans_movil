# Coopertrans · Iconos de app

Set completo de iconos para todas las plataformas, basado en la dirección
**A · Núcleo** (monograma C en indigo eléctrico sobre near-black, escuela
Linear / Cursor / Vercel).

```
exports/
├── master-square.svg          ← SVG master full-bleed (iOS, Android, Web, Win)
├── master-macos.svg           ← SVG master con squircle baked-in (macOS)
├── foreground.svg             ← Solo la C, sin fondo (Android adaptive)
├── master-1024.png            ← Preview render 1024 px
├── master-2048.png            ← Preview render 2048 px (presentaciones)
│
├── ios/AppIcon.appiconset/    ← Drag & drop en Xcode
├── macos/AppIcon.appiconset/  ← Drag & drop en Xcode
├── android/
│   ├── mipmap-mdpi/ … mipmap-xxxhdpi/   ← Copiar a android/app/src/main/res/
│   ├── mipmap-anydpi-v26/               ← XML adaptive
│   └── values/                          ← color background
├── windows/
│   ├── ico-sources/           ← PNGs para armar app_icon.ico
│   └── store/                 ← Tile assets MSIX (si publicás a Store)
└── web/
    ├── icon.svg               ← Favicon vectorial (browsers modernos)
    ├── favicon-*.png          ← PNG fallbacks
    ├── apple-touch-icon.png   ← iOS web clip
    ├── site.webmanifest       ← Manifest para PWA
    └── _HEAD_SNIPPET.html     ← <link> tags listos para pegar
```

---

## 🍎 iOS · Cómo aplicar

1. Abrir el proyecto en Xcode (`coopertrans_movil/ios/Runner.xcworkspace`).
2. En el navegador izquierdo: `Runner > Assets.xcassets > AppIcon`.
3. **Borrar el AppIcon viejo.**
4. Arrastrar la carpeta entera `iconos/exports/ios/AppIcon.appiconset/`
   sobre `Assets.xcassets` en el navegador. Xcode la integra.
5. Build & Run en simulator + device físico para verificar.
6. Para el ícono del Spotlight / Settings — Xcode los toma del mismo
   appiconset (ya están todos los slots: 20/29/40/60/76/83.5/1024).

> **Nota Flutter:** si usás `flutter_launcher_icons` package, podés
> seguir el método tradicional (ver Android abajo). Acá hacemos el
> upgrade directo porque ya tenemos los assets cocinados.

---

## 🍏 macOS · Cómo aplicar

1. Abrir `coopertrans_movil/macos/Runner.xcworkspace` en Xcode.
2. `Runner > Assets.xcassets > AppIcon`.
3. Borrar el AppIcon viejo + arrastrar
   `iconos/exports/macos/AppIcon.appiconset/`.
4. Build & Run.
5. El icono macOS YA tiene squircle + margen baked-in en el SVG
   (a diferencia de iOS), por eso es distinto archivo master.

**Si querés generar el `.icns` manualmente** (para distribución
fuera del Mac App Store):

```bash
cd iconos/exports/macos/AppIcon.appiconset
# Renombrar PNGs al formato esperado por iconutil:
mkdir AppIcon.iconset
cp icon_16x16.png       AppIcon.iconset/icon_16x16.png
cp icon_16x16-2x.png    AppIcon.iconset/icon_16x16@2x.png
cp icon_32x32.png       AppIcon.iconset/icon_32x32.png
cp icon_32x32-2x.png    AppIcon.iconset/icon_32x32@2x.png
cp icon_128x128.png     AppIcon.iconset/icon_128x128.png
cp icon_128x128-2x.png  AppIcon.iconset/icon_128x128@2x.png
cp icon_256x256.png     AppIcon.iconset/icon_256x256.png
cp icon_256x256-2x.png  AppIcon.iconset/icon_256x256@2x.png
cp icon_512x512.png     AppIcon.iconset/icon_512x512.png
cp icon_512x512-2x.png  AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns AppIcon.iconset
# → AppIcon.icns
```

---

## 🤖 Android · Cómo aplicar

Hay 2 layers ahora:
- **Legacy** (ic_launcher.png + ic_launcher_round.png en cada mipmap-*)
- **Adaptive** (foreground + background separados, Android 8.0+)

### Pasos

1. Borrar el contenido viejo de:
   ```
   coopertrans_movil/android/app/src/main/res/mipmap-*
   ```
2. Copiar el contenido de `iconos/exports/android/` adentro de
   `coopertrans_movil/android/app/src/main/res/`. Estructura:
   ```
   res/
   ├── mipmap-anydpi-v26/ic_launcher.xml
   ├── mipmap-anydpi-v26/ic_launcher_round.xml
   ├── mipmap-mdpi/ic_launcher.png
   ├── mipmap-mdpi/ic_launcher_round.png
   ├── mipmap-mdpi/ic_launcher_foreground.png
   ├── mipmap-hdpi/… (idem para hdpi/xhdpi/xxhdpi/xxxhdpi)
   └── values/ic_launcher_background.xml
   ```
3. **Si tu `res/values/colors.xml` ya tiene un `<color>`** distinto,
   en vez de copiar `values/ic_launcher_background.xml` agregás
   esta línea al archivo existente:
   ```xml
   <color name="ic_launcher_background">#050505</color>
   ```
4. `flutter clean && flutter run` para verificar.

### Notas técnicas

- El **monocromo** (Android 13+) usa el mismo foreground PNG —
  Android lo decolora automáticamente. Funciona porque la C es
  silueta sólida sin detalles internos.
- La **safe area** del adaptive icon es 264dp dentro del canvas
  108dp total. La C está centrada con scale 0.62 → queda ~190dp
  alto, perfectamente dentro de la safe area sin riesgo de crop
  por máscaras del launcher.

---

## 🪟 Windows · Cómo aplicar

### Para la app de escritorio (msys / Flutter Windows)

1. **Generar el `.ico`** desde los PNGs:
   - Opción A — online: https://icoconvert.com → subir los 8 PNGs
     de `iconos/exports/windows/ico-sources/` → bajar el `.ico`.
   - Opción B — ImageMagick:
     ```bash
     cd iconos/exports/windows/ico-sources
     magick app_icon_16.png app_icon_24.png app_icon_32.png \
            app_icon_48.png app_icon_64.png app_icon_96.png \
            app_icon_128.png app_icon_256.png app_icon.ico
     ```
2. Reemplazar `coopertrans_movil/windows/runner/resources/app_icon.ico`
   por el nuevo.
3. `flutter clean && flutter run -d windows`.

### Para MSIX / Microsoft Store (opcional)

Los assets de `iconos/exports/windows/store/` van directo al
manifesto MSIX:
- `Square44x44Logo.png` → ícono de la barra de tareas
- `Square150x150Logo.png` → ícono del menú Start
- `Wide310x150Logo.png` → tile ancho del Start
- `StoreLogo.png` → ícono en la Store

---

## 🌐 Web (Chrome / Edge / Safari iOS) · Cómo aplicar

Asume que estás en `coopertrans_movil/web/`.

1. Copiar todo el contenido de `iconos/exports/web/` adentro de
   `coopertrans_movil/web/`:
   ```
   web/
   ├── icon.svg
   ├── favicon-16.png
   ├── favicon-32.png
   ├── favicon-48.png
   ├── favicon-192.png
   ├── favicon-512.png
   ├── apple-touch-icon.png
   └── site.webmanifest
   ```
2. Editar `coopertrans_movil/web/index.html` y pegar el contenido
   de `_HEAD_SNIPPET.html` adentro del `<head>` (reemplazando los
   `<link>` viejos de favicon).
3. **Si querés un `favicon.ico` clásico** para browsers super viejos:
   ```bash
   magick favicon-16.png favicon-32.png favicon-48.png favicon.ico
   ```
   y poner `favicon.ico` en `web/`.
4. Build: `flutter build web`.

---

## 🎨 Editar el master (cuando necesites variantes)

El SVG es **editable**. Para variar:

- **Cambiar color del fondo:** abrir `master-square.svg`, cambiar
  los dos `fill="#050505"` por el color nuevo. El glow se adapta
  automáticamente porque es relativo al brand.
- **Cambiar color de la C:** cambiar los `stop-color` del
  `<linearGradient id="cFill">`. Default: `#A5ACFF → #7C83FF`
  (brandSoft → brand).
- **Engrosar / afinar la C:** cambiar los radios de los arcos en
  el path. Actualmente outer=320 / inner=200 (= peso 120). Subir
  el inner a 220 = C más fina. Bajar a 180 = más gruesa.
- **Cambiar el ángulo de la apertura de la C:** los puntos
  `M 220 -250` y `L 220 130` controlan la abertura. Subir o
  bajar el primer Y.

Después de editar, re-renderizar todos los PNG con el script
`run_script` o con `rsvg-convert` / Inkscape.

---

## Plataformas que tu equipo usa

| Plataforma | Archivo a aplicar | Tiempo estimado |
|---|---|---|
| **iOS** | `ios/AppIcon.appiconset/` → Xcode | 5 min |
| **macOS** | `macos/AppIcon.appiconset/` → Xcode | 5 min |
| **Windows** | `windows/ico-sources/` → genera .ico → reemplazar | 10 min |
| **Android** | `android/` entero → copy a `res/` | 5 min |
| **Chrome (web)** | `web/` entero → copy a `web/` + edit index.html | 5 min |

**Total: ~30 minutos para tener el icono nuevo en las 5 plataformas.**

---

## Si querés volver a la versión anterior

El icono viejo está commiteado en git en las rutas:
- `coopertrans_movil/ios/Runner/Assets.xcassets/AppIcon.appiconset/`
- `coopertrans_movil/android/app/src/main/res/mipmap-*/`
- `coopertrans_movil/windows/runner/resources/app_icon.ico`
- `coopertrans_movil/macos/Runner/Assets.xcassets/AppIcon.appiconset/`
- `coopertrans_movil/web/favicon.png` + `icons/`

`git checkout <ruta>` para revertir.

---

## Master values

- Background: `#050505` (`AppColors.background`)
- Brand: `#7C83FF` (`AppColors.brand`)
- Brand soft: `#A5ACFF` (`AppColors.brandSoft`)
- Glow: radial gradient brand @ 35% opacity, top center
- Corner radius (macOS only): 22.5% del canvas (squircle Apple)
- Margen interno (macOS only): 100px de 1024px (~10%)
