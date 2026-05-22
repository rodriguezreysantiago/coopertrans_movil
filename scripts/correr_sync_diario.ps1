# Corre un scraper Playwright diario en la PC dedicada (volvo_sync o
# sitrack_sync) con lockfile + log rotado. Lo invoca la Scheduled Task que
# registra instalar_syncs_diarios.ps1. ASCII puro (convencion del proyecto).
#
# No es un daemon: corre, hace el --commit a Firestore, y sale.
#
# Uso manual (test):
#   .\correr_sync_diario.ps1 -Sync volvo
#   .\correr_sync_diario.ps1 -Sync sitrack
#
# Log: <repo>\<scraper>\logs\sync_diario.log

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('volvo', 'sitrack')]
    [string]$Sync
)

$ErrorActionPreference = 'Stop'

# Paths absolutos (la Scheduled Task corre sin cwd predecible).
$RepoRoot = 'C:\coopertrans_movil'
$VenvPy   = Join-Path $RepoRoot 'sync_venv\Scripts\python.exe'

$map = @{
    volvo   = @{ Dir = 'volvo_sync';   Script = 'sync_taller.py' }
    sitrack = @{ Dir = 'sitrack_sync'; Script = 'sync_icm.py' }
}
$cfg     = $map[$Sync]
$Dir     = Join-Path $RepoRoot $cfg.Dir
$LogDir  = Join-Path $Dir 'logs'
$LogFile = Join-Path $LogDir 'sync_diario.log'
$LockFile = Join-Path $LogDir 'sync_diario.lock'

# Verificacion temprana: si el scraper no esta, no es esta PC -> salir silencioso.
if (-not (Test-Path $Dir)) { exit 0 }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Level, [string]$Msg)
    $ts = (Get-Date).ToString('dd/MM HH:mm:ss')
    "[$ts] [$Level] $Msg" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

# Rotacion simple a los ~5 MB.
if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 5MB)) {
    Move-Item $LogFile "$LogFile.1" -Force
}

# Lockfile anti-overlap (si una corrida tarda mas que lo esperado).
if (Test-Path $LockFile) {
    $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($age.TotalMinutes -lt 40) { exit 0 }
    Remove-Item $LockFile -Force
}
New-Item -ItemType File -Path $LockFile -Force | Out-Null

try {
    if (-not (Test-Path $VenvPy)) {
        Write-Log 'ERROR' "No existe el venv: $VenvPy (ver docs/SCRAPERS_DEDICADA.md)"
        exit 1
    }
    Set-Location $Dir
    # UTF-8 forzado: cuando la Scheduled Task corre con la salida redirigida,
    # Python usa cp1252 por defecto y revienta al imprimir '->' o acentos
    # (UnicodeEncodeError). PYTHONUTF8=1 lo pone en modo UTF-8 (stdout/stderr).
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    # PS 5.1 captura la salida nativa con [Console]::OutputEncoding (cp1252 por
    # defecto) -> los acentos/flechas que emite python en UTF-8 quedan mojibake
    # en el log. Lo ponemos en UTF-8 para que el log se lea bien. (Es solo
    # cosmetico: lo que se escribe a Firestore lo hace python aparte, ya UTF-8.)
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    Write-Log 'INFO' "Corriendo $($cfg.Script) --commit ..."

    # Capturamos stdout+stderr como texto sin abortar (PS 5.1: $EAP local).
    $out = & {
        $ErrorActionPreference = 'Continue'
        & $VenvPy '-u' $cfg.Script '--commit' 2>&1
    }
    $code = $LASTEXITCODE

    # Logueamos solo las ultimas lineas (el resumen). Sin volcar todo el detalle.
    # Por las dudas, filtramos cualquier linea que parezca traer credenciales.
    $tail = ($out | Where-Object { $_ -notmatch 'password' } |
        Select-Object -Last 12) -join ' || '
    if ($code -eq 0) {
        Write-Log 'INFO' "OK (exit 0). $tail"
    } else {
        Write-Log 'ERROR' "FALLO (exit $code). $tail"
    }
} catch {
    Write-Log 'ERROR' "Excepcion: $($_.Exception.Message)"
} finally {
    if (Test-Path $LockFile) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }
}
