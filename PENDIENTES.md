# Pendientes follow-up

Cosas que requieren acción nuestra en una fecha específica. Para roadmap general
del proyecto, ver `ESTADO_PROYECTO.md`. Para procedimientos operativos, `RUNBOOK.md`.

Convención: orden cronológico (los próximos arriba). Sacar el ítem cuando se ejecuta.

---

## 📅 2026-05-21 EOD — Arco Volvo: jornada + mantenimiento de punta a punta

Sesión gigante. Plan "todo desde Volvo, ICM queda en Sitrack". Ver memoria
`project_volvo_estado_fundacion.md` (detalle completo) y `project_modulo_icm.md`.

### Hecho y deployado (Cloud Functions — auto-deploy ON, ya están en vivo)
- **Fundación `estadoVolvoPoller`** verificada con los 53 camiones reales. Fix
  `limpiarNulos` (no borrar tell-tales por contenido) + `conductor_estado` + 2ª
  consulta UPTIME para testigos (commits `0350b0c` `6396c90` `72008f6`).
- **Jornada #36 → Volvo** (`d015e80`): el bug de paradas no detectadas era medir
  staleness sobre `consultado_en` (siempre fresco). Ahora `decidirManejando` gana
  la fuente MÁS FRESCA (Volvo `posicion_ts` real + speed; fallback SITRACK
  `report_date`). Verificado en vivo. Suite functions 186/186.
- **Parte de mantenimiento a Emmanuel #43** (`130453d` `8826257`): cron
  `resumenMantenimientoVehiculosDiario` 08:00 ART → WhatsApp con advertencias
  exactas (tell-tales en español) + declara cobertura honesta (hoy 20/53).

### Hecho — Mantenimiento por km #44 + #45 (componente NUEVO `volvo_sync/`)
- Scraper Playwright de Volvo Connect (login `logistica@cooper-trans.com.ar`,
  HTML estándar SIN MFA/CAPTCHA, sesión reusable). Trae historial de taller
  (`ecs-workshophistory` GraphQL) → `ULTIMO_SERVICE_KM/FECHA` + historial completo
  a `VEHICULOS_TALLER`. Parser PURO (último service por functionGroup, NO
  visitReason ni última visita). Reglas deployadas. Commits `a4b3945` `208e563`
  `cfdcd19`. **Flota sincronizada 1 vez (53 unidades).**
- App: campo de service **read-only** ("automático desde Volvo", `fb0f1f3`) +
  **pantalla de Mantenimiento unificada** (`9505e27`): lista → detalle por unidad
  con Service + Advertencias + Telemetría + Historial de taller completo.

### ⚠️ PENDIENTE para que quede 100% automático y visible
1. **Deploy `volvo_sync` en la PC dedicada** (cierra #44/#45 al 100% auto):
   `pip install playwright` + `playwright install chromium` + copiar
   `volvo_sync/claves.json` (creds, gitignoreado) + tarea programada DIARIA
   `python sync_taller.py --commit`. Hoy corrió 1 vez a mano desde la PC oficina.
2. **Release de la app** (Windows/Android/iOS) — propaga: jornada (transparente),
   campo service read-only, pantalla Mantenimiento unificada.
3. **Avisarle a Emmanuel** que desde mañana 8 AM le llega un WhatsApp diario con
   las advertencias de los camiones (que no le caiga de sorpresa).

### Hallazgos que cierran ideas
- **Testigos del tablero = límite de GENERACIÓN del camión**, NO de la API ni de
  acceso: los ~33 camiones viejos (2017-18) no transmiten "Estado actual" a NINGÚN
  lado (confirmado en la web). #43 techo real ~20/53. NO es activable.
- **Peso por eje (#46): 0/53 — descartado.** La flota no lo transmite.

---

## 📅 2026-05-20 EOD — Web institucional VAVG + acceso web a la app (proyecto nuevo)

Remodelación completa de la web pública del cliente + se le agregó el acceso web a la
app. **EN VIVO.** Proyecto separado en `C:\Users\Colo Logistica\web_coopertrans\` (NO
versionado en git). Detalle en `ESTADO_PROYECTO.md` §16 y memoria
`project_web_institucional.md`.

### Hecho (en vivo)
- Sitio nuevo marca **VAVG** en `https://cooper-trans.com.ar` (reemplazó al Flash/PHP viejo).
- App web en `https://cooper-trans.com.ar/sistema/` — mismo DNI + contraseña.
- Sitio viejo respaldado (`cooper-trans_sitio_viejo_backup_2026-05-19.zip`) y limpiado del server.
- `release_completo.ps1` ahora también compila + sube `/sistema` (best-effort, flag `-SkipWeb`).

### Deploys / push pendientes (Santiago, desde su PC)
- Push de los 2 commits del repo: `0d940c1` (branding `web/index.html`) + `d1a3af3`
  (integración web en release). Salen solos en el próximo `release_completo` (paso git
  push), o `git push` a mano cuando quieras.
- (Sigue pendiente lo del 19-may: `firebase deploy --only functions` + verificar
  rules/indexes del 18-may.)

### Pendiente / ideas
- **Versionar `web_coopertrans` en git local** (anti-pérdida; hoy el proyecto web NO está
  en ningún repo → bus-factor).
- Para actualizar la web/app desde la OTRA PC: copiar `web_coopertrans` + `ftp_datos.txt` allá.
- Fotos de flota del hero son media-res (recortes del brochure ~700px). Si hay fotos
  propias en alta, mejoran.

---

## 📅 2026-05-19 EOD — Cierre del día (vigilador fix + split functions completo + tests CF)

Sesión larga: fix de un bug real reportado por Santiago + completar el
split de `functions/index.ts` + sacar de "deferred" los tests de flujo
de las Cloud Functions.

### 🐛 Bug REAL del día: aviso falso de "12h jornada" (Oscar + César)

Dos choferes recibieron "Llegás al límite de 12 horas de jornada" sin
avisos progresivos previos y sin estar silenciados. **Causa raíz**: el
disparador era `bloques_completos >= 3`, pero un "bloque" se cuenta con
cualquier manejo + pausa de 15+ min. Un chofer con pausas frecuentes y
cortas llega a 3 bloques con poco manejo real. Verificado con datos
reales (`scripts/diagnosticar_jornada_chofer.js`): César tenía 3 bloques
con **7h54 manejo neto** → aviso falso. **Fix**: avisos por MANEJO NETO
acumulado (heads-up 11h, límite firme 12h). Clarificación Santiago: el
límite son 12h de manejo neto (las paradas de 15 min suceden DENTRO).

### Commits del día (9)

**Vigilador jornada (3)**:
- `1c9e0af` — cuota por manejo neto (CF jornadas_v2)
- `97e9acb` — `/jornada` del bot usa manejo neto + heads-up 11h + script diagnóstico
- `bf18767` — corrección límite: 12h (no 11h)

**Bot WhatsApp (2)**:
- `25c49cb` — comando admin `/enviar-jornada <DNI>` (manda al chofer su estado de jornada) + fix time-sensitive `jornada_v2_cuota_proxima`
- `cd3e658` — fix mock Firestore de agrupador.test.js (faltaba orderBy/limit) → bot 129/129

**Descargas PTO (1)**:
- `b647fc5` — dedup por (patente, ventana 15 min) en pantalla descargas

**Split functions/index.ts COMPLETADO (5)** — `6884 → 45 LOC (-99%)`:
- `383939c` auth.ts · `8dffd96` audit.ts · `6076075` comun.ts ·
  `e80bfae` volvo.ts · `442450c` telemetria.ts + index entry point puro

**Tests de flujo CF (2)** — sacado de "deferred":
- `acb6c5a` — `evaluarTickJornada` (máquina de estados pura) + 21 tests
- `b61375e` — 5 builders de resúmenes (puros) + 23 tests

### Estado de las suites

```
flutter test:        310/310 ✓  (sin cambios hoy)
functions npm test:  148/148 ✓  (de 104 → +44 tests del vigilador y resúmenes)
whatsapp-bot test:   129/129 ✓  (de 120 → +8 /enviar-jornada, +1 fix mock)
```

### Deploys pendientes (para Santiago, desde su PC)

1. `git push` — (probablemente ya pusheado sobre la marcha)
2. `firebase deploy --only functions` — propaga: **fix vigilador manejo
   neto** (jornadas_v2) + **split completo** (redeploy de las 31
   functions, cero cambio de comportamiento) + builders de resúmenes.
   Tarda unos minutos por el volumen.
3. **Bot**: el push dispara el auto-update de la PC dedicada en ≤5 min
   (toma `/enviar-jornada` + fixes). No requiere tocar la PC.
4. **Verificar del 18/5 si no se corrió**: `firebase deploy --only
   firestore:rules` (guard BORRADORES_VIAJE) + `firebase deploy --only
   firestore:indexes` (index JORNADAS DESC) — comandos separados.

### Validación natural mañana 8 AM ART

Que el resumen de jornadas a Molina (`resumenExcesosJornadaDiario`)
refleje bien los excesos con la lógica nueva de manejo neto.

---

## 📅 2026-05-18 EOD — Cierre del día (auditoría completa + tests + splits + bug horaArt)

**Sesión gigante** de auditoría profunda del proyecto con 6 agentes
paralelos + ~20 commits de fixes, refactors estructurales y tests.

### Lo más importante: 🐛 1 bug REAL descubierto por test

`functions/src/jornadas_v2.ts:horaArt()` devolvía **24** (no 0) para
medianoche ART en Node V8. La lógica de veda nocturna chequeaba
`horaActual < 6` → con 24, falso → **el chofer que arrancaba 00:00-00:59
ART NO recibía aviso de veda nocturna**. Ventana ciega de 1h/día por
al menos 3 refactors. Fix de 1 línea (`return h === 24 ? 0 : h`).
Commit `a4ab509`.

### Commits del día (16+)

**Sentry (4)**:
- `38315b1` — Panel: eficiencia combustible en L/100km (métrica AR)
- `ed24c66` — Filtros + rate limiter anti-storm en `beforeSend`
- `0bd873c` — SentryNavigatorObserver (breadcrumbs de ruta)
- `201c300` — Release name unificado Windows/Android/iOS

**Auditoría — fixes (8)**:
- `f68ecdb` — Regresión CHECKLISTS (chofer no veía si rotación de patente) + DNI maskeado en 4 logs
- `e499da2` — Bot: `/pausar` serverTimestamp + delay anti-baneo chunks 5-15s + rate limit pattern + cache silenciados
- `12fb37a` — Cloud Functions: limits defensivos + warn al alcanzar (resumen conducta, ICM semanal, EMPLEADOS)
- `0855510` — Rules: BORRADORES_VIAJE guard de owner + Index JORNADAS DESC + TTL COLA_WHATSAPP
- `7730393` — `npm audit fix` resuelve CVE HIGH (fast-xml-builder) + MODERATE (ws)
- `04716d7` — Cleanup: 4 scripts deprecated → `_deprecated/` + borrar logs viejos
- `0abbeca` — Docs: README 16 crons (vs 9 documentados) + MANUAL 6 roles (vs 4) + comment ICM outdated
- `4361c31` — CI: pin Flutter 3.41.7 en `ci.yml` + `ci_post_clone.sh` + `.flutter-version`

**Refactors estructurales (5)**:
- `95f6c27` — Split `logistica_viaje_form_screen.dart` 2823 → 5 archivos (patrón `part of`)
- `90edd44` — Extract helpers compartidos functions a `helpers.ts` (drift fix: jornadas_v2 capitaliza nombres + round-robin)
- `a6a90f5` — Split `functions/index.ts` iter 1-3: cleanup + dashboard + icm + mantenimiento
- `75f61f1` — Split iter 4: sitrack.ts
- `38f4acf` — Split iter 5: resumenes_diarios.ts (50% completado en total)

**Bot fix (1)**:
- `52c36a9` — TTL 36h en los 3 resúmenes diarios del bot (cierra gap residual del fix Fase 2)

**Tests (2)**:
- `a4ab509` — 16 tests TS (jornadas v2 helpers) + 20 tests Dart (ICM helpers) + **bug horaArt 24→0**
- `fd28d17` — 15 tests Dart ICM flujo completo con `fake_cloud_firestore`

### Estado de la suite post-sesión

```
flutter test:        310/310 ✓  (de 275 anteriores +35 nuevos)
functions npm test:   62/62 ✓  (de 46 anteriores +16 nuevos)
```

### Deploys pendientes (para Santiago)

1. `git push` — ~20 commits acumulados desde tu PC
2. `firebase deploy --only firestore:rules` — para que entre el guard BORRADORES_VIAJE
3. `firebase deploy --only firestore:indexes` — para crear el index JORNADAS DESC (comando separado por bug conocido del CLI)
4. `firebase deploy --only functions` — propaga: **fix bug horaArt** (veda nocturna 00:00) + limits defensivos + helpers extraidos + módulos splitteados
5. **Próximo build app** (Windows/Android/iOS) — propaga fixes Sentry + DNI mask + km/L → L/100km + regresión CHECKLISTS
6. **PC dedicada** toma fix bot automático en ≤5 min vía Scheduled Task auto-update (TTL 36h resúmenes + serverTimestamp pausar + rate limit cache)

### Pendiente para próximas sesiones

**Completar split de `functions/index.ts`** (50% restante, ver memoria `project_split_functions_index.md`):
- `auth.ts` (~1700 LOC, 5 functions: login + cambiar/resetear pwd + actualizar rol + rename DNI)
- `volvo_alertas.ts` (~1900 LOC) + `volvo_scores.ts` (~400 LOC)
- `telemetria.ts` (~350 LOC, depende de helpers Volvo, hacer DESPUÉS de volvo)

**Tests de flujos completos CF** (deferred honestamente — sesión propia):
- `tickVigiladorJornada` + resúmenes diarios CF
- Requieren `firebase-functions-test` SDK + mock manual de Firestore (Timestamp/FieldValue sentinels + estado mutable)
- Plan: arrancar por `resumenBotDiario` (el más simple) como proof of concept del setup
- Tiempo estimado: 3-4h SOLO para tener mock + 1 test funcionando, después escalar

**Items del audit deferred por decisión consciente**:
- Race ready/destroy bot whatsapp.js (complejo, baja probabilidad)
- Match sufijo 10 dígitos `/jornada` (decisión de negocio: aceptar riesgo bajo)
- DNIs hardcoded → META/destinatarios_alertas (esperar cambio real de persona)
- Code-signing Windows installer ($80/año, decisión gasto)
- Major bumps Flutter (sentry 8→9, win32 5→6, fl_chart 0→1 — riesgo breaking)

Ver memoria `project_tests_logica_negocio.md` y `feedback_sentry_observabilidad.md` para detalle.

---

## 📅 2026-05-16 EOD — Cierre del día (iOS TestFlight operativo)

**Logro del día**: 🎉 **App instalable en iPhone via TestFlight**.
Build #11 Xcode Cloud con log 100% limpio (3 exports OK, 0 errores).
TestFlight Internal Testing andando — Santiago ya tiene la app
instalada en su iPhone.

### Commits del día (4)
- `5f97188` — `CFBundleIconName=AppIcon` en Info.plist (faltaba ícono
  en TestFlight, requisito iOS 13+).
- `14eb01a` — `ENABLE_APP_INTENTS_INTEGRATION=NO` en Podfile post_install
  (apaga 19 warnings cosméticos por pod).
- `cd585f0` — `install_profile_optional` en `ci_post_clone.sh` para
  silenciar errores ruidosos del log (~200 errores de "No profiles
  for..." en exports Ad Hoc + Development).
- `a7acc95` — `NSLocationAlwaysAndWhenInUseUsageDescription` en
  Info.plist (warning ITMS-90683 del email Apple post-upload).

### Lo que se hizo en App Store Connect / portal Apple
- 2 profiles nuevos creados en developer.apple.com:
  - `Coopertrans Movil Ad Hoc` (NLN3W2KT9J-style)
  - `Coopertrans Movil Development`
  - Ambos con dummy UDID `00008101-001A2B3C4D5E6F70` (Apple no valida
    que el UDID sea real, solo formato).
- 2 secrets nuevos subidos al workflow Xcode Cloud:
  - `IOS_ADHOC_PROFILE_BASE64`
  - `IOS_DEV_PROFILE_BASE64`
- Workflow ahora tiene **5 secrets** total (cert + password + 3 profiles).
- Build #11 disparado → todo OK.
- Grupo "Vecchi Choferes" creado en TestFlight Pruebas Externas (vacío
  todavía).

### Pendiente de push (sin pushear todavía)
```powershell
git push  # commit a7acc95 (Info.plist con NSLocationAlways...)
```
Sin esto, el próximo Build #12 vuelve a tirar el warning ITMS-90683
(no bloquea, pero queda ruidoso).

### Pendiente para próxima sesión — completar External Testing
El Build #11 está OK en TestFlight Internal pero falta para External:

1. **App Store Connect → Distribución → Información de la app**:
   - Categoría principal: `Productividad` (o `Negocios`)
   - Clasificación por edades: completar cuestionario respondiendo
     "No"/"Ninguno" a todo → resultado `4+`.
   - NO hace falta cargar Encryption Documentation (exenta por usar
     solo cifrado estándar del OS — `ITSAppUsesNonExemptEncryption=false`).

2. **TestFlight → "Información para las pruebas"** (sidebar Adicional):
   - Email comentarios: `santiagocoopertrans@gmail.com`
   - Información de contacto: nombre + email + tel
   - Descripción Beta (~200 chars sobre qué hace la app)
   - Política de privacidad: URL de Firebase Hosting (la misma que
     Play Store)
   - Qué probar: "Login con DNI + clave. Probar navegación general"
   - Cuenta de prueba: DNI + clave de un admin/test

3. **TestFlight → "Vecchi Choferes"** → tab Compilaciones → "+" →
   agregar Build 11 → **Submit for Beta App Review** (1-2 días, primer
   build external).

4. Después de Beta Review aprobado:
   - Cargar choferes vía CSV (sin header: `email,first_name,last_name`)
     o vía Public Link (`testflight.apple.com/join/XXXXXX`).
   - Solo Apple IDs válidos (típicamente Gmail).

### Helpers iOS para futuro
- `G:\Mi unidad\ClaudeCodeSync\secrets-ios\convertir_profiles_extra.ps1` —
  convierte .mobileprovision a base64 limpio para subir como secret.
- `G:\Mi unidad\ClaudeCodeSync\secrets-ios\README.md` — manual completo
  con instrucciones de regeneración cert + 3 profiles.

---

## 📅 2026-05-15 EOD — Cierre del día (lo que quedó deployable)

Sesión gigante: 17 commits + bump 1.0.55+58 → 1.0.56+59. Lo que sigue
es el orden recomendado para mañana sábado / lunes:

### Deploys pendientes
```powershell
# Trae lo del día (release_completo.ps1 ya pusheó hasta 974dbaf):
git push                              # por si quedó algo

# Backend:
firebase deploy --only firestore:rules,firestore:indexes
firebase deploy --only functions

# Una vez deployado el vigilador v2, limpiar la legacy:
node scripts/limpiar_jornadas_chofer_legacy.js --dry-run
node scripts/limpiar_jornadas_chofer_legacy.js --apply
```

### Releases ya hechos hoy
- ✅ 1.0.55+58 (release_completo.ps1) — adelantos para todo personal +
  primera versión del cron `resumenConductaManejoDiario`.
- ✅ 1.0.56+59 (974dbaf) — módulo ICM completo (hub + ranking + reporte
  semanal + detalle por chofer + mapa de calor placeholder) + reporte
  Excel ICM en menú Reportes + sobrevelocidades por chofer en resumen
  Molina + capability `verIcm` (admin/supervisor/seg_higiene).

### Cosas a validar mañana 8 AM ART (cuando llegue el resumen Molina)
- Mensaje del cron `resumenConductaManejoDiario` con el formato nuevo
  unificado (Sitrack + Volvo AEBS/ESP, sin jerga técnica) + línea
  "Peor exceso: X km/h (límite Y, +Z)" cuando hubo sobrevelocidad
  (event_id 8/9).
- Mensaje del cron `resumenExcesosJornadaDiario` (vigilador v2 con
  modelo bloques 3×4h).

---

## 📅 2026-05-16 (sáb) — ya cumplido / re-evaluar consumer Sitrack

El re-análisis de la ventana 60h se corrió 2026-05-15 (`scripts/analizar_sitrack_eventos.js --horas 60`):
- 7437 eventos / 124 evt/h.
- Conducción peligrosa = 573 eventos (7.7%): 407 salida de carril, 92
  sobrevelocidad, 37 giro brusco, 23 frenada brusca, 10 distancia
  frenado insuficiente, 1 aceleración brusca, 2 colisión.
- 87.9% chofer identificado, 52.3% con cartografía.

**Decisión tomada 2026-05-15**: NO armar consumer Sitrack adicional —
los 10 tipos peligrosos ya entran al `resumenConductaManejoDiario` y
al módulo ICM. Está cubierto end-to-end.

---

## 🟡 Pendientes operativos (sin fecha fija)

### Bot WhatsApp en PC dedicada 24/7 — pendiente migración física
Kit completo armado en `G:\Mi unidad\ClaudeCodeSync\bot-pc-dedicada\`
(683 MB). Cuando Santiago prenda la PC dedicada (Windows Pro recién
instalado):

1. Esperar que Drive sincronice la carpeta.
2. Click derecho `instalar_todo.ps1` → Run with PowerShell (admin).
3. ~10-15 min: instala Node+Git via winget, clona repo, copia los 3
   archivos secret, npm install, registra servicio NSSM, configura
   Windows 24/7, instala auto-update Scheduled Task, smoke test.
4. Cuando confirme heartbeat OK desde `bot_estado_remoto.js`, apagar
   bot en PC oficina (`Stop-Service CoopertransMovilBot` +
   `Set-Service ... -StartupType Manual`).

Ver memoria `project_bot_pc_dedicada.md` para detalle.

### Acceso remoto PC dedicada → casa
Recomendado: Tailscale + RDP nativo. Setup en `docs/SETUP_PC_DEDICADA_BOT.md`
(actualizar con sección Tailscale cuando se concrete). Windows Pro ya
instalado en la PC dedicada — RDP funciona out-of-the-box.

### Multi-tramo Logística — features chicas
- Reordenar tramos (drag handle).
- Duplicar tramo (botón "+ copiar").
- Validar encadenamiento (origen tramo N+1 = destino tramo N).
- Buscador en empresas y tarifas (igual al de ubicaciones).
- Pantalla "viajes borrados" para revisar/restaurar soft-deleted.
- Exportar liquidación a Excel.

### Volvo Driver/Tachograph Files API
Módulos activos pero feeds vacíos. Pedir a Volvo Argentina alta de 48
choferes + activación transmisión por unidad.

### iOS — Listing público App Store (cuando se quiera publicar)
- Capturas de pantalla (mínimo iPhone 6.7" y 6.5").
- Descripción larga + corta + keywords.
- Material similar a `docs/PLAY_STORE_LISTING.md` (reutilizable).
- DSA Trader Status para distribución en EU (marcar "No comerciante"
  para uso interno sin facturación a usuarios).

### Refinamientos ICM (no urgentes)
- Cuando haya histórico de odómetros por patente (snapshot diario
  desde TELEMETRIA_HISTORICO), reemplazar el baseline `1 evento = 100
  km` del calculator por cálculo real. El factor del ICM (default 5)
  podría calibrarse para que matchee con el Tablero ICM YPF.
- Iconos custom para ICM verde/amarillo/rojo (hoy usa `Icons.leaderboard`
  + colores de fondo).
