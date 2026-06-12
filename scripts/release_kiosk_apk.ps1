# Publica el APK firmado de la tablet KIOSK (Gomeria) como asset del GitHub
# Release del tag actual. Es lo que habilita el auto-update SILENCIOSO de la
# tablet Device Owner: la app (AndroidUpdateService) lee releases/latest, busca
# el asset .apk, lo baja y lo instala sola.
#
# IMPORTANTE: el APK DEBE estar firmado con la MISMA clave que la app instalada
# en la tablet, si no Android rechaza el update por firma distinta. Por eso se
# buildea release (key.properties), nunca debug.
#
# Pre-requisitos:
#   - android/key.properties configurado (keystore release).
#   - gh CLI instalado y autenticado (gh auth login).
#   - El GitHub Release del tag YA tiene que existir. release_app.ps1 (o
#     release_completo.ps1) lo crea con los assets de Windows; este script
#     SOLO le suma el .apk. Si el release no existe, lo crea.
#   - La version en pubspec.yaml es la que se va a publicar.
#
# Uso (desde la raiz del repo):
#   .\scripts\release_kiosk_apk.ps1
#   .\scripts\release_kiosk_apk.ps1 -DryRun

param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Helper para llamar comandos nativos (gh, flutter) sin que stderr dispare
# excepcion en PowerShell 5.1 (mismo patron que release_app.ps1).
function Invoke-Native {
    param([scriptblock]$Block)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Block } finally { $ErrorActionPreference = $prev }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pubspec  = Join-Path $repoRoot 'pubspec.yaml'
$keyProps = Join-Path $repoRoot 'android\key.properties'
$apkBuilt = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-release.apk'

# --- 1. Version y tag -----------------------------------------------
$verLine = (Get-Content $pubspec) | Where-Object { $_ -match '^version:\s*(\S+)' } | Select-Object -First 1
if (-not $verLine) { throw "No encuentro 'version:' en pubspec.yaml" }
$version = ($verLine -replace '^version:\s*', '').Trim()
$tag = "v$version"
# Nombre de asset estable, sin '+' (puede romper en URLs de descarga). Mismo
# criterio que el .zip de Windows: reemplazamos '+' por '-build'.
$apkAsset = "coopertrans_movil_$($version -replace '\+','-build').apk"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "RELEASE KIOSK APK: $tag" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# --- 2. key.properties (firma release) ------------------------------
if (-not (Test-Path $keyProps)) {
    Write-Host "ERROR: no encontre android/key.properties (necesario para firmar)." -ForegroundColor Red
    Write-Host "Esta PC no tiene el keystore; corre el release desde la PC que lo tenga." -ForegroundColor Yellow
    exit 1
}

# --- 3. gh CLI ------------------------------------------------------
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    throw "gh CLI no esta instalado. Instalar con: winget install GitHub.cli"
}
Invoke-Native { & gh auth status *>$null }
if ($LASTEXITCODE -ne 0) {
    Invoke-Native { & gh auth status }
    throw "gh CLI no esta autenticado. Correr: gh auth login"
}

# --- 4. Build APK release firmado -----------------------------------
Write-Host ""
Write-Host "[1/3] flutter build apk --release..." -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "  [DRY-RUN] flutter build apk --release" -ForegroundColor Yellow
} else {
    Push-Location $repoRoot
    try {
        Invoke-Native { & flutter build apk --release }
        if ($LASTEXITCODE -ne 0) { throw "flutter build apk fallo" }
    } finally { Pop-Location }
    if (-not (Test-Path $apkBuilt)) {
        throw "no encontre el APK en $apkBuilt"
    }
    $sizeMB = [math]::Round((Get-Item $apkBuilt).Length / 1MB, 1)
    Write-Host "  OK - APK: $sizeMB MB" -ForegroundColor Green
}

# --- 5. Copiar al nombre de asset estable ---------------------------
$apkPublicar = Join-Path $env:TEMP $apkAsset
if (-not $DryRun) {
    Copy-Item $apkBuilt $apkPublicar -Force
}

# --- 6. Subir al GitHub Release del tag -----------------------------
Write-Host ""
Write-Host "[2/3] Subiendo $apkAsset al release $tag..." -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "  [DRY-RUN] gh release upload $tag $apkAsset --clobber" -ForegroundColor Yellow
    Write-Host "  (si el release no existe: gh release create $tag ...)" -ForegroundColor DarkGray
    exit 0
}

# Â¿Existe el release? Si si, upload --clobber; si no, lo creamos con el apk.
$releaseExiste = $false
Invoke-Native { & gh release view $tag *>$null }
if ($LASTEXITCODE -eq 0) { $releaseExiste = $true }

if ($releaseExiste) {
    Invoke-Native { & gh release upload $tag $apkPublicar --clobber }
    if ($LASTEXITCODE -ne 0) { throw "gh release upload fallo" }
} else {
    Write-Host "  El release $tag no existe todavia, lo creo con el APK..." -ForegroundColor Yellow
    Invoke-Native { & gh release create $tag $apkPublicar --title "Coopertrans Movil $tag" --notes "Kiosk APK $tag" }
    if ($LASTEXITCODE -ne 0) { throw "gh release create fallo" }
}

Remove-Item $apkPublicar -Force -ErrorAction SilentlyContinue

# --- 7. Cierre ------------------------------------------------------
Write-Host ""
Write-Host "[3/3] APK publicado." -ForegroundColor Green
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "OK KIOSK APK $tag publicado en GitHub Release" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "La tablet kiosk lo va a bajar e instalar sola en el proximo" -ForegroundColor Cyan
Write-Host "arranque/chequeo (AndroidUpdateService). No requiere tocar la tablet." -ForegroundColor Cyan
