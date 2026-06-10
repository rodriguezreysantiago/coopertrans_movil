import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Resultado de [WindowsUpdateService.descargarEInstalar].
enum WinUpdateResult {
  exito,
  yaEnCurso,
  errorNoInstalado,
  errorDescarga,
  errorOtro,
}

/// Updater in-app para WINDOWS. Reemplaza la "ventana negra" del launcher
/// PowerShell: la app chequea sola si hay una release nueva en GitHub, muestra
/// un banner, baja el `.zip` y lanza un helper PowerShell **oculto** que
/// reemplaza la instalación y relanza la app. El usuario nunca ve una consola.
///
/// Windows NO deja sobrescribir el `.exe`/DLLs mientras la app corre (locks del
/// SO). Por eso el helper ESPERA a que el proceso muera (libera los locks),
/// reemplaza la carpeta con backup+rollback, reescribe `VERSION.txt` y relanza.
///
/// Fuente de versión: la **GitHub Releases API** pública del repo (la misma que
/// usa `scripts/launcher_app.ps1`). El asset `.zip` es el que publica
/// `scripts/release_app.ps1` (`coopertrans_movil_<ver>-build<n>.zip`). El
/// `VERSION.txt` queda como fuente de verdad compartida con el launcher legacy.
///
/// SOLO opera en Windows y SOLO desde una instalación real (carpeta
/// `...\CoopertransMovil\` en ProgramData/LocalAppData), nunca desde el build
/// dir de desarrollo (`...\coopertrans_movil\build\...`, con guión bajo). En
/// otras plataformas y en dev todos los métodos son no-ops.
class WindowsUpdateService {
  WindowsUpdateService._();
  static final WindowsUpdateService instance = WindowsUpdateService._();

  /// GitHub Releases API — último release del repo. Sin auth (límite 60/h por
  /// IP, de sobra para 1 chequeo por arranque en las pocas PCs de Vecchi).
  static const String _releasesApiUrl =
      'https://api.github.com/repos/rodriguezreysantiago/coopertrans_movil/releases/latest';
  static const String _exeName = 'coopertrans_movil.exe';
  static const String _userAgent = 'CoopertransMovil-Updater';

  /// `null` si no hay update disponible (o aún no se chequeó).
  final ValueNotifier<WinUpdateInfo?> actualizacionDisponible =
      ValueNotifier<WinUpdateInfo?>(null);

  /// Progreso de descarga 0.0..1.0. `null` si no estamos descargando.
  final ValueNotifier<double?> progresoDescarga = ValueNotifier<double?>(null);

  bool _iniciado = false;
  bool _instalando = false;

  /// Arranca el chequeo en background. Idempotente. No-op fuera de Windows o si
  /// la app corre desde el build dir (dev). Fire-and-forget: NO bloquea arranque.
  void iniciar() {
    if (_iniciado || !Platform.isWindows) return;
    if (!_esInstalacionReal(Platform.resolvedExecutable)) return;
    _iniciado = true;
    Future<void>.delayed(const Duration(seconds: 4), _chequear);
  }

  /// Re-chequea on-demand (para un botón "Buscar actualizaciones" futuro).
  Future<void> chequearAhora() => _chequear();

  Future<void> _chequear() async {
    if (!Platform.isWindows) return;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/vnd.github+json',
        },
      ));
      final resp = await dio.get<Map<String, dynamic>>(_releasesApiUrl);
      final data = resp.data;
      if (resp.statusCode != 200 || data == null) {
        debugPrint('[WinUpdate] releases/latest HTTP ${resp.statusCode}');
        return;
      }
      final tag = data['tag_name']?.toString();
      if (tag == null) {
        debugPrint('[WinUpdate] release sin tag_name, ignorando.');
        return;
      }
      // El asset .zip de la app (el instalador es .exe; el único .zip es la app).
      Map<String, dynamic>? zip;
      for (final a in (data['assets'] as List?) ?? const []) {
        if (a is Map<String, dynamic>) {
          final name = (a['name']?.toString() ?? '').toLowerCase();
          if (name.endsWith('.zip')) {
            zip = a;
            break;
          }
        }
      }
      final url = zip?['browser_download_url']?.toString();
      if (url == null) {
        debugPrint('[WinUpdate] release sin asset .zip, ignorando.');
        return;
      }
      final remota = _Version.parse(tag);
      final info = await PackageInfo.fromPlatform();
      // En Windows, `PackageInfo.version` lee el `FileVersion` del .exe que ya
      // viene con el `+build` adentro (string completa "1.2.5+10205") y
      // `buildNumber` lo trae aparte ("10205"). Concatenar siempre daría
      // "1.2.5+10205+10205" → el parser toma el primer `+`, deja build =
      // tryParse("10205+10205") = 0 → `local = 1.2.5+0` < remota = 1.2.5+10205
      // → banner sale aunque la app YA esté actualizada (loop infinito tras
      // aplicar el update — reporte Santiago 2026-06-08). En Android/iOS
      // `info.version` es solo el semver y `buildNumber` aparte, así que ahí
      // sí hay que concatenar. Detectamos por presencia de `+`.
      final versionRaw = info.version.contains('+')
          ? info.version
          : '${info.version}+${info.buildNumber}';
      final local = _Version.parse(versionRaw);
      debugPrint(
          '[WinUpdate] local=$local remota=$remota (raw="$versionRaw")');
      if (remota > local) {
        actualizacionDisponible.value = WinUpdateInfo(
          version: _Version.limpiar(tag),
          url: url,
          sizeBytes: int.tryParse('${zip?['size'] ?? 0}') ?? 0,
        );
      }
    } catch (e) {
      // No romper la app por un error de update; reintenta al próximo arranque.
      debugPrint('[WinUpdate] error chequeando update: $e');
    }
  }

  /// Descarga el ZIP, lanza el helper oculto que reemplaza la instalación, y
  /// cierra la app. En caso de éxito NO retorna (la app hace `exit(0)`).
  /// Cualquier retorno es un fallo o el race-guard, con [progresoDescarga] ya
  /// reseteado.
  Future<WinUpdateResult> descargarEInstalar({
    required WinUpdateInfo info,
    VoidCallback? onListoParaReiniciar,
  }) async {
    if (!Platform.isWindows) return WinUpdateResult.errorOtro;

    // Race-guard: ignorar el segundo click si ya estamos descargando.
    if (_instalando) return WinUpdateResult.yaEnCurso;
    _instalando = true;

    Directory? tmpDir;
    try {
      final exe = Platform.resolvedExecutable;
      if (!_esInstalacionReal(exe)) return WinUpdateResult.errorNoInstalado;
      final installDir = File(exe).parent.path;

      progresoDescarga.value = 0.0;

      // 1. Descargar el ZIP con progreso a un temp.
      tmpDir = await Directory.systemTemp.createTemp('ctm_update_');
      final zipFile = File('${tmpDir.path}\\CoopertransMovil-update.zip');
      final dio = Dio(BaseOptions(headers: {'User-Agent': _userAgent}));
      await dio.download(
        info.url,
        zipFile.path,
        onReceiveProgress: (recibido, total) {
          if (total > 0) {
            progresoDescarga.value = (recibido / total).clamp(0.0, 1.0);
          }
        },
      );

      // 2. Escribir el helper PowerShell a tmpDir.
      final helperFile = File('${tmpDir.path}\\update_helper.ps1');
      await helperFile.writeAsString(_helperPs1Script);

      // 3. Lanzar el helper de forma que SOBREVIVA al cierre de la app. Lanzar
      //    PowerShell directo con Process.start(detached) NO alcanzaba: al hacer
      //    exit(0), el hijo moría antes de terminar de arrancar y el helper
      //    NUNCA corría (bug 2026-06-07: descargaba pero no reemplazaba/relanzaba).
      //    Solución: un .bat que usa `start` → crea el PowerShell FUERA del árbol
      //    de procesos de la app (desacople real). Paths entre comillas (toleran
      //    espacios, p.ej. el user "Colo Logistica"). Args posicionales del
      //    helper: <zip> <installDir> <exeName> <pidApp> <nuevaVersion>.
      //
      //    `cd /d %TEMP%` al inicio del .bat: CRITICO. El cmd.exe hereda CWD
      //    del proceso padre (la app), que es InstallDir. Si lo dejamos, todo
      //    el arbol de procesos (cmd -> powershell del helper) mantiene un
      //    handle sobre InstallDir mientras el helper corre, y el Move-Item
      //    falla con "el elemento esta en uso" — ¡el lock lo ponemos nosotros
      //    mismos! Confirmado Santiago 2026-06-09: handle.exe de Sysinternals
      //    no veia ningun otro lock; el helper fallaba 12s seguidos.
      //
      //    Tambien especificamos `workingDirectory: tmpDir.path` en el
      //    Process.start para no heredar el CWD desde el primer instante.
      String q(String s) => '"$s"';
      final batFile = File('${tmpDir.path}\\update_run.bat');
      await batFile.writeAsString(
        '@echo off\r\n'
        'cd /d "%TEMP%"\r\n'
        'start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass '
        '-WindowStyle Hidden -File ${q(helperFile.path)} '
        '${q(zipFile.path)} ${q(installDir)} ${q(_exeName)} $pid '
        '${q(info.version)}\r\n',
      );
      await Process.start(
        'cmd.exe',
        ['/c', batFile.path],
        mode: ProcessStartMode.detached,
        workingDirectory: tmpDir.path,
      );

      // 4. Notificar UI + cerrar la app. Damos 2 s para que el `start` lance el
      //    PowerShell antes del exit; el helper igual espera a que el PID muera
      //    para poder reemplazar los archivos bloqueados.
      onListoParaReiniciar?.call();
      await Future<void>.delayed(const Duration(seconds: 2));
      exit(0);
    } catch (e) {
      debugPrint('[WinUpdate] error descargando: $e');
      try {
        await tmpDir?.delete(recursive: true);
      } catch (_) {
        // Best-effort: limpiar el temp tras un error de descarga. Si falla,
        // el SO lo purga solo — no agrega señal loguearlo.
      }
      return WinUpdateResult.errorDescarga;
    } finally {
      // Reset siempre que NO hayamos hecho exit(0).
      _instalando = false;
      progresoDescarga.value = null;
    }
  }

  /// Cierra el banner sin descargar — el usuario optó por "más tarde". Vuelve a
  /// aparecer en el próximo arranque si sigue habiendo versión nueva.
  void descartar() {
    actualizacionDisponible.value = null;
    progresoDescarga.value = null;
  }
}

/// La app está instalada de verdad (no corriendo desde el build dir de dev).
/// El instalador la deja en `...\CoopertransMovil\` (ProgramData o LocalAppData);
/// en dev corre desde `...\coopertrans_movil\build\windows\...\Release\` (con
/// guión bajo), que NO debemos tocar con el updater.
bool _esInstalacionReal(String exePath) {
  return exePath.toLowerCase().contains(r'\coopertransmovil\');
}

class WinUpdateInfo {
  WinUpdateInfo({
    required this.version,
    required this.url,
    required this.sizeBytes,
  });

  final String version;
  final String url;
  final int sizeBytes;

  int get sizeMb => (sizeBytes / 1024 / 1024).round();

  /// Sólo el semver visible para el usuario (sin el +build): "1.2.2".
  /// El `version` completo (con +build) se sigue usando internamente para
  /// comparar y para el VERSION.txt; esto es únicamente cosmético.
  String get versionCorta => version.split('+').first;
}

/// Versión semver+build. Comparación: major > minor > patch > build.
class _Version implements Comparable<_Version> {
  _Version(this.major, this.minor, this.patch, this.build);

  final int major;
  final int minor;
  final int patch;
  final int build;

  /// Quita un prefijo `v`/`V` y espacios (el tag de GitHub es `v1.0.94+97`).
  static String limpiar(String s) {
    var t = s.trim();
    if (t.startsWith('v') || t.startsWith('V')) t = t.substring(1);
    return t;
  }

  factory _Version.parse(String s) {
    final clean = limpiar(s);
    final plus = clean.indexOf('+');
    final semver = plus >= 0 ? clean.substring(0, plus) : clean;
    final build = plus >= 0 ? int.tryParse(clean.substring(plus + 1)) ?? 0 : 0;
    final parts = semver.split('.');
    int at(int i) => i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0;
    return _Version(at(0), at(1), at(2), build);
  }

  bool operator >(_Version other) => compareTo(other) > 0;

  @override
  int compareTo(_Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return build.compareTo(other.build);
  }

  @override
  String toString() => '$major.$minor.$patch+$build';
}

/// Helper PowerShell que se escribe a %TEMP% y se lanza OCULTO + detached.
///
/// Args posicionales: `<zip> <installDir> <exeName> <pidApp> <nuevaVersion>`.
///
/// REWRITE 2026-06-08 — caso reportado por Santiago tras 3 intentos:
///   1. El log file VIVÍA en `$InstallDir\update.log` y se quedaba con handle
///      abierto cuando intentaba mover la carpeta entera → primer ERROR en
///      backup, helper aborta, relanza la app vieja, banner vuelve a salir.
///   2. Algunos procesos hijo de los plugins Firebase (cloud_firestore C++
///      worker, auth) sobreviven al `exit(0)` un par de segundos y mantienen
///      handles a DLLs dentro de la carpeta — backup también falla por eso.
///   3. `Move-Item` falla DURO ante cualquier lock; `Copy-Item -Force` también.
///
/// Solución (rewrite 3 — 2026-06-09, tercer reporte de Santiago):
///   El rewrite 2 (robocopy /MIR, commit 6250f90) ya NO moría (el fix del
///   2>&1 + try/finally anduvo: hacía rollback y relanzaba). Pero el robocopy
///   /MIR fallaba con exit=10 tras ~2 min de reintentos → "no actualiza". El
///   /MIR sobrescribe el .exe/DLLs viejos IN-PLACE, y Windows todavía no los
///   liberó del todo justo tras el `exit(0)` → no puede pisarlos.
///
///   DATO CLAVE: el LAUNCHER EXTERNO (scripts/launcher_app.ps1) actualiza
///   bien esta misma PC con `Move-Item` de la CARPETA entera + `Copy-Item`.
///   Renombrar el directorio completo es una operación a nivel de dir
///   (robusta ante archivos individuales con lock transitorio), y copiar a
///   una carpeta VACÍA no pelea con ningún archivo viejo. Ese approach está
///   probado en producción; volvemos a él.
///
///   El bug ORIGINAL del Move-Item ("la carpeta está en uso") era el
///   `update.log` que vivía DENTRO de InstallDir y dejaba un handle abierto.
///   Ya está resuelto: el log vive en el PADRE de InstallDir desde el
///   rewrite 2. Así que Move-Item ahora funciona igual que en el launcher.
///
///   Se conserva del rewrite 2: log en el padre, try/finally con relaunch
///   garantizado, sin 2>&1, kill de procesos residuales por nombre.
///
/// ASCII puro (PowerShell 5.1 en Windows rompe con acentos/ñ). Embebido como
/// string para que viaje SIEMPRE con la versión correcta de la app.
const String _helperPs1Script = r'''param(
  [string]$Zip,
  [string]$InstallDir,
  [string]$ExeName,
  [int]$AppPid,
  [string]$NuevaVersion
)
# Helper de update Windows para Coopertrans Movil.
# Generado por lib/core/services/windows_update_service.dart, no editar a mano.
$ErrorActionPreference = 'Stop'

# CRITICO: salir de cualquier CWD que el helper haya heredado del proceso padre.
# El cmd.exe que nos lanzo (Process.start desde Dart) tiene como CWD el de la
# app, que es InstallDir. Si dejamos eso, PowerShell mantiene un HANDLE al
# InstallDir durante TODA la ejecucion, y el Move-Item falla con "el elemento
# esta en uso" — no es la app, es el propio helper. Confirmado Santiago
# 2026-06-09: el handle.exe de Sysinternals no veia ningun otro proceso
# locking, pero el Move-Item fallaba 12 seg seguidos.
Set-Location -LiteralPath $env:TEMP

$exePath = Join-Path $InstallDir $ExeName
$verFile = Join-Path $InstallDir 'VERSION.txt'
# Log en el PADRE de InstallDir: predecible (no depende de %TEMP%) y fuera de
# la carpeta que vamos a mover, asi el Add-Content no la deja con un handle
# (ese handle era el bug original del Move-Item).
$logDir = Split-Path $InstallDir -Parent
$logFile = Join-Path $logDir 'ctm_update.log'

function Log($m) {
  try {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "[$ts] [in-app] $m" -ErrorAction SilentlyContinue
  } catch {}
}

# Relaunch GARANTIZADO (idempotente): se llama en el finally pase lo que pase,
# para que la app SIEMPRE reabra aunque el update haya fallado a mitad.
$script:relanzado = $false
function Relanzar {
  if ($script:relanzado) { return }
  try {
    if (Test-Path $exePath) {
      Start-Process -FilePath $exePath -WorkingDirectory $InstallDir
      $script:relanzado = $true
      Log "App relanzada."
    } else {
      Log "ERROR: no existe $exePath para relanzar."
    }
  } catch {
    Log "ERROR relanzando: $($_.Exception.Message)"
  }
}

$staging = Join-Path $env:TEMP ("ctm_staging_" + [guid]::NewGuid().ToString('N'))
$backup = "$InstallDir.bak"
$movido = $false  # true una vez que renombramos InstallDir -> backup (para rollback)
$pasoActual = '?'  # se actualiza antes de cada operacion critica para que el catch sepa donde murio

# Helper para loggear excepciones con CONTEXTO: tipo + path si lo trae +
# inner exception. Sin esto, "Acceso denegado a la ruta de acceso." sale sin
# saber QUE ruta ni que API lo lanzo — diagnosticar imposible (caso real
# Santiago 2026-06-09, log con 3 errores genericos).
function LogException($ex, $paso) {
  $tipo = $ex.GetType().FullName
  $msg = $ex.Message
  $ruta = $null
  # Algunas excepciones de IO/UnauthorizedAccess traen el path en .FileName.
  try { if ($ex.PSObject.Properties['FileName']) { $ruta = $ex.FileName } } catch {}
  $inner = $null
  if ($ex.InnerException) {
    $inner = "$($ex.InnerException.GetType().FullName): $($ex.InnerException.Message)"
  }
  $detalle = "tipo=$tipo"
  if ($ruta) { $detalle += " path=$ruta" }
  if ($inner) { $detalle += " inner={$inner}" }
  Log "ERROR fatal en [$paso]: $msg | $detalle"
}

try {
  # 1. Esperar a que la app (AppPid) cierre (libera locks de exe/DLLs).
  $pasoActual = 'wait_pid'
  Log "PASO wait_pid: esperando cierre de la app (PID $AppPid)..."
  $tries = 0
  while ($tries -lt 120) {
    $p = Get-Process -Id $AppPid -ErrorAction SilentlyContinue
    if (-not $p) { break }
    Start-Sleep -Milliseconds 500
    $tries++
  }
  Start-Sleep -Milliseconds 800

  # 1b. Matar procesos residuales con el mismo nombre (defensa extra).
  $pasoActual = 'kill_residuales'
  $exeBase = [IO.Path]::GetFileNameWithoutExtension($ExeName)
  $residuales = @(Get-Process -Name $exeBase -ErrorAction SilentlyContinue)
  if ($residuales.Count -gt 0) {
    Log "PASO kill_residuales: matando $($residuales.Count) proceso(s) residual(es)..."
    foreach ($r in $residuales) {
      try { $r | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
  # Espera larga (3s) para que Windows libere TODOS los handles del proceso
  # recien terminado: DLLs cargadas (Flutter, Firebase, Sentry), file system
  # watchers, sub-procesos (crashpad). Los 800ms del rewrite anterior NO
  # alcanzaban — Santiago 2026-06-09 vio el Move-Item fallar 4s despues del
  # exit con "el elemento esta en uso" (handles todavia activos).
  Start-Sleep -Seconds 3

  # 1c. Limpieza preventiva de .sentry-native: el crashpad de Sentry deja
  # %InstallDir%\.sentry-native\<UUID>.run\session.json con permisos
  # restringidos del crashpad si la app no cerro limpia. Best-effort.
  $pasoActual = 'limpiar_sentry_native'
  $sentryDir = Join-Path $InstallDir '.sentry-native'
  if (Test-Path $sentryDir) {
    Log "PASO limpiar_sentry_native: borrando .sentry-native preventivamente..."
    try { Remove-Item $sentryDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }

  # 2. Extraer el ZIP a staging.
  $pasoActual = "expand_archive(zip=$Zip)"
  Log "PASO expand_archive: extrayendo zip a $staging..."
  Expand-Archive -Path $Zip -DestinationPath $staging -Force
  if (-not (Test-Path (Join-Path $staging $ExeName))) {
    throw "el zip no contiene $ExeName"
  }

  # 3. Backup = MOVER la carpeta entera (renombre de directorio). A diferencia
  # de robocopy /MIR (que sobrescribe el .exe/DLLs viejos IN-PLACE y pelea con
  # los locks transitorios que Windows aun no libero tras el exit), renombrar
  # el dir completo es UNA operacion a nivel de directorio, robusta. Mismo
  # approach que el launcher externo (scripts/launcher_app.ps1), probado en
  # produccion en esta PC.
  if (Test-Path $backup) {
    $pasoActual = "limpiar_backup_previo(backup=$backup)"
    Log "PASO limpiar_backup_previo: el .bak ya existe (residuo de intento anterior), lo borro..."
    Remove-Item $backup -Recurse -Force
  }
  $pasoActual = "move_a_backup(src=$InstallDir, dst=$backup)"
  Log "PASO move_a_backup: renombrando $InstallDir -> $backup..."
  # Retries para el Move-Item: Windows a veces tarda VARIOS segundos en
  # liberar todos los handles del proceso recien terminado (especialmente
  # con apps grandes con Flutter+Firebase+Sentry). Si falla con "el elemento
  # esta en uso", esperamos 2s y reintentamos hasta 5 veces (total ~10s
  # extra). Despues sube al catch principal.
  $moveErr = $null
  for ($mi = 1; $mi -le 6; $mi++) {
    try {
      Move-Item -Path $InstallDir -Destination $backup -ErrorAction Stop
      $moveErr = $null
      break
    } catch {
      $moveErr = $_.Exception
      if ($mi -lt 6) {
        Log "  intento $mi fallo: $($moveErr.Message) - espero 2s y reintento..."
        Start-Sleep -Seconds 2
      }
    }
  }
  if ($moveErr) { throw $moveErr }
  $movido = $true

  # 4. Copiar la version nueva a una carpeta NUEVA y VACIA (sin archivos viejos
  # locked con que pelear — esa es la clave de por que esto anda y /MIR no).
  $pasoActual = "crear_install_vacio(dst=$InstallDir)"
  Log "PASO crear_install_vacio: creando $InstallDir limpio..."
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

  $pasoActual = "copy_nueva(src=$staging, dst=$InstallDir)"
  Log "PASO copy_nueva: copiando version nueva a $InstallDir..."
  Copy-Item -Path (Join-Path $staging '*') -Destination $InstallDir -Recurse -Force

  # VERSION.txt con la version nueva (UTF-8 SIN BOM, como el launcher legacy).
  $pasoActual = "escribir_version(file=$verFile)"
  try {
    [System.IO.File]::WriteAllText($verFile, $NuevaVersion, (New-Object System.Text.UTF8Encoding $false))
  } catch {
    Log "WARN escribir_version: $($_.Exception.Message)"
  }
  $movido = $false  # exito: ya no hace falta rollback
  Log "OK actualizado a $NuevaVersion"
} catch {
  LogException $_.Exception $pasoActual
  if ($movido) {
    # El backup ya se movio pero la copia nueva fallo: restaurar la vieja.
    Log "ROLLBACK: restaurando carpeta anterior..."
    try {
      if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
      Move-Item -Path $backup -Destination $InstallDir
      $movido = $false
    } catch {
      LogException $_.Exception 'rollback'
    }
  }
} finally {
  # Limpieza best-effort (no debe impedir el relaunch). El backup solo se
  # borra si el update fue OK (si quedo $movido=true hubo rollback y NO lo
  # tocamos aca para no perder la copia buena).
  if (-not $movido) {
    try { Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
  try { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  try { Remove-Item $Zip -Force -ErrorAction SilentlyContinue } catch {}
  # SIEMPRE relanzar la app (nueva si el update fue OK, vieja si hubo rollback).
  Relanzar
}
''';
