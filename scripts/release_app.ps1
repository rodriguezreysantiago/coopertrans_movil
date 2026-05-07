# Empaqueta el build Windows release de la app Flutter y lo publica como
# GitHub Release. Pensado para correr UNA SOLA VEZ por release, en la PC
# donde acabás de buildear.
#
# Pre-requisitos:
#   - flutter build windows --release (corrido antes, deja el output en
#     build/windows/x64/runner/Release/).
#   - gh CLI instalado y autenticado (`gh auth login`).
#   - El número de versión en pubspec.yaml ya bumpeado para este release.
#
# Uso (desde la raíz del repo):
#   .\scripts\release_app.ps1
#   .\scripts\release_app.ps1 -Notes "Fix de cálculo de service preventivo"
#   .\scripts\release_app.ps1 -DryRun

param(
    [string]$Notes = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Helper para llamar comandos nativos (gh, git) sin que stderr dispare
# excepción en PowerShell 5.1. PS 5.1 envuelve cada línea de stderr en
# un ErrorRecord y con ErrorActionPreference='Stop' aborta el script
# aunque el comando termine con exit code 0. Bajamos la setting solo
# durante el call y la restauramos al final.
function Invoke-Native {
    param([scriptblock]$Block)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Block } finally { $ErrorActionPreference = $prev }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pubspec  = Join-Path $repoRoot 'pubspec.yaml'
$buildDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'

# --- 1. Leer versión de pubspec.yaml --------------------------------
$pubLines = Get-Content $pubspec
$verLine = $pubLines | Where-Object { $_ -match '^version:\s*(\S+)' } | Select-Object -First 1
if (-not $verLine) { throw "No encuentro 'version:' en pubspec.yaml" }
$version = ($verLine -replace '^version:\s*', '').Trim()
$tag = "v$version"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "RELEASE: $tag" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# --- 2. Verificar gh CLI -------------------------------------------
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    throw "gh CLI no está instalado. Instalar con: winget install GitHub.cli"
}
Invoke-Native { & gh auth status *>$null }
if ($LASTEXITCODE -ne 0) {
    Invoke-Native { & gh auth status }   # ahora sí mostrar el detalle al usuario
    throw "gh CLI no está autenticado. Correr: gh auth login"
}

# --- 3. Verificar que existe el build ------------------------------
$exePath = Join-Path $buildDir 'coopertrans_movil.exe'
if (-not (Test-Path $exePath)) {
    Write-Host "ERROR: no encontre $exePath" -ForegroundColor Red
    Write-Host "Antes de correr este script, hace:" -ForegroundColor Yellow
    Write-Host "  flutter build windows --release" -ForegroundColor Yellow
    exit 1
}

# --- 4. Detectar si el release ya existe (idempotente) -------------
# Si el release no existe gh escribe "release not found" a stderr
# (esperable). Invoke-Native evita que eso aborte el script.
# Si EXISTE, en lugar de abortar, después del [1/3] decidimos qué hacer:
#   - Si los assets locales ya están subidos al release remoto → "ya
#     estaba publicado", exit 0.
#   - Si faltan assets → los subimos al release existente.
#   - Si los assets locales son distintos a los remotos (mismo nombre
#     pero size distinto) → reemplazamos con --clobber.
$releaseJson = Invoke-Native { & gh release view $tag --json tagName,assets 2>$null }
$releaseExiste = ($LASTEXITCODE -eq 0)
$assetsRemotos = @()
if ($releaseExiste) {
    try {
        $assetsRemotos = ($releaseJson | ConvertFrom-Json).assets
    } catch {
        $assetsRemotos = @()
    }
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host "  AVISO IMPORTANTE: $tag ya existe en GitHub." -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Si tu codigo cambio desde la ultima publicacion," -ForegroundColor Yellow
    Write-Host "  los OPERADORES NO van a recibir el update aunque" -ForegroundColor Yellow
    Write-Host "  reemplaces el zip — el launcher de cada PC compara" -ForegroundColor Yellow
    Write-Host "  VERSION.txt local vs el tag, y si coincide no descarga." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Lo correcto en ese caso es:" -ForegroundColor Yellow
    Write-Host "    1) Bumpear pubspec.yaml (ej: 1.0.4+12 -> 1.0.5+13)" -ForegroundColor Yellow
    Write-Host "    2) flutter build windows --release" -ForegroundColor Yellow
    Write-Host "    3) Volver a correr este script" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Republicar la misma version solo sirve para corregir" -ForegroundColor DarkGray
    Write-Host "  el zip antes de que algun PC lo haya descargado." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Assets remotos actuales:" -ForegroundColor DarkGray
    if ($assetsRemotos.Count -eq 0) {
        Write-Host "    (ninguno)" -ForegroundColor DarkGray
    } else {
        foreach ($a in $assetsRemotos) {
            $mb = [math]::Round($a.size / 1MB, 1)
            Write-Host "    $($a.name) ($mb MB)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    $continuar = Read-Host "Continuar igual con republicacion de $tag? (s/N)"
    if ($continuar -ne 's' -and $continuar -ne 'S') {
        Write-Host "Cancelado. Bumpea la version y volve." -ForegroundColor Cyan
        exit 0
    }
}

# --- 5. Verificar que el repo está limpio + pusheado ---------------
Push-Location $repoRoot
try {
    $dirty = Invoke-Native { git status --porcelain }
    if ($dirty) {
        Write-Host "ADVERTENCIA: hay cambios sin commitear:" -ForegroundColor Yellow
        Write-Host $dirty
        $confirm = Read-Host "¿Seguir igual? (s/N)"
        if ($confirm -ne 's' -and $confirm -ne 'S') { exit 1 }
    }
    $unpushed = Invoke-Native { git log --oneline '@{u}..HEAD' 2>$null }
    if ($unpushed) {
        Write-Host "ADVERTENCIA: hay $(($unpushed | Measure-Object).Count) commits sin pushear:" -ForegroundColor Yellow
        Write-Host $unpushed
        $confirm = Read-Host "El release apunta al codigo del remoto. ¿Pushear primero? (S/n)"
        if ($confirm -ne 'n' -and $confirm -ne 'N') {
            Invoke-Native { git push }
            if ($LASTEXITCODE -ne 0) { throw "git push falló" }
        }
    }
}
finally { Pop-Location }

# --- 6. Crear zip --------------------------------------------------
$zipName = "coopertrans_movil_$($version -replace '\+','-build').zip"
$zipPath = Join-Path $env:TEMP $zipName

# Sumar VERSION.txt al build (lo lee el launcher)
Set-Content -Path (Join-Path $buildDir 'VERSION.txt') -Value $version -Encoding UTF8

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Write-Host ""
Write-Host "[1/3] Empaquetando $buildDir → $zipName ..." -ForegroundColor Cyan
Compress-Archive -Path "$buildDir\*" -DestinationPath $zipPath -CompressionLevel Optimal
$sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Host "  OK ($sizeMB MB)" -ForegroundColor Green

# --- 7. Crear release en GitHub ------------------------------------
if (-not $Notes) {
    # Notas auto: últimos 5 commits
    Push-Location $repoRoot
    try {
        $log = Invoke-Native { git log --oneline -5 --no-decorate }
        $Notes = "Cambios recientes:`n`n" + ($log | ForEach-Object { "- $_" } | Out-String)
    }
    finally { Pop-Location }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "[DRY-RUN] No publico nada. El release sería:" -ForegroundColor Yellow
    Write-Host "  Tag:      $tag" -ForegroundColor White
    Write-Host "  Asset:    $zipName ($sizeMB MB)" -ForegroundColor White
    Write-Host "  Notes:" -ForegroundColor White
    Write-Host $Notes
    Write-Host ""
    Write-Host "Para publicarlo realmente:" -ForegroundColor Cyan
    Write-Host "  .\scripts\release_app.ps1" -ForegroundColor White
    Remove-Item $zipPath -Force
    exit 0
}

# Armado de la lista de assets locales a publicar.
# Si hay instalador .exe compilado en dist/, lo sumamos como segundo asset.
# build_installer.ps1 reemplaza '+' por '-build' en el filename.
$versionInno = $version -replace '\+', '-build'
$installerExe = Join-Path $repoRoot "dist\CoopertransMovil-Setup-$versionInno.exe"
$assets = @($zipPath)
if (Test-Path $installerExe) {
    $instMB = [math]::Round((Get-Item $installerExe).Length / 1MB, 1)
    Write-Host "  Sumando instalador: $(Split-Path $installerExe -Leaf) ($instMB MB)" -ForegroundColor Cyan
    $assets += $installerExe
} else {
    Write-Host "  (sin instalador .exe en dist\ — para sumarlo: .\scripts\build_installer.ps1)" -ForegroundColor DarkGray
}

if ($releaseExiste) {
    # Modo upload: comparar assets locales vs remotos. Subir los que
    # faltan o tienen size distinto. Sin tocar los que ya coinciden.
    Write-Host ""
    Write-Host "[2/3] Sincronizando assets con release existente $tag..." -ForegroundColor Cyan
    $remoteByName = @{}
    foreach ($a in $assetsRemotos) { $remoteByName[$a.name] = $a }

    $subidos = 0
    $reemplazados = 0
    $yaIguales = 0
    foreach ($localPath in $assets) {
        $localName = Split-Path $localPath -Leaf
        $localSize = (Get-Item $localPath).Length
        if ($remoteByName.ContainsKey($localName)) {
            $remoteSize = [int64]$remoteByName[$localName].size
            if ($remoteSize -eq $localSize) {
                Write-Host "  $localName ya estaba subido (size match)" -ForegroundColor DarkGray
                $yaIguales++
                continue
            }
            Write-Host "  $localName existe pero size distinto, reemplazando..." -ForegroundColor Cyan
            Invoke-Native { & gh release upload $tag $localPath --clobber }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Error al reemplazar $localName" -ForegroundColor Red
                exit 1
            }
            $reemplazados++
        } else {
            Write-Host "  Subiendo $localName..." -ForegroundColor Cyan
            Invoke-Native { & gh release upload $tag $localPath }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Error al subir $localName" -ForegroundColor Red
                exit 1
            }
            $subidos++
        }
    }

    # Cleanup
    Remove-Item $zipPath -Force

    Write-Host ""
    Write-Host "[3/3] Sincronización lista." -ForegroundColor Green
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "OK RELEASE $tag" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Assets subidos:      $subidos" -ForegroundColor White
    Write-Host "Assets reemplazados: $reemplazados" -ForegroundColor White
    Write-Host "Assets sin cambios:  $yaIguales" -ForegroundColor White
    Write-Host ""
    if ($subidos -eq 0 -and $reemplazados -eq 0) {
        Write-Host "El release ya estaba completo, no hubo cambios." -ForegroundColor Cyan
    } else {
        Write-Host "Las otras PCs van a tomar la actualización la próxima vez" -ForegroundColor Cyan
        Write-Host "que el operador haga doble click en el icono 'Coopertrans Móvil'." -ForegroundColor Cyan
    }
    exit 0
}

Write-Host ""
Write-Host "[2/3] Creando release $tag en GitHub..." -ForegroundColor Cyan
Invoke-Native { & gh release create $tag $assets --title "Coopertrans Movil $tag" --notes $Notes }
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error al crear release. El zip quedó en $zipPath" -ForegroundColor Red
    exit 1
}

# --- 8. Cleanup ----------------------------------------------------
Remove-Item $zipPath -Force

Write-Host ""
Write-Host "[3/3] Release publicado correctamente." -ForegroundColor Green
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "OK RELEASE $tag" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Las otras PCs van a tomar la actualización la próxima vez" -ForegroundColor Cyan
Write-Host "que el operador haga doble click en el icono 'Coopertrans Móvil'." -ForegroundColor Cyan
