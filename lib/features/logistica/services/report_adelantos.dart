import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/pdf_printer.dart';
import '../models/adelanto_chofer.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
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
///   - Tabla con: # | FECHA | EMPLEADO | DETALLE | ESTADO | ADELANTO $ | N° RECIBO.
///     (ESTADO + FECHA por fila agregadas 2026-05-19 — el resumen ahora
///      mezcla pendientes + entregados + eliminados; cada fila refleja
///      su estado y la fecha del adelanto, los eliminados van tachados.)
///   - Footer chico con timestamp de impresión.
///
/// Impresión delegada a `PdfPrinter` (lib/shared/utils/pdf_printer.dart):
/// directo a impresora default en desktop, sheet nativo (AirPrint /
/// Cloud Print) en iOS y Android. Mismo helper que usa el comprobante
/// individual de la pantalla de adelantos.
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
    /// Si el listado está filtrado por un empleado específico, su
    /// nombre se imprime en el header del PDF como bloque resaltado
    /// con cantidad de adelantos + totales por estado (Santiago
    /// 2026-05-19). Pasar null cuando no hay filtro de empleado.
    String? empleadoFiltradoNombre,
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

      final pdfBytes = await _generarPdf(
        ordenados,
        empleadoFiltradoNombre: empleadoFiltradoNombre,
      );

      // Nombre tipo "Adelantos-Resumen-2026-05-13_HHmmss.pdf".
      // (era "Pendientes-" hasta 2026-05-19, ahora el resumen mezcla
      // pendientes + entregados + eliminados según selección).
      final ts = DateTime.now();
      final nombreArchivo =
          'Adelantos-Resumen-${_slugFecha(ts)}_${_hhmmss(ts)}.pdf';

      final outcome = await PdfPrinter.imprimir(
        bytes: pdfBytes,
        nombreArchivo: nombreArchivo,
        etiquetaCorta: 'Resumen de ${ordenados.length} adelanto(s)',
      );
      AppFeedback.successOn(messenger, outcome.mensajeUsuario);
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

  static Future<Uint8List> _generarPdf(
    List<AdelantoChofer> adelantos, {
    String? empleadoFiltradoNombre,
  }) async {
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
          // Bloque de resumen del empleado filtrado (solo si hay
          // filtro activo). Mismo contenido que el mini-card que ve
          // el operador en la app antes de imprimir.
          if (empleadoFiltradoNombre != null) ...[
            _bloqueResumenEmpleado(empleadoFiltradoNombre, adelantos),
            pw.SizedBox(height: 10),
          ],
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
                pw.SizedBox(width: AppSpacing.md),
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
                      'Resumen de adelantos',
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
          pw.SizedBox(height: AppSpacing.sm),
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
          pw.SizedBox(height: AppSpacing.sm),
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

  /// Bloque de resumen del empleado filtrado (Santiago 2026-05-19).
  /// Aparece en el PDF cuando se imprime con filtro de empleado
  /// activo — mismo contenido que el mini-card de la pantalla:
  /// nombre, cantidad de adelantos en el rango, totales por estado
  /// (pendiente / entregado / eliminado).
  static pw.Widget _bloqueResumenEmpleado(
    String nombre,
    List<AdelantoChofer> adelantos,
  ) {
    // Excluimos eliminados de los totales en plata (no son plata
    // real) pero los contamos en "X adelantos en rango".
    final activos = adelantos.where((a) => !a.eliminado).toList();
    final pendientes = activos.where((a) => !a.pagado).toList();
    final entregados = activos.where((a) => a.pagado).toList();
    final eliminados = adelantos.where((a) => a.eliminado).toList();
    final totPend = pendientes.fold<double>(0, (s, a) => s + a.monto);
    final totEntr = entregados.fold<double>(0, (s, a) => s + a.monto);
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.blue50,
        border: pw.Border.all(color: PdfColors.blue300, width: 0.8),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Text(
                  nombre.toUpperCase(),
                  style: pw.TextStyle(
                    color: PdfColors.blue900,
                    fontSize: 13,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.Text(
                '${adelantos.length} adelanto'
                '${adelantos.length == 1 ? '' : 's'} en rango',
                style: pw.TextStyle(
                  color: PdfColors.blue900,
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 6),
          pw.Row(
            children: [
              pw.Expanded(
                child: _miniChipPdf(
                  label: 'PENDIENTE',
                  cant: pendientes.length,
                  monto: totPend,
                  color: PdfColors.orange700,
                ),
              ),
              pw.SizedBox(width: AppSpacing.sm),
              pw.Expanded(
                child: _miniChipPdf(
                  label: 'ENTREGADO',
                  cant: entregados.length,
                  monto: totEntr,
                  color: PdfColors.green700,
                ),
              ),
              if (eliminados.isNotEmpty) ...[
                pw.SizedBox(width: AppSpacing.sm),
                pw.Expanded(
                  child: _miniChipPdf(
                    label: 'ELIMINADO',
                    cant: eliminados.length,
                    monto: 0,
                    color: PdfColors.grey600,
                    sinMonto: true,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _miniChipPdf({
    required String label,
    required int cant,
    required double monto,
    required PdfColor color,
    bool sinMonto = false,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border(left: pw.BorderSide(color: color, width: 3)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            '$label · $cant',
            style: pw.TextStyle(
              color: color,
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          if (!sinMonto)
            pw.Text(
              '\$ ${AppFormatters.formatearMonto(monto)}',
              style: pw.TextStyle(
                color: PdfColors.black,
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }

  static pw.Widget _tablaAdelantos(List<AdelantoChofer> adelantos) {
    // 7 columnas — anchos ajustados Santiago 2026-05-19 tras ver que
    // # / FECHA / ESTADO se cortaban en 2 líneas. Cambios:
    //   #         flex 0.8 → 1.2   (entra "16" sin wrap)
    //   FECHA     flex 1.5 → 2.2   (entra "14/05" sin wrap)
    //   ESTADO    flex 2.4 → 3.0   (entra "ENTREGADO" sin wrap)
    //   EMPLEADO  flex 6   → 5.5   (compensa)
    //   DETALLE   flex 7   → 6.5
    //   ADELANTO  flex 3   → 3.0   (sin cambio)
    //   N° RECIBO flex 2.5 → 2.5   (sin cambio)
    final colWidths = <int, pw.TableColumnWidth>{
      0: const pw.FlexColumnWidth(1.2),
      1: const pw.FlexColumnWidth(2.2),
      2: const pw.FlexColumnWidth(5.5),
      3: const pw.FlexColumnWidth(6.5),
      4: const pw.FlexColumnWidth(3.0),
      5: const pw.FlexColumnWidth(3.0),
      6: const pw.FlexColumnWidth(2.5),
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
            _celdaHeader('FECHA', align: pw.TextAlign.center),
            _celdaHeader('EMPLEADO'),
            _celdaHeader('DETALLE'),
            _celdaHeader('ESTADO', align: pw.TextAlign.center),
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
    // Fecha sin año (Santiago 2026-05-19): el rango ya está en el
    // header "FECHAS: …" — repetir el año por fila ocupa espacio y
    // no aporta info nueva. Formato compacto DD/MM.
    final fechaStr = '${a.fecha.day.toString().padLeft(2, '0')}/'
        '${a.fecha.month.toString().padLeft(2, '0')}';
    // Estado visible en el PDF (Santiago 2026-05-19): el resumen
    // ahora puede mezclar pendientes + pagados + eliminados, hay
    // que distinguirlos a simple vista.
    final estadoLabel = a.eliminado
        ? 'ELIMINADO'
        : (a.pagado ? 'ENTREGADO' : 'PENDIENTE');
    final estadoColor = a.eliminado
        ? PdfColors.grey600
        : (a.pagado ? PdfColors.green800 : PdfColors.orange800);
    // Línea de tachado visual cuando está eliminado para que salte
    // más a la vista al revisar el papel impreso.
    final tachado = a.eliminado;

    return pw.TableRow(
      verticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: [
        _celdaDato(numero.toString(),
            align: pw.TextAlign.center, tachado: tachado),
        _celdaDato(fechaStr,
            align: pw.TextAlign.center, tachado: tachado),
        _celdaDato(nombre, tachado: tachado),
        _celdaDato(detalle, tachado: tachado),
        _celdaDato(estadoLabel,
            align: pw.TextAlign.center, bold: true, color: estadoColor),
        _celdaDato('\$ $monto',
            align: pw.TextAlign.right, bold: true, tachado: tachado),
        _celdaDato(recibo, align: pw.TextAlign.center, tachado: tachado),
      ],
    );
  }

  static pw.Widget _celdaHeader(String text,
      {pw.TextAlign align = pw.TextAlign.left}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 7),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        ),
      ),
    );
  }

  static pw.Widget _celdaDato(String text,
      {pw.TextAlign align = pw.TextAlign.left,
      bool bold = false,
      bool tachado = false,
      PdfColor? color}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: color ?? (tachado ? PdfColors.grey500 : PdfColors.black),
          decoration: tachado ? pw.TextDecoration.lineThrough : null,
        ),
      ),
    );
  }

  /// Devuelve "FECHA: dd-mm-aaaa" si todos los adelantos son del
  /// mismo día, o "FECHAS: primero AL último" si son varios días.
  ///
  /// (Antes 2026-05-19 listaba cada fecha distinta con · cuando eran
  /// ≤5 días — pero quedaba feo en el papel impreso: "FECHAS:
  /// 14/05/2026 · 15/05/2026 · 16/05/2026 · 18/05/2026 · 19/05/2026".
  /// Santiago pidió rango compacto "DESDE al HASTA" siempre que sean
  /// más de 1 día, sin importar cuántos.)
  static String _etiquetaFechas(List<AdelantoChofer> adelantos) {
    final dias = <DateTime>{};
    for (final a in adelantos) {
      dias.add(DateTime(a.fecha.year, a.fecha.month, a.fecha.day));
    }
    final ordenados = dias.toList()..sort();
    if (ordenados.length == 1) {
      return 'FECHA: ${AppFormatters.formatearFecha(ordenados.first)}';
    }
    return 'FECHAS: ${AppFormatters.formatearFecha(ordenados.first)} '
        'al ${AppFormatters.formatearFecha(ordenados.last)}';
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

