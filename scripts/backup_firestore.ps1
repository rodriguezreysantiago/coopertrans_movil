# Backup de Firestore via gcloud firestore export.
#
# Genera un export completo de Firestore a un bucket GCS. Esto es la
# linea de defensa basica para disaster recovery: si algo se rompe en
# Firestore (admin borra docs por error, migracion mala, ataque, etc.)
# se puede restaurar al estado de un backup previo.
#
# REQUISITOS antes de correr (one-time setup):
#   1. gcloud CLI instalado y autenticado:
#        gcloud auth login
#        gcloud config set project coopertrans-movil
#
#   2. Bucket GCS para los backups:
#        gcloud storage buckets create gs://coopertrans-movil-backups `
#          --project=coopertrans-movil `
#          --location=southamerica-east1 `
#          --uniform-bucket-level-access
#
#      Region southamerica-east1 minimiza latencia desde Argentina y
#      matchea la region de Firestore (mismo proyecto migrado el 2026-05).
#
#   3. Permisos: la SA por default ya tiene permisos para hacer export.
#      Si falla con "permission denied", asignar Cloud Datastore Import
#      Export Admin a la SA que corre gcloud.
#
# Uso manual:
#   .\scripts\backup_firestore.ps1
#
# Uso programado (Cloud Scheduler en GCP, recomendado para diario):
#   Ver "Programar Cloud Scheduler" en RUNBOOK.md.
#
# Uso programado alternativo (Windows Task Scheduler -- requiere PC
# encendida): igual que backup_wwebjs_auth.ps1 pero con este script.
#
# Costo: el export en si es gratis. Storage en GCS es ~0.02 USD/GB/mes
# en region southamerica-east1. Una flota chica como Vecchi pesa < 50 MB
# por export, asi que ~30 backups diarios = 1.5 GB = ~3 centavos/mes.

$ErrorActionPreference = 'Stop'

$projectId = if ($env:FIREBASE_PROJECT_ID) {
    $env:FIREBASE_PROJECT_ID
} else {
    'coopertrans-movil'
}

$bucket = if ($env:FIRESTORE_BACKUP_BUCKET) {
    $env:FIRESTORE_BACKUP_BUCKET
} else {
    "gs://coopertrans-movil-backups"
}

# Retencion: cuantos dias mantener (default 30).
$retencionDias = if ($env:FIRESTORE_BACKUP_RETENCION_DIAS) {
    [int]$env:FIRESTORE_BACKUP_RETENCION_DIAS
} else {
    30
}

$fecha = Get-Date -Format 'yyyy-MM-dd_HHmm'
$prefix = "$bucket/$fecha"

function Write-Log {
    param([string]$msg)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$stamp] $msg"
}

try {
    Write-Log "Inicio backup Firestore -> $prefix"

    # Verificar gcloud disponible.
    $gcloud = Get-Command gcloud -ErrorAction SilentlyContinue
    if (-not $gcloud) {
        Write-Log "ERROR: gcloud CLI no esta instalado o no esta en PATH."
        Write-Log "Instalar desde: https://cloud.google.com/sdk/docs/install"
        exit 1
    }

    # Export. Mantener una lista hardcoded de colecciones es una bomba
    # de tiempo — cada vez que aparece un modulo nuevo (Logistica, ICM,
    # Gomeria, EMPRESAS_EMPLEADORAS, vigilador v2, etc.) el backup
    # queda incompleto silenciosamente y la proxima recovery descubre
    # que faltan datos. Auditoria 2026-05-16 detecto 14+ colecciones
    # no incluidas (VIAJES_LOGISTICA, ADELANTOS_CHOFER, JORNADAS,
    # EMPRESAS_LOGISTICA, UBICACIONES_LOGISTICA, TARIFAS_LOGISTICA,
    # ASIGNACIONES_ENGANCHE, CUBIERTAS*, EMPRESAS_EMPLEADORAS,
    # SITRACK_EVENTOS, ICM_SEMANAL, VOLVO_SCORES_DIARIOS, etc).
    #
    # Sacamos el filtro: ahora exporta TODAS las colecciones del proyecto.
    # Pesa un poco mas (incluye colecciones efimeras como LOGIN_ATTEMPTS,
    # AVISOS_AUTOMATICOS_HISTORICO, MANTENIMIENTOS_AVISADOS) pero el
    # ahorro es despreciable frente al riesgo de no tener disaster
    # recovery completo.

    & gcloud firestore export $prefix `
        --project=$projectId

    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: gcloud firestore export fallo (exit $LASTEXITCODE)"
        exit 1
    }

    Write-Log "Backup OK: $prefix"

    # Retencion: borrar exports mas viejos que $retencionDias dias.
    $cutoff = (Get-Date).AddDays(-$retencionDias).ToString('yyyy-MM-dd')
    Write-Log "Retencion: borrar exports anteriores a $cutoff..."

    # Listar exports y filtrar por nombre (que empiezan con yyyy-MM-dd).
    $listado = & gcloud storage ls $bucket 2>$null
    if ($LASTEXITCODE -eq 0) {
        $borrados = 0
        foreach ($linea in $listado) {
            $linea = $linea.TrimEnd('/')
            $base = Split-Path -Leaf $linea
            # Solo procesar carpetas con formato yyyy-MM-dd_HHmm.
            if ($base -match '^(\d{4}-\d{2}-\d{2})') {
                $fechaExport = $matches[1]
                if ($fechaExport -lt $cutoff) {
                    Write-Log "  Borrando $linea"
                    & gcloud storage rm --recursive $linea 2>$null
                    if ($LASTEXITCODE -eq 0) { $borrados++ }
                }
            }
        }
        Write-Log "Retencion: borrados $borrados export(s) > $retencionDias dias"
    } else {
        Write-Log "WARNING: no pude listar $bucket para retencion"
    }

    Write-Log "Fin OK"
    exit 0
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
