# Release completo en 1 comando: bump + build Windows + instalador +
# push + GitHub Release + AAB Android.
#
# Pensado para que NO te quedes colgado en ningún paso. Cada paso
# valida que el anterior haya completado antes de seguir.
#
# Uso:
#   .\scripts\release_completo.ps1                 # bump patch+1+build+1
#   .\scripts\release_completo.ps1 -Version 1.2.3+45   # versión explícita
#   .\scripts\release_completo.ps1 -SkipAndroid    # solo Windows
#   .\scripts\release_completo.ps1 -DryRun         # muestra qué haría
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
#   9. Imprime instrucciones para subir el AAB a Play Console.
#
# Si querés republicar el MISMO tag (no bumpear), usá `release_app.ps1`
# directo — ese script ya maneja la republicación.

param(
    [string]$Version = '',
    [switch]$SkipAndroid,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

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
$bumpArgs = @()
if ($Version -ne '') { $bumpArgs += '-Version', $Version }
if ($DryRun) { $bumpArgs += '-DryRun' }

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

# ─── 9. Cierre + instrucciones manuales ──────────────────────────
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  OK RELEASE $newVersion COMPLETO" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "[8/8] Pasos manuales que quedan:" -ForegroundColor Cyan
Write-Host ""
if (-not $SkipAndroid) {
    Write-Host "  1. Subir el AAB a Play Console:" -ForegroundColor White
    Write-Host "     - https://play.google.com/console/" -ForegroundColor DarkGray
    Write-Host "     - Closed Testing -> Crear nueva version" -ForegroundColor DarkGray
    Write-Host "     - Subir build/app/outputs/bundle/release/app-release.aab" -ForegroundColor DarkGray
    Write-Host "     - Pegar release notes envueltas en <es-419>...</es-419>" -ForegroundColor DarkGray
    Write-Host ""
}
Write-Host "  2. Forzar update local en tu PC:" -ForegroundColor White
Write-Host "     Stop-Process -Name 'coopertrans_movil' -Force -ErrorAction SilentlyContinue" -ForegroundColor DarkGray
Write-Host "     Remove-Item `"`$env:ProgramData\CoopertransMovil\VERSION.txt`" -Force -ErrorAction SilentlyContinue" -ForegroundColor DarkGray
Write-Host "     & `"C:\Program Files\CoopertransMovil\launcher.ps1`"" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  3. Las otras PCs Windows toman el update solas al abrir el icono." -ForegroundColor White
Write-Host ""
