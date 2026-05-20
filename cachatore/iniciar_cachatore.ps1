# Inicia el cachatore (servicio NSSM 'cachatore-vigia') y abre la ventana de
# logs en vivo (visor v3). Pensado para el icono del escritorio de la dedicada.
# Auto-eleva a admin (Start-Service lo necesita). NO hace git pull: de eso se
# encarga el auto-update (un pull a mano le rompe el auto-reinicio).
#
#   .\iniciar_cachatore.ps1

$ErrorActionPreference = 'Stop'
$servicio = 'cachatore-vigia'
$dir = $PSScriptRoot
$verLogs = Join-Path $dir 'ver_logs_vigia.ps1'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host ''
Write-Host '=== INICIAR CACHATORE (turnos YPF) ===' -ForegroundColor Cyan

$svc = Get-Service -Name $servicio -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "ERROR: el servicio '$servicio' no esta instalado." -ForegroundColor Red
    Write-Host 'Corre primero (como admin): cachatore\instalar_servicio_vigia.ps1' -ForegroundColor Yellow
    Start-Sleep -Seconds 6
    exit 1
}

if ($svc.Status -eq 'Running') {
    Write-Host 'El cachatore YA estaba corriendo.' -ForegroundColor Yellow
} else {
    Write-Host "Arrancando '$servicio'..." -ForegroundColor Cyan
    if (Test-IsAdmin) {
        Start-Service -Name $servicio -ErrorAction Stop
    } else {
        Write-Host 'Pido permisos de admin (UAC)...' -ForegroundColor Yellow
        try {
            $p = Start-Process powershell -ArgumentList @(
                '-NoProfile', '-Command', "Start-Service -Name '$servicio'"
            ) -Verb RunAs -Wait -PassThru -ErrorAction Stop
            if ($p.ExitCode -ne 0) { throw "exit $($p.ExitCode)" }
        } catch {
            Write-Host "No pude arrancar el servicio: $($_.Exception.Message)" -ForegroundColor Red
            Start-Sleep -Seconds 6
            exit 1
        }
    }
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name $servicio -ErrorAction SilentlyContinue
    Write-Host "Estado: $($svc.Status)" -ForegroundColor Green
}

# Abrir la ventana de logs en vivo (visor v3).
if (Test-Path $verLogs) {
    Write-Host 'Abriendo los logs en vivo...' -ForegroundColor Cyan
    Start-Process powershell -ArgumentList @(
        '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $verLogs
    ) | Out-Null
} else {
    Write-Host 'No encontre ver_logs_vigia.ps1 para abrir los logs.' -ForegroundColor Yellow
    Start-Sleep -Seconds 4
}
