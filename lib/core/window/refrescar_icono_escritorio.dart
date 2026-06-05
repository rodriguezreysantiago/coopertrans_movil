// Refresco del ícono del escritorio en Windows tras un cambio de ícono.
//
// PROBLEMA: el .exe de Windows trae el ícono embebido (windows/runner/
// Runner.rc) y se actualiza con cada release vía el launcher de auto-update.
// Pero el CACHÉ de íconos de Windows sigue mostrando el viejo: el shortcut del
// escritorio ya apunta bien al .exe (`...coopertrans_movil.exe,0`), lo único
// que queda stale es el caché — Windows no lo invalida solo al sobrescribir el
// .exe con uno del mismo path.
//
// SOLUCIÓN: `ie4uinit.exe -show` invalida ese caché. Corre como usuario común
// (NO requiere admin) y NO toca el shortcut (que el instalador Inno Setup creó
// como admin en %PUBLIC%\Desktop y es read-only para el user). Por eso el
// refresco lo dispara la APP y no el launcher: el .exe llega a TODAS las PCs
// con cada release (auto-update), mientras que el launcher vive en
// Program Files (read-only) y no se auto-actualiza. Así, largar un release con
// ícono nuevo arregla el escritorio de todas las PCs sin tocarlas una por una.
//
// Selección por plataforma de COMPILACIÓN (igual patrón que desktop_window):
//   - con dart:io (móvil + desktop) → _io.dart  (corre ie4uinit en Windows)
//   - sin dart:io (web)             → _stub.dart (no-op)
//
// `Process`/`File`/`Platform` (dart:io) no existen en web; el stub evita que
// entren al build web. Llamar `refrescarIconoEscritorioWindows()` una vez
// desde main(), fire-and-forget (nunca debe demorar el primer frame).
export 'refrescar_icono_escritorio_stub.dart'
    if (dart.library.io) 'refrescar_icono_escritorio_io.dart';
