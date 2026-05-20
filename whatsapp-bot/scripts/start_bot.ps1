# Arranca el bot WhatsApp (servicio NSSM 'CoopertransMovilBot') despues
# de sincronizar el codigo con git y refrescar dependencias npm.
#
# Pensado para el flujo de 2 PCs (casa + oficina): cada vez que llegas
# a una de las dos, corres este script y queda todo listo. La otra
# PC tiene que estar APAGADA o haber corrido stop_bot.ps1 antes
# (sino se procesan los mismos mensajes 2 veces y WhatsApp puede
# bannear el numero).
#
# Uso:
#   cd <ruta-al-repo>\whatsapp-bot
#   .\scripts\start_bot.ps1
#
# Que hace:
#   1. git pull en la raiz del repo (trae los ultimos cambios).
#   2. npm install --silent en whatsapp-bot/ (solo instala si cambio package.json).
#   3. Start-Service CoopertransMovilBot (con auto-elevacion UAC si hace falta).
#   4. Te dice donde ver los logs en vivo.

$ErrorActionPreference = 'Stop'
$serviceName = 'CoopertransMovilBot'

# Resolvemos paths desde el script para que funcione igual en
# cualquier PC, sin importar donde clonaste el repo.
$botRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $botRoot '..')).Path
$logsDir  = Join-Path $botRoot 'logs'

# Helpers de elevacion ----------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedServiceAction {
    param(
        [Parameter(Mandatory)] [string]$Action,
        [Parameter(Mandatory)] [string]$Name
    )
    if (Test-IsAdmin) {
        if ($Action -eq 'Start') { Start-Service -Name $Name -ErrorAction Stop }
        elseif ($Action -eq 'Stop') { Stop-Service -Name $Name -ErrorAction Stop }
        return $true
    }
    Write-Host "Necesito permisos de admin para tocar el servicio." -ForegroundColor Yellow
    Write-Host "Vas a ver un prompt de UAC -- aceptalo." -ForegroundColor Yellow
    $verb = if ($Action -eq 'Start') { 'Start-Service' } else { 'Stop-Service' }
    $arg = "$verb -Name '$Name' -ErrorAction Stop"
    try {
        $proc = Start-Process powershell -ArgumentList @('-NoProfile','-Command',$arg) `
            -Verb RunAs -Wait -PassThru -ErrorAction Stop
        return ($proc.ExitCode -eq 0)
    } catch {
        Write-Host "El usuario rechazo el prompt de UAC, o el servicio fallo." -ForegroundColor Red
        return $false
    }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "INICIANDO BOT - Coopertrans Movil" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# --- 1. Verificar que el servicio este instalado -------------------
$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "ERROR: el servicio '$serviceName' no esta instalado." -ForegroundColor Red
    Write-Host "Ejecuta primero (como administrador):" -ForegroundColor Yellow
    Write-Host "  .\scripts\instalar_servicio.ps1" -ForegroundColor Yellow
    exit 1
}

# --- 2. Verificar si ya esta corriendo -----------------------------
if ($svc.Status -eq 'Running') {
    Write-Host "El bot YA esta corriendo en esta PC." -ForegroundColor Yellow
    Write-Host "Si queres reiniciar (despues de un git pull con cambios), corre:" -ForegroundColor Yellow
    Write-Host "  Restart-Service $serviceName" -ForegroundColor Yellow
    exit 0
}

# --- 3. git pull en el repo ----------------------------------------
Write-Host "[1/3] Sincronizando con git pull..." -ForegroundColor Cyan
Push-Location $repoRoot
try {
    $dirty = git status --porcelain
    if ($dirty) {
        Write-Host "ADVERTENCIA: hay cambios sin commitear en el repo:" -ForegroundColor Yellow
        Write-Host $dirty -ForegroundColor Yellow
        Write-Host "Resolvelos (commit/stash) antes de seguir, o arranca el bot a mano con:" -ForegroundColor Yellow
        Write-Host "  Start-Service $serviceName" -ForegroundColor Yellow
        exit 1
    }
    git pull
    if ($LASTEXITCODE -ne 0) {
        Write-Host "git pull fallo. Revisa el error arriba." -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}

# --- 4. npm install en el bot --------------------------------------
Write-Host "[2/3] Refrescando dependencias del bot (npm install)..." -ForegroundColor Cyan
Push-Location $botRoot
try {
    npm install --silent
    if ($LASTEXITCODE -ne 0) {
        Write-Host "npm install fallo. Revisa el error arriba." -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}

# --- 5. Arrancar el servicio ---------------------------------------
Write-Host "[3/3] Arrancando servicio '$serviceName'..." -ForegroundColor Cyan
$ok = Invoke-ElevatedServiceAction -Action 'Start' -Name $serviceName
if (-not $ok) {
    Write-Host "No pude arrancar el servicio." -ForegroundColor Red
    Write-Host "Revisa los logs:" -ForegroundColor Yellow
    Write-Host "  Get-Content $logsDir\bot.err.log -Tail 50" -ForegroundColor Yellow
    exit 1
}
Start-Sleep -Seconds 3

$svc = Get-Service -Name $serviceName
if ($svc.Status -ne 'Running') {
    Write-Host "El servicio no llego a estado Running. Estado actual: $($svc.Status)" -ForegroundColor Red
    Write-Host "Revisa los logs:" -ForegroundColor Yellow
    Write-Host "  Get-Content $logsDir\bot.err.log -Tail 50" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "OK BOT CORRIENDO" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Para detener cuando termines de trabajar:" -ForegroundColor Cyan
Write-Host "  .\scripts\stop_bot.ps1   (o el icono 'Detener Bot WhatsApp')" -ForegroundColor White
Write-Host ""
Write-Host "RECORDATORIO: si tenes el bot tambien en otra PC, asegurate" -ForegroundColor Yellow
Write-Host "de que esa otra este APAGADA o el bot detenido alla." -ForegroundColor Yellow
Write-Host ""

# Abrir ventana con los logs en vivo usando monitor_logs.ps1 (visor v3):
# resiste la rotacion del log (no se "cuelga") y muestra ademas el auto-update.
# Antes usaba un Get-Content -Wait inline que quedaba zombie al rotar el log.
$verLogs = Join-Path $PSScriptRoot 'monitor_logs.ps1'
Write-Host "Abriendo ventana con los logs en vivo..." -ForegroundColor Cyan
try {
    Start-Process powershell -ArgumentList @(
        '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $verLogs
    ) -ErrorAction Stop | Out-Null
} catch {
    Write-Host "No pude abrir la ventana de logs. Abrila a mano:" -ForegroundColor Yellow
    Write-Host "  .\scripts\monitor_logs.ps1" -ForegroundColor Yellow
}
