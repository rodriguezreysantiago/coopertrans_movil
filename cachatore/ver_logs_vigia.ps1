# Muestra en vivo el log del vigia 24/7 (servicio cachatore-vigia).
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $Dir "logs\vigia.log"
if (-not (Test-Path $LogFile)) {
  Write-Host "Todavia no hay log en $LogFile (el servicio nunca arranco?)." -ForegroundColor Yellow
  exit 1
}
Write-Host "Siguiendo $LogFile  (Ctrl-C para salir)" -ForegroundColor Cyan
Get-Content -Path $LogFile -Tail 40 -Wait
