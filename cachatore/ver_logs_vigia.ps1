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
Write-Host '  visor v2 (resiste la rotacion del log)' -ForegroundColor DarkGray
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

# tail -f robusto a la ROTACION de NSSM. El clasico Get-Content -Wait sigue el
# archivo por handle: cuando NSSM rota (renombra vigia.log y crea uno nuevo al
# pasar ~5 MB, o al reiniciar si ya estaba grande) la ventana queda pegada al
# archivo VIEJO y no muestra mas nada ("zombie"), aunque el bot siga logueando
# bien en el nuevo. Aca leemos por offset de bytes: si el archivo se achico
# (rotado/recreado) reabrimos desde 0; si crecio, leemos solo lo nuevo. Abrimos
# con FileShare ReadWrite para no trabar a NSSM mientras escribe.
# -Encoding UTF8 / GetString UTF8 es CRITICO para no mojibakear acentos.
$utf8 = [System.Text.UTF8Encoding]::new($false)

# Arranque: ultimas 100 lineas y nos paramos al final del archivo.
Get-Content -Path $logFile -Tail 100 -Encoding UTF8 | ForEach-Object { Write-Color $_ }
$lastSize = (Get-Item $logFile).Length

while ($true) {
    Start-Sleep -Milliseconds 700
    if (-not (Test-Path $logFile)) { continue }     # instante de la rotacion
    try { $len = (Get-Item $logFile).Length } catch { continue }
    if ($len -eq $lastSize) { continue }
    if ($len -lt $lastSize) {                        # se roto/recreo: reabrir
        Write-Host '--- (log rotado, reabriendo) ---' -ForegroundColor DarkGray
        $lastSize = 0
        if ($len -eq 0) { continue }
    }
    $fs = $null
    try {
        $fs = [System.IO.FileStream]::new(
            $logFile, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $fs.Seek($lastSize, [System.IO.SeekOrigin]::Begin) | Out-Null
        $count = [int]($len - $lastSize)
        $buf = New-Object byte[] $count
        $read = $fs.Read($buf, 0, $count)
    } catch {
        continue
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    if ($read -le 0) { continue }
    $text = $utf8.GetString($buf, 0, $read)
    $nl = $text.LastIndexOf("`n")
    if ($nl -lt 0) { continue }                      # linea a medio escribir: esperar
    foreach ($line in ($text.Substring(0, $nl) -split "`r?`n")) { Write-Color $line }
    # Avanzar SOLO por los bytes de las lineas completas (UTF8-aware).
    $lastSize += $utf8.GetByteCount($text.Substring(0, $nl + 1))
}
