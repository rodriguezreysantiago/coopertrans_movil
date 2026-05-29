# Release completo en 1 comando: bump + build Windows + instalador +
# push + GitHub Release + AAB Android.
#
# Pensado para que NO te quedes colgado en ningún paso. Cada paso
# valida que el anterior haya completado antes de seguir.
#
# Uso:
#   .\scripts\release_completo.ps1                  # bump patch+1+build+1
#   .\scripts\release_completo.ps1 -Version 1.2.3+45   # versión explícita
#   .\scripts\release_completo.ps1 -SkipAndroid     # solo Windows
#   .\scripts\release_completo.ps1 -SkipWeb         # no actualiza la web
#   .\scripts\release_completo.ps1 -SkipLocalUpdate # no actualiza tu PC
#   .\scripts\release_completo.ps1 -DryRun          # muestra qué haría
#
# Flujo:
#   1. Verifica que el repo esté limpio (no commits perdidos).
#   2. bump_version.ps1 (pubspec + AppTexts.appVersion + main.cpp).
#   3. git add + commit del bump.
#   4. flutter build windows --release.
#   5. build_installer.ps1 (Inno Setup, .exe firmado).
#   6. git push (incluye el bump y todo lo previo).
#   7. release_app.ps1 (zip + .exe → GitHub Release, auto-update Win).
#   8. release_android.ps1 -PlayStore (AAB para Play Console).
#   9. App web: flutter build web + subir SOLO /sistema por FTP a
#      cooper-trans.com.ar/sistema/ (best-effort: si falla o no está el
#      proyecto web/credenciales en esta PC, avisa y NO corta el release).
#  10. Forzar update local en esta PC (cierra la app, borra
#      VERSION.txt, lanza el launcher para que baje la nueva).
#  11. Imprime instrucciones para subir el AAB a Play Console.
#
# Si querés republicar el MISMO tag (no bumpear), usá `release_app.ps1`
# directo — ese script ya maneja la republicación.

param(
    [string]$Version = '',
    [switch]$SkipAndroid,
    [switch]$SkipWeb,
    [switch]$SkipLocalUpdate,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$webStatus = 'no ejecutado'   # estado del deploy web, se reporta al final

function Invoke-Native {
    param([scriptblock]$Block)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Block } finally { $ErrorActionPreference = $prev }
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  RELEASE COMPLETO" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# ─── 1. Verificar estado git ──────────────────────────────────────
Push-Location $repoRoot
try {
    $dirty = Invoke-Native { git status --porcelain }
    if ($dirty) {
        Write-Host "ADVERTENCIA: hay cambios sin commitear:" -ForegroundColor Yellow
        Write-Host $dirty
        Write-Host ""
        $confirm = Read-Host "¿Commitearlos antes del bump? (S/n)"
        if ($confirm -ne 'n' -and $confirm -ne 'N') {
            Write-Host "Commiteando cambios pendientes..." -ForegroundColor Cyan
            if (-not $DryRun) {
                Invoke-Native { git add -A }
                Invoke-Native { git commit -m "chore: cambios previos al release" }
                if ($LASTEXITCODE -ne 0) { throw "git commit fallo" }
            }
        }
    }
}
finally { Pop-Location }

# ─── 2. Bump de versión ───────────────────────────────────────────
Write-Host ""
Write-Host "[1/8] Bump de versión..." -ForegroundColor Cyan
$bumpScript = Join-Path $repoRoot 'scripts\bump_version.ps1'
if (-not (Test-Path $bumpScript)) {
    throw "No encuentro $bumpScript"
}
# Splat por hashtable. Antes era array (`@('-Version', $Version)`)
# pero PowerShell lo pasaba como string posicional en lugar de
# parámetro nombrado — bump_version.ps1 leía `-Version` como el valor
# de su primer param y reventaba con "Version nueva '-Version' no
# respeta MAJOR.MINOR.PATCH+BUILD". Hashtable splat sí pasa los
# nombres correctamente. Bug fixeado 2026-05-13.
$bumpArgs = @{}
if ($Version -ne '') { $bumpArgs['Version'] = $Version }
if ($DryRun) { $bumpArgs['DryRun'] = $true }

if ($bumpArgs.Count -gt 0) {
    & $bumpScript @bumpArgs
} else {
    & $bumpScript
}
if ($LASTEXITCODE -ne 0) { throw "bump_version.ps1 fallo" }

if ($DryRun) {
    Write-Host ""
    Write-Host "[DRY-RUN] No se commitea, no se buildea, no se publica." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# ─── 3. Commit del bump ──────────────────────────────────────────
Push-Location $repoRoot
try {
    $pubLines = Get-Content (Join-Path $repoRoot 'pubspec.yaml')
    $verLine = $pubLines | Where-Object { $_ -match '^version:\s*(\S+)' } | Select-Object -First 1
    $newVersion = ($verLine -replace '^version:\s*', '').Trim()

    Write-Host ""
    Write-Host "[2/8] Commit del bump $newVersion..." -ForegroundColor Cyan
    Invoke-Native { git add pubspec.yaml lib/core/constants/app_constants.dart windows/runner/main.cpp }
    Invoke-Native { git commit -m "chore: bump version $newVersion" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "(no había cambios para commitear, capaz ya estaba bumpeado)" -ForegroundColor DarkGray
    }
}
finally { Pop-Location }

# ─── 4. Build Windows ─────────────────────────────────────────────
Write-Host ""
Write-Host "[3/8] flutter build windows --release..." -ForegroundColor Cyan
Push-Location $repoRoot
try {
    Invoke-Native { & flutter build windows --release }
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows fallo" }
}
finally { Pop-Location }

# ─── 5. Instalador Windows ───────────────────────────────────────
Write-Host ""
Write-Host "[4/8] build_installer.ps1..." -ForegroundColor Cyan
$installerScript = Join-Path $repoRoot 'scripts\build_installer.ps1'
& $installerScript
if ($LASTEXITCODE -ne 0) { throw "build_installer.ps1 fallo" }

# ─── 6. Push (release_app.ps1 también pushea, pero nos aseguramos)
Write-Host ""
Write-Host "[5/8] git push..." -ForegroundColor Cyan
Push-Location $repoRoot
try {
    Invoke-Native { git push }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "AVISO: git push devolvio $LASTEXITCODE — capaz Push Protection" -ForegroundColor Yellow
        Write-Host "      (secrets en commits). Resolvelo en GitHub web y reintentar." -ForegroundColor Yellow
        throw "git push fallo"
    }
}
finally { Pop-Location }

# ─── 7. GitHub Release (auto-update Windows) ─────────────────────
Write-Host ""
Write-Host "[6/8] release_app.ps1 (GitHub Release Windows)..." -ForegroundColor Cyan
$releaseAppScript = Join-Path $repoRoot 'scripts\release_app.ps1'
& $releaseAppScript
if ($LASTEXITCODE -ne 0) { throw "release_app.ps1 fallo" }

# ─── 8. AAB Android ──────────────────────────────────────────────
if (-not $SkipAndroid) {
    Write-Host ""
    Write-Host "[7/8] release_android.ps1 -PlayStore (AAB)..." -ForegroundColor Cyan
    $releaseAndroidScript = Join-Path $repoRoot 'scripts\release_android.ps1'
    & $releaseAndroidScript -PlayStore
    if ($LASTEXITCODE -ne 0) { throw "release_android.ps1 fallo" }
}

# ─── 8b. App web -> cooper-trans.com.ar/sistema/ ─────────────────
# Best-effort: compila la app a web y sube SOLO /sistema por FTP. Si
# algo falla (sin proyecto web / sin credenciales / FTP caido), avisa
# y sigue — el release de Windows/Android ya quedó publicado y NO se
# debe abortar por la web.
if (-not $SkipWeb) {
    Write-Host ""
    Write-Host "[WEB] App web -> https://cooper-trans.com.ar/sistema/ ..." -ForegroundColor Cyan

    $webRoot  = Join-Path (Split-Path $repoRoot -Parent) 'web_coopertrans'
    $sitioApp = Join-Path $webRoot 'sitio_nuevo\sistema'
    $subirPy  = Join-Path $webRoot '_subir_sitio.py'

    # Credenciales FTP: priorizamos el Drive (G:/Mi unidad/ClaudeCodeSync)
    # para que cualquier PC con el Drive sincronizado pueda hacer release
    # sin pasos manuales de restauración. Fallback al Desktop por compat
    # con PCs que ya las tienen ahí desde antes del setup multi-PC.
    $ftpCredsDrive   = 'G:\Mi unidad\ClaudeCodeSync\secrets\ftp\ftp_datos.txt'
    $ftpCredsDesktop = Join-Path $env:USERPROFILE 'Desktop\ftp_datos.txt'
    $ftpCreds = $null
    if (Test-Path $ftpCredsDrive)        { $ftpCreds = $ftpCredsDrive }
    elseif (Test-Path $ftpCredsDesktop)  { $ftpCreds = $ftpCredsDesktop }

    if (-not (Test-Path $subirPy)) {
        Write-Host "  AVISO: no encuentro $subirPy" -ForegroundColor Yellow
        Write-Host "  Salteo el deploy web (esta PC no tiene el proyecto web)." -ForegroundColor DarkGray
        $webStatus = 'salteado (sin proyecto web en esta PC)'
    }
    elseif (-not $ftpCreds) {
        Write-Host "  AVISO: no encuentro credenciales FTP." -ForegroundColor Yellow
        Write-Host "    Busque en:" -ForegroundColor DarkGray
        Write-Host "      $ftpCredsDrive" -ForegroundColor DarkGray
        Write-Host "      $ftpCredsDesktop" -ForegroundColor DarkGray
        Write-Host "  Salteo el deploy web." -ForegroundColor DarkGray
        $webStatus = 'salteado (sin credenciales FTP)'
    }
    else {
        try {
            # 1) Build web con base-href /sistema/ (PowerShell pasa la ruta
            #    literal; NO usar git-bash que la mangle a C:/Program Files/Git/).
            #    --no-wasm-dry-run: la app compila a JS, no a WebAssembly. El dry-run
            #    de wasm solo tira warnings por incompatibilidades en deps de terceros
            #    (ej. package `image`) que no nos afectan. Lo apagamos para no ensuciar el log.
            Write-Host "  Compilando flutter web..." -ForegroundColor DarkGray
            Push-Location $repoRoot
            try {
                Invoke-Native { & flutter build web --release --base-href /sistema/ --no-wasm-dry-run }
                if ($LASTEXITCODE -ne 0) { throw "flutter build web fallo (exit $LASTEXITCODE)" }
            }
            finally { Pop-Location }

            # 2) Copiar build/web -> sitio_nuevo/sistema (overwrite; preserva
            #    el .htaccess del SPA que no viene en el build).
            Write-Host "  Copiando build/web a la carpeta del sitio..." -ForegroundColor DarkGray
            $buildWeb = Join-Path $repoRoot 'build\web'
            New-Item -ItemType Directory -Force -Path $sitioApp | Out-Null
            Copy-Item (Join-Path $buildWeb '*') $sitioApp -Recurse -Force

            # 3) Subir SOLO /sistema por FTP (no re-sube el sitio de marketing).
            Write-Host "  Subiendo por FTP (solo /sistema)..." -ForegroundColor DarkGray
            Push-Location $webRoot
            try {
                Invoke-Native { & python $subirPy sistema }
                if ($LASTEXITCODE -ne 0) { throw "subida FTP fallo (exit $LASTEXITCODE)" }
            }
            finally { Pop-Location }

            Write-Host "  OK app web actualizada." -ForegroundColor Green
            $webStatus = 'OK'
        }
        catch {
            Write-Host "  AVISO: el deploy web fallo: $_" -ForegroundColor Yellow
            Write-Host "  (El release de Windows/Android NO se ve afectado.)" -ForegroundColor DarkGray
            $webStatus = "FALLO: $_"
        }
    }
}
else {
    $webStatus = 'salteado (-SkipWeb)'
}

# ─── 9. Forzar update local en esta PC ───────────────────────────
# Cierra la instancia abierta (si la hay) y dispara el launcher para
# que baje la nueva versión. Sin esto, la PC del operador queda con
# la versión vieja hasta que cierre y reabra la app — incómodo
# después de cada release.
if (-not $SkipLocalUpdate) {
    Write-Host ""
    Write-Host "[8/9] Forzando update local en esta PC..." -ForegroundColor Cyan

    # 1) Matar la instancia si está corriendo. -ErrorAction
    # SilentlyContinue para que no falle si no está abierta.
    Stop-Process -Name 'coopertrans_movil' -Force -ErrorAction SilentlyContinue

    # 2) Borrar VERSION.txt. Si no existe, no falla. El launcher al
    # no encontrar VERSION.txt detecta "primera instalación" y baja
    # la última desde GitHub Releases (que acabamos de publicar).
    $verFile = Join-Path $env:ProgramData 'CoopertransMovil\VERSION.txt'
    if (Test-Path $verFile) {
        Remove-Item $verFile -Force -ErrorAction SilentlyContinue
    }

    # 3) Lanzar el launcher. Detecta nueva versión, baja zip,
    # extrae, lanza la app. El launcher usa Start-Process (no
    # bloqueante), así que volvemos al script casi de inmediato.
    $launcher = 'C:\Program Files\CoopertransMovil\launcher.ps1'
    if (Test-Path $launcher) {
        Write-Host "  Lanzando launcher (descarga la versión nueva en background)..." -ForegroundColor DarkGray
        Start-Process powershell -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-WindowStyle', 'Minimized',
            '-File', $launcher
        )
        Write-Host "  OK launcher iniciado." -ForegroundColor Green
    } else {
        Write-Host "  AVISO: no encuentro $launcher" -ForegroundColor Yellow
        Write-Host "  La app no se va a actualizar automáticamente en esta PC." -ForegroundColor Yellow
        Write-Host "  Si nunca instalaste el .exe del instalador acá, eso es esperado." -ForegroundColor DarkGray
    }
}

# ─── 10. Cierre + instrucciones manuales que quedan ──────────────
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  OK RELEASE $newVersion COMPLETO" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
$webColor = if ($webStatus -eq 'OK') { 'Green' } elseif ($webStatus -like 'FALLO*') { 'Yellow' } else { 'DarkGray' }
Write-Host "  App web (cooper-trans.com.ar/sistema/): $webStatus" -ForegroundColor $webColor
Write-Host ""
Write-Host "[11/11] Pasos manuales que quedan:" -ForegroundColor Cyan
Write-Host ""
if (-not $SkipAndroid) {
    Write-Host "  1. Subir el AAB a Play Console:" -ForegroundColor White
    Write-Host "     - https://play.google.com/console/" -ForegroundColor DarkGray
    Write-Host "     - Closed Testing -> Crear nueva version" -ForegroundColor DarkGray
    Write-Host "     - Subir build/app/outputs/bundle/release/app-release.aab" -ForegroundColor DarkGray
    Write-Host "     - Pegar release notes envueltas en <es-419>...</es-419>" -ForegroundColor DarkGray
    Write-Host ""
}
Write-Host "  2. Las otras PCs Windows toman el update solas al abrir el icono." -ForegroundColor White
Write-Host ""
