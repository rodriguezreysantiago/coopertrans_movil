# Coopertrans Móvil

[![CI](https://github.com/rodriguezreysantiago/coopertrans_movil/actions/workflows/ci.yml/badge.svg)](https://github.com/rodriguezreysantiago/coopertrans_movil/actions/workflows/ci.yml)

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
git clone https://github.com/rodriguezreysantiago/coopertrans_movil.git
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
│   ├── features/         # 24 módulos: admin_dashboard, administracion,
│   │                     # asignaciones, auditoria_asignaciones, auth,
│   │                     # cachatore, checklist, eco_driving, employees,
│   │                     # empresas_empleadoras, expirations, fleet_map,
│   │                     # gomeria, home, icm, jornada_historico, logistica,
│   │                     # registro_jornadas, reports, revisions, vehicles,
│   │                     # vista_ejecutiva, whatsapp_bot, zonas_descarga
│   ├── routing/          # app_router.dart
│   └── shared/           # widgets, utils
├── functions/            # Cloud Functions (TypeScript Node 22)
├── whatsapp-bot/         # Bot Node.js (whatsapp-web.js + firebase-admin)
├── cachatore/            # Sniper de turnos YPF (Python, servicio en la PC dedicada)
├── sitrack_sync/, volvo_sync/  # Scrapers Python (ICM Sitrack / taller Volvo)
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

**onCall (RPC desde el cliente)** — 16 al 2026-06-12
- `loginConDni` — auth con DNI + password (bcrypt + rate limit + custom token con claims).
- `actualizarRolEmpleado` — cambio de rol que refresca custom claim + libera unidades.
- `renombrarEmpleadoDni` — rename de DNI con cascade a colecciones referenciadas.
- `cambiarContrasenaChofer` / `resetearContrasenaEmpleadoAdmin` / `revocarSesionEmpleado` — credenciales y sesión.
- `volvoProxy` — proxy autenticado a Volvo Connect API.
- `auditLogWrite` — bitácora de acciones admin (whitelist server-side).
- `asignarNumeroReciboAdelanto` — numerador secuencial de recibos de adelanto.
- `procesarJornadaHoyChofer` / `procesarJornadaHoyChoferV3` — recálculo on-demand de la jornada del día.
- `cruzarParadasReportadasManual` — corrida manual del cruce paradas↔v3.
- `backfillHistoricoDescargas` / `backfillHistoricoIButtons` / `backfillJornadas` / `backfillRegistrosV3` — backfills manuales.

**onSchedule (crons)** — 25, regenerado desde el código el 2026-06-12

> **Salud de crons**: cada cron registra su latido en `CRON_HEALTH/{id}`
> (wrapper `onScheduleConLatido` de `comun.ts`) y `cronWatchdog` (cada 3 h,
> `cron_health.ts`) avisa por Telegram + WhatsApp si alguno está muerto o
> viene fallando. **Al crear un cron nuevo**: usar el wrapper + sumarlo a
> `REGISTRO_CRONES` (hay un test que lo recuerda).

Pollers de APIs externas:
- `telemetriaSnapshotScheduled` (cada 6h) — odómetro+combustible → `TELEMETRIA_HISTORICO`.
- `volvoAlertasPoller` (cada 5 min) — Vehicle Alerts API Volvo → `VOLVO_ALERTAS`.
- `volvoScoresPoller` (04:00 ART) — Group Scores API → `VOLVO_SCORES_DIARIOS`.
- `estadoVolvoPoller` (cada 5 min) — snapshot rFMS (tell-tales, niveles, horas) → `VOLVO_ESTADO`.
- `sitrackPosicionPoller` (cada 5 min) — Sitrack → `SITRACK_POSICIONES` + drift detection + aviso "pasá el iButton" con throttle 30 min.
- `sitrackEventosPoller` (cada 5 min) — Sitrack `/files/reports` → `SITRACK_EVENTOS` (eventos crudos, TTL 90 días).

Jornadas (v2 en vivo + v3 oficial + reclamos):
- `vigiladorJornadaChofer` (cada 5 min) — v2 EN VIVO: bloques 3×4h + descanso 8h + veda nocturna → `JORNADAS` + avisos al chofer por manejo neto (heads-up 11h, límite 12h). Lógica pura en `evaluarTickJornada`.
- `registrarJornadasV3Diario` (06:45 ART) — v3 OFICIAL a posteriori: reconstruye los turnos de ayer → `REGISTRO_JORNADAS` (fuente del resumen a Molina).
- `reconstruirJornadasDiario` (06:30 ART) — jornadas históricas por día → `VOLVO_JORNADAS_HISTORICO`.
- `reconstruirHistoricoIButtonsDiario` (06:00 ART) — tramos chofer↔patente por iButton → `SITRACK_IBUTTONS_HISTORICO`.
- `cruzarParadasReportadasV3Diario` (07:00 ART) — cruza `PARADAS_REPORTADAS` del chofer contra el v3.
- `cerrarReportesJornadaDiario` (08:00 ART) — cierra reclamos de jornada con veredicto CIERTO/NO_CIERTO/MANUAL cruzando v3 + GPS; el veredicto dispara la devolución WhatsApp. Kill-switch en `META/config_cierre_reportes`.

Descargas YPF:
- `zonaDescargaPoller` (cada 5 min) — presencia en geocercas → `ZONA_DESCARGA_COLA` (cola en vivo) + `ZONA_DESCARGA_HISTORICO`.
- `backfillDescargasDiario` (04:30 ART) — repesca descargas desde `SITRACK_EVENTOS` (más completo que el poller).

Resúmenes diarios 08:00 ART:
- `resumenBotDiario` — estado del bot al admin.
- `resumenDriftsAsignacionesDiario` — drifts (chofer manejó patente no asignada) al admin.
- `resumenExcesosJornadaDiario` — excesos de jornada (fuente v3) al jefe Seg e Higiene.
- `resumenConductaManejoDiario` — Sitrack peligrosos + Volvo AEBS/ESP + sobrevelocidad por chofer a Molina.
- `resumenMantenimientoVehiculosDiario` — parte de mantenimiento (tell-tales/AdBlue/service) a Emmanuel.

Dashboard:
- `recomputeDashboardStats` (cada 30 min) — agregado para tablero admin → `STATS/dashboard`.

Salud + mantenimiento:
- `cronWatchdog` (cada 3 h) — el "cron de los crons": latidos de `CRON_HEALTH` vs cadencia esperada → Telegram + WhatsApp.
- `botHealthWatchdog` (cada 15 min) — bot sin heartbeat → alerta TELEGRAM fuera de banda.
- `procesarSilenciadosExpirados` (cada 10 min) — limpia silenciamientos vencidos en `BOT_SILENCIADOS_CHOFER`.
- `purgarColaWhatsappAntigua` (04:00 ART) — cleanup de `COLA_WHATSAPP` (ENVIADO/ERROR viejos).
- `backupFirestoreScheduled` (domingo 06:00 ART) — export semanal a `gs://coopertrans-movil-backups` (lista explícita de colecciones — al crear una colección nueva, sumarla ahí).

> **Estructura (split completado 2026-05-19)**: `functions/src/index.ts` es un entry point puro (~45 LOC). La lógica vive en módulos temáticos: `comun.ts`/`setup.ts`/`helpers.ts` (compartidos), `auth.ts`, `audit.ts`, `volvo.ts`, `volvo_estado.ts`, `volvo_mantenimiento.ts`, `volvo_telltales.ts`, `telemetria.ts`, `sitrack.ts`, `mantenimiento.ts`, `resumenes_diarios.ts`, `jornadas_v2.ts`, `jornadas_v3.ts` (+`_batch`), `jornada_historico.ts`, `cierre_reportes_jornada.ts`, `paradas_reportadas.ts`, `reportes_discrepancia.ts`, `historico_descargas.ts`, `historico_ibuttons.ts`, `zonas_descarga.ts`, `dashboard_stats.ts`, `cleanup_y_recibos.ts`, `excluidos.ts`, `canales_pausados.ts`, `bot_alerta_externa.ts`. Importar SIEMPRE de `./comun`, nunca de `./index`.

**Triggers de Firestore**
- `onAlertaVolvoCreated` (onDocumentCreated) — al crear alerta Volvo, encola WhatsApp al chofer (blacklist mantenimiento + bypass seguridad a Molina + throttle + silenciamiento).
- `onReporteDiscrepanciaRevisado` (onDocumentUpdated) — al setearse el veredicto de un reclamo, encola la devolución WhatsApp al chofer (idempotente por doc-ID determinístico).

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
