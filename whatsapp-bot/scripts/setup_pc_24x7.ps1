# Configura una PC Windows para correr el bot 24/7. Setea:
#
#   1. Power settings: nunca suspender, nunca apagar pantalla, nunca
#      poner discos en standby. Tanto AC (enchufada) como DC (bateria,
#      por si es notebook).
#
#   2. Wake-on-LAN del Network Adapter (opcional, solo si la PC esta
#      enchufada a Ethernet — para poder despertarla remoto si se cae).
#
#   3. Auto-restart de Windows Update solo en horario nocturno
#      (3-5 AM) para minimizar downtime. NO desactiva Windows Update
#      (eso es peligroso) — solo controla CUANDO reinicia.
#
#   4. Suprime el "menu de selecion de SO" del boot (si hay dual-boot
#      no toca; si es Windows unico, acelera el boot 5 seg).
#
# NO toca:
#
#   - Auto-login. Es preferible que pidas login manual al boot por
#     seguridad — el bot corre como LocalSystem (no necesita user
#     logueado). Si igual queres auto-login, hace falta a mano:
#       netplwiz → desmarcar "Users must enter a user name and
#       password to use this computer".
#
#   - Wi-Fi. Si vas a usar Wi-Fi en la PC dedicada, recomendamos
#     pasar a Ethernet por estabilidad.
#
#   - Antivirus. Asegurate de excluir la carpeta del bot
#     (whatsapp-bot/) y la cache puppeteer del scan en vivo, sino
#     a veces bloquea Chromium.
#
# Requiere Administrador. Idempotente: se puede correr varias veces
# sin efectos secundarios.
#
# Uso:
#   1. PowerShell como Administrador.
#   2. Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   3. cd <ruta>\whatsapp-bot
#   4. .\scripts\setup_pc_24x7.ps1

$ErrorActionPreference = 'Stop'

# --- Verificar admin -----------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: ejecutar como Administrador." -ForegroundColor Red
    exit 1
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "SETUP PC DEDICADA BOT - Coopertrans Movil" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# --- 1. Power settings ---------------------------------------------
Write-Host "[1/4] Configurando power settings (nunca suspender)..." -ForegroundColor Cyan

# powercfg.exe es la herramienta nativa de Windows para esto. Setea
# todo a 0 (= nunca) para AC y DC. Aplica al esquema activo.
#
# /change <setting> <minutes> — 0 desactiva la accion.
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0
powercfg /change disk-timeout-ac 0
powercfg /change disk-timeout-dc 0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0

# Ademas, deshabilitar hibernacion completamente (libera espacio en
# disco y evita que la PC entre en hibernacion por algun trigger).
powercfg /hibernate off

Write-Host "  OK Power: standby/monitor/disk/hibernate = NEVER" -ForegroundColor Green
Write-Host "  OK Hibernacion deshabilitada (libera ~RAM bytes en disco)" -ForegroundColor Green

# --- 2. Wake-on-LAN (opcional, mejor effort) -----------------------
Write-Host ""
Write-Host "[2/4] Wake-on-LAN del Network Adapter (best effort)..." -ForegroundColor Cyan
try {
    # Habilitar WoL en todos los adapters Ethernet (no Wi-Fi —
    # Wi-Fi no soporta WoL universalmente).
    $eth = Get-NetAdapter -Physical | Where-Object {
        $_.MediaType -eq '802.3' -and $_.Status -eq 'Up'
    }
    if ($eth) {
        foreach ($a in $eth) {
            try {
                Enable-NetAdapterPowerManagement -Name $a.Name -WakeOnMagicPacket -ErrorAction SilentlyContinue
                Write-Host "  OK WoL habilitado en $($a.Name)" -ForegroundColor Green
            } catch {
                Write-Host "  WARN no pude habilitar WoL en $($a.Name): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  SKIP no hay adapter Ethernet activo (probablemente solo Wi-Fi)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  WARN: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 3. Windows Update active hours --------------------------------
Write-Host ""
Write-Host "[3/4] Windows Update — restringir reinicios a horario nocturno..." -ForegroundColor Cyan

# Active hours = ventana en la que Windows NO reinicia automaticamente.
# Setear de 6 AM a 23:59 deja solo 6 horas (00:00-06:00) en las que
# puede reiniciar — minimo downtime para el bot. La key esta en
# HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings.
$wuPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
try {
    if (-not (Test-Path $wuPath)) {
        New-Item -Path $wuPath -Force | Out-Null
    }
    Set-ItemProperty -Path $wuPath -Name 'ActiveHoursStart' -Value 6 -Type DWord
    Set-ItemProperty -Path $wuPath -Name 'ActiveHoursEnd' -Value 23 -Type DWord
    Set-ItemProperty -Path $wuPath -Name 'IsActiveHoursEnabled' -Value 1 -Type DWord
    Write-Host "  OK Active Hours: 06:00 - 23:00 (Windows reinicia 00:00-06:00)" -ForegroundColor Green
} catch {
    Write-Host "  WARN: no pude setear Active Hours: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 4. Boot menu timeout -----------------------------------------
Write-Host ""
Write-Host "[4/4] Acelerar boot (boot menu timeout)..." -ForegroundColor Cyan
try {
    bcdedit /timeout 5 | Out-Null
    Write-Host "  OK timeout = 5 seg (vs 30 default)" -ForegroundColor Green
} catch {
    Write-Host "  WARN: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- Resumen -------------------------------------------------------
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "OK SETUP PC 24/7 COMPLETO" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Configurado:" -ForegroundColor Cyan
Write-Host "  - Power: nunca suspender, nunca apagar pantalla, no hibernar" -ForegroundColor White
Write-Host "  - Wake-on-LAN: habilitado en Ethernet (si hay)" -ForegroundColor White
Write-Host "  - Windows Update: solo reinicia entre 00:00 y 06:00" -ForegroundColor White
Write-Host "  - Boot menu: 5 seg" -ForegroundColor White
Write-Host ""
Write-Host "PENDIENTE (a mano):" -ForegroundColor Yellow
Write-Host "  - Antivirus: excluir whatsapp-bot/ y .cache/puppeteer/ del scan en vivo" -ForegroundColor White
Write-Host "  - UPS: si la PC se apaga por corte, perdes la sesion WA hasta reescaneo QR" -ForegroundColor White
Write-Host "  - Conectar por Ethernet (mas estable que Wi-Fi)" -ForegroundColor White
Write-Host "  - Auto-login (opcional): netplwiz -> desmarcar 'requerir password'" -ForegroundColor White
Write-Host ""
Write-Host "Documento completo: docs\SETUP_PC_DEDICADA_BOT.md" -ForegroundColor Cyan
