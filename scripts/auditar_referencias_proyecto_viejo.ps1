# Auditoría pre-decommission del proyecto Firebase legacy
# `logisticaapp-e539a` (migrado a `coopertrans-movil` el 2026-05-02).
#
# Recorre el repo buscando referencias residuales al proyecto viejo:
#   - projectId (`logisticaapp-e539a`)
#   - bucket de backups (`gs://logisticaapp-backups`)
#   - bucket de storage (`logisticaapp.firebasestorage.app`)
#   - bucket alterno (`logisticaapp.appspot.com`)
#   - URLs de Cloud Functions del proyecto viejo
#
# Si encuentra HITS, los lista con archivo:línea y CONTENIDO. El
# operador decide caso por caso: ¿es histórico esperado (ESTADO_PROYECTO,
# RUNBOOK) o es código activo que apunta al proyecto viejo y va a
# romper cuando bajemos `logisticaapp-e539a`?
#
# Excluye carpetas auto-generadas: node_modules, .git, build, .dart_tool,
# .claude/worktrees, .sentry-native, etc.
#
# CUÁNDO CORRERLO:
#   - Antes de bajar el proyecto viejo a Spark plan o borrarlo entero
#     (>= 2026-06-02 según el período de validación).
#   - Cuando quieras confirmar que un cambio no introdujo refs nuevas.
#
# USO (desde la raíz del repo):
#   .\scripts\auditar_referencias_proyecto_viejo.ps1
#
# EXIT CODES:
#   0 -> cero referencias activas (seguro proceder con decommission)
#   1 -> hay referencias en código activo (NO bajar el proyecto viejo)

$ErrorActionPreference = 'Stop'

# Patrones literales a buscar. Cada uno cubre un alias distinto del
# proyecto viejo. NO usamos regex amplios para evitar matches espurios.
$patterns = @(
    'logisticaapp-e539a',
    'gs://logisticaapp-backups',
    'logisticaapp.firebasestorage.app',
    'logisticaapp.appspot.com',
    'us-central1-logisticaapp',
    'southamerica-east1-logisticaapp'
)

# Carpetas a excluir del recursivo. Son artefactos de build, deps,
# control de versiones, worktrees, etc. NO código fuente real.
# Match por substring del FullName (case-insensitive).
$excludeDirs = @(
    'node_modules',
    '.git\',
    '.dart_tool',
    '\build\',
    '.claude\',
    '.sentry-native',
    '.firebase',
    '.gradle',
    'flutter\ephemeral',
    'lib\generated',
    'functions\lib\',
    '.wwebjs_auth',
    '.wwebjs_cache',
    'whatsapp-bot\logs'
)

# Archivos donde encontrar referencias es ESPERADO (histórico
# documentado, NO código activo). Las matches se reportan pero NO
# cuentan para el exit code de fallo.
#
# - ESTADO_PROYECTO.md: log histórico de la migración 2026-05-02.
# - RUNBOOK.md: documenta el procedimiento de decommission, comando
#   de delete del proyecto, etc. — necesariamente menciona el id viejo.
# - auditar_referencias_proyecto_viejo.ps1: este mismo script define
#   los patrones a buscar como constantes literales — clásico falso
#   positivo de "el grep encuentra al grep".
$historicalFiles = @(
    'ESTADO_PROYECTO.md',
    'RUNBOOK.md',
    'auditar_referencias_proyecto_viejo.ps1'
)

# Extensiones a buscar (código + docs + config).
$extensions = @('.dart', '.ts', '.js', '.json', '.yaml', '.yml', '.md', '.ps1', '.py')

Write-Host ''
Write-Host 'Auditoria de referencias al proyecto Firebase legacy' -ForegroundColor Cyan
Write-Host '   logisticaapp-e539a -> coopertrans-movil (migrado 2026-05-02)' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Patrones buscados:' -ForegroundColor Gray
foreach ($p in $patterns) { Write-Host "  - $p" -ForegroundColor Gray }
Write-Host ''

# Función helper: ¿el archivo está en una carpeta excluida? Operamos
# sobre la RUTA RELATIVA al CWD, no sobre la full path, porque el
# CWD puede contener fragmentos como ".claude\worktrees\..." que
# matchearían las exclusiones y descartarían todo el repo.
function Test-Excluded {
    param($relPath, $dirs)
    foreach ($dir in $dirs) {
        if ($relPath -like "*$dir*") { return $true }
    }
    return $false
}

# Función helper: ¿el archivo es histórico whitelist?
function Test-Historical {
    param($relPath, $whitelist)
    $sep = [IO.Path]::DirectorySeparatorChar
    foreach ($wh in $whitelist) {
        if ($relPath -eq $wh) { return $true }
        if ($relPath.EndsWith("$sep$wh")) { return $true }
    }
    return $false
}

# Indexar archivos del repo una sola vez. Calculamos la ruta relativa
# al CWD para cada uno y filtramos sobre eso (ver Test-Excluded).
Write-Host 'Indexando archivos...' -ForegroundColor Gray
$dirsRef = $excludeDirs
$cwd = (Get-Location).Path
$allFiles = Get-ChildItem -Path . -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $extensions -contains $_.Extension.ToLower() } |
    Where-Object {
        $rel = $_.FullName.Substring($cwd.Length).TrimStart('\', '/')
        -not (Test-Excluded -relPath $rel -dirs $dirsRef)
    }
Write-Host "  $($allFiles.Count) archivos indexados" -ForegroundColor Gray

$totalHits = 0
$hitsActivos = 0
$hitsHistoricos = 0

foreach ($pattern in $patterns) {
    $found = $allFiles | Select-String -Pattern ([regex]::Escape($pattern)) -SimpleMatch -ErrorAction SilentlyContinue
    if (-not $found -or $found.Count -eq 0) { continue }

    $cnt = @($found).Count
    Write-Host ''
    Write-Host "Patron: $pattern  ($cnt match$(if ($cnt -ne 1) {'es'}))" -ForegroundColor Yellow

    foreach ($m in $found) {
        $rel = Resolve-Path $m.Path -Relative -ErrorAction SilentlyContinue
        if (-not $rel) { $rel = $m.Path }
        $rel = $rel -replace '^\.[\\/]', ''

        $totalHits++
        if (Test-Historical -relPath $rel -whitelist $historicalFiles) {
            $hitsHistoricos++
            Write-Host "    [HIST] $rel`:$($m.LineNumber)  (historico OK)" -ForegroundColor DarkGray
            Write-Host "           $($m.Line.Trim())" -ForegroundColor DarkGray
        } else {
            $hitsActivos++
            Write-Host "    [WARN] $rel`:$($m.LineNumber)" -ForegroundColor Red
            Write-Host "           $($m.Line.Trim())" -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host '----------------- RESUMEN -----------------' -ForegroundColor Cyan
Write-Host ''

if ($totalHits -eq 0) {
    Write-Host 'OK: cero referencias al proyecto legacy.' -ForegroundColor Green
    Write-Host '   Si pasaron >=30 dias desde la migracion (2026-05-02),' -ForegroundColor Green
    Write-Host '   es seguro proceder con el decommission.' -ForegroundColor Green
    Write-Host ''
    Write-Host '   Ver pasos en RUNBOOK.md seccion "Decommission del proyecto legacy".' -ForegroundColor Gray
    exit 0
}

Write-Host "  Total hits             : $totalHits" -ForegroundColor White
Write-Host "  En archivos historicos : $hitsHistoricos  (OK, no bloquean)" -ForegroundColor DarkGray
if ($hitsActivos -gt 0) {
    Write-Host "  En codigo activo       : $hitsActivos  -> revisar" -ForegroundColor Red
} else {
    Write-Host "  En codigo activo       : 0  OK" -ForegroundColor Green
}
Write-Host ''

if ($hitsActivos -eq 0) {
    Write-Host 'OK: solo hay referencias en archivos historicos esperados.' -ForegroundColor Green
    Write-Host '   Seguro proceder con el decommission.' -ForegroundColor Green
    exit 0
}

Write-Host 'NO bajar el proyecto viejo todavia.' -ForegroundColor Red
Write-Host '   Revisar cada hit en codigo activo y migrarlo, o sumarlo' -ForegroundColor Red
Write-Host '   a $historicalFiles si es historico legitimo.' -ForegroundColor Red
exit 1
