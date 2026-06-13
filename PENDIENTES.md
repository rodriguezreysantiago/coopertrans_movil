# Pendientes follow-up

Cosas que requieren acción nuestra en una fecha específica. Para roadmap general
del proyecto, ver `ESTADO_PROYECTO.md`. Para procedimientos operativos, `RUNBOOK.md`.

Convención: orden cronológico (los próximos arriba). Sacar el ítem cuando se ejecuta.

---

## 🎯 VIGENTE — consolidado al 2026-06-10 (revisión total)

Única sección a mirar para saber qué está abierto. El log cronológico de abajo
es el historial (sus "PENDIENTE" viejos pueden estar resueltos — ante la duda,
manda esta lista). Actualizar acá cuando algo se cierra o se abre.

### Operativo / corto plazo
- [ ] **DEEP LINKS — Vertical 1 (commit `0df2549`, 2026-06-13): infra + handler LISTOS,
  falta ACTIVAR**. Cada aviso de WhatsApp podrá abrir la app en la pantalla exacta
  (`coopertrans-movil.web.app/app/ir/{destino}`; destinos: jornada, vencimientos,
  equipo, perfil, home). Hosting `.well-known` DEPLOYADO y verificado (200). App
  handler (`DeepLinkService`) + manifest Android + entitlements iOS en el repo,
  **viajan con el próximo release**. Pasos para que funcione de verdad:
  1. **Android SHA-256**: Play Console → Integridad de la app → "Certificado de la
     clave de firma de apps" → copiar el SHA-256 → reemplazar el placeholder en
     `public/.well-known/assetlinks.json` → `firebase deploy --only hosting`.
  2. **iOS**: Xcode → Runner → Signing & Capabilities → **+ Associated Domains** →
     `applinks:coopertrans-movil.web.app` (Xcode escribe el pbxproj + habilita la
     capability en el App ID + regenera el provisioning profile). El entitlements
     ya está creado para que lo reuse.
  3. **Bot/functions appendeando los links a los avisos** (hacer JUNTO al release,
     no antes — si no, los choferes reciben links que caen en la página de fallback
     hasta que actualicen): footer `/app/ir/{destino}` en vencimientos (bot
     cron.js), jornada (functions) y devolución de reclamos.
  4. **Release** de la app (sube el handler). Después: tappear un link de prueba
     en Android e iOS para confirmar que abre la app (no el browser).
  **Vertical 2 (push FCM: turnos + failover + sesión)**: **fundación backend HECHA
  y DEPLOYADA** (commit `4dcb62e`): `push.ts` con `enviarPush` (resuelve tokens de
  `EMPLEADOS/{dni}/dispositivos`, multicast FCM, poda muertos) + cola `COLA_PUSH`
  multi-productor + trigger `procesarColaPush` + rules + TTL + tests. Inerte hasta
  que la app registre tokens. **Falta**:
  1. **App `PushService`** (Flutter, ships con release): `firebase_messaging` +
     pedir permiso + token → `EMPLEADOS/{dni}/dispositivos/{installId}` + refresh +
     foreground (mostrar notif local) + tap → ruta (reusa `DeepLinkService.rutaDeDestino`)
     + background handler. **OJO**: `firebase_messaging` NO soporta Windows desktop
     → guards de plataforma + `flutter build windows` de verificación (la app admin
     es Windows y está LIVE).
  2. **Nativo iOS**: Push Notifications capability + Background Modes (remote
     notification) + **APNs Auth Key (.p8) cargada en Firebase Console** (sin esto
     el push NO llega a iPhone). Android: `POST_NOTIFICATIONS` en el manifest (13+).
  3. **Wiring de los 3 productores** → `encolarPush()` / `COLA_PUSH`: turno del
     cachatore (Python nube.py), failover de críticos cuando el bot cae
     (bot_alerta_externa.ts), cambio de rol/sesión (auth.ts).
- [ ] **LOTE FASE 1 INFRA (2026-06-12, noche — revisado adversarialmente antes de prod)**:
  (a) **Backup DIARIO** (era semanal — RPO 7d→1d) con **auto-verificación anti-drift**:
  compara `collectionIds` vs `listCollections()` real y Telegram si algo quedó sin
  clasificar; chequeo estático da 0 gaps (65 colecciones clasificadas). Estado en
  `STATS/ultimo_backup`. DEPLOYADO. (b) **Censo mensual** (`censoColeccionesMensual`,
  día 1 03:30) → `STATS/censo_{mes}` + diff vs mes anterior → WhatsApp (crecimientos
  >40% o ≥10x, colecciones nuevas). DEPLOYADO. (c) **Healthchecks.io** cableado en el
  bot (`HEALTHCHECKS_PING_URL`) y el vigía (`HEALTHCHECKS_PING_URL_VIGIA`, en hilo
  daemon) — **TENÉS QUE crear los checks gratis en healthchecks.io y pegar las URLs en
  los .env** (sin la env var es no-op; ver .env.example). (d) **Budget GCP $50** con
  alertas 50/90/100% a tu mail (+ tripwire pre-existente de $10). (e) **Dependabot**
  alerts + security-fixes ON + `.github/dependabot.yml` (updates mensuales agrupados por
  stack, majors Firebase ignorados). (f) **Coverage** medido e informativo en los 4 jobs
  del CI. (g) **Bump actions a Node 24** (checkout/setup-node/setup-python v6, gitleaks
  v3) + `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` — adelanta el cambio que GitHub fuerza el
  16/6. (h) **Drill de restore** documentado en RUNBOOK (DRILL #1 pendiente de correr).
  **Seguimiento**: crear los checks de Healthchecks; correr el drill de restore 1 vez;
  validar el primer censo (1/jul) y el primer backup diario.
- [ ] **ALERTA DE COLA EXCEDIDA EN PLANTA (Fase 2 — ACTIVA desde 2026-06-12,
  noche)**: el `zonaDescargaPoller` avisa por WhatsApp cuando una unidad lleva
  más del umbral DENTRO de una geocerca sin salir (default 120 min; 1 aviso por
  estadía; incluye el caso GPS-dormido-adentro). Config sin redeploy:
  `META/config_alerta_cola` {activo, umbral_min}. Destinatario: key M5
  `colaPlantaExcedida` (fallback = Santiago; la key NUEVA todavía no aparece en
  el catálogo de la pantalla Destinatarios — agregarla a la UI con el próximo
  release si se quiere redirigir a Errazu). **Seguimiento**: validar el primer
  episodio real y calibrar el umbral con datos (después de 1-2 semanas de
  ZONA_DESCARGA_HISTORICO se puede elegir percentil por zona).
- [ ] **DEPENDABOT: alertas de seguridad en deps TRANSITIVAS de firebase-admin**
  (aparecen como runs rojos de "Dependabot Updates" — NO es el CI, que está
  verde 5/5). Cluster: `@grpc/grpc-js` (high, DoS), `protobufjs`/`qs`/`uuid`
  (medium, DoS/bounds) — TODAS transitivas vía firebase-admin 13.10 →
  google-cloud → grpc/protobuf/uuid. Explotabilidad real BAJA (el bot/functions
  son CLIENTES de las APIs de Google, no servidores expuestos; son advisories
  server/parser-side). Dependabot security-update no puede parchear transitivas
  sin el padre → los runs fallan.
  **INTENTO 2026-06-13 (firebase-admin 13→14): BLOQUEADO POR UPSTREAM.**
  firebase-functions (última = 7.2.5) tiene peer `firebase-admin ^11||^12||^13`
  — NO acepta 14, y NO existe release de firebase-functions que lo soporte aún.
  Adoptar admin 14 = correr combo no soportado por upstream en las functions de
  plata/jornadas/auth (+ admin 14 dropea Node 18/20: rompería el bot en la
  dedicada, que corre Node 18+). Además el bump NO limpiaba todo (quedaban 8
  moderate de qs/uuid/protobufjs vía @google-cloud/storage). Probado y
  REVERTIDO al known-good (admin 13.10, 373 tests verdes).
  **Decisión recomendada**: como las 4 advisories son NO explotables en nuestro
  contexto (app B2B interna, Google es el "servidor", ningún input atacante
  llega a esos paths) y forzar `overrides` de grpc-js bajo Firestore es riesgo
  de transporte en prod >> riesgo del advisory → **dismissear las alertas como
  riesgo tolerable** (`gh api .../dependabot/alerts/{n} -f state=dismissed
  -f dismissed_reason=tolerable_risk`) Y/O esperar a que firebase-functions
  publique soporte de admin 14 (Dependabot ofrecerá el bump alineado, CI-gateado).
  NO forzar overrides de grpc-js. El Python usa firebase-admin 7.4.0 (paquete
  distinto, no afectado).
- [ ] **CRON DE LOS CRONS (Fase 1 del plan — ACTIVO desde 2026-06-12)**: los 25
  onSchedule registran latido en `CRON_HEALTH/{id}` (wrapper `onScheduleConLatido`
  en comun.ts) y `cronWatchdog` (cada 3 h, `cron_health.ts`) avisa por Telegram +
  WhatsApp (key `mantenimientoBot`) si un cron está muerto (tolerancia por
  cadencia: pollers 3 h, diarios 26 h, censo 33 días) o su última corrida falló.
  Anti-spam 24 h por cron; silencio = OK. **Seguimiento**: validar el primer
  episodio real (o forzar uno pausando un cron en Cloud Scheduler). Al crear un
  cron nuevo: wrapper + entrada en `REGISTRO_CRONES` (hay test que lo exige).
  Rentabilidad por tarifa y alerta de robo de gasoil quedaron PENDIENTES a pedido
  de Santiago (2026-06-12).
- [ ] **ROTAR LA PASS DEL .p12 DE iOS**: gitleaks encontró
  `IOS_DIST_CERT_P12_PASSWORD` en texto plano en ESTADO_PROYECTO.md (repo
  público; ya REDACTADA del árbol 2026-06-12, pero el historial la conserva).
  El .p12 está solo en Drive `secrets-ios/` → riesgo moderado. Rotación (sin
  Mac): `openssl pkcs12` re-export del .p12 con clave nueva → actualizar la
  env var `IOS_DIST_CERT_P12_PASSWORD` en el workflow de Xcode Cloud → subir
  el .p12 nuevo al Drive. 10 minutos.
- [ ] **CI ampliado (2026-06-12, noche)**: job `python` (cachatore 73 tests +
  parsers ICM/Volvo 9+9 — corrían solo a mano en la dedicada) + job `gitleaks`
  (secretos en cada push; `.gitleaks.toml` con falsos positivos triagados:
  API keys cliente Firebase + Podfile.lock; `.gitleaksignore` con el histórico
  aceptado). Ruleset de main completado con `deletion` (ya tenía
  non_fast_forward + PR + status checks + linear history). requirements.txt
  materializados en cachatore/ y los 2 sync/. **Seguimiento**: confirmar el
  primer run verde de los 2 jobs nuevos.
- [ ] **AUDITORÍA TOTAL 2026-06-12** (`docs/auditorias/2026-06-12_reporte.md` + anexo):
  7 bugs ALTA confirmados adversarialmente. **Hecho el 2026-06-12**: Push Protection +
  Secret Scanning activados en GitHub; fix comisión $0 en recálculo (`viajes_service.dart`
  + 3 tests de regresión — espera release de la app); regla AGENTE_CONVERSACIONES +
  TTL `expira_en` (rules + indexes DEPLOYADOS — dashboard del agente funciona de nuevo);
  backup completado con 16 colecciones faltantes (function DEPLOYADA — verificar el
  export del próximo domingo); fix telemetría #5 (fecha Timestamp/String — consumo
  mensual y labels del gráfico vuelven a aparecer, retroactivo sin migración) y fix
  gomería #6 (montar() resuelve solo la base del semáforo desde KM_ACTUAL) — ambos
  esperan release de la app, +10 tests. También hecho (2026-06-12, tarde): política
  de privacidad #7 reescrita y PUBLICADA (MD + privacidad.html deployado — declara
  Sitrack/jornadas/iButton/agente IA + retenciones + permiso de ubicación opcional);
  hardening del cierre de reclamos DEPLOYADO (kill-switch fail-open + idempotencia
  diaria + timeout 540s/512MiB); `.limit(2000)` + aviso de truncado en el mapa Volvo;
  unicode minus normalizado en vértices de geocercas + validator que avisa líneas no
  parseadas. Cierre del lote (2026-06-12, noche): backfill de gomería APLICADO
  (500/510 montajes con base real de telemetría del mismo día — semáforo activo
  apenas salga release); #13 null-safety jornada_dia (patrón v3); #15 chunking del
  batch de zonas (flush a 400 ops, DEPLOYADO); README regenerado desde el código
  (24 crons reales con horarios, 16 onCall, 2 triggers, 24 features, módulos
  functions al día — el catálogo viejo tenía 9 crons faltantes y un trigger que ya
  no existe). **Abierto**: credenciales Sitrack en el historial público (no se
  pueden rotar — riesgo aceptado; evaluar purga de los 3 docs igual); #8 viaje
  duplicado por remito fallido (decisión de diseño pendiente: ¿subir remito antes
  de crear el doc, o flujo "retomar guardado"?). **#12 CERRADO (2026-06-12,
  noche)**: tests de firestore.rules en dos capas — vacuna estática
  AppCollections↔rules dentro de `npm test` (345 tests functions) + suite de
  emulador `npm run test:rules` (34 asserts: whitelist self-service, anti-escalada
  supervisor, ownership jornadas, plata, server-only). Java Temurin 21 instalado
  para el emulador. Correr `test:rules` antes de deployar cambios de rules
  (queda pendiente automatizarlo en CI). El plan estratégico en 4 fases vive en el reporte
  (Fase 2 = features de ROI directo: rentabilidad por tarifa, robo de gasoil,
  viajes sin facturar, detention YPF, informe ejecutivo mensual).
- [ ] **macOS**: confirmar el estado del re-submit a Apple post-fix del
  entitlement (rechazo 2026-06-06, fix hecho ese día — ver entrada).
- [ ] **Play Store**: confirmar que el AAB de la serie vigente (1.2.24) esté
  subido/aprobado.
- [ ] **Windows**: PCs con versión instalada < 1.2.3 necesitan re-correr el
  setup 1 vez (link estable de `cooper-trans.com.ar/app`) para que el update
  in-app ande solo. También aplica el cambio a installer per-user (2026-06-10).
- [ ] **"+build" visible**: Santiago dice ver `+10202` en "varios lugares";
  código actual limpio — falta captura/pantalla exacta para confirmar si era
  la versión pre-fix (entrada 2026-06-07).
- [ ] **Validación visual pendiente**: Gomería (stock oculto + conteo a ciegas)
  y módulo Vacaciones (Gantt + saldos; 3 proporcionales de 1er año a mano).
- [ ] **Buzón de discrepancias — cierre AUTOMÁTICO (CF `cerrarReportesJornadaDiario`,
  08:00 ART, ACTIVA 2026-06-11)**: cruza los reclamos directos de jornada pendientes
  vs v3 + GPS y los resuelve solos — CIERTO (v3 confirma o GPS detenido → "tenías
  razón"), NO_CIERTO (GPS lo muestra andando → "el GPS te registra a X km/h, no
  figura parada"), o los deja MANUAL si hay hueco de señal / sin hora concreta
  (FERNANDEZ). El veredicto dispara la devolución por WhatsApp. Kill-switch:
  `META/config_cierre_reportes.activo=false`. **Seguimiento**: 1ra corrida real
  = 2026-06-12 08:00 (procesa CAROLA/ALTAMIRANDA/FERNANDEZ con el v3 del 11/6) →
  revisar el log + lo que mandó. GODOY/GONZALEZ (auto de paradas) siguen siendo
  manual (fuera del alcance del cron).
- [ ] **Vigilador v3**: monitorear los primeros resúmenes diarios a Molina
  (v3 es la fuente oficial desde 2026-06-07) + release de las pantallas
  nuevas de jornada (gráfico velocidad + selector rango, 2026-06-10).
- [ ] **Alertas nuevas (2026-06-10, esta sesión)**: validar el primer episodio
  real de (a) alerta Telegram de bot caído/QR (`botHealthWatchdog`) y
  (b) aviso de salud del vigía cachatore (Cloudflare / claves.json).
- [ ] **F.931 PDF liviano** (opcional, no es código — lo re-sube el admin).

### Roadmap por ROI (sin fecha comprometida)
- [ ] **P1 Sitrack — auto-poblar viajes desde geocercas** (ROI máximo del
  módulo Logística; ver plan completo en entrada 2026-05-24).
- [ ] **V1 Volvo — tablero Seguridad por chofer** (la data ya está en
  `VOLVO_SCORES_DIARIOS`, falta solo UI).
- [ ] **V2 Volvo — ralentí % por chofer/unidad** (combustible: ~$1,5M ARS/mes
  por punto de ralentí).
- [ ] **P3 Sitrack — DTCs históricos** para el parte de Emmanuel.
- [ ] **Monitor de frescura Volvo** + fallback de mantenimiento por Sitrack +
  decisión sobre las 16 suscripciones Volvo vencidas (hoy: quedan en Sitrack).
- [ ] **ICM premios/castigos**: cuando Santiago defina el esquema (los cierres
  inmutables semanal/mensual ya están). + mapa de calor (placeholder) +
  decisión de retirar el CESVI propio (`recomputeIcmSemanalScheduled`) si
  nadie lo consume.
- [ ] **Volvo Driver/Tachograph/Messaging APIs**: feeds vacíos — requiere
  gestión con Volvo Argentina (alta de 48 chofers + transmisión por unidad).

---

## 📅 2026-06-11 (cont. 2) — KM en tarifas + KM/fecha de descarga en el Excel de liquidación

Sesión de UX/reportes (todo en main + pusheado). La app Flutter **espera release**.
Santiago **probó el export real en Windows y lo aprobó**.

### KM del recorrido por tarifa (`d46bc48`)
Cada tarifa lleva ahora `km` (entero, opcional) = distancia del tramo origen→destino. Es
**identidad de la RUTA, NO se versiona** con el precio (un cambio de tarifa no cambia la
distancia → va plano, fuera de las vigencias). Input en el form de alta/edición (sección
Modalidad, formato AR de miles); en la card de la lista de tarifas el km manual es
**autoritativo** y reemplaza la distancia estimada por coords (geodésica/OSRM); sin km
cargado cae al estimado. `fromMap`/`toMap` + guard en `crearTarifa`. +4 tests round-trip.
⚠️ SUPERA la nota "Versiona SOLO importes": km es identidad NUEVA persistida, pero fuera
de las vigencias.

### KM del tramo + fecha de descarga en el Excel (`932ae93`; reorden `f4450da`)
El export de Liquidación incorpora **km de cada tramo** y **fecha de descarga** en las dos vistas:
- **Cuaderno por chofer** (una fila por tramo, + espejo CONSULTA): columnas **F. DESC** y **KM**
  intercaladas entre PROV. destino (J) y los kg. Eso **corrió las columnas con fórmula** →
  ahora **KG=M, DIF.KG=N, TARIFA=O, GANANCIA=P, GASTOS=Q** (antes N/O). **D3 pasó a F. CARGA**.
  Se reescribieron TODAS las fórmulas vivas (el FLOOR de ganancia refiere `kg=M` y `tarifa=O`;
  el pie `SUM ganancia P`/`SUM gastos Q`; el RESUMEN cross-sheet P/Q).
- **Anexo VIAJES** (una fila por viaje): **FECHA DESCARGA** (del último tramo) + **KM** (suma de
  los tramos; un tramo sin km se omite, no cuenta 0).
- **Resolución del km**: `ResolverProvincias` (que ya carga el catálogo de tarifas para las
  provincias) mapea ahora `tarifaId → km` (`kmDe`). Resuelve **retroactivamente** — viajes viejos
  toman el km apenas se carga en su tarifa (mientras la tarifa exista). `llenarHojaViajes`
  quedó `@visibleForTesting`.
- **Verificado en Excel (COM)**: abre/cierra sin reparación; **NETO idéntico** al layout previo
  (la plata no cambió al reordenar). Tests anclados a celdas actualizados; suite report_planilla verde.

---

## 📅 2026-06-11 (cont.) — Tarifas real/chofer + Sentry + hardening del bot + auditoría del agente + devolución de reclamos

Sesión larga (todo en main + pusheado). La app Flutter **espera release**; el bot y
las Cloud Functions **YA en prod** (auto-update de la dedicada + `firebase deploy`).

### Tarifas — vigencia real y de chofer INDEPENDIENTES (`bbcc69c`, `7103377`)
Editar una tarifa separa la **tarifa real** y la **de chofer** en dos timelines de
vigencia propios: cada una se edita y fecha por separado; si la vigencia es anterior
a hoy, **recalcula los viajes NO liquidados** que la tocan (real y chofer, simétrico).
**Quitado el bloqueo** chofer ≤ real (muchas tarifas bajas se complementan con otras
altas) → ahora es warning suave, no rechazo. UI: dos sub-bloques real/chofer + dos
sheets de registrar precio; sacado el botón duplicado "Nueva tarifa"; el chip
"Activas" es un **toggle Activas↔Inactivas**. ⚠️ SUPERA la nota "ratio chofer ≤ real".

### Sentry (`2e8a200`)
`beforeSend` filtra el assert de `raw_keyboard` (Alt+Tab en Windows, FLUTTER-V) —
ruido, no bug. El SIGABRT del robot de Google se silenció en el dashboard.

### Bot WhatsApp — auditoría profunda + hardening (`c187e3e`, `a306cd3`, `6193678`, `c962452`, `e80fb10`)
4 ejes, verificado a mano contra el código (el bot ya estaba MUY endurecido):
- **PLATA (adelantos)**: confirmación stateful real (hash {dni,monto,fecha,medio},
  no solo prompt) + dedup de writes por turno + tope $5M (`AGENTE_TOPE_ADELANTO`,
  CONFIRMADO dejarlo) + redondeo. Las 3 tools de escritura sumadas a
  `TOOLS_DE_ACCION` (el retry sin_texto las duplicaba).
- **IDENTIDAD cross-user**: `_aprenderLid` solo en match estricto + unicidad; match
  laxo AR ambiguo → null; descarte "Bot-On" acotado a firma + ventana.
- **RESILIENCIA**: heartbeat HONESTO (probe `client.getState()` en cada latido → no
  miente "LISTO" con browser zombi); `health.iniciar` antes de `wa.inicializar` (sin
  ventana de doble-bot); reintento transitorio del claim anti-doble-bot.
- **P3 + tests**: exclusiones con warn al truncar, `/forzar-cron` fuera de horario,
  backoff de crons en ERROR, audio sin data. Suite bot 262 → 299.

### Agente — auditoría de TODOS los chats (`AGENTE_CONVERSACIONES`, 30 días)
- 🎯 **Causa raíz del `sin_texto`** (`ec7b742`): el **thinking de gemini-2.5-flash**
  (ON por defecto) devuelve candidato VACÍO al decidir una tool — medido 40/40 vacío
  → 0/40 con `thinkingBudget:0`. Apagado en el loop + la transcripción (tapó la fuga
  "SILENT THOUGHTS"). Era el patrón de fallo VIGENTE (jornada/turnos). Los 429/503
  del audit eran TODOS pre-8/6 (Groq + Gemini sin pago) → ya cerrados. Memoria
  `feedback_gemini_thinking_off.md`.
- **CUIL en `info_chofer`** (lo pedía Errazu) + **paradas "ahora"** sin pedir HH:MM
  cuando el chofer avisa que para en el momento (`e694789`).
- **Fix del script del buzón** (`181b9ad`): cruza los auto-generados por la fecha de
  la PARADA, no la de creación (miraba el día equivocado).
- **Devolución al chofer** (`ef16e68`, CF `onReporteDiscrepanciaRevisado` DEPLOYADA):
  al resolver su reclamo recibe un WhatsApp citando el mismo + el resultado. Disparo
  automático, solo reclamos directos, idempotente. El agente guarda el `detalle` en
  1ra persona. Detalle en `project_alertas_y_resumenes_whatsapp.md`.

---

## 📅 2026-06-11 — Adelantos: cards-filtro + sin buscador + hint de últimos 3

Sesión corta de UX sobre el menú **Adelantos** (`logistica_adelantos_screen`),
validada en vivo en Windows. Todo en main + pusheado.

- **Cards-filtro** (`8854fd0`): los KPIs del header (PENDIENTES · PAGADOS · ELIMINADOS ·
  TODOS) ahora SON el filtro, reemplazan los 4 pills de vista. Conteos GLOBALES sobre la
  base facetada (rango/empleado), cada card con su $ abajo. Se quitó el hero "$ X
  pendiente" (repetía la card PENDIENTES). El stream trae SIEMPRE los eliminados para que
  esa card cuente en vivo. 5° menú con el patrón (ver `feedback_cards_filtro_admin`).
- **Sin buscador de texto** (`ad9e9cd`): se sacó el AppInput "Buscar por chofer,
  observación…" — el filtro de Empleado ya cubre buscar por persona.
- **"Empleado: todos" → "Buscador" con lupa** (`4ee6190`): renombrado + `Icons.search` en
  vez del ícono de personas (sigue abriendo el selector de empleado).
- **Hint de últimos adelantos en el alta** (`0402fb2` → `18e742d`): al crear un adelanto,
  tras elegir el empleado se muestran sus **3 últimos adelantos NO eliminados** (fecha +
  importe, del más viejo arriba) arriba del campo Monto, para ver cuánto lleva y decidir.
  `AdelantosService.getUltimosDelChofer(dni, cantidad)` = one-shot por igualdad simple
  (SIN orderBy → sin índice compuesto), filtra eliminados, ordena y recorta client-side.

---

## 📅 2026-06-11 — Export de reportes Excel funcionando en web (/sistema/)

Cerrado el pendiente que dejó el hotfix web del 2026-06-10: exportar un reporte Excel
desde `cooper-trans.com.ar/sistema/` tiraba `UnsupportedError` — mismo patrón
`Platform.isWindows` (dart:io) sin `kIsWeb` del hotfix, pero **on-demand** (en el click
de exportar) en vez de en el arranque. Hasta ahora los 5 reports cortaban en web con un
stopgap ("los reportes Excel solo están disponibles en Windows y Android"); ahora
descargan de verdad.

**Fix** (todo en main):
- `ReportSaveHelper.guardarYAbrir`: rama `if (kIsWeb)` PRIMERO → descarga del navegador
  con los bytes del .xlsx, ANTES de cualquier `File`/`Process.run`/`getTemporaryDirectory`
  (todos dart:io, todos tiran en web).
- Descarga web real (Blob + `<a download>` + `revokeObjectURL`) en
  `reports/services/web_download_web.dart` con `package:web` + `dart:js_interop`. Import
  condicional `web_download.dart` (`export ..._web.dart if (dart.library.io) ..._stub.dart`)
  — mismo truco que `core/window/desktop_window.dart`, así `package:web` NUNCA entra al
  build móvil/desktop (ahí el guardado sigue por File/Process/SharePlus). `web` promovida
  de transitive a directa en pubspec (1.1.x) para no disparar `depend_on_referenced_packages`.
- Sacado el stopgap `if (kIsWeb) { warning; return; }` de los 5 reports que usan el helper:
  flota, icm, consumo, checklist (reports/) + liquidación (logistica/). `report_adelantos`
  NO usa el helper (imprime PDF vía PdfPrinter) → fuera de scope.

**Verificado**: `flutter analyze` 0 issues · `flutter build web --release --base-href
/sistema/ --pwa-strategy=none` (PowerShell, NO git-bash) OK con `<base href="/sistema/">`
correcto · boot en preview headless limpio (Firebase conecta, prefs migran, 0 errores/
warnings de consola; el canvas no pinta en el headless = quirk canvaskit conocido, no bug).
El **click real de descarga** necesita login admin + data → lo prueba Santiago en
`/sistema/` tras el próximo deploy FTP (deploy web = acción de release, la larga él).

---

## 📅 2026-06-10 — Sesión UI: cards-filtro en 4 menús + Mapa recorrido/acordeón + agente apodos + 2 bugs Windows

Sesión larga de UX (todo en main + pusheado). La app Flutter **espera el release**
que larga Santiago; el bot (agente) ya está VIVO por auto-update.

### Cards-filtro en las listas admin (mismo gesto en los 4 menús)
Los KPIs del header dejaron de ser decorativos: **las cards SON el filtro**.
Tocás una → filtra la lista, la activa se resalta; se quitaron los chips viejos
y el número grande del hero (repetía la card TOTAL/equivalente). Convención
nueva en memoria `feedback_cards_filtro_admin.md`. Replicado en:
- **Viajes** (`logistica_viajes_lista_screen`): PLANEADOS·EN CURSO·CONCLUIDOS·
  TOTAL·GANANCIA CHOFERES + vista mensual (selector ◀MES▶). Sacado el botón
  "Nuevo viaje" (queda el FAB). Detalle en `project_modulo_logistica.md`.
- **Personal** (`admin_personal_lista_*`): TODOS·CHOFERES·PLANTA·ADMINISTRACIÓN·
  INACTIVOS. PLANTA agrupa planta/gomería/taller/seg-higiene; INACTIVOS junta
  inactivos+tanqueros+testers (sin sumar al total). Fix "Ficha del chofer"→
  "Ficha del empleado".
- **Flota** (`admin_vehiculos_lista_*`): TRACTORES·BATEAS·TOLVAS·BIVUELCOS·
  TANQUES·LIBRES·INACTIVOS (default TRACTORES). LIBRES = cualquier tipo sin
  asignar (badge de tipo en la card); INACTIVOS junta tanques+inactivos+
  excluidos. Extintores SOLO en tractores (los enganches no llevan → ya no
  dicen "sin datos").
- **Mantenimiento** (`admin_mantenimiento_*`): TODOS·VENCIDOS·URGENTES·
  A PROGRAMAR·AL DÍA·SIN DATOS (default TODOS; A PROGRAMAR = programar+falta-
  poco). Conteos globales; número con color de urgencia.

### Mapa de flota — acordeón + recorrido histórico (detalle en `project_modulo_mapa_flota.md`)
Satélite por defecto; detalle de unidad como **acordeón en la card** (se eliminó
el panel derecho); hero "ACTIVAS n de total" (sin las 3 cajitas ni chips);
**recorrido histórico** 24h/48h/rango dibujado como polyline (fuente
`SITRACK_EVENTOS`, índice compuesto `(asset_id, report_date)` deployado). Fix del
scroll que saltaba al seleccionar (stream `SITRACK_POSICIONES` cacheado en
`initState`, ya no inline en build).

### Agente WhatsApp (vivo por auto-update; detalle en `project_agente_whatsapp.md`)
Retry ante el bug errático `sin_texto` de Gemini (1 reintento si no hubo tool de
acción); tool real `guardar_apodo` (escribe `EMPLEADOS/{dni}.APODO`, el mismo
campo de la ficha) + saludo por apodo en TODOS los roles. Suite bot 265/265.

### Admin shell
Sacado el botón redundante "Volver al menú principal" (exit_to_app) del AppBar —
la flecha de atrás de la izquierda ya cumple esa función.

### 2 bugs cazados en recorrida `flutter run -d windows --debug` (commit `7031dc9`)
Cosméticos/debug-only (no rompían nada), arreglados + **verificados en vivo**
(2do run 100% limpio mientras Santiago recorría):
- **Assertion de ListTile en los sheets de detalle**: el contenido iba pegado al
  Container con color de fondo sin un Material en el medio → "ListTile background
  color or ink splashes may be invisible". `app_detail_sheet.dart` ahora envuelve
  el contenido del caller en `Material(transparency)` → arregla TODAS las fichas.
- **Overflow 1px del buscador del Mapa**: TextField clavado en `SizedBox(height:
  38)` cuando el InputDecorator mide ~39px → "RenderFlex overflowed by 1.00
  pixels", re-disparado en cada tick del stream de posiciones. Subido a 40.
La recorrida completa salió **limpia**: sin crashes, sin errores de datos, sin
índices faltantes (el recorrido del mapa funcionó). El resto de los warnings del
log eran ruido conocido (firestore non-platform-thread en Windows + un Volvo 404
de un VIN sin alta).

### 🔴 Hotfix web /sistema/ — `Platform.isWindows` sin `kIsWeb` (commit `8d58b85`)
Más tarde Santiago reportó `cooper-trans.com.ar/sistema/` en "Cargando" eterno (web
1.2.25). Dos accesos a `Platform.isWindows` (dart:io) sin guard de `kIsWeb` →
`UnsupportedError` en el browser, antes de `runApp`: `WindowsUpdateService.iniciar()`
(fire-and-forget en main, sin try/catch — el throw escapaba y runApp nunca corría) +
`WindowsUpdateOverlay.build()` (siempre montado). Web roto en silencio desde el updater
Windows (~2026-06-06); se notó al deployar 1.2.25. Fix: `kIsWeb` primero. Rebuild web
(PowerShell, NO git-bash — mangle de `/sistema/`) + redeploy FTP → **verificado en vivo,
carga OK**. Diagnóstico: `curl` a los assets (todos 200, descartó 404/FTP incompleto) +
el `Uncaught Error` de la consola que mandó Santiago. Regla + detalle en memoria
`project_web_institucional.md`.
- [x] **RESUELTO (2026-06-11)**: `report_save_helper.dart` ahora dispara una descarga del
  navegador (Blob + `<a download>`) en web vía import condicional (`web_download.dart` →
  `_web`/`_stub`, discriminador `dart.library.io`). El branch `kIsWeb` corta ANTES de
  tocar File/Process/getTemporaryDirectory. Se sacó el stopgap "solo Windows/Android" de
  los 5 reports que lo usan (flota, icm, consumo, checklist, liquidación). Detalle abajo
  (sección 2026-06-11).

---

## 📅 2026-06-07 (cont.) — Link estable de descarga Windows + Paso 0 vigilador v3

### Link de descarga Windows ESTABLE (commits `89f5dc7`, `a230b5c`)
El botón Windows de la landing (`cooper-trans.com.ar/app`) ahora apunta a
`…/releases/latest/download/CoopertransMovil-Setup.exe` — GitHub redirige al `.exe` del ÚLTIMO
release → **descarga directa, sin JS** (antes el JS caía al fallback que abría la página de GitHub).
`release_app.ps1` sube ahora, además del `.exe` versionado, una **copia con nombre fijo
`CoopertransMovil-Setup.exe`** en cada release (la subí manual al 1.2.2 actual para que ande ya).
Verificado: 200 · 22.9 MB.

### 🐛 BUG CRÍTICO ARREGLADO: el update in-app no relanzaba (`427fade`)
El banner descargaba el `.zip` OK pero el helper PowerShell que reemplaza/relanza
**nunca corría** → la app quedaba en la versión vieja y al reabrir salía el banner
otra vez. Causa: `Process.start('powershell', detached)` + `exit(0)` mataba el
helper antes de que terminara de arrancar (no sobrevivía al cierre de la app). El
helper en sí estaba bien (probado a mano: extrae/reemplaza/relanza OK). **Fix:**
lanzarlo desde un `.bat` que usa `start` → el PowerShell queda FUERA del árbol de
procesos de la app (desacople real, sobrevive al exit). Validado end-to-end con el
helper+zip reales (arranca, extrae, reemplaza el exe de 15 MB, reescribe VERSION.txt).
- ⚠️ **Entra en la 1.2.3.** Las PCs con una versión instalada ANTERIOR (1.0.94–1.2.2)
  corren el código viejo → su update in-app a la 1.2.3 va a fallar igual (una última vez).
  Para llegar a la 1.2.3 hay que **re-instalar el setup 1 vez** (del link estable
  `cooper-trans.com.ar/app`). De la 1.2.3 en adelante el update in-app anda solo.

### Cosmético: banner de update sin `+build` (`a230b5c`)
`WinUpdateInfo.versionCorta` → el banner muestra `1.2.2` en vez de `1.2.2+10202`. Cosmético (el
version completo se sigue usando para comparar). Se ve limpio **a partir de la 1.2.3** (lo dibuja la
app instalada).
- [ ] **PENDIENTE (lo ve Santiago): dice que el `+10202` aparece en "varios lugares" de la app, no
  solo el banner.** Revisado el código actual (login/panel = `v 1.2.2`, barra de título =
  `Coopertrans Móvil`, banner ya arreglado) → todo limpio. Falta que precise EN QUÉ pantallas lo ve
  (captura). Hipótesis: está mirando la 1.2.2 instalada (pre-fix del banner). A confirmar.

### Vigilador v3 — Paso 0 HECHO, Camino B
Ver detalle en la entrada de abajo + `docs/PLAN_vigilador_jornada_v3.md`. Próximo: **Paso 1** (batch
de reconstrucción, lógica pura + tests) — texto de arranque listo, ejecutar en sesión fresca.

---

## 📅 2026-06-07 — Fix vigilador (pausas en gaps), landing de descargas, serie 1.2.x

Sesión de revisión del agente + reportes de choferes → derivó en 4 cosas:

### 1) Fix vigilador de jornada: pausas encubiertas en gaps de reporte (DEPLOYADO)
5 reportes de choferes el 6/6 (buzón de discrepancias): "paré 20-50 min y el sistema
me sigue contando en ruta" → avisos de "4h" injustos. **Diagnóstico con datos:** NO era
feed caído ni que mintieran — eran **gaps de reporte por cobertura GSM** en zonas rurales
(Baigorrita, Chinchinales). `analizarEventosDetencion` unía dos eventos de movimiento
separados por un gap como **manejo continuo** (el gap de 51 min de FERNANDEZ = su parada
real de ~50 min). **Volvo NO sirve de respaldo**: es snapshot sin histórico y su posición
está mucho peor (mediana 21,5 h stale, 85% de la flota >30 min; peor que Sitrack).
**Fix (commit `d7b751f`, función `vigiladorJornadaChofer` DEPLOYADA):** si entre 2 eventos
de movimiento hay un gap ≥15 min y la posición casi no cambió (≤500 m) → **pausa encubierta**
(corta el bloque). Si se movió (>500 m) o falta lat/lng → cuenta manejo (conservador, no
silencia un aviso de descanso legítimo). `EventoDetencionLite` +lat/lng (de SITRACK_EVENTOS);
`RADIO_PAUSA_GAP_METROS=500`; gap mínimo = `PAUSA_BLOQUE_SEGUNDOS` (15 min); +4 tests (188/188).
- [ ] Marcar revisados los 5 reportes pendientes (pantalla "Reportes de choferes") — ahora con el
  botón "Ver jornada real" que abre el registro v3 del chofer.
- ✅ **SUPERADO por el VIGILADOR v3 — COMPLETO y VIVO (07-jun).** El parche de arriba quedó subsumido
  por el rediseño v3 (`docs/PLAN_vigilador_jornada_v3.md`, memoria `project_vigilador_jornada_v3.md`):
  Pasos 1-4 hechos. **Vivo en prod:** lógica pura `jornadas_v3.ts` + crons `jornadas_v3_batch.ts`
  (registro 06:45 → `REGISTRO_JORNADAS`, fuente oficial; backfill 1030 registros; resumen a Molina
  08:00 ahora sale de v3) + **aviso en vivo humilde** en el v2 (gate de frescura 7 min, deployado).
  El v2 quedó como aviso preventivo + fallback. Manejo NO está inflado (verificado 3 formas). Flag
  `META/config_vigilador_v3.registro_batch_activo` ON (off = `flag_jornada_v3.js off`). 246/246 tests.
  - [ ] **RELEASE de la app** (Santiago): sube las 3 pantallas v3 (mi jornada chofer + vista admin +
    botón en disputas) de `lib/features/registro_jornadas/`. Backend/rules/índices ya vivos.
  - [ ] Mañana 08:00: confirmar visual el **primer resumen v3** que recibe Molina.
  - [ ] (Opcional) Monitorear el buzón: los reportes de "parada no detectada" deberían cesar.

### 2) Landing de descargas — cooper-trans.com.ar/app (LIVE)
Página única con los 5 puntos (iPhone/iPad + Android + Mac + Windows + web), branding VAVG.
Archivo `web_coopertrans/sitio_nuevo/app/index.html`, subida por FTP (`python _subir_sitio.py app`).
App Store id `6769592572` (ficha universal iOS/Mac); Play `com.coopertrans.movil`; Windows = botón
que consulta la GitHub Releases API y baja el `.exe` directo (sin abrir GitHub); web = `/sistema/`.
- [ ] (Opcional) Linkearla desde la home del sitio + badges oficiales de las stores.
- [ ] (Opcional) Commitear el archivo en el repo del sitio (`sitio_nuevo` tiene su propio git).

### 3) Versionado: serie 1.2.x + build derivado (commits `ad91664`, `b357bb5`)
`bump_version.ps1` apunta a una **serie objetivo** (`$serieMajor=1`, `$serieMinor=2`) y sube solo
el patch (1.2.1, 1.2.2…). El **build se DERIVA del semver** (`M*10000+m*100+patch` → 1.2.2 = `+10202`),
ya NO es un contador aparte: solo se maneja `1.2.X` y el build (que Play/App Store exigen único y
creciente) se arma solo. Para saltar a 1.3.x: cambiar `$serieMinor`. Ya se largaron 1.2.0 y 1.2.1;
el próximo release da **1.2.2+10202**.

### 4) Agente WhatsApp: sano
99 chats/7d, **0 fallbacks**. Los 17 errores eran históricos (1-4 jun) por saldo/cuota de
Gemini + Groq (Groq ya eliminado del código). Desde el 5/6 responde limpio. Sin acción.
Scripts de diagnóstico read-only en `whatsapp-bot/scripts/` (`revisar_agente_reportes`,
`investigar_jornada_paradas`, `comparar_volvo_sitrack`) — sin commitear, por si reusás.

---

## 📅 2026-06-06 — Windows: crash 1.0.93 fixeado + update IN-APP → 1.0.94 LIVE y validada

**Dos cosas en una versión (1.0.94+97 — ya largada y validada end-to-end):**

### 1) Fix del crash 1.0.93 ("se abre y se cierra")
`refrescarIconoEscritorioWindows()` reescribía el `.lnk` del pin de la taskbar vía **COM/FFI (win32)** para
refrescar su ícono. En build **RELEASE** eso tiraba **ACCESS VIOLATION (0xC0000005)** al arrancar — crash
NATIVO in-process que el `try/catch` de Dart NO atrapa, *antes* del marker en prefs → rompía cada arranque
(en dev no se veía). Fix `bf19072`: **eliminado todo el COM/FFI**, queda solo `ie4uinit -show`.
**⚠️ LECCIÓN: NUNCA FFI/COM in-process al arranque; probar SIEMPRE en build RELEASE real.** (Detalle técnico
en memoria `project_windows_distribucion.md`.)

### 2) Update IN-APP (reemplaza la ventana del launcher)
Modelo de sport_manager: el ícono abre `coopertrans_movil.exe` DIRECTO (sin launcher, **sin ventana negra**)
y la app actualiza sola. `lib/core/services/windows_update_service.dart` (consulta GitHub Releases API, baja
el `.zip` con `dio`, helper PowerShell OCULTO con backup+rollback, relanza) + `windows_update_banner.dart`
(banner descartable) + `installer/coopertrans_movil.iss` (shortcut → `.exe`; `launcher.ps1` LEGACY/fallback).
Commit `8d82f6a`. NO usa FFI/COM in-process (lección de arriba): todo lo nativo va por PowerShell externo.

**Validado E2E (06-jun):** detección contra GitHub API real ✓ · helper aislado (reemplazo limpio + rollback) ✓ ·
el launcher baja la 1.0.94 de GitHub ✓ · la 1.0.94 instalada **arranca sin crash** (PID vivo) ✓ · `flutter analyze` limpio.

**PENDIENTE de Santiago:**
- [ ] **Subir el AAB de 1.0.94 a Play** (Production) — `build/app/outputs/bundle/release/app-release.aab`. NO el de 1.0.93.
- [ ] **Re-instalar `dist\CoopertransMovil-Setup-1.0.94-build97.exe` 1 vez en cada PC Windows** (incluida la de dev)
  para migrar el ícono al modelo sin ventana. Las PCs que solo abran el ícono viejo igual se actualizan a 1.0.94
  (chau crash) pero siguen con la ventana del launcher hasta re-instalar.
- [ ] El **banner in-app** se confirma visualmente en el salto a la **1.0.95** (la 1.0.94 ya es la última → no muestra banner).

**Nota menor:** el paso [8/9] del `release_completo` (force-update local) quedó a medias (dejó la PC en 1.0.93
sin `VERSION.txt`); se completó corriendo el launcher a mano. No afecta a las PCs reales (abren el ícono con la
app cerrada → el launcher actualiza bien). Revisar ese pasito del script algún día.

---

## 📅 2026-06-06 — Agente WhatsApp: 4 mejoras de la revisión de chats (HECHO, por auto-update)

Revisión de TODO el histórico del agente (82 chats, 1→5 jun): **0 fallbacks**. De
los 10 casos donde declinó salieron 4 mejoras (commit `a5cd686`, en prod por
auto-update del bot — `whatsapp-bot/src/agente.js`):
1. **`jornada_de` con `dia`** — consulta jornadas PASADAS ya cerradas ("la de
   ayer / el 03-06"), no solo la de hoy. Día ART por `Intl` (no el ISO-UTC de
   `_fechaIso`).
2. **`contacto_oficina`** (tool común chofer + gestión) — da nombre + teléfono
   del responsable por ÁREA: mantenimiento=Corchete (29820141), logística=Errazu
   (25022800), documentación=Giagante (26456455), sistema/app=Santiago
   (35244439), seguridad=Molina (34730329). Mapa `CONTACTOS_POR_AREA`; el
   teléfono se resuelve en vivo de EMPLEADOS. Reemplaza el "comunicate con la
   oficina" genérico.
3. **`adelantos_emitidos`** (verLogistica) — cuántos adelantos se registraron en
   una ventana (default hoy) + total, por `creado_en`. Distinto de
   `adelantos_pendientes`.
4. **Match de nombres FUZZY** (Levenshtein, fallback del exacto) → "Akerman" cae
   en "ACKERMANN"; + el chofer puede consultar su jornada/unidad mencionando SU
   patente (antes lo rechazaba).

+9 tests (agente 77/77).

**Buzón de discrepancias del chofer (Santiago 06-jun)** — los choferes a veces
mienten sobre jornada/datos: NO se les cree (el dato lo define la telemetría/GPS),
pero SÍ se guarda lo que dicen como feedback para revisar caso por caso (puede ser
bug real del sistema o el chofer mintiendo).
- ✅ **Fase 1 (bot, commit `5c50eb7`, por auto-update)**: tool `reportar_discrepancia`
  → registra en `REPORTES_DISCREPANCIA` {chofer_dni, chofer_nombre, tema, detalle,
  estado:pendiente, creado_en} SIN tocar ningún dato. Alcance: cualquier dato
  (jornada/unidad/adelantos/vencimientos). El agente no le da la razón, solo anota.
- ✅ **Fase 2 (commit `04bfb86`, rules DEPLOYADAS)**: pantalla "Reportes de
  choferes" en el hub Administración (admin/sup, tile con `builder` directo) —
  lista pendientes/todos + KPIs, marcar CIERTO / NO COINCIDE + nota, reabrir.
  Modelo `ReporteDiscrepancia` + `ReportesDiscrepanciaService` + 6 tests. Rules
  `REPORTES_DISCREPANCIA` read/update admin-sup, create/delete false (solo el bot
  escribe). ⏳ Verificar visual al salir el release (la pantalla viaja con la app;
  las rules ya están vivas).

Verificar en próximos chats que las 4 mejoras + el buzón se usen bien.

---

## 📅 2026-06-06 — macOS rechazado por Apple — entitlement inválido (FIX HECHO)

Apple rechazó **macOS 1.0 (58)** (Submission `47e2ee0a-fbd1-4ef1-9557-f6c95848cb54`)
por **Guideline 2.4.5(i) — Performance**:
> The app incorrectly implements sandboxing, or it contains one or more entitlements
> with invalid values. — `com.apple.security.automation.apple-events`

**Causa**: `macos/Runner/Release.entitlements` declaraba el entitlement con valor
`false`. Apple lo trata como inválido — la regla del sandbox es:
- si NO necesitás el permiso, **no declarés el entitlement** (false ya es el default);
- si lo necesitás, lo declarás con `true`.

El comentario que decía "flutter_local_notifications usa NSAppleEventManager" era
erróneo: notificaciones locales van por `UNUserNotificationCenter`, no por Apple
Events. Confirmado: 0 referencias a `apple-events` / `NSAppleEventManager` /
`NSAppleScript` / `AppleEvent` en `macos/`. `DebugProfile.entitlements` ya no lo
tenía.

**Fix** (commit acompañando este doc): eliminada la entrada del Release.entitlements.
`plutil -lint` OK. No cambia comportamiento — solo limpia un entitlement nulo del
binario firmado.

**⏳ Pendiente Santiago**: re-submit a App Store Connect macOS con un build nuevo
(Xcode Cloud lo arma con el próximo push de tag de versión). Probablemente entra
directo con la 1.0.92+95 o el bump siguiente — sin tocar nada más.

---

## 📅 2026-06-05 PM — Gomería: stock solo admin + conteo de inventario a ciegas

Pedido Santiago. Dos partes (commits `bc200aa` + `9489a9e`, rules deployadas):
- **(a) Stock oculto al rol GOMERIA**: capability nueva `verGomeriaStock`
  (ADMIN+SUPERVISOR). El gomero monta/retira cubiertas pero NO ve cantidades —
  FAB Stock oculto, pantalla de depósito con guard, y en el sheet de montaje
  ve qué modelo poner SIN el número "en depósito".
- **(b) Conteo a ciegas** (`GOMERIA_CONTEOS`): el gomero reporta cuántas ve por
  modelo × nueva/recapada (sin ver el teórico); admin/supervisor compara contra
  el sistema en "Revisar conteos" y ve faltan/sobran. NO auto-ajusta (el admin
  decide). `compararConteoVsStock` pura + 9 tests. 2 pantallas nuevas + 2 tiles
  en el hub.

**⏳ FALTA verificación visual** (se codeó con analyze limpio + 36 tests, no se
corrió la UI). La colección arranca vacía (se llena con el 1er conteo real).
Sale en 1.0.92. Detalle: memoria `project_modulo_gomeria.md`.

---

## 📅 2026-06-05 PM — Módulo Vacaciones (Administración) — construido completo

"Panel de administración" → **"Panel de control"**. Nuevo módulo **Administración**
(hub RRHH) con submenú **Vacaciones**. De cero en 1 sesión (commits `33fd8fe` →
`05f5c83`):
- Colección `VACACIONES` (doc/empleado/año, **sin duplicar EMPLEADOS** — pedido
  Santiago; nombre/empresa/área se joinean por DNI, tomados/restan derivados).
- Cálculo días por antigüedad LCT (`vacaciones_calculo.dart`, validado **69/72**
  vs el Excel) + 24 tests verdes.
- **Import del Excel 2025 = 72 docs EN PROD** (`scripts/vacaciones_import.js`, vía
  Admin SDK; match CUIL 71/72 + 1 nombre, 0 huérfanos). **Rules deployadas.**
- 3 pantallas: tabla anual (filtros + saldos) + editor (días auto + períodos +
  guardar/borrar) + calendario Gantt mensual. Solo oficina (admin/supervisor).

**⏳ FALTA verificar visualmente** — se codeó con `flutter analyze` limpio pero NO
se corrió la UI. Validar al abrir **1.0.92** (o `flutter run`). Los 3 proporcionales
de 1er año (Balbiano/Celiz/Álvarez) a confirmar a mano. Detalle en memoria
`project_modulo_vacaciones.md`.

---

## 📅 2026-06-05 PM — Ícono Windows no se actualizaba en el escritorio (caché)

**Síntoma**: tras aplicar el ícono v2, el escritorio de Windows seguía mostrando
el ícono viejo aunque el `.exe` ya tenía el nuevo embebido.

**Causa (NO era el build)**: el `.exe` en `C:\ProgramData\CoopertransMovil\` ya
trae el ícono v2 (verificado extrayéndolo) y el shortcut apunta bien
(`...coopertrans_movil.exe,0`). Es el **caché de íconos de Windows**, que no se
invalida solo al sobrescribir el `.exe` con uno del mismo path. El launcher tenía
un bug: corría `ie4uinit -show` **solo si cambiaba el IconLocation** del shortcut
— y en un cambio de ícono el path NO cambia, solo el contenido del `.exe`. Peor:
el launcher vive en `Program Files` (read-only) y **no se auto-actualiza**, y el
shortcut está en `%PUBLIC%\Desktop` creado por el instalador como admin →
read-only para el user (no se puede tocar sin UAC).

**Fix (se propaga SOLO con el próximo release, sin tocar PC por PC)**: lo dispara
la **APP** (lo único que se actualiza garantizado en cada PC vía auto-update). Al
arrancar en Windows, `refrescarIconoEscritorioWindows()` (`lib/core/window/`,
conditional import con stub web igual que `desktop_window`) corre `ie4uinit -show`
**una vez por versión nueva** (marcador en SharedPreferences). No requiere admin,
no toca el shortcut, no es disruptivo. Validado a mano en esta PC: el escritorio
pasó al C neón sin reinicio ni UAC. Defensa en profundidad: el `launcher.ps1` ahora
refresca el caché SIEMPRE (no solo si cambia el shortcut) → beneficia
instalaciones nuevas vía el instalador. `flutter analyze` limpio.

**Pin de la barra de tareas** (`773fb30` + follow-up): el escritorio lo arregla
`ie4uinit -show`, pero el **pin de la taskbar** guarda su PROPIO ícono cacheado que
`ie4uinit` no toca → hay que re-escribir su `.lnk`. La app lo hace vía **COM/FFI**
(`win32`, IShellLink + IPersistFile; toggle del IconLocation), **sin lanzar
PowerShell** (evita falsos positivos de antivirus en una app no firmada). El `.lnk`
del pin es del usuario (`%APPDATA%\...\TaskBar`, writable; a diferencia del
escritorio público que es read-only sin admin). Validado: mecánica COM probada
sobre copia + `flutter build apk --debug` OK (el import de win32 NO rompe Android;
sólo corre dentro del guard `Platform.isWindows`). Pedido de Santiago: que el pin
también se arregle solo, sin tocar PC por PC.

**⏳ Sale en 1.0.92** (entra con el próximo release de app que largue Santiago).

---

## 📅 2026-06-05 — Fix jornada inflada (Volvo vencido) + adaptación a Sitrack

**Bug**: choferes veían manejo absurdo (Laina 23h25, Bastias 19h55). El vigilador
decidía el descanso por "el equipo dice parado"; los 16 Volvo con suscripción
VENCIDA quedan congelados y reportan velocidad falsa → la rama "manejando"
reseteaba el reloj de descanso cada tick → la jornada nunca cerraba y acumulaba
DÍAS.

**Fix DEPLOYADO** (`b484cf6`, CF `vigiladorJornadaChofer` southamerica-east1):
en `jornadas_v2.ts` / `evaluarTickJornada`, cierre por **POSICIÓN QUIETA** (lat/lng
sin moverse del radio 1 km en ≥8h, sin mirar la velocidad) + **cap defensivo**
(manejo neto ≥14h → cierre forzado). Aditivo, 184 tests verdes (3 nuevos).

**El vigilador YA mide con SITRACK**: el gate de frescura de 10 min descarta solo
el Volvo congelado (verificado: `posicion_ts` de las vencidas es de hace ~7 días).
La jornada NO depende de Volvo. Renovar las 16 suscripciones sigue dando la
telemetría de motor (combustible/AdBlue/eco) pero la jornada no la necesita.

**Reparación one-shot**: cerradas 8 jornadas colgadas que arrastraban de antes del
fix (incl. zombie de Erasmo, 407h, dado de baja). Quedan 2 borderline que se
auto-cierran esta noche.

**Herramientas nuevas en `scripts/`** (para medir el vigilador y el agente):
`monitor_jornadas.js` (jornadas abiertas + marca colgadas), `reparar_jornadas_colgadas.js`
(dry-run + `--aplicar`), `leer_chats_agente.js`, `leer_jornada.js`, `diag_fuente.js`.

### ✅ AGENTE — revisión de chats 2026-06-05 (HECHO, va por auto-update del bot)
- **Respuestas vacías** (`f297588`): `turnos_ypf_detalle` ahora trae siempre una
  `nota` (si no hay turnos, el modelo igual tiene qué decir) + el STOP sin texto
  marca `error:'sin_texto'` → fallback en vez de mudo + check de vacío robusto a
  whitespace en `responder`.
- **3 huecos de tools** (`e2b9ddc`): tool `adelantos_pendientes` (consulta, no
  registra) + tool `listar_empleados_por_rol` (ej. "quiénes son los admins") +
  guía en el prompt para crear VARIOS adelantos en un mensaje (crear_adelanto ×N
  con una sola confirmación). Validado contra datos reales.

---

## 📅 2026-06-04 PM — Fix Gomería + auditoría no-refresh

- **Bug arreglado** (`5f6111b`): el editor de un MODELO de cubierta (catálogo
  Marcas y Modelos) era `StatelessWidget` con el objeto cacheado → tras "Guardar"
  un campo mostraba el dato viejo hasta cerrar/reabrir el panel. Ahora re-lee el
  doc + `setState`. **⏳ Pendiente de salir en 1.0.92** — quedó DESPUÉS del build
  de 1.0.91, así que NO está en lo que se subió hoy (Android/iOS/macOS/Windows/web
  van con 1.0.91 sin este fix). Bug menor (admin-only).
- **Auditoría sistémica** del mismo patrón en toda la app (Personal, Flota,
  Empresas, Ubicaciones, mantenimiento, revisiones, asignaciones, ICM, cachatore,
  volvo, vencimientos, empresas empleadoras…): **el de Gomería era el ÚNICO bug**.
  El resto usa el patrón correcto (editor sobre `StreamBuilder` del doc, o
  `setState` tras guardar). Patrón estándar a respetar a futuro.

---

## 📅 2026-06-04 — Sesión grande: agente IA + cachatore + tarifas + mantenimiento + Volvo

~17 commits (todo en main + pusheado). **Bot y Cloud Functions YA en producción**
(auto-update PC dedicada + `firebase deploy`). La **app Flutter espera el release**
que larga Santiago.

### ✅ YA en producción (NO requieren release)
**Bot WhatsApp** (auto-update ≤5 min c/u):
- Groq eliminado → **Gemini de PAGO** único proveedor (key en `.env` de la dedicada).
- Agente: jornada reporta manejo **NETO**; nueva tool **`crear_adelanto`** (2 pasos
  con confirmación, escribe `ADELANTOS_CHOFER`); **buscador de nombres tolerante a
  tildes + orden invertido** (unificado con cachatore); log del fallback
  (`es_fallback`); no fuerza tools en charla social; **alerta WhatsApp al admin si
  Gemini se queda sin saldo** (throttle 6h, `AGENTE_SIN_SALDO_ALERT_DNI` →
  fallback `COLA_CRECIENTE_ALERT_DNI`).
- **Anti-auto-respuesta DEFINITIVO** — 3 capas: firma `Bot-On` + `BOT_PHONE` +
  **descarte por ID del saliente** (`wa.esMensajePropio`). El de ID cierra el
  "hablan entre ellos" del vigilador (el reflejo del saliente llega corrupto en
  sesión recién vinculada → solo el id es infalible).
- Cachatore: reprocesa re-pedidos de reagendar (reset `reagendar_hecho` por
  franja/fecha) + polling 30→8 s; logs en **DD-MM sin año** + reagendado muestra
  **fecha + hora** (sin franja).
**Cloud Functions** (deployado southamerica-east1): **vigilador de jornada cierra
por GAP de reportes** (fix "dormí 8 h → me decía 12 h" — equipo apagado de noche).
**Firestore**: limpiado el fantasma `alertasVolvoDiario` de `BOT_HEALTH/main`.

### ✅ SALIÓ EN 1.0.91+94 (app Flutter — Windows + AAB a Play + web + iOS/macOS)
- **Cachatore**: card "buscando reagendar" EN VIVO (KPI + badge por flag).
- **Tarifas**: "CHOFER FIJO $X" cuando el chofer cobra monto fijo.
- **Mantenimiento**: editar el service a mano desde el detalle.
- **Auditoría total de Logística** (`b999d2b`): liquidación sin adelantos de
  no-choferes ni filas fantasma; fecha del gasto refleja; resumen avisa monto
  fijo vacío; borrar/reactivar viaje atómicos; recálculo anti lost-update;
  `getPorViaje` determinístico; dup empresa/ubicación con query puntual; banner
  re-sincroniza; detalle sin parpadeo; atajos al tab correcto en Empresas.
- **Auditoría iOS/macOS** (`c6c1d98`): permisos (sin cámara macOS, sin add-photos
  iOS, dark mode real), CI pin flutterfire, `Podfile.lock` macOS, bundle ids.
- (+ versionado de tarifas por vigencia, filtro de Flota por tipo, tooltip de
  jornada, etc., acumulado de bumps previos.)

### 🔧 Pendientes / a verificar (Santiago)
- ✅ Resuelto 2026-06-05: ~~corregir 2 tarifas mal cargadas (Sea White→La
  Martineta sin tarifa de chofer; Río Colorado→Monte Hermoso/Devic chofer $2)~~.
- ✅ Monitoreado 2026-06-06: ~~vigilador de jornada~~ SANO (gate Volvo/Sitrack OK —
  descarta los Volvo congelados ~7d y usa Sitrack fresco; cierra por 8h-quieto / gap de
  reportes ≥8h / cap 14h; las jornadas que el monitor marca >16h son reales largas que
  cruzan la noche, NO bug — cierran solas) + ~~anti-auto-respuesta~~ SANO (2 capas en el
  handler, por id + por contenido; **0 auto-conversaciones** en los últimos 30 chats del
  agente, 0 fallbacks). Nota de diseño: la veda nocturna AVISA pero NO cierra (política
  Vecchi) — cambiar eso sería decisión aparte de Santiago.
- ✅ Resueltos 2026-06-04: ~~alerta presupuesto Gemini (Cloud Billing)~~ ·
  ~~franja reagendar AVIT~~ · ~~subir AAB a Play~~ · ~~iOS/macOS build + submit~~.

### 🟡 Para retomar (en pausa)
Monitor de frescura Volvo · fallbacks de mantenimiento a Sitrack · suscripciones
Volvo de las 16 unidades (ver entrada "Auditoría Volvo" abajo).

---

## 📅 2026-06-04 — Auditoría Volvo: 16 unidades con suscripción VENCIDA (decisión: dejar en Sitrack por ahora)

**Confirmado por Santiago**: 16 tractores Volvo tienen la suscripción de Volvo Connect **vencida** — cortaron transmisión casi simultáneamente **~29-may**. El poller los sigue "viendo" (consultado_en <1h) pero la API devuelve el último estado **congelado** de hace ~6 días. Auditoría completa esta sesión (datos en vivo en Firestore + mapeo de código con agentes).

**Patentes** (16 asignadas a choferes activos, congeladas ~6 d): AC114PY, AC114QQ, AC114QP, AB927WN, AB927WU, AC274LU, AC114QR, AB421DP, AC274IS, AC383ND, AC114PX, AC383OM, AB493CP, AC114PZ, AG848IK (2 d). Más **AH490YJ** (29 d — parada de verdad, muerta también en Sitrack) y 2 sin asignar (AB787RS, AF869ZU, probablemente paradas).

**Qué se perdió** (exclusivo de Volvo, irrecuperable sin renovar): combustible / AdBlue / autonomía · tell-tales del tablero (mantenimiento predictivo) · scores eco-driving (L/100km, CO₂) · alertas de seguridad activa (AEBS/ESP/LKS).

**Qué NO se perdió** — Sitrack cubre toda la flota (55) y **ya está reportando esas 16 en vivo**: posición/velocidad, odómetro, iButton (chofer), sobrevelocidad cartográfica, conducta (frenada/aceleración brusca vía ICM), zonas/descargas, jornada. **El ICM oficial que audita YPF sale de Sitrack, NO de Volvo → relación con YPF intacta.** El 70% operativo siempre vivió en Sitrack; Volvo era el "plus" de telemetría de motor.

**DECISIÓN (Santiago, 2026-06-04): dejar como está, operar esas 16 con Sitrack, NO renovar Volvo por ahora.** Revisitar si se necesita el control de combustible / mantenimiento predictivo de esas unidades.

**Para retomar (NO hacer ahora, quedó pausado):**
1. 🥇 **Monitor de frescura** — el verdadero problema fue perder 16 unidades 6 días sin enterarse. Cron que avise por WhatsApp cuando una unidad asignada deja de transmitir posición >X h. Esfuerzo chico, alto valor, **independiente de la decisión de suscripción**.
2. **Service por km/horas → fallback a Sitrack** (`odometer` / `hourmeter`) para unidades sin Volvo. Horas solo donde hay ICAN (~15/55); km en todas. Verificar que el mantenimiento caiga bien.
3. **Mejoras de código** (del mapeo): `volvoAlertasPoller` y `volvoScoresPoller` NO reintentan ante 401/403/500 (el cursor de alertas no avanza → riesgo de perder eventos en outage transitorio) — igualar a `telemetria.ts`. Colecciones muertas `ULTIMO_SERVICE_KM`/`ULTIMO_SERVICE_FECHA` (vacías; el dato vive en `VEHICULOS_TALLER`) → limpiar.
4. **Decisión de fondo**: renovar Volvo de las 16 (recupera combustible/eco/tell-tales/seguridad) vs seguir en Sitrack. Combustible vía Sitrack existe como módulo aparte (suscripción).

**El pipeline Volvo está SANO**: poller cada 5 min sobre 53/53, auth OAuth OK, alertas en tiempo real (última hace minutos), telemetría fresca, campos clave 53/53. El problema es 100% de suscripción, no del código.

---

## 📅 2026-05-29 — macOS enviado a review de Apple 🎉

Frente macOS destrabado end-to-end y **app enviada a review** del Mac App Store.
Detalle técnico en `ESTADO_PROYECTO.md` (entrada 2026-05-29) y `docs/RUNBOOK_macos_signing.md`.

**✅ Hecho hoy** (commits `c7c1c62`, `be9999c`, `7db6cee`, `1897091`):
- Pantalla negra de arranque resuelta (faltaba `macOS` en flutter_local_notifications +
  Firebase macOS sin configurar + inits de `main()` sin try/catch).
- Deployment target Podfile macOS → 11.0 (−86% warnings de build); Podfile versionado.
- Página de soporte `public/soporte.html` deployada (Support URL daba 404 → ahora 200).
- Listing macOS completo: capturas 2560×1600 (DNI propio borrado; la de Descargas
  DESCARTADA por exponer PII de otros choferes), promo, descripción, keywords.
- functions: 0 warnings (fix max-len en `comun.ts`). Entorno Mac alineado: Flutter 3.44.0 + SPM off + Node 26.

**⏳ Pendiente:**
1. **Esperar aprobación de Apple** (1-3 días) → publicar (modo **manual** elegido). Si rechazan, leer motivo y ajustar.
2. **Confirmar que el login demo `00000001` sigue activo** — es la causa #1 de rechazo de Apple (probar el login antes de que revisen).
3. **Android — análisis de warnings**: NO se pudo en la Mac (sin Android SDK). Pendiente desde la PC Windows: `flutter build appbundle` capturando el log de Gradle/Kotlin y clasificar (como se hizo con macOS).
4. **Limpieza menor**: borrar `~/Desktop/appstore_macos/_originales_sin_procesar/` (respaldo de capturas crudas) cuando se confirme que las finales entraron OK en el listing.

---

## 📅 2026-05-28 — Revisión de pendientes (varios cerrados) + setup PC nueva

Revisión del estado real contra el código. **Cerrados / obsoletos:**

- **Logística multi-tramo — features chicas**: TODO resuelto. Reordenar y
  duplicar tramos los descartó Santiago el 14-may (innecesarios en la práctica);
  validación de encadenamiento (banner amarillo), buscador en empresas y tarifas,
  pantalla de viajes borrados (toggle "Mostrar eliminados" + Reactivar) y export
  de liquidación a Excel (`report_liquidacion.dart` → `.xlsx`) ya implementados.
- **iOS — listing App Store**: hecho. App **aprobada + LIVE en App Store público**
  2026-05-28 → distribución multiplataforma completa (Windows + Play + iOS).
- **Sitrack P4 — tiempo promedio de descarga**: el KPI ya lo muestra la pantalla
  Descargas (`admin_descargas_screen`, promedio en min). Queda solo ranking por
  chofer + alerta de outliers (esperar ~1 mes de data).
- **Bot PC dedicada + acceso remoto**: operativos desde 2026-05-18 (NSSM +
  Tailscale `100.99.223.44` + RDP). Ver `project_bot_pc_dedicada.md`.
- **Setup PC de desarrollo nueva**: `docs/SETUP_PC_DESARROLLO.md` (toolchain:
  Flutter 3.44.0, Node 22 nvm, etc.) + `secrets\README_RESTAURACION.md` del Drive.

**Decisión abierta de ICM**: el "baseline odómetro" del CESVI quedó **moot** — la
UI usa el ICM **oficial** de Sitrack desde el 22-may y el CESVI está desconectado.
Lo que queda es decidir si **retirar** el CESVI (ver sección operativa abajo).

---

## 📅 2026-05-24 — Actualización del estado de propuestas Volvo/WhatsApp

### ✅ HECHO hoy (commits del 24-may)

- **V5 Bypass de seguridad** (`onAlertaVolvoCreated` extendido):
  DAS / LKS / LCS / AEBS ya NO van al chofer (él los apagó) → van a
  Molina con throttle 6h por (patente, tipo). Helper
  `_notificarBypassSeguridad` + colección META_BYPASS_SEGURIDAD.

- **WhatsApp Bot — mejoras menú** (M1 + M2 + M3): breakdown enviados
  por categoría, búsqueda free-form en cola, badge en tile panel.
  M4 ya estaba.

- **Card "Reglas de notificación" completa**: 16 reglas en 5 categorías
  reflejan TODA la realidad operativa (no las 3 viejas).

### ⚠️ HALLAZGOS que reorientan tareas

- **V1 (Tablero Seguridad)**: el agente del inventario se equivocó.
  `VOLVO_SCORES_DIARIOS` tiene los 17 sub-scores de EFICIENCIA
  (anticipation/idling/topgear/etc.) — NO los de SEGURIDAD
  (Defensivo/Atención/Uso funcional que vimos en Volvo Connect web).
  Para hacer V1 real hay que agregar un poller a `/safetyReport` (M).
  Postponed.

- **V2 (Ralentí)**: la pantalla Eco-Driving YA expone `idling` por
  unidad + drill-down con los 17 sub-scores. Una pantalla nueva
  "Ralentí" sería redundante. Lo que SÍ falta:
  · % real de ralentí (no el score Volvo, el % de tiempo del informe
    Rendimiento — requiere endpoint /performance o cálculo desde
    /vehiclestatuses con ignition + speed).
  · Estimación monetaria L perdidos × precio diésel.
  Ambos requieren ingest nuevo. Postponed.

- **Bonus (Eco-Driving detallado)**: YA estaba implementado de antes.
  La pantalla muestra los 8 principales + drill-down con los 17.

- **C P3 (DTCs históricos Sitrack)**: requiere scraper Sitrack web
  nuevo (`sync_dtcs.py` en `sitrack_sync/`). Postponed.

- **E M5 (Editar destinatarios desde la app)**: refactor de ~10 CFs
  para que lean los DNIs de Firestore `META/destinatarios_notificacion`
  en lugar de hardcoded en `comun.ts`. Pantalla CRUD. Postponed por
  scope (M-L), pero queda como prioritario porque ya lo flageó la
  auditoría del 2026-05-18 y mantenimiento es realmente importante
  para evitar dependencia técnica si cambia un destinatario.

---

## 📅 2026-05-24 — Análisis Volvo Connect vs nuestra app — propuestas pendientes

Exploración profunda del portal Volvo Connect (9 módulos del app launcher
+ 8 informes estándar + dashboard) + inventario exhaustivo del lado nuestro
(qué ya consumimos vs qué no). **8 propuestas priorizadas por ROI**. Hoy
se cerró V6 — las 7 restantes quedan acá como roadmap.

### ✅ HECHO hoy

- **V6 — Widget Km Recorridos** (commit `3507d4a`). Sorpresa: TELEMETRIA_HISTORICO
  ya tenía snapshot diario por las 53 unidades Volvo (`telemetriaSnapshotScheduled`
  cada 6h). Solo faltaba consumirlo. Nuevo widget en
  AdminMantenimientoDetalleScreen con KPIs mes en curso vs anterior +
  gráfico 30 días + tabla 3 meses (km, L, l/100km). Service
  OdometrosService calcula deltas client-side.

### ⏳ PENDIENTE — ordenadas por ROI

#### 🥇 V1 — Tablero Seguridad por chofer (data ya en Firestore, solo UI)
**Esfuerzo: S. Valor: 🔥🔥🔥**

`VOLVO_SCORES_DIARIOS` ya tiene 17 sub-scores del API Volvo (Defensivo, Atención,
Uso funcional, etc.). La pantalla Eco-Driving solo muestra eficiencia.
**Toda la data de seguridad está, falta UI.**

Plan: pantalla nueva "Seguridad" en hub ICM con score 78 + 3 sub-scores
(Defensivo 85 / Atención 53 / Uso funcional 91) + 12 sub-métricas (Distance
Alert, ABS, frenado brusco, advertencia colisión, DAS, LKS, LCS, AEBS) +
ranking unidades por score seguridad + WhatsApp diario a Molina con
unidades < 60.

#### 🥈 V2 — Métrica RALENTÍ % por chofer/unidad (combustible perdido)
**Esfuerzo: M. Valor: 🔥🔥🔥**

Hoy desperdiciamos plata sin medir. Volvo lo expone en informe Rendimiento
(% ralentí, % PTO, % punto muerto, % programador velocidad por vehículo).
**1 punto % menos de ralentí flota = ~3000 L/mes = $1.500.000 ARS/mes.**

Plan: extender `volvoScoresPoller` para persistir `ralenti_pct`, `pto_pct`,
`punto_muerto_pct` por vehículo/día (los campos ya vienen del API).
Pantalla "Combustible" en Reportes con ranking + L perdidos estimados +
$/mes + alerta WhatsApp si una unidad > 35% ralentí 3 días seguidos.
Cruce con chofer asignado via SITRACK_IBUTTONS_HISTORICO.

#### 🥉 V3 — Calendario citas taller FUTURAS (visibilidad Emmanuel)
**Esfuerzo: M. Valor: 🔥🔥🔥**

Hoy Emmanuel sabe lo PASADO (sync_taller.py historial). NO sabe qué hay
PROGRAMADO. Volvo `/calendar` tiene cada cita con tipo (Diagnóstico/Reparación)
+ taller + dirección + tel + estado.

Plan: scraper Playwright `sync_calendario.py` en volvo_sync/ → escribe
VEHICULOS_CITAS_TALLER/{patente}_{fecha_iso}. Pantalla "Calendario taller"
en Mantenimiento (vista mes con citas). WhatsApp a Emmanuel cada lunes
06:00: "Esta semana van al taller: AF472BO mié 30/abr (Ruta Sur Trucks
Bahía Blanca)". Tile en panel: "3 citas próximas".

#### 4️⃣ V4 — Reporte mensual sostenibilidad CO₂/NOx/PM para YPF
**Esfuerzo: M. Valor: 🔥🔥🔥** (diferenciador comercial)

YPF y clientes corporativos PIDEN datos de emisiones. Volvo los calcula
(informe Medioambiental: CO₂ t, NOx kg, PM kg por unidad).

Plan: scraper extrae informe Medioambiental mensual → VOLVO_EMISIONES_MES/{YYYY-MM}.
Pantalla "Sostenibilidad" en Reportes (CO₂ t mensual + por unidad + tendencia
anual). Excel exportable "Reporte de Emisiones Vecchi — Mes X" listo para
enviar a YPF.

#### 5️⃣ V5 — Capturar "DAS desactivado" + alertas bypass de seguridad
**Esfuerzo: S. Valor: 🔥🔥🔥** (señal grave hoy invisible)

Cuando un chofer apaga DAS/AEBS/LKS, deliberadamente apaga la seguridad.
Volvo lo emite como alerta separada. Hoy probablemente cae en nuestra
blacklist genérica.

Plan: auditar tipos de alerta en VOLVO_ALERTAS últimos 30 días → identificar
"DAS desactivado" / "Sistema deshabilitado". Whitelist específica
(DAS_DISABLED, DISTANCE_ALERT_DISABLED, LKS_DISABLED) → SIEMPRE al admin
(no al chofer). WhatsApp inmediato a Molina. Ranking mensual top 5 unidades
con más DAS-disabled.

#### 6️⃣ V7 — Monitor suscripciones Volvo vencidas
**Esfuerzo: S. Valor: 🔥** (preventivo, evita perder data)

Dashboard muestra 6 suscripciones vencidas hoy. Si vencen las críticas
(Posicionamiento, Telemetría, Alerts API), perdemos data sin enterarnos.

Plan: scraper extiende sync_taller.py para leer el widget de suscripciones
semanalmente. Si hay vencidas → alerta a Santiago para renovar antes.

#### 7️⃣ V8 — Frenadas/Aceleraciones/ESC/Distance Alert por 100 km
**Esfuerzo: S. Valor: 🔥🔥**

Hoy comparamos choferes por # eventos absolutos. Un chofer que hizo 3000 km
naturalmente tiene más eventos que uno que hizo 1000 km. Volvo normaliza
por 100 km — comparación justa.

Plan: extender VOLVO_SCORES_DIARIOS con los promedios/100km que Volvo
expone en informe Seguridad. Agregar columnas al ranking ICM:
"Frenadas/100km", "Aceleraciones/100km", "ESC/100km".

### ❌ DESCARTADOS con justificación

- **Libro de Registro Volvo**: chat con taller. Vecchi no lo usa, nuestro
  módulo de Taller es propio.
- **Mensajería Volvo**: chat con asistencia. WhatsApp ya cubre.
- **Tienda de servicios Volvo**: gestión comercial externa.
- **Administración usuarios/vehículos Volvo**: gestión externa, no fluye
  nada operativo a la app.
- **Informe Resumen + Seguimiento**: duplican lo que tenemos en pantallas propias.

---

## 📅 2026-05-24 — Análisis Sitrack vs nuestra app — propuestas pendientes

Auditoría completa del portal Sitrack (43 endpoints / vistas inventariados) + cruce
con nuestra app. **6 propuestas priorizadas por ROI**. Hoy se cerraron 2 — las 4
restantes quedan acá como roadmap para próximas sesiones.

### ✅ HECHO hoy

- **P2 — Histórico real de iButton** (`7d9919d`). Pipeline desde `SITRACK_EVENTOS`
  con CF diaria + backfill + pantalla "Auditoría asignaciones" que cruza contra
  `ASIGNACIONES_VEHICULO`. 1.755 tramos cargados.
- **P4 (parcial) — Cola de descargas YPF Añelo** (`78f50aa` + `2ad40be`). Reemplaza
  PTO Volvo por geocercas Sitrack configurables. Filtro por rango de fecha+hora.
  Falta: el KPI específico "tiempo promedio descarga" + ranking choferes + alerta
  outliers (acumular ~1 mes de data primero y después decidir).

### ⏳ PENDIENTE — ordenadas por ROI

#### 🥇 P1 — Auto-poblar viajes desde Sitrack (ROI MÁXIMO)
**Esfuerzo: M (3-7 días). Valor: 🔥🔥🔥**

Hoy: cada viaje en `VIAJES_LOGISTICA` se carga MANUAL (chofer / unidad / origen /
destino / fecha_carga / fecha_descarga / km). Es la fricción más grande del módulo.

**Plan:**
1. Definir geocercas en Sitrack para los 5-10 lugares clave (YPF Añelo, plantas
   Vecchi, destinos GASPERINI, etc.). 1 vez, en Sitrack web.
2. Scraper nuevo `sitrack_sync/sync_viajes.py` cada 30 min:
   - `tiempoEnZona.php` (rango ayer→hoy) — entradas/salidas por chofer
   - `tiempoViaje.php` (rango ayer→hoy) — viajes detectados
3. CF que ingiere y propone viajes:
   - Patrón "estadía >30min origen → movimiento → estadía >30min destino"
   - Crea `VIAJES_LOGISTICA` con `estado='PROPUESTO_SITRACK'` (no `EN_CURSO`)
   - Pre-llena chofer, unidad, fecha_carga, fecha_descarga, tarifa sugerida
4. Pantalla nueva "Viajes propuestos" en hub Logística — admin revisa y confirma
   con 1 click.

**Impacto:** ahorro de horas/mes de operador, 0 errores de tipeo, métricas reales
de duración. **Esto sólo justifica el proyecto.**

#### 🥈 P3 — DTCs históricos para Emmanuel (alto valor, rápido)
**Esfuerzo: S (1-2 días). Valor: 🔥🔥🔥**

Hoy: sólo tell-tales del momento actual (Volvo `VOLVO_ESTADO`). Si un Check Engine
se prende y apaga sin que Emmanuel mire en ese instante, lo perdemos.

**Plan:**
1. Extender `sync_icm.py` (o nuevo `sync_dtcs.py`) para llamar
   `historicoCodigoFalla.php` (últimos 7 días) → array de DTCs por unidad.
2. Persistir `VEHICULOS_DTC_HISTORICO/{patente}_{ts}` (idempotente por timestamp).
3. **Sumar al "Parte de mantenimiento" 08:00 de Emmanuel**
   (`resumenMantenimientoVehiculosDiario`):
   - "Tractor AB421DP: 3 códigos de falla últimos 7 días (P0507, P0420, P1259)"
   - DTC recurrente 3+ veces → highlight rojo "REVISAR"
4. Pantalla "Historial DTCs" en mantenimiento detalle por unidad.

**Impacto:** mantenimiento PREDICTIVO real (no reactivo). Emmanuel anticipa fallas.

#### 🥉 P5 — Consumo combustible cubriendo NO-Volvo
**Esfuerzo: M. Valor: 🔥🔥**

Hoy: `report_consumo.dart` sale de `TELEMETRIA_HISTORICO` (Volvo) — sólo cubre los
53 Volvo. Las unidades no-Volvo quedan fuera.

**Plan:**
1. Scraper consulta `/site5/fuel_consumption/` (toda la flota).
2. Persistir `SITRACK_CONSUMO_DIARIO/{patente}_{YYYY-MM-DD}`.
3. Modificar `report_consumo.dart` para cruzar Volvo + Sitrack — consumo unificado.

**Impacto:** cobertura total de la flota Vecchi.

#### 6️⃣ P6 — Auditar geocercas + Reglas Sitrack
**Esfuerzo: S. Valor: 🔥** (bajo en código, alto en operación)

Hoy: no sabemos qué reglas / geocercas tiene Vecchi configuradas en Sitrack.

**Plan:**
1. Santiago abre las Reglas en Sitrack y lista qué hay vs qué falta.
2. Configurar las que faltan (ej. "Salir de zona Bahía Blanca después de las 02:00"
   → alerta operativa).
3. Documentar en un doc o card admin.

**Impacto:** complementa el sistema de alertas existente con triggers nativos
Sitrack que NO requieren código nuestro.

### ❌ DESCARTADOS con justificación

- **Adm Mantenimiento de Sitrack** (G11): nuestra solución es más rica (Volvo
  serviceDistance + horas motor + historial taller + Emmanuel). Migrar = retroceder.
- **DVR cámaras cabina** (G9): Vecchi probable no tiene cámaras. N/A.
- **Enviar Mensaje a teclado cabina** (G8): WhatsApp ya cubre. Bajísimo ROI.
- **H. Temperatura** (G13) + **Validar Carga Combustible** (G14): no aplican al
  negocio Vecchi (transporta arena seca, carga combustible en estaciones).

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

### Limpieza alertasVolvoDiario HECHA (commit `1c2da83`, mismo día PM)
Removida la regla obsoleta de `health.js` + texto de ayuda + `_etiquetaTipo` del
card "Reglas de notificación" — `ALERTAS_RESUMEN_DESTINATARIO_DNI` ya no aparece
en la app y no engaña a quien intente cambiarla. El card pasa de 4 a 3 reglas.

### ⚠️ Lo único que queda
**(opcional, no es código)** Re-subir el F.931 como PDF más liviano para que abra
al instante en la app (hoy son 18 MB; ya funciona, pero la primera carga toma
varios segundos en datos móviles). Es del lado de Vecchi (admin que sube), no
del lado de la app.

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

> Limpieza 2026-05-28: se quitaron los ya cerrados (multi-tramo features, bot PC
> dedicada, acceso remoto, iOS listing) — detalle en la entrada del 28-may arriba.
> Queda lo realmente abierto:

### Volvo Driver/Tachograph Files API
Módulos activos pero feeds vacíos. Pedir a Volvo Argentina alta de 48
choferes + activación transmisión por unidad.

### ICM — iconos custom (cosmético menor)
✅ El CESVI propio fue **RETIRADO** 2026-05-28: `icm_calculator` + `icm_cesvi` +
`icm_historico_service` + cron `recomputeIcmSemanalScheduled` + colección
`ICM_SEMANAL` + sus tests. La UI usa solo el ICM oficial de Sitrack. Queda como
pendiente cosmético: iconos custom para ICM verde/amarillo/rojo (hoy
`Icons.leaderboard` + color de fondo). ✅ PROD cerrado 2026-05-28: function
`recomputeIcmSemanalScheduled` eliminada + `firestore:rules` deployadas +
colección `ICM_SEMANAL` borrada (firestore:delete).

### Sitrack P4 — ranking + outliers de descarga
El tiempo promedio de descarga ya lo muestra la pantalla Descargas. Falta el
ranking por chofer + alerta de outliers (el que tardó >> que el promedio).
Esperar ~1 mes de data para que el promedio sea representativo.
