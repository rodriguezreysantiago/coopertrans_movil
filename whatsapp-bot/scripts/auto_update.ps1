# Auto-update del bot WhatsApp desde git (opcion A del plan 2026-05-15).
#
# Disenado para correr cada N minutos como Scheduled Task en la PC dedicada,
# bajo cuenta SYSTEM (la misma que corre el servicio CoopertransMovilBot).
#
# Flujo:
#   1. git fetch origin main (sin red de seguridad: si no hay internet, exit silencioso)
#   2. Si el HEAD remoto == HEAD local -> nada que hacer (exit silencioso, no loguear ruido)
#   3. Si hay cambios bajo whatsapp-bot/** -> deploy:
#        a) git pull --ff-only
#        b) si package.json o package-lock.json cambio -> npm install --silent
#        c) Restart-Service CoopertransMovilBot
#        d) esperar 90s
#        e) smoke test: chequear que el bot heartbeatea via bot_estado_remoto.js --json
#        f) log resultado (OK / WARNING) - sin rollback automatico
#   4. Si hay cambios pero NO tocan whatsapp-bot/** -> fast-forward sin restart (siempre util tener el repo al dia para scripts/diagnostico)
#
# Lockfile para evitar overlap si un deploy tarda mas que el intervalo de polling.
#
# Log: whatsapp-bot/logs/auto_update.log (rotacion manual cuando supere 5 MB)

$ErrorActionPreference = 'Stop'

# --- Paths absolutos (Scheduled Task corre sin cwd predecible) ------
$BotDir   = "C:\coopertrans_movil\whatsapp-bot"
$RepoRoot = "C:\coopertrans_movil"
$LogDir   = Join-Path $BotDir "logs"
$LogFile  = Join-Path $LogDir "auto_update.log"
$LockFile = Join-Path $LogDir "auto_update.lock"

# Verificacion temprana - si el path no existe, no es esta PC, salir silencioso
if (-not (Test-Path $BotDir)) { exit 0 }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# --- Helpers --------------------------------------------------------
function Write-Log {
    param([string]$Level, [string]$Msg)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    "$ts [$Level] $Msg" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Rotate-LogIfBig {
    if (Test-Path $LogFile) {
        $size = (Get-Item $LogFile).Length
        if ($size -gt 5MB) {
            Move-Item $LogFile "$LogFile.1" -Force
            Write-Log 'INFO' "Log rotado (tamano anterior: $size bytes)"
        }
    }
}

# --- Lockfile (anti-overlap) ----------------------------------------
if (Test-Path $LockFile) {
    $lockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($lockAge.TotalMinutes -lt 30) {
        # Otro auto-update esta corriendo (o quedo colgado < 30 min). Salir silencioso.
        exit 0
    } else {
        Write-Log 'WARN' "Lockfile stale (>30 min). Lo limpio y sigo."
        Remove-Item $LockFile -Force
    }
}
New-Item -ItemType File -Path $LockFile -Force | Out-Null

try {
    Rotate-LogIfBig

    Set-Location $RepoRoot

    # --- 1. git fetch (silencioso si falla por red) -----------------
    # `2>&1` con $EAP=Stop en PS 5.1 convierte stderr en ErrorRecord
    # y aborta. Usamos $EAP local 'Continue' para capturar stderr en
    # variable como string sin crashear.
    $fetchOut = & {
        $ErrorActionPreference = 'Continue'
        git fetch origin main 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'WARN' "git fetch fallo (sin internet?): $fetchOut"
        exit 0
    }

    # --- 2. Chequear si hay commits nuevos --------------------------
    $localHead  = (git rev-parse HEAD).Trim()
    $remoteHead = (git rev-parse origin/main).Trim()

    if ($localHead -eq $remoteHead) {
        # Sin cambios. Exit silencioso (no spamear el log).
        exit 0
    }

    # --- 3. Ver que archivos cambiaron entre localHead y remoteHead -
    $changedFiles = git diff --name-only $localHead $remoteHead
    $tocaBot = $changedFiles | Where-Object { $_ -like 'whatsapp-bot/*' }
    $tocaPkg = $changedFiles | Where-Object { $_ -eq 'whatsapp-bot/package.json' -or $_ -eq 'whatsapp-bot/package-lock.json' }
    $tocaCachatore = $changedFiles | Where-Object { $_ -like 'cachatore/*' }

    Write-Log 'INFO' "PULL EN PROCESO: actualizando $($localHead.Substring(0,7)) -> $($remoteHead.Substring(0,7)) ($($changedFiles.Count) archivo/s)..."

    # --- 4. git pull --ff-only --------------------------------------
    $pullOut = & {
        $ErrorActionPreference = 'Continue'
        git pull --ff-only origin main 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'ERROR' "git pull fallo: $pullOut"
        exit 1
    }

    # --- Cachatore: reiniciar el vigia si cambio cachatore/** -------
    # Es un servicio aparte (Python, cachatore-vigia); el bot de WhatsApp
    # no se toca. Restart liviano (no necesita el grace period del bot).
    # Solo si el servicio esta instalado en esta PC.
    if ($tocaCachatore) {
        $svcVigia = Get-Service -Name cachatore-vigia -ErrorAction SilentlyContinue
        if ($svcVigia) {
            Write-Log 'INFO' "Cambios tocan cachatore/**, reiniciando cachatore-vigia..."
            try {
                Restart-Service -Name cachatore-vigia -ErrorAction Stop
                Write-Log 'INFO' "cachatore-vigia reiniciado OK."
            } catch {
                Write-Log 'WARNING' "No pude reiniciar cachatore-vigia: $($_.Exception.Message)"
            }
        } else {
            Write-Log 'INFO' "cachatore/** cambio pero cachatore-vigia no esta instalado aca (omito)."
        }
    }

    if (-not $tocaBot) {
        Write-Log 'INFO' "Pull OK, no toca whatsapp-bot/** (sin restart del bot)."
        exit 0
    }

    Write-Log 'INFO' "Cambios tocan whatsapp-bot/**, iniciando deploy."

    # --- 5. npm install si package cambio ---------------------------
    if ($tocaPkg) {
        Write-Log 'INFO' "package.json o package-lock.json cambio, corriendo npm install..."
        Set-Location $BotDir
        $npmOut = & {
            $ErrorActionPreference = 'Continue'
            npm install --silent 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Log 'ERROR' "npm install fallo: $npmOut"
            exit 1
        }
        Write-Log 'INFO' "npm install OK."
        Set-Location $RepoRoot
    }

    # --- 6. Restart graceful (NO usar Restart-Service) --------------
    #
    # IMPORTANTE (Fase 24/7 2026-05-18): Restart-Service mata el proceso
    # demasiado rapido - entre el Stop y el Start, NSSM envia SIGINT
    # pero no espera al graceful shutdown del bot (que toma ~10-70s
    # segun envios en curso). Si el bot estaba commiteando a
    # `.wwebjs_auth/` cuando lo matan, la carpeta queda corrupta y la
    # proxima vez pide QR.
    #
    # Secuencia correcta: Stop-Service + wait + Start-Service. NSSM
    # respeta SIGINT y el bot tiene tiempo de cerrar limpio, hacer
    # backup pre-shutdown a Cloud Storage, y deshacer locks de
    # `.wwebjs_auth/` antes del exit.
    $svc = Get-Service -Name CoopertransMovilBot -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log 'ERROR' "Servicio CoopertransMovilBot no existe en esta PC. Cancelado."
        exit 1
    }

    Write-Log 'INFO' "Stop-Service CoopertransMovilBot (graceful, espera SIGINT + backup)..."
    Stop-Service -Name CoopertransMovilBot
    # Espera generosa: 75s cubre el grace period default del bot
    # (DELAY_MAX_MS=60000 + 10s + backup pre-shutdown ~5s).
    Write-Log 'INFO' "Esperando 75s para que termine envios en curso + backup pre-shutdown..."
    Start-Sleep -Seconds 75
    # Verificar que efectivamente este Stopped antes de arrancar.
    $svcCheck = Get-Service -Name CoopertransMovilBot
    if ($svcCheck.Status -ne 'Stopped') {
        Write-Log 'WARNING' "Servicio sigue $($svcCheck.Status) tras 75s. Forzando stop..."
        Stop-Service -Name CoopertransMovilBot -Force
        Start-Sleep -Seconds 10
    }
    Write-Log 'INFO' "Start-Service CoopertransMovilBot..."
    Start-Service -Name CoopertransMovilBot
    Write-Log 'INFO' "Start-Service OK. Smoke test con reintentos (hasta ~4 min)..."

    # --- 7. Smoke test via bot_estado_remoto.js --json -------------------
    # El bot puede tardar 2-4 min en quedar LISTO (a veces reinicia el cliente
    # de WhatsApp internamente). En lugar de chequear una sola vez a los 90s
    # (que daba un falso "sospechoso" cuando el bot solo estaba tardando),
    # polleamos cada 20s y cortamos OK apenas esta LISTO. Solo si NUNCA llega
    # tras ~4 min damos WARNING.
    Set-Location $RepoRoot
    $listo = $false
    $ultimoEstado = '?'
    $intentos = 12   # 12 x 20s = ~4 min
    for ($i = 1; $i -le $intentos; $i++) {
        Start-Sleep -Seconds 20
        $jsonOut = & {
            $ErrorActionPreference = 'Continue'
            & node "scripts\bot_estado_remoto.js" --json 2>&1
        }
        if ($LASTEXITCODE -ne 0) { continue }   # el chequeo fallo; reintentar
        try {
            $health = $jsonOut | ConvertFrom-Json
            $hbAgeSeg = [math]::Floor(((Get-Date).ToUniversalTime() - [DateTime]'1970-01-01').TotalSeconds - $health.ultimoHeartbeat._seconds)
            $ultimoEstado = $health.estadoCliente
            if ($hbAgeSeg -lt 120 -and $ultimoEstado -eq 'LISTO') {
                Write-Log 'INFO' "Smoke test OK: bot LISTO (~$($i * 20)s), heartbeat hace ${hbAgeSeg}s, version $($health.bot.version)."
                $listo = $true
                break
            }
        } catch {
            # JSON ilegible en este intento; reintentar.
        }
    }
    if (-not $listo) {
        Write-Log 'WARNING' "Smoke test: el bot no llego a LISTO tras ~4 min (ultimo estado=$ultimoEstado)."
        Write-Log 'WARNING' "DEPLOY hecho pero conviene revisar los logs del bot."
    }

} catch {
    Write-Log 'ERROR' "Excepcion no manejada: $($_.Exception.Message)"
    Write-Log 'ERROR' "Stack: $($_.ScriptStackTrace)"
    exit 1
} finally {
    if (Test-Path $LockFile) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }
}
