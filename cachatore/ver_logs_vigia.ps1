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
Write-Host '  visor v3 (resiste rotacion + muestra el auto-update)' -ForegroundColor DarkGray
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

# Log del AUTO-UPDATE (la tarea programada que hace el git pull + reinicia los
# servicios). Lo mostramos INTERCALADO en esta ventana (en cyan) para ver en
# vivo cuando se actualiza/reinicia el cachatore. Vive en el dir del bot, un
# nivel arriba de cachatore\.
$auLog = Join-Path (Split-Path $PSScriptRoot -Parent) 'whatsapp-bot\logs\auto_update.log'

$utf8 = [System.Text.UTF8Encoding]::new($false)

# tail -f robusto a la ROTACION de NSSM. El clasico Get-Content -Wait sigue el
# archivo por handle y queda "zombie" cuando NSSM rota (renombra el log y crea
# uno nuevo). Aca leemos por offset de bytes: si el archivo se achico (rotado/
# recreado) reabrimos desde 0; si crecio, leemos solo lo nuevo. FileShare
# ReadWrite para no trabar a NSSM. UTF8 para no mojibakear acentos. Devuelve el
# nuevo offset; imprime las lineas nuevas con el scriptblock $Pintor.
function Mostrar-Nuevas {
    param([string]$Path, [long]$Desde, [scriptblock]$Pintor)
    if (-not (Test-Path $Path)) { return $Desde }
    try { $len = (Get-Item $Path).Length } catch { return $Desde }
    if ($len -lt $Desde) { $Desde = 0 }   # rotado/recreado: reabrir desde 0
    if ($len -le $Desde) { return $len }
    $fs = $null
    try {
        $fs = [System.IO.FileStream]::new(
            $Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $fs.Seek($Desde, [System.IO.SeekOrigin]::Begin) | Out-Null
        $count = [int]($len - $Desde)
        $buf = New-Object byte[] $count
        $read = $fs.Read($buf, 0, $count)
    } catch {
        return $Desde
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    if ($read -le 0) { return $Desde }
    $text = $utf8.GetString($buf, 0, $read)
    $nl = $text.LastIndexOf("`n")
    if ($nl -lt 0) { return $Desde }   # linea a medio escribir: esperar
    foreach ($line in ($text.Substring(0, $nl) -split "`r?`n")) { & $Pintor $line }
    return $Desde + $utf8.GetByteCount($text.Substring(0, $nl + 1))
}

# Arranque: ultimas 100 lineas del log y nos paramos al final de AMBOS archivos
# (del auto-update solo mostramos lo NUEVO de aca en adelante).
Get-Content -Path $logFile -Tail 100 -Encoding UTF8 | ForEach-Object { Write-Color $_ }
$posMain = (Get-Item $logFile).Length
$posAu = if (Test-Path $auLog) { (Get-Item $auLog).Length } else { 0 }

$pintarMain = { param($l) Write-Color $l }
$pintarAu = { param($l) Write-Host "  [auto-update] $l" -ForegroundColor Cyan }

while ($true) {
    Start-Sleep -Milliseconds 700
    $posMain = Mostrar-Nuevas $logFile $posMain $pintarMain
    $posAu = Mostrar-Nuevas $auLog $posAu $pintarAu
}
