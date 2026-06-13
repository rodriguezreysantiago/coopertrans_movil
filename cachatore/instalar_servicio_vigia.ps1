# Instala/actualiza el vigia 24/7 del cachatore como servicio de Windows (NSSM)
# en la PC dedicada del bot. Correr en PowerShell COMO ADMINISTRADOR.
#
# Mismo patron que el servicio del bot de WhatsApp: NSSM + Auto (arranque
# diferido) + log rotado. El servicio queda prendido 24/7 y arranca solo al
# bootear la PC (junto con el auto-login de Windows).
#
# Prerequisitos en la PC dedicada (NO vienen del git, hay que ponerlos a mano):
#   - venv creado en cachatore\venv con: curl_cffi beautifulsoup4 firebase-admin
#   - serviceAccountKey.json en la raiz del repo (un nivel arriba de cachatore)
#   - cachatore\claves.json con la clave comun (Cooper2022)
#   - cachatore\drop.json con la seleccion del dia (o lo escribe la UI)
#
# Uso:
#   .\instalar_servicio_vigia.ps1
#   .\instalar_servicio_vigia.ps1 -Reinstalar   # borra y recrea el servicio

param([switch]$Reinstalar)

# OJO: NO usar 'Stop' global. nssm escribe a stderr (ej. "Can't open service!"
# cuando el servicio no existe) y en PS 5.1 ese stderr se vuelve NativeCommandError
# y aborta el script. Manejamos errores a mano (Fail) y chequeamos existencia con
# Get-Service (cmdlet, no native).
$ErrorActionPreference = "Continue"
$Servicio = "cachatore-vigia"
$Dir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Python   = Join-Path $Dir "venv\Scripts\python.exe"
$Script   = "vigia.py"
$LogsDir  = Join-Path $Dir "logs"
$LogFile  = Join-Path $LogsDir "vigia.log"

# Master del env extra del servicio (Healthchecks ping URL, etc). Drive primero
# (editable desde cualquier PC), fallback local. Ver service.env.example.
$DriveServiceEnv = "G:\Mi unidad\ClaudeCodeSync\secrets\cachatore\service.env"
$LocalServiceEnv = Join-Path $Dir "service.env"

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# --- admin? ---
$esAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $esAdmin) { Fail "Hay que correr esta consola COMO ADMINISTRADOR." }

# --- nssm en el PATH? ---
$nssm = (Get-Command nssm.exe -ErrorAction SilentlyContinue).Source
if (-not $nssm) {
  foreach ($p in @("C:\nssm\nssm.exe", "C:\Program Files\nssm\nssm.exe",
                   "C:\ProgramData\chocolatey\bin\nssm.exe")) {
    if (Test-Path $p) { $nssm = $p; break }
  }
}
if (-not $nssm) { Fail "No encontre nssm.exe (el mismo que usa el bot). Instalalo o agregalo al PATH." }

# --- prerequisitos ---
if (-not (Test-Path $Python)) {
  Fail "No existe el venv: $Python`n  Crealo:  python -m venv venv ; venv\Scripts\pip install curl_cffi beautifulsoup4 firebase-admin"
}
$sak = Join-Path (Split-Path -Parent $Dir) "serviceAccountKey.json"
if (-not (Test-Path $sak))                       { Write-Host "AVISO: falta serviceAccountKey.json en la raiz del repo ($sak)" -ForegroundColor Yellow }
if (-not (Test-Path (Join-Path $Dir "claves.json"))) { Write-Host "AVISO: falta cachatore\claves.json (la clave comun)" -ForegroundColor Yellow }
if (-not (Test-Path (Join-Path $Dir "drop.json")))   { Write-Host "AVISO: falta cachatore\drop.json (la seleccion del dia)" -ForegroundColor Yellow }

New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

# --- recrear si se pidio (Get-Service evita el stderr de nssm que aborta en PS 5.1) ---
$existe = Get-Service -Name $Servicio -ErrorAction SilentlyContinue
if ($existe -and $Reinstalar) {
  Write-Host "Borrando servicio existente para recrearlo..." -ForegroundColor Yellow
  & $nssm stop   $Servicio 2>$null | Out-Null
  & $nssm remove $Servicio confirm | Out-Null
  Start-Sleep -Seconds 1
  $existe = $null
}

if (-not $existe) {
  Write-Host "Instalando servicio '$Servicio'..." -ForegroundColor Cyan
  & $nssm install $Servicio $Python $Script
} else {
  Write-Host "El servicio ya existe; actualizo su configuracion..." -ForegroundColor Cyan
  & $nssm stop $Servicio 2>$null | Out-Null
  & $nssm set $Servicio Application $Python
  & $nssm set $Servicio AppParameters $Script
}

& $nssm set $Servicio AppDirectory   $Dir
& $nssm set $Servicio DisplayName     "Cachatore - sniper de turnos YPF (vigia 24/7)"
& $nssm set $Servicio Description      "Caza/reserva/reagenda turnos de carga YPF en iTurnos las 24 hs."
& $nssm set $Servicio Start            SERVICE_DELAYED_AUTO_START
& $nssm set $Servicio AppStdout        $LogFile
& $nssm set $Servicio AppStderr        $LogFile
& $nssm set $Servicio AppRotateFiles   1
& $nssm set $Servicio AppRotateOnline  1
& $nssm set $Servicio AppRotateBytes   5242880      # rota a los ~5 MB
& $nssm set $Servicio AppStopMethodConsole 5000     # Ctrl-C ordenado antes de matar
& $nssm set $Servicio AppExit Default Restart       # si se cae, reinicia
& $nssm set $Servicio AppRestartDelay 5000

# --- Env extra (Healthchecks ping URL, etc) en AppEnvironmentExtra -----------
# Se lee del master (Drive primero, fallback local) y se aplica en CADA install
# o -Reinstalar. Asi un reinstall NUNCA apaga el monitoreo en silencio: si el
# master falta, AVISA fuerte (no queda mudo). AppEnvironmentExtra REEMPLAZA el
# bloque entero, pero el vigia no tiene otras env extra -> es seguro.
$envSrc = $null
if     (Test-Path -LiteralPath $DriveServiceEnv) { $envSrc = $DriveServiceEnv }
elseif (Test-Path -LiteralPath $LocalServiceEnv) { $envSrc = $LocalServiceEnv }

if ($envSrc) {
  $pares  = @()
  $claves = @()
  foreach ($linea in (Get-Content -LiteralPath $envSrc -Encoding UTF8)) {
    $l = $linea.Trim()
    if ($l -eq '' -or $l.StartsWith('#')) { continue }
    $eq = $l.IndexOf('=')
    if ($eq -lt 1) {                       # sin '=' o '=' al inicio -> malformada
      Write-Host "AVISO: linea ignorada en service.env (sin KEY=): '$l'" -ForegroundColor Yellow
      continue
    }
    $k = $l.Substring(0, $eq).Trim()
    $v = $l.Substring($eq + 1).Trim()
    if ($k) { $pares += "$k=$v"; $claves += $k }
  }
  if ($pares.Count -gt 0) {
    # Array -> PowerShell expande cada "KEY=VALUE" como arg posicional (forma
    # multi-valor de NSSM). Values con espacios NO estan blindados (las URLs/
    # tokens no llevan), pero VERIFICAMOS el resultado abajo por las dudas.
    & $nssm set $Servicio AppEnvironmentExtra $pares | Out-Null
    Write-Host ("AppEnvironmentExtra: " + $pares.Count + " var(s) desde $envSrc") -ForegroundColor Green

    # Read-back: confirmar que NSSM persistio CADA clave (no confiar a ciegas:
    # algunas versiones de nssm descartan args multi-valor en silencio).
    $persistido = (& $nssm get $Servicio AppEnvironmentExtra 2>$null | Out-String)
    $faltan = @()
    foreach ($c in $claves) {
      if ($persistido -notmatch ('(?m)^\s*' + [regex]::Escape($c) + '\s*=')) { $faltan += $c }
    }
    if ($faltan.Count -gt 0) {
      Write-Host "*** AVISO MONITOREO: nssm NO persistio: $($faltan -join ', ')" -ForegroundColor Red
      Write-Host "    El dead-man's switch puede quedar PARCIAL/APAGADO. Seteala a mano:" -ForegroundColor Red
      Write-Host "      nssm set $Servicio AppEnvironmentExtra <KEY=VALUE>" -ForegroundColor Red
    } else {
      foreach ($c in $claves) { Write-Host ("    OK $c=<set>") -ForegroundColor DarkGray }
    }
  } else {
    Write-Host "AVISO: $envSrc existe pero no tiene lineas KEY=VALUE; no toco AppEnvironmentExtra." -ForegroundColor Yellow
  }
} else {
  Write-Host ""
  Write-Host "***************************************************************" -ForegroundColor Red
  Write-Host "*** AVISO MONITOREO: no encontre service.env (Drive ni local)." -ForegroundColor Red
  Write-Host "*** El vigia queda SIN HEALTHCHECKS_PING_URL_VIGIA:"            -ForegroundColor Red
  Write-Host "*** dead-man's switch EXTERNO APAGADO (caida silenciosa)."      -ForegroundColor Red
  Write-Host "*** Crealo en: $DriveServiceEnv"                                -ForegroundColor Red
  Write-Host "***   HEALTHCHECKS_PING_URL_VIGIA=https://hc-ping.com/<uuid>"   -ForegroundColor Red
  Write-Host "***   (plantilla: cachatore\service.env.example)"              -ForegroundColor Red
  Write-Host "***************************************************************" -ForegroundColor Red
}

& $nssm start $Servicio 2>$null | Out-Null
Start-Sleep -Seconds 2
$estado = (Get-Service -Name $Servicio -ErrorAction SilentlyContinue).Status
Write-Host ""
Write-Host "Estado: $estado" -ForegroundColor Green
Write-Host "Log:    $LogFile"
# nssm puede no estar en el PATH; los cmdlets nativos siempre funcionan
# (un servicio NSSM es un servicio de Windows normal).
Write-Host "Ver en vivo:    .\ver_logs_vigia.ps1"
Write-Host "Reiniciar:      Restart-Service $Servicio"
Write-Host "Parar/arrancar: Stop-Service $Servicio  /  Start-Service $Servicio"
Write-Host "Desinstalar:    Stop-Service $Servicio; sc.exe delete $Servicio"
