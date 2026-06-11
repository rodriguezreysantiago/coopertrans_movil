// Stub no-web de `descargarBytesEnNavegador`.
//
// Este archivo se compila SOLO en móvil/desktop (donde existe dart:io). Ahí el
// guardado real lo hace `ReportSaveHelper` con File/Process/SharePlus, y el
// branch `kIsWeb` corta antes de llegar acá — así que esto JAMÁS debería
// ejecutarse. Lanzamos para que un llamado accidental fuera de web sea ruidoso
// (y caiga en el try/catch del helper) en vez de un no-op silencioso.
import 'dart:typed_data';

void descargarBytesEnNavegador(Uint8List bytes, String nombreArchivo) {
  throw UnsupportedError(
    'descargarBytesEnNavegador() solo está disponible en web; '
    'en móvil/desktop el guardado va por ReportSaveHelper '
    '(File/Process/SharePlus).',
  );
}
