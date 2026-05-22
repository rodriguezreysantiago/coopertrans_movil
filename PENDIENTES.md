# Pendientes follow-up

Cosas que requieren acción nuestra en una fecha específica. Para roadmap general
del proyecto, ver `ESTADO_PROYECTO.md`. Para procedimientos operativos, `RUNBOOK.md`.

Convención: orden cronológico (los próximos arriba). Sacar el ítem cuando se ejecuta.

---

## 📅 2026-05-22 PM (3) — Auditoría general + dedup Emmanuel + F.931 iOS + cachatore

Sesión grande de cierre. 7 commits (`f334604` → `46626c6`), todo en main + pusheado.
CF afectadas **deployadas** (toman efecto ya); cambios de app van en el **release de hoy**.

### Hecho — dedup del parte de mantenimiento a Emmanuel (`f334604`, CF deployada)
- Emmanuel recibía 2 informes con lo MISMO (luces de tablero Volvo). Se **eliminó** el
  "Resumen diario — Alertas de mantenimiento" del bot (`cron_mantenimiento_diario` +
  builder `buildResumenMantenimientoDiario`). El **Parte de mantenimiento** de la CF
  (`resumenMantenimientoVehiculosDiario`) ahora suma lo único exclusivo del otro:
  eventos TPM/TTM/tacógrafo (24 h, con horario). `ALERTAS_RESUMEN_DESTINATARIO_DNI`
  quedó **obsoleta** (sin efecto). Pendiente menor: limpiar la regla `alertasVolvoDiario`
  de `health.js` + el texto de ayuda en `admin_estado_bot_widgets.dart` (tarea spawneada).

### Hecho — cachatore (`1babce3` + `8d9d970`, deploy por auto-update PC dedicada)
- **Búsqueda visible en los logs**: el barrido latente ahora loguea (throttle 30 s) qué
  está buscando y qué ve ("la agenda no tiene huecos…") para que entre latidos no
  parezca colgado.
- **Aviso de cancelación**: al cancelar un turno, manda WhatsApp al **chofer** + al
  **encargado de logística (Errazu, 25022800)**, igual que reservar/reagendar.

### Hecho — auditoría general profunda (agentes por subsistema, hallazgos VERIFICADOS)
1 ALTO + 6 MEDIO, todos arreglados con tests donde aplica:
- **[ALTO]** `report_liquidacion.dart`: `slugSeguro` hacía `substring(0, raw.length)` sobre
  el string ya saneado → **RangeError** y NO salía la liquidación (ej. "Vecchi S.R.L."). `eb3dcb9` +7 tests.
- **[MEDIO]** `jornadas_v2`: `bloque_excedido` no se reseteaba por bloque → aviso de "4h
  continuas" salía 1 vez por jornada. `d1e79ae` (CF deployada) +test.
- **[MEDIO]** RBAC `app_router`: cada ruta admin ahora pide su capability **fina** (antes
  todas pedían `verPanelAdmin` que GOMERIA/SEG_HIGIENE tienen → podían abrir pantallas
  ajenas por deep-link). `eb3dcb9`.
- **[MEDIO]** `mantenimiento.ts`: doble "notificaciones reanudadas" si fallaba el delete →
  flag `reanudacion_encolada`. `d1e79ae` (CF deployada).
- **[MEDIO]** `volvo.ts`: `_esAlertaMantenimiento` leía solo `.type` (vacío en el 100% de
  la data real; el subtipo viene en `triggerType`) → ahora `triggerType ?? type`. `d1e79ae` (CF deployada).
- **[MEDIO]** `cachatore_hub`: `_confirmar` sin try/catch → spinner infinito si fallaba
  Firestore. `eb3dcb9`.
- **[MEDIO]** `admin_shell`: ráfaga de avisos de revisiones viejas al abrir (consumía el
  flag con el snapshot de cache) → ignora `isFromCache`. `eb3dcb9`.

### Hecho — F.931 no se veía en iOS (`9872c41` → `46626c6`)
- Síntoma "cartel azul con código" = banner de pdfrx `FPDF_GetLastError=3`. Verificado:
  data/permisos/URL OK (el 931 es un PDF real de **18 MB**). pdfrx `PdfViewer.uri`
  streamea/cachea y falla con PDFs pesados en iOS. **Fix**: en móvil descargamos el PDF
  completo (dio) y lo renderizamos in-app desde bytes (`PdfViewer.data`) con spinner de %;
  web sigue con `PdfViewer.uri`; "Abrir en el navegador" queda solo de último recurso.
  **Validar en TestFlight** con VOGEL.

### Bundle BAJO HECHO (commit `b747407`, mismo día PM)
Cerrado el bundle de menores. CF `estadoVolvoPoller` deployada con lock-tick.
- HECHO: estadoVolvoPoller lock; commands.js phone strict canónico; historico.js
  -15 helpers obsoletos; checklist `_ItemPregunta` Stateful con controller; cuotas
  docstring honesto; `icm_historico_service.dart` deprecado a stub.
- SKIPPED con justificación (no son bugs reales): SITRACK_EVENTOS limit (ya tiene
  warn + volumen << cap); Python TZ -3 (AR no DST); dedup del bot por texto
  (defensa secundaria, cambiar = behavior change con riesgo).

### ⚠️ Queda pendiente (NO bloquea el release)
1. **Limpiar `alertasVolvoDiario`** de `health.js` + ayuda en `admin_estado_bot_widgets.dart`
   (footgun: `ALERTAS_RESUMEN_DESTINATARIO_DNI` ya no reenruta nada).
2. **(opcional)** Si re-suben el F.931 como PDF más liviano, abre al instante en la app.

---

## 📅 2026-05-22 PM (2) — Revisión profunda ICM + preparación para PREMIOS/CASTIGOS

Santiago: "revisión profunda del ICM archivo por archivo, card por card... quiero
que quede perfecto porque vamos a empezar con el sistema de premios y
penalizaciones". 2 agentes de auditoría (UI + pipeline) + exploración EN VIVO de
Sitrack y Volvo (sesiones logueadas).

### Hecho — blindaje de correctitud (commit `5651843`, en main, necesita release)
- Universo rankeable = actividad **Y** DNI real (cierra el "fantasma sin chofer"
  en top5/Excel/tablero). Comparativa mes-a-mes ya no confunde 0=sin-infracciones
  con 0=sin-actividad. Conteos del header coherentes con las filas. Excel UNIDADES
  respeta excluirPatente. Formato AR en infracciones. + tests de regresión.

### Hecho — fundación para premios (commits `20ca8a0` + `1931a0e`, necesita release)
- **Tendencia diaria en la card de inicio**: `tendencia_diaria[]` (ICM de flota
  día por día, de `rankingItemsByDay`) en `ICM_OFICIAL/{mes}`. La card ya no
  espera meses; muestra el mes en curso día por día. Backfill 2026-05 cargado.
- **Ranking SEMANAL + mensual**: `sync_icm.py` escribe también
  `ICM_OFICIAL_SEMANAL/{lunes YYYY-MM-DD}` cada corrida; ranking con chips
  Semana/Mes/Mes anterior. Regla deployada. Data real ya en prod (semana
  2026-05-18: ICM 16.66, peor HIDALGO 95.5 ≠ peor mensual LESCANO 61).

### Hecho — snapshot inmutable de cierre (commit `e4f538c`)
- `ICM_OFICIAL_CIERRE/{YYYY-MM}` (mes anterior, congela día ≥4) +
  `ICM_OFICIAL_CIERRE_SEMANAL/{lunes}` (semana lun→dom anterior, congela desde el
  martes). create-once (`congelado:true`, nunca sobreescribe) → la liquidación se
  hará sobre un número que no cambia. Validado: congeló abril (15.67) + semana
  2026-05-11 (20.23); 2da corrida confirmó inmutabilidad. Reglas read deployadas.
- **BUSCIO/no-choferes filtrados** del ranking (commit `b393951`); BASTIAS ya con
  DNI cargado (Santiago). Docs limpios: 0 sin-DNI, 0 no-choferes.

### ⚠️ PENDIENTE
1. **Flujo de premios/castigos** (cuando Santiago lo defina): leer los CIERRE,
   calcular premio/castigo (top 5 mejores/peores semanal+mensual ya disponibles),
   y decidir "cómo avisar". El respaldo de datos ya está listo.
2. **Mapa de calor** (hoy placeholder): Sitrack tiene Control Conducción /
   H. Posición / Monitor Eventos con eventos geolocalizados → construible.
3. **Enriquecer más** (opcional, gratis en la misma respuesta): distancia+tiempo
   urbano vs ruta por chofer, excesos/agresiva por vehículo.
4. **Volvo "Informe de seguridad"**: score de conducta propio de Volvo, candidato
   a métrica SECUNDARIA interna para premios. Extracción aparte (no es el oficial).

---

## 📅 2026-05-22 PM — ICM OFICIAL de Sitrack ingerido + automatización dedicada

Santiago: "esa página de Sitrack es de donde saca YPF el ICM, ¿no podemos
replicar esa info?". **Sí, y resuelve de raíz el "framing" del ítem de abajo:**
Sitrack (proveedor satelital) YA calcula el ICM con la cartografía de segmento
vial que nosotros NO tenemos → ingerimos SU número en vez de estimar.

### Hecho + validado
- **`sitrack_sync/`** (Playwright): login portal site5 (usuario **SantiagoRRey**,
  reCAPTCHA pasivo) → endpoint `get_ranking_data` (JSON por chofer, match por
  **DNI**) → `ICM_OFICIAL/{YYYY-MM}`. Escala INVERTIDA (más bajo = mejor; flota
  ~20, peor LESCANO 64.5). Parser puro + 6 tests. Regla read deployada.
- **Automatización dedicada**: 2 Scheduled Tasks (Volvo taller 05:10, Sitrack
  ICM 06:10) validadas end-to-end por la tarea (`LastTaskResult 0`), reinicio-OK.
  Detalle + lecciones (prioridad 7→5, pipe→archivo, Volvo por **fetch directo**
  porque la SPA no renderiza bajo la tarea) en `project_bot_pc_dedicada.md`.
- **Bot**: `BOT_PC_ID` de la dedicada corregido a `dedicada` (era `oficina`);
  log nombra admins/destinatarios de resúmenes (no solo choferes). Tests 129/129.

### Fase B — rework del módulo a la escala oficial ✅ HECHO
- Módulo ICM (ranking / reporte mensual / detalle), card de inicio del tablero
  ejecutivo y Excel de auditoría ahora leen `ICM_OFICIAL` (más bajo = mejor,
  severidad de Sitrack NO/LOW/MEDIUM/HIGH). Service nuevo
  `icm_oficial_service.dart` (modelos + helper de color + derivaciones) con 12
  tests puros. `flutter analyze` limpio + 405 tests verdes. Commits `2ddc903`
  (módulo + card) y `56ea03c` (Excel). Validado contra la data real de 2026-05.
- El CESVI propio (cliente `icm_calculator`/`icm_historico_service` + server
  `recomputeIcmSemanalScheduled` → `ICM_SEMANAL`) queda VIVO pero
  **desconectado de la UI**. Esto vuelve MOOT el ítem "framing" de abajo.

### ⚠️ PENDIENTE
- **Release de la app** (lo larga Santiago): sin release los usuarios siguen
  viendo el módulo viejo (CESVI ~94). El número oficial ya está en Firestore;
  la card de inicio se actualizará al reabrirse SOLO tras el release (cambió el
  código que la arma, no solo el dato).
- **Decisión futura (no urgente)**: si nadie consume `ICM_SEMANAL` ni el CESVI
  semanal, retirar el cron `recomputeIcmSemanalScheduled` + el path cliente
  CESVI. Hoy quedan como oráculo de los tests de paridad — no tocar sin decidir.

---

## 📅 2026-05-22 — Rediseño del ICM (#49): "todo marca ~100"

Santiago: "estamos haciendo mal los cálculos, los rankings no me parecen
acordes, las cards marcan todo 100". Diagnóstico contra datos reales lo
explicó: el ICM se calculaba sobre las **JORNADAS del vigilador** (rotas:
ventanas 10-22h con 1.3h de manejo) → el **41% de las infracciones caía
fuera de toda ventana**; y el km salía del odómetro **por evento** (los
eventos bruscos no traen odómetro) → el filtro km>=10 descartaba casi
todo → ICM_SEMANAL/W20 = **99.59 todo verde**.

### Hecho + deployado + validado en vivo
- Unidad: **(chofer, día ART)** en vez de jornada (no pierde eventos).
- **km POR PATENTE** (odómetro de eventos de movimiento 98%) prorrateado
  al chofer. Sin fatiga (no hay señal real). Umbrales **YPF 91/71** (era
  80/60) en los 4 lugares. `combinarJornadas` peso=max(km,1). Flota =
  media simple. Detalle en memoria `project_modulo_icm.md`.
- Server deployado + **W20 recomputado**: pasó de **99.59 → 93.92**, con
  28 verdes / **13 amarillos** / 0 rojos sobre 41 choferes (antes todo
  verde). Tests flutter 74/74 + functions 188/188. Commit `8eb6502`.
- La card de inicio lee el doc del server → ya muestra el número nuevo
  **sin release** (se actualiza al reabrir la pantalla).

### ⚠️ SUPERSEDED por la Fase B (ICM oficial, arriba)
El rediseño CESVI se hizo y deployó, pero la **Fase B lo reemplazó en la UI**:
en vez de estimar internamente (no teníamos segmento vial), ahora ingerimos el
ICM oficial de Sitrack y lo mostramos tal cual (es el que audita YPF). El CESVI
queda vivo en el server pero desconectado de pantallas. Único pendiente real:
el **release** (ver arriba).

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
