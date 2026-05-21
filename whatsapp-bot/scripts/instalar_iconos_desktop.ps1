# Crea los iconos de operacion en el escritorio del user actual (PC dedicada).
#
#   BOT WHATSAPP:
#     - Iniciar Bot WhatsApp   -> start_bot.ps1 (arranca + abre los logs) [admin]
#     - Detener Bot WhatsApp   -> stop_bot.ps1                            [admin]
#     - Logs Bot WhatsApp      -> monitor_logs.ps1 (solo ver logs)        [normal]
#     - PowerShell Admin - Bot -> shell admin parada en whatsapp-bot/     [admin]
#   CACHATORE (turnos YPF):
#     - Iniciar Cachatore      -> iniciar_cachatore.ps1 (arranca + logs)  [admin]
#     - Detener Cachatore      -> detener_cachatore.ps1                   [admin]
#     - Logs Cachatore         -> ver_logs_vigia.ps1 (solo ver logs)      [normal]
#
# Los de iniciar/detener vienen con "Run as Administrator" (Start/Stop-Service
# lo necesita). Los de "Logs" NO (solo leen el archivo de log) -> no piden UAC.
#
# Iconos de la libreria estandar de Windows: play verde (iniciar), stop rojo
# (detener), consola PowerShell (logs / shell).
#
# Idempotente: se puede correr de nuevo (sobreescribe los .lnk).
# DESINSTALAR: borrar los .lnk del escritorio.
#
#   .\instalar_iconos_desktop.ps1

$ErrorActionPreference = 'Stop'

$scriptsDir   = $PSScriptRoot                      # whatsapp-bot\scripts
$botDir       = Split-Path $scriptsDir -Parent     # whatsapp-bot
$repoRoot     = Split-Path $botDir -Parent         # raiz del repo
$cachatoreDir = Join-Path $repoRoot 'cachatore'
$desktopDir   = [Environment]::GetFolderPath('Desktop')
$psIcon       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"

# Crea un .lnk a powershell.exe que ejecuta un .ps1. Con -Admin le pega el flag
# "Run as Administrator" (bit 0x20 del byte 0x15 del formato MS-SHLLINK; no se
# puede via WScript.Shell). Con -NoExit la ventana queda abierta (para logs).
function New-Lnk {
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$IconResource,
        [Parameter(Mandatory)][string]$Description,
        [switch]$Admin,
        [switch]$NoExit
    )
    $lnk = Join-Path $desktopDir "$Nombre.lnk"
    if (-not (Test-Path $File)) {
        Write-Host "  SKIP $Nombre (no encuentro $File)" -ForegroundColor Yellow
        return
    }
    # OJO: la variable NO puede llamarse $noexit -> en PowerShell las variables
    # son case-insensitive, asi que colisionaria con el switch $NoExit y al
    # asignarle un string falla con "no se puede convertir '' a SwitchParameter".
    $neArg = if ($NoExit) { '-NoExit ' } else { '' }
    $argLine = "-NoProfile $neArg-ExecutionPolicy Bypass -File `"$File`""
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = 'powershell.exe'
    $sc.Arguments = $argLine
    $sc.WorkingDirectory = $WorkingDirectory
    $sc.WindowStyle = 1
    $sc.Description = $Description
    $sc.IconLocation = $IconResource
    $sc.Save()
    if ($Admin) {
        $bytes = [System.IO.File]::ReadAllBytes($lnk)
        $bytes[0x15] = $bytes[0x15] -bor 0x20
        [System.IO.File]::WriteAllBytes($lnk, $bytes)
    }
    Write-Host "  OK $Nombre" -ForegroundColor Green
}

# Shortcut a un PowerShell de ADMINISTRADOR parado en una carpeta. OJO: al
# elevar (UAC) Windows ignora el WorkingDirectory del .lnk y abriria en
# System32; por eso forzamos la ruta con Set-Location al arrancar (-NoExit deja
# la ventana abierta despues del cd).
function New-AdminShell {
    param([string]$Nombre, [string]$Dir, [string]$Descripcion)
    try {
        $lnk = Join-Path $desktopDir "$Nombre.lnk"
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($lnk)
        $sc.TargetPath = 'powershell.exe'
        $sc.Arguments = "-NoExit -NoProfile -Command `"Set-Location '$Dir'`""
        $sc.WorkingDirectory = $Dir
        $sc.WindowStyle = 1
        $sc.Description = $Descripcion
        $sc.IconLocation = $psIcon
        $sc.Save()
        $bytes = [System.IO.File]::ReadAllBytes($lnk)
        $bytes[0x15] = $bytes[0x15] -bor 0x20
        [System.IO.File]::WriteAllBytes($lnk, $bytes)
        Write-Host "  OK $Nombre" -ForegroundColor Green
    } catch {
        Write-Host "  FAIL $Nombre : $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  ICONOS DE ESCRITORIO - Bot WhatsApp + Cachatore' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'BOT WHATSAPP:' -ForegroundColor White

New-Lnk -Nombre 'Iniciar Bot WhatsApp' -File (Join-Path $scriptsDir 'start_bot.ps1') -WorkingDirectory $scriptsDir -IconResource 'imageres.dll,98' -Description 'Inicia el bot WhatsApp y abre la ventana de logs (admin)' -Admin

New-Lnk -Nombre 'Detener Bot WhatsApp' -File (Join-Path $scriptsDir 'stop_bot.ps1') -WorkingDirectory $scriptsDir -IconResource 'imageres.dll,100' -Description 'Detiene el bot WhatsApp (admin)' -Admin

New-Lnk -Nombre 'Logs Bot WhatsApp' -File (Join-Path $scriptsDir 'monitor_logs.ps1') -WorkingDirectory $scriptsDir -IconResource $psIcon -Description 'Ventana de logs en vivo del bot WhatsApp' -NoExit

# PowerShell de administrador parados en una ruta (ver New-AdminShell). El de
# la RAIZ del repo (C:\coopertrans_movil en la dedicada) es el mas util para
# tareas manuales: git pull, correr scripts, etc. El de whatsapp-bot queda por
# compatibilidad.
New-AdminShell -Nombre 'PowerShell Admin - coopertrans' -Dir $repoRoot -Descripcion "PowerShell admin parado en $repoRoot (raiz del repo)"
New-AdminShell -Nombre 'PowerShell Admin - Bot' -Dir $botDir -Descripcion "PowerShell admin parado en $botDir"

Write-Host ''
Write-Host 'CACHATORE (turnos YPF):' -ForegroundColor White

New-Lnk -Nombre 'Iniciar Cachatore' -File (Join-Path $cachatoreDir 'iniciar_cachatore.ps1') -WorkingDirectory $cachatoreDir -IconResource 'imageres.dll,98' -Description 'Inicia el cachatore (turnos YPF) y abre la ventana de logs (admin)' -Admin

New-Lnk -Nombre 'Detener Cachatore' -File (Join-Path $cachatoreDir 'detener_cachatore.ps1') -WorkingDirectory $cachatoreDir -IconResource 'imageres.dll,100' -Description 'Detiene el cachatore (turnos YPF) (admin)' -Admin

New-Lnk -Nombre 'Logs Cachatore' -File (Join-Path $cachatoreDir 'ver_logs_vigia.ps1') -WorkingDirectory $cachatoreDir -IconResource $psIcon -Description 'Ventana de logs en vivo del cachatore (turnos YPF)' -NoExit

Write-Host ''
Write-Host '====================================================' -ForegroundColor Green
Write-Host '  LISTO - revisa el escritorio' -ForegroundColor Green
Write-Host '====================================================' -ForegroundColor Green
Write-Host ''
Write-Host '  Iniciar/Detener piden UAC (admin). Los de "Logs" no.' -ForegroundColor Cyan
Write-Host '  "Iniciar ..." arranca el servicio Y abre los logs.' -ForegroundColor Cyan
Write-Host '  Para desinstalar: borrar los .lnk del escritorio.' -ForegroundColor DarkGray
Write-Host ''
