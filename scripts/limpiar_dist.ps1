# =============================================================================
# limpiar_dist.ps1 — borra instaladores Windows viejos de dist/
# =============================================================================
# dist/ acumula un .exe de ~23 MB por release (42 archivos / ~950 MB al
# 2026-06-10). Todos los instaladores estan TAMBIEN en GitHub Releases (los
# sube release_app.ps1, incluida la copia estable CoopertransMovil-Setup.exe),
# asi que borrar los locales viejos no pierde nada.
#
# Conserva:
#   - Las ultimas -UltimasN versiones (default 3, por LastWriteTime).
#   - CoopertransMovil-Setup.exe (la copia estable sin version).
#
# Uso:
#   .\scripts\limpiar_dist.ps1            # muestra que borraria (dry-run)
#   .\scripts\limpiar_dist.ps1 -Ejecutar  # borra de verdad
#   .\scripts\limpiar_dist.ps1 -UltimasN 5 -Ejecutar
# =============================================================================
param(
    [int]$UltimasN = 3,
    [switch]$Ejecutar
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $repo "dist"

if (-not (Test-Path $dist)) {
    Write-Host "No existe $dist - nada que limpiar." -ForegroundColor Yellow
    exit 0
}

# Solo los instaladores versionados (no tocar la copia estable ni otros files).
$versionados = Get-ChildItem $dist -File -Filter "CoopertransMovil-Setup-*.exe" |
    Sort-Object LastWriteTime -Descending

$conservar = $versionados | Select-Object -First $UltimasN
$borrar = $versionados | Select-Object -Skip $UltimasN

if (-not $borrar) {
    Write-Host "Solo hay $($versionados.Count) instalador(es) - nada que borrar." -ForegroundColor Green
    exit 0
}

$mb = [math]::Round(($borrar | Measure-Object Length -Sum).Sum / 1MB)
Write-Host "Conservo ($($conservar.Count)):" -ForegroundColor Green
$conservar | ForEach-Object { Write-Host "  $($_.Name)" -ForegroundColor Green }
Write-Host "Borro ($($borrar.Count) archivos, $mb MB):" -ForegroundColor Yellow
$borrar | ForEach-Object { Write-Host "  $($_.Name)" }

if (-not $Ejecutar) {
    Write-Host "`nDRY-RUN: no borre nada. Ejecuta con -Ejecutar para borrar." -ForegroundColor Cyan
    exit 0
}

$borrar | Remove-Item -Force
Write-Host "`nListo: $($borrar.Count) instaladores borrados ($mb MB liberados)." -ForegroundColor Green
