# Detiene el cachatore (servicio NSSM 'cachatore-vigia'). Auto-eleva a admin.
# Pensado para el icono del escritorio de la dedicada.
#
#   .\detener_cachatore.ps1

$ErrorActionPreference = 'Stop'
$servicio = 'cachatore-vigia'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host ''
Write-Host '=== DETENER CACHATORE (turnos YPF) ===' -ForegroundColor Cyan

$svc = Get-Service -Name $servicio -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "El servicio '$servicio' no esta instalado en esta PC." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    exit 0
}
if ($svc.Status -ne 'Running') {
    Write-Host 'El cachatore ya estaba detenido.' -ForegroundColor Yellow
    Start-Sleep -Seconds 4
    exit 0
}

Write-Host "Deteniendo '$servicio'..." -ForegroundColor Cyan
if (Test-IsAdmin) {
    Stop-Service -Name $servicio -ErrorAction Stop
} else {
    Write-Host 'Pido permisos de admin (UAC)...' -ForegroundColor Yellow
    try {
        $p = Start-Process powershell -ArgumentList @(
            '-NoProfile', '-Command', "Stop-Service -Name '$servicio'"
        ) -Verb RunAs -Wait -PassThru -ErrorAction Stop
        if ($p.ExitCode -ne 0) { throw "exit $($p.ExitCode)" }
    } catch {
        Write-Host "No pude detener el servicio: $($_.Exception.Message)" -ForegroundColor Red
        Start-Sleep -Seconds 6
        exit 1
    }
}
Start-Sleep -Seconds 1
$svc = Get-Service -Name $servicio -ErrorAction SilentlyContinue
Write-Host "Estado: $($svc.Status)" -ForegroundColor Green
Start-Sleep -Seconds 3
