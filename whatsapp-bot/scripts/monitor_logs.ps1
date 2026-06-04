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

# Desactivar QuickEdit Mode de la consola. Con QuickEdit (default de Windows), al
# hacer click o seleccionar texto en la ventana el proceso se CONGELA (deja de
# mostrar lineas nuevas) hasta apretar Esc/Enter — parece que el visor se colgo.
# Lo apagamos para que nunca se congele al pasar el mouse / scrollear / clickear.
# (Para copiar texto: click-derecho -> Marcar.) Best-effort: si falla (no hay
# consola real, p.ej. corriendo bajo un servicio), seguimos sin tocar nada.
try {
    $qeSig = '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);'
    $qe = Add-Type -Name ConsoleQuickEdit -Namespace W32 -PassThru -MemberDefinition $qeSig
    $hIn = $qe::GetStdHandle(-10)   # STD_INPUT_HANDLE
    $m = 0
    if ($qe::GetConsoleMode($hIn, [ref]$m)) {
        # quitar ENABLE_QUICK_EDIT (0x40); poner ENABLE_EXTENDED_FLAGS (0x80)
        $qe::SetConsoleMode($hIn, (($m -band (-bnot 0x40)) -bor 0x80)) | Out-Null
    }
} catch { }

$botDir = Split-Path $PSScriptRoot -Parent
$logsDir = Join-Path $botDir 'logs'
$outLog = Join-Path $logsDir 'bot.out.log'

$Host.UI.RawUI.WindowTitle = 'Coopertrans Bot - Logs en vivo'

Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  COOPERTRANS BOT - Logs en vivo' -ForegroundColor Cyan
Write-Host '  visor v3 (resiste rotacion + muestra el auto-update)' -ForegroundColor DarkGray
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
    } elseif ($line -match 'Agente respondi') {
        # Respuestas del agente IA: magenta para que resalten distinto del
        # verde de los envios del bot (pedido Santiago 2026-06-04). El patron
        # va SIN tilde a proposito ("respondi" es prefijo de "respondio"),
        # robusto al encoding del .ps1.
        $color = 'Magenta'
    } elseif ($line -match '\bOK\b|listo|enviado|Heartbeat OK') {
        $color = 'Green'
    } elseif ($line -match '\bINFO\b|iniciando|cargand') {
        $color = 'White'
    } else {
        $color = 'Gray'
    }
    Write-Host $line -ForegroundColor $color
}

# Log del AUTO-UPDATE (la tarea programada que hace el git pull + reinicia los
# servicios). Lo mostramos INTERCALADO aca (en cyan) para ver en vivo cuando se
# actualiza/reinicia el bot. Vive en el mismo logs\ del bot.
$auLog = Join-Path $logsDir 'auto_update.log'

$utf8 = [System.Text.UTF8Encoding]::new($false)

# tail -f robusto a la ROTACION de NSSM. El clasico Get-Content -Wait sigue el
# archivo por handle y queda "zombie" cuando NSSM rota (renombra el log y crea
# uno nuevo al pasar ~10 MB). Aca leemos por offset: si el archivo se achico
# (rotado/recreado) reabrimos desde 0; si crecio, leemos solo lo nuevo.
# FileShare ReadWrite = no trabamos a NSSM. UTF8 para no mojibakear flechas/
# tildes. Devuelve el nuevo offset; imprime las lineas nuevas con $Pintor.
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

# Arranque: ultimas 100 lineas del log y nos paramos al final de AMBOS (del
# auto-update solo mostramos lo NUEVO de aca en adelante).
Get-Content -Path $outLog -Tail 100 -Encoding UTF8 | ForEach-Object { Write-Color $_ }
$posMain = (Get-Item $outLog).Length
$posAu = if (Test-Path $auLog) { (Get-Item $auLog).Length } else { 0 }

$pintarMain = { param($l) Write-Color $l }
# En la ventana del BOT mostramos del auto-update SOLO el aviso de pull y lo del
# propio bot. Lo del cachatore se omite aca: va en la ventana del cachatore.
$pintarAu = {
    param($l)
    if ($l -match 'CoopertransMovilBot|whatsapp-bot|smoke|npm|DEPLOY|PULL EN PROCESO|git (fetch|pull)|Excepcion no manejada') {
        # "auto-update" DESPUES de la fecha, igual que en el visor del cachatore.
        $shown = $l -replace '^(\[\d\d/\d\d \d\d:\d\d:\d\d\]) ', '$1 auto-update '
        Write-Host $shown -ForegroundColor Cyan
    }
}

while ($true) {
    Start-Sleep -Milliseconds 700
    $posMain = Mostrar-Nuevas $outLog $posMain $pintarMain
    $posAu = Mostrar-Nuevas $auLog $posAu $pintarAu
}
