import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Auto-update SILENCIOSO para la tablet kiosk de Gomería (Android Device Owner).
///
/// Es el espejo de [WindowsUpdateService] pero SIN banner ni interacción: la
/// tablet está encerrada en la app (lock task) y nadie puede tocar un botón de
/// "Actualizar". Entonces, siendo Device Owner, la app:
///   1. chequea el último release en GitHub (la MISMA fuente que el updater de
///      Windows — repo público, sin auth),
///   2. si hay versión más nueva con un asset `.apk`, lo descarga,
///   3. lo instala EN SILENCIO via PackageInstaller (privilegio Device Owner,
///      sin prompt) — la app se reinicia sola con la versión nueva.
///
/// SOLO actúa en la tablet kiosk (Device Owner). En el celular de un chofer
/// común, el canal nativo responde `esDeviceOwner=false` y este servicio es un
/// no-op total: esos teléfonos siguen actualizando por Play Store / App
/// Distribution, sin que este código toque nada.
///
/// El APK del release tiene que estar firmado con la MISMA clave que la app
/// instalada (si no, Android rechaza el update por firma distinta). El
/// `scripts/release_kiosk_apk.ps1` sube el build release firmado al GitHub
/// Release del tag, así que coincide.
class AndroidUpdateService {
  AndroidUpdateService._();
  static final AndroidUpdateService instance = AndroidUpdateService._();

  static const MethodChannel _channel =
      MethodChannel('com.coopertrans.movil/kiosk_update');

  /// Mismo release feed que el updater de Windows. Repo público → sin auth
  /// (límite 60/h por IP, de sobra para 1 chequeo por arranque).
  static const String _releasesApiUrl =
      'https://api.github.com/repos/rodriguezreysantiago/coopertrans_movil/releases/latest';
  static const String _userAgent = 'CoopertransMovil-Updater';

  bool _iniciado = false;

  /// Arranca el chequeo en background. Idempotente. No-op fuera de Android.
  /// Fire-and-forget: NO bloquea el arranque.
  void iniciar() {
    // `kIsWeb` PRIMERO: en web `Platform.isAndroid` (dart:io) lanza
    // UnsupportedError, y esto se llama fire-and-forget antes de runApp.
    if (_iniciado || kIsWeb || !Platform.isAndroid) return;
    _iniciado = true;
    // Delay para no competir con el arranque/login (igual que el de Windows).
    Future<void>.delayed(const Duration(seconds: 8), _chequear);
  }

  Future<void> _chequear() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      // Solo la tablet kiosk (Device Owner) puede instalar en silencio. En
      // cualquier otro teléfono cortamos acá, sin siquiera pegarle a GitHub.
      if (!await _esDeviceOwner()) return;

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
        debugPrint('[AndroidUpdate] releases/latest HTTP ${resp.statusCode}');
        return;
      }
      final tag = data['tag_name']?.toString();
      if (tag == null) return;

      // Buscar el asset .apk del release (el de Windows es .zip/.exe).
      String? apkUrl;
      for (final a in (data['assets'] as List?) ?? const []) {
        if (a is Map<String, dynamic>) {
          final name = (a['name']?.toString() ?? '').toLowerCase();
          if (name.endsWith('.apk')) {
            apkUrl = a['browser_download_url']?.toString();
            break;
          }
        }
      }
      if (apkUrl == null) {
        debugPrint('[AndroidUpdate] release sin asset .apk, ignoro.');
        return;
      }

      final remota = _Version.parse(tag);
      final info = await PackageInfo.fromPlatform();
      // En Android `info.version` es solo el semver y `buildNumber` aparte:
      // concatenamos para comparar igual que el tag "v1.2.29+10229".
      final local = _Version.parse('${info.version}+${info.buildNumber}');
      debugPrint('[AndroidUpdate] local=$local remota=$remota');
      if (!(remota > local)) return;

      // Descargar el APK a un temporal.
      final dir = await getTemporaryDirectory();
      final apk = File('${dir.path}/coopertrans_update.apk');
      if (await apk.exists()) await apk.delete();
      await dio.download(apkUrl, apk.path);

      // Instalar en silencio (Device Owner). En caso de éxito, el sistema
      // reinicia la app con la versión nueva.
      debugPrint('[AndroidUpdate] instalando ${apk.path} ($remota)...');
      await _channel.invokeMethod<bool>('instalarApk', {'ruta': apk.path});
    } catch (e) {
      // No romper la app por un error de update; reintenta al próximo arranque.
      debugPrint('[AndroidUpdate] error: $e');
    }
  }

  Future<bool> _esDeviceOwner() async {
    try {
      return await _channel.invokeMethod<bool>('esDeviceOwner') ?? false;
    } catch (_) {
      // El canal no existe (build viejo / plataforma sin el handler) → tratamos
      // como NO kiosk: el updater no hace nada.
      return false;
    }
  }
}

/// Versión semver+build. Comparación: major > minor > patch > build.
/// (Copia local del comparador del updater de Windows — el de allá es privado.)
class _Version implements Comparable<_Version> {
  _Version(this.major, this.minor, this.patch, this.build);

  final int major;
  final int minor;
  final int patch;
  final int build;

  static String _limpiar(String s) {
    var t = s.trim();
    if (t.startsWith('v') || t.startsWith('V')) t = t.substring(1);
    return t;
  }

  factory _Version.parse(String s) {
    final clean = _limpiar(s);
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
