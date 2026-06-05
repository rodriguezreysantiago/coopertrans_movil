# Pendiente en la Mac — release 1.0.89+92 (4-jun-2026)

Lo que queda de Mac / App Store Connect. **iOS se puede hacer también desde
Windows/web** (Xcode Cloud + ASC son web), pero acá queda todo junto.
`git pull` en la Mac para tener este archivo.

> ⚠️ **Antes de buildear, ojo con la versión.** Después del bump 1.0.89+92
> entraron DOS tandas: el **audit de Logística** (`b999d2b`) y la **auditoría
> iOS/macOS** que hiciste en la Mac (`c6c1d98` — ver sección 0). Como los
> cambios de plataforma (entitlements, Info.plist, ci_post_clone, Podfile.lock)
> afectan el BUILD, conviene **`release_completo` de nuevo (1.0.90) desde
> Windows ANTES de buildear** así el build los toma. Si ya disparaste 1.0.89,
> van en el próximo release. Detalle en `PENDIENTES.md`.

---

## 0. ✅ Ya resuelto en la Mac — auditoría iOS/macOS (4-jun, commit `c6c1d98`)

Auditoría multi-agente con verificación adversarial (14 de 16 hallazgos
aplicados; 2 descartados). Validado: `flutter analyze` limpio + 437 tests +
`plutil -lint` OK + `pod install` macOS resuelve. **Ya está en main.**

- **Permisos**: macOS sin `device.camera`/`NSCameraUsageDescription`
  (image_picker en macOS no abre cámara → menos fricción en App Review); iOS
  sin `NSPhotoLibraryAddUsageDescription` (la app solo LEE galería); macOS
  `NSAppearance=DarkAqua` fuerza dark mode real en el chrome nativo.
- **CI/reproducibilidad**: `ci_post_clone` pinea `flutterfire_cli 1.3.2` + valida
  el Name del profile; `macos/Podfile.lock` versionado.
- **Config**: `RunnerTests` bundle id → `com.coopertrans.movil.RunnerTests`
  (iOS+macOS, cierra el pendiente histórico); `CODE_SIGN_IDENTITY` iOS → `Apple
  Development/Distribution` (nombres modernos; signing real sigue Manual).
- **Comentarios desincronizados**: `Release.xcconfig` (macOS) y
  `map_navigation_helper.dart` corregidos.

El signing iOS moderno y el dark mode visual se **confirman en el próximo build
de Xcode Cloud**.

---

## 1. iOS — App Store 1.0.89+92 (lo largaste hoy)

El `release_completo` ya hizo el bump (1.0.89+92) y pusheó. Falta el build + submit.

- [ ] **App Store Connect → Xcode Cloud**: verificá que el build de `1.0.89`
      corrió OK. Si el workflow es **manual**, hacé **Start Build** en branch
      `main`. (~30 min.)
- [ ] ⚠️ **Si el build falla en `ci_post_clone`** con
      `Could not resolve host release-assets.githubusercontent.com` (es la
      descarga de `pdfium` del plugin `pdfrx`) → es **transient de Apple**.
      **Re-trigger** del build (1 click, sin commit). >90% pasa a la 2da vuelta.
- [ ] **ASC → app iOS → `+ Versión` `1.0.89`** → **Add Build** (1.0.89+92) →
      completar "qué hay de nuevo" → **Submit for Review**.
- [ ] Cuando Apple apruebe → **Publish**.

**Qué incluye esta versión** (para el "qué hay de nuevo"): fix de tarifas con
chofer a monto fijo, editar service a mano en Mantenimiento, mejoras del módulo
Cachatore. **Si re-bumpeás a 1.0.90** (ver nota arriba): sumá los arreglos del
audit de Logística (liquidación, formularios de viaje, adelantos). (Lo del
bot/agente NO va en la app — corre en la PC dedicada.)

---

## 2. macOS — Mac App Store

Estado al **29-may**: pipeline RESUELTO end-to-end (Build/Compilación 51 — Archive
+ TestFlight interno OK; las 3 capas codesign/categoría/export-compliance
cerradas). Quedó en **TestFlight interno** / enviado a review. **Pasaron 6 días →
verificá en qué quedó.**

- [ ] **ASC → app macOS → ver estado**: ¿aprobada? ¿sigue en review? ¿solo
      TestFlight interno?
- [ ] Si falta el submit a **App Store público**: `+ Versión` → **Add Build**
      (Compilación 51 o la del build de hoy si corrés uno nuevo) → **Submit for
      Review** → **Publish**. Mismo flujo que iOS.
- [ ] ⚠️ **Confirmá que el login demo `00000001` sigue activo** — es la causa #1
      de rechazo de Apple (lo prueban en la review). Probalo antes de submit.
- [ ] (Opcional, desde la Mac) limpiar los ~701 warnings de build: subir
      `MACOSX_DEPLOYMENT_TARGET` a `11.0` en `macos/Podfile`. **NO bloquea.**

---

## Referencias
- `docs/RUNBOOK_macos_signing.md` — detalle macOS (codesign, secrets, historia 8 builds).
- `docs/SETUP_IOS_RELEASE.md` — flujo iOS.
- App Store Connect: https://appstoreconnect.apple.com

## NO te traigas esto a la Mac (no es de Mac)
- **Bot WhatsApp / agente**: corre en la PC dedicada (auto-update). Nada que hacer en Mac.
- **Warnings de build Android**: se analizan desde **Windows** (la Mac no tiene Android SDK).
