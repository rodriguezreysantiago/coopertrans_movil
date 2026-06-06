# Instalador end-to-end del bot WhatsApp en una PC dedicada nueva.
#
# Pensado para correr UNA SOLA VEZ desde la carpeta del kit (la que
# arma `preparar_kit_pc_dedicada.ps1` en la PC origen). El kit
# contiene los 3 archivos secret (.env + serviceAccountKey.json +
# .wwebjs_auth/) que NO estan en git, y este script lo orquesta
# todo lo demas:
#
#   1. Verifica admin.
#   2. Instala Node.js LTS si no esta (via winget, Windows 10/11).
#   3. Instala Git for Windows si no esta (via winget).
#   4. Refresca el PATH para usar las herramientas recien instaladas.
#   5. Clona el repo en C:\coopertrans_movil si no existe.
#   6. Copia los 3 archivos del kit a sus paths del repo.
#   7. cd whatsapp-bot && npm install (descarga Chromium ~150 MB).
#   8. instalar_servicio.ps1 -Auto (NSSM modo Automatic delayed).
#   9. setup_pc_24x7.ps1 (power plan, wake-on-lan, update windows).
#  10. instalar_auto_update.ps1 (Scheduled Task auto-deploy cada 5 min).
#  11. Smoke test final: bot heartbeateando + estadoCliente=LISTO.
#
# Idempotente: se puede correr de nuevo sin romper nada. Cada paso
# detecta si ya esta hecho y lo skipea.
#
# Tiempo total: 10-15 min en una PC promedio con buena conexion.
#
# Uso:
#   Click derecho sobre instalar_todo.ps1 -> Run with PowerShell (admin)
#   o
#   PowerShell como Administrador:
#       Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#       cd <ruta-del-kit>
#       .\instalar_todo.ps1
#
# Flags opcionales:
#   -RepoUrl   URL del repo (default: https://github.com/rodriguezreysantiago/coopertrans_movil.git)
#   -RepoPath  Donde clonar (default: C:\coopertrans_movil)
#   -SkipNode  No intentar instalar Node (asume que ya esta)
#   -SkipGit   No intentar instalar Git (asume que ya esta)

[CmdletBinding()]
param(
    [string]$RepoUrl  = 'https://github.com/rodriguezreysantiago/coopertrans_movil.git',
    [string]$RepoPath = 'C:\coopertrans_movil',
    [switch]$SkipNode,
    [switch]$SkipGit
)

$ErrorActionPreference = 'Stop'

# --- Helpers --------------------------------------------------------
function Write-Step {
    param([int]$N, [int]$Total, [string]$Msg)
    Write-Host ""
    Write-Host "[$N/$Total] $Msg" -ForegroundColor Cyan
}

function Write-Ok    { param([string]$Msg) Write-Host "  OK   $Msg" -ForegroundColor Green }
function Write-Skip  { param([string]$Msg) Write-Host "  SKIP $Msg" -ForegroundColor DarkGray }
function Write-Warn  { param([string]$Msg) Write-Host "  WARN $Msg" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Msg) Write-Host "  FAIL $Msg" -ForegroundColor Red }

function Refresh-Path {
    # Toma el PATH actualizado del registro (Machine + User) y lo aplica
    # al shell actual. Despues de instalar algo con winget, el PATH
    # nuevo solo aparece en shells nuevos - esto evita tener que
    # cerrar y reabrir PowerShell.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# --- 1. Admin check -------------------------------------------------
$totalSteps = 12
Write-Step 1 $totalSteps "Verificando privilegios de Administrador..."
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Fail "Este script DEBE correr como Administrador."
    Write-Host ""
    Write-Host "Para reabrir:" -ForegroundColor Yellow
    Write-Host "  Click derecho sobre instalar_todo.ps1 -> Run with PowerShell" -ForegroundColor White
    Write-Host "  O abrir PowerShell como Admin y correr:" -ForegroundColor White
    Write-Host "    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass" -ForegroundColor White
    Write-Host "    .\instalar_todo.ps1" -ForegroundColor White
    exit 1
}
Write-Ok "Estamos como Administrador."

# --- 2. Node.js -----------------------------------------------------
Write-Step 2 $totalSteps "Verificando Node.js..."
if ($SkipNode) {
    Write-Skip "-SkipNode pasado, no chequeo."
} elseif (Test-Command 'node') {
    $nodeVer = (node --version)
    Write-Ok "Node ya instalado: $nodeVer"
} else {
    Write-Host "  Node no esta instalado. Instalando via winget..." -ForegroundColor Yellow
    if (-not (Test-Command 'winget')) {
        Write-Fail "winget no esta disponible. Instalar Node manualmente desde https://nodejs.org y volver a correr este script con -SkipNode."
        exit 1
    }
    winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "winget install Node fallo (exit $LASTEXITCODE). Instalar manualmente desde https://nodejs.org"
        exit 1
    }
    Refresh-Path
    if (-not (Test-Command 'node')) {
        Write-Fail "Node se instalo pero 'node' no aparece en PATH. Cerrar PowerShell, abrir uno NUEVO como admin y re-correr."
        exit 1
    }
    Write-Ok "Node instalado: $(node --version)"
}

# --- 3. Git ---------------------------------------------------------
Write-Step 3 $totalSteps "Verificando Git..."
if ($SkipGit) {
    Write-Skip "-SkipGit pasado, no chequeo."
} elseif (Test-Command 'git') {
    $gitVer = (git --version)
    Write-Ok "Git ya instalado: $gitVer"
} else {
    Write-Host "  Git no esta instalado. Instalando via winget..." -ForegroundColor Yellow
    if (-not (Test-Command 'winget')) {
        Write-Fail "winget no disponible. Instalar Git manualmente desde https://git-scm.com/download/win"
        exit 1
    }
    winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "winget install Git fallo (exit $LASTEXITCODE)."
        exit 1
    }
    Refresh-Path
    if (-not (Test-Command 'git')) {
        Write-Fail "Git se instalo pero 'git' no aparece en PATH. Cerrar PowerShell, abrir uno NUEVO como admin y re-correr."
        exit 1
    }
    Write-Ok "Git instalado: $(git --version)"
}

# --- 4. Refresh PATH una vez mas por las dudas ---------------------
Write-Step 4 $totalSteps "Refrescando PATH del shell..."
Refresh-Path
Write-Ok "PATH refrescado."

# --- 5. Clone del repo ----------------------------------------------
Write-Step 5 $totalSteps "Clone del repo en $RepoPath..."
if (Test-Path (Join-Path $RepoPath '.git')) {
    Write-Skip "Repo ya esta clonado en $RepoPath, hago git pull..."
    Push-Location $RepoPath
    try {
        # NO usar `2>&1 | Out-Host`: PS 5.1 con $EAP=Stop trata cada
        # linea de stderr de un native command como RemoteException
        # fatal. Git escribe "Cloning into..." y similares a stderr
        # aunque NO sean errores (incidente Santiago 2026-05-18).
        # `--quiet` silencia esa salida; los errores reales siguen
        # apareciendo via $LASTEXITCODE.
        git pull --ff-only --quiet origin main
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "git pull devolvio exit $LASTEXITCODE - sigo igual."
        } else {
            Write-Ok "Repo actualizado a HEAD: $((git rev-parse --short HEAD).Trim())"
        }
    } finally {
        Pop-Location
    }
} else {
    $parent = Split-Path $RepoPath -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    git clone --quiet $RepoUrl $RepoPath
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "git clone fallo (exit $LASTEXITCODE). Verificar conexion + permisos."
        exit 1
    }
    Write-Ok "Repo clonado en $RepoPath"
}

# --- 6. Copiar los 3 archivos del kit ------------------------------
Write-Step 6 $totalSteps "Copiando archivos secret del kit a sus paths del repo..."
$kitDir          = $PSScriptRoot
$kitWwebjs       = Join-Path $kitDir '.wwebjs_auth'
$kitEnv          = Join-Path $kitDir '.env'
$kitServiceAcc   = Join-Path $kitDir 'serviceAccountKey.json'

$dstWwebjs       = Join-Path $RepoPath 'whatsapp-bot\.wwebjs_auth'
$dstEnv          = Join-Path $RepoPath 'whatsapp-bot\.env'
$dstServiceAcc   = Join-Path $RepoPath 'serviceAccountKey.json'

# serviceAccountKey.json
if (Test-Path $kitServiceAcc) {
    Copy-Item -Path $kitServiceAcc -Destination $dstServiceAcc -Force
    Write-Ok "serviceAccountKey.json -> $dstServiceAcc"
} else {
    Write-Fail "Falta serviceAccountKey.json en el kit ($kitServiceAcc). Sin eso el bot no inicia."
    exit 1
}

# .env
if (Test-Path $kitEnv) {
    Copy-Item -Path $kitEnv -Destination $dstEnv -Force
    Write-Ok ".env -> $dstEnv"
} else {
    Write-Fail "Falta .env en el kit. Sin eso el bot no inicia."
    exit 1
}

# .wwebjs_auth/
if (Test-Path $kitWwebjs) {
    if (Test-Path $dstWwebjs) {
        Write-Skip "$dstWwebjs ya existe - lo borro y reemplazo con la version del kit."
        Remove-Item -Path $dstWwebjs -Recurse -Force
    }
    # robocopy /MIR es mas rapido que Copy-Item con muchos archivos
    Write-Host "  Copiando .wwebjs_auth/ (puede tardar 1-2 min)..." -ForegroundColor Cyan
    $null = robocopy $kitWwebjs $dstWwebjs /MIR /B /R:1 /W:1 /NFL /NDL /NJH /NJS /XJ /NP
    if ($LASTEXITCODE -ge 8) {
        Write-Fail "robocopy fallo (exit $LASTEXITCODE)."
        exit 1
    }
    $sz = [math]::Round((Get-ChildItem $dstWwebjs -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB, 1)
    Write-Ok ".wwebjs_auth/ copiada ($sz MB)"
} else {
    Write-Warn "Falta .wwebjs_auth/ en el kit. El bot va a pedir QR la primera vez que arranque."
}

# --- 7. npm install -------------------------------------------------
Write-Step 7 $totalSteps "Instalando dependencias del bot (npm install)..."
$botDir = Join-Path $RepoPath 'whatsapp-bot'
Push-Location $botDir
try {
    # --silent reduce ruido. NO usar `2>&1 | Out-Host` con $EAP=Stop:
    # npm escribe warnings a stderr (deprecaciones, peer deps, etc.)
    # que NO son errores reales, pero PS 5.1 los convierte en
    # RemoteException fatal y aborta el script.
    npm install --silent
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "npm install fallo (exit $LASTEXITCODE)."
        exit 1
    }
    Write-Ok "npm install OK."
} finally {
    Pop-Location
}

# --- 8. Instalar servicio NSSM en modo Auto -------------------------
Write-Step 8 $totalSteps "Instalando el servicio CoopertransMovilBot (NSSM, modo Automatic)..."
$instalarSvc = Join-Path $botDir 'scripts\instalar_servicio.ps1'
if (-not (Test-Path $instalarSvc)) {
    Write-Fail "No existe $instalarSvc - el repo esta corrupto o muy desactualizado."
    exit 1
}
& $instalarSvc -Auto
if ($LASTEXITCODE -ne 0) {
    Write-Fail "instalar_servicio.ps1 fallo (exit $LASTEXITCODE)."
    exit 1
}
Write-Ok "Servicio instalado."

# --- 9. Configurar Windows 24/7 -------------------------------------
Write-Step 9 $totalSteps "Configurando Windows para operacion 24/7..."
$setup247 = Join-Path $botDir 'scripts\setup_pc_24x7.ps1'
if (Test-Path $setup247) {
    & $setup247
    Write-Ok "Power plan + wake-on-lan + ventana de updates configurados."
} else {
    Write-Warn "$setup247 no existe. Skip (no critico)."
}

# --- 10. Instalar auto-update ---------------------------------------
Write-Step 10 $totalSteps "Instalando auto-update del bot (Scheduled Task cada 5 min)..."
$autoUpd = Join-Path $botDir 'scripts\instalar_auto_update.ps1'
if (Test-Path $autoUpd) {
    & $autoUpd
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "instalar_auto_update.ps1 devolvio exit $LASTEXITCODE - revisar a mano."
    } else {
        Write-Ok "Auto-update activo."
    }
} else {
    Write-Warn "$autoUpd no existe. Skip (instalar a mano despues)."
}

# --- 11. Ventana de logs en vivo al inicio (Startup) ----------------
# Crea el shortcut en Startup que abre monitor_logs.ps1 al login. El
# shortcut apunta al script DEL REPO, asi cada reinicio/corte de luz abre
# la ventana con el visor ACTUAL (UTF-8 + "auto-update" despues de la fecha).
Write-Step 11 $totalSteps "Instalando la ventana de logs del bot en el inicio de Windows..."
$instLogs = Join-Path $botDir 'scripts\instalar_monitor_logs.ps1'
if (Test-Path $instLogs) {
    try {
        & $instLogs | Out-Null
        Write-Ok "Ventana de logs del bot: se abre sola al login (UTF-8 + fecha primero)."
    } catch {
        Write-Warn "No pude instalar la ventana de logs del bot: $($_.Exception.Message)"
    }
} else {
    Write-Warn "$instLogs no existe. Skip (instalar a mano con instalar_monitor_logs.ps1)."
}

# --- 12. Smoke test -------------------------------------------------
Write-Step 12 $totalSteps "Smoke test: esperando que el bot heartbeatee..."
Write-Host "  Esperando 60s para que el servicio termine de arrancar..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

$svc = Get-Service -Name CoopertransMovilBot -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Running') {
    Write-Warn "Servicio NO esta Running (status: $($svc.Status)). Revisar logs:"
    Write-Host "    Get-Content $botDir\logs\bot.err.log -Tail 50" -ForegroundColor Gray
} else {
    Write-Ok "Servicio Running."

    # Llamar a bot_estado_remoto.js --json para verificar heartbeat
    $estadoScript = Join-Path $RepoPath 'scripts\bot_estado_remoto.js'
    if (Test-Path $estadoScript) {
        Push-Location $RepoPath
        try {
            $jsonOut = & {
                $ErrorActionPreference = 'Continue'
                & node 'scripts\bot_estado_remoto.js' --json 2>&1
            }
            if ($LASTEXITCODE -eq 0) {
                try {
                    $health = $jsonOut | ConvertFrom-Json
                    Write-Ok "Heartbeat OK. estadoCliente=$($health.estadoCliente), version=$($health.bot.version)"
                } catch {
                    Write-Warn "Heartbeat existe pero no se pudo parsear el JSON: $_"
                }
            } else {
                Write-Warn "bot_estado_remoto.js devolvio exit $LASTEXITCODE - el bot puede no haber escrito heartbeat aun."
            }
        } finally {
            Pop-Location
        }
    }
}

# --- Resumen --------------------------------------------------------
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "INSTALACION COMPLETA" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Que quedo activo en esta PC:" -ForegroundColor Cyan
Write-Host "  - Servicio CoopertransMovilBot (NSSM, Automatic delayed)" -ForegroundColor White
Write-Host "  - Scheduled Task CoopertransMovilBotAutoUpdate (auto-deploy 5 min)" -ForegroundColor White
Write-Host "  - Repo en $RepoPath" -ForegroundColor White
Write-Host ""
Write-Host "Verificaciones utiles:" -ForegroundColor Cyan
Write-Host "  Get-Service CoopertransMovilBot" -ForegroundColor Gray
Write-Host "  Get-ScheduledTask -TaskName CoopertransMovilBotAutoUpdate" -ForegroundColor Gray
Write-Host "  Get-Content $botDir\logs\bot.out.log -Tail 30" -ForegroundColor Gray
Write-Host "  Get-Content $botDir\logs\auto_update.log -Tail 20" -ForegroundColor Gray
Write-Host ""
Write-Host "IMPORTANTE - apagar el bot en la PC vieja:" -ForegroundColor Yellow
Write-Host "  (sino corren 2 en simultaneo y WhatsApp banea el numero)" -ForegroundColor Yellow
Write-Host "  En la PC vieja, PowerShell admin:" -ForegroundColor White
Write-Host "    Stop-Service CoopertransMovilBot" -ForegroundColor White
Write-Host "    Set-Service CoopertransMovilBot -StartupType Manual" -ForegroundColor White
Write-Host ""
