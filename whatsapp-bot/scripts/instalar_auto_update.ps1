# Instala la Scheduled Task que hace auto-update del bot desde git
# cada N minutos. Diseñado para correr UNA VEZ en la PC dedicada del bot.
#
# Requiere PowerShell como Administrador (Register-ScheduledTask con
# usuario SYSTEM y RunLevel Highest).
#
# Uso:
#   .\instalar_auto_update.ps1                    # cada 5 min (default)
#   .\instalar_auto_update.ps1 -IntervalMinutes 10
#   .\instalar_auto_update.ps1 -Remove            # desinstala la task

[CmdletBinding()]
param(
    [int]$IntervalMinutes = 5,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$TaskName = 'CoopertransMovilBotAutoUpdate'
$ScriptPath = 'C:\coopertrans_movil\whatsapp-bot\scripts\auto_update.ps1'

# ─── Verificar admin ────────────────────────────────────────────────
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Este script necesita PowerShell como Administrador." -ForegroundColor Red
    Write-Host "       Cerralo y reabri PowerShell con click derecho -> 'Ejecutar como administrador'." -ForegroundColor Yellow
    exit 1
}

# ─── Modo desinstalar ───────────────────────────────────────────────
if ($Remove) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "OK: Scheduled Task '$TaskName' eliminada." -ForegroundColor Green
    } else {
        Write-Host "INFO: La task '$TaskName' no estaba instalada." -ForegroundColor Gray
    }
    exit 0
}

# ─── Pre-checks ─────────────────────────────────────────────────────
if (-not (Test-Path $ScriptPath)) {
    Write-Host "ERROR: No existe $ScriptPath" -ForegroundColor Red
    Write-Host "       Ejecutar git pull en C:\coopertrans_movil primero." -ForegroundColor Yellow
    exit 1
}

# Si ya existe, desregistrarla primero (asi se puede re-correr para cambiar interval)
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "INFO: Task ya existia, la actualizo." -ForegroundColor Gray
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# ─── Crear la task ──────────────────────────────────────────────────
$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

# Trigger 1: al boot, esperando 3 min para que el servicio del bot ya este levantado
$triggerBoot = New-ScheduledTaskTrigger -AtStartup
$triggerBoot.Delay = 'PT3M'

# Trigger 2: cada N minutos, sin fecha de fin
$triggerPoll = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
    -RestartCount 0 `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger @($triggerBoot, $triggerPoll) `
    -Principal $principal `
    -Settings $settings `
    -Description "Auto-update del bot WhatsApp desde git cada $IntervalMinutes min" | Out-Null

Write-Host ""
Write-Host "OK: Scheduled Task '$TaskName' instalada." -ForegroundColor Green
Write-Host "    Intervalo:  cada $IntervalMinutes min" -ForegroundColor Gray
Write-Host "    Script:     $ScriptPath" -ForegroundColor Gray
Write-Host "    Usuario:    SYSTEM (RunLevel Highest)" -ForegroundColor Gray
Write-Host "    Log:        C:\coopertrans_movil\whatsapp-bot\logs\auto_update.log" -ForegroundColor Gray
Write-Host ""
Write-Host "Para verla:        Get-ScheduledTask -TaskName $TaskName" -ForegroundColor Cyan
Write-Host "Para correr ya:    Start-ScheduledTask -TaskName $TaskName" -ForegroundColor Cyan
Write-Host "Para desinstalar:  .\instalar_auto_update.ps1 -Remove" -ForegroundColor Cyan
Write-Host ""
Write-Host "Test rapido (corre el script en primer plano):" -ForegroundColor Yellow
Write-Host "  & '$ScriptPath'" -ForegroundColor Gray
Write-Host "  Get-Content C:\coopertrans_movil\whatsapp-bot\logs\auto_update.log -Tail 20" -ForegroundColor Gray
