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
;     ├── launcher.ps1                  (auto-update vía GitHub Releases)
;     └── app_icon.ico                  (ícono compartido)
;
;   ProgramData\CoopertransMovil\       (Permissions: users-modify)
;     ├── coopertrans_movil.exe         (la app real)
;     ├── flutter_windows.dll
;     ├── data\flutter_assets\          (assets de Flutter)
;     ├── ...                           (DLLs nativos)
;     └── VERSION.txt                   (versión instalada)
;
; FLUJO:
;   1. Pendrive con .exe → doble click → UAC → instala ambas carpetas.
;   2. Doble click en icono "Coopertrans Móvil" del escritorio → corre
;      launcher.ps1 (sin UAC) → chequea último release en GitHub →
;      si hay nuevo, descarga el zip y reemplaza los archivos en
;      ProgramData\CoopertransMovil → lanza la app.
;   3. Updates futuros: simplemente abrir el icono. No hace falta
;      pendrive ni reinstalar.

#ifndef MyAppVersion
  #error MyAppVersion no definido. Compilar via scripts\build_installer.ps1
#endif

#define MyAppName       "Coopertrans Movil"
#define MyAppExeName    "coopertrans_movil.exe"
#define MyAppPublisher  "Coopertrans"
#define MyAppURL        "https://github.com/rodriguezreysantiago/logistica_app_profesional"
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
; Inno Setup escapa comillas dentro de strings con "" (dos comillas).
; powershell.exe necesita comillas alrededor del path al .ps1 porque
; el path contiene espacios ("Program Files\CoopertransMovil\...").
;
; IconFilename apunta al ICONO EMBEBIDO del .exe en ProgramData (IconIndex 0),
; NO al app_icon.ico estatico de Program Files. Asi, cuando el auto-update
; (launcher) reemplaza el .exe con un release nuevo, el icono del shortcut se
; actualiza SOLO — sin re-correr el instalador ni el script actualizar_icono.
; El .exe que copia este instalador ya trae el icono nuevo embebido (Runner.rc).
Name: "{group}\{#MyAppName}"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File ""{app}\launcher.ps1"""; IconFilename: "{commonappdata}\CoopertransMovil\{#MyAppExeName}"; IconIndex: 0; WorkingDir: "{app}"
Name: "{group}\Desinstalar {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File ""{app}\launcher.ps1"""; IconFilename: "{commonappdata}\CoopertransMovil\{#MyAppExeName}"; IconIndex: 0; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; Ofrecer arrancar la app al final del install, vía el launcher (que
; chequea si hay versión más nueva en GitHub que la incluida en el
; instalador, y la baja si corresponde).
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\launcher.ps1"""; Description: "Iniciar {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Limpiar logs y carpeta de la app de ProgramData. La data del usuario
; vive en %APPDATA% (Firebase cache, Sentry, etc.) — no se toca para
; permitir reinstalación con datos preservados.
Type: filesandordirs; Name: "{commonappdata}\CoopertransMovil"
