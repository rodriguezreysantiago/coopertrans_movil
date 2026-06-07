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
      final local = _Version.parse('${info.version}+${info.buildNumber}');
      debugPrint('[WinUpdate] local=$local remota=$remota');
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

      // 3. Lanzar el helper OCULTO + detached. Args posicionales:
      //    <zip> <installDir> <exeName> <pidApp> <nuevaVersion>
      await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy', 'Bypass',
          '-WindowStyle', 'Hidden',
          '-File', helperFile.path,
          zipFile.path,
          installDir,
          _exeName,
          '$pid',
          info.version,
        ],
        mode: ProcessStartMode.detached,
      );

      // 4. Notificar UI + cerrar la app después de 1 s (el helper espera el
      //    cierre para poder reemplazar los archivos bloqueados).
      onListoParaReiniciar?.call();
      await Future<void>.delayed(const Duration(seconds: 1));
      exit(0);
    } catch (e) {
      debugPrint('[WinUpdate] error descargando: $e');
      try {
        await tmpDir?.delete(recursive: true);
      } catch (_) {}
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
/// Replica la lógica probada de `scripts/launcher_app.ps1` (backup atómico +
/// rollback + VERSION.txt sin BOM) pero ESPERANDO a que la app cierre primero,
/// porque corre mientras la app todavía está viva (la lanzó ella).
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

$exePath = Join-Path $InstallDir $ExeName
$verFile = Join-Path $InstallDir 'VERSION.txt'
$logFile = Join-Path $InstallDir 'update.log'

function Log($m) {
  try {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "[$ts] [in-app] $m" -ErrorAction SilentlyContinue
  } catch {}
}

# 1. Esperar a que la app (AppPid) cierre del todo (libera locks de exe/DLLs).
Log "Esperando cierre de la app (PID $AppPid)..."
$tries = 0
while ($tries -lt 120) {
  $p = Get-Process -Id $AppPid -ErrorAction SilentlyContinue
  if (-not $p) { break }
  Start-Sleep -Milliseconds 500
  $tries++
}
Start-Sleep -Milliseconds 800

# 2. Extraer el ZIP a staging.
$staging = Join-Path $env:TEMP ("ctm_staging_" + [guid]::NewGuid().ToString('N'))
try {
  Expand-Archive -Path $Zip -DestinationPath $staging -Force
} catch {
  Log "ERROR extrayendo el zip: $($_.Exception.Message)"
  if (Test-Path $exePath) { Start-Process -FilePath $exePath -WorkingDirectory $InstallDir }
  exit 1
}
if (-not (Test-Path (Join-Path $staging $ExeName))) {
  Log "ERROR: el zip no contiene $ExeName"
  Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path $exePath) { Start-Process -FilePath $exePath -WorkingDirectory $InstallDir }
  exit 1
}

# 3. Backup atomico de la instalacion actual.
$backup = "$InstallDir.bak"
try {
  if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
  Move-Item -Path $InstallDir -Destination $backup
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
} catch {
  Log "ERROR en backup: $($_.Exception.Message)"
  Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path $exePath) { Start-Process -FilePath $exePath -WorkingDirectory $InstallDir }
  exit 1
}

# 4. Copiar la version nueva. Si falla, ROLLBACK del backup.
try {
  Copy-Item -Path (Join-Path $staging '*') -Destination $InstallDir -Recurse -Force
  # VERSION.txt con la version nueva (UTF-8 SIN BOM, como el launcher), para que
  # el launcher externo NO la vea desactualizada y re-baje.
  [System.IO.File]::WriteAllText($verFile, $NuevaVersion, (New-Object System.Text.UTF8Encoding $false))
  Log "OK actualizado a $NuevaVersion"
} catch {
  Log "ERROR copiando, hago rollback: $($_.Exception.Message)"
  if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
  Move-Item -Path $backup -Destination $InstallDir
  Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path $exePath) { Start-Process -FilePath $exePath -WorkingDirectory $InstallDir }
  exit 1
}

# 5. Limpieza: backup, staging, zip.
Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $Zip -Force -ErrorAction SilentlyContinue

# 6. Relanzar la app nueva.
Start-Process -FilePath $exePath -WorkingDirectory $InstallDir
Log "Relanzada en $NuevaVersion."
''';
