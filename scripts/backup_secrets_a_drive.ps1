# =============================================================================
# Backup nocturno de secrets vivos de la PC dedicada al Drive
# =============================================================================
#
# Corre en la PC dedicada (Colo Logistica) como Scheduled Task. Sincroniza
# los archivos que cambian con el tiempo (sesión WhatsApp Web, claves
# rotadas, env vars actualizadas) al kit del Drive, así si la PC se muere
# mañana, el kit es de hace < 24h y la PC nueva levanta en 15 min sin
# pedir QR de WhatsApp ni claves obsoletas.
#
# Política multi-PC 2026-05-28 — corolario operativo del refactor de
# secrets en Drive.
#
# USO:
#   .\backup_secrets_a_drive.ps1                # corrida normal
#   .\backup_secrets_a_drive.ps1 -DryRun        # mostrar sin copiar
#   .\backup_secrets_a_drive.ps1 -InstalarTask  # registra Scheduled Task
#                                               # diaria a las 3 AM ART
#   .\backup_secrets_a_drive.ps1 -DesinstalarTask
#
# Para que funcione:
#   - Drive Desktop instalado en la PC dedicada bajo la misma cuenta
#     Google que monta G:\Mi unidad\ClaudeCodeSync\.
#   - El repo del bot/cachatore clonado en C:\coopertrans_movil\.

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$InstalarTask,
    [switch]$DesinstalarTask
)

$ErrorActionPreference = 'Stop'

# ─── Config ──────────────────────────────────────────────────────
$RepoRoot     = 'C:\coopertrans_movil'
$DriveRoot    = 'G:\Mi unidad\ClaudeCodeSync'

# Items a sincronizar: [origen, destino, descripcion]
# Cada entry es un objeto con Src, Dst y Label.
$Items = @(
    # Bot WhatsApp — kit completo en Drive (instalador all-in-one)
    @{
        Src   = "$RepoRoot\whatsapp-bot\.env"
        Dst   = "$DriveRoot\bot-pc-dedicada\.env"
        Label = 'bot .env'
    }
    @{
        Src   = "$RepoRoot\serviceAccountKey.json"
        Dst   = "$DriveRoot\bot-pc-dedicada\serviceAccountKey.json"
        Label = 'bot serviceAccountKey.json'
    }
    @{
        Src   = "$RepoRoot\whatsapp-bot\.wwebjs_auth"
        Dst   = "$DriveRoot\bot-pc-dedicada\.wwebjs_auth"
        Label = 'bot .wwebjs_auth (sesión WhatsApp)'
        IsDir = $true
    }
    # Cachatore — secrets que cambian (la PC vieja no tenía kit del cachatore)
    @{
        Src   = "$RepoRoot\cachatore\claves.json"
        Dst   = "$DriveRoot\secrets\cachatore\claves.json"
        Label = 'cachatore claves.json'
    }
    # serviceAccountKey general también para los scripts admin
    @{
        Src   = "$RepoRoot\serviceAccountKey.json"
        Dst   = "$DriveRoot\secrets\firebase\serviceAccountKey.json"
        Label = 'secrets/firebase/serviceAccountKey.json'
    }
)

# ─── Manejo de Scheduled Task ─────────────────────────────────────
$TaskName = 'CoopertransMovilBackupSecretsDrive'
$ScriptPath = "$RepoRoot\scripts\backup_secrets_a_drive.ps1"

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($InstalarTask) {
    if (-not (Test-Admin)) {
        Write-Host "ERROR: Necesita PowerShell como Administrador." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $ScriptPath)) {
        Write-Host "ERROR: No encuentro $ScriptPath" -ForegroundColor Red
        Write-Host "        ¿El repo está clonado en $RepoRoot?" -ForegroundColor Yellow
        exit 1
    }
    # Borrar si ya existía (idempotente)
    $existente = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existente) {
        Write-Host "  Borrando task existente..." -ForegroundColor DarkGray
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    $action = New-ScheduledTaskAction `
        -Execute 'PowerShell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At 3:00am
    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Backup nocturno de secrets vivos al kit del Drive (PC dedicada → G:\Mi unidad\ClaudeCodeSync\)'
    Write-Host "OK Scheduled Task '$TaskName' registrada (diaria 3:00 AM)." -ForegroundColor Green
    exit 0
}

if ($DesinstalarTask) {
    if (-not (Test-Admin)) {
        Write-Host "ERROR: Necesita PowerShell como Administrador." -ForegroundColor Red
        exit 1
    }
    $existente = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existente) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "OK Task '$TaskName' desinstalada." -ForegroundColor Green
    } else {
        Write-Host "  Task '$TaskName' no estaba instalada." -ForegroundColor DarkGray
    }
    exit 0
}

# ─── Ejecución normal (sync) ──────────────────────────────────────
Write-Host "[backup_secrets_a_drive] iniciando $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

if (-not (Test-Path $DriveRoot)) {
    Write-Host "ERROR: No encuentro el Drive en $DriveRoot" -ForegroundColor Red
    Write-Host "       Verificá que Google Drive Desktop esté instalado y" -ForegroundColor Yellow
    Write-Host "       sincronizando la cuenta correcta." -ForegroundColor Yellow
    exit 1
}

$copiados = 0
$skipped  = 0
$errores  = 0

foreach ($item in $Items) {
    $src = $item.Src
    $dst = $item.Dst
    $lbl = $item.Label
    $isDir = [bool]$item.IsDir

    if (-not (Test-Path $src)) {
        Write-Host "  - $lbl: ORIGEN NO EXISTE ($src)" -ForegroundColor Yellow
        $skipped++
        continue
    }

    # Si el destino existe y tiene mismo tamaño (para archivos) o
    # mismo número de items (para dirs), capaz no hace falta copiar.
    # Para simplicidad, copiamos siempre (los archivos son chicos y
    # .wwebjs_auth es lo único pesado — usamos robocopy con /MIR).
    try {
        if ($isDir) {
            if ($DryRun) {
                Write-Host "  [DRY] sync dir: $src → $dst" -ForegroundColor Cyan
            } else {
                # Crear destino si no existe
                if (-not (Test-Path $dst)) {
                    New-Item -ItemType Directory -Path $dst -Force | Out-Null
                }
                # robocopy /MIR mantiene el destino IDÉNTICO al origen
                # (borra del destino lo que no esté en origen, copia lo
                # nuevo). Es lo correcto para .wwebjs_auth donde la
                # sesión vieja se reemplaza por la nueva.
                $result = robocopy $src $dst /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:5
                # robocopy exit code: 0-7 = OK (sin errores reales), 8+ = error
                if ($LASTEXITCODE -ge 8) {
                    Write-Host "  - $lbl: robocopy exit $LASTEXITCODE" -ForegroundColor Red
                    $errores++
                    continue
                }
                Write-Host "  OK $lbl (dir)" -ForegroundColor Green
            }
        } else {
            if ($DryRun) {
                Write-Host "  [DRY] copy file: $src → $dst" -ForegroundColor Cyan
            } else {
                # Crear directorio del destino si no existe
                $dstDir = Split-Path $dst -Parent
                if (-not (Test-Path $dstDir)) {
                    New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
                }
                Copy-Item -Path $src -Destination $dst -Force
                Write-Host "  OK $lbl" -ForegroundColor Green
            }
        }
        $copiados++
    } catch {
        Write-Host "  - $lbl: ERROR — $($_.Exception.Message)" -ForegroundColor Red
        $errores++
    }
}

# ─── Marca de "última corrida exitosa" ────────────────────────────
# Útil para diagnóstico: si el kit del Drive tiene 30 días de viejo,
# este timestamp dice cuándo fue el último sync OK.
if (-not $DryRun -and $errores -eq 0) {
    $marker = "$DriveRoot\bot-pc-dedicada\ULTIMO_BACKUP.txt"
    $contenido = @"
Último backup OK: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
PC origen: $env:COMPUTERNAME ($env:USERNAME)
Items copiados: $copiados
"@
    Set-Content -Path $marker -Value $contenido -Encoding UTF8
}

Write-Host ""
Write-Host "[backup_secrets_a_drive] TOTAL: $copiados copiados, $skipped skipped, $errores errores"

if ($errores -gt 0) { exit 1 }
exit 0
