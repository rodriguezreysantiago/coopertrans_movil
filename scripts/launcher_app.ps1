# Launcher de Coopertrans Movil - chequea GitHub Releases (via API
# publica, sin auth ni gh CLI), baja la version nueva si hay, y lanza
# la app.
#
# El icono "Coopertrans Movil" del escritorio apunta a este script.
# El operador hace doble click -> si hay update se actualiza solo ->
# arranca la app. Sin ir PC por PC copiando archivos.
#
# Como el repo es PUBLICO, no hace falta instalar gh CLI ni autenticar
# nada. Usa Invoke-RestMethod / Invoke-WebRequest directos contra la
# API publica de GitHub. Cero setup en cada PC, solo bajar este archivo.
#
# Ubicaciones (por usuario, NO requiere admin):
#   - Instalacion de la app: %LOCALAPPDATA%\CoopertransMovil\
#   - Ejecutable:             %LOCALAPPDATA%\CoopertransMovil\coopertrans_movil.exe
#   - Version instalada:      %LOCALAPPDATA%\CoopertransMovil\VERSION.txt
#   - Log de updates:         %LOCALAPPDATA%\CoopertransMovil\update.log

$ErrorActionPreference = 'Stop'

# === CONFIG ========================================================
$repo    = 'rodriguezreysantiago/coopertrans_movil'
$exeName = 'coopertrans_movil.exe'

# Install dir con auto-deteccion:
#   - ProgramData\CoopertransMovil  -> si fue creado por el instalador
#     Inno Setup (con permisos users-modify para que el launcher pueda
#     actualizar sin UAC). Una sola copia compartida entre todos los
#     usuarios de la PC.
#   - LOCALAPPDATA\CoopertransMovil -> fallback para modo "sin instalador"
#     (correr el launcher directo desde el repo en una PC dev).
$installDir = if (Test-Path (Join-Path $env:ProgramData 'CoopertransMovil')) {
    Join-Path $env:ProgramData 'CoopertransMovil'
} else {
    Join-Path $env:LOCALAPPDATA 'CoopertransMovil'
}
$logFile = Join-Path $installDir 'update.log'
$exePath = Join-Path $installDir $exeName
$verFile = Join-Path $installDir 'VERSION.txt'

# GitHub requiere User-Agent en cualquier request a la API.
$apiHeaders = @{
    'User-Agent' = 'CoopertransMovil-Launcher'
    'Accept'     = 'application/vnd.github+json'
}

# === HELPERS =======================================================
# Tolerar fallas de log (-EA SilentlyContinue + try/catch): caso reportado
# Santiago 2026-06-09 — el update.log del InstallDir habia sido creado
# alguna vez con permisos de SYSTEM (heredados de archivos Inno) y el
# Add-Content moria con "Acceso denegado" en la PRIMERA linea de Log con
# $ErrorActionPreference='Stop' implicito. El launcher ni siquiera llegaba
# a chequear si habia update. Ahora el log es best-effort: si no puede
# escribir, sigue corriendo. (Para evitar que vuelva a pasar, el rewrite
; per-user del .iss 2026-06-09 instala en %LOCALAPPDATA% sin permisos
# heredados de SYSTEM; este try/catch es defensa en profundidad.)
function Log {
    param([string]$Msg, [string]$Color = 'White')
    Write-Host $Msg -ForegroundColor $Color
    try {
        if (Test-Path $installDir) {
            $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Add-Content -Path $logFile -Value "[$ts] $Msg" -Encoding UTF8 -ErrorAction Stop
        }
    } catch {
        # No podemos escribir al log — no critico, seguimos. La salida por
        # Write-Host arriba ya quedo (visible si alguien ejecuta el launcher
        # interactivo). El logFile roto se va a regenerar despues de un
        # update / reinstall.
    }
}

# Asegura que el shortcut del escritorio tome el icono EMBEBIDO del
# .exe (auto-se-actualiza con cada release) en vez del .ico estatico
# que el instalador Inno Setup deja en Program Files (que requiere
# re-correr el instalador con UAC para cambiar).
#
# Idempotente: si el IconLocation ya apunta al .exe, no hace nada.
# Si apunta al .ico viejo de Program Files, lo corrige y limpia el
# cache de iconos de Windows. Cubre dos caminos:
#   - Shortcut publico: %PUBLIC%\Desktop (Inno Setup como admin)
#   - Shortcut por usuario: %USERPROFILE%\Desktop (si lo copiaron)
#
# Pedido Santiago 2026-05-19: "se puede meter en una actualizacion
# automatica asi cambia para todas las pc?". Esta es la respuesta —
# cada vez que el launcher corre, refresca el shortcut.
function Refrescar-IconoEscritorio {
    param([string]$ExePath)
    if (-not (Test-Path $ExePath)) { return }
    try {
        $expectedIcon = "$ExePath,0"
        $candidatos = @(
            (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Coopertrans Movil.lnk'),
            (Join-Path "$env:PUBLIC\Desktop" 'Coopertrans Movil.lnk')
        )
        $shell = New-Object -ComObject WScript.Shell
        $algunRefrescado = $false
        foreach ($lnk in $candidatos) {
            if (-not (Test-Path $lnk)) { continue }
            try {
                $sc = $shell.CreateShortcut($lnk)
                if ($sc.IconLocation -ne $expectedIcon) {
                    $sc.IconLocation = $expectedIcon
                    $sc.Save()
                    Log "Shortcut icono refrescado: $lnk" 'Green'
                    $algunRefrescado = $true
                }
            } catch {
                Log "No pude tocar $lnk : $($_.Exception.Message)" 'Yellow'
            }
        }
        # Refrescar SIEMPRE el cache de iconos, no solo cuando cambia el
        # IconLocation del shortcut. Al salir un release con icono nuevo, el
        # .exe cambia de CONTENIDO pero sigue en el mismo path -> el
        # IconLocation no cambia aunque el icono SI, y Windows muestra el
        # viejo cacheado. ie4uinit -show invalida el cache sin matar explorer
        # (no disruptivo). Nota: $algunRefrescado puede ser $false aca y esta
        # bien (el shortcut publico es read-only para el user sin admin, asi
        # que el Save de arriba suele fallar; igual queremos refrescar).
        # El refresco PRINCIPAL lo hace la app al arrancar (1 vez por version,
        # core/window/refrescar_icono_escritorio.dart); esto es defensa en
        # profundidad para instalaciones nuevas via el instalador.
        try {
            $ie4 = "$env:WINDIR\System32\ie4uinit.exe"
            if (Test-Path $ie4) {
                Start-Process -FilePath $ie4 -ArgumentList '-show' -WindowStyle Hidden -Wait
            }
        } catch {
            # Best-effort — si falla, el nuevo icono aparece despues
            # de cerrar/abrir explorer o reboot. No es bloqueante.
        }
    } catch {
        Log "Refrescar-IconoEscritorio fallo: $($_.Exception.Message)" 'Yellow'
    }
}

function Lanzar-App {
    if (-not (Test-Path $exePath)) {
        Log "ERROR: no existe $exePath. El update inicial debe completarse primero." 'Red'
        Read-Host "Enter para cerrar"
        exit 1
    }
    # Idempotente — solo escribe el .lnk si el icono no estaba apuntando
    # al .exe. Cuesta ~10ms si ya esta OK.
    Refrescar-IconoEscritorio -ExePath $exePath
    Log "Lanzando $exeName..." 'Cyan'
    Start-Process -FilePath $exePath -WorkingDirectory $installDir
}

# === 1. La app ya esta corriendo? =================================
$running = Get-Process -Name ($exeName -replace '\.exe$') -ErrorAction SilentlyContinue
if ($running) {
    Log "La app ya esta corriendo (PID $($running[0].Id)). No actualizo." 'Yellow'
    Log "Cerra la app antes para chequear updates." 'Yellow'
    Start-Sleep -Seconds 2
    exit 0
}

# === 2. Crear installDir si no existe (primer arranque) ===========
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Log "Primer arranque - voy a bajar la ultima release." 'Cyan'
}

# === 3. Chequear ultima release via GitHub API publica ============
Log "Chequeando ultima release en GitHub..." 'Cyan'

$latest = $null
try {
    $latest = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$repo/releases/latest" `
        -Headers $apiHeaders `
        -TimeoutSec 15
} catch {
    Log "No pude consultar GitHub (capaz sin red): $($_.Exception.Message)" 'Yellow'
    Log "Lanzo version local sin chequear updates." 'Yellow'
    Lanzar-App
    exit 0
}

$tagRemoto = $latest.tag_name              # ej "v1.0.0+1"
$versionRemota = $tagRemoto -replace '^v', ''

$versionLocal = if (Test-Path $verFile) {
    (Get-Content $verFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
} else { '' }

Log "Version local:  $(if ($versionLocal) { $versionLocal } else { '(ninguna instalada)' })" 'White'
Log "Version remota: $versionRemota" 'White'

if ($versionLocal -eq $versionRemota) {
    Log "Estas al dia. Lanzando app." 'Green'
    Lanzar-App
    exit 0
}

# === 4. Hay version nueva - bajar e instalar ======================
Log "" 'White'
Log "Hay version nueva disponible: $versionRemota" 'Cyan'

$asset = $latest.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
if (-not $asset) {
    Log "ERROR: el release $tagRemoto no tiene asset .zip. Lanzo version local." 'Red'
    Lanzar-App
    exit 1
}

Log "Descargando $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..." 'Cyan'

$tempDir   = Join-Path $env:TEMP "CoopertransMovil_update_$(Get-Random)"
$backupDir = $null
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

try {
    $zipPath = Join-Path $tempDir $asset.name
    Invoke-WebRequest `
        -Uri $asset.browser_download_url `
        -OutFile $zipPath `
        -Headers $apiHeaders `
        -TimeoutSec 300

    $stagingDir = Join-Path $tempDir 'staging'
    Log "Extrayendo..." 'Cyan'
    Expand-Archive -Path $zipPath -DestinationPath $stagingDir -Force

    if (-not (Test-Path (Join-Path $stagingDir $exeName))) {
        throw "El zip no contiene $exeName en la raiz"
    }

    # Backup atomico de la version actual (si existia algo instalado).
    if (Test-Path (Join-Path $installDir $exeName)) {
        # Limpieza preventiva ANTES del Move: el crashpad de Sentry crea
        # %InstallDir%\.sentry-native\<UUID>.run\session.json mientras la app
        # corre. Si la app no cerro bien (crash, kill, alt-F4 forzado), esos
        # archivos quedan con permisos restringidos del proceso crashpad y
        # bloquean el Move-Item del backup. Borrarlos antes nos saca ese pie
        # de la trampa. -EA SilentlyContinue: si no hay nada, no pasa nada.
        Remove-Item -Path (Join-Path $installDir '.sentry-native') -Recurse -Force -ErrorAction SilentlyContinue

        $backupDir = "$installDir.bak"
        if (Test-Path $backupDir) { Remove-Item $backupDir -Recurse -Force }
        Log "Backup de version actual..." 'Cyan'
        Move-Item -Path $installDir -Destination $backupDir
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    }

    Log "Instalando $versionRemota..." 'Cyan'
    Copy-Item -Path "$stagingDir\*" -Destination $installDir -Recurse -Force

    if (-not (Test-Path $verFile)) {
        Set-Content -Path $verFile -Value $versionRemota -Encoding UTF8
    }

    Log "OK Actualizado a $versionRemota" 'Green'
} catch {
    Log "ERROR durante el update: $($_.Exception.Message)" 'Red'
    if ($backupDir -and (Test-Path $backupDir)) {
        Log "Restaurando version anterior..." 'Yellow'
        if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
        Move-Item -Path $backupDir -Destination $installDir
    }
} finally {
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# === 5. Lanzar app =================================================
Lanzar-App
