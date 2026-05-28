# =============================================================================
# Generador del kit instalador del CACHATORE para PC dedicada
# =============================================================================
#
# Analogo al `whatsapp-bot/scripts/preparar_kit_pc_dedicada.ps1`. Genera
# en el Drive una carpeta con TODO lo necesario para levantar el cachatore
# en una PC nueva con 1-click:
#
#   G:\Mi unidad\ClaudeCodeSync\cachatore-pc-dedicada\
#     - instalar_todo.ps1       <- wrapper que: clona repo, copia secrets,
#                                  llama a instalar_todo_cachatore.ps1
#     - claves.json             <- clave comun iTurnos (snapshot al momento
#                                  del kit; backup_secrets_a_drive.ps1 la
#                                  actualiza diario)
#     - serviceAccountKey.json  <- cred Firebase (mismo archivo que el del bot)
#     - LEEME.txt
#
# USO (corre desde la PC origen -- la que tiene el repo + secrets ya OK):
#   .\cachatore\scripts\preparar_kit_pc_dedicada.ps1
#   .\cachatore\scripts\preparar_kit_pc_dedicada.ps1 -DestinoPath "<otro path>"
#
# NOTA encoding: este archivo es ASCII puro a proposito. Idem el heredoc
# del instalador interno que se genera mas abajo. PowerShell 5.1 lee
# UTF-8 sin BOM como Latin-1 y rompe caracteres unicode.

[CmdletBinding()]
param(
    [string]$DestinoPath = 'G:\Mi unidad\ClaudeCodeSync\cachatore-pc-dedicada'
)

$ErrorActionPreference = 'Stop'

# Repo root. Join-Path en PS 5.1 solo acepta 2 args; encadenamos.
$RepoRoot = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$Cachatore = Join-Path $RepoRoot 'cachatore'

Write-Host ""
Write-Host "============================================================"
Write-Host "  GENERAR KIT PC DEDICADA -- CACHATORE"
Write-Host "============================================================"
Write-Host ""
Write-Host "Repo origen: $RepoRoot"
Write-Host "Destino:     $DestinoPath"
Write-Host ""

# --- Verificar archivos origen -----------------------------------
$srcClaves    = Join-Path $Cachatore 'claves.json'
$srcServiceAcc = Join-Path $RepoRoot 'serviceAccountKey.json'

$faltantes = @()
if (-not (Test-Path $srcClaves))     { $faltantes += 'cachatore\claves.json (clave comun iTurnos)' }
if (-not (Test-Path $srcServiceAcc)) { $faltantes += 'serviceAccountKey.json (cred Firebase)' }

if ($faltantes.Count -gt 0) {
    Write-Host "ERROR: faltan archivos origen en la PC actual:" -ForegroundColor Red
    foreach ($f in $faltantes) { Write-Host "  - $f" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Restauralos primero (ver docs/SETUP_PC_DEDICADA_BOT.md) y reintenta." -ForegroundColor Yellow
    exit 1
}

# --- Crear destino -----------------------------------------------
if (-not (Test-Path $DestinoPath)) {
    New-Item -ItemType Directory -Force -Path $DestinoPath | Out-Null
}

# --- 1) Copiar secrets -------------------------------------------
Write-Host "[1/3] Copiando secrets al kit..." -ForegroundColor Cyan
Copy-Item -Path $srcClaves     -Destination (Join-Path $DestinoPath 'claves.json') -Force
Copy-Item -Path $srcServiceAcc -Destination (Join-Path $DestinoPath 'serviceAccountKey.json') -Force
Write-Host "  OK claves.json + serviceAccountKey.json" -ForegroundColor Green

# --- 2) Generar instalar_todo.ps1 --------------------------------
Write-Host "[2/3] Generando instalar_todo.ps1..." -ForegroundColor Cyan
$instalador = @'
# =============================================================================
# Instalador all-in-one -- CACHATORE en PC dedicada
# =============================================================================
# Lo genera `cachatore/scripts/preparar_kit_pc_dedicada.ps1`. NO editar
# a mano -- los cambios reales van en el generador.
#
# Hace TODO desde cero en una PC nueva Windows 10/11:
#   1. Verifica/instala Python 3.11+ y Git (via winget).
#   2. Clona el repo en C:\coopertrans_movil si no existe.
#   3. Copia los secrets del kit al repo.
#   4. Crea venv + instala requirements.
#   5. Registra el servicio NSSM `cachatore-vigia` (Auto + DelayedAutoStart).
#   6. (Opcional) Instala monitor de logs en Startup.
#
# Asume que el bot YA esta instalado o se va a instalar aparte. Ambos
# pueden coexistir en la misma PC dedicada -- uno corre el bot, el otro
# el vigia.
#
# USO:
#   Click derecho sobre instalar_todo.ps1 -> Run with PowerShell
#   (Acepta UAC -- necesita admin para NSSM + auto-update Task)

[CmdletBinding()]
param(
    [string]$RepoUrl  = 'https://github.com/rodriguezreysantiago/logistica_app_profesional.git',
    [string]$RepoPath = 'C:\coopertrans_movil',
    [switch]$SkipMonitorLogs
)

$ErrorActionPreference = 'Stop'

function Step($n, $msg) { Write-Host ""; Write-Host "[$n] $msg" -ForegroundColor Cyan }
function Ok($msg)       { Write-Host "  OK $msg" -ForegroundColor Green }
function Warn($msg)     { Write-Host "  AVISO $msg" -ForegroundColor Yellow }
function Fail($msg)     { Write-Host "  ERROR $msg" -ForegroundColor Red; exit 1 }

# --- Verificar admin ---------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p  = [Security.Principal.WindowsPrincipal]::new($id)
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Este script necesita PowerShell como Administrador. Cerralo y reabrilo con click derecho > 'Ejecutar como administrador'."
}

$KitDir = $PSScriptRoot

# --- 1) Python + Git ---------------------------------------------
Step 1 "Verificando Python 3.11+ y Git..."
$pyOk = $false
try { $v = & python --version 2>&1; if ($v -match '3\.(1[1-9]|[2-9]\d)') { $pyOk = $true } } catch {}
if (-not $pyOk) {
    Warn "Python 3.11+ no encontrado. Instalando con winget..."
    winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { Fail "winget no pudo instalar Python. Instalalo manual de python.org y reintenta." }
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
    Ok "Python instalado"
} else { Ok "Python presente: $v" }

try { git --version | Out-Null; Ok "Git presente" }
catch {
    Warn "Git no encontrado. Instalando con winget..."
    winget install -e --id Git.Git --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { Fail "winget no pudo instalar Git." }
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
    Ok "Git instalado"
}

# --- 2) Clonar repo ----------------------------------------------
Step 2 "Clonando repo en $RepoPath..."
if (Test-Path (Join-Path $RepoPath '.git')) {
    Ok "Repo ya existe -- skip clone"
} else {
    git clone $RepoUrl $RepoPath
    if ($LASTEXITCODE -ne 0) { Fail "git clone fallo" }
    Ok "Repo clonado"
}

# --- 3) Copiar secrets -------------------------------------------
Step 3 "Copiando secrets del kit al repo..."
$kitClaves    = Join-Path $KitDir 'claves.json'
$kitServiceAcc = Join-Path $KitDir 'serviceAccountKey.json'
$dstClaves    = Join-Path $RepoPath 'cachatore\claves.json'
$dstServiceAcc = Join-Path $RepoPath 'serviceAccountKey.json'
if (-not (Test-Path $kitClaves))    { Fail "Falta $kitClaves en el kit." }
if (-not (Test-Path $kitServiceAcc)) { Fail "Falta $kitServiceAcc en el kit." }
Copy-Item -Path $kitClaves    -Destination $dstClaves -Force
Copy-Item -Path $kitServiceAcc -Destination $dstServiceAcc -Force
Ok "claves.json + serviceAccountKey.json copiados"

# --- 4) Llamar al instalador interno del cachatore ---------------
Step 4 "Llamando a instalar_todo_cachatore.ps1 (crea venv + NSSM + auto-update)..."
$instInterno = Join-Path $RepoPath 'cachatore\instalar_todo_cachatore.ps1'
if (-not (Test-Path $instInterno)) { Fail "Falta $instInterno -- repo desactualizado?" }
& $instInterno
if ($LASTEXITCODE -ne 0) { Fail "instalar_todo_cachatore.ps1 fallo (exit $LASTEXITCODE)." }
Ok "Cachatore instalado y servicio registrado"

# --- 5) Opcionales -----------------------------------------------
if (-not $SkipMonitorLogs) {
    Step 5 "Instalando monitor de logs en Startup..."
    $mon = Join-Path $RepoPath 'cachatore\instalar_monitor_logs_vigia.ps1'
    if (Test-Path $mon) {
        & $mon
        if ($LASTEXITCODE -eq 0) { Ok "Monitor de logs instalado" } else { Warn "Monitor fallo (no critico)" }
    } else {
        Warn "instalar_monitor_logs_vigia.ps1 no encontrado en el repo"
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "  OK CACHATORE INSTALADO" -ForegroundColor Green
Write-Host "============================================================"
Write-Host ""
Write-Host "Verifica con:"
Write-Host "  Get-Service cachatore-vigia"
Write-Host ""
'@
Set-Content -Path (Join-Path $DestinoPath 'instalar_todo.ps1') -Value $instalador -Encoding ASCII
Write-Host "  OK instalar_todo.ps1 generado" -ForegroundColor Green

# --- 3) Generar LEEME.txt ----------------------------------------
Write-Host "[3/3] Generando LEEME.txt..." -ForegroundColor Cyan
$fechaSnapshot = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$leeme = @"
============================================================
KIT PC DEDICADA - CACHATORE (sniper de turnos YPF)
============================================================
Snapshot: $fechaSnapshot

Que hay en esta carpeta:
  - instalar_todo.ps1        Instalador AUTOMATICO (1 click).
  - claves.json              Clave comun iTurnos (Cooper2022).
  - serviceAccountKey.json   Credenciales Firebase (admin SDK).
  - LEEME.txt                Este archivo.

============================================================
INSTALAR EN PC NUEVA - 1 click
============================================================

1) Esperar que Drive sincronice esta carpeta entera.

2) Click derecho sobre instalar_todo.ps1 -> Run with PowerShell.
   (Aceptar UAC - necesita privilegios de admin para registrar
    el servicio NSSM y la Scheduled Task de auto-update.)

3) El script hace TODO esto solo (5-10 min):
   - Verifica/instala Python 3.11+ y Git (via winget).
   - Clona el repo en C:\coopertrans_movil.
   - Copia claves.json + serviceAccountKey.json al repo.
   - Crea venv + instala requirements del cachatore.
   - Registra el servicio NSSM 'cachatore-vigia' en Automatic
     DelayedAutoStart (arranca solo despues del boot).
   - Instala el monitor de logs en Startup.

4) Validar:
   Get-Service cachatore-vigia

============================================================
COMBO CON BOT WHATSAPP
============================================================

El kit del BOT WHATSAPP vive aparte en:
  G:\Mi unidad\ClaudeCodeSync\bot-pc-dedicada\

En una PC dedicada NUEVA: corre ambos instaladores (bot primero,
cachatore despues). Los dos servicios coexisten sin problema en
la misma PC dedicada.

============================================================
ACTUALIZACION AUTOMATICA
============================================================

El cachatore tiene auto-update cada 5 minutos (ver
scripts/auto_update.ps1) que pulea git y reinicia el servicio
si tocaron archivos de cachatore/. Esto significa que cualquier
PC dedicada se mantiene al dia sin intervencion.

============================================================
"@
Set-Content -Path (Join-Path $DestinoPath 'LEEME.txt') -Value $leeme -Encoding ASCII
Write-Host "  OK LEEME.txt generado" -ForegroundColor Green

Write-Host ""
Write-Host "============================================================"
Write-Host "  KIT GENERADO" -ForegroundColor Green
Write-Host "============================================================"
Write-Host ""
$tam = (Get-ChildItem $DestinoPath -Recurse | Measure-Object -Property Length -Sum).Sum / 1KB
Write-Host "Contenido (~$([math]::Round($tam, 1)) KB):"
Get-ChildItem $DestinoPath | ForEach-Object {
    $sz = if ($_.PSIsContainer) { '(dir)' } else { "$([math]::Round($_.Length / 1KB, 1)) KB" }
    Write-Host "  $($_.Name)  -  $sz"
}
Write-Host ""
Write-Host "El kit ya esta sincronizado al Drive. Para instalar en PC nueva,"
Write-Host "esperar que la sync termine y seguir LEEME.txt." -ForegroundColor DarkGray
