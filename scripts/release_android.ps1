# Buildea el release de Android y lo distribuye:
#   - Por defecto: APK -> Firebase App Distribution (testers internos).
#   - Con -PlayStore:  AAB -> queda listo en disco para subir a Play Console
#     (no se publica automaticamente; Google exige subida manual o via API).
#
# Pre-requisitos:
#   - android/key.properties con las contraseñas del keystore configuradas.
#   - firebase CLI instalado y autenticado (solo si NO usas -PlayStore).
#   - flutter en el PATH.
#
# Uso (desde la raíz del repo):
#   .\scripts\release_android.ps1
#   .\scripts\release_android.ps1 -Notes "Corrección de agrupador Volvo"
#   .\scripts\release_android.ps1 -Groups "choferes,admins"
#   .\scripts\release_android.ps1 -DryRun
#   .\scripts\release_android.ps1 -PlayStore     # genera el .aab para Play Console

param(
    [string]$Notes    = '',
    [string]$Groups   = 'testers',
    [switch]$DryRun,
    [switch]$PlayStore
)

$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param([scriptblock]$Block)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Block } finally { $ErrorActionPreference = $prev }
}

$repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pubspec    = Join-Path $repoRoot 'pubspec.yaml'
$keyProps   = Join-Path $repoRoot 'android\key.properties'
$apkPath    = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-release.apk'
$aabPath    = Join-Path $repoRoot 'build\app\outputs\bundle\release\app-release.aab'
$firebaseAppId = '1:808925655961:android:9238749f27b21130a4d908'

# --- 1. Leer versión -------------------------------------------------
$verLine = (Get-Content $pubspec) | Where-Object { $_ -match '^version:\s*(\S+)' } | Select-Object -First 1
if (-not $verLine) { throw "No encuentro 'version:' en pubspec.yaml" }
$version = ($verLine -replace '^version:\s*', '').Trim()
$tag = "v$version"

$modo = if ($PlayStore) { 'PLAY STORE (AAB)' } else { 'APP DISTRIBUTION (APK)' }
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "RELEASE ANDROID: $tag — $modo" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# --- 2. Verificar key.properties -------------------------------------
if (-not (Test-Path $keyProps)) {
    Write-Host "ERROR: no encontré android/key.properties" -ForegroundColor Red
    Write-Host "Creá el archivo con:" -ForegroundColor Yellow
    Write-Host "  storePassword=TU_PASSWORD" -ForegroundColor Yellow
    Write-Host "  keyPassword=TU_PASSWORD" -ForegroundColor Yellow
    Write-Host "  keyAlias=coopertrans_key" -ForegroundColor Yellow
    Write-Host "  storeFile=C:/Users/Colo Logistica/keystores/coopertrans_movil.jks" -ForegroundColor Yellow
    exit 1
}
$keyContent = Get-Content $keyProps -Raw
if ($keyContent -match 'REEMPLAZAR') {
    Write-Host "ERROR: android/key.properties todavía tiene valores placeholder." -ForegroundColor Red
    Write-Host "Reemplazá REEMPLAZAR_CON_TU_PASSWORD con tus contraseñas reales." -ForegroundColor Yellow
    exit 1
}

# --- 3. Verificar firebase CLI (solo modo App Distribution) ----------
if (-not $PlayStore) {
    $fb = Get-Command firebase -ErrorAction SilentlyContinue
    if (-not $fb) {
        throw "firebase CLI no encontrado. Instalar con: npm install -g firebase-tools"
    }
    Invoke-Native { & firebase projects:list *>$null }
    if ($LASTEXITCODE -ne 0) {
        throw "firebase CLI no está autenticado. Correr: firebase login"
    }
}

# --- 4. Verificar git limpio -----------------------------------------
Push-Location $repoRoot
try {
    $dirty = Invoke-Native { git status --porcelain }
    if ($dirty) {
        Write-Host "ADVERTENCIA: hay cambios sin commitear:" -ForegroundColor Yellow
        Write-Host $dirty
        $confirm = Read-Host "¿Seguir igual? (s/N)"
        if ($confirm -ne 's' -and $confirm -ne 'S') { exit 1 }
    }
} finally { Pop-Location }

# --- 5. Build release (APK o AAB segun modo) -------------------------
Write-Host ""
$artefacto  = if ($PlayStore) { 'AAB' } else { 'APK' }
$cmd        = if ($PlayStore) { 'appbundle' } else { 'apk' }
$outPath    = if ($PlayStore) { $aabPath } else { $apkPath }
# Carpeta donde flutter genera los symbols Dart (1 archivo por arch).
# Sin estos symbols, Sentry muestra los crashes Dart como offsets crudos
# tipo `+0x4eb638` que son inutiles para diagnosticar.
$symbolsDir = Join-Path $repoRoot 'build\symbols'
Write-Host "[1/3] Buildeando $artefacto release con symbols Dart..." -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "  [DRY-RUN] flutter build $cmd --release --obfuscate --split-debug-info=$symbolsDir" -ForegroundColor Yellow
} else {
    # Crear carpeta de symbols si no existe (idempotente).
    if (-not (Test-Path $symbolsDir)) {
        New-Item -ItemType Directory -Force -Path $symbolsDir | Out-Null
    }
    Push-Location $repoRoot
    try {
        Invoke-Native { & flutter build $cmd --release --obfuscate --split-debug-info=$symbolsDir }
        if ($LASTEXITCODE -ne 0) { throw "flutter build $cmd falló" }
    } finally { Pop-Location }
}

if (-not $DryRun -and -not (Test-Path $outPath)) {
    Write-Host "ERROR: no encontré el $artefacto en $outPath" -ForegroundColor Red
    exit 1
}

if (-not $DryRun) {
    $sizeMB = [math]::Round((Get-Item $outPath).Length / 1MB, 1)
    Write-Host "  OK — $artefacto`: $sizeMB MB" -ForegroundColor Green
}

# --- 5b. Subir symbols Dart a Sentry (best-effort) -------------------
# Para que cada crash en Sentry venga con stack legible (linea de codigo
# en lugar de offset hex), subimos los .symbols generados por
# --split-debug-info. Si sentry-cli no esta instalado o falta config,
# salta sin fallar — el AAB es valido igual.
#
# Setup one-time por maquina:
#   1) Instalar sentry-cli:
#        npm install -g @sentry/cli       (cualquier OS)
#        scoop install sentry-cli         (Win, alternativa)
#        brew install getsentry/tools/sentry-cli  (Mac)
#   2) Configurar org/project/auth token via git config:
#        git config sentry.org      "<tu-org>"
#        git config sentry.project  "flutter"
#        git config sentry.authtoken "sntrys_xxxxxx..."
#      (el auth token lo generas en Sentry > Settings > Account >
#       Auth Tokens, con scope `project:releases` y `project:write`).
if (-not $DryRun) {
    Write-Host ""
    Write-Host "[2/3] Subiendo symbols a Sentry..." -ForegroundColor Cyan
    $sentryCli = Get-Command sentry-cli -ErrorAction SilentlyContinue
    $sentryOrg     = (Invoke-Native { & git config --get sentry.org }) | Out-String
    $sentryProject = (Invoke-Native { & git config --get sentry.project }) | Out-String
    $sentryToken   = (Invoke-Native { & git config --get sentry.authtoken }) | Out-String
    $sentryOrg     = $sentryOrg.Trim()
    $sentryProject = $sentryProject.Trim()
    $sentryToken   = $sentryToken.Trim()

    if (-not $sentryCli) {
        Write-Host "  sentry-cli no esta instalado. Salto upload de symbols." -ForegroundColor Yellow
        Write-Host "  Para activarlo: npm install -g @sentry/cli + git config sentry.{org,project,authtoken}" -ForegroundColor DarkGray
    } elseif (-not $sentryOrg -or -not $sentryProject -or -not $sentryToken) {
        Write-Host "  Falta config Sentry (sentry.org/project/authtoken). Salto upload." -ForegroundColor Yellow
        Write-Host "  Para activarlo: git config sentry.org/project/authtoken (ver comentarios del script)." -ForegroundColor DarkGray
    } else {
        Push-Location $repoRoot
        try {
            Invoke-Native {
                & sentry-cli debug-files upload `
                    --auth-token $sentryToken `
                    --org $sentryOrg `
                    --project $sentryProject `
                    --include-sources `
                    $symbolsDir
            }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  WARN: sentry-cli upload fallo (exit $LASTEXITCODE). El AAB sigue valido." -ForegroundColor Yellow
            } else {
                Write-Host "  OK — symbols subidos a Sentry." -ForegroundColor Green
            }
        } finally { Pop-Location }
    }
}

# --- 6. Modo Play Store: parar aca con instrucciones de subida ------
if ($PlayStore) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "OK AAB LISTO PARA PLAY CONSOLE" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Archivo:" -ForegroundColor Cyan
    Write-Host "  $aabPath" -ForegroundColor White
    Write-Host ""
    Write-Host "Proximos pasos manuales:" -ForegroundColor Cyan
    Write-Host "  1) Abrir https://play.google.com/console/" -ForegroundColor White
    Write-Host "  2) App 'Coopertrans Movil' -> Testing -> Closed testing" -ForegroundColor White
    Write-Host "  3) Crear nueva release -> Subir el .aab de arriba" -ForegroundColor White
    Write-Host "  4) Pegar release notes / changelog" -ForegroundColor White
    Write-Host "  5) Save -> Review release -> Start rollout" -ForegroundColor White
    Write-Host ""
    Write-Host "La primera vez que subis un AAB Google va a pedirte" -ForegroundColor Yellow
    Write-Host "que registres el upload key (es la coopertrans_movil.jks)." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# --- 6b. Armar notas de release (solo App Distribution) --------------
if (-not $Notes) {
    Push-Location $repoRoot
    try {
        $log = Invoke-Native { git log --oneline -5 --no-decorate }
        $Notes = "v$version`n`n" + ($log | ForEach-Object { "- $_" } | Out-String).Trim()
    } finally { Pop-Location }
}

# --- 7. Subir a Firebase App Distribution ----------------------------
Write-Host ""
Write-Host "[2/3] Subiendo a Firebase App Distribution (grupos: $Groups)..." -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "  [DRY-RUN] firebase appdistribution:distribute $apkPath" -ForegroundColor Yellow
    Write-Host "    --app $firebaseAppId" -ForegroundColor Yellow
    Write-Host "    --groups `"$Groups`"" -ForegroundColor Yellow
    Write-Host "    --release-notes `"$Notes`"" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Para publicar realmente:" -ForegroundColor Cyan
    Write-Host "  .\scripts\release_android.ps1" -ForegroundColor White
    exit 0
}

Push-Location $repoRoot
try {
    Invoke-Native {
        & firebase appdistribution:distribute $apkPath `
            --app $firebaseAppId `
            --groups $Groups `
            --release-notes $Notes
    }
    if ($LASTEXITCODE -ne 0) { throw "firebase appdistribution:distribute falló" }
} finally { Pop-Location }

# --- 8. Resultado ----------------------------------------------------
Write-Host ""
Write-Host "[3/3] APK distribuido correctamente." -ForegroundColor Green
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "OK ANDROID $tag → App Distribution" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Los testers del grupo '$Groups' van a recibir una" -ForegroundColor Cyan
Write-Host "notificación para actualizar en su celular." -ForegroundColor Cyan
