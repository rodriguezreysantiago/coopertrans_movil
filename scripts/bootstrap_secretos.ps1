# =============================================================================
# Secret Manager como FUENTE UNICA de los secrets del proyecto + bootstrap multi-PC
# =============================================================================
#
# Reemplaza el "Drive personal como vault" por Google Cloud Secret Manager:
# audit log (quien accedio que secret y cuando), versionado/rotacion nativa y
# cero dependencia del Drive personal para provisionar una PC nueva.
#
# Modelo: los archivos-secreto del proyecto se guardan en Secret Manager
# codificados en BASE64 (round-trip byte-exacto: sin lios de CRLF/encoding al
# pasar binarios o .env por PowerShell). Un manifest mapea cada secret a su
# origen en el vault (para subir) y a su destino local (para bootstrap).
#
# Los 6 secrets de VALOR que ya usan las Cloud Functions via defineSecret
# (SITRACK_*, VOLVO_*, TELEGRAM_*) son RAW y NO los toca este script.
#
# Excepcion honesta: la sesion de WhatsApp (.wwebjs_auth) es un perfil Chromium
# mutante de varios MB -> NO es una credencial versionable, no va a Secret
# Manager. Sigue respaldada en el Drive por backup_secrets_a_drive.ps1.
#
# USO (PowerShell, requiere gcloud autenticado como owner/secretAccessor):
#   .\scripts\bootstrap_secretos.ps1 -Subir -DryRun        # que subiria (no toca)
#   .\scripts\bootstrap_secretos.ps1 -Subir                # vault -> Secret Manager (idempotente)
#   .\scripts\bootstrap_secretos.ps1                       # Secret Manager -> esta PC (TODO)
#   .\scripts\bootstrap_secretos.ps1 -Categoria dedicada   # solo runtime (bot/scrapers)
#   .\scripts\bootstrap_secretos.ps1 -Categoria build      # solo secrets de build (keystore/iOS/macOS)
#   .\scripts\bootstrap_secretos.ps1 -Verificar            # compara hash SM vs vault
#
# Categorias: dedicada (runtime PC dedicada) | infra (FTP/Sentry/CLI) |
#             build (keystore Android + iOS/macOS) | all (default).
#
# ROTACION de un secret:
#   1) actualiza el archivo en el vault   2) -Subir (agrega version nueva solo
#   a lo que cambio)   3) -Verificar   4) opcional: deshabilita la version
#   anterior para reducir superficie:
#     gcloud secrets versions disable <N-1> --secret=<NOMBRE> --project=coopertrans-movil
#
# NOTA seguridad: NO correr con 'Start-Transcript' activo -- el transcript
# guardaria en disco el base64 de los secrets que pasa por la sesion.
#
# NOTA encoding: ASCII puro a proposito. PowerShell 5.1 (default Windows) lee
# UTF-8 sin BOM como Latin-1 y rompe unicode. No agregar caracteres > 127.

[CmdletBinding()]
param(
    [switch]$Subir,
    [switch]$Verificar,
    [switch]$DryRun,
    [ValidateSet('all', 'dedicada', 'infra', 'build')]
    [string]$Categoria = 'all',
    [string]$BotPcId = 'dedicada',
    [string]$Project = 'coopertrans-movil',
    [string]$Vault = 'G:\Mi unidad\ClaudeCodeSync\secrets',
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

# Repo root = carpeta padre de scripts\ (donde vive este archivo).
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }

# --- Manifest: Secret <-> origen en vault <-> destino local <-> categoria -----
# EnvPcId=$true -> es el .env del bot: al restaurar se fuerza BOT_PC_ID (igual
# que sync_env_desde_drive.ps1) para no tumbar el bot por el anti-doble-bot.
$Manifest = @(
    # --- Runtime de la PC dedicada (bot + scrapers) ---
    # OJO: estos SOLO deben restaurarse en la dedicada. claves.json/service.env
    # son del cachatore; restaurarlos en otra PC no arranca nada por si solo
    # (el daemon lo levanta NSSM), pero no tienen sentido fuera de la dedicada.
    @{ Secret = 'SA_FIREBASE_ADMIN';            Vault = 'firebase\serviceAccountKey.json';                         Target = 'serviceAccountKey.json';                                     Cat = 'dedicada' }
    @{ Secret = 'WHATSAPP_BOT_ENV';             Vault = 'whatsapp-bot\.env';                                       Target = 'whatsapp-bot\.env';                                          Cat = 'dedicada'; EnvPcId = $true }
    @{ Secret = 'CACHATORE_CLAVES';             Vault = 'cachatore\claves.json';                                   Target = 'cachatore\claves.json';                                      Cat = 'dedicada' }
    @{ Secret = 'CACHATORE_SERVICE_ENV';        Vault = 'cachatore\service.env';                                   Target = 'cachatore\service.env';                                      Cat = 'dedicada' }
    # --- Infra (web/observabilidad/CLI) ---
    @{ Secret = 'FTP_DATOS';                    Vault = 'ftp\ftp_datos.txt';                                       Target = 'secretos_restaurados\ftp\ftp_datos.txt';                     Cat = 'infra' }
    @{ Secret = 'SENTRY_AUTH_TOKEN';            Vault = 'sentry\authtoken_releases.txt';                           Target = 'secretos_restaurados\sentry\authtoken_releases.txt';         Cat = 'infra' }
    @{ Secret = 'SENTRY_CLIRC';                 Vault = '.sentryclirc';                                            Target = 'secretos_restaurados\.sentryclirc';                          Cat = 'infra' }
    @{ Secret = 'FIREBASE_TOOLS_TOKEN';         Vault = 'firebase\firebase-tools.json';                            Target = 'secretos_restaurados\firebase-tools.json';                   Cat = 'infra' }
    # --- Build Android ---
    @{ Secret = 'ANDROID_KEYSTORE';             Vault = 'android\coopertrans_movil.jks';                           Target = 'android\coopertrans_movil.jks';                              Cat = 'build' }
    @{ Secret = 'ANDROID_KEY_PROPERTIES';       Vault = 'android\key.properties';                                  Target = 'android\key.properties';                                     Cat = 'build' }
    # --- Build iOS ---
    @{ Secret = 'IOS_APNS_AUTHKEY_3FQKMB32HK';  Vault = 'secrets-ios\AuthKey_3FQKMB32HK.p8';                       Target = 'secretos_restaurados\ios\AuthKey_3FQKMB32HK.p8';             Cat = 'build' }
    @{ Secret = 'IOS_APNS_AUTHKEY_7K3A7243WL';  Vault = 'secrets-ios\AuthKey_7K3A7243WL.p8';                       Target = 'secretos_restaurados\ios\AuthKey_7K3A7243WL.p8';             Cat = 'build' }
    @{ Secret = 'IOS_DIST_P12';                 Vault = 'secrets-ios\coopertrans_dist.p12';                        Target = 'secretos_restaurados\ios\coopertrans_dist.p12';              Cat = 'build' }
    @{ Secret = 'IOS_PROVISION_APPSTORE';       Vault = 'secrets-ios\Coopertrans_Movil_App_Store.mobileprovision'; Target = 'secretos_restaurados\ios\Coopertrans_Movil_App_Store.mobileprovision'; Cat = 'build' }
    @{ Secret = 'IOS_PROVISION_ADHOC';          Vault = 'secrets-ios\Coopertrans_Movil_Ad_Hoc.mobileprovision';    Target = 'secretos_restaurados\ios\Coopertrans_Movil_Ad_Hoc.mobileprovision';    Cat = 'build' }
    @{ Secret = 'IOS_PROVISION_DEV';            Vault = 'secrets-ios\Coopertrans_Movil_Development.mobileprovision'; Target = 'secretos_restaurados\ios\Coopertrans_Movil_Development.mobileprovision'; Cat = 'build' }
    # --- Build macOS ---
    @{ Secret = 'MACOS_P12';                    Vault = 'secrets-macos\CoopertransMac.p12';                        Target = 'secretos_restaurados\macos\CoopertransMac.p12';              Cat = 'build' }
    @{ Secret = 'MACOS_KEY';                    Vault = 'secrets-macos\CoopertransMac.key';                        Target = 'secretos_restaurados\macos\CoopertransMac.key';              Cat = 'build' }
    @{ Secret = 'MACOS_P12_PASSWORD';           Vault = 'secrets-macos\p12_password.txt';                          Target = 'secretos_restaurados\macos\p12_password.txt';                Cat = 'build' }
    @{ Secret = 'MACOS_PROVISION';              Vault = 'secrets-macos\Coopertrans_Movil_Mac_App_Store.provisionprofile'; Target = 'secretos_restaurados\macos\Coopertrans_Movil_Mac_App_Store.provisionprofile'; Cat = 'build' }
)

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- Helpers gcloud ----------------------------------------------------------
# El wrapper gcloud.ps1 corre python via & y, si python escribe a stderr (ej.
# NOT_FOUND esperado), bajo ErrorActionPreference=Stop eso se vuelve un error
# TERMINANTE. Lo aislamos: corremos gcloud con 'Continue' y chequeamos exit code.
function Invoke-Gc([string[]]$GcArgs) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & gcloud @GcArgs 2>$null
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    } finally {
        $ErrorActionPreference = $eap
    }
}

function Test-SecretExiste([string]$name) {
    return (Invoke-Gc @('secrets', 'describe', $name, "--project=$Project")).Code -eq 0
}

function Get-SecretB64([string]$name) {
    # Devuelve el payload (base64) de la version latest, o $null si no hay
    # (no existe, o existe pero su version latest esta DISABLED/DESTROYED).
    # -join '' (no Out-String) para no meter CRLF que romperia la idempotencia.
    $r = Invoke-Gc @('secrets', 'versions', 'access', 'latest', "--secret=$name", "--project=$Project")
    if ($r.Code -ne 0 -or $null -eq $r.Out) { return $null }
    return (($r.Out -join '').Trim())
}

function Set-SecretB64([string]$name, [string]$b64, [bool]$existe) {
    # Sube $b64 como nueva version (o crea el secret). Via temp file para no
    # depender del encoding de stdin de gcloud.
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $b64, $Utf8NoBom)
        if ($existe) {
            $r = Invoke-Gc @('secrets', 'versions', 'add', $name, "--data-file=$tmp", "--project=$Project")
        } else {
            $r = Invoke-Gc @('secrets', 'create', $name, "--data-file=$tmp", '--replication-policy=automatic', '--labels=kind=file-b64,proj=coopertrans', "--project=$Project")
        }
        return ($r.Code -eq 0)
    } finally {
        # El temp tiene el base64 del secret: avisar si quedo sin borrar.
        try { Remove-Item $tmp -Force -ErrorAction Stop }
        catch { Write-Warning "No se pudo borrar el temp con el secret: $tmp -- $($_.Exception.Message)" }
    }
}

function Get-Sha256([byte[]]$bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}

# --- Preflight: gcloud disponible --------------------------------------------
if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: no encuentro 'gcloud' en el PATH." -ForegroundColor Red
    Write-Host "       Instala el Google Cloud SDK y corre 'gcloud auth login'." -ForegroundColor Yellow
    exit 1
}

# --- Filtro por categoria ----------------------------------------------------
$items = $Manifest | Where-Object { $Categoria -eq 'all' -or $_.Cat -eq $Categoria }
if (-not $items) { Write-Host "Sin items para la categoria '$Categoria'." -ForegroundColor Yellow; exit 0 }

# =============================================================================
# MODO 1: SUBIR (vault local -> Secret Manager), idempotente.
# =============================================================================
if ($Subir) {
    Write-Host "[subir] vault -> Secret Manager ($Project) | categoria=$Categoria" -ForegroundColor Cyan
    $creados = 0; $nuevasVer = 0; $sinCambio = 0; $faltan = 0; $err = 0
    foreach ($it in $items) {
        $src = Join-Path $Vault $it.Vault
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Host "  - $($it.Secret): ORIGEN NO EXISTE ($src)" -ForegroundColor Yellow
            $faltan++; continue
        }
        $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($src))
        $existe = Test-SecretExiste $it.Secret
        if ($existe -and ((Get-SecretB64 $it.Secret) -eq $b64)) {
            Write-Host "  = $($it.Secret): sin cambios" -ForegroundColor DarkGray
            $sinCambio++; continue
        }
        if ($DryRun) {
            $accion = if ($existe) { 'nueva version' } else { 'CREAR' }
            Write-Host "  [DRY] $($it.Secret): $accion" -ForegroundColor Cyan
            continue
        }
        if (Set-SecretB64 $it.Secret $b64 $existe) {
            if ($existe) { Write-Host "  + $($it.Secret): nueva version" -ForegroundColor Green; $nuevasVer++ }
            else { Write-Host "  * $($it.Secret): creado" -ForegroundColor Green; $creados++ }
        } else {
            Write-Host "  ! $($it.Secret): ERROR al subir" -ForegroundColor Red; $err++
        }
    }
    Write-Host ""
    Write-Host "[subir] creados=$creados nuevasVersiones=$nuevasVer sinCambio=$sinCambio faltan=$faltan errores=$err"
    if ($err -gt 0) { exit 1 }
    exit 0
}

# =============================================================================
# MODO 2: VERIFICAR (hash de Secret Manager vs vault local).
# =============================================================================
if ($Verificar) {
    Write-Host "[verificar] Secret Manager vs vault | categoria=$Categoria" -ForegroundColor Cyan
    $ok = 0; $mismatch = 0; $faltaSm = 0; $faltaVault = 0
    foreach ($it in $items) {
        $src = Join-Path $Vault $it.Vault
        $hVault = if (Test-Path -LiteralPath $src) { Get-Sha256 ([System.IO.File]::ReadAllBytes($src)) } else { $null }
        $b64 = Get-SecretB64 $it.Secret
        $hSm = if ($b64) { Get-Sha256 ([Convert]::FromBase64String($b64)) } else { $null }
        if (-not $hSm) { Write-Host "  ? $($it.Secret): sin version accesible en SM (no existe o DISABLED)" -ForegroundColor Yellow; $faltaSm++; continue }
        if (-not $hVault) { Write-Host "  ? $($it.Secret): en SM pero no en vault local" -ForegroundColor DarkYellow; $faltaVault++; continue }
        if ($hSm -eq $hVault) { Write-Host "  OK $($it.Secret)" -ForegroundColor Green; $ok++ }
        else { Write-Host "  X $($it.Secret): HASH DISTINTO (SM!=vault)" -ForegroundColor Red; $mismatch++ }
    }
    Write-Host ""
    Write-Host "[verificar] ok=$ok mismatch=$mismatch faltaEnSM=$faltaSm faltaEnVault=$faltaVault"
    if ($mismatch -gt 0) { exit 1 }
    exit 0
}

# =============================================================================
# MODO 3 (default): BOOTSTRAP (Secret Manager -> archivos locales de ESTA PC).
# =============================================================================
Write-Host "[bootstrap] Secret Manager -> $RepoRoot | categoria=$Categoria" -ForegroundColor Cyan

# Guardrail RepoRoot: avisar si no parece el repo (sin .git) -> un -RepoRoot
# equivocado depositaria secrets fuera del perimetro gitignored.
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
    Write-Host "AVISO: $RepoRoot no parece un repo git (sin .git). Verifica -RepoRoot." -ForegroundColor Yellow
}

# Guardrail BOT_PC_ID: si vamos a escribir el .env y NO se paso -BotPcId
# explicito, avisar con el hostname para no pisar el .env con un PC_ID erroneo
# (el patron del incidente que casi tumba el bot). Default = 'dedicada'.
$tieneEnv = @($items | Where-Object { $_.EnvPcId }).Count -gt 0
if ($tieneEnv -and -not $PSBoundParameters.ContainsKey('BotPcId')) {
    Write-Host "AVISO: escribire BOT_PC_ID=$BotPcId en el .env del bot, en la PC '$env:COMPUTERNAME'." -ForegroundColor Yellow
    Write-Host "       Si esta NO es la dedicada, cancela (Ctrl+C) y corre con -BotPcId <id-de-esta-pc>." -ForegroundColor Yellow
}

$rest = 0; $faltan = 0; $sinVersion = 0; $err = 0
foreach ($it in $items) {
    $b64 = Get-SecretB64 $it.Secret
    if (-not $b64) {
        # Distinguir 'no existe' de 'existe pero sin version accesible'
        # (DISABLED/DESTROYED): lo segundo es un ERROR, no un faltante benigno.
        if (Test-SecretExiste $it.Secret) {
            Write-Host "  ! $($it.Secret): existe en SM pero sin version accesible (DISABLED/DESTROYED)" -ForegroundColor Red
            $sinVersion++
        } else {
            Write-Host "  - $($it.Secret): NO esta en Secret Manager (omito)" -ForegroundColor Yellow
            $faltan++
        }
        continue
    }
    $dst = Join-Path $RepoRoot $it.Target
    $dstDir = Split-Path $dst -Parent

    if ($DryRun) { Write-Host "  [DRY] $($it.Secret) -> $dst" -ForegroundColor Cyan; continue }

    try {
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        $bytes = [Convert]::FromBase64String($b64)

        if ($it.EnvPcId) {
            # .env del bot: forzar BOT_PC_ID (anti-doble-bot) y escribir UTF-8 sin BOM.
            # Sin .bak: Secret Manager ya es la fuente de verdad para recuperarlo.
            $txt = $Utf8NoBom.GetString($bytes)
            $lineas = $txt -split "`r?`n"
            $visto = $false
            $nuevo = foreach ($l in $lineas) {
                if ($l -match '^\s*BOT_PC_ID\s*=') { $visto = $true; "BOT_PC_ID=$BotPcId" } else { $l }
            }
            if (-not $visto) { $nuevo += "BOT_PC_ID=$BotPcId" }
            $texto = (($nuevo -join "`n").TrimEnd("`n")) + "`n"
            [System.IO.File]::WriteAllText($dst, $texto, $Utf8NoBom)
            Write-Host "  OK $($it.Secret) -> $($it.Target) (BOT_PC_ID=$BotPcId)" -ForegroundColor Green
        } else {
            [System.IO.File]::WriteAllBytes($dst, $bytes)
            Write-Host "  OK $($it.Secret) -> $($it.Target)" -ForegroundColor Green
        }
        $rest++
    } catch {
        Write-Host "  ! $($it.Secret): ERROR -- $($_.Exception.Message)" -ForegroundColor Red; $err++
    }
}

# Chequeo Android: si restauramos key.properties, el storeFile que referencia
# debe existir. Hoy storeFile es una ruta absoluta por-PC y el .jks lo dejamos
# en android\, que puede NO coincidir -> sin este aviso el build fallaria con
# un 'keystore file does not exist' a pesar del bootstrap OK.
if (-not $DryRun -and ($items | Where-Object { $_.Secret -eq 'ANDROID_KEY_PROPERTIES' })) {
    $kp = Join-Path $RepoRoot 'android\key.properties'
    if (Test-Path -LiteralPath $kp) {
        $store = ((Get-Content -LiteralPath $kp | Where-Object { $_ -match '^\s*storeFile\s*=' } | Select-Object -First 1) -replace '^\s*storeFile\s*=\s*', '').Trim()
        if ($store -and -not (Test-Path -LiteralPath $store)) {
            Write-Host "AVISO Android: key.properties.storeFile apunta a '$store', que NO existe en esta PC." -ForegroundColor Yellow
            Write-Host "       El keystore se restauro en android\coopertrans_movil.jks: ajusta storeFile o copia el .jks." -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "[bootstrap] restaurados=$rest faltan=$faltan sinVersion=$sinVersion errores=$err"
if ($Categoria -eq 'all' -or $Categoria -eq 'dedicada') {
    Write-Host "NOTA: la sesion de WhatsApp (.wwebjs_auth) NO esta en Secret Manager." -ForegroundColor Yellow
    Write-Host "      Restaurala del Drive (bot-pc-dedicada\.wwebjs_auth) o escanea el QR." -ForegroundColor Yellow
}
# Un bootstrap incompleto (falta algo o hay version inaccesible) sale != 0 para
# que el operador NO crea que la PC quedo bien provisionada.
if ($err -gt 0 -or $sinVersion -gt 0 -or $faltan -gt 0) { exit 1 }
exit 0
