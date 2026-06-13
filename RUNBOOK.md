# RUNBOOK — Coopertrans Móvil

Documento operativo para resolver incidentes en producción. Pensado para que **alguien que no sea Santiago** pueda mantener el sistema funcionando si Santiago no está disponible.

> El [README.md](README.md) es para arrancar el proyecto; el [ESTADO_PROYECTO.md](ESTADO_PROYECTO.md) es contexto histórico. Este archivo es para **apagar incendios**.

---

## Tabla de contenidos

1. [Diagnóstico rápido — ¿qué está roto?](#diagnóstico-rápido)
2. [Cambio de PC (sync casa ↔ oficina)](#cambio-de-pc-sync-casa--oficina)
3. [Bot WhatsApp no envía mensajes](#bot-whatsapp-no-envía-mensajes)
4. [Login no funciona / la app no deja entrar](#login-no-funciona)
5. [Volvo Connect: telemetría sin actualizar](#volvo-connect-telemetría-sin-actualizar)
6. [Volvo Alertas: tablero sin eventos nuevos](#volvo-alertas-tablero-sin-eventos-nuevos)
7. [Migrar Cloud Functions de region (gotchas)](#migrar-cloud-functions-de-region)
8. [Rollback de un deploy malo](#rollback-de-un-deploy-malo)
9. [Backup y disaster recovery](#backup-y-disaster-recovery)
10. [Comandos rápidos de diagnóstico](#comandos-rápidos-de-diagnóstico)
11. [Contactos y secretos](#contactos-y-secretos)
12. [Web institucional + deploy del sitio y la app web](#web-institucional--deploy-del-sitio-y-la-app-web)

---

## Diagnóstico rápido

**Si algo no anda, chequear en este orden:**

| Síntoma | Dónde mirar primero |
|---|---|
| Choferes no reciben WhatsApp | Pantalla "Estado del Bot" en la app → si hace > 2 min sin heartbeat, [bot caído](#bot-whatsapp-no-envía-mensajes) |
| App pide login pero rechaza credenciales válidas | [Cloud Function loginConDni](#login-no-funciona) |
| Tractores Volvo aparecen sin telemetría | [Volvo Connect 401](#volvo-connect-telemetría-sin-actualizar) o ticket de paquete UPTIME |
| Después de un deploy todo se rompe | [Rollback](#rollback-de-un-deploy-malo) |
| `firebase deploy` falla con `eslint no se reconoce` o `No currently active project` | [Pre-checks de deploy](#pre-checks-antes-de-correr-firebase-deploy) |
| `start_bot.ps1` aborta diciendo que hay cambios pero `git diff` está vacío | [Stat dirty del package-lock](#start_botps1-aborta-por-package-lock-modificado-pero-git-diff-está-vacío) |
| Pantalla blanca al abrir la app | Crashlytics en Firebase Console (solo mobile) — desktop solo logs locales |

---

## Cambio de PC (sync casa ↔ oficina)

Santiago alterna entre PC de casa y PC de oficina. La PC que NO se usa
queda atrás: faltan commits de Flutter, faltan deploys ya hechos, el
bot puede estar corriendo en la otra. Esta sección es la check-list
para ponerla al día sin perderse nada.

> **Tip operativo**: hacé un `git push` y `git status` siempre **antes
> de cerrar la PC actual**. Si dejás cambios sin commitear, la otra
> PC va a empezar el día con un estado raro (rama divergida) y vas a
> perder tiempo merging.

### Paso 1 — Cerrar correctamente la PC actual

Antes de irte de la PC donde estuviste trabajando:

```bash
# 1) Verificar que no hay cambios sin commitear
git status

# 2) Si hay cambios pendientes, commitearlos (o stashearlos)
git add -A && git commit -m "WIP: <descripción corta>"
# o si querés guardarlo sin ensuciar la historia:
# git stash push -m "wip-<fecha>"

# 3) Push a remote — esto es lo que la otra PC va a bajar
git push origin main

# 4) Si tenés el bot corriendo acá, decidir qué hacer (ver paso 4)
```

### Setup one-time en CADA PC nueva (Win) o en la Mac

Ejecutar UNA SOLA VEZ después de clonar el repo. Los hooks de Claude Code (`SessionStart` con `git pull` automático + `Stop` con alerta de cambios sin pushear) ya vienen en `.claude/settings.json` versionado — se activan solos. Lo que sí hay que configurar por máquina es:

#### Windows

```powershell
cd C:\Users\Colo Logistica\coopertrans_movil

# 1) Git hooks versionados (post-commit que respalda docs a Drive).
git config core.hooksPath .githooks

# 2) Path de Drive en Win (asume que Drive Desktop mapeo G:).
git config claudesync.drivepath "G:/Mi unidad/ClaudeCodeSync/proyecto-docs"
mkdir -Force "G:\Mi unidad\ClaudeCodeSync\proyecto-docs"

# 3) Sentry CLI + config (para upload de symbols Dart en builds Android).
npm install -g @sentry/cli
git config sentry.org      "coopertrans"
git config sentry.project  "flutter"
git config sentry.authtoken "sntryu_..."   # token con scopes Project + Release Admin
```

#### Mac

```bash
cd ~/ruta/al/repo/coopertrans_movil

# 1) Git hooks versionados.
git config core.hooksPath .githooks

# 2) Path de Drive en Mac (CloudStorage). Verificar primero el path real:
ls "$HOME/Library/CloudStorage/" | grep -i drive
# Despues, ajustar al email de la cuenta:
git config claudesync.drivepath "$HOME/Library/CloudStorage/GoogleDrive-santiagocoopertrans@gmail.com/My Drive/ClaudeCodeSync/proyecto-docs"
mkdir -p "$HOME/Library/CloudStorage/GoogleDrive-santiagocoopertrans@gmail.com/My Drive/ClaudeCodeSync/proyecto-docs"

# 3) Sentry CLI + config (para upload de Dart symbols + iOS dSYMs en builds iOS).
brew install getsentry/tools/sentry-cli   # o: npm install -g @sentry/cli
git config sentry.org      "coopertrans"
git config sentry.project  "flutter"
git config sentry.authtoken "sntryu_..."   # token con scopes Project + Release Admin

# 4) (Solo Mac) workaround Ruby 4.0 + CocoaPods 1.16:
#    En vez de `pod install` directo, siempre:
#      cd ios
#      LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install
#      cd ..
```

Después de eso queda todo automatizado:
- Cada `git commit` copia los `.md` críticos a Drive (`ESTADO_PROYECTO.md`, `RUNBOOK.md`, `MANUAL_USUARIO.md`, `POLITICA_PRIVACIDAD.md`, `docs/PLAY_STORE_LISTING.md`, etc.).
- Cada vez que arranca Claude Code: `git pull --ff-only` automático.
- Cada vez que cierra Claude Code: aviso si quedaron cambios sin commitear o commits sin pushear.
- Los scripts `release_android.ps1` (Win) y `release_ios.sh` (Mac) suben los symbols a Sentry automáticamente como parte del build.

### Generar token de Sentry (one-time, sirve para todas las maquinas)

1. https://coopertrans.sentry.io/settings/account/api/auth-tokens/
2. **Create New Token** → nombre `cli-symbols-upload`.
3. Permissions:
   - **Project** → `Admin` (cubre `project:read/write/admin/releases`).
   - **Release** → `Admin`.
   - El resto en `No Access`.
4. Click Create → copiar el token (`sntryu_...`) — solo se muestra UNA vez.
5. Pegarlo en cada máquina con `git config sentry.authtoken "..."`.

Si el token se filtra (por error en chat, log, etc.), **revocarlo** desde la misma URL y generar uno nuevo — actualizar las máquinas con el nuevo `git config`.

### Paso 2 — Sync de código en la PC nueva (oficina)

```bash
cd C:\Users\Colo Logistica\coopertrans_movil

# 1) Bajar todo lo que se pusheó desde la otra PC
git fetch origin
git pull origin main

# 2) Si la PC estuvo varios días sin abrir el repo, mirá el changelog:
git log --oneline -20

# 3) Resolver dependencias Flutter (puede haber packages nuevos)
flutter pub get

# 4) Si pubspec.yaml o pubspec.lock cambiaron, reinstalar plugins nativos:
flutter clean
flutter pub get
```

### Paso 3 — Compilar y arrancar la app

```bash
# Para ver que todo compila antes de correr en debug
flutter analyze --no-pub
flutter test --no-pub

# Si pasaron, arrancar la app
flutter run -d windows
```

> Si el build Windows falla con `Filename too long` en submódulos de
> sentry-native, el path del cwd es muy profundo. Asegurate de
> trabajar desde `C:\Users\Colo Logistica\coopertrans_movil\` y NO
> desde un worktree dentro de `.claude/worktrees/...`.

### Paso 4 — Bot WhatsApp: ¿dónde corre ahora?

**Modelo actual** (definido 2026-05-10): el bot está instalado **solo
en PC oficina** como instancia primaria, y en **PC casa** como backup
standby por si la oficina falla físicamente. **Etapa testeo**: el bot
se arranca manualmente sólo en días hábiles cuando hace falta — NO
está en auto-start (`StartType: Manual`). Domingo / feriados / horario
no hábil → bot apagado, sin gasto de WhatsApp Web ni riesgo de baneo
por mensajes fuera de turno. Cuando se pase a operación 24×7 (post
testeo) → cambiar a `StartType: Automatic` para que sobreviva reboots.

**El bot solo puede correr en UNA PC a la vez** (anti-doble-bot
chequea heartbeat compartido en `BOT_HEALTH/main` para evitar
mensajes duplicados a choferes — ver `start_bot.ps1`). Si por
accidente quedan ambos prendidos en simultáneo, la primera en
levantar el lock gana y la otra se autocierra.

#### Caso normal: bot en PC oficina (etapa testeo)

```powershell
# Verificar estado
Get-Service CoopertransMovilBot
# Esperado en etapa testeo:
#   Status      : Running    (durante días hábiles, prendido por Santiago)
#   Status      : Stopped    (fines de semana / feriados / horario no hábil)
#   StartType   : Manual     (NO arranca solo en boot — decisión consciente)

# Arrancar al inicio del día hábil:
Start-Service CoopertransMovilBot

# Detener al fin del día hábil (opcional — el bot ya respeta horario
# hábil a nivel polling, pero apagar el proceso ahorra recursos y
# elimina cualquier riesgo de mensaje accidental fuera de turno):
Stop-Service CoopertransMovilBot

# Validar que arrancó OK:
Get-Content whatsapp-bot\logs\bot.out.log -Tail 30 -Wait
# Buscar línea "WhatsApp listo para enviar" + "Polling de COLA_WHATSAPP"
```

#### Si la PC oficina falla → activar backup en PC casa

```powershell
# === En la PC de OFICINA (si todavía responde) ===
Stop-Service CoopertransMovilBot
Set-Service CoopertransMovilBot -StartupType Disabled

# === En la PC de CASA (la que va a tomar el bot) ===
cd C:\Users\Colo Logistica\coopertrans_movil

# 1) Sync del código (es parte del mismo repo)
git pull origin main

# 2) Instalar dependencias si cambiaron
cd whatsapp-bot
npm ci
cd ..

# 3) Levantar el bot (anti-doble-bot validará que no haya otro vivo)
Set-Service CoopertransMovilBot -StartupType Automatic
Start-Service CoopertransMovilBot

# 4) Verificar
Get-Service CoopertransMovilBot
# y mirar la pantalla "Estado del Bot" en la app — heartbeat < 30s
```

#### Cuando vuelve la PC oficina

```powershell
# === En la PC de CASA, parar el bot y volver a standby ===
Stop-Service CoopertransMovilBot
Set-Service CoopertransMovilBot -StartupType Manual

# === En la PC de OFICINA ===
Set-Service CoopertransMovilBot -StartupType Manual
Start-Service CoopertransMovilBot
# Recordatorio: en etapa testeo el bot va Manual on-demand. Cuando se
# pase a 24×7 post-testeo, cambiar a Automatic en lugar de Manual.
```

#### Caso testing: no querés bot real

Si solo vas a hacer testing local sin bot real, dejá el servicio
parado en ambas PCs y trabajá tranquilo. El admin puede ver en la
pantalla "Estado del Bot" que está caído (heartbeat viejo) — eso es
esperable mientras desarrollás.

### Paso 5 — Deploys pendientes

Si en casa hiciste cambios a `firestore.rules`, `firestore.indexes.json`,
`functions/`, `storage.rules`, los deploys los hace el que tiene
acceso a Firebase y NO se replican automáticamente. Algunos quedan
"pendientes" hasta que corras los comandos.

Para ver qué te falta deployar:

```bash
# Diff de los últimos commits, mirar si tocan rules/indexes/functions
git log --oneline --name-only -10 | grep -E "(rules|indexes|functions/)"
```

Comandos típicos (correr de a UNO — el filter combinado tiene un bug
de Firebase CLI conocido):

```bash
firebase deploy --only firestore:rules
firebase deploy --only firestore:indexes
firebase deploy --only functions
firebase deploy --only storage:rules
```

### Paso 6 — Cron `volvoPoller` y schedules

No requieren acción al cambiar PC: están en GCP Cloud Scheduler y
corren igual desde dónde sea. Solo verificar en la pantalla "Sync
Dashboard" de la app que el último poll fue reciente.

### Check-list rápida para "vine después de varios días"

```bash
# 1. Sync
git pull origin main

# 2. Dependencias
flutter pub get

# 3. Migraciones de schema/rules: ya están en Firestore (server-side),
#    no hay nada que correr local
flutter analyze --no-pub
flutter test --no-pub

# 4. ¿Hay deploys pendientes?
git log --oneline --name-only origin/main..HEAD 2>/dev/null   # vacío = ok
# Si la oficina hace 5 días que no commitea, NO hay nada para deployar
# desde acá — los deploys los hizo casa. Mirá el ESTADO_PROYECTO para
# confirmar que las rules/indexes/functions deployadas están al día.

# 5. Bot
# Modelo actual: el bot corre siempre en PC oficina. PC casa es backup
# standby. Verificar Get-Service CoopertransMovilBot — debe estar Running
# en oficina, Stopped/Disabled en casa.

# 6. Arrancar
flutter run -d windows
```

> **Memoria de Drive**: si trabajás con Claude Code, la memoria vive
> en `G:\Mi unidad\ClaudeCodeSync\memory\` y es la misma en ambas PCs
> (Drive sincroniza sola). No hace falta sync explícito.

---

## Bot WhatsApp no envía mensajes

El bot corre como **servicio NSSM en una PC con Windows** (PC oficina, modelo actual desde 2026-05-10; PC casa lo tiene instalado en standby como backup). El proceso se llama `CoopertransMovilBot`.

### Cómo te enterás: alerta por Telegram (desde 2026-06-10)

La Cloud Function `botHealthWatchdog` (corre en GCP cada 15 min, independiente
de la PC) avisa al **Telegram de Santiago** (bot `@Coopertrans_Bot`) cuando:

- 🔴 **Bot caído**: sin heartbeat > 10 min (PC apagada, NSSM muerto, sin internet).
- 🔴 **Sesión WhatsApp rota**: el bot está vivo pero el cliente quedó en
  `AUTH_PENDIENTE`/`AUTH_FALLO` (pide QR — inmediato) o lleva > 30 min sin
  llegar a `LISTO` (Chromium trabado / no reconecta).
- 🟢 **Recuperado**: cuando vuelve a `LISTO`, con la duración del incidente.

Anti-spam: re-aviso a los 60 min y después cada 6 h. Si te llega la alerta,
seguí los pasos de abajo según el caso (caído → restart limpio; QR → receta
"Si el restart no alcanza", paso 4-5).

Setup/código: `functions/src/bot_alerta_externa.ts` (header con el detalle).
Secrets en Secret Manager: `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`. Si hay
que cambiar el destinatario: actualizar el secret `TELEGRAM_CHAT_ID` (el
chat_id sale de `https://api.telegram.org/bot<TOKEN>/getUpdates` después de
escribirle al bot) y redeployar `functions:botHealthWatchdog`.

### Verificar si el bot está corriendo

```powershell
# Estado del servicio Windows
Get-Service CoopertransMovilBot

# Heartbeat a Firestore (lo que ve la app)
# Pantalla admin > "Estado del Bot" muestra ultimoHeartbeat,
# pcId, cliente WA, cola, último ciclo del cron.
```

Si el heartbeat es de hace > 2 min, el bot está caído **aunque el servicio diga "Running"**: puede estar trabado en initial-load de WhatsApp Web.

### Restart limpio

```powershell
cd C:\Users\Colo Logistica\coopertrans_movil\whatsapp-bot
.\scripts\stop_bot.ps1   # auto-eleva UAC, espera grace period 90s
.\scripts\start_bot.ps1  # hace git pull + npm install + nssm start
```

`scripts\stop_bot.ps1` hace stop ordenado respetando el `grace_shutdown` del bot (deja terminar mensajes en vuelo). `scripts\start_bot.ps1` rechaza arrancar si hay cambios sin commitear (proteger producción).

### Si el restart no alcanza

El "calvario operativo" del 1-mayo PM (sec. 6.11.11 del `ESTADO_PROYECTO.md`) dejó esta receta:

```powershell
# 1. Stop service desde PowerShell-Admin
Stop-Service CoopertransMovilBot -Force

# 2. Borrar la sesión rota (requiere admin porque LocalSystem la creó)
Remove-Item C:\Users\Colo Logistica\coopertrans_movil\whatsapp-bot\.wwebjs_auth -Recurse -Force

# 3. Borrar cache de Chromium
Remove-Item C:\Users\Colo Logistica\coopertrans_movil\whatsapp-bot\.wwebjs_cache -Recurse -Force

# 4. Start service. Va a pedir QR fresco.
Start-Service CoopertransMovilBot

# 5. Mirar logs de NSSM para ver el QR
Get-Content C:\Users\Colo Logistica\coopertrans_movil\whatsapp-bot\logs\bot.out.log -Tail 50 -Wait
```

**Importante**: nunca correr `node src/index.js` a mano si el servicio NSSM está activo. Una sesión a la vez. Mezclar ambos quema la sesión persistida.

### Comandos por WhatsApp (sin abrir la PC)

Mandar al **propio número del bot** desde un teléfono que esté en `ADMIN_PHONES` del `.env`:

- `/estado` — resumen de cola, último ciclo, pausa.
- `/pausar [Nh|Nd]` — pausar envíos (opcional duración: `/pausar 24h`).
- `/reanudar` — reanudar.
- `/forzar-cron` — corre el ciclo del cron ahora (no espera 60min).
- `/test-aviso DNI` — mensaje de prueba al teléfono del DNI indicado.
- `/jornada DNI` — estado del vigilador para ese chofer (manejo neto total de la jornada / 12h, manejo continuo del bloque actual, pausa, avisos enviados, patente, silenciado si aplica). Output técnico.
- `/enviar-jornada DNI` — (2026-05-19) le manda AL CHOFER su estado de jornada (el mismo texto que ve si tipea `/jornada`). Útil para recordatorios de descanso o al discutir horas con un chofer. Si el chofer está silenciado, no encola y avisa. Encola en COLA_WHATSAPP con origen `jornada_manual_admin` (time-sensitive, TTL 30 min).
- `/silenciar DNI dur [motivo]` — suprime avisos del vigilador (Ns/Nm/Nh/Nd, cap 30d). Ej: `/silenciar 12345678 2h en taller`. Encola aviso al chofer "silenciado por X horas hasta DD/MM HH:MM ART, motivo: X". El cron `procesarSilenciadosExpirados` (cada 10 min) detecta cuando se cumple el plazo y encola "notificaciones reanudadas".
- `/desilenciar DNI` — revierte un /silenciar previo. Si estaba activo, encola "se reanudaron las notificaciones".
- `/ayuda` — lista comandos.

Si los comandos no responden y vos sí estás en la whitelist, el bot está **caído** — no es problema de permisos.

#### Comandos para CHOFERES (desde su WhatsApp)

Cualquier chofer cuyo `EMPLEADOS.TELEFONO` matchee el número que manda al bot puede usar:

- `/jornada` — *sin DNI*. El bot resuelve su DNI por su teléfono y le devuelve cómo va su jornada del día en lenguaje natural (cuántas horas manejó, cuántas le quedan antes del límite, cuánto le falta para la pausa de 4h, qué avisos recibió, hora mín. de arranque si cumplió 12h). Si está silenciado, también se lo dice.
- `/ayuda` — lista los 2 comandos disponibles para chofer.

**Restricciones**:
- Si el chofer tipea `/jornada DNI_AJENO`, el bot ignora el DNI y le devuelve sus propios datos. No puede espiar a otros.
- Si tipea cualquier comando admin (`/silenciar`, `/pausar`, etc.) → silencio total. Sin error visible para no exponer la existencia del comando.
- Match teléfono: el `EMPLEADOS.TELEFONO` debe estar formateado con prefijo (ej. `5492914567890`). Si está mal cargado, el chofer no se reconoce y el bot lo ignora.

### Resumen diario perdido (Emma, Giagante, Molina, Santiago)

**Síntoma**: el destinatario habitual de un resumen consolidado diario
no lo recibió hoy. Causa común: el bot estuvo caído toda la ventana
hábil (8h+) y el TTL `expira_en` venció antes de que el bot vuelva. El
doc se descarta automáticamente, y el lock de idempotencia diaria
(`AVISOS_AUTOMATICOS_HISTORICO/<tipo>_<YYYY-MM-DD>_<dni>`) bloquea
re-generación dentro del mismo día.

**Re-disparar manualmente** (cuando el bot vuelva):

```powershell
# 1) Identificar el lock a borrar segun cron:
#    - cron_service_diario:           service_diario_<fecha>_<dni>
#    - resumen_mantenimiento_vehiculos (CF "Parte de mantenimiento", reemplazó
#                                      al cron_mantenimiento_diario el 2026-05-22):
#                                      mantenimiento_vehiculos_<DD-MM-YYYY>
#    - cron_vencimientos_proximos_diario: ya no usa AAH (idem)
#    - resumen_jornadas_v2:           excesos_jornada_<fecha>
#    - resumen_conducta_manejo_diario: conducta_manejo_<fecha>
#    - cron_bot_resumen_diario:       bot_resumen_<fecha>_<dni>
#    - resumen_drifts_asignaciones:   drifts_<fecha>_<dni>

# 2) Desde GCP Console -> Firestore -> AVISOS_AUTOMATICOS_HISTORICO
#    buscar el doc del dia y BORRARLO. Esto libera el lock.

# 3) Forzar el cron:
#    - Crons del bot (service/mantenimiento/vencimientos): /forzar-cron
#      por WhatsApp al bot desde un numero ADMIN.
#    - Crons CF (bot_resumen/drifts/jornadas/conducta): no se pueden
#      forzar via API. Opciones:
#        a) Esperar al proximo cron del dia siguiente (mas simple).
#        b) Re-deployar la function con un cambio trivial → GCF
#           dispara automaticamente la siguiente invocacion en su
#           proximo schedule.
#        c) Manual desde GCP Console -> Cloud Functions -> seleccionar
#           la function -> tab "Logs" no permite trigger, pero
#           Cloud Scheduler SI: GCP Console -> Cloud Scheduler ->
#           buscar el job correspondiente (ej. firebase-schedule-
#           resumenConductaManejoDiario-southamerica-east1) -> "Force
#           run".

# Importante: si borras el lock pero NO forzas el cron, el doc se
# va a regenerar en el proximo cron natural (ej. 8 AM del dia
# siguiente). Pero ese resumen sera del DIA SIGUIENTE, no del dia
# perdido.
```

**Para evitarlo a futuro**: el setup 24/7 con PC dedicada + smart plug
+ BIOS auto-power-on + UPS reduce el riesgo a ~cero. Cuando ocurra
igual, ya sabés el procedimiento.

### El bot está corriendo pero choferes no responden

Probablemente WhatsApp baneó el número. Síntomas:
- Heartbeat OK pero `cola.PROCESANDO` se acumula.
- Errores tipo "rate limit" en logs.

**Acción inmediata**: pausar el bot (`/pausar 24h`) para no agravar. El número descartable hay que reemplazarlo. Esto es un riesgo conocido de `whatsapp-web.js` no oficial — la migración a WhatsApp Business API oficial está en el roadmap (sec. 13.4 del ESTADO_PROYECTO).

---

## Login no funciona

Síntoma: el usuario tipea DNI + password correctos y la app dice "Error de servidor".

### Chequeo 1 — Cloud Function viva

```powershell
# Logs en tiempo real de loginConDni
firebase functions:log --only loginConDni --lines 50
```

Errores comunes:

| Mensaje | Causa | Fix |
|---|---|---|
| `iam.serviceAccounts.signBlob denied` | SA runtime sin Service Account Token Creator sobre sí misma | Re-aplicar IAM (ver `ESTADO_PROYECTO.md` sec. "Hardening de seguridad") |
| `permission-denied: ...allUsers Cloud Run Invoker missing` | Después de un deploy nuevo, Cloud Run quitó el `allUsers` invoker | `gcloud run services add-iam-policy-binding logincondni --region=southamerica-east1 --member="allUsers" --role="roles/run.invoker"` |
| `resource-exhausted: Demasiados intentos fallidos` | Rate limit pegándole al usuario | Esperar 15 min, o limpiar `LOGIN_ATTEMPTS/{hash(dni)}` desde la consola Firestore |

### Chequeo 2 — Custom claims desactualizadas

Si un usuario fue creado o cambió rol HACE POCO y aún no funciona, es porque el JWT viejo no tiene el claim. Solución: **logout + login** en la app (forza renovar el token).

---

## Volvo Connect telemetría sin actualizar

`telemetriaSnapshotScheduled` corre cada 6h y escribe a `TELEMETRIA_HISTORICO`. Si los datos están viejos:

```powershell
# Ver últimas ejecuciones del scheduled
firebase functions:log --only telemetriaSnapshotScheduled --lines 30
```

Errores comunes:

- **401 Unauthorized**: credenciales Volvo expiraron o cliente las rotó. Recuperar nueva password de Volvo (mirar email del cliente / sec. 8 ESTADO_PROYECTO) y rotar el secret:
  ```powershell
  firebase functions:secrets:set VOLVO_PASSWORD
  # pega la nueva password
  firebase deploy --only functions:telemetriaSnapshotScheduled,functions:volvoProxy
  ```
- **`uptimeData.serviceDistance` undefined**: paquete UPTIME inactivo en la cuenta Volvo. Hay ticket abierto. Mientras tanto el bot usa Plan B (`ULTIMO_SERVICE_KM + 50.000 - KM_ACTUAL`).

---

## Volvo Alertas: tablero sin eventos nuevos

`volvoAlertasPoller` corre cada 5 min y escribe a `VOLVO_ALERTAS` los eventos del Vehicle Alerts API (IDLING, DISTANCE_ALERT, OVERSPEED, PTO, TELL_TALE, ALARM, etc.). Si el tablero "Alertas" del admin no muestra nada nuevo:

```powershell
# Logs del poller — buscar el último ciclo OK
firebase functions:log --only volvoAlertasPoller --lines 30

# Estado del cursor (si quedó atascado)
# Ir a Firestore Console → META/volvo_alertas_cursor
# Campos: ultimo_request_server_datetime, ultimo_exito_at, ultimo_recibidos
```

**Si los logs muestran `OK` con `recibidos: 0` por varios ciclos**: no es un bug — significa que la flota Volvo no generó eventos en la última ventana. Confirmá mirando el `ultimo_exito_at` del cursor, debería actualizarse cada 5 min.

**Errores comunes:**

- **401 Unauthorized en logs**: credenciales Volvo expiraron. Mismo fix que `telemetriaSnapshotScheduled` arriba (rotar `VOLVO_PASSWORD` y redeploy).
- **`Volvo HTTP error statusCode: 429`**: rate limit de Volvo. El poller se sale silencio sin avanzar el cursor → próximo ciclo reintenta. Si pasa seguido, bajar la cadencia (cambiar `every 5 minutes` a `every 10 minutes` en el código + redeploy).
- **`fetch falló` con timeout**: glitch de red. Idem 429 — no avanza cursor, próximo ciclo reintenta.
- **Cursor atascado**: si el poller falló muchas veces seguidas, el `ultimo_request_server_datetime` apunta a un punto del pasado y cada run trae mucho histórico. Para resetear: borrar el doc `META/volvo_alertas_cursor` desde Firestore Console (próximo run hace cold start desde "ahora −1h").

**Modelo del doc en VOLVO_ALERTAS:**
```
docId: {VIN}_{createdMs}_{TIPO}      // composite e idempotente
fields:
  vin, tipo, severidad,              // alertType, severity del payload
  patente,                           // customerVehicleName o cross-ref VEHICULOS
  creado_en, recibido_en,            // Timestamps ARG (UTC en Firestore)
  posicion_gps: {lat, lng, ...},     // si vino gnssPosition
  detalle_<subtipo>: {...},          // sub-objeto del payload (idling, pto, etc.)
  driver_id,                         // si vino tachoDriverIdentification
  distancia_total_metros, horas_motor,
  polled_en,                         // serverTimestamp del run
  // Campos de gestión (los setea el admin desde la app, NO el poller):
  // atendida, atendida_por, atendida_en
```

El poller usa `getAll` antes de escribir para detectar duplicados — **no pisa los campos de gestión** seteados por el admin.

---

## Migrar Cloud Functions de region

Cambiar la region de las Cloud Functions (ej: us-central1 → southamerica-east1) toca prod completo. Orden correcto aprendido en la migración del 2026-05-02:

1. **Cambiar el código**:
   - `functions/src/index.ts:setGlobalOptions({ region: "<nueva>" })`.
   - **Buscar TODAS las URLs hardcoded** en el cliente Flutter (`grep -r "us-central1-coopertrans"`). En esta app son 4: `auth_service.dart`, `audit_log_service.dart`, `empleado_actions.dart`, `volvo_api_service.dart`. Reemplazar por la región nueva.
2. **Build + lint + tests local** (`npm run build && npm run lint && npm test` en `functions/`).
3. **Commit + merge a main** (si trabajás desde un worktree, ojo: el deploy lee del repo principal, no del worktree).
4. **Deploy**: `firebase deploy --only functions`. Firebase detecta que las viejas están en otra region y pregunta `Would you like to proceed with deletion?` — **respondé `N`** para que cree las nuevas sin borrar las viejas. Las viejas quedan vivas pero huérfanas (no las gestiona Firebase).
5. **Reaplicar IAM `allUsers Cloud Run Invoker`** en las callables públicas (Gen2 lo pierde en cada deploy nuevo):
   ```powershell
   foreach ($svc in @("logincondni","auditlogwrite","actualizarrolempleado","volvoproxy")) {
     gcloud run services add-iam-policy-binding $svc --region=<nueva> --member="allUsers" --role="roles/run.invoker"
   }
   ```
6. **Smoke test** desde un cliente Flutter rebuildeado: login admin + acción auditable + sync Volvo + actualizar rol. Si **algo** falla → `git revert` + redeploy en la región vieja.
7. **Borrar viejas con `gcloud`** (Firebase NO las borra automáticamente):
   ```powershell
   foreach ($fn in @("loginConDni","auditLogWrite","actualizarRolEmpleado","volvoProxy","telemetriaSnapshotScheduled","volvoAlertasPoller")) {
     gcloud functions delete $fn --region=<vieja> --quiet
   }
   ```

**Gotchas conocidos:**

- En el primer deploy multi-function en una región nueva, una function puede fallar con `NAME_UNKNOWN: Repository "gcf-artifacts" not found` (race en la creación del repo Artifact Registry). Reintento simple con `firebase deploy --only functions:<nombre>` resuelve.
- Filter combinado `--only functions:NAME,firestore:rules` puede tirar `No function matches given --only filters` aún si la function existe en el código. Workaround: dos comandos separados.

---

## Deploy de Cloud Functions

### Pre-checks antes de correr `firebase deploy`

Si nunca deployaste desde esta PC (o pasó tiempo), tres cosas que hay que verificar antes para no chocarse con errores de tooling:

**1. Project alias activo** (`No currently active project`):
```powershell
firebase use coopertrans-movil
# → "Now using project coopertrans-movil"
```
Queda guardado en `.firebaserc` local de la PC.

**2. Dev dependencies de `functions/` instaladas** (`"eslint" no se reconoce`):
```powershell
cd functions
npm install
cd ..
```
El predeploy hook de `firebase.json` corre `npm run lint` + `npm run build` — sin las dev deps falla a la primera. Una vez al setupear la PC alcanza.

**3. Build local OK** (sanity check antes de quemar el deploy):
```powershell
cd functions
npm run build
cd ..
```
Si `tsc` tira error, el deploy va a fallar igual — mejor verlo acá. Sigue: `flutter analyze` + `flutter test` + `cd whatsapp-bot ; npm test` para confirmar que el repo entero está limpio.

### Comando de deploy

```powershell
# Deploy de UNA function (recomendado para producción)
firebase deploy --only functions:loginConDni

# Deploy de todas las functions del codebase
firebase deploy --only functions
```

⚠️ **Bug conocido del filter combinado**: `firebase deploy --only firestore:rules,functions:X`
solo deploya **el primer item silenciosamente** y termina con éxito (no
te avisa que el segundo lo ignoró). **Siempre separar en 2 comandos**:

```powershell
firebase deploy --only firestore:rules
firebase deploy --only functions:X
```

### Validación post-deploy obligatoria

**Apenas termine el deploy**, validar:
- Login admin desde la app Flutter en < 5 segundos.
- Login chofer cualquiera, también OK.
- Si alguno falla: rollback inmediato (siguiente sección). No esperar a que se quejen los usuarios.

Errores comunes después de un deploy:
- `iam.serviceAccounts.signBlob denied` → ver tabla en [Login no funciona](#login-no-funciona).
- `permission-denied: ...allUsers Cloud Run Invoker missing` → idem.

---

## Web institucional + deploy del sitio y la app web

La web pública (`https://cooper-trans.com.ar`) y el acceso web a esta misma app
(`/sistema/`) viven en **`C:\Users\Colo Logistica\web_coopertrans\`** — proyecto
separado, **NO versionado en git**. Detalle: memoria `project_web_institucional.md`.

**Hosting:** FTP, Apache/LiteSpeed, fuerza HTTPS. Credenciales **solo** en
`~/Desktop/ftp_datos.txt` (`SERVIDOR` / `USUARIO` / `PASSWORD`) — nunca hardcodear ni
commitear. Raíz del server = `/public_html`.

### Actualizar la app web (lo normal: ya va dentro del release)
`release_completo.ps1` lo hace solo (paso best-effort, flag `-SkipWeb` para omitir).
A mano:

```powershell
cd "C:\Users\Colo Logistica\coopertrans_movil"
flutter build web --release --base-href /sistema/    # ¡PowerShell, NO git-bash!
Copy-Item build\web\* "..\web_coopertrans\sitio_nuevo\sistema\" -Recurse -Force
cd "..\web_coopertrans"
python _subir_sitio.py sistema                        # sube SOLO /sistema
```

⚠️ El `--base-href /sistema/` SOLO funciona desde **PowerShell**. En git-bash la ruta
se mangle a `C:/Program Files/Git/sistema/` y el build queda con base `/` (los assets
dan 404 al servirse en `/sistema/`).

### Actualizar el sitio de marketing (la home)
Editar `web_coopertrans\sitio_nuevo\` y subir:

```powershell
cd "C:\Users\Colo Logistica\web_coopertrans"
python _subir_sitio.py            # sube TODO (sitio de marketing + /sistema)
python _subir_sitio.py --dry      # simular sin tocar el server
```

### Cosas a saber
- **Login web** = mismo DNI + contraseña (callable `loginConDni`, CORS lo maneja el
  framework de callables). Si el login web falla pero el de la app no: confirmar HTTPS
  (contexto seguro) — el `.htaccess` raíz lo fuerza.
- `.htaccess` raíz: HTTPS + `DirectoryIndex index.html ...` (gana al `index.php` viejo)
  + gzip. `sistema/.htaccess`: fallback SPA (sirve index.html en rutas internas) + gzip.
  Si el host ignorara `.htaccess` (no Apache), el refresh en una ruta interna de la app
  podría dar 404.
- Backup del sitio viejo (Flash/PHP): `web_coopertrans\cooper-trans_sitio_viejo_backup_2026-05-19.zip`.
- Para deployar desde la **OTRA PC**: copiar `web_coopertrans` + `ftp_datos.txt` allá
  (si no, el paso web del release simplemente se saltea).
- Limpiar restos del sitio viejo en el server: `python _limpiar_viejo.py` (dry) /
  `--go` (ejecuta). Excluye cgi-bin / local-cgi / .well-known.

## Rollback de un deploy malo

### Cloud Functions

```powershell
# Ver versiones desplegadas
gcloud functions list --regions=southamerica-east1

# Rollback a una versión específica de una function
# (Functions Gen2 corren en Cloud Run — el rollback es por revisión)
gcloud run services update-traffic <function-name> --to-revisions=<previous-revision>=100 --region=southamerica-east1
```

Ejemplo concreto si `loginConDni` se rompe:
```powershell
# Listar revisiones
gcloud run revisions list --service=logincondni --region=southamerica-east1
# Volver a la anterior
gcloud run services update-traffic logincondni --to-revisions=logincondni-00012-abc=100 --region=southamerica-east1
```

### Firestore rules

```powershell
# Las rules NO tienen rollback automático.
# Mantener un backup local antes de cada deploy:
cp firestore.rules firestore.rules.backup
firebase deploy --only firestore:rules
# Si algo se rompe:
cp firestore.rules.backup firestore.rules
firebase deploy --only firestore:rules
```

### App Flutter (en producción)

No hay rollback automático para mobile/desktop builds — el usuario tiene que reinstalar la versión anterior. Para desktop la app se distribuye manualmente (`flutter build windows --release`); guardar el `.exe` de la versión estable en OneDrive antes de cada release nueva.

---

## Backup y disaster recovery

Hay dos backups críticos: **Firestore** (datos del negocio) y **`.wwebjs_auth/`** (sesión WhatsApp del bot). Los scripts ya están en el repo; falta programarlos.

### Backup Firestore — automático cloud-side (`backupFirestoreScheduled`)

Desde 2026-05-03 el backup corre **en la nube**, sin depender de ninguna PC. Es la Cloud Function `backupFirestoreScheduled` (en `functions/src/mantenimiento.ts`):

- **Frecuencia**: **DIARIO 06:00 ART** (desde 2026-06-12 — era semanal; el RPO de 7 días era una semana de liquidaciones perdibles).
- **Output**: `gs://coopertrans-movil-backups/auto-{YYYY-MM-DD}_{HHMM}/` con todas las colecciones operativas (~60 — ver `collectionIds` en el código).
- **Retención**: 30 días, gestionada por Object Lifecycle del bucket (sin código). Con frecuencia diaria son ~30 exports rotando (~USD 1-2/mes).
- **Auto-verificación anti-drift (2026-06-12)**: antes de cada export, la function compara `collectionIds` contra las colecciones REALES de la base (`listCollections()`); lo que no esté ni respaldado ni whitelisteado como efímero (`EXCLUIDAS_DEL_BACKUP`) dispara un **Telegram** para clasificarlo. El inventario quedó corto 3 veces (2026-05-18, 2026-06-12 ×2 — la última: los ICM oficiales de YPF) — ya no puede pasar en silencio. Estado del último export en `STATS/ultimo_backup`.
- **Salud**: registra latido en `CRON_HEALTH` y lo vigila `cronWatchdog` (tolerancia 26 h).

### Drill de restore — ENSAYAR la restauración (DRILL #1 ✅ corrido 2026-06-13)

Un backup que jamás se restauró es una promesa, no un plan. El drill completo (anotar cuánto tardó acá abajo). **Dos gotchas confirmados en el DRILL #1 — leer los comentarios antes de correr.**

```powershell
# 1. Elegir el export más reciente:
gcloud storage ls gs://coopertrans-movil-backups

# 2. OPCIÓN A — restore al EMULADOR local (gratis, no toca nada):
#    a. Bajar el export. ⚠️ GOTCHA #1 (DRILL #1): `gcloud storage cp -r` SALTEA
#       archivos en silencio (en el drill bajó 1490 de 1493 sin error). USAR rsync
#       y VERIFICAR que el conteo matchee, si no el import del emulador explota con
#       "FileNotFoundException ...export_metadata / output-NNNN".
gcloud storage rsync -r gs://coopertrans-movil-backups/auto-YYYY-MM-DD_HHMM C:\Temp\restore_drill\firestore_export
#       Verificar: (ls -r del bucket | contar) debe == (Get-ChildItem -Recurse -File | count)
#    b. ⚠️ GOTCHA #2 (DRILL #1): el emulador NO importa un export crudo de GCS;
#       espera SU formato. Hay que envolverlo: poner el export en una subcarpeta
#       `firestore_export\` y crear al lado un `firebase-export-metadata.json`:
#         { "version":"<firebase-tools>", "firestore": {
#             "version":"<jar emulador, ej 1.21.0>", "path":"firestore_export",
#             "metadata_file":"firestore_export/auto-YYYY-MM-DD_HHMM.overall_export_metadata" } }
#    c. Levantar el emulador importando la carpeta CONTENEDORA (la del .json):
firebase emulators:start --only firestore --import C:\Temp\restore_drill --project coopertrans-movil
#    d. Smoke test: correr un script con firebase-admin apuntando al emulador
#       ($env:FIRESTORE_EMULATOR_HOST="127.0.0.1:8080"; NODE_PATH=functions\node_modules)
#       que liste colecciones + cuente docs + muestre EMPLEADOS/VIAJES_LOGISTICA/
#       REGISTRO_JORNADAS. (El error NoClassDefFoundError LegacySystemExit en el log
#       es solo del PATH de salida tras un fatal; si el import OK, no aparece.)
#    e. Apagar: Stop-Process del java en :8080 y del arbol de firebase.cmd.

# 3. OPCIÓN B — restore a un proyecto staging real (más fiel, requiere
#    crear coopertrans-staging una vez):
gcloud firestore import gs://coopertrans-movil-backups/auto-YYYY-MM-DD_HHMM `
  --project=coopertrans-staging

# 4. RESULTADO DEL DRILL:
#    DRILL #1: 2026-06-13 — OPCIÓN A (emulador). Export auto-2026-06-13_0600
#      (245 MiB, 1493 archivos, 68 kinds). Descarga ~13s + import ~12s. Smoke test:
#      54 colecciones top-level, 200.817 docs restaurados, muestras EMPLEADOS/
#      VIAJES_LOGISTICA/REGISTRO_JORNADAS con datos íntegros. RTO efectivo (sin
#      contar los 2 gotchas de arriba): ~3-4 min. Backup CONFIRMADO restaurable.
```

⚠️ **JAMÁS** `gcloud firestore import` contra `coopertrans-movil` salvo catástrofe real confirmada — el import PISA los docs existentes con los del backup.

**Setup operativo (one-time — hacé esto la primera vez)**:

```powershell
# 1. gcloud CLI logueado y proyecto activo:
gcloud auth login
gcloud config set project coopertrans-movil

# 2. Crear bucket si no existe (región SA = menor latencia desde AR):
gcloud storage buckets create gs://coopertrans-movil-backups `
  --project=coopertrans-movil `
  --location=southamerica-east1 `
  --uniform-bucket-level-access

# 3. IAM grants para la SA de Cloud Functions Gen2 (compute SA del proyecto):
gcloud projects add-iam-policy-binding coopertrans-movil `
  --member="serviceAccount:808925655961-compute@developer.gserviceaccount.com" `
  --role="roles/datastore.importExportAdmin"

gcloud storage buckets add-iam-policy-binding gs://coopertrans-movil-backups `
  --member="serviceAccount:808925655961-compute@developer.gserviceaccount.com" `
  --role="roles/storage.objectAdmin"

# 4. Lifecycle de retención 30 días (gestionado por GCP, gratis):
'{"lifecycle":{"rule":[{"action":{"type":"Delete"},"condition":{"age":30}}]}}' | Out-File -Encoding ascii lc.json
gcloud storage buckets update gs://coopertrans-movil-backups --lifecycle-file=lc.json
Remove-Item lc.json

# 5. Deploy de la function:
firebase deploy --only functions:backupFirestoreScheduled
```

**Verificar que el primer run anduvo** (se ejecuta el primer domingo después del deploy, o lo podés disparar manualmente):

```powershell
# Disparar manualmente (en lugar de esperar al domingo):
gcloud scheduler jobs run firebase-schedule-backupFirestoreScheduled-southamerica-east1 `
  --location=southamerica-east1

# Ver el log de la function:
firebase functions:log --only backupFirestoreScheduled --lines 30

# Ver exports en el bucket (debería aparecer la carpeta auto-YYYY-MM-DD_HHMM):
gcloud storage ls gs://coopertrans-movil-backups
```

**Fallback manual**: el script viejo `scripts/backup_firestore.ps1` sigue en el repo como respaldo si querés disparar un export adicional desde tu PC (ej. antes de un cambio riesgoso). NO lo programes con Task Scheduler — la function cloud ya cubre el backup periódico.

**Costo**: ~3 centavos USD/mes para una flota chica. El export en sí es gratis; solo paga storage en GCS.

### Restaurar Firestore desde backup (disaster recovery)

Si pasa lo peor (un admin borra docs por error, una migración corrompe data, ataque, etc.):

**Paso 1 — Identificar qué export usar**:

```powershell
gcloud storage ls gs://coopertrans-movil-backups
# Ver carpetas tipo `auto-YYYY-MM-DD_HHMM` (semanales) y
# `pre-migration-2026-05-01_2259` (snapshot histórico).
# Elegí el más reciente ANTES del incidente.
```

**Paso 2 — Restaurar UNA colección específica** (recomendado — minimiza blast radius):

```powershell
# Ejemplo: restaurar solo EMPLEADOS desde el backup del 5-mayo.
# El import SOBRESCRIBE los docs existentes con el mismo ID — ojo
# con perder cambios hechos después del backup.
gcloud firestore import gs://coopertrans-movil-backups/auto-2026-05-05_0600 `
  --collection-ids=EMPLEADOS `
  --project=coopertrans-movil
```

**Paso 3 — Verificar en Firestore Console** que la colección quedó como esperabas. Solo después de eso seguir con otras colecciones si hace falta.

> **Nunca restaurar TODAS las colecciones a la vez sin pensarlo dos veces** — eso te lleva al estado del backup completo, perdiendo cualquier cambio operativo posterior. Restaurar siempre la colección mínima necesaria.

### Backup `.wwebjs_auth/` (`whatsapp-bot/scripts/backup_wwebjs_auth.ps1`)

La sesión es el "estado autenticado" de WhatsApp Web. Si se pierde, hay que reescanear QR desde el celular descartable. El script comprime la carpeta a un zip con timestamp y aplica retención (60 días por default).

**Programar con Task Scheduler** (Windows):

1. Abrir **Programador de tareas** (Task Scheduler).
2. Click en **Crear tarea básica** → nombre: `Backup wwebjs_auth semanal`.
3. **Trigger**: Semanalmente, día y hora a tu elección (recomendado: domingo 03:00 AM).
4. **Acción**: Iniciar un programa.
   - **Programa**: `powershell.exe`
   - **Argumentos**:
     ```
     -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Colo Logistica\coopertrans_movil\whatsapp-bot\scripts\backup_wwebjs_auth.ps1"
     ```
5. **Condiciones**: marcar "Despertar el equipo para ejecutar esta tarea" si la PC duerme.
6. **Configuración** → "Si la tarea falla, reintentar cada": 5 minutos, hasta 3 intentos.

**Variables de entorno opcionales** (set en system env vars o pasalas al script):
- `BOT_BACKUP_DIR` — destino del zip. Default `%USERPROFILE%\Backups\bot`.
- `BOT_BACKUP_RETENCION_DIAS` — borra zips más viejos que esto. Default 60.

Para llevar los zips a la nube: el `BOT_BACKUP_DIR` apunta a una subcarpeta dentro de **OneDrive** (que sincroniza solo). Ej:
```powershell
[Environment]::SetEnvironmentVariable('BOT_BACKUP_DIR', "$env:USERPROFILE\OneDrive\Backups\bot", 'User')
```

Logs del backup: `whatsapp-bot/logs/backup.log`.

### `serviceAccountKey.json`

Está en **Bitwarden** (vault personal de Santiago). Si Santiago no está disponible: Firebase Console → Project Settings → Service accounts → Generate new private key. La key vieja seguirá funcionando hasta que se revoque manualmente.

> Las credenciales Volvo Connect (`VOLVO_USERNAME`/`VOLVO_PASSWORD`) ya NO se cargan vía `secrets.json` desde 2026-04-29: viven en Secret Manager de GCP del proyecto `coopertrans-movil` y el cliente Flutter las consume vía la Cloud Function `volvoProxy`. Para rotarlas: actualizar en Secret Manager + redeploy de `volvoProxy`.

---

## Sentry — observabilidad

Sentry está integrado en el cliente Flutter. Captura errores y métricas de performance en producción. **El DSN está embebido como `defaultValue`** en `lib/main.dart` (no es un secret crítico — solo permite enviar eventos al proyecto, no leer/borrar datos). Esto significa que **NO necesitás pasar nada** para activarlo: corre activado por default.

### Estado actual

Activo en producción contra el proyecto Sentry de Coopertrans (org `coopertrans` o equivalente). DSN visible en `lib/main.dart`.

### Cómo deshabilitar Sentry temporalmente (dev/local)

```powershell
flutter run -d windows --dart-define=SENTRY_DSN=
```

Pasar `SENTRY_DSN=` (vacío explícito) override el defaultValue → la app corre sin Sentry.

### Cómo rotar el DSN

1. Ir a https://sentry.io → Settings → Projects → tu proyecto → Client Keys (DSN).
2. Generate new key → revoke la vieja.
3. Editar `lib/main.dart`: cambiar el `defaultValue` con el DSN nuevo.
4. Commit + push.

### Cómo cambiar de proyecto Sentry (ej. crear uno nuevo)

1. Crear nuevo proyecto en sentry.io.
2. Copiar el DSN.
3. Editar `lib/main.dart` reemplazando el `defaultValue`.
4. Commit + push.

### Validar en Sentry Console que está funcionando

Corré la app y hacé que tire un error a propósito (ej. login con password mal). En el dashboard Sentry → **Issues** debería aparecer el evento en < 30 segundos. Si no aparece:
- Verificar que el DSN no se haya invalidado.
- Verificar conectividad a `sentry.io` desde la máquina cliente.
- Mirar logs de la app — debería decir `Sentry inicializado (env: production)` al arrancar.

### Configuración actual

- `tracesSampleRate: 0.2` — 20% de transactions trackeadas para perf monitoring. Para una flota chica con uso bajo es razonable; bajar a 0.05 si crece el volumen y los costos de Sentry suben.
- `sendDefaultPii: false` — NO se mandan IPs ni identificadores del usuario sin consentimiento explícito. Importante por compliance AR (Ley 25.326).
- `environment: 'production'` por default — ajustable con `SENTRY_ENV`.

### Cuándo desactivar Sentry

- Durante desarrollo local: `SENTRY_DSN` vacío → modo dev sin Sentry.
- Si sale del free tier (5K events/mes), bajar `tracesSampleRate` o filtrar errores triviales con `beforeSend` en `SentryFlutter.init`.
- Si Sentry falla / cae: la app sigue funcionando (Sentry init fallido no rompe runApp).

### Costo

- Plan free: 5K events/mes. Con flota chica (~57 empleados, errores raros) sobra.
- Si supera, plan Team es ~26 USD/mes.

---

## Costos GCP — budget + alertas

**Budget activo** (configurado 2026-05-11):
- **Billing account**: `012131-B936BA-6291CB` ("Pago de Firebase")
- **Proyecto cubierto**: `coopertrans-movil` (project number `808925655961`)
- **Monto**: USD 10/mes (calendar period)
- **Alertas por email** (a `santiagocoopertrans@gmail.com`):
  - 50% (USD 5) — warning informativo
  - 90% (USD 9) — atención
  - 100% (USD 10) — crítico
- **Display name**: "Firebase Project coopertrans-movil"

USD 10/mes da margen 10× sobre el uso típico actual de la flota (~few USD/mes). Si una Cloud Function entra en loop infinito o algún polling se dispara, las alertas llegan **antes** de que la factura cause sorpresas.

### Comandos de inspección

```powershell
# Ver budgets del billing account
gcloud beta billing budgets list --billing-account=012131-B936BA-6291CB

# Ver detalles de un budget específico
gcloud beta billing budgets describe `
  billingAccounts/012131-B936BA-6291CB/budgets/<BUDGET_ID> `
  --billing-account=012131-B936BA-6291CB

# Ver el billing account asociado a un proyecto
gcloud beta billing projects describe coopertrans-movil

# Listar todos los billing accounts donde Santiago tiene acceso
gcloud beta billing accounts list
```

### Si el budget se vuelve restrictivo (la app crece)

El monto USD 10 está pensado para etapa testeo + Closed Testing. Si la operación crece significativamente:

1. Bajar `tracesSampleRate` de Sentry (ya en 0.05 desde 2026-05-11; se puede bajar más a 0.01).
2. Activar TTL más agresivo en TELEMETRIA_HISTORICO (hoy 18 meses; se puede bajar a 12).
3. Subir el budget a USD 25-50 desde GCP Console.

### Si las alertas llegan inesperadamente

1. Abrir `https://console.cloud.google.com/billing/012131-B936BA-6291CB/reports?project=coopertrans-movil` para ver el desglose por SKU/servicio.
2. Filtrar por las últimas 24h — el spike usualmente viene de Cloud Functions (loop), Firestore reads (query sin limit), o Storage egress (download masivo).
3. Si es Cloud Functions: `firebase functions:log` para encontrar la función culpable y matarla con `gcloud functions delete <name> --region=southamerica-east1`.

---

## CI/CD — GitHub Actions

Workflow en `.github/workflows/ci.yml` que corre **3 jobs en paralelo** en cada push a `main` (y a ramas `claude/**` que es donde Claude Code commitea), y en cada PR hacia `main`. Si alguno falla, GitHub marca el commit con ✗ rojo. Si pasan los tres, ✓ verde.

| Job | Qué hace |
|---|---|
| **Flutter** | `flutter pub get` → `flutter analyze` → `flutter test` (67 tests) → check anti-regresión: falla si alguien introduce nuevos `Colors.<accent>` hardcoded en `lib/` (deben usar `AppColors.accent*`). |
| **WhatsApp Bot** | `npm ci` → `npm test` (54 tests) → `node --check` para validar sintaxis de cada módulo. Skip de descarga de Chromium con `PUPPETEER_SKIP_DOWNLOAD=true` para velocidad (~30s vs ~3min). |
| **Cloud Functions** | `npm ci` → `npm run build` (tsc) → `npm run lint` (ESLint) → `npm test` (helpers puros bcrypt/sha256). |

**El CI NO deploya nada** — solo valida que el repo está sano. Deploy sigue siendo manual (`firebase deploy --only ...`) por decisión consciente: minimiza el blast radius si algo se cuela.

### Activar branch protection (one-time, requiere ser owner del repo)

Sin protection, los ✗ rojos del CI son **informativos** — se pueden mergear igual. Para hacerlos **bloqueantes**:

1. Ir a: https://github.com/rodriguezreysantiago/coopertrans_movil/settings/branches
2. Click en **"Add branch ruleset"** (o "Add rule" si está en la UI vieja).
3. **Branch name pattern**: `main`.
4. Activar:
   - ✅ **Require status checks to pass before merging**
   - ✅ **Require branches to be up to date before merging** (recomendado)
   - En "Status checks that are required" buscar y agregar:
     - `Flutter (analyze + test)`
     - `WhatsApp Bot (npm test)`
     - `Cloud Functions (build + lint)`
5. (Opcional pero recomendado):
   - ✅ **Require a pull request before merging** — bloquea push directo a main, fuerza pasar por PR.
   - ✅ **Require linear history** — evita merge commits, mantiene historia limpia.
   - ❌ NO marcar "Require approvals" (sos único dev — te bloquearías a vos mismo).
6. **Save**.

A partir de ahí, si Flutter analyze rompe, GitHub bloquea el merge hasta que el commit esté en verde.

### Cómo interpretar fails del CI

| Job que falla | Qué revisar primero |
|---|---|
| Flutter — `analyze` | Tirar `flutter analyze` local. Suele ser warning nuevo de un upgrade reciente o variable no usada. |
| Flutter — `test` | `flutter test` local. Test roto por cambio reciente o snapshot obsoleto. |
| Flutter — "No nuevos colors hardcoded" | Reemplazar `Colors.greenAccent` (etc) por `AppColors.accentGreen` (etc) en las líneas que el log marca con `+`. |
| Bot — `npm test` | `cd whatsapp-bot && npm test` local. Suele ser test de feriados que necesita actualizarse en cada cambio de año. |
| Bot — `node --check` | Sintaxis JS rota en algún módulo de `whatsapp-bot/src/`. Suele ser typo de paréntesis. |
| Functions — `npm run build` | `cd functions && npm run build` local. TypeScript no compila. |
| Functions — `npm run lint` | `cd functions && npm run lint -- --fix` autoarreglar; lo que queda es lo manual. |

### Status badge

Visible en el README — muestra el estado del último run del CI sobre `main`. Click en el badge → lleva a la página de Actions.

---

## Decommission del proyecto legacy `logisticaapp-e539a` — ✅ EJECUTADO 2026-05-08

El 2026-05-02 migramos del proyecto Firebase original `logisticaapp-e539a` al nuevo `coopertrans-movil`. El proyecto viejo quedó **frozen** (sin tráfico activo) como red de seguridad mientras validamos que el nuevo se banca todo.

**Decommission ejecutado el 2026-05-08** vía Firebase / GCP Console (Shut down). Se hizo SIN backup final del proyecto viejo — decisión explícita: toda la data viva ya estaba en `coopertrans-movil` desde la migración 2026-05-02 y los avisos / cron / app llevan 6 días operando contra el proyecto nuevo sin observaciones. El proyecto entró en estado `DELETE_REQUESTED` con grace period de 30 días — recuperable hasta ~2026-06-07 desde [GCP Console → IAM → Manage Resources → "Show deleted resources"](https://console.cloud.google.com/cloud-resource-manager). Después de esa fecha, irrecuperable.

> **Nota**: ejecutado 25 días antes de la ventana sugerida (≥ 2026-06-02). Decisión consciente del owner — sin observaciones operativas pendientes en el proyecto nuevo y sin necesidad evidente de la red de seguridad. Si en el grace period (30 días desde 2026-05-08) aparece un caso que requiere consultar el proyecto viejo, restaurar desde GCP Console.

La sección de abajo queda como referencia histórica del procedimiento (NO ejecutar de nuevo).

---

### ¿Cuándo es seguro proceder?

Tres condiciones — TODAS tienen que cumplirse:

1. **≥ 30 días desde la migración**, o sea **≥ 2026-06-02**.
2. **Operación normal validada** durante esa ventana en `coopertrans-movil`:
   - App Flutter levantando OK (login + reportes + carga archivos + nuevas pantallas).
   - Bot WhatsApp despachando notificaciones (vencimientos, alertas Volvo HIGH, mantenimiento).
   - Cloud Functions corriendo sin errores (`firebase functions:log --project=coopertrans-movil --lines 50`).
   - Backup automático Firestore generándose (ver bucket `gs://coopertrans-movil-backups`).
   - Volvo Alerts entrando cada 5 min (`firebase functions:log --only volvoAlertasPoller`).
   - Volvo Scores entrando cada día a las 04:00 ART.
3. **Cero referencias residuales** al proyecto viejo en el código. Validar con:
   ```powershell
   .\scripts\auditar_referencias_proyecto_viejo.ps1
   ```
   Tiene que terminar con `OK: solo hay referencias en archivos historicos esperados.` y exit code 0. Si aparece "WARN" / "código activo", revisar cada hit y migrarlo (o sumarlo al whitelist `$historicalFiles` del script si es histórico legítimo).

### Checklist pre-decommission (línea por línea)

Marcá ✅ a cada uno antes de avanzar al delete final.

- [ ] Pasaron ≥30 días desde la migración (≥ 2026-06-02).
- [ ] Script de auditoría sale con exit 0 y cero hits en código activo.
- [ ] App Flutter validada manualmente: login + reporte Excel + carga archivo en últimas 48h.
- [ ] Bot WhatsApp validado: revisar `Get-Service CoopertransMovilBot` → `Running`.
- [ ] Cloud Functions sin errores: `firebase functions:log --project=coopertrans-movil --lines 100` no muestra `ERROR` ni `WARN` repetidos.
- [ ] Cloud Scheduler ENABLED: `gcloud scheduler jobs list --project=coopertrans-movil --location=southamerica-east1` muestra todos los jobs en `ENABLED`.
- [ ] Backup más reciente del proyecto NUEVO existe: `gcloud storage ls gs://coopertrans-movil-backups | Sort-Object | Select-Object -Last 3` muestra exports de los últimos 3 días.
- [ ] Backup final del proyecto VIEJO (por las dudas, antes de bajar):
  ```powershell
  gcloud firestore export gs://logisticaapp-backups/PRE_DECOMMISSION_$(Get-Date -Format 'yyyy-MM-dd') `
    --project=logisticaapp-e539a
  ```
- [ ] Documentar el delete en `ESTADO_PROYECTO.md` (sección 6.X de la sesión donde se hace).

### Comando final de delete (NO correr antes del checklist)

Hay 2 caminos. **Elegir uno**:

**Opción A — Bajar a Spark plan** (más conservador, gratis pero limitado):
- Firebase Console → `logisticaapp-e539a` → Settings → Usage and billing → Modify plan → Spark.
- El proyecto sigue existiendo pero sin Cloud Functions/Tasks/etc activos. Si en el futuro hace falta consultar la DB vieja, está accesible en read-only.
- No hay comando CLI para esto — desde la consola web.

**Opción B — Borrar el proyecto entero** (definitivo, no hay vuelta atrás):
```powershell
# Esto BORRA el proyecto y TODO su contenido (DB, Storage, Auth, Functions, etc.)
# Hay un grace period de 30 días donde se puede restaurar desde Console,
# pero después de eso es irrecuperable.
gcloud projects delete logisticaapp-e539a
```

**Recomendación**: Opción A (Spark) primero. Da otro mes de gracia "por las dudas" sin costo. Si después de 60 días totales (30 frozen + 30 en Spark) nadie tocó nada del proyecto viejo, ahí sí Opción B.

### Después del decommission

- Actualizar `RUNBOOK.md` (esta sección): marcar "DECOMMISSIONED" con fecha.
- Actualizar `project_pendientes_post_migracion.md` (memoria) para sacar el ítem.
- Si Opción A (Spark): el bucket `gs://logisticaapp-backups` se mantiene mientras dure el plan. Si Opción B: el bucket se borra automáticamente con el proyecto.

---

## Otros gotchas operativos (Windows)

### `start_bot.ps1` aborta por package-lock "modificado" pero `git diff` está vacío

Síntoma:
```
ADVERTENCIA: hay cambios sin commitear en el repo:
 M whatsapp-bot/package-lock.json
```
pero al correr `git diff whatsapp-bot/package-lock.json` no muestra nada.

Es un **stat dirty**: `npm install` actualizó el `mtime` del archivo aunque el contenido es idéntico al committeado. Pasa seguido en Windows + npm.

Fix:
```powershell
git restore whatsapp-bot/package-lock.json
git status   # debe decir "working tree clean"
.\whatsapp-bot\scripts\start_bot.ps1
```

`git restore` re-escribe el archivo desde el index. Como el contenido es idéntico, no rompe nada — solo limpia la marca.

### El bot está corriendo pero las notificaciones no llegan a la app

Cliente Flutter: la pantalla "Estado del Bot" muestra heartbeat OK pero los push notifications de admin no llegan. Causa típica: la sesión del admin está cacheando claims viejos. **Logout + login** en la app suele arreglarlo (renueva el JWT con custom claims actuales).

### El bot arrancó OK pero después de horas se cuelga (encola en loop, no envía)

Síntoma: en `bot.out.log` ves cada 15s los mismos doc IDs entrando a la cola sin enviarse, y en `bot.err.log` warnings repetidos:
```
[WARN] Verificación de XXXXX@c.us falló (transient): Attempted to use detached Frame '...'
```

Significa que el browser de Puppeteer se desconectó (memoria, push de WhatsApp Web, kicked por device, etc.) pero el cliente `whatsapp-web.js` **no emite `disconnected`** y el bot queda llamando un frame muerto.

**Fix automatizado** (commit `673d503`): el wrapper de `whatsapp.js` detecta los patrones `detached Frame` / `target closed` / `browser is closed` y dispara `_gestionarBrowserMuerto()` que destruye el cliente y arranca el flujo de reconexión. Con el bot al día (>= `673d503`) se recupera solo en ~10-15s.

**Fix manual** si necesitás resolverlo a mano (ej. con un bot viejo):
```powershell
Restart-Service CoopertransMovilBot
# o si está corriendo manual con node, Ctrl+C + relanzar
```

### El bot arranca y se cierra en seguida — `client.initialize() falló: The browser is already running`

Síntoma en `bot.err.log`:
```
[ERROR] client.initialize() falló: The browser is already running for ...\.wwebjs_auth\session. Use a different `userDataDir` or stop the running browser first.
[INFO] Reintentando conexión (intento 1/5) en 1000ms...
[WARN] Reconexión falló: The browser is already running for ...
```

Pasa cuando el proceso anterior (`node`/Chromium de Puppeteer) crasheó o no cerró limpio (ej. Ctrl+C duro, kill -9, NSSM kill, host suspendido). Quedó un `chrome.exe` zombi corriendo contra el `userDataDir` y el nuevo intento rebota.

**Fix automatizado** (commit `eb8b37f`): la función `matarProcesosChromiumZombi()` en `whatsapp-bot/src/index.js` corre en pre-flight y mata los `chrome.exe` cuyo CommandLine contiene el path del bot. Con el bot al día (>= `eb8b37f`) el arranque debería ser self-healing.

**Fix manual** si necesitás resolverlo a mano (ej. con un bot viejo):
```powershell
# Listar y matar zombis del bot (NO toca otros Chromes del sistema)
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
  Where-Object { $_.CommandLine -like '*whatsapp-bot*' -or $_.CommandLine -like '*wwebjs_auth*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "Matado PID $($_.ProcessId)" }

# Después arrancar normal
.\whatsapp-bot\scripts\start_bot.ps1
```

### "Working tree clean" pero `git status` muestra `.claude/` untracked

Eso es el state directory del agent (Claude Code). Está ignorado por `.gitignore` desde el commit `80874b3`. Si igual aparece, tu copia local del repo no tiene ese commit — `git pull` y debería desaparecer.

---

## Comandos rápidos de diagnóstico

```powershell
# === Bot ===
Get-Service CoopertransMovilBot                   # Estado del servicio
Get-Content whatsapp-bot\logs\bot.out.log -Tail 50 -Wait   # Logs en vivo (punto, no guion)
Get-Content whatsapp-bot\logs\bot.err.log -Tail 50         # Errores

# === Tests (deben pasar antes de cada deploy) ===
flutter test                                    # 275 tests cliente (al 2026-05-13)
cd whatsapp-bot ; npm test                      # 120 tests bot
cd functions ; npm run build                    # tsc limpio

# === Firebase ===
firebase functions:log --lines 100              # logs de TODAS las functions
firebase deploy --only functions:loginConDni    # deploy una sola function
firebase deploy --only firestore:rules          # deploy solo rules

# === Git ===
git log --oneline -20                           # últimos 20 commits
git status -uno                                 # cambios sin .claude/
```

---

## Scripts de probe APIs externas

Patrón seguro: las credenciales viven SOLO en Secret Manager. Para correr scripts ad-hoc, levantar las creds a env vars del proceso PowerShell con `Get-Credential` (prompt nativo Windows que NO expone la pass a history ni a logs) y limpiar al final.

### Probes Volvo Connect

```powershell
cd "C:\Users\Colo Logistica\coopertrans_movil"
$cred = Get-Credential -Message "Volvo Connect" -UserName "018B1E992E"
$env:VOLVO_USERNAME = $cred.UserName
$env:VOLVO_PASSWORD = $cred.GetNetworkCredential().Password

# Scores (eco-driving). Confirma si el módulo está activo en el contrato.
node scripts/probar_volvo_scores_api.js

# Driver API — actividad del tacógrafo (DRIVE/REST/WORK/AVAILABLE) +
# forecast (timeLeftToDriveUntilBreak / DailyRest etc).
# Estado al 2026-05-13: 200 OK pero solo 2 chofers registrados y
# `activities: []` en histórico 7 días → bloqueado esperando que Volvo
# active la transmisión por unidad.
node scripts/probar_volvo_driver_api.js

# Messaging API (HMI camión) + Tachograph Files API (.DDD legales).
# Estado al 2026-05-13: Messaging 403 (fuera de contrato),
# Tachograph 200 con archivos vacíos (mismo bloqueo que Driver).
node scripts/probar_volvo_modulos_no_usados.js

Remove-Item Env:VOLVO_USERNAME, Env:VOLVO_PASSWORD
```

### Probes Sitrack

```powershell
cd "C:\Users\Colo Logistica\coopertrans_movil"
$cred = Get-Credential -Message "Sitrack" -UserName "ws41629VecchiSRL"
$env:SITRACK_USERNAME = $cred.UserName
$env:SITRACK_PASSWORD = $cred.GetNetworkCredential().Password

# /v2/report — snapshot último estado de cada unidad (lo que ya consume
# `sitrackPosicionPoller`). El script enumera eventos distintos +
# campos ricos disponibles para Fase 1 ICM.
node scripts/sitrack_listar_eventos.js

# /files/reports — eventos acumulados desde la última invocación.
# ACTIVADO desde 2026-05-13 (probe confirmó 988 KB con eventos reales).
# El cron `sitrackEventosPoller` lo consume cada 5 min y persiste a
# SITRACK_EVENTOS. Este probe es para diagnóstico ad-hoc.
# OJO: cada llamada vacía el buffer del lado Sitrack — si lo corrés
# manual, perdés eventos hasta el próximo poll del cron.
node scripts/sitrack_probar_files_reports.js

# Análisis ranking + cobertura por categoría de los últimos N horas
# de SITRACK_EVENTOS. Ayuda a decidir qué consumidor armar primero
# (vigilador jornada v2 / auto-poblar viajes / anti-robo combustible /
# conducción peligrosa / fatiga MobileEye / mantenimiento / puertas).
# Requiere serviceAccountKey.json en la raíz.
node scripts/analizar_sitrack_eventos.js --horas 36

Remove-Item Env:SITRACK_USERNAME, Env:SITRACK_PASSWORD
```

### Diagnóstico vigilador de jornada por chofer

```powershell
# Lee JORNADAS_CHOFER + SITRACK_POSICIONES + flags de alerta del día.
# Equivalente a `/jornada DNI` por WhatsApp pero con más detalle.
node scripts/diagnosticar_vigilador_chofer.js <DNI>
```

---

## Contactos y secretos

> **Completar antes del primer handoff a un segundo operador o ante el primer incidente real**. Estos son los datos que un colaborador necesita para llamar a alguien que sepa. Los `⚠️ TODO` están explícitos para que cualquiera que abra esta sección sepa que hay info crítica faltando — completarlos a medida que estén disponibles.

### Personas

| Recurso | Dato |
|---|---|
| **Santiago** (dueño/dev/operador) | ⚠️ TODO: completar teléfono móvil + email personal de respaldo. Punto de contacto único hoy. Sacar del Bitwarden vault de Santiago cuando se complete. |
| **Contacto Vecchi** (cliente) | ⚠️ TODO: completar nombre + teléfono + email del responsable en Vecchi (la persona que reclama si el sistema cae). Pedirlo a Santiago la próxima vez que vea al cliente. |
| **Contacto técnico Volvo Connect** | ⚠️ TODO: completar email del contacto que ayuda si la API se cae o pierde permisos. Buscar en el portal de Volvo Connect → soporte / contacto del distribuidor local. |

### Servicios

| Recurso | Dato |
|---|---|
| **Bitwarden vault** | Cuenta personal de Santiago. Tiene: Volvo Connect (user `018B1E992E` + password v2 vigente), Google/Firebase/GCP (`santiagocoopertrans@gmail.com`), GitHub (`rodriguezreysantiago`), email principal, WhatsApp del bot. Master password en sobre cerrado en casa de Santiago + recovery code de 2FA en el mismo sobre. |
| **Firebase Console** | https://console.firebase.google.com/project/coopertrans-movil |
| **Google Cloud Console** | https://console.cloud.google.com/?project=coopertrans-movil — project number `808925655961`. |
| **GitHub** | https://github.com/rodriguezreysantiago/coopertrans_movil |
| **WhatsApp del bot** | ⚠️ TODO: completar número del celular descartable. Solo Santiago lo conoce hoy. Una vez completado, ese número va al campo de Bitwarden item "WhatsApp del bot" si todavía no está. |
| **`ADMIN_PHONES`** (whitelist comandos del bot) | En `whatsapp-bot/.env` de la PC oficina (instancia primaria) y PC casa (backup standby). NO en git por seguridad — duplicar a mano si se cambia. |

### Credenciales sensibles (NUNCA por chat / repo)

| Credencial | Dónde vive (autoridad) |
|---|---|
| `VOLVO_USERNAME` / `VOLVO_PASSWORD` | Secret Manager de GCP del proyecto coopertrans-movil. La copia maestra está acá. La copia de Bitwarden es para acceso humano (al portal Volvo). Rotación: ver `RUNBOOK.md` sección Sentry / Secrets (mismo flujo). |
| `serviceAccountKey.json` | Generar en Firebase Console → Project Settings → Service accounts → Generate new private key. NO commit. Copia local en cada PC con bot/scripts admin (no la del usuario común). |

---

## Cómo mantener este documento

- Si resolvés un incidente y **la solución no está acá**, agregala. La próxima persona se ahorra horas.
- Si una sección dice "TODO", es porque no la sabe nadie todavía — completala apenas la sepas.
- No mover esto a Notion ni a Drive. Vive en el repo para que `git blame` muestre quién cambió qué.
