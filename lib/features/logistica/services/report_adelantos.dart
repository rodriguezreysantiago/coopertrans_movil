import 'dart:io' show File, Platform, Process;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../models/adelanto_chofer.dart';

/// Resumen de adelantos en PDF — pensado para imprimir, NO para
/// enviar al contador en Excel. Pedido por Santiago 2026-05-13: el
/// flujo físico es el mismo que el recibo individual (oficina entrega
/// la planilla a la persona que distribuye los adelantos), entonces
/// el resumen tiene que mantener el mismo look + flow de impresión
/// directa que el comprobante de adelanto individual.
///
/// Estructura (mimica el `recibos_adelanto_service.dart` pero
/// adaptada a una tabla):
///   - Logo VAVG arriba a la izquierda + "TRANSPORTE SERVI-TOLVA" +
///     subtítulo "Resumen de adelantos" en el header.
///   - Caja con FECHA: dd-mm-aaaa (o FECHAS si son varios días).
///   - Tabla con: # | CHOFER | DETALLE | ADELANTO $ | N° RECIBO.
///   - Footer chico con timestamp de impresión.
///
/// Imprime directo a la impresora default del sistema con
/// `Printing.directPrintPdf` y fallback al viewer del SO si falla.
/// Mismo patrón que `_ComprobantePrinter` de la pantalla de adelantos.
class ReportAdelantosService {
  ReportAdelantosService._();

  /// Punto de entrada desde la pantalla. Genera el PDF y lo manda a
  /// imprimir. Errores se reportan con SnackBar — el caller no
  /// necesita catchear.
  static Future<void> generar({
    required BuildContext context,
    required List<AdelantoChofer> adelantos,
    DateTime? fechaDesde,
    DateTime? fechaHasta,
  }) async {
    final messenger = ScaffoldMessenger.of(context);

    if (kIsWeb) {
      AppFeedback.warningOn(messenger,
          'La impresión solo está disponible en Windows, Android e iOS.');
      return;
    }
    if (adelantos.isEmpty) {
      AppFeedback.warningOn(
          messenger, 'No hay adelantos seleccionados para imprimir.');
      return;
    }

    _notificarProgreso(messenger);
    try {
      // Orden cronológico ASC para que el correlativo del reporte
      // (columna #) tenga sentido (más antiguos arriba). El stream de
      // la pantalla viene desc.
      final ordenados = [...adelantos]
        ..sort((a, b) => a.fecha.compareTo(b.fecha));

      final pdfBytes = await _generarPdf(ordenados);

      // Nombre tipo "Adelantos-Pendientes-2026-05-13_HHmmss.pdf".
      final ts = DateTime.now();
      final nombreArchivo =
          'Adelantos-Pendientes-${_slugFecha(ts)}_${_hhmmss(ts)}.pdf';

      final impresoOk = await _imprimirDirecto(pdfBytes, nombreArchivo);
      if (impresoOk) {
        AppFeedback.successOn(messenger,
            'Resumen de ${ordenados.length} adelanto(s) enviado a la impresora.');
      } else {
        AppFeedback.successOn(messenger,
            'Resumen abierto en el visor. Imprimí desde ahí (Ctrl+P).');
      }
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo generar el resumen de adelantos. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  // ===========================================================================
  // PDF
  // ===========================================================================

  static Future<Uint8List> _generarPdf(List<AdelantoChofer> adelantos) async {
    // Roboto regular + bold — necesarias para acentos españoles, °, —, etc.
    // Mismo motivo que `recibos_adelanto_service`: Helvetica embedded
    // del package `pdf` no garantiza esos glifos.
    final robotoRegular = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Roboto-Regular.ttf'),
    );
    final robotoBold = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Roboto-Bold.ttf'),
    );
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: robotoRegular, bold: robotoBold),
    );

    // Logo VAVG opcional. Si falla la carga del asset, seguimos sin
    // logo en lugar de romper el PDF — auditoría igual sirve.
    pw.MemoryImage? logo;
    try {
      final bytes = await rootBundle.load('assets/brand/vavg_logo.png');
      logo = pw.MemoryImage(bytes.buffer.asUint8List());
    } catch (_) {
      logo = null;
    }

    final fechaImpresion = DateTime.now();
    final etiquetaFechas = _etiquetaFechas(adelantos);

    // MultiPage para soportar listas largas que no entran en 1 hoja.
    // El `header` se repite en cada página; el footer también.
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(24, 20, 24, 20),
        header: (ctx) => _headerBuilder(
          logo: logo,
          etiquetaFechas: etiquetaFechas,
          numeroPagina: ctx.pageNumber,
          totalPaginas: ctx.pagesCount,
        ),
        footer: (ctx) => _footerBuilder(
          fechaImpresion: fechaImpresion,
          numeroPagina: ctx.pageNumber,
          totalPaginas: ctx.pagesCount,
        ),
        build: (ctx) => [
          _tablaAdelantos(adelantos),
        ],
      ),
    );

    final bytes = await doc.save();
    return bytes;
  }

  static pw.Widget _headerBuilder({
    required pw.MemoryImage? logo,
    required String etiquetaFechas,
    required int numeroPagina,
    required int totalPaginas,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 12),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (logo != null) ...[
                pw.SizedBox(
                  width: 60,
                  height: 36,
                  child: pw.Image(logo, fit: pw.BoxFit.contain),
                ),
                pw.SizedBox(width: 12),
              ],
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'TRANSPORTE SERVI-TOLVA',
                      style: pw.TextStyle(
                        fontSize: 16,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Adelantos pendientes de pago',
                      style: const pw.TextStyle(
                        fontSize: 11,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ],
                ),
              ),
              if (totalPaginas > 1)
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(
                      horizontal: 6, vertical: 3),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: PdfColors.grey400),
                  ),
                  child: pw.Text(
                    'Hoja $numeroPagina/$totalPaginas',
                    style: const pw.TextStyle(
                      fontSize: 9,
                      color: PdfColors.grey700,
                    ),
                  ),
                ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Container(
            padding:
                const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey200,
              border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
            ),
            child: pw.Text(
              etiquetaFechas,
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          pw.SizedBox(height: 8),
        ],
      ),
    );
  }

  static pw.Widget _footerBuilder({
    required DateTime fechaImpresion,
    required int numeroPagina,
    required int totalPaginas,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 8),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Impreso ${AppFormatters.formatearFechaHoraSinSegundos(fechaImpresion)}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
          if (totalPaginas > 1)
            pw.Text(
              '$numeroPagina / $totalPaginas',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
        ],
      ),
    );
  }

  static pw.Widget _tablaAdelantos(List<AdelantoChofer> adelantos) {
    // Anchos relativos de las 5 columnas. Ajustados a ojo en una
    // página A4 con margen 24 + headers de columna razonables:
    //   #          ~5%   centrado
    //   CHOFER     ~30%
    //   DETALLE    ~38%
    //   ADELANTO   ~15%  derecha
    //   N° RECIBO  ~12%  centrado
    final colWidths = <int, pw.TableColumnWidth>{
      0: const pw.FlexColumnWidth(1),
      1: const pw.FlexColumnWidth(6),
      2: const pw.FlexColumnWidth(7.5),
      3: const pw.FlexColumnWidth(3),
      4: const pw.FlexColumnWidth(2.5),
    };

    return pw.Table(
      columnWidths: colWidths,
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      children: [
        // ─── Header ─────────────────────────────────────────────────
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.green800),
          children: [
            _celdaHeader('#', align: pw.TextAlign.center),
            _celdaHeader('EMPLEADO'),
            _celdaHeader('DETALLE'),
            _celdaHeader('ADELANTO \$', align: pw.TextAlign.right),
            _celdaHeader('N° RECIBO', align: pw.TextAlign.center),
          ],
        ),
        // ─── Filas ──────────────────────────────────────────────────
        for (var i = 0; i < adelantos.length; i++)
          _filaAdelanto(i + 1, adelantos[i]),
      ],
    );
  }

  static pw.TableRow _filaAdelanto(int numero, AdelantoChofer a) {
    final nombre = a.choferNombre?.trim().isNotEmpty == true
        ? a.choferNombre!.trim()
        : 'DNI ${a.choferDni}';
    final detalle = a.observacion?.trim().isNotEmpty == true
        ? a.observacion!.trim()
        : '';
    final recibo = a.numeroRecibo == null
        ? ''
        : a.numeroRecibo.toString().padLeft(6, '0');
    final monto = AppFormatters.formatearMonto(a.monto);

    return pw.TableRow(
      verticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: [
        _celdaDato(numero.toString(), align: pw.TextAlign.center),
        _celdaDato(nombre),
        _celdaDato(detalle),
        _celdaDato('\$ $monto', align: pw.TextAlign.right, bold: true),
        _celdaDato(recibo, align: pw.TextAlign.center),
      ],
    );
  }

  static pw.Widget _celdaHeader(String text,
      {pw.TextAlign align = pw.TextAlign.left}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
          fontSize: 10,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        ),
      ),
    );
  }

  static pw.Widget _celdaDato(String text,
      {pw.TextAlign align = pw.TextAlign.left, bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
          fontSize: 10,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  /// Decide entre "FECHA: dd-mm-aaaa" (todos del mismo día), "FECHAS:
  /// a · b · c" (hasta 5 días distintos) o "FECHAS: primer AL último"
  /// (más de 5).
  static String _etiquetaFechas(List<AdelantoChofer> adelantos) {
    final dias = <DateTime>{};
    for (final a in adelantos) {
      dias.add(DateTime(a.fecha.year, a.fecha.month, a.fecha.day));
    }
    final ordenados = dias.toList()..sort();
    if (ordenados.length == 1) {
      return 'FECHA: ${AppFormatters.formatearFecha(ordenados.first)}';
    }
    if (ordenados.length > 5) {
      return 'FECHAS: ${AppFormatters.formatearFecha(ordenados.first)} '
          'AL ${AppFormatters.formatearFecha(ordenados.last)}';
    }
    return 'FECHAS: ${ordenados.map(AppFormatters.formatearFecha).join(" · ")}';
  }

  // ===========================================================================
  // IMPRESIÓN (mismo flow que _ComprobantePrinter del recibo individual)
  // ===========================================================================

  /// Manda el PDF a la impresora default del sistema. Devuelve `true`
  /// si pudo mandar a imprimir, `false` si terminó abriendo el viewer
  /// (sin impresora / falla del subsystem).
  static Future<bool> _imprimirDirecto(
      Uint8List bytes, String nombreArchivo) async {
    try {
      final printers = await Printing.listPrinters();
      if (printers.isEmpty) {
        await _abrirPdfConViewerSistema(bytes, nombreArchivo: nombreArchivo);
        return false;
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
        return false;
      }
      return true;
    } catch (e, stack) {
      debugPrint('⚠️ Printing.directPrintPdf falló: $e');
      debugPrint(stack.toString());
      await _abrirPdfConViewerSistema(bytes, nombreArchivo: nombreArchivo);
      return false;
    }
  }

  static Future<void> _abrirPdfConViewerSistema(
    Uint8List bytes, {
    required String nombreArchivo,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$nombreArchivo');
    await file.writeAsBytes(bytes, flush: true);
    if (!kIsWeb && Platform.isWindows) {
      await Process.start(
        'cmd',
        ['/c', 'start', '', file.path],
        runInShell: true,
      );
    } else {
      await launchUrl(
        Uri.file(file.path),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  static String _slugFecha(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yyyy = d.year.toString();
    return '$yyyy-$mm-$dd';
  }

  static String _hhmmss(DateTime d) {
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    final ss = d.second.toString().padLeft(2, '0');
    return '$hh$mm$ss';
  }

  static void _notificarProgreso(ScaffoldMessengerState messenger) {
    messenger.showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  color: Colors.white, strokeWidth: 2),
            ),
            SizedBox(width: 15),
            Text('Generando resumen para imprimir...'),
          ],
        ),
        backgroundColor: Colors.blueGrey,
      ),
    );
  }
}

