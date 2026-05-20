# Muestra los logs del vigia (cachatore - turnos YPF) en vivo (tail -f con
# colores), igual que monitor_logs.ps1 del bot de WhatsApp. Pensado para la PC
# dedicada: se abre solo al login (ver instalar_monitor_logs_vigia.ps1) y queda
# como ventana siempre visible.
#
# Colorea por el prefijo que pone el bot: ERROR: rojo, EXITO: verde, LOG: blanco.
# Uso manual: .\ver_logs_vigia.ps1   (Ctrl+C para salir)

$ErrorActionPreference = 'Stop'

# UTF-8 en consola/stdout: el vigia escribe el log en UTF-8 (acentos de los
# nombres). PS 5.1 por default muestra en Windows-1252 -> mojibake.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$logFile = Join-Path $PSScriptRoot 'logs\vigia.log'
$Host.UI.RawUI.WindowTitle = 'Cachatore - Logs en vivo'

Write-Host ''
Write-Host '====================================================' -ForegroundColor Magenta
Write-Host '  CACHATORE (turnos YPF) - Logs en vivo' -ForegroundColor Magenta
Write-Host '====================================================' -ForegroundColor Magenta
Write-Host "  Archivo: $logFile" -ForegroundColor DarkGray
Write-Host '  Ctrl+C para salir' -ForegroundColor DarkGray
Write-Host '====================================================' -ForegroundColor Magenta
Write-Host ''

# Esperar a que el log exista (el servicio recien arranca y no escribio nada).
$primera = $true
while (-not (Test-Path $logFile)) {
    if ($primera) {
        Write-Host '[INFO] Esperando que cachatore-vigia escriba el log...' -ForegroundColor Yellow
        $primera = $false
    }
    Start-Sleep -Seconds 2
}

function Write-Color([string]$line) {
    $color = 'Gray'
    if ($line -match '^ERROR:') {
        $color = 'Red'
    } elseif ($line -match '^EXITO:') {
        $color = 'Green'
    } elseif ($line -match '^LOG:') {
        $color = 'White'
    }
    Write-Host $line -ForegroundColor $color
}

# tail -f: -Encoding UTF8 es CRITICO para no mojibakear acentos.
Get-Content -Path $logFile -Wait -Tail 100 -Encoding UTF8 | ForEach-Object {
    Write-Color $_
}
