# Coopertrans Móvil

[![CI](https://github.com/rodriguezreysantiago/logistica_app_profesional/actions/workflows/ci.yml/badge.svg)](https://github.com/rodriguezreysantiago/logistica_app_profesional/actions/workflows/ci.yml)

Sistema de gestión de flota para la empresa de transporte **Vecchi / Sucesión Vecchi** (Bahía Blanca). Maneja personal, flota, vencimientos de papeles, checklists, revisiones, integración con Volvo Connect (telemetría + Vehicle Alerts API + Scores API) y un bot de WhatsApp para avisos automáticos.

> Producto comercializado como **Coopertrans Móvil**. Rebrand visual 2026-05-02. Rename del paquete Dart + carpeta del proyecto a `coopertrans_movil` ejecutado 2026-05-08 (commit `22b6825`).

## Stack

- **App Flutter** 3.44 multiplataforma: Windows desktop (admin), Android (choferes, LIVE en Google Play), iOS (LIVE en App Store) y macOS (enviado a review de App Store, 2026-05-29). Web compila pero algunos features se desactivan.
- **Firebase**: Firestore (datos), Storage (archivos), Auth con custom token, Cloud Functions Gen2 (Node.js 22), Crashlytics.
- **Bot WhatsApp**: proyecto Node.js separado en `whatsapp-bot/` que escucha la cola en Firestore y envía mensajes con anti-baneo + watchdog + retry + agrupación por chofer.
- **Volvo Connect API**: telemetría de tractores Volvo (odómetro, combustible, mantenimiento) vía Cloud Function proxy.

## Cómo arrancar

### App Flutter

```powershell
# Clonar
git clone https://github.com/rodriguezreysantiago/logistica_app_profesional.git
cd coopertrans_movil

flutter pub get
flutter run -d windows
# (en VS Code F5 ya tiene la config lista en .vscode/launch.json)

# Las credenciales Volvo Connect viven en Secret Manager (Firebase
# Functions) desde 2026-04-29 y el cliente las consume vía la Cloud
# Function `volvoProxy`. Por eso ya NO hay que pasar `secrets.json`
# ni `--dart-define-from-file` al arrancar.
#
# `serviceAccountKey.json` SÍ sigue siendo necesario para correr
# scripts de admin (`scripts/*.js` y `scripts/*.py`) y para el bot
# de WhatsApp. NO está en git — copiarlo desde Bitwarden, o regenerar
# desde Firebase Console → Project Settings → Service accounts.
```

### Bot WhatsApp

```powershell
cd whatsapp-bot
npm install
cp .env.example .env  # editar valores reales
npm start
```

El primer arranque pide escanear un QR desde el celular descartable. La sesión se persiste en `.wwebjs_auth/`.

## Estructura general

```
coopertrans_movil/
├── lib/                  # App Flutter
│   ├── core/             # services, constants, theme
│   ├── features/         # admin_dashboard, auth, employees, vehicles,
│   │                     # expirations, revisions, reports, whatsapp_bot,
│   │                     # checklist, sync_dashboard, home, gomeria,
│   │                     # logistica, eco_driving, fleet_map, asignaciones
│   ├── routing/          # app_router.dart
│   └── shared/           # widgets, utils
├── functions/            # Cloud Functions (TypeScript Node 22)
├── whatsapp-bot/         # Bot Node.js (whatsapp-web.js + firebase-admin)
├── scripts/              # Migraciones one-shot (Python + Node) + release pipeline
├── android/, ios/, web/, windows/
├── firebase.json         # firebase deploy --only firestore:rules / functions
├── firestore.rules
├── storage.rules
└── ESTADO_PROYECTO.md    # Doc de handoff completo
```

## Documentación

| Archivo | Para qué |
|---|---|
| **[`RUNBOOK.md`](RUNBOOK.md)** | Apagar incendios. Bot caído, login roto, rollback, backup, Sentry, disaster recovery. Leerlo si algo NO ESTÁ ANDANDO en producción. |
| **[`ESTADO_PROYECTO.md`](ESTADO_PROYECTO.md)** | Handoff completo. Stack, arquitectura, convenciones, decisiones técnicas, sesiones de trabajo, pendientes. Leerlo si vas a CAMBIAR algo. |
| **[`MANUAL_USUARIO.md`](MANUAL_USUARIO.md)** | Guía para usuarios finales (chofer, admin, supervisor). Para entregar al cliente. |
| **[`DEMO_CHECKLIST.md`](DEMO_CHECKLIST.md)** | Checklist pre-demo: 8 flujos clave para validar la app antes de presentarla al cliente. |
| **`README.md`** (este) | Onboarding inicial. Cómo arrancar el proyecto la primera vez. |

## Roles y permisos

6 roles del sistema (custom claim `rol` en JWT) × 5 áreas (descriptivas):

| Rol | Qué hace |
|-----|----------|
| `CHOFER` | Empleado de manejo. Ve sus vencimientos + su unidad asignada. |
| `PLANTA` | Empleado sin vehículo (planta, taller, gomería). Solo vencimientos personales. |
| `GOMERIA` | Especializado: solo opera el módulo Gomería (cubiertas). |
| `SEG_HIGIENE` | Especializado: solo ve los tableros Volvo (alertas, eco-driving, descargas, mapa). |
| `SUPERVISOR` | Mando medio. Gestiona personal/flota/vencimientos/revisiones/bot/Logística. |
| `ADMIN` | Control total. Crea admins, cambia roles, audita. |

Áreas: `MANEJO`, `ADMINISTRACION`, `PLANTA`, `TALLER`, `GOMERIA`.

Las capabilities cliente viven en `lib/core/services/capabilities.dart`. Los chequeos server-side están en `firestore.rules` con helpers `isAdmin()`, `isSupervisor()`, `isAdminOrSupervisor()`, `puedeOperarGomeria()`, `puedeVerVolvoTableros()`.

## Cloud Functions

Todas en `southamerica-east1`.

**onCall (RPC desde el cliente)**
- `loginConDni` — auth con DNI + password (bcrypt + rate limit + custom token con claims).
- `actualizarRolEmpleado` — cambio de rol que refresca custom claim + libera unidades.
- `renombrarEmpleadoDni` — rename atómico de DNI con cascade a colecciones referenciadas.
- `volvoProxy` — proxy autenticado a Volvo Connect API.
- `auditLogWrite` — bitácora de acciones admin (whitelist server-side).

**onSchedule (crons)** — última actualización 2026-05-18

Pollers de APIs externas:
- `telemetriaSnapshotScheduled` (cada 6h) — escribe a `TELEMETRIA_HISTORICO`.
- `volvoAlertasPoller` (cada 5 min) — Vehicle Alerts API Volvo → `VOLVO_ALERTAS`.
- `volvoScoresPoller` (04:00 ART) — Group Scores API → `VOLVO_SCORES_DIARIOS`.
- `sitrackPosicionPoller` (cada 5 min) — Sitrack → `SITRACK_POSICIONES` + drift detection + aviso "pasá el iButton" con throttle 30 min.
- `sitrackEventosPoller` (cada 5 min) — Sitrack `/files/reports` → `SITRACK_EVENTOS` (1400+ tipos de evento crudos para análisis).

Vigilador jornada v2 (refactor 2026-05-15, reemplaza al v1):
- `vigiladorJornadaChofer` (cada 5 min) — tracking de bloques 3×4h (3h45 manejo + 15 min pausa) + descanso 8h + veda nocturna → escribe a `JORNADAS` (no más `JORNADAS_CHOFER` legacy) + encola avisos al chofer. **Avisos de jornada por MANEJO NETO acumulado** (heads-up 11h, límite firme 12h — fix 2026-05-19; antes era por `bloques_completos >= 3`, que daba falsos positivos). Lógica de decisión en `evaluarTickJornada` (pura, 21 tests).
- `procesarSilenciadosExpirados` (cada 1h) — limpia silenciamientos vencidos en `BOT_SILENCIADOS_CHOFER`.

Resúmenes diarios a Vecchi:
- `resumenBotDiario` (08:00 ART) — estado del bot al admin.
- `resumenDriftsAsignacionesDiario` (08:00 ART) — drifts (chofer manejó patente no asignada) al admin.
- `resumenExcesosJornadaDiario` (08:00 ART) — excesos del vigilador v2 al jefe Seg e Higiene.
- `resumenConductaManejoDiario` (08:00 ART) — Sitrack peligrosos + Volvo AEBS/ESP únicos + sobrevelocidad cartográfica detallada por chofer a Molina.

Dashboard:
- `recomputeDashboardStats` (cada 5 min) — agregado para tablero admin → `STATS/dashboard`.

Salud + mantenimiento:
- `botHealthWatchdog` (cada 15 min) — alerta si el bot WhatsApp no heartbeatea.
- `purgarColaWhatsappAntigua` (diario) — cleanup de docs viejos en `COLA_WHATSAPP` con estado ENVIADO/ERROR.
- `backupFirestoreScheduled` (domingo 06:00 ART) — export semanal a `gs://coopertrans-movil-backups`.

(Cron eliminado en refactor v2: `avisoFinJornadaNocturna` — la veda nocturna 00:00 ART ahora se detecta en tiempo real por `vigiladorJornadaChofer`.)

> **Estructura (split completado 2026-05-19)**: `functions/src/index.ts` es un entry point puro (6884 → 45 LOC, solo `import "./setup"` + re-exports). La lógica vive en módulos temáticos: `auth.ts`, `audit.ts`, `comun.ts` (helpers compartidos), `volvo.ts`, `telemetria.ts`, `sitrack.ts`, `icm.ts`, `mantenimiento.ts`, `resumenes_diarios.ts`, `jornadas_v2.ts`, `dashboard_stats.ts`, `cleanup_y_recibos.ts`. Ver `project_split_functions_index.md`.

**onDocumentCreated (triggers)**
- `onAlertaVolvoCreated` — al crear alerta Volvo, encola WhatsApp al chofer (con blacklist mantenimiento + throttle 10/h/chofer + silenciamiento universal).
- `onAlertaVolvoMantenimientoCreated` — persiste eventos de mantenimiento sin encolar (los recoge el bot 1 vez/día).

Deploy:
```powershell
firebase deploy --only functions
firebase deploy --only firestore:rules
firebase deploy --only storage
```

⚠️ **Bug conocido**: `firebase deploy --only firestore:rules,functions:X` solo deploya el primero silenciosamente. Siempre separar en 2 comandos.

## Bot WhatsApp

Escucha `COLA_WHATSAPP` en Firestore. Cron cada 60 min escanea EMPLEADOS y VEHICULOS, calcula urgencias y encola avisos. Si un chofer tiene 2+ vencimientos para avisar, los agrupa en un solo mensaje (anti-baneo). Tiene:

- Reintentos con backoff exponencial para errores transitorios.
- Watchdog del evento `READY` (resuelve cuelgue del A/B testing de WhatsApp Web).
- Heartbeat cada 60s a `BOT_HEALTH/main` (visible en pantalla "Estado del Bot" de la app).
- Kill-switch desde la app (toggle en pantalla del bot).
- Comandos admin por WhatsApp (`/estado`, `/pausar`, `/reanudar`, `/forzar-cron`, `/ayuda`).
- Modo dry-run (`BOT_DRY_RUN=true`) para testing sin enviar real.

## Convenciones críticas

- **Orden de NOMBRE**: APELLIDO(s) + NOMBRE(s) en mayúsculas. El algoritmo de saludo extrae el primer nombre del segundo token. Para casos donde falla (dos apellidos, segundo nombre), usar el campo `APODO`.
- **DNI = doc.id en EMPLEADOS** (sin formato, solo dígitos).
- **Patente = doc.id en VEHICULOS** (sin guiones, en mayúsculas).
- **Fechas**: formato ISO `YYYY-MM-DD` en Firestore. Parseo manual para evitar shift UTC vs local.

## Release de una versión nueva

Script todo-en-uno (bump + build Windows + instalador + GitHub Release + AAB
Android + **deploy de la app web** a cooper-trans.com.ar/sistema/):

```powershell
.\scripts\release_completo.ps1                  # bump patch+1+build+1, todo
.\scripts\release_completo.ps1 -DryRun          # ver qué haría sin tocar nada
.\scripts\release_completo.ps1 -SkipAndroid     # solo Windows
.\scripts\release_completo.ps1 -SkipWeb         # no actualiza la web
.\scripts\release_completo.ps1 -Version 1.2.3+45  # versión explícita
```

Después subir manual el AAB a Play Console (Closed Testing → nueva
versión → upload). El AAB queda en
`build/app/outputs/bundle/release/app-release.aab`.

### Web institucional + acceso web a la app

La web pública del cliente (`https://cooper-trans.com.ar`) y el acceso web a esta
misma app (`/sistema/`) viven en un proyecto **separado**:
`C:\Users\Colo Logistica\web_coopertrans\` (no versionado en git todavía). El paso
web del `release_completo` compila `flutter build web --base-href /sistema/` y lo
sube por FTP — es best-effort (si no está ese proyecto o las credenciales FTP en la
PC, lo saltea). Ver memoria `project_web_institucional.md` para el detalle.

⚠️ **Bug conocido**: si renombrás la carpeta del proyecto, el cache
de CMake en `build/windows/x64/CMakeCache.txt` queda con el path
absoluto viejo y `flutter build windows` falla con
`The current CMakeCache.txt directory is different than the
directory ... where CMakeCache.txt was created`. Fix: `flutter
clean` antes de buildear.

## Licencia

Privado — uso interno de Vecchi.
