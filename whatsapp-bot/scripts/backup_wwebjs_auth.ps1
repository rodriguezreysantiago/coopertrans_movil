# Backup de la sesion .wwebjs_auth/ del bot.
#
# La sesion es el "estado autenticado" de WhatsApp Web. Si se pierde,
# hay que reescanear QR desde el celular descartable -- y ese tambien
# es SPOF. Este script comprime la carpeta a un zip con timestamp.
#
# Uso manual:
#   .\scripts\backup_wwebjs_auth.ps1
#
# Uso programado (Windows Task Scheduler):
#   1. Abrir Task Scheduler ("Programador de tareas").
#   2. Create Basic Task -> "Backup wwebjs_auth semanal".
#   3. Trigger: Weekly, dia y hora a eleccion (ej. domingo 03:00 AM).
#   4. Action: Start a program
#        Program: powershell.exe
#        Arguments:
#          -NoProfile -ExecutionPolicy Bypass -File
#          "C:\coopertrans_movil\whatsapp-bot\scripts\backup_wwebjs_auth.ps1"
#   5. Conditions: marcar "Wake the computer to run this task".
#
# Sale con exit 0 si OK, 1 si algo fallo. Loguea en
# whatsapp-bot/logs/backup.log para diagnostico (no se rota -- el
# script propio limpia entradas viejas al final).

$ErrorActionPreference = 'Stop'

# Path absoluto al repo (basado en la ubicacion del script).
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = Split-Path -Parent (Split-Path -Parent $scriptDir)
$srcDir    = Join-Path $repoRoot 'whatsapp-bot\.wwebjs_auth'

# Destino: por default %USERPROFILE%\Backups\bot. Override via env var.
$destDir = if ($env:BOT_BACKUP_DIR) {
    $env:BOT_BACKUP_DIR
} else {
    Join-Path $env:USERPROFILE 'Backups\bot'
}

# Retencion: cuantos dias mantener (default 60 = ~8 backups semanales).
$retencionDias = if ($env:BOT_BACKUP_RETENCION_DIAS) {
    [int]$env:BOT_BACKUP_RETENCION_DIAS
} else {
    60
}

$fecha    = Get-Date -Format 'yyyy-MM-dd_HHmm'
$destZip  = Join-Path $destDir "bot_wwebjs_auth_$fecha.zip"
$logFile  = Join-Path $repoRoot 'whatsapp-bot\logs\backup.log'

function Write-Log {
    param([string]$msg)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] $msg"
    Write-Host $line
    try {
        $logDir = Split-Path -Parent $logFile
        if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        Add-Content -Path $logFile -Value $line
    } catch {
        # No bloquear backup si el log no se puede escribir.
    }
}

try {
    Write-Log "Inicio backup .wwebjs_auth"

    if (-not (Test-Path $srcDir)) {
        Write-Log "ERROR: no existe $srcDir. El bot nunca arranco o la sesion fue borrada?"
        exit 1
    }

    if (-not (Test-Path $destDir)) {
        Write-Log "Creando dir destino $destDir"
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
    }

    # Compress-Archive a veces falla con archivos en uso (puppeteer
    # con la sesion activa puede tener locks en SingletonCookie).
    # Estrategia: copiar a temp primero, despues comprimir el temp.
    $tempCopy = Join-Path $env:TEMP "wwebjs_auth_backup_$fecha"
    Write-Log "Copiando a temp $tempCopy"
    Copy-Item -Path $srcDir -Destination $tempCopy -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log "Comprimiendo a $destZip"
    Compress-Archive -Path "$tempCopy\*" -DestinationPath $destZip -CompressionLevel Optimal

    # Limpiar temp.
    Remove-Item -Path $tempCopy -Recurse -Force -ErrorAction SilentlyContinue

    $sizeMb = [math]::Round((Get-Item $destZip).Length / 1MB, 2)
    Write-Log "Backup OK: $destZip ($sizeMb MB)"

    # Retencion: borrar backups mas viejos que $retencionDias.
    $cutoff = (Get-Date).AddDays(-$retencionDias)
    $borrados = 0
    Get-ChildItem -Path $destDir -Filter 'bot_wwebjs_auth_*.zip' |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            Remove-Item $_.FullName -Force
            Write-Log "Borrado backup viejo: $($_.Name)"
            $borrados++
        }

    Write-Log "Retencion: borrados $borrados backup(s) > $retencionDias dias"
    Write-Log "Fin OK"
    exit 0
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
