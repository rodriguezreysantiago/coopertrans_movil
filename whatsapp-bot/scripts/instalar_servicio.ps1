# Instala el bot como servicio Windows con NSSM. Soporta dos modos:
#
#   - MANUAL (default): vos lo arrancas con start_bot.ps1, no en el
#     boot. Ideal cuando trabajas en 2 PCs distintas (casa + oficina)
#     y queres evitar que se ejecuten 2 bots en simultaneo procesando
#     la misma cola de Firestore.
#
#   - AUTO-START 24/7 (flag `-Auto`): arranca solo al boot, ideal
#     para una PC dedicada al bot 24/7. En este modo:
#       * Service Start = AUTOMATIC (delayed)
#       * Servicio prendido al final de la instalacion
#       * Aviso para correr setup_pc_24x7.ps1 (power settings, etc.)
#     Si vas a usar este modo, ASEGURATE de que NINGUNA otra PC
#     tenga el bot corriendo — sino se duplican mensajes y WhatsApp
#     banea el numero.
#
# Otras props comunes a ambos modos:
#
#   - Auto-restart con backoff si el proceso muere (mientras este
#     arrancado).
#
#   - Logs persistentes en carpeta `logs/` del bot, con rotacion a 10MB.
#
#   - Corre como LocalSystem (cuenta de servicio default de Windows).
#     Para que LocalSystem pueda leer/escribir los archivos del bot
#     (que viven en C:\Users\<vos>\), el script da permisos full
#     control sobre la carpeta del repo y sobre la cache de puppeteer.
#     Tambien setea PUPPETEER_CACHE_DIR para que puppeteer encuentre
#     el Chromium descargado por tu user (LocalSystem por default
#     buscaria en C:\WINDOWS\system32\config\systemprofile\.cache\
#     que esta vacio).
#
# Requiere ejecutar como Administrador.
#
# Uso:
#   1. Click derecho en PowerShell -> "Ejecutar como administrador".
#   2. Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   3. cd <ruta-al-repo>\whatsapp-bot
#   4. .\scripts\instalar_servicio.ps1            # modo MANUAL (multi-PC)
#      .\scripts\instalar_servicio.ps1 -Auto      # modo AUTO 24/7
#
# Para arrancar/detener despues de instalado (modo MANUAL):
#   .\scripts\start_bot.ps1
#   .\scripts\stop_bot.ps1
#
# Para desinstalar:
#   nssm stop CoopertransMovilBot
#   nssm remove CoopertransMovilBot confirm

[CmdletBinding()]
param(
    # Si se pasa, instala el servicio en modo AUTOMATIC delayed-start
    # y lo arranca al final. Pensado para PC dedicada al bot 24/7.
    [switch]$Auto
)

$ErrorActionPreference = 'Stop'

# --- 1. Variables --------------------------------------------------
$serviceName = 'CoopertransMovilBot'
# El root del bot lo derivamos de la ubicacion de ESTE script para que
# funcione igual en casa y en la oficina (no hardcodeamos un path
# absoluto a un usuario especifico de Windows). El script vive en
# `whatsapp-bot/scripts/`, asi que el root es dos niveles arriba.
$botRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot    = (Resolve-Path (Join-Path $botRoot '..')).Path
$logsDir     = Join-Path $botRoot 'logs'
$nssmDir     = 'C:\nssm'
$nssmExe     = Join-Path $nssmDir 'nssm.exe'

# Cache de puppeteer (donde el primer `node src/index.js` o npm
# install descargo Chrome). Default: $env:USERPROFILE\.cache\puppeteer
# Si en tu PC esta en otro lado, cambialo aca antes de correr.
$puppeteerCache = Join-Path $env:USERPROFILE '.cache\puppeteer'

# --- 2. Verificar permisos de admin --------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR Este script necesita ejecutarse como Administrador." -ForegroundColor Red
    Write-Host "Cerra esta ventana, abri PowerShell con click derecho -> 'Ejecutar como administrador' y reintenta." -ForegroundColor Yellow
    exit 1
}

# --- 3. Instalar NSSM si no esta -----------------------------------
if (-not (Test-Path $nssmExe)) {
    Write-Host "[DL] NSSM no esta instalado. Bajando..." -ForegroundColor Cyan
    $nssmZip = "$env:TEMP\nssm.zip"
    $nssmUrl = 'https://nssm.cc/release/nssm-2.24.zip'

    Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip -UseBasicParsing
    Expand-Archive -Path $nssmZip -DestinationPath "$env:TEMP\nssm-extract" -Force

    $nssm64 = Get-ChildItem "$env:TEMP\nssm-extract" -Recurse `
        -Filter 'nssm.exe' | Where-Object { $_.DirectoryName -match 'win64' } |
        Select-Object -First 1

    if (-not $nssm64) {
        throw "No encontre nssm.exe (64-bit) en el zip descargado."
    }

    New-Item -ItemType Directory -Force -Path $nssmDir | Out-Null
    Copy-Item $nssm64.FullName $nssmExe -Force

    Remove-Item $nssmZip -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\nssm-extract" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "OK NSSM instalado en $nssmExe" -ForegroundColor Green
} else {
    Write-Host "OK NSSM ya estaba instalado." -ForegroundColor Green
}

# --- 4. Verificar Node.js ------------------------------------------
$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) {
    throw "Node.js no esta en el PATH. Instala desde https://nodejs.org/ y reabri PowerShell."
}
Write-Host "OK Node.js encontrado: $nodeExe" -ForegroundColor Green

# --- 5. Verificar que Chromium de puppeteer este descargado --------
# Si no esta, recordamos que hay que correr `node src/index.js` una
# vez como tu user para que puppeteer baje Chrome. Sin Chrome, el
# bot crashea al arrancar el servicio.
if (-not (Test-Path $puppeteerCache)) {
    Write-Host "" -ForegroundColor Yellow
    Write-Host "AVISO: no encontre Chromium de puppeteer en $puppeteerCache" -ForegroundColor Yellow
    Write-Host "Despues de instalar el servicio, corre UNA VEZ:" -ForegroundColor Yellow
    Write-Host "  cd $botRoot" -ForegroundColor Yellow
    Write-Host "  npm install" -ForegroundColor Yellow
    Write-Host "  node src/index.js   # solo para que puppeteer baje Chrome y autenticar QR de WA" -ForegroundColor Yellow
    Write-Host "  Ctrl+C cuando llegue a 'WhatsApp listo para enviar.'" -ForegroundColor Yellow
    Write-Host "Despues podes arrancar el servicio con start_bot.ps1." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
}

# --- 6. Crear carpeta de logs --------------------------------------
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

# --- 7. Detener y borrar el servicio si ya existia -----------------
$existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "WARN  Servicio '$serviceName' ya existe. Lo voy a recrear..." -ForegroundColor Yellow
    & $nssmExe stop $serviceName confirm 2>&1 | Out-Null
    & $nssmExe remove $serviceName confirm 2>&1 | Out-Null
    Start-Sleep -Seconds 2
}

# --- 8. Instalar el servicio ---------------------------------------
Write-Host "[PKG] Creando servicio Windows '$serviceName'..." -ForegroundColor Cyan

& $nssmExe install $serviceName $nodeExe 'src\index.js' | Out-Null
& $nssmExe set $serviceName AppDirectory $botRoot | Out-Null

# Logs separados para stdout y stderr.
& $nssmExe set $serviceName AppStdout (Join-Path $logsDir 'bot.out.log') | Out-Null
& $nssmExe set $serviceName AppStderr (Join-Path $logsDir 'bot.err.log') | Out-Null

# Rotacion de logs: cuando un log llega a 10 MB, lo rotamos.
& $nssmExe set $serviceName AppRotateFiles 1 | Out-Null
& $nssmExe set $serviceName AppRotateOnline 1 | Out-Null
& $nssmExe set $serviceName AppRotateBytes 10485760 | Out-Null  # 10 MB

# Auto-restart: si el proceso termina con cualquier codigo, reintentar.
& $nssmExe set $serviceName AppExit Default Restart | Out-Null
& $nssmExe set $serviceName AppRestartDelay 10000 | Out-Null
& $nssmExe set $serviceName AppThrottle 60000 | Out-Null

# Modo de inicio: depende del flag.
#   - Sin -Auto (default): MANUAL. El servicio NO arranca al boot;
#     vos lo encendes con start_bot.ps1 cuando empezas a trabajar.
#     Pensado para multi-PC (casa + oficina).
#   - Con -Auto: AUTOMATIC delayed-start. El servicio arranca solo
#     ~2 min despues del boot (delay para que red y cache puppeteer
#     esten listos). Pensado para PC dedicada al bot 24/7.
if ($Auto) {
    & $nssmExe set $serviceName Start SERVICE_AUTO_START | Out-Null
    # Delayed-auto-start: NSSM expone esto via la propiedad nativa
    # "DelayedAutoStart" del Service Control Manager.
    & $nssmExe set $serviceName DelayedAutoStart 1 | Out-Null
    Write-Host "OK Servicio en modo AUTOMATIC (delayed) — arranca al boot." -ForegroundColor Green
} else {
    & $nssmExe set $serviceName Start SERVICE_DEMAND_START | Out-Null
}

# Variables de entorno para el bot. PUPPETEER_CACHE_DIR es CRITICO:
# cuando el servicio corre como LocalSystem, su HOME es
# C:\WINDOWS\system32\config\systemprofile\ y puppeteer busca
# Chromium ahi. Lo redirigimos a la cache que ya tiene tu user.
& $nssmExe set $serviceName AppEnvironmentExtra "PUPPETEER_CACHE_DIR=$puppeteerCache" | Out-Null

# Descripcion visible en services.msc.
& $nssmExe set $serviceName DisplayName 'Coopertrans Movil - Bot WhatsApp' | Out-Null
& $nssmExe set $serviceName Description 'Bot Node.js que procesa la cola COLA_WHATSAPP de Firestore y envia avisos automaticos por WhatsApp Web. Modo MANUAL: usar start_bot.ps1 para encenderlo.' | Out-Null

Write-Host "OK Servicio '$serviceName' creado (modo MANUAL)." -ForegroundColor Green

# --- 9. Permisos para LocalSystem ----------------------------------
# Por default Windows protege C:\Users\<user>\ asi que solo el user
# puede leer. Cuando el servicio corre como LocalSystem (la cuenta
# default de NSSM), no puede acceder a los archivos del bot ni a la
# cache de puppeteer. Le damos full control sobre las dos carpetas
# que necesita.
Write-Host "[ACL] Otorgando permisos a LocalSystem sobre carpetas del bot..." -ForegroundColor Cyan

# Repo entero (necesita leer src/, node_modules/, .env, y escribir
# logs/, .wwebjs_auth/, .wwebjs_cache/).
icacls $repoRoot /grant 'NT AUTHORITY\SYSTEM:(OI)(CI)F' /T /C 2>&1 | Out-Null
Write-Host "  OK $repoRoot" -ForegroundColor DarkGray

# Cache de puppeteer (Chromium descargado).
if (Test-Path $puppeteerCache) {
    icacls $puppeteerCache /grant 'NT AUTHORITY\SYSTEM:(OI)(CI)F' /T /C 2>&1 | Out-Null
    Write-Host "  OK $puppeteerCache" -ForegroundColor DarkGray
} else {
    Write-Host "  SKIP $puppeteerCache (todavia no existe; correr node src/index.js una vez)" -ForegroundColor Yellow
}

# --- 10. Si modo AUTO, arrancar el servicio ya ---------------------
if ($Auto) {
    Write-Host "[BOOT] Arrancando servicio (modo AUTO)..." -ForegroundColor Cyan
    try {
        Start-Service -Name $serviceName -ErrorAction Stop
        Start-Sleep -Seconds 3
    } catch {
        Write-Host "WARN: no pude arrancar el servicio. Probablemente puppeteer todavia no bajo Chrome o falta el QR." -ForegroundColor Yellow
        Write-Host "       Revisa los logs: Get-Content $logsDir\bot.err.log -Tail 50" -ForegroundColor Yellow
    }
}

# --- 11. Resumen ---------------------------------------------------
$svc = Get-Service -Name $serviceName
$modoStr = if ($Auto) { 'AUTOMATIC (delayed) — 24/7' } else { 'MANUAL — multi-PC' }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "INSTALACION COMPLETA" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Servicio:           $serviceName"
Write-Host "Modo:               $modoStr"
Write-Host "Estado:             $($svc.Status)"
Write-Host "Cuenta:             LocalSystem"
Write-Host "Ejecutable:         $nodeExe src\index.js"
Write-Host "Working dir:        $botRoot"
Write-Host "Logs:               $logsDir"
Write-Host "PUPPETEER_CACHE_DIR: $puppeteerCache"
Write-Host ""
Write-Host "Comandos NSSM utiles:" -ForegroundColor Yellow
Write-Host "  Ver estado:           Get-Service $serviceName"
Write-Host "  Arrancar:             Start-Service $serviceName"
Write-Host "  Detener:              Stop-Service $serviceName"
Write-Host "  Reiniciar:            Restart-Service $serviceName"
Write-Host "  Editar config (GUI):  & '$nssmExe' edit $serviceName"
Write-Host "  Ver log en vivo:      Get-Content $logsDir\bot.out.log -Tail 50 -Wait"
Write-Host "  Ver errores:          Get-Content $logsDir\bot.err.log -Tail 50 -Wait"
Write-Host "  Desinstalar:          & '$nssmExe' remove $serviceName confirm"
Write-Host ""
if ($Auto) {
    Write-Host "MODO 24/7 ACTIVO." -ForegroundColor Green
    Write-Host "  - El servicio arranca SOLO al prender la PC." -ForegroundColor Green
    Write-Host "  - ASEGURATE de NO tener el bot corriendo en NINGUNA otra PC" -ForegroundColor Yellow
    Write-Host "    (si hay 2 instancias, se duplican mensajes y WhatsApp banea)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Pasos siguientes para PC dedicada:" -ForegroundColor Cyan
    Write-Host "  1. Configurar Windows para no suspender (power settings):" -ForegroundColor Cyan
    Write-Host "       .\scripts\setup_pc_24x7.ps1" -ForegroundColor White
    Write-Host "  2. Leer la guia completa: docs\SETUP_PC_DEDICADA_BOT.md" -ForegroundColor Cyan
} else {
    Write-Host "IMPORTANTE: el servicio quedo en MODO MANUAL." -ForegroundColor Cyan
    Write-Host "  - NO arranca solo al prender la PC." -ForegroundColor Cyan
    Write-Host "  - Tenes que prenderlo vos con start_bot.ps1 cuando empieces a trabajar." -ForegroundColor Cyan
    Write-Host "  - Esto evita que arranquen 2 bots a la vez si tenes el repo en varias PCs." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Para empezar a usar el bot:" -ForegroundColor Yellow
    Write-Host "  cd $botRoot"
    Write-Host "  .\scripts\start_bot.ps1"
}
