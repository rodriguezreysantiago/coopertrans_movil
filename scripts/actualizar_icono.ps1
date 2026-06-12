# =============================================================================
# Actualizar Icono del Escritorio — Coopertrans Movil
# =============================================================================
#
# Script standalone para arreglar el icono "Coopertrans Movil" del escritorio
# en las PCs que ya tienen la app instalada. NO requiere admin / UAC.
#
# Para que sirve:
#
# Cuando renovamos el icono de la app (ej. 2026-05-18 logo VAVG cuadrado),
# el .exe nuevo se distribuye solo via el launcher (auto-update). Pero el
# shortcut del escritorio fue creado por el instalador Inno Setup
# apuntando a un .ico ESTATICO en Program Files\CoopertransMovil\app_icon.ico
# que solo se reemplaza al re-correr el instalador. Eso significa que el
# escritorio sigue mostrando el icono viejo aunque el .exe ya este al dia.
#
# Este script cambia el shortcut para que tome el icono EMBEBIDO del .exe
# (que se autoactualiza con cada release). Una vez corrido, el icono del
# escritorio refleja el icono actual y los futuros cambios de icono se
# distribuyen automaticamente con el proximo update de la app.
#
# Como distribuir:
#
#   1. Pegar el contenido de este archivo en un mensaje de WhatsApp al
#      operador, o subirlo como archivo .ps1.
#   2. Operador lo guarda en su escritorio, click derecho > Ejecutar con
#      PowerShell. (Si Windows pide permisos, "Si" / "Mas info > Ejecutar
#      de todas formas" — el script NO requiere admin.)
#   3. El icono se refresca en 2-3 segundos. Listo.
#
# Cero riesgo: solo modifica el IconLocation del shortcut. Si algo sale
# mal (shortcut borrado por error, etc.), el operador puede regenerarlo
# corriendo el launcher de la app (doble click en cualquier .lnk que
# apunte a la app la regenera).

$ErrorActionPreference = 'Stop'

Write-Host "=== Refrescar icono escritorio Coopertrans Movil ===" -ForegroundColor Cyan
Write-Host ""

# === 1. Encontrar el .exe instalado ==================================
# El instalador Inno Setup pone la app en ProgramData\CoopertransMovil.
# Fallback: LOCALAPPDATA (modo dev sin instalador).
$candidatos = @(
    (Join-Path $env:ProgramData    'CoopertransMovil\coopertrans_movil.exe'),
    (Join-Path $env:LOCALAPPDATA   'CoopertransMovil\coopertrans_movil.exe')
)
$exePath = $null
foreach ($c in $candidatos) {
    if (Test-Path $c) { $exePath = $c; break }
}
if (-not $exePath) {
    Write-Host "ERROR: no encuentro coopertrans_movil.exe en ninguna ubicacion conocida." -ForegroundColor Red
    Write-Host "Ubicaciones chequeadas:" -ForegroundColor Yellow
    foreach ($c in $candidatos) { Write-Host "  $c" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Posibles causas:" -ForegroundColor Yellow
    Write-Host "  - La app nunca se instalo en esta PC." -ForegroundColor Yellow
    Write-Host "  - El operador nunca abrio la app despues de instalar." -ForegroundColor Yellow
    Write-Host "Solucion: doble click en el icono de escritorio para que" -ForegroundColor Yellow
    Write-Host "el launcher baje la app por primera vez, despues volver a correr este." -ForegroundColor Yellow
    Read-Host "Enter para cerrar"
    exit 1
}
Write-Host "App encontrada: $exePath" -ForegroundColor Green

# === 2. Buscar shortcuts del escritorio a refrescar ==================
# El instalador puede haber creado el shortcut en:
#   - %PUBLIC%\Desktop  (instalacion como admin, default Inno)
#   - %USERPROFILE%\Desktop  (si el usuario lo copio)
$candidatosLnk = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Coopertrans Movil.lnk'),
    (Join-Path "$env:PUBLIC\Desktop" 'Coopertrans Movil.lnk')
)
$lnksToFix = @($candidatosLnk | Where-Object { Test-Path $_ })

if ($lnksToFix.Count -eq 0) {
    Write-Host "AVISO: no encontre 'Coopertrans Movil.lnk' en el escritorio." -ForegroundColor Yellow
    Write-Host "Si en tu escritorio el icono se llama distinto, decime el nombre" -ForegroundColor Yellow
    Write-Host "exacto y ajustamos el script." -ForegroundColor Yellow
    Read-Host "Enter para cerrar"
    exit 0
}

# === 3. Cambiar IconLocation a apuntar al .exe =======================
# El .exe tiene el icono embebido via windows/runner/Runner.rc — se
# actualiza solo con cada release del launcher.
$expected = "$exePath,0"
$shell = New-Object -ComObject WScript.Shell
$cambiados = 0
foreach ($lnk in $lnksToFix) {
    try {
        $sc = $shell.CreateShortcut($lnk)
        $iconActual = $sc.IconLocation
        Write-Host ""
        Write-Host "Shortcut: $lnk" -ForegroundColor Cyan
        Write-Host "  Icono actual:  $iconActual" -ForegroundColor DarkGray
        if ($iconActual -eq $expected) {
            Write-Host "  Ya apunta al .exe. Skip." -ForegroundColor Green
            continue
        }
        $sc.IconLocation = $expected
        $sc.Save()
        Write-Host "  Icono nuevo:   $expected" -ForegroundColor Green
        $cambiados++
    } catch {
        Write-Host "  ERROR al modificar: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# === 4. Refrescar cache de iconos de Windows =========================
# `ie4uinit.exe -show` fuerza a Explorer a releer iconos sin matar el
# proceso (no disruptivo — no cierra ventanas abiertas). Si no
# funciona, despues de cerrar/abrir sesion Windows reconstruye el cache
# automaticamente.
if ($cambiados -gt 0) {
    Write-Host ""
    Write-Host "Refrescando cache de iconos de Windows..." -ForegroundColor Cyan
    try {
        $ie4 = "$env:WINDIR\System32\ie4uinit.exe"
        if (Test-Path $ie4) {
            Start-Process -FilePath $ie4 -ArgumentList '-show' -WindowStyle Hidden -Wait
            Write-Host "  OK" -ForegroundColor Green
        } else {
            Write-Host "  (ie4uinit no disponible, el icono se ve despues de cerrar sesion)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  No se pudo refrescar cache: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  El icono se actualiza despues de cerrar/abrir sesion." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "=== Listo ===" -ForegroundColor Green
if ($cambiados -eq 0) {
    Write-Host "El icono ya estaba apuntando al .exe. No hubo cambios." -ForegroundColor Cyan
} else {
    Write-Host "Shortcuts refrescados: $cambiados" -ForegroundColor Cyan
    Write-Host "Si el icono viejo sigue apareciendo despues de unos segundos," -ForegroundColor Cyan
    Write-Host "cerra sesion de Windows y volve a entrar (no hace falta reboot)." -ForegroundColor Cyan
}
Write-Host ""
Read-Host "Enter para cerrar"
