# Muestra los logs del bot en vivo (tail -f style).
#
# Pensado para correr en la PC dedicada al bot, donde no hay otra
# actividad y conviene tener una ventana siempre visible con el flujo
# del servicio.
#
# Comportamiento:
#  - Espera a que aparezca bot.out.log (si el servicio aun no
#    arranco). Sin bloquear cpu - sleep 1 seg entre chequeos.
#  - Muestra las ultimas 100 lineas + sigue printeando lineas nuevas.
#  - Colorea segun el nivel (INFO blanco, OK verde, WARN amarillo,
#    ERROR rojo). El logger del bot prefija con esos tokens.
#  - Si se cierra el bot, sigue leyendo (Get-Content -Wait nunca
#    devuelve nada). Si se quiere salir, Ctrl+C.
#
# Uso manual:
#   .\monitor_logs.ps1
#
# Auto-arranque al login: ver instalar_monitor_logs.ps1 (crea el
# shortcut en la carpeta Startup del user).

$ErrorActionPreference = 'Stop'

# Forzar UTF-8 en la consola y en stdout. El bot escribe los logs en
# UTF-8 (con flechas, tildes, checks); PowerShell 5.1 por default lee
# y muestra en Windows-1252 -> queda mojibake (e.g. la palabra
# "Sesion" con tilde sale como "Sesi" + 2 chars basura). Setear
# esto ANTES de cualquier Write-Host garantiza que se renderice bien.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$botDir = Split-Path $PSScriptRoot -Parent
$logsDir = Join-Path $botDir 'logs'
$outLog = Join-Path $logsDir 'bot.out.log'

$Host.UI.RawUI.WindowTitle = 'Coopertrans Bot - Logs en vivo'

Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  COOPERTRANS BOT - Logs en vivo' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host "  Archivo: $outLog" -ForegroundColor DarkGray
Write-Host '  Ctrl+C para salir' -ForegroundColor DarkGray
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''

# Esperar a que el log exista. Pasa cuando el servicio recien arranca
# y todavia no escribio nada.
$primeraEspera = $true
while (-not (Test-Path $outLog)) {
    if ($primeraEspera) {
        Write-Host '[INFO] Esperando que el servicio arranque y escriba bot.out.log...' -ForegroundColor Yellow
        $primeraEspera = $false
    }
    Start-Sleep -Seconds 2
}

if (-not $primeraEspera) {
    Write-Host '[INFO] Log aparecio, mostrando contenido...' -ForegroundColor Green
    Write-Host ''
}

# Colorear cada linea segun el nivel detectado en el texto.
# El logger del bot prefija con tokens como "INFO", "OK", "WARN", "ERROR".
function Write-Color([string]$line) {
    $color = 'White'
    if ($line -match '\bERROR\b|FATAL|CRITICAL|fail|FAIL') {
        $color = 'Red'
    } elseif ($line -match '\bWARN\b|warning') {
        $color = 'Yellow'
    } elseif ($line -match '\bOK\b|listo|enviado|Heartbeat OK') {
        $color = 'Green'
    } elseif ($line -match '\bINFO\b|iniciando|cargand') {
        $color = 'White'
    } else {
        $color = 'Gray'
    }
    Write-Host $line -ForegroundColor $color
}

# tail -f robusto a la ROTACION de NSSM. El clasico Get-Content -Wait sigue el
# archivo por handle: cuando NSSM rota (renombra bot.out.log y crea uno nuevo al
# pasar ~10 MB) la ventana queda pegada al archivo VIEJO y no muestra mas nada
# ("zombie"), aunque el bot siga logueando bien en el nuevo. Aca leemos por
# offset de bytes: si el archivo se achico (rotado/recreado) reabrimos desde 0;
# si crecio, leemos solo lo nuevo. FileShare ReadWrite = no trabamos a NSSM.
# -Encoding UTF8 / GetString UTF8 es CRITICO para no mojibakear flechas/tildes.
$utf8 = [System.Text.UTF8Encoding]::new($false)

Get-Content -Path $outLog -Tail 100 -Encoding UTF8 | ForEach-Object { Write-Color $_ }
$lastSize = (Get-Item $outLog).Length

while ($true) {
    Start-Sleep -Milliseconds 700
    if (-not (Test-Path $outLog)) { continue }       # instante de la rotacion
    try { $len = (Get-Item $outLog).Length } catch { continue }
    if ($len -eq $lastSize) { continue }
    if ($len -lt $lastSize) {                         # se roto/recreo: reabrir
        Write-Host '--- (log rotado, reabriendo) ---' -ForegroundColor DarkGray
        $lastSize = 0
        if ($len -eq 0) { continue }
    }
    $fs = $null
    try {
        $fs = [System.IO.FileStream]::new(
            $outLog, [System.IO.FileMode]::Open,
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
    if ($nl -lt 0) { continue }                       # linea a medio escribir: esperar
    foreach ($line in ($text.Substring(0, $nl) -split "`r?`n")) { Write-Color $line }
    $lastSize += $utf8.GetByteCount($text.Substring(0, $nl + 1))
}
