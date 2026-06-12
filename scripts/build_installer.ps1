# Compila el instalador .exe de Coopertrans Móvil con Inno Setup.
#
# Pre-requisitos:
#   - Inno Setup instalado: winget install JRSoftware.InnoSetup
#   - flutter build windows --release corrido antes (deja el output
#     en build\windows\x64\runner\Release\).
#
# Uso (desde la raíz del repo):
#   .\scripts\build_installer.ps1
#
# Output:
#   dist\CoopertransMovil-Setup-{version}.exe

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pubspec  = Join-Path $repoRoot 'pubspec.yaml'
$iss      = Join-Path $repoRoot 'installer\coopertrans_movil.iss'
$buildDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
$distDir  = Join-Path $repoRoot 'dist'

# --- 1. Versión del pubspec ----------------------------------------
$verLine = Get-Content $pubspec | Where-Object { $_ -match '^version:\s*(\S+)' } | Select-Object -First 1
if (-not $verLine) { throw "No encuentro 'version:' en pubspec.yaml" }
$version = ($verLine -replace '^version:\s*', '').Trim()

# Inno no acepta '+' en AppVersion display. Lo reemplazamos por '-build'.
$versionInno = $version -replace '\+', '-build'

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "BUILD INSTALADOR: $versionInno" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# --- 2. Verificar build de Flutter ---------------------------------
if (-not (Test-Path (Join-Path $buildDir 'coopertrans_movil.exe'))) {
    Write-Host "ERROR: no encontre el build de Flutter." -ForegroundColor Red
    Write-Host "Antes de correr este script, hace:" -ForegroundColor Yellow
    Write-Host "  flutter build windows --release" -ForegroundColor Yellow
    exit 1
}

# --- 3. Encontrar iscc.exe (compilador Inno Setup) -----------------
# winget puede instalar Inno Setup en system (Program Files) o user
# (LOCALAPPDATA\Programs) según la opción que use. Buscamos en ambos.
$iscc = $null
$candidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 5\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 5\ISCC.exe"
)
foreach ($c in $candidates) {
    if (Test-Path $c) { $iscc = $c; break }
}
if (-not $iscc) {
    $cmd = Get-Command iscc -ErrorAction SilentlyContinue
    if ($cmd) { $iscc = $cmd.Source }
}
if (-not $iscc) {
    Write-Host "ERROR: no encontre Inno Setup (ISCC.exe)." -ForegroundColor Red
    Write-Host "Instalar con (PowerShell admin, una vez):" -ForegroundColor Yellow
    Write-Host "  winget install JRSoftware.InnoSetup" -ForegroundColor Yellow
    exit 1
}
Write-Host "OK Inno Setup: $iscc" -ForegroundColor Green

# --- 4. Crear dir de output ----------------------------------------
if (-not (Test-Path $distDir)) {
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
}

# --- 5. Generar VERSION.txt en installer/ --------------------------
# Este archivo se incluye en el setup y queda en
# ProgramData\CoopertransMovil para que el launcher pueda comparar
# con la última release.
Set-Content -Path (Join-Path $repoRoot 'installer\VERSION.txt') -Value $version -Encoding UTF8

# --- 6. Compilar ---------------------------------------------------
Write-Host ""
Write-Host "Compilando $iss ..." -ForegroundColor Cyan
& $iscc "/DMyAppVersion=$versionInno" $iss
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: iscc.exe falló (exit $LASTEXITCODE)" -ForegroundColor Red
    exit 1
}

$installer = Join-Path $distDir "CoopertransMovil-Setup-$versionInno.exe"
if (-not (Test-Path $installer)) {
    Write-Host "ADVERTENCIA: no encuentro el .exe en $installer" -ForegroundColor Yellow
    exit 1
}

$sizeMB = [math]::Round((Get-Item $installer).Length / 1MB, 1)

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "OK INSTALADOR LISTO" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Archivo:  $installer" -ForegroundColor White
Write-Host "Tamaño:   $sizeMB MB" -ForegroundColor White
Write-Host ""
Write-Host "Llevá ese .exe en pendrive a cualquier PC." -ForegroundColor Cyan
Write-Host "Doble click → UAC → instala en Program Files + crea iconos." -ForegroundColor Cyan
