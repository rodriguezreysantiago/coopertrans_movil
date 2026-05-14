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
- **UPS** muy recomendado: si la PC se apaga por corte de luz, perdés
  la sesión de WhatsApp Web y hay que reescanear QR desde el celular.

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

### 5. Primer arranque — escanear QR de WhatsApp

```powershell
cd C:\coopertrans_movil\whatsapp-bot
npm start
```

Va a aparecer un QR ASCII en consola. Desde el **celular descartable
de la oficina** (no tu celular personal), abrí WhatsApp →
**Ajustes → Dispositivos vinculados → Vincular un dispositivo** y
escaneá el QR. Cuando veas en consola algo como `WhatsApp listo para
enviar`, hacé `Ctrl+C` para detener.

A partir de acá la sesión queda cacheada en `.wwebjs_auth/` y NO
hace falta volver a escanear (salvo que el celular te desvincule el
dispositivo o pasen ~30 días sin actividad).

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
controlado cuando la batería baje del 20%. Si la PC se apaga sin
shutdown, podés perder la sesión de WhatsApp.

#### d. Acceso remoto

Si la PC va a estar en otro lugar, instalá:
- **TeamViewer** (más simple) o
- **AnyDesk** (más rápido) o
- **Windows Remote Desktop** (si tenés Windows Pro y red privada)

Necesario para mirar logs, reiniciar el bot, reescanear QR si la
sesión se cae.

### 9. Backup automático de la sesión WhatsApp

Si la PC se rompe, la sesión `.wwebjs_auth/` se va con ella y hay
que reescanear QR. Backup semanal a tu Drive:

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

### Reescanear QR (si se cayó la sesión)

1. `Stop-Service CoopertransMovilBot`
2. Borrar la carpeta `whatsapp-bot\.wwebjs_auth\` (perdés la sesión vieja).
3. Correr `npm start` desde consola normal (no como servicio) —
   aparece el QR.
4. Escanear desde el celular descartable.
5. Cuando veas `WhatsApp listo para enviar`, `Ctrl+C`.
6. `Start-Service CoopertransMovilBot` para volver al modo servicio.

---

## Monitoreo / detectar caídas

El bot escribe en `whatsapp-bot\logs\bot.out.log` cada vez que
procesa un mensaje. Si dejás de ver actividad por horas y hay
mensajes pendientes en la cola, algo se cayó.

**Heartbeat sugerido (no implementado todavía)**: agregar al bot un
write a `META/bot_heartbeat` cada 5 min con timestamp + versión, y
un cron de Cloud Functions que avise por WhatsApp al admin si no
hubo heartbeat en > 30 min. Es un trabajo de 1 hora — pendiente para
la próxima iteración.

Mientras tanto, alertas indirectas:
- Si llegan los avisos automáticos de jornada / vencimientos →
  bot funciona.
- Si pasan 24h sin avisos cuando deberían haberse enviado → bot caído.

---

## Troubleshooting

### El servicio no arranca después del boot

Mirá el log de errores:

```powershell
Get-Content C:\coopertrans_movil\whatsapp-bot\logs\bot.err.log -Tail 80
```

Causas comunes:
- **Sesión WhatsApp expiró**: reescanear QR (paso de arriba).
- **Chromium no encontrado**: borrar `.wwebjs_cache\` y reinstalar
  con `npm install` (descarga Chrome de nuevo).
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
