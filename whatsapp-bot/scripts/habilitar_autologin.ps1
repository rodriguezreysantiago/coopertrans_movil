# Habilita auto-login del user actual en Windows usando Autologon de
# Sysinternals (la pass se guarda encriptada en LSA Secrets, NO en
# plain text en el registry).
#
# Pensado para la PC dedicada al bot: como la maquina arranca sola
# tras un corte de luz / reboot, conviene que entre directo a la
# sesion del user para que el shortcut Startup abra la ventana de
# logs sin esperar login manual.
#
# Trade-off de seguridad: cualquiera con acceso fisico a la PC entra
# sin pass. Aceptable en oficina cerrada con llave; NO recomendado en
# notebook que sale del lugar. Acceso remoto (RDP) sigue exigiendo
# pass - auto-login solo aplica al boot de consola.
#
# USO:
#   .\habilitar_autologin.ps1 -Password '<password-de-windows>'
#
#   Si omitis -Password, el script lo prompteea de forma segura
#   (Read-Host -AsSecureString, no aparece en el historial).
#
# REQUIERE Administrador.
#
# DESACTIVAR auto-login:
#   .\habilitar_autologin.ps1 -Disable

[CmdletBinding()]
param(
    [string]$Password = $null,
    [string]$UserName = $env:USERNAME,
    [string]$Domain = $env:COMPUTERNAME,
    [switch]$Disable
)

$ErrorActionPreference = 'Stop'

# --- Verificar admin -------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'ERROR: ejecutar como Administrador.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  AUTO-LOGIN (Sysinternals Autologon)' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan

# --- Descargar Autologon64.exe si no esta ---------------------------
$autologonPath = Join-Path $env:TEMP 'Autologon64.exe'
if (-not (Test-Path $autologonPath)) {
    Write-Host ''
    Write-Host '[1/3] Descargando Autologon64.exe de live.sysinternals.com...' -ForegroundColor Cyan
    try {
        $url = 'https://live.sysinternals.com/Autologon64.exe'
        Invoke-WebRequest -Uri $url -OutFile $autologonPath -UseBasicParsing
        Write-Host "  OK descargado en $autologonPath" -ForegroundColor Green
    } catch {
        Write-Host "  FAIL no pude descargar: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Bajalo manual de https://learn.microsoft.com/sysinternals/downloads/autologon' -ForegroundColor Yellow
        Write-Host "  y guardalo como $autologonPath" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host ''
    Write-Host "[1/3] Autologon64.exe ya descargado en $autologonPath" -ForegroundColor DarkGray
}

# --- Modo Disable ---------------------------------------------------
if ($Disable) {
    Write-Host ''
    Write-Host '[2/3] Desactivando auto-login...' -ForegroundColor Cyan
    & $autologonPath /accepteula $UserName $Domain '' | Out-Host
    Write-Host ''
    Write-Host '  OK auto-login desactivado. En el proximo boot va a pedir pass.' -ForegroundColor Green
    exit 0
}

# --- Pedir pass si no se paso por arg ------------------------------
if (-not $Password) {
    Write-Host ''
    $secure = Read-Host -Prompt "Password de $UserName" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

# --- Configurar auto-login ------------------------------------------
Write-Host ''
Write-Host "[2/3] Configurando auto-login para: $Domain\$UserName" -ForegroundColor Cyan

# Autologon64 sintaxis:
#   Autologon64.exe -accepteula USERNAME DOMAIN PASSWORD
# La pass queda encriptada en LSA Secrets (HKLM:\SECURITY\Policy\Secrets).
# Es MUCHO mas seguro que el patron viejo de meterla en
# HKLM:\...\Winlogon\DefaultPassword en plain text.
& $autologonPath /accepteula $UserName $Domain $Password | Out-Host

if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
    Write-Host ''
    Write-Host '[3/3] Verificacion final...' -ForegroundColor Cyan
    $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $autoAdmin = (Get-ItemProperty -Path $winlogonPath -Name AutoAdminLogon -ErrorAction SilentlyContinue).AutoAdminLogon
    $defaultUser = (Get-ItemProperty -Path $winlogonPath -Name DefaultUserName -ErrorAction SilentlyContinue).DefaultUserName
    if ($autoAdmin -eq '1' -and $defaultUser -eq $UserName) {
        Write-Host '  OK Registry actualizado correctamente.' -ForegroundColor Green
        Write-Host ''
        Write-Host '====================================================' -ForegroundColor Green
        Write-Host '  AUTO-LOGIN ACTIVO' -ForegroundColor Green
        Write-Host '====================================================' -ForegroundColor Green
        Write-Host ''
        Write-Host "  User:     $Domain\$UserName" -ForegroundColor White
        Write-Host '  Password: encriptada en LSA Secrets (no plain text)' -ForegroundColor White
        Write-Host ''
        Write-Host '  En el proximo reboot, Windows va a loguear solo' -ForegroundColor Cyan
        Write-Host '  sin pedir pass en la pantalla de login.' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  IMPORTANTE: RDP (Remote Desktop) SIGUE pidiendo pass' -ForegroundColor Yellow
        Write-Host '  para conectarse - solo afecta la consola fisica.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Para DESACTIVAR auto-login mas adelante:' -ForegroundColor DarkGray
        Write-Host "    .\habilitar_autologin.ps1 -Disable" -ForegroundColor DarkGray
        Write-Host ''
    } else {
        Write-Host '  WARN Registry no quedo como esperado:' -ForegroundColor Yellow
        Write-Host "    AutoAdminLogon = $autoAdmin (esperado 1)" -ForegroundColor Yellow
        Write-Host "    DefaultUserName = $defaultUser (esperado $UserName)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  FAIL Autologon64 devolvio exit $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
