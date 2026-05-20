# Instalador end-to-end del cachatore (vigia 24/7) en la PC dedicada del bot.
# Idempotente: se puede re-correr sin romper nada. Correr COMO ADMINISTRADOR.
#
# Hace de un saque lo que 'git pull' NO trae:
#   1. Verifica/instala Python (la dedicada tiene Node por el bot, no Python).
#   2. Crea el venv e instala curl_cffi + beautifulsoup4 + firebase-admin.
#   3. Deja claves.json (la clave comun de iTurnos).
#   4. Deja drop.json (la seleccion del dia) si no existe.
#   5. Instala el servicio NSSM 'cachatore-vigia' (llama a instalar_servicio_vigia.ps1).
#
# El codigo (vigia.py, etc.) SI viene del git; esto completa el runtime.
#
# Uso (en C:\coopertrans_movil\cachatore, PowerShell admin):
#   .\instalar_todo_cachatore.ps1 -Clave Cooper2022
#   .\instalar_todo_cachatore.ps1                 # sin clave: copia la plantilla y avisa
#   .\instalar_todo_cachatore.ps1 -Clave Cooper2022 -Reinstalar   # recrea el servicio

param(
  [string]$Clave,
  [switch]$Reinstalar
)

$Dir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir    = Join-Path $Dir "venv"
$VenvPy     = Join-Path $VenvDir "Scripts\python.exe"
$ClavesPath = Join-Path $Dir "claves.json"
$DropPath   = Join-Path $Dir "drop.json"
$SakPath    = Join-Path (Split-Path $Dir -Parent) "serviceAccountKey.json"

function Paso($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Ok($msg)       { Write-Host "    OK: $msg" -ForegroundColor Green }
function Aviso($msg)    { Write-Host "    AVISO: $msg" -ForegroundColor Yellow }
function Fail($msg)     { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

function Test-PyCmd($exe, $pre) {
  try {
    $out = & $exe @pre --version 2>$null
    return ($LASTEXITCODE -eq 0 -and "$out" -match "Python 3")
  } catch { return $false }
}
function Find-Python {
  if (Test-PyCmd "py" @("-3"))     { return @("py", "-3") }
  if (Test-PyCmd "python" @())     { return @("python") }
  return $null
}

# --- admin? ---
$esAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $esAdmin) { Fail "Hay que correr esta consola COMO ADMINISTRADOR." }

Write-Host "== Instalador cachatore (vigia 24/7) ==" -ForegroundColor White
Write-Host "   Carpeta: $Dir"

# --- 1) Python ---
Paso 1 "Python"
$py = Find-Python
if (-not $py) {
  Aviso "no encontre Python; lo instalo con winget..."
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail "no hay winget. Instala Python 3 a mano (https://python.org) y re-corre el script."
  }
  winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
  # refrescar PATH del shell actual (winget no lo hace)
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
              [Environment]::GetEnvironmentVariable("Path", "User")
  $py = Find-Python
  if (-not $py) {
    Fail "Python quedo instalado pero no aparece en este shell. Cerra y abri PowerShell de nuevo (admin) y re-corre el script."
  }
}
$PyExe = $py[0]; $PyPre = @(); if ($py.Count -gt 1) { $PyPre = $py[1..($py.Count - 1)] }
Ok ("uso: " + ($py -join " "))

# --- 2) venv + dependencias ---
Paso 2 "Entorno virtual + dependencias"
if (-not (Test-Path $VenvPy)) {
  & $PyExe @PyPre -m venv $VenvDir
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $VenvPy)) { Fail "no pude crear el venv." }
  Ok "venv creado"
} else {
  Ok "venv ya existe"
}
& $VenvPy -m pip install --upgrade pip --quiet
& $VenvPy -m pip install --quiet curl_cffi beautifulsoup4 firebase-admin
if ($LASTEXITCODE -ne 0) { Fail "fallo el pip install de las dependencias." }
Ok "curl_cffi + beautifulsoup4 + firebase-admin instalados"

# --- 3) claves.json (clave comun de iTurnos) ---
Paso 3 "claves.json"
if ($Clave) {
  if (Test-Path $ClavesPath) {
    Aviso "claves.json ya existe; NO lo piso (borralo a mano si queres regenerarlo)."
  } else {
    $json = @{ _comun = $Clave } | ConvertTo-Json
    [System.IO.File]::WriteAllText($ClavesPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Ok "claves.json creado con la clave comun"
  }
} elseif (-not (Test-Path $ClavesPath)) {
  Copy-Item (Join-Path $Dir "claves.ejemplo.json") $ClavesPath
  Aviso "copie la PLANTILLA -> edita claves.json y poni la clave comun (o re-corre con -Clave Cooper2022)."
} else {
  Ok "claves.json ya existe"
}

# --- 4) drop.json (seleccion del dia) ---
# Lo creamos VACIO (sin choferes) a proposito: asi el vigia arranca IDLE y no
# saca turnos para nadie hasta que lo configures. El formato esta en
# drop.ejemplo.json; lo va a escribir la UI de la app.
Paso 4 "drop.json"
if (-not (Test-Path $DropPath)) {
  $dropIdle = "{`n  ""fecha"": null,`n  ""hora_inicio"": ""10:29"",`n  ""duracion_min"": 20,`n  ""poll_latente_seg"": 5,`n  ""choferes"": []`n}`n"
  [System.IO.File]::WriteAllText($DropPath, $dropIdle, (New-Object System.Text.UTF8Encoding($false)))
  Aviso "cree drop.json VACIO (sin choferes = vigia IDLE). Edita drop.json y agrega los choferes (DNI) + franjas; se relee en caliente (no hace falta reiniciar)."
} else {
  Ok "drop.json ya existe (no lo toco)"
}

# --- 5) serviceAccountKey.json (Firestore) ---
Paso 5 "serviceAccountKey.json"
if (Test-Path $SakPath) {
  Ok "presente en la raiz del repo"
} else {
  Aviso "falta $SakPath -> copialo del kit del bot (es el mismo). Sin esto no lee Firestore."
}

# --- 6) servicio NSSM ---
Paso 6 "Servicio NSSM (cachatore-vigia)"
$svc = Join-Path $Dir "instalar_servicio_vigia.ps1"
if (-not (Test-Path $svc)) { Fail "no encuentro instalar_servicio_vigia.ps1 junto a este script." }
if ($Reinstalar) { & $svc -Reinstalar } else { & $svc }

Write-Host "`n== Listo ==" -ForegroundColor Green
Write-Host "Ver el log en vivo:  .\ver_logs_vigia.ps1"
