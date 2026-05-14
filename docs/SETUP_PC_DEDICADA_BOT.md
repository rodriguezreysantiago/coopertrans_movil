# PC dedicada al bot WhatsApp 24/7

Guía para mover el bot de WhatsApp a una **PC dedicada** que lo
mantenga corriendo 24 horas, 7 días, sin intervención manual.

> **Antes de arrancar:** mientras instales la PC nueva, **detené el bot
> en cualquier otra PC** donde lo tengas. Si arrancan dos bots en
> simultáneo procesan la misma cola de Firestore y mandan cada mensaje
> 2 veces — WhatsApp banea el número y perdés todo el setup.

---

## Hardware mínimo recomendado

- **Cualquier PC con Windows 10/11** sirve — no necesita ser potente.
- **8 GB RAM** (Chromium headless + Node usan ~1.5 GB).
- **20 GB libres** en disco (puppeteer baja Chrome ~150 MB + logs +
  margen para Windows Updates).
- **Ethernet** preferido sobre Wi-Fi (estabilidad).
- **UPS** recomendado: la sesión de WhatsApp Web tolera bien un
  corte (cuando vuelve la luz, el bot arranca solo y sigue con la
  sesión guardada en `.wwebjs_auth/`). El UPS es más por estabilidad
  general (evitar corrupción del disco / Windows) que por la sesión
  WA en sí. Si tenés cortes frecuentes, sí vale la pena.

---

## Setup paso a paso

### 1. Instalar Node.js + Git

- Node.js 18 LTS o superior: https://nodejs.org
- Git for Windows: https://git-scm.com/download/win

Después de instalar, abrir un PowerShell **nuevo** y verificar:

```powershell
node --version    # v18.x.x o superior
git --version
```

### 2. Clonar el repo

```powershell
cd C:\
git clone <URL_DEL_REPO> coopertrans_movil
cd coopertrans_movil\whatsapp-bot
npm install
```

`npm install` baja Chromium para puppeteer (~150 MB). Tarda
varios minutos la primera vez.

### 3. Copiar el `serviceAccountKey.json`

Este archivo no está en git (es secreto). Copiarlo desde tu PC actual
a `C:\coopertrans_movil\serviceAccountKey.json`.

### 4. Copiar el `.env` del bot

Igual que el service account, no está en git. Copiarlo a
`C:\coopertrans_movil\whatsapp-bot\.env`. Si arrancás de cero, partir
de `.env.example` y completar.

### 5. Primer arranque — escanear QR de WhatsApp (UNA SOLA VEZ)

> El QR se escanea **una sola vez**, igual que en tu PC actual donde
> escaneaste hace meses y nunca más. La sesión queda guardada y dura
> indefinidamente — el bot la reusa en cada arranque. Solo hay que
> reescanear si se rompe la PC, formateás el disco, o WhatsApp
> invalida la sesión (rarísimo).
>
> **Atajo recomendado**: en vez de reescanear desde cero, copiá la
> carpeta `.wwebjs_auth/` que ya tenés en tu PC actual a la PC
> dedicada. Eso evita el QR completamente. Ver "Migrar la sesión
> existente" más abajo.

Si arrancás de cero (sin sesión existente):

```powershell
cd C:\coopertrans_movil\whatsapp-bot
npm start
```

Va a aparecer un QR ASCII en consola. Desde el **celular descartable
de la oficina** (no tu celular personal), abrí WhatsApp →
**Ajustes → Dispositivos vinculados → Vincular un dispositivo** y
escaneá el QR. Cuando veas en consola algo como `WhatsApp listo para
enviar`, hacé `Ctrl+C` para detener.

A partir de acá la sesión queda cacheada en `.wwebjs_auth/` y el bot
la reusa en cada arranque (no hay que volver a escanear).

#### Migrar la sesión existente (recomendado si ya tenés bot corriendo)

En tu PC actual:

```powershell
Stop-Service CoopertransMovilBot   # importante: detener antes de copiar
```

Copiar la carpeta entera `whatsapp-bot\.wwebjs_auth\` de tu PC actual
a la PC dedicada (mismo path: `C:\coopertrans_movil\whatsapp-bot\.wwebjs_auth\`).
Podés usar pendrive, escritorio remoto, OneDrive, lo que sea más cómodo.

> **Importante**: una vez que arrancás el bot en la PC dedicada con esa
> sesión copiada, **NO** la vuelvas a arrancar en la PC vieja. Si dos
> PCs usan la misma sesión simultáneamente, WhatsApp Web detecta el
> conflicto y banea el dispositivo (= reescaneo + posible baneo del
> número).

### 6. Instalar como servicio Windows en modo 24/7

PowerShell **como Administrador**:

```powershell
cd C:\coopertrans_movil\whatsapp-bot
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\instalar_servicio.ps1 -Auto
```

El flag `-Auto` configura el servicio en modo **AUTOMATIC delayed**:
- Arranca solo al prender la PC (~2 min después del boot).
- Auto-restart si el proceso muere.
- Logs en `whatsapp-bot\logs\bot.out.log` y `bot.err.log` con rotación
  a 10 MB.

Al final el script arranca el servicio. Verificá:

```powershell
Get-Service CoopertransMovilBot
# Status: Running
```

### 7. Configurar Windows para 24/7

PowerShell **como Administrador**:

```powershell
cd C:\coopertrans_movil\whatsapp-bot
.\scripts\setup_pc_24x7.ps1
```

Esto setea:
- Power: nunca suspender, nunca apagar pantalla, no hibernar.
- Wake-on-LAN en Ethernet (si está disponible).
- Windows Update: solo reinicia entre 00:00 y 06:00.
- Boot menu: 5 seg de timeout.

### 8. Tareas manuales (no las hace el script)

Estas las tenés que hacer vos:

#### a. Antivirus — excluir carpetas del bot

Windows Defender (o el AV que tengas) a veces bloquea Chromium o
hace scan en vivo de los archivos del bot, ralentizando todo.
Excluir:

- `C:\coopertrans_movil\whatsapp-bot\` (toda la carpeta)
- `C:\Users\<TU_USER>\.cache\puppeteer\` (Chrome de puppeteer)

En Windows Defender:
> Settings → Update & Security → Windows Security → Virus & threat
> protection → Manage settings → Exclusions → Add or remove exclusions.

#### b. Auto-login (opcional)

Por seguridad, lo recomendado es que la PC pida login al arrancar.
El bot corre como **LocalSystem** y NO necesita ningún usuario
logueado para funcionar.

Si igualmente querés auto-login (ej. para poder ver el desktop
remotamente sin tener que ingresar password):

1. `Win+R` → escribir `netplwiz` → Enter.
2. Seleccionar tu usuario.
3. Desmarcar `Users must enter a user name and password to use this
   computer`.
4. Apply → ingresar password 2 veces → OK.

#### c. UPS (si tenés)

Configurar el software del UPS para que apague la PC con shutdown
controlado cuando la batería baje del 20%. Esto es por sanidad
general del SO/disco; la sesión de WhatsApp en sí tolera bien
apagones — el bot vuelve a arrancar y reusa la sesión guardada.

#### d. Acceso remoto

Si la PC va a estar en otro lugar, instalá:
- **TeamViewer** (más simple) o
- **AnyDesk** (más rápido) o
- **Windows Remote Desktop** (si tenés Windows Pro y red privada)

Necesario para mirar logs, reiniciar el bot, reescanear QR si la
sesión se cae.

### 9. Backup automático de la sesión WhatsApp (defensa-en-profundidad)

La sesión vive en `.wwebjs_auth/` y dura indefinidamente — no es algo
que se "caiga" en el día a día. **Pero** si en algún momento la PC se
rompe físicamente (disco quemado, robo, etc.) o formateás Windows,
perdés la carpeta y hay que reescanear desde el celular descartable.

El backup semanal a otra ubicación (Drive, NAS, otra PC) es
defensa-en-profundidad para ese caso:

PowerShell normal:

```powershell
# Editar el script si querés cambiar destino o frecuencia
Get-Content C:\coopertrans_movil\whatsapp-bot\scripts\backup_wwebjs_auth.ps1
```

Programar como tarea semanal:
1. Abrir `Task Scheduler`.
2. `Create Basic Task` → "Backup wwebjs_auth semanal".
3. Trigger: Weekly, domingo 03:00 AM.
4. Action: `Start a program`
   - Program: `powershell.exe`
   - Arguments: `-NoProfile -ExecutionPolicy Bypass -File "C:\coopertrans_movil\whatsapp-bot\scripts\backup_wwebjs_auth.ps1"`
5. Conditions: marcar `Wake the computer to run this task`.

### 10. Verificación final

Reiniciar la PC y comprobar que el bot arranca solo:

```powershell
Restart-Computer
# después del reboot, esperar 2 min y verificar:
Get-Service CoopertransMovilBot   # Status Running
Get-Content C:\coopertrans_movil\whatsapp-bot\logs\bot.out.log -Tail 30
```

Si ves `WhatsApp listo para enviar` en el log, está funcionando.

---

## Operación diaria

### Actualizar el bot a la última versión

Cuando se commitean cambios al código del bot (`whatsapp-bot/src/`)
o a las Cloud Functions, hay que actualizar la PC dedicada. Cada vez
que hagas un cambio importante:

```powershell
cd C:\coopertrans_movil
git pull
cd whatsapp-bot
npm install --silent
Restart-Service CoopertransMovilBot   # requiere admin
```

### Ver logs en vivo

```powershell
Get-Content C:\coopertrans_movil\whatsapp-bot\logs\bot.out.log -Tail 50 -Wait
```

### Detener temporalmente

```powershell
Stop-Service CoopertransMovilBot      # requiere admin
```

Para que NO arranque al próximo boot:

```powershell
Set-Service CoopertransMovilBot -StartupType Manual
```

### Reescanear QR (caso EXCEPCIONAL — si se cayó la sesión)

Esto **no pasa en el día a día**. La sesión dura indefinidamente
mientras el celular descartable mantenga el dispositivo vinculado y
la PC no se rompa. Solo hace falta reescanear cuando:

- Alguien desvincula manualmente el dispositivo desde el celular
  (Ajustes → Dispositivos vinculados → cerrar sesión).
- WhatsApp Web invalida la sesión por inactividad muy larga del
  celular principal (~14 días sin abrir WA en el cel).
- Se borró/corrompió la carpeta `.wwebjs_auth/` o se cambió de PC
  sin migrar la sesión.
- Update de WhatsApp/whatsapp-web.js incompatible (raro).

Si pasa:

1. `Stop-Service CoopertransMovilBot`
2. Borrar la carpeta `whatsapp-bot\.wwebjs_auth\` (perdés la sesión vieja).
3. Correr `npm start` desde consola normal (no como servicio) —
   aparece el QR.
4. Escanear desde el celular descartable.
5. Cuando veas `WhatsApp listo para enviar`, `Ctrl+C`.
6. `Start-Service CoopertransMovilBot` para volver al modo servicio.

---

## Revisar el bot remoto (sin entrar a la PC dedicada)

Hay 4 formas, de más rápida a más detallada:

### 1. Script CLI `bot_estado_remoto.js` (desde cualquier PC con el repo)

```powershell
cd C:\coopertrans_movil
node scripts\bot_estado_remoto.js
```

Muestra todo en una sola pantalla con colores:
- Estado: 🟢 vivo / 🟡 stale / 🔴 caído (basado en `ultimoHeartbeat`).
- PC donde corre + estado del cliente WA (LISTO/AUTH_FALLO/etc).
- Versión del bot + uptime + PID.
- Cola WhatsApp (pendientes / procesando / error).
- Mensajes enviados hoy + cuándo fue el último.
- Errores recientes (ring buffer de los últimos 10).
- Próximo ciclo del cron y stats del último.
- Eventos del watchdog (caídas/recuperaciones — últimas 20 por
  default, `--eventos 50` para más).
- Diagnóstico automático al final.

Flags:
- `--json` → output crudo del doc `BOT_HEALTH/main`, útil para
  pipelines o jq.
- `--eventos N` → cantidad de eventos del watchdog a mostrar.

### 2. Pantalla "Estado del Bot" en la app admin Flutter

La app móvil tiene una pantalla dedicada que lee el mismo
`BOT_HEALTH/main` y lo muestra visual. Lo más cómodo desde el celular.

### 3. WhatsApp directo al bot — comandos admin

Desde tu WhatsApp (admin):
- `/estado` → resumen corto de la cola y estado del bot.
- `/ayuda` → lista completa de comandos.

### 4. RDP / TeamViewer / AnyDesk (acceso visual completo)

Para casos que requieren ver los logs en vivo o tocar algo del SO
(reescaneo de QR, restart manual, mirar `bot.err.log`):

```powershell
# Ya conectado por escritorio remoto a la PC dedicada:
Get-Content C:\coopertrans_movil\whatsapp-bot\logs\bot.out.log -Tail 50 -Wait
Get-Content C:\coopertrans_movil\whatsapp-bot\logs\bot.err.log -Tail 50 -Wait
Restart-Service CoopertransMovilBot   # como admin
```

---

## Alertas automáticas

No es necesario que vos chequees activamente — el sistema te avisa
solo cuando algo se rompe:

### Watchdog de caídas (`botHealthWatchdog`, Cloud Function)

Corre cada 15 min y compara `BOT_HEALTH/main.ultimoHeartbeat` con
ahora. Si pasaron > 10 min sin heartbeat, registra un evento `caida`
en `BOT_EVENTOS`. Cuando el bot vuelve, registra `recuperado` con
la duración total.

**Cambio 2026-05-08**: las caídas/recuperaciones ya NO mandan WhatsApp
inmediato (quedaba viejo rápido — ej. caída a las 15:38, aviso a
las 18:10 cuando ya recuperó hace rato). Se acumulan y van en el
resumen diario.

### Resumen diario del bot (`resumenBotDiario`, Cloud Function)

Te llega WhatsApp a las 8 AM con las caídas/recuperaciones del día
anterior si las hubo. Si el bot estuvo 100% del tiempo arriba, no
se envía nada (silencio = todo bien).

### Alerta de cola creciente (desde el mismo bot, `health.js`)

Si la cola pendiente queda arriba de **50 mensajes por > 30 min
seguidos**, el bot encola una alerta WhatsApp al admin
(`COLA_CRECIENTE_ALERT_DNI` en `.env` del bot). Esto detecta el
caso "bot vivo pero procesando muy lento" — que el watchdog basado
en heartbeat no captura.

---

## Troubleshooting

### El servicio no arranca después del boot

Mirá el log de errores:

```powershell
Get-Content C:\coopertrans_movil\whatsapp-bot\logs\bot.err.log -Tail 80
```

Causas comunes:
- **Chromium no encontrado**: borrar `.wwebjs_cache\` y reinstalar
  con `npm install` (descarga Chrome de nuevo).
- **Sesión WhatsApp invalidada** (raro): reescanear QR (paso de
  arriba). Si pasa repetidamente, revisar si hay otro dispositivo
  usando la misma cuenta o si el celular descartable está apagado
  hace mucho.
- **Sin internet al arrancar**: el delayed start (2 min post-boot)
  ayuda, pero si tu red tarda más, considerá agregar un sleep al
  arranque.
- **Permisos**: si el servicio falla con `EACCES`, re-correr
  `instalar_servicio.ps1 -Auto` que reotorga ACLs a LocalSystem.

### Mensajes duplicados a los choferes

= Hay dos bots corriendo simultáneamente. Detener uno:

```powershell
# En la PC vieja:
Stop-Service CoopertransMovilBot
Set-Service CoopertransMovilBot -StartupType Manual   # para que no vuelva al boot
```

### El bot está corriendo pero no envía nada

1. Verificar que la cuenta de WhatsApp del bot **no esté baneada**
   abriendo WhatsApp Web manualmente desde otro browser con esa
   cuenta. Si te tira "número bloqueado", perdiste el número.
2. Verificar que el `.env` tenga `BOT_DRY_RUN=false` (no estaba en
   modo prueba).
3. Verificar la cola en Firestore: ¿hay docs en `COLA_WHATSAPP` con
   `estado=PENDIENTE`? Si todos están en `ERROR` o `ENVIADO`, no hay
   nada que enviar.

---

## Volviendo al modo multi-PC

Si en algún momento querés volver al setup viejo (bot manual en
varias PCs), desde la PC dedicada:

```powershell
Stop-Service CoopertransMovilBot
Set-Service CoopertransMovilBot -StartupType Manual
```

O directamente desinstalar el servicio:

```powershell
& 'C:\nssm\nssm.exe' remove CoopertransMovilBot confirm
```
