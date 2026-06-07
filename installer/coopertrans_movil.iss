; Inno Setup script para Coopertrans Móvil — modelo "instalador + launcher".
;
; Compilar con `scripts\build_installer.ps1` (toma la versión del
; pubspec.yaml y se la pasa a iscc.exe). NO compilar el .iss directo
; sin pasarle MyAppVersion.
;
; Pre-requisitos (una vez en la PC que crea releases):
;   winget install JRSoftware.InnoSetup
;   flutter build windows --release  (antes de cada build del instalador)
;
; ARQUITECTURA del install resultante:
;   Program Files\CoopertransMovil\
;     ├── launcher.ps1                  (LEGACY: fallback manual de update; el
;     │                                  ícono ya NO lo usa — ver modelo abajo)
;     └── app_icon.ico                  (ícono compartido)
;
;   ProgramData\CoopertransMovil\       (Permissions: users-modify)
;     ├── coopertrans_movil.exe         (la app real)
;     ├── flutter_windows.dll
;     ├── data\flutter_assets\          (assets de Flutter)
;     ├── ...                           (DLLs nativos)
;     └── VERSION.txt                   (versión instalada)
;
; FLUJO (modelo update IN-APP desde 2026-06-06):
;   1. Pendrive/descarga del .exe → doble click → UAC → instala ambas carpetas.
;   2. El ícono "Coopertrans Móvil" abre coopertrans_movil.exe DIRECTO (sin
;      launcher, SIN ventana de PowerShell).
;   3. Updates futuros: 100% IN-APP. La app consulta la GitHub Releases API al
;      arrancar y muestra un banner; el updater in-app (lib/core/services/
;      windows_update_service.dart) baja el zip y lo reemplaza con un helper
;      PowerShell OCULTO, y relanza. No hace falta pendrive ni reinstalar.
;   4. launcher.ps1 queda como LEGACY (fallback manual / dev). El ícono ya no lo
;      usa → NO vuelve a aparecer la ventana negra.
;
; MIGRACIÓN: las PCs con un install VIEJO tienen el ícono apuntando al launcher
; (read-only, la app sin admin no lo puede cambiar). Para pasarlas al modelo
; nuevo hay que correr ESTE instalador una vez en cada una.

#ifndef MyAppVersion
  #error MyAppVersion no definido. Compilar via scripts\build_installer.ps1
#endif

#define MyAppName       "Coopertrans Movil"
#define MyAppExeName    "coopertrans_movil.exe"
#define MyAppPublisher  "Coopertrans"
#define MyAppURL        "https://github.com/rodriguezreysantiago/coopertrans_movil"
#define MyAppId         "{{B6F7E8A9-1234-4567-8901-COOPERTRANSMOV}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\CoopertransMovil
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
OutputDir=..\dist
OutputBaseFilename=CoopertransMovil-Setup-{#MyAppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

; Cierra la app si está corriendo, evitando "no se pudo reemplazar el .exe".
CloseApplications=yes
RestartApplications=no

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear icono en el escritorio"; GroupDescription: "Iconos adicionales:"; Flags: checkedonce

[Dirs]
; ProgramData\CoopertransMovil con permisos modify para Users → el
; launcher puede actualizar sin UAC. Esta es la diferencia clave vs
; instalar la app en Program Files (que sería read-only para users).
Name: "{commonappdata}\CoopertransMovil"; Permissions: users-modify

[Files]
; --- Launcher + ícono en Program Files (read-only por users) ----
Source: "..\scripts\launcher_app.ps1"; DestDir: "{app}"; DestName: "launcher.ps1"; Flags: ignoreversion
Source: "..\windows\runner\resources\app_icon.ico"; DestDir: "{app}"; Flags: ignoreversion

; --- App completa en ProgramData (writable por users vía launcher) ----
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{commonappdata}\CoopertransMovil"; Flags: ignoreversion recursesubdirs createallsubdirs

; VERSION.txt para que el launcher sepa qué versión está instalada y
; pueda compararla con la última release en GitHub.
Source: "VERSION.txt"; DestDir: "{commonappdata}\CoopertransMovil"; Flags: ignoreversion

[Icons]
; El shortcut abre coopertrans_movil.exe DIRECTO (modelo update in-app, sin
; launcher ni ventana de PowerShell). IconFilename apunta al ICONO EMBEBIDO del
; mismo .exe en ProgramData (IconIndex 0): cuando el updater in-app reemplaza el
; .exe con un release nuevo, el icono del shortcut se actualiza SOLO. El .exe que
; copia este instalador ya trae el icono nuevo embebido (Runner.rc).
Name: "{group}\{#MyAppName}"; Filename: "{commonappdata}\CoopertransMovil\{#MyAppExeName}"; IconFilename: "{commonappdata}\CoopertransMovil\{#MyAppExeName}"; IconIndex: 0; WorkingDir: "{commonappdata}\CoopertransMovil"
Name: "{group}\Desinstalar {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{commonappdata}\CoopertransMovil\{#MyAppExeName}"; IconFilename: "{commonappdata}\CoopertransMovil\{#MyAppExeName}"; IconIndex: 0; WorkingDir: "{commonappdata}\CoopertransMovil"; Tasks: desktopicon

[Run]
; Ofrecer arrancar la app al final del install — abre el .exe DIRECTO. El propio
; updater in-app consultará la GitHub Releases API al arrancar y ofrecerá la
; última versión si el instalador trajera una más vieja.
Filename: "{commonappdata}\CoopertransMovil\{#MyAppExeName}"; WorkingDir: "{commonappdata}\CoopertransMovil"; Description: "Iniciar {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Limpiar logs y carpeta de la app de ProgramData. La data del usuario
; vive en %APPDATA% (Firebase cache, Sentry, etc.) — no se toca para
; permitir reinstalación con datos preservados.
Type: filesandordirs; Name: "{commonappdata}\CoopertransMovil"
