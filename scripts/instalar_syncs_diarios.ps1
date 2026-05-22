# Registra las 2 Scheduled Tasks diarias de los scrapers en la PC dedicada:
#   - CoopertransSyncVolvoTaller  (05:10) -> service/taller de Volvo Connect
#   - CoopertransSyncSitrackIcm   (06:10) -> ICM oficial de Sitrack
#
# Correr UNA VEZ en la PC dedicada, PowerShell COMO ADMINISTRADOR.
# Las tareas corren como el USUARIO logueado (el del auto-login), NO como
# SYSTEM: asi Playwright/chromium usan el entorno y el cache del usuario
# (evita los problemas de chromium headless bajo SYSTEM). RunLevel Highest.
#
# Prerequisitos (ver docs/SCRAPERS_DEDICADA.md): venv en C:\coopertrans_movil\
# sync_venv con playwright + firebase-admin + chromium, claves.json de cada
# scraper, y serviceAccountKey.json en la raiz del repo.
#
# Uso:
#   .\instalar_syncs_diarios.ps1            # instala/actualiza las 2 tareas
#   .\instalar_syncs_diarios.ps1 -Remove    # desinstala las 2 tareas

[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'Stop'

$RepoRoot = 'C:\coopertrans_movil'
$Runner   = Join-Path $RepoRoot 'scripts\correr_sync_diario.ps1'

$tasks = @(
    @{ Name = 'CoopertransSyncVolvoTaller'; Sync = 'volvo';   At = '05:10';
       Desc = 'Sync diario Volvo Connect -> service/taller (VEHICULOS, VEHICULOS_TALLER)' }
    @{ Name = 'CoopertransSyncSitrackIcm';  Sync = 'sitrack'; At = '06:10';
       Desc = 'Sync diario ICM oficial de Sitrack -> ICM_OFICIAL' }
)

# --- Admin? ---------------------------------------------------------
$principalCheck = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Corre esta consola COMO ADMINISTRADOR." -ForegroundColor Red
    exit 1
}

# --- Modo desinstalar ----------------------------------------------
if ($Remove) {
    foreach ($t in $tasks) {
        $ex = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($ex) {
            Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false
            Write-Host "OK: '$($t.Name)' eliminada." -ForegroundColor Green
        } else {
            Write-Host "INFO: '$($t.Name)' no estaba instalada." -ForegroundColor Gray
        }
    }
    exit 0
}

# --- Pre-checks -----------------------------------------------------
if (-not (Test-Path $Runner)) {
    Write-Host "ERROR: No existe $Runner (corre git pull en $RepoRoot primero)." -ForegroundColor Red
    exit 1
}
$venvPy = Join-Path $RepoRoot 'sync_venv\Scripts\python.exe'
if (-not (Test-Path $venvPy)) {
    Write-Host "AVISO: falta el venv $venvPy. Ver docs/SCRAPERS_DEDICADA.md (las tareas fallaran sin el)." -ForegroundColor Yellow
}
foreach ($c in @('volvo_sync\claves.json', 'sitrack_sync\claves.json')) {
    if (-not (Test-Path (Join-Path $RepoRoot $c))) {
        Write-Host "AVISO: falta $c (la tarea correspondiente fallara sin credenciales)." -ForegroundColor Yellow
    }
}

# Usuario interactivo actual (el del auto-login). Las tareas corren como el,
# 'solo cuando esta logueado' -> con auto-login esta logueado 24/7.
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -RestartCount 0 `
    -MultipleInstances IgnoreNew
# Prioridad de CPU NORMAL (5). Por defecto las Scheduled Tasks corren en 7
# (below-normal) -> el chromium de Playwright queda hambreado compitiendo con
# el Chrome del bot (prioridad normal) y las paginas no cargan a tiempo
# (timeouts de 35s/unidad en Volvo). Con 5 compite parejo. (Confirmado el
# 2026-05-22: a mano andaba, por tarea timeouteaba.)
$settings.Priority = 5

foreach ($t in $tasks) {
    $existing = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "INFO: '$($t.Name)' ya existia, la actualizo." -ForegroundColor Gray
        Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false
    }
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
                   "-File `"$Runner`" -Sync $($t.Sync)")
    $trigger = New-ScheduledTaskTrigger -Daily -At $t.At
    Register-ScheduledTask `
        -TaskName $t.Name `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description $t.Desc | Out-Null
    Write-Host "OK: '$($t.Name)' instalada (diaria $($t.At))." -ForegroundColor Green
}

Write-Host ""
Write-Host "Usuario de las tareas: $userId (RunLevel Highest)" -ForegroundColor Gray
Write-Host "Verlas:       Get-ScheduledTask CoopertransSync*" -ForegroundColor Cyan
Write-Host "Correr ya:    Start-ScheduledTask -TaskName CoopertransSyncSitrackIcm" -ForegroundColor Cyan
Write-Host "Logs:         C:\coopertrans_movil\sitrack_sync\logs\sync_diario.log" -ForegroundColor Cyan
Write-Host "              C:\coopertrans_movil\volvo_sync\logs\sync_diario.log" -ForegroundColor Cyan
Write-Host "Desinstalar:  .\instalar_syncs_diarios.ps1 -Remove" -ForegroundColor Cyan
