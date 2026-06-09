# Bumpea la versión en los 3 lugares donde vive:
#   - pubspec.yaml (version: X.Y.Z+N)
#   - lib/core/constants/app_constants.dart (appVersion = 'v X.Y.Z')
#   - windows/runner/main.cpp (título de la ventana)
#
# Uso:
#   .\scripts\bump_version.ps1                    -> sugiere el siguiente patch
#   .\scripts\bump_version.ps1 -Version 1.2.3+45  -> set explícito
#   .\scripts\bump_version.ps1 -DryRun            -> muestra qué cambiaría
#
# Convención: pubspec usa MAJOR.MINOR.PATCH+BUILD (ej. 1.0.8+16). Cada
# bump del patch incrementa también el build (1.0.8+16 → 1.0.9+17).
# El "appVersion" en el constant coincide 1:1 con el patch del pubspec
# (`v MAJOR.MINOR.PATCH`). Antes había un offset legacy `patch + 6`
# que generaba mismatch entre pubspec y UI; sacado 2026-05-08.

param(
    [string]$Version = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$repoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pubspec        = Join-Path $repoRoot 'pubspec.yaml'
$appConstants   = Join-Path $repoRoot 'lib\core\constants\app_constants.dart'
$mainCpp        = Join-Path $repoRoot 'windows\runner\main.cpp'

# --- Leer versión actual de pubspec --------------------------------
$pubLines = Get-Content $pubspec
$verLine  = $pubLines | Where-Object { $_ -match '^version:\s*(\S+)' } | Select-Object -First 1
if (-not $verLine) { throw "No encuentro 'version:' en pubspec.yaml" }
$verActual = ($verLine -replace '^version:\s*', '').Trim()

if (-not ($verActual -match '^(\d+)\.(\d+)\.(\d+)\+(\d+)$')) {
    throw "Version actual '$verActual' no respeta MAJOR.MINOR.PATCH+BUILD."
}
$major   = [int]$matches[1]
$minor   = [int]$matches[2]
$patch   = [int]$matches[3]
$build   = [int]$matches[4]

# --- Decidir versión nueva -----------------------------------------
# Serie de versión vigente: el auto-bump mantiene MAJOR.MINOR fijos y sólo
# sube el PATCH (el último número) + el BUILD. Para saltar de serie (ej. el
# día que quieras pasar a 1.3.x), cambiá $serieMinor/$serieMajor acá abajo:
# el próximo bump arranca la serie nueva en ".0". El BUILD siempre sube +1
# (las stores exigen versionCode monótono).
$serieMajor = 1
$serieMinor = 2
if ($Version -eq '') {
    if ($major -eq $serieMajor -and $minor -eq $serieMinor) {
        # Ya estamos en la serie: subir sólo el último número (patch).
        $nuevoPatch = $patch + 1
    } else {
        # Cambio de serie (ej. 1.0.x -> 1.2.x): arrancar la serie nueva en .0.
        $nuevoPatch = 0
        Write-Host "Cambio de serie: $major.$minor.x -> $serieMajor.$serieMinor.x (arranca en .0)" -ForegroundColor Yellow
    }
    # Build DERIVADO del semver (NO un contador aparte): vos manejás SOLO X.Y.Z
    # (1.2.1, 1.2.2…) y el build se calcula solo. Play/App Store exigen un
    # versionCode/build único y creciente — este esquema (M*10000 + m*100 +
    # patch) lo garantiza mientras la versión suba. El guard final asegura que
    # nunca quede <= al build actual (robustez ante un cambio de serie raro).
    $nuevoBuild = $serieMajor * 10000 + $serieMinor * 100 + $nuevoPatch
    if ($nuevoBuild -le $build) { $nuevoBuild = $build + 1 }
    $Version    = "$serieMajor.$serieMinor.$nuevoPatch+$nuevoBuild"
    Write-Host "Sugerida: $serieMajor.$serieMinor.$nuevoPatch  (build interno $nuevoBuild, automatico)" -ForegroundColor Cyan
}

if (-not ($Version -match '^(\d+)\.(\d+)\.(\d+)\+(\d+)$')) {
    throw "Version nueva '$Version' no respeta MAJOR.MINOR.PATCH+BUILD."
}
$nMajor = [int]$matches[1]
$nMinor = [int]$matches[2]
$nPatch = [int]$matches[3]
$nBuild = [int]$matches[4]

# Idempotencia: si pidieron bump a la versión que ya está, salir sin
# tocar archivos. Útil cuando release_completo.ps1 se relanza con
# `-Version X.Y.Z+B` y el bump del run anterior ya estaba commiteado
# (sino los Set-Content reescriben los mismos archivos y git detecta
# cambios espurios por line endings CRLF/LF).
if ($Version -eq $verActual) {
    Write-Host "Versión ya está en $Version — nada que bumpear." -ForegroundColor DarkGray
    exit 0
}

# appVersion visible coincide 1:1 con el patch del pubspec
# (decisión 2026-05-08: sacar el offset legacy que históricamente
# era `patch + 6` y generaba mismatch entre pubspec y UI).
$appVer = "v $nMajor.$nMinor.$nPatch"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Bump de version" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  pubspec.yaml      : $verActual -> $Version"
Write-Host "  app_constants.dart: appVersion -> '$appVer'"
Write-Host "  main.cpp (titulo) : 'Coopertrans Movil - $appVer (build $nBuild)'"
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY-RUN] No se modifico ningun archivo." -ForegroundColor Yellow
    exit 0
}

# --- Aplicar cambios ----------------------------------------------
# IMPORTANTE: en PowerShell 5.1 `-Encoding UTF8` agrega BOM. pubspec.yaml
# con BOM confunde parsers de YAML (algunos toleran, otros no) y
# app_constants.dart con BOM puede confundir analizadores Dart. Usamos
# UTF8Encoding sin BOM via [System.IO.File]::WriteAllText para evitarlo.
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

# LEER en UTF-8 EXPLICITO. En PowerShell 5.1, `Get-Content -Raw` SIN
# -Encoding lee con la codificacion del sistema (Windows-1252/Latin-1).
# Si el archivo es UTF-8 (como debe ser todo .dart/.yaml), los caracteres
# no-ASCII (acentos, eñe, "·", "—") se decodifican como Latin-1 → al
# re-escribir en UTF-8 cada byte se vuelve 2 bytes → mojibake. Y cada
# release lo amplifica. Caso reportado Santiago 2026-06-09: la pantalla
# splash mostraba la `tagline` como ASCII soup (basura tipo "GESTI<...>
# DE FLOTA <...> COOPERTRANS" en lugar de "GESTIÓN DE FLOTA · COOPERTRANS").
# Sin -Encoding UTF8 el bug es invisible hasta que alguien mira la app
# en pantalla.
$pubContent = Get-Content $pubspec -Raw -Encoding UTF8
$pubContent = $pubContent -replace "version:\s*\S+", "version: $Version"
Write-Utf8NoBom $pubspec $pubContent

$constContent = Get-Content $appConstants -Raw -Encoding UTF8
$constContent = $constContent -replace "appVersion\s*=\s*'v [^']+'", "appVersion = '$appVer'"
Write-Utf8NoBom $appConstants $constContent

$mainContent = Get-Content $mainCpp -Raw -Encoding UTF8
# Reemplaza el string del titulo. Tolerante con o sin acento, con
# diferentes formatos de version.
$mainContent = $mainContent -replace 'L"Coopertrans M[^"]*"', "L`"Coopertrans Móvil — $appVer (build $nBuild)`""
# main.cpp: UTF-8 CON BOM (MSVC lo necesita para los no-ASCII del título "Móvil —")
# + LF. Antes Set-Content -Encoding UTF8 escribía CRLF y git avisaba "CRLF will be
# replaced by LF" en cada release (el .gitattributes fuerza LF). Preservamos el BOM.
$mainContent = $mainContent -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($mainCpp, $mainContent, [System.Text.UTF8Encoding]::new($true))

Write-Host "OK. Cambios aplicados." -ForegroundColor Green
Write-Host ""
Write-Host "Proximos pasos:" -ForegroundColor Cyan
Write-Host "  flutter build windows --release"
Write-Host "  git add pubspec.yaml lib/core/constants/app_constants.dart windows/runner/main.cpp"
Write-Host "  git commit -m 'chore: bump version $verActual -> $Version'"
Write-Host "  .\scripts\release_app.ps1"
