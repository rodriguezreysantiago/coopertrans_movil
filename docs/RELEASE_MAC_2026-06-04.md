# Pendiente en la Mac — release 1.0.89+92 (4-jun-2026)

Lo que queda de Mac / App Store Connect. **iOS se puede hacer también desde
Windows/web** (Xcode Cloud + ASC son web), pero acá queda todo junto.
`git pull` en la Mac para tener este archivo.

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
Cachatore. (Lo del bot/agente NO va en la app — corre en la PC dedicada.)

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
