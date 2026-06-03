# =============================================================================
# Sincroniza el .env del bot WhatsApp DESDE el master del Drive hacia la
# dedicada. Corre EN LA PC DEDICADA (donde vive el bot + el Drive en G:).
# =============================================================================
#
# Por que existe: el .env NO esta en git (es secreto). El master vive en el
# Drive (lo edita Santiago desde cualquier PC) y la dedicada tiene que traerlo.
#
# SALVAGUARDA CLAVE (lo que casi tumba el bot el 2026-06-01): NUNCA pisar el
# .env de la dedicada con un BOT_PC_ID de otra PC. Si el master trae
# BOT_PC_ID=oficina (o cualquier otro), al reiniciar el bot ABORTA por el
# check anti-doble-bot (ve un heartbeat "fantasma" de la otra PC). Por eso
# este script SIEMPRE fuerza BOT_PC_ID=dedicada, sin importar que traiga el
# master.
#
# USO (PowerShell en la dedicada, desde C:\coopertrans_movil):
#   .\scripts\sync_env_desde_drive.ps1            # trae el .env (sin reiniciar)
#   .\scripts\sync_env_desde_drive.ps1 -Reiniciar # trae + reinicia el bot
#   .\scripts\sync_env_desde_drive.ps1 -DryRun    # muestra que haria, no toca
#
# Para que el bot TOME una key nueva (ej. GROQ_API_KEY) hay que reiniciar:
# corre con -Reiniciar, o reinicia el servicio a mano despues.
#
# NOTA encoding: ASCII puro a proposito (PowerShell 5.1 rompe UTF-8 sin BOM).
# El .env se LEE y ESCRIBE como UTF-8 sin BOM (lo que espera dotenv) via .NET,
# preservando acentos de los comentarios.

[CmdletBinding()]
param(
    [switch]$Reiniciar,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- Config (rutas reales de la dedicada) ----------------------------------
$Master   = 'G:\Mi unidad\ClaudeCodeSync\secrets\whatsapp-bot\.env'
$Destino  = 'C:\coopertrans_movil\whatsapp-bot\.env'
$PcId     = 'dedicada'
$Servicio = 'CoopertransMovilBot'

# --- 1. Verificaciones -----------------------------------------------------
if (-not (Test-Path -LiteralPath $Master)) {
    Write-Host "ERROR: no encuentro el master en:" -ForegroundColor Red
    Write-Host "       $Master" -ForegroundColor Red
    Write-Host "       Esta Google Drive sincronizado en G: en esta PC?" -ForegroundColor Yellow
    exit 1
}
$destDir = Split-Path -LiteralPath $Destino -Parent
if (-not (Test-Path -LiteralPath $destDir)) {
    Write-Host "ERROR: no existe $destDir (esta el bot clonado en C:\coopertrans_movil?)." -ForegroundColor Red
    exit 1
}

# --- 2. Leer el master (UTF-8 sin BOM) y FORZAR BOT_PC_ID=dedicada ----------
$utf8 = [System.Text.UTF8Encoding]::new($false)
$contenido = [System.IO.File]::ReadAllText($Master, $utf8)
$lineas = $contenido -split "`r?`n"

$vistoBotId = $false
$nuevo = foreach ($l in $lineas) {
    if ($l -match '^\s*BOT_PC_ID\s*=') {
        $vistoBotId = $true
        "BOT_PC_ID=$PcId"
    } else {
        $l
    }
}
if (-not $vistoBotId) { $nuevo += "BOT_PC_ID=$PcId" }

# Normalizar: una sola newline final, sin lineas en blanco de mas al final.
$nuevoTexto = (($nuevo -join "`n").TrimEnd("`n")) + "`n"

# --- 3. Idempotencia: si el destino ya es identico, no tocar ---------------
$actualTexto = ''
if (Test-Path -LiteralPath $Destino) {
    $actualTexto = [System.IO.File]::ReadAllText($Destino, $utf8)
}
if ($nuevoTexto -eq $actualTexto) {
    Write-Host "El .env ya esta sincronizado (sin cambios). Nada que hacer." -ForegroundColor DarkGray
    exit 0
}

if ($DryRun) {
    Write-Host "[DRY] Reemplazaria $Destino con el master del Drive" -ForegroundColor Cyan
    Write-Host "      (BOT_PC_ID forzado a '$PcId'). No se toco nada." -ForegroundColor Cyan
    exit 0
}

# --- 4. Backup del .env actual + escribir el nuevo (UTF-8 sin BOM) ---------
if (Test-Path -LiteralPath $Destino) {
    Copy-Item -LiteralPath $Destino -Destination "$Destino.bak" -Force
    Write-Host "Backup del .env actual -> $Destino.bak" -ForegroundColor DarkGray
}
[System.IO.File]::WriteAllText($Destino, $nuevoTexto, $utf8)
Write-Host "OK: .env actualizado desde el Drive (BOT_PC_ID=$PcId)." -ForegroundColor Green

# --- 5. Reinicio graceful del bot (opcional, para tomar la config nueva) ---
# NO usar Restart-Service: NSSM no espera el graceful shutdown del bot (~10-70s)
# y puede dejar .wwebjs_auth/ corrupto (pediria QR). Secuencia: Stop + esperar
# + Start (igual que auto_update.ps1).
if ($Reiniciar) {
    $svc = Get-Service -Name $Servicio -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "AVISO: el servicio $Servicio no existe en esta PC; no reinicio." -ForegroundColor Yellow
        Write-Host "       (Corre este script en la dedicada.)" -ForegroundColor Yellow
        exit 0
    }
    Write-Host "Stop-Service $Servicio (graceful, espera SIGINT + backup)..." -ForegroundColor Cyan
    Stop-Service -Name $Servicio
    Start-Sleep -Seconds 75
    if ((Get-Service -Name $Servicio).Status -ne 'Stopped') {
        Write-Host "Sigue corriendo tras 75s; forzando stop..." -ForegroundColor Yellow
        Stop-Service -Name $Servicio -Force
        Start-Sleep -Seconds 10
    }
    Start-Service -Name $Servicio
    Write-Host "OK: $Servicio reiniciado. Verifica con:" -ForegroundColor Green
    Write-Host "    node scripts\bot_estado_remoto.js --json" -ForegroundColor DarkGray
} else {
    Write-Host "NOTA: el bot sigue con la config vieja en memoria. Para tomar la" -ForegroundColor Yellow
    Write-Host "      nueva (ej. GROQ_API_KEY), volve a correr con -Reiniciar." -ForegroundColor Yellow
}
