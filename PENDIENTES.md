# Pendientes follow-up

Cosas que requieren acción nuestra en una fecha específica. Para roadmap general
del proyecto, ver `ESTADO_PROYECTO.md`. Para procedimientos operativos, `RUNBOOK.md`.

Convención: orden cronológico (los próximos arriba). Sacar el ítem cuando se ejecuta.

---

## 📅 Post 2026-05-15 — Validar build #7 Xcode Cloud (Plan A Manual Signing en marcha)

**Estado al cierre 2026-05-15 ~13:50 ART**: Plan A 100% configurado y
build #7 disparado. Esperando resultado (~30 min).

Setup completo:
- Cert Apple Distribution exportado del Keychain → `coopertrans_dist.p12`
  en `G:\ClaudeCodeSync\secrets-ios\` (password `coopertrans2026`).
- `.mobileprovision` "Coopertrans Movil App Store" descargado via
  App Store Connect API (script reusable en
  `scripts/download_provisioning_profile.py`).
- 3 secret env vars seteadas en el workflow Xcode Cloud:
  `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_P12_PASSWORD`,
  `IOS_DIST_PROFILE_BASE64`.
- Build #7 disparado manualmente desde App Store Connect web.

**Si build #7 OK** ✅: te llega mail "Build available in TestFlight" a
`santiagocoopertrans@gmail.com`. Bajá la app **TestFlight** del App Store
en tu iPhone, login con esa cuenta (o la otra si aceptaste la invitación
para testers internos), tap "Instalar" en Coopertrans Móvil. Pipeline
iOS queda operable desde Windows para siempre — sólo hace falta volver
a la Mac cuando vence el cert (1 año).

**Si build #7 falla** ❌: bajar logs (en App Store Connect → Xcode Cloud
→ workflow → click sobre el build → "Download Logs"). Si el error sigue
siendo "Communication with Apple failed", esperar 48-72h post-aprobación
de la cuenta (2026-05-14) — la causa más probable es propagación lenta
del backend Apple para cuentas nuevas.

**Contexto del día** (2026-05-15): Apple desde 2026 exige iOS SDK 26 obli-
gatorio para uploads a App Store / TestFlight. El MacBook Air 2020 Intel
de Santiago **no soporta** Xcode 26 (requiere macOS 26 Tahoe, solo Apple
Silicon). Decisión: descartar build local en Mac, migrar a **Xcode
Cloud** (CI/CD de Apple, incluido en el Apple Developer Program).

**Setup avanzado durante la sesión 2026-05-15** (todo commiteado):
- App registrada en App Store Connect (`com.coopertrans.movil`).
- Apple Distribution Cert + Provisioning Profile "Coopertrans Movil App
  Store" creados manualmente en el portal Apple.
- App Store Connect API Key creada (Issuer `2b70dc6f-0859-4830-925f-743881d5cf1c`,
  Key ID `7K3A7243WL`, Admin role). **`.p8` backup en
  `G:\Mi unidad\ClaudeCodeSync\secrets-ios\`**.
- Xcode Cloud workflow "Build & Upload to TestFlight" configurado con
  trigger **MANUAL** (no auto, para no quemar cuota).
- `ios/ci_scripts/ci_post_clone.sh` con instalación Flutter + flutterfire
  CLI + bloque opcional Manual Signing.
- pbxproj con Manual Signing en Release apuntando a profile manual.
- Acuerdos comerciales App Store Connect aceptados.

**6 builds Xcode Cloud todos fallaron** con el mismo error:

```
Account "Session Proxy Provider": Unable to authenticate with App Store Connect
error: exportArchive Communication with Apple failed
error: exportArchive No profiles for 'com.coopertrans.movil' were found
```

Causa: cuenta Apple Developer recién aprobada, Apple tarda 24-72h en
propagar la API de signing al backend completo. La API Key creada NO se
está usando (Apple Cloud sigue con el "Session Proxy Provider" interno).

### Camino A — Esperar 48-72h y reintentar manual (sin esfuerzo)

1. **Después del 2026-05-17** (≥72h post aprobación cuenta), abrir desde
   cualquier PC (Windows también):
   App Store Connect → Coopertrans Móvil → Xcode Cloud → workflow →
   **Start Build** → branch `main`.
2. Esperar ~30 min.
3. Si funciona → archive + export + upload a TestFlight automático.
4. Te llega mail "Build available in TestFlight".
5. Instalás en iPhone via app TestFlight.

### Camino B — Forzar Manual Signing con cert + profile pre-cargados

Si el Camino A sigue fallando, este destraba 100% (workaround DIY que no
depende de la API rota de Apple):

1. **One-time desde la Mac** (única cosa que necesita la Mac):
   Abrir Acceso a Llaveros → Mis Certificados → click derecho sobre
   "Apple Distribution: Santiago Rodriguez Rey" → Exportar:
   - Formato `.p12`, password `coopertrans2026` (o el que se elija).
   - Guardar en `G:\Mi unidad\ClaudeCodeSync\secrets-ios\coopertrans_dist.p12`.

2. **Desde cualquier PC** (Windows OK):
   - Bajar el `.mobileprovision` desde
     https://developer.apple.com/account/resources/profiles/list
     → click "Coopertrans Movil App Store" → Download.
   - Guardar en `G:\Mi unidad\ClaudeCodeSync\secrets-ios\Coopertrans_Movil_App_Store.mobileprovision`.

3. **Convertir ambos a base64** (Windows PowerShell):
   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("G:\Mi unidad\ClaudeCodeSync\secrets-ios\coopertrans_dist.p12")) | Set-Clipboard
   ```
   (Pegá el resultado en un .txt temporal. Repetí para el .mobileprovision.)

4. **Subir 3 secret env vars al workflow Xcode Cloud**:
   App Store Connect → Coopertrans Móvil → Xcode Cloud → workflow →
   Edit → Custom Environment Variables → "+":
   - `IOS_DIST_CERT_P12_BASE64` = (paste base64 del .p12) → **Secret** ✅
   - `IOS_DIST_CERT_P12_PASSWORD` = `coopertrans2026` → **Secret** ✅
   - `IOS_DIST_PROFILE_BASE64` = (paste base64 del .mobileprovision) → **Secret** ✅
   - Save workflow.

5. **Disparar build manual** → branch `main` → esperar 30 min.
6. El `ci_post_clone.sh` detecta las 3 env vars y configura Manual
   Signing automáticamente (importa cert al keychain, instala
   profile en `~/Library/MobileDevice/Provisioning Profiles/`).
7. xcodebuild encuentra todo localmente, NO trata de hablar con Apple.
8. Build OK → IPA sube a TestFlight automático via Post-Action.

### Pasos posteriores a primer build OK

Crear grupo de Internal Testers en App Store Connect → Coopertrans Móvil
→ tab TestFlight → Internal Testing → "+" → Name "Internal Testers" →
agregar Santiago. Editar workflow Xcode Cloud → agregar Post-Action
"TestFlight Internal Testing" apuntando a ese grupo.

**Bajar app TestFlight** del App Store en el iPhone, login con
`santiagocoopertrans@gmail.com` (o la otra cuenta si aceptaron la
invitación que Santiago mandó), tap "Instalar" en Coopertrans Móvil.

Memoria completa con todo el detalle: `claude-memory/project_ios_release.md`
(en G: Drive) o ver `docs/SETUP_IOS_RELEASE.md` (queda como referencia
histórica del flujo Mac local descartado).

---

## 📅 2026-05-16 (sáb) — Re-análisis de eventos Sitrack con ventana de 60h

**Contexto**: el primer análisis se corrió el 2026-05-14 a las 32h del deploy
y devolvió 1036 eventos / 28.8 evt/h. Hallazgos clave:
- ✅ **CONDUCCIÓN PELIGROSA** = 108 eventos (10.4%) — categoría dominante.
  Distribución: salida de carril 1006 (77%), sobrevelocidad 8/9 (15%),
  giro brusco 383, distancia frenado 444, frenada brusca 67.
- ✅ Hay LDWS/cámara en algunos tractores (eventos 1006).
- ✅ 88.8% eventos con chofer identificado, 53.6% con cartography_limit_speed.
- ❌ **JORNADA** con eventos directos NO viable (los GPS son básicos sin
  ICAN, no emiten 152/153/513/514). El `vigiladorJornadaChofer` actual
  con proxy `speed > 15` SE QUEDA — no migrar.
- ❌ Viajes / combustible / fatiga MobileEye / mantenimiento — 0 eventos.
- ⚠️ Solo 29 de ~53 tractores emitiendo. Confirmar si los 24 restantes
  son inactivos o sin configurar (consultar a Sitrack).

**Decisión Santiago 2026-05-14**: esperar UN día más antes de codear el
consumer. Una ventana de 36h es muestra chica — quiero validar que la
distribución se mantiene estable antes de decidir features.

**Acción**: el sábado 2026-05-16 (o domingo) correr el análisis de nuevo
con ventana 60h:

```powershell
cd "C:\Users\Colo Logistica\coopertrans_movil"
node scripts/analizar_sitrack_eventos.js --horas 60
```

**Qué validar**:
- ¿La distribución por categoría se mantiene estable o cambia?
  (ej. Conducción peligrosa sigue siendo > 10% del total).
- ¿Aparecen tipos de evento que no vimos en 36h (ej. mantenimiento,
  combustible)?
- ¿La cobertura de patentes sube de 29 o se queda?
- ¿Cuántos eventos de salida de carril (1006) por chofer? Identificar
  quién maneja peor.

**Decisión a tomar después**: con muestra más grande, elegir entre:
- 🥇 Camino A: Resumen diario a Molina con eventos peligrosos del día
  (~150 LOC, mínimo riesgo).
- 🥈 Camino B: Score Sitrack por chofer (compite con Volvo Scores)
  (~400 LOC + UI).
- 🥉 Camino C: Alerta sobrevelocidad cartográfica en tiempo real
  (~100 LOC, posible spam).

Mi recomendación al cierre del 14/05: empezar por A.
