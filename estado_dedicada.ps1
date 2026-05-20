# Estado de la PC dedicada de un vistazo: que commit corre, si esta al dia con
# el repo, cuando reinicio cada servicio (= cuando capturo el ultimo pull) y
# las ultimas lineas del auto-update. Para no quedar a ciegas con los pulls.
#
# Uso (en la dedicada):  .\estado_dedicada.ps1
# (La hora de arranque de los servicios puede requerir consola de Administrador.)

$ErrorActionPreference = 'Continue'
$Repo = 'C:\coopertrans_movil'

Write-Host ''
Write-Host '==================== ESTADO DEDICADA ====================' -ForegroundColor Cyan

# --- Codigo (git) ---
Write-Host ''
Write-Host '[ Codigo (git) ]' -ForegroundColor Yellow
if (Test-Path (Join-Path $Repo '.git')) {
    Push-Location $Repo
    $head = (git log -1 --format='%h  %s  (%cd)' --date=local 2>$null)
    Write-Host "  HEAD local : $head"
    & git fetch origin main --quiet 2>$null | Out-Null
    $detras = (git rev-list --count HEAD..origin/main 2>$null)
    if (-not [string]::IsNullOrWhiteSpace($detras)) {
        if ([int]$detras -gt 0) {
            Write-Host "  ATRASADO de origin por $detras commit(s) - el auto-update lo trae en <=5 min." -ForegroundColor Yellow
        } else {
            Write-Host '  Al dia con origin/main.' -ForegroundColor Green
        }
    }
    Pop-Location
} else {
    Write-Host "  No encontre el repo en $Repo" -ForegroundColor Red
}

# --- Servicios (estado + cuando arrancaron) ---
Write-Host ''
Write-Host '[ Servicios ]' -ForegroundColor Yellow
foreach ($svc in 'CoopertransMovilBot', 'cachatore-vigia') {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { Write-Host "  $svc : NO instalado en esta PC"; continue }
    $arranque = '(hora de arranque no disponible)'
    try {
        $wmi = Get-CimInstance Win32_Service -Filter "Name='$svc'" -ErrorAction Stop
        if ($wmi.ProcessId -gt 0) {
            $p = Get-Process -Id $wmi.ProcessId -ErrorAction SilentlyContinue
            if ($p -and $p.StartTime) {
                $mins = [int]((Get-Date) - $p.StartTime).TotalMinutes
                $arranque = "arranco $($p.StartTime.ToString('dd/MM HH:mm:ss'))  (hace $mins min)"
            }
        }
    } catch {}
    $color = if ($s.Status -eq 'Running') { 'Green' } else { 'Red' }
    Write-Host "  $svc : $($s.Status)   $arranque" -ForegroundColor $color
}

# --- auto-update (cada cuanto pullea + que reinicio) ---
Write-Host ''
Write-Host '[ auto_update.log (ultimas 15 lineas) ]' -ForegroundColor Yellow
$auLog = Join-Path $Repo 'whatsapp-bot\logs\auto_update.log'
if (Test-Path $auLog) {
    Get-Content $auLog -Tail 15 -Encoding UTF8 | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host '  (todavia no hay auto_update.log)'
}

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
