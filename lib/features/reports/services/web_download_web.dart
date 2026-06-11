// Implementación web de `descargarBytesEnNavegador` (solo entra al build web
// vía import condicional en `web_download.dart`).
//
// Web puro, SIN dart:io: arma un Blob con los bytes del .xlsx, crea un
// `<a download>` temporal, lo clickea y libera el object URL. Es el reemplazo
// web del file picker (desktop) / SharePlus (móvil) — el navegador dispara la
// descarga al directorio de descargas del usuario.
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// MIME oficial del formato .xlsx (OpenXML spreadsheet).
const _mimeXlsx =
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

void descargarBytesEnNavegador(Uint8List bytes, String nombreArchivo) {
  // El Blob necesita un JSArray de "blob parts". Pasamos los bytes como
  // JSUint8Array (vista tipada que copia los datos al heap de JS).
  final partes = <JSAny>[bytes.toJS].toJS;
  final blob = web.Blob(
    partes,
    web.BlobPropertyBag(type: _mimeXlsx),
  );

  final url = web.URL.createObjectURL(blob);
  // `document.createElement('a')` + cast (no `new HTMLAnchorElement()`: los
  // elementos no son construibles vía constructor en JS). Oculto y clickeado
  // por código. Lo agregamos al DOM porque algunos navegadores (Firefox) no
  // disparan `.click()` si el <a> no está montado.
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = nombreArchivo
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  // Liberar la memoria del object URL (si no, queda viva hasta cerrar la
  // pestaña).
  web.URL.revokeObjectURL(url);
}
