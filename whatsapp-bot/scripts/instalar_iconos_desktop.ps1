# Crea 3 iconos en el escritorio del user actual:
#   - "Iniciar Bot WhatsApp"  -> ejecuta scripts\start_bot.ps1
#   - "Detener Bot WhatsApp"  -> ejecuta scripts\stop_bot.ps1
#   - "PowerShell Admin - Bot" -> abre PS admin en la raiz del bot
#
# Pensado para la PC dedicada al bot: en lugar de abrir PowerShell y
# tipear comandos, el operador hace doble click en el escritorio.
#
# Los 3 shortcuts vienen con el flag "Run as Administrator" porque:
#   - Start/Stop-Service requiere admin (sino el script interno hace
#     un segundo UAC prompt y queda feo).
#   - La shell admin sirve justamente para tareas de mantenimiento
#     (git pull, npm install, debug del servicio, etc.).
#
# El icono visual es de la libreria estandar de Windows (imageres.dll)
# para que se vea consistente con el resto del sistema:
#   - Play verde para Iniciar
#   - Stop rojo para Detener
#   - Consola para la PowerShell admin
#
# Idempotente: se puede correr de nuevo, sobreescribe los .lnk.
#
# USO:
#   .\instalar_iconos_desktop.ps1
#
# DESINSTALAR: borrar los 3 .lnk del escritorio.

$ErrorActionPreference = 'Stop'

# Paths -------------------------------------------------------------
$scriptsDir = $PSScriptRoot
$botDir = Split-Path $scriptsDir -Parent  # whatsapp-bot/
$startScript = Join-Path $scriptsDir 'start_bot.ps1'
$stopScript = Join-Path $scriptsDir 'stop_bot.ps1'

foreach ($s in @($startScript, $stopScript)) {
    if (-not (Test-Path $s)) {
        Write-Host "ERROR no encuentro $s" -ForegroundColor Red
        exit 1
    }
}

$desktopDir = [Environment]::GetFolderPath('Desktop')
$lnkStart = Join-Path $desktopDir 'Iniciar Bot WhatsApp.lnk'
$lnkStop = Join-Path $desktopDir 'Detener Bot WhatsApp.lnk'
$lnkShell = Join-Path $desktopDir 'PowerShell Admin - Bot.lnk'

Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  ICONOS DE ESCRITORIO - Bot WhatsApp' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan

# Helper: crea un .lnk + le pega el flag RunAsAdmin -----------------
#
# El flag "Run as Administrator" NO se puede setear via WScript.Shell
# directamente. La tecnica estandar es:
#   1. Crear el shortcut normal con WScript.Shell.
#   2. Leer los bytes del .lnk.
#   3. Setear bit 0x20 en el byte 0x15 (parte de LinkFlags) que es el
#      "RunAsUser" flag del formato MS-SHLLINK.
#   4. Escribir los bytes de vuelta.
#
# Probado y funcional en Windows 10/11.
function New-AdminShortcut {
    param(
        [Parameter(Mandatory)] [string]$LnkPath,
        [Parameter(Mandatory)] [string]$Arguments,
        [Parameter(Mandatory)] [string]$WorkingDirectory,
        [Parameter(Mandatory)] [string]$IconResource,
        [Parameter(Mandatory)] [string]$Description
    )
    # Crear shortcut basico
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($LnkPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.WindowStyle = 1  # Normal
    $shortcut.Description = $Description
    $shortcut.IconLocation = $IconResource
    $shortcut.Save()

    # Setear flag RunAsAdmin
    $bytes = [System.IO.File]::ReadAllBytes($LnkPath)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($LnkPath, $bytes)
}

# Crear "Iniciar Bot WhatsApp" --------------------------------------
Write-Host ''
Write-Host '[1/3] Creando "Iniciar Bot WhatsApp.lnk"...' -ForegroundColor Cyan
try {
    New-AdminShortcut `
        -LnkPath $lnkStart `
        -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`"" `
        -WorkingDirectory $scriptsDir `
        -IconResource 'imageres.dll,98' `
        -Description 'Inicia el servicio CoopertransMovilBot (requiere admin)'
    Write-Host "  OK $lnkStart" -ForegroundColor Green
} catch {
    Write-Host "  FAIL $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Crear "Detener Bot WhatsApp" --------------------------------------
Write-Host ''
Write-Host '[2/3] Creando "Detener Bot WhatsApp.lnk"...' -ForegroundColor Cyan
try {
    New-AdminShortcut `
        -LnkPath $lnkStop `
        -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$stopScript`"" `
        -WorkingDirectory $scriptsDir `
        -IconResource 'imageres.dll,100' `
        -Description 'Detiene el servicio CoopertransMovilBot (requiere admin)'
    Write-Host "  OK $lnkStop" -ForegroundColor Green
} catch {
    Write-Host "  FAIL $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Crear "PowerShell Admin - Bot" ------------------------------------
# Abre PS admin parado en la raiz del bot (whatsapp-bot/), sin
# ejecutar ningun script. Sirve para tareas manuales: git pull,
# npm install, debug, ver status del servicio, etc.
#
# -NoExit para que la ventana quede abierta despues de cargar el
# profile (sino se cerraria sola al no haber -File ni -Command).
Write-Host ''
Write-Host '[3/3] Creando "PowerShell Admin - Bot.lnk"...' -ForegroundColor Cyan
try {
    New-AdminShortcut `
        -LnkPath $lnkShell `
        -Arguments '-NoExit -NoProfile' `
        -WorkingDirectory $botDir `
        -IconResource "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0" `
        -Description "PowerShell admin parado en $botDir"
    Write-Host "  OK $lnkShell" -ForegroundColor Green
} catch {
    Write-Host "  FAIL $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '====================================================' -ForegroundColor Green
Write-Host '  ICONOS INSTALADOS' -ForegroundColor Green
Write-Host '====================================================' -ForegroundColor Green
Write-Host ''
Write-Host '  Ya tenes 3 iconos en el escritorio:' -ForegroundColor White
Write-Host '    - Iniciar Bot WhatsApp     (icono play verde)' -ForegroundColor Green
Write-Host '    - Detener Bot WhatsApp     (icono stop rojo)' -ForegroundColor Red
Write-Host '    - PowerShell Admin - Bot   (icono PS azul)' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Doble click en cada uno te pide UAC (admin) y:' -ForegroundColor Cyan
Write-Host '    - Iniciar / Detener        ejecutan el script' -ForegroundColor Cyan
Write-Host '    - PowerShell Admin - Bot   abre PS parado en' -ForegroundColor Cyan
Write-Host "                                 $botDir" -ForegroundColor Cyan
Write-Host '                                 para tareas manuales' -ForegroundColor Cyan
Write-Host '                                 (git pull, npm i, debug)' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Para desinstalar: borrar los .lnk del escritorio.' -ForegroundColor DarkGray
Write-Host ''
