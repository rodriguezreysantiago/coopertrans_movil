import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

/// Refresca el ícono del escritorio + pin de la barra de tareas en Windows
/// **una sola vez por versión nueva**, para que reflejen el ícono del .exe
/// recién actualizado.
///
/// Por qué acá (la app) y no en el launcher: ver `refrescar_icono_escritorio.dart`.
///
/// Hace dos cosas (ambas best-effort, nunca deben romper el arranque):
///  1. Re-escribe el IconLocation de los shortcuts del USUARIO (pin de
///     taskbar + escritorio del user) vía COM. El pin guarda su propio ícono
///     cacheado que `ie4uinit` NO refresca: hay que tocar su `.lnk`.
///  2. Corre `ie4uinit -show` para invalidar el caché de íconos del sistema
///     (cubre el shortcut del escritorio PÚBLICO, que es read-only sin admin).
///
/// No-op fuera de Windows.
Future<void> refrescarIconoEscritorioWindows() async {
  if (!Platform.isWindows) return;
  try {
    final info = await PackageInfo.fromPlatform();
    final version = '${info.version}+${info.buildNumber}';

    final prefs = await SharedPreferences.getInstance();
    const key = 'icono_escritorio_refrescado_para_version';
    if (prefs.getString(key) == version) return;

    _reescribirIconoShortcutsUsuario(Platform.resolvedExecutable);

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

/// Re-apunta el IconLocation de los shortcuts del usuario al `.exe` (toggle,
/// para forzar a la taskbar a soltar el ícono cacheado del pin). El shortcut
/// del escritorio PÚBLICO (`%PUBLIC%\Desktop`) lo crea el instalador como
/// admin → read-only para el user, no se intenta acá (lo cubre `ie4uinit`).
void _reescribirIconoShortcutsUsuario(String exe) {
  final appData = Platform.environment['APPDATA'];
  final userProfile = Platform.environment['USERPROFILE'];
  final lnks = <String>[
    if (appData != null)
      '$appData\\Microsoft\\Internet Explorer\\Quick Launch\\User Pinned\\TaskBar\\Coopertrans Movil.lnk',
    if (userProfile != null) '$userProfile\\Desktop\\Coopertrans Movil.lnk',
  ].where((p) => File(p).existsSync()).toList();
  if (lnks.isEmpty) return;

  // COM debe estar inicializado en este thread. Flutter usa STA en el thread
  // de UI → CoInitializeEx devuelve S_FALSE (ya inicializado), que igual hay
  // que balancear con CoUninitialize. Cualquier otro estado (error) → no
  // tocamos COM.
  final hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (hr != S_OK && hr != S_FALSE) return;
  try {
    for (final lnk in lnks) {
      _reescribirUnShortcut(lnk, exe);
    }
  } finally {
    CoUninitialize();
  }
}

void _reescribirUnShortcut(String lnk, String exe) {
  ShellLink? shellLink;
  IPersistFile? persistFile;
  final pathPtr = lnk.toNativeUtf16(allocator: calloc);
  final exeIcon = exe.toNativeUtf16(allocator: calloc);
  final tmpIcon =
      r'C:\Windows\System32\shell32.dll'.toNativeUtf16(allocator: calloc);
  try {
    shellLink = ShellLink.createInstance();
    persistFile = IPersistFile.from(shellLink);
    if (persistFile.load(pathPtr, STGM_READWRITE) != S_OK) return;
    // Toggle a un ícono cualquiera y de vuelta al .exe: fuerza a Explorer a
    // soltar el ícono cacheado del pin sin cambiar lo que el usuario ve
    // (queda apuntando al .exe, índice 0).
    shellLink.setIconLocation(tmpIcon, 2);
    persistFile.save(nullptr, TRUE);
    shellLink.setIconLocation(exeIcon, 0);
    persistFile.save(nullptr, TRUE);
  } catch (_) {
    // best-effort: un .lnk no editable no debe afectar al otro ni al arranque.
  } finally {
    persistFile?.release();
    shellLink?.release();
    calloc.free(pathPtr);
    calloc.free(exeIcon);
    calloc.free(tmpIcon);
  }
}
