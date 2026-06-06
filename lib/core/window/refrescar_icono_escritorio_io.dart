import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Refresca el caché de íconos del escritorio en Windows **una sola vez por
/// versión nueva**, para que el escritorio refleje el ícono del `.exe` recién
/// actualizado. Corre `ie4uinit -show` (un proceso del sistema, aparte). No-op
/// fuera de Windows.
///
/// ⚠️ NOTA (2026-06-06): la variante anterior ADEMÁS reescribía el `.lnk` del
/// pin de la barra de tareas vía **COM/FFI (win32)** para forzar el refresco de
/// SU ícono cacheado. Eso causaba un **ACCESS VIOLATION (0xC0000005)** en el
/// build RELEASE de Windows que **tumbaba la app al arrancar** — un crash NATIVO
/// in-process que el `try/catch` de Dart NO atrapa, y como ocurría antes de
/// marcar la versión en prefs, rompía TODOS los arranques (la app "se abría y se
/// cerraba"). Se ELIMINÓ el COM. El escritorio lo cubre `ie4uinit`; el pin de la
/// taskbar se refresca cuando Windows lo decide (detalle cosmético, no vale
/// arriesgar el arranque). Si en el futuro hace falta refrescar el pin, hacerlo
/// FUERA del proceso de la app (script del launcher), nunca por FFI in-process.
Future<void> refrescarIconoEscritorioWindows() async {
  if (!Platform.isWindows) return;
  try {
    final info = await PackageInfo.fromPlatform();
    final version = '${info.version}+${info.buildNumber}';

    final prefs = await SharedPreferences.getInstance();
    const key = 'icono_escritorio_refrescado_para_version';
    if (prefs.getString(key) == version) return;

    final winDir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final ie4 = '$winDir\\System32\\ie4uinit.exe';
    if (await File(ie4).exists()) {
      await Process.run(ie4, ['-show']);
    }

    // Marcamos aunque algo falle: no queremos reintentar en cada arranque.
    await prefs.setString(key, version);
  } catch (e) {
    if (kDebugMode) {
      debugPrint('refrescarIconoEscritorioWindows (no bloqueante): $e');
    }
  }
}
