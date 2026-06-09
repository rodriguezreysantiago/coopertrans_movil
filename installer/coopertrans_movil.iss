; Inno Setup script para Coopertrans Movil — modelo PER-USER (sin admin).
;
; REWRITE 2026-06-09 — el modelo anterior instalaba machine-wide en
; C:\ProgramData con permisos `users-modify` que NO incluyen Delete sobre
; archivos individuales heredados de Admin/SYSTEM. Resultado: ningun update
; in-app podia reemplazar la carpeta, todos fallaban con "Acceso denegado".
; Caso reportado Santiago 2026-06-09 (3 dias peleando con el bug).
;
; Approach actual: instalacion per-user en %LOCALAPPDATA%, sin UAC. Mismo
; modelo que Slack, Spotify, VSCode-user. Sin SYSTEM/Admin tocando archivos,
; sin permisos heredados restrictivos. La app + updates corren bajo el user
; logueado y pueden borrar/sobrescribir lo que crearon ellos mismos.
;
; Compilar con `scripts\build_installer.ps1` (toma version del pubspec.yaml).
;
; Pre-requisitos (PC release-master):
;   winget install JRSoftware.InnoSetup
;   flutter build windows --release  (antes de cada build del instalador)
;
; ARQUITECTURA del install resultante (per-user, SIN admin):
;   %LOCALAPPDATA%\CoopertransMovil\          (carpeta del user, sin restricciones)
;     |- coopertrans_movil.exe                (la app real)
;     |- flutter_windows.dll
;     |- data\flutter_assets\                 (assets Flutter)
;     |- launcher.ps1                         (fallback manual de update)
;     |- app_icon.ico                         (icono compartido)
;     |- VERSION.txt                          (version instalada)
;
;   Shortcut: %USERPROFILE%\Desktop\Coopertrans Movil.lnk -> coopertrans_movil.exe
;
; FLUJO:
;   1. Usuario baja el .exe del link estable (GitHub Release).
;   2. Doble click — Inno corre como user normal, SIN UAC.
;   3. Wizard minimo (sin pagina de directorio, va directo a LOCALAPPDATA).
;   4. Instala todo en una carpeta del user, crea shortcut, arranca la app.
;   5. Updates futuros: 100% IN-APP. Como la carpeta es del user, no hay
;      problemas de permisos: Move-Item / Copy-Item / Remove-Item vuelan.
;
; MIGRACION desde la version vieja (machine-wide en ProgramData): el operador
; desinstala la version vieja desde "Aplicaciones" (UAC), despues corre este
; setup nuevo (sin UAC). El AppId NUEVO (abajo) evita que Inno se confunda
; con la entrada de Programs and Features de la version vieja — quedan como
; 2 apps distintas hasta que el user desinstale la vieja.

#ifndef MyAppVersion
  #error MyAppVersion no definido. Compilar via scripts\build_installer.ps1
#endif

#define MyAppName       "Coopertrans Movil"
#define MyAppExeName    "coopertrans_movil.exe"
#define MyAppPublisher  "Coopertrans"
#define MyAppURL        "https://github.com/rodriguezreysantiago/coopertrans_movil"
; AppId NUEVO 2026-06-09 (rewrite per-user). El AppId viejo
; {B6F7E8A9-1234-4567-8901-COOPERTRANSMOV} corresponde al install machine-wide
; en ProgramData; si lo dejaramos igual, Inno intentaria "actualizar" la
; instalacion vieja (que requiere admin) en vez de crear una nueva per-user.
; Quedan visibles como 2 apps distintas en Programs and Features.
#define MyAppId         "{{A4F1C2B3-5678-4ABC-9DEF-CTMOVUSERINST}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases

; PER-USER: sin admin, sin UAC, sin ProgramData. Instala en LOCALAPPDATA.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\CoopertransMovil
; Sin "pagina de directorio" en el wizard — flujo Next-Next-Finish.
DisableDirPage=yes
DisableProgramGroupPage=yes

OutputDir=..\dist
OutputBaseFilename=CoopertransMovil-Setup-{#MyAppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

; Cierra la app si esta corriendo, evitando "no se pudo reemplazar el .exe".
CloseApplications=yes
RestartApplications=no

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear icono en el escritorio"; GroupDescription: "Iconos adicionales:"; Flags: checkedonce

[Files]
; Todo en la MISMA carpeta del user (%LOCALAPPDATA%\CoopertransMovil).
; Sin separar "launcher + app" como antes — el launcher es solo otro
; archivo dentro de la app, sin requerir Program Files (read-only).
Source: "..\scripts\launcher_app.ps1"; DestDir: "{app}"; DestName: "launcher.ps1"; Flags: ignoreversion
Source: "..\windows\runner\resources\app_icon.ico"; DestDir: "{app}"; Flags: ignoreversion

; App completa (recursesubdirs + createallsubdirs porque hay data\ y data\flutter_assets\).
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; VERSION.txt para que el launcher sepa la version y la compare con GitHub.
Source: "VERSION.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Sin grupo en Inicio (lo apago con DisableProgramGroupPage). Solo el
; shortcut en el escritorio del user (per-user, NO Public).
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; IconIndex: 0; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; Ofrecer arrancar la app al final. El updater in-app va a chequear GitHub
; al primer arranque y mostrar banner si hay version mas nueva.
Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Description: "Iniciar {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Limpiar la carpeta completa al desinstalar. La data persistente de la app
; (Firebase cache, secure storage DPAPI, etc.) vive en otros paths del user
; (%APPDATA%, Credential Manager) — no se toca para permitir reinstall sin
; reloguear.
Type: filesandordirs; Name: "{app}"
