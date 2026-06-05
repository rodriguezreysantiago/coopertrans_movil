import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Invalida el caché de íconos de Windows **una sola vez por versión nueva**,
/// para que el ícono del escritorio refleje el del .exe recién actualizado.
///
/// Por qué acá (la app) y no en el launcher: ver `refrescar_icono_escritorio.dart`.
///
/// Best-effort: cualquier fallo se traga — esto NUNCA debe romper el arranque.
/// No-op fuera de Windows (en Android/iOS/macOS/Linux retorna de inmediato).
Future<void> refrescarIconoEscritorioWindows() async {
  if (!Platform.isWindows) return;
  try {
    final info = await PackageInfo.fromPlatform();
    final version = '${info.version}+${info.buildNumber}';

    // Marcador en SharedPreferences (dato no sensible → no usamos el
    // secure storage de PrefsService). Si ya refrescamos para esta versión,
    // no volvemos a correr ie4uinit en cada arranque.
    final prefs = await SharedPreferences.getInstance();
    const key = 'icono_escritorio_refrescado_para_version';
    if (prefs.getString(key) == version) return;

    final winDir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final ie4 = '$winDir\\System32\\ie4uinit.exe';
    if (await File(ie4).exists()) {
      // -show fuerza a Explorer a releer los íconos (incluidos los de
      // shortcuts cuyo .exe cambió de contenido pero no de ruta). No mata
      // explorer, no es disruptivo. Validado a mano en una PC con el ícono
      // stale: el escritorio pasó al ícono nuevo sin reinicio ni admin.
      await Process.run(ie4, ['-show']);
    }
    // Marcamos aunque ie4uinit no exista: en esa PC no hay forma de
    // refrescar por esta vía y no queremos reintentar en cada arranque.
    await prefs.setString(key, version);
  } catch (e) {
    if (kDebugMode) {
      debugPrint('refrescarIconoEscritorioWindows (no bloqueante): $e');
    }
  }
}
