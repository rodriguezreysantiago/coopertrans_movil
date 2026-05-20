# Instala la ventana de logs del cachatore en la carpeta Startup del user.
# Cada vez que el user loguee en Windows, se abre sola la ventana con los logs
# del vigia en vivo - igual que la del bot de WhatsApp, asi en la PC dedicada
# ves las DOS ventanas (bot + cachatore) al iniciar sesion.
#
# El shortcut apunta a powershell -NoExit -File ver_logs_vigia.ps1, en
# %APPDATA%\...\Startup (solo este user). Idempotente (sobreescribe).
# Desinstalar: borrar el .lnk de esa carpeta.
#
# Uso:  .\instalar_monitor_logs_vigia.ps1

$ErrorActionPreference = 'Stop'

$monitorScript = Join-Path $PSScriptRoot 'ver_logs_vigia.ps1'
if (-not (Test-Path $monitorScript)) {
    Write-Host "ERROR No se encuentra $monitorScript" -ForegroundColor Red
    exit 1
}

$startupDir = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startupDir 'Cachatore_Logs.lnk'

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$monitorScript`""
$shortcut.WorkingDirectory = Split-Path $monitorScript -Parent
$shortcut.WindowStyle = 1  # 1=Normal
$shortcut.Description = 'Cachatore - Logs en vivo'
$shortcut.IconLocation = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
$shortcut.Save()

Write-Host ''
Write-Host '====================================================' -ForegroundColor Green
Write-Host '  Ventana de logs del cachatore INSTALADA' -ForegroundColor Green
Write-Host '====================================================' -ForegroundColor Green
Write-Host "  Shortcut: $lnkPath" -ForegroundColor White
Write-Host "  Apunta a: $monitorScript" -ForegroundColor White
Write-Host '  Se abre sola cada vez que loguees en este user.' -ForegroundColor Cyan
Write-Host '  Abrirla AHORA sin reloguear:' -ForegroundColor Cyan
Write-Host "    Start-Process powershell -ArgumentList '-NoExit','-File','$monitorScript'" -ForegroundColor Gray
Write-Host "  Desinstalar:  Remove-Item `"$lnkPath`"" -ForegroundColor DarkGray
Write-Host ''
