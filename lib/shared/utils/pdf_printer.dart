// =============================================================================
// PDF PRINTER — UX de impresión por plataforma (escritorio vs móvil)
// =============================================================================
//
// Encapsula la decisión de CÓMO imprimir un PDF según la plataforma:
//
// - **Windows**: `Printing.directPrintPdf` a la impresora default del
//   sistema. Sin diálogo intermedio. Esa es la UX que Santiago quiere
//   en la oficina — el operador genera el adelanto, le da imprimir, y
//   el papel sale directo. Cualquier diálogo extra lo distrae del flujo.
//
// - **iOS / Android**: `Printing.layoutPdf` que muestra el sheet
//   NATIVO de impresión del SO. En iOS aparece el dialog con AirPrint,
//   guardar en Files, share, etc. En Android aparece el dialog
//   "Imprimir / Guardar como PDF". El usuario elige destino.
//
//   **Bug previo (Santiago 2026-05-19)**: el código original usaba
//   `Printing.listPrinters` también en mobile, pero esa API devuelve
//   lista VACÍA en iOS (la API nativa no expone impresoras del sistema
//   de esa forma). Por eso siempre caía al fallback `_abrirPdfConViewerSistema`
//   que en iOS llamaba `launchUrl(Uri.file(...))` — y eso tampoco
//   funciona bien en iOS para PDFs locales del tempDir. Resultado:
//   tocar IMPRIMIR no hacía absolutamente nada visible. Fix:
//   detectar plataforma y rutear al API correcto del package.
//
// - **macOS / Linux desktop**: mismo flujo que Windows
//   (directPrintPdf + fallback viewer).
//
// - **Web**: no soportado. El caller debe chequear `kIsWeb` antes
//   de invocar y mostrar un mensaje al usuario.

import 'dart:io' show File, Platform, Process;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

/// Resultado de la operación de impresión, con un mensaje sugerido
/// para mostrar al usuario en un SnackBar.
class PdfPrintOutcome {
  /// `true` si el sistema operativo aceptó el PDF (sheet abierto en
  /// mobile, impreso/encolado en desktop). `false` si terminó en el
  /// viewer fallback o si el usuario canceló.
  final bool success;

  /// Texto sugerido para SnackBar de éxito/info. El caller puede
  /// usarlo tal cual o construir el suyo a partir de [success].
  final String mensajeUsuario;

  const PdfPrintOutcome({
    required this.success,
    required this.mensajeUsuario,
  });
}

class PdfPrinter {
  PdfPrinter._();

  /// Imprime [bytes] con UX por plataforma.
  ///
  /// - [nombreArchivo]: nombre que se muestra en el sheet de impresión
  ///   y el que recibe el archivo temporal si cae al viewer.
  /// - [etiquetaCorta]: descripción corta para los mensajes de
  ///   SnackBar (ej: "Comprobante Nro. 000123", "Resumen de
  ///   5 adelanto(s)"). Si null, se usa "Documento".
  ///
  /// Nunca tira excepciones — captura todo internamente y reporta vía
  /// el outcome.
  static Future<PdfPrintOutcome> imprimir({
    required Uint8List bytes,
    required String nombreArchivo,
    String? etiquetaCorta,
  }) async {
    final etiqueta = etiquetaCorta ?? 'Documento';

    // ─── Mobile (iOS + Android) → sheet nativo del SO ────────────────
    // `Printing.layoutPdf` muestra el preview con opciones de imprimir
    // (AirPrint en iOS, Cloud Print/Save en Android) y compartir. Es
    // la UX nativa que el usuario espera en móvil — no se intenta
    // impresión directa porque iOS no expone esa API.
    if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
      try {
        final ok = await Printing.layoutPdf(
          onLayout: (_) async => bytes,
          name: nombreArchivo,
        );
        if (ok) {
          return PdfPrintOutcome(
            success: true,
            mensajeUsuario: '$etiqueta listo para imprimir o compartir.',
          );
        }
        // ok=false significa que el usuario cerró el sheet sin imprimir.
        // No es un error — solo info.
        return const PdfPrintOutcome(
          success: false,
          mensajeUsuario:
              'Impresión cancelada. Volvé a tocar IMPRIMIR si lo necesitás.',
        );
      } catch (e, stack) {
        debugPrint('⚠️ Printing.layoutPdf (mobile) falló: $e');
        debugPrint(stack.toString());
        // Caer al viewer fallback (raro en mobile pero no imposible).
        final fallback = await _abrirPdfConViewerSistema(
          bytes,
          nombreArchivo: nombreArchivo,
        );
        return PdfPrintOutcome(
          success: fallback,
          mensajeUsuario: fallback
              ? '$etiqueta abierto en el visor.'
              : 'No se pudo abrir el documento. Probá de nuevo.',
        );
      }
    }

    // ─── Desktop (Windows + macOS + Linux) → impresión directa ───────
    try {
      final printers = await Printing.listPrinters();
      if (printers.isEmpty) {
        await _abrirPdfConViewerSistema(bytes, nombreArchivo: nombreArchivo);
        return PdfPrintOutcome(
          success: false,
          mensajeUsuario:
              '$etiqueta abierto en el visor. Imprimí desde ahí (Ctrl+P).',
        );
      }
      final printer = printers.firstWhere(
        (p) => p.isDefault,
        orElse: () => printers.first,
      );
      final ok = await Printing.directPrintPdf(
        printer: printer,
        onLayout: (_) async => bytes,
        name: nombreArchivo,
      );
      if (!ok) {
        await _abrirPdfConViewerSistema(bytes, nombreArchivo: nombreArchivo);
        return PdfPrintOutcome(
          success: false,
          mensajeUsuario:
              '$etiqueta abierto en el visor. Imprimí desde ahí (Ctrl+P).',
        );
      }
      return PdfPrintOutcome(
        success: true,
        mensajeUsuario: '$etiqueta enviado a la impresora.',
      );
    } catch (e, stack) {
      debugPrint('⚠️ Printing.directPrintPdf (desktop) falló: $e');
      debugPrint(stack.toString());
      final fallback = await _abrirPdfConViewerSistema(
        bytes,
        nombreArchivo: nombreArchivo,
      );
      return PdfPrintOutcome(
        success: fallback,
        mensajeUsuario: fallback
            ? '$etiqueta abierto en el visor. Imprimí desde ahí (Ctrl+P).'
            : 'No se pudo abrir el documento. Probá de nuevo.',
      );
    }
  }

  /// Fallback: escribe el PDF a temp y lo abre con el viewer del SO.
  /// Devuelve `true` si pudo lanzar el viewer, `false` si todo falló.
  static Future<bool> _abrirPdfConViewerSistema(
    Uint8List bytes, {
    required String nombreArchivo,
  }) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$nombreArchivo');
      await file.writeAsBytes(bytes, flush: true);
      if (!kIsWeb && Platform.isWindows) {
        await Process.start(
          'cmd',
          ['/c', 'start', '', file.path],
          runInShell: true,
        );
        return true;
      }
      final lanzado = await launchUrl(
        Uri.file(file.path),
        mode: LaunchMode.externalApplication,
      );
      return lanzado;
    } catch (e, stack) {
      debugPrint('⚠️ _abrirPdfConViewerSistema falló: $e');
      debugPrint(stack.toString());
      return false;
    }
  }
}
