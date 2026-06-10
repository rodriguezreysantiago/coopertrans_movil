import 'package:excel/excel.dart' as ex;
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';

import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../reports/services/excel_utils.dart' as xu;
import '../../reports/services/report_save_helper.dart';
import '../models/adelanto_chofer.dart';
import '../models/tarifa_logistica.dart';
import '../models/ubicacion_logistica.dart';
import '../models/viaje.dart';
import '../services/liquidacion_service.dart' show EmpleadoLiquidacion;
import 'logistica_service.dart';
import 'report_planilla_chofer.dart';

/// Reporte Excel de liquidación — la "planilla de cuadernos" mensual.
/// Lo dispara la pantalla `LogisticaLiquidacionScreen` con los viajes
/// + adelantos ya filtrados en memoria (mes + empresa empleadora +
/// chofer + estado liquidado).
///
/// Desde 2026-06-10 el archivo replica el formato histórico que
/// administración usaba antes de la app (`VIAJES VC <MES>.xlsm`) —
/// pedido Vecchi. Output:
///   1. RESUMEN      — choferes × BRUTO/ADELANTOS/GASTOS/FINAL con
///                     fórmulas vivas + DNI y FACTURADO A EMPRESA.
///   2. Una hoja POR CHOFER en formato cuaderno (adelantos + viajes
///                     en paralelo + bloque de liquidación al pie).
///      → ver `ReportPlanillaChofer` para el layout y las fórmulas.
///   3. VIAJES       — anexo: una fila por viaje con monto, estado,
///                     liquidado y unidad (trazabilidad de la app).
///   4. ADELANTOS    — anexo: una fila por adelanto con medio de
///                     pago, recibo e impresión.
///
/// Los catálogos de tarifas y ubicaciones se leen one-shot al generar
/// (únicos reads de Firestore acá) para resolver las columnas PROV.
/// del cuaderno — el snapshot del tramo no guarda provincia. Si esa
/// lectura falla (sin red), el reporte sale igual con PROV. en blanco.
class ReportLiquidacionService {
  ReportLiquidacionService._();

  static Future<void> generar({
    required BuildContext context,
    required List<Viaje> viajes,
    required List<AdelantoChofer> adelantos,
    required Map<String, EmpleadoLiquidacion> empleados,
    required DateTime mes,
    String? empresaCuit,
    String? choferDniFiltro,
  }) async {
    final messenger = ScaffoldMessenger.of(context);

    if (kIsWeb) {
      AppFeedback.warningOn(messenger,
          'Los reportes Excel solo están disponibles en Windows, Android e iOS.');
      return;
    }
    if (viajes.isEmpty && adelantos.isEmpty) {
      AppFeedback.warningOn(messenger,
          'No hay datos para exportar en el período seleccionado.');
      return;
    }

    _notificarProgreso(messenger);
    try {
      final provincias = await _cargarResolverProvincias();

      // CONSULTA (dropdown) + hojas cuaderno (una por chofer) + RESUMEN.
      final wb = ReportPlanillaChofer.construir(
        viajes: viajes,
        adelantos: adelantos,
        empleados: empleados,
        mes: mes,
        provincias: provincias,
      );
      final excel = wb.excel;

      // Anexos tabulares al final (trazabilidad completa de la app:
      // estado, liquidado, unidad, medio de pago, recibo).
      _llenarHojaViajes(
        excel,
        viajes: viajes,
        empleados: empleados,
      );
      _llenarHojaAdelantos(
        excel,
        adelantos: adelantos,
        empleados: empleados,
      );

      final bytesRaw = excel.save();
      if (bytesRaw == null || bytesRaw.isEmpty) {
        throw StateError('El archivo Excel se generó vacío.');
      }
      // AutoFilter SOLO en los anexos — las hojas cuaderno y el
      // RESUMEN tienen headers merged y bloques de pie; un autofilter
      // en A1 las rompe visualmente.
      var bytes = xu.aplicarAutoFilterAlXlsx(
        bytesRaw,
        soloHojas: {'VIAJES', 'ADELANTOS'},
      );
      // Dropdown de chofer en CONSULTA + ocultar las hojas por chofer
      // (quedan como fuente de datos del espejo INDIRECT + RESUMEN).
      bytes = xu.configurarConsultaYOcultarHojas(
        bytes,
        hojaConsulta: 'CONSULTA',
        celdaDropdown: 'H1',
        cantidadChoferes: wb.cantidadChoferes,
        hojasAOcultar: wb.hojasChofer.toSet(),
      );

      // Nombre: `Viajes_VC_MAYO_2026_<timestamp>.xlsx` (convención de
      // la planilla histórica) con sufijo chofer o empresa si filtró
      // por alguno (para que se diferencien exports del mismo mes).
      final mesStr =
          AppFormatters.formatearMes(mes).toUpperCase().replaceAll(' ', '_');
      final sufijos = <String>[];
      if (choferDniFiltro != null) {
        final nombre = empleados[choferDniFiltro]?.nombre ?? choferDniFiltro;
        sufijos.add(slugSeguro(nombre));
      } else if (empresaCuit != null) {
        sufijos.add(slugSeguro(empresaCuit));
      }
      final sufijo = sufijos.isEmpty ? null : sufijos.join('_');
      final nombreArchivo = ReportSaveHelper.nombreUnico(
        'Viajes_VC_$mesStr',
        sufijoExtra: sufijo,
      );

      await ReportSaveHelper.guardarYAbrir(
        bytes: bytes,
        nombreDefault: nombreArchivo,
        messenger: messenger,
        textoCompartir:
            'Planilla de viajes ${AppFormatters.formatearMes(mes)} — Coopertrans Móvil',
      );
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo generar el reporte de liquidación. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  /// Lee tarifas + ubicaciones one-shot y arma el resolver de
  /// provincias para las columnas PROV. del cuaderno. Sin red (o
  /// cualquier error) → resolver vacío: el reporte sale igual, con
  /// las provincias en blanco.
  static Future<ResolverProvincias> _cargarResolverProvincias() async {
    try {
      final snaps = await Future.wait([
        LogisticaService.tarifasCol.get(),
        LogisticaService.ubicacionesCol.get(),
      ]);
      return ResolverProvincias(
        tarifas: snaps[0].docs.map(TarifaLogistica.fromDoc).toList(),
        ubicaciones: snaps[1].docs.map(UbicacionLogistica.fromDoc).toList(),
      );
    } catch (_) {
      return ResolverProvincias.vacio();
    }
  }

  // ===========================================================================
  // HOJAS ANEXO
  // ===========================================================================

  static void _llenarHojaViajes(
    ex.Excel excel, {
    required List<Viaje> viajes,
    required Map<String, EmpleadoLiquidacion> empleados,
  }) {
    final hoja = excel['VIAJES'];
    final headers = [
      'FECHA',
      'CHOFER',
      'DNI',
      'TRACTOR',
      'ENGANCHE',
      'TRAMOS',
      'RUTA',
      'KG DESCARGADOS',
      'FACTURADO',
      'COMISIÓN CHOFER',
      'REDONDEADO',
      'GASTOS',
      'LIQUIDADO',
      'ESTADO',
    ];
    for (var i = 0; i < headers.length; i++) {
      final cell = hoja.cell(
          ex.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = ex.TextCellValue(headers[i]);
      cell.cellStyle = ex.CellStyle(
        bold: true,
        backgroundColorHex: ex.ExcelColor.fromHexString('#1565C0'),
        fontColorHex: ex.ExcelColor.fromHexString('#FFFFFF'),
      );
    }

    final ordenados = [...viajes]
      ..sort((a, b) {
        final fa = a.fechaReferencia;
        final fb = b.fechaReferencia;
        if (fa == null && fb == null) return 0;
        if (fa == null) return 1;
        if (fb == null) return -1;
        return fa.compareTo(fb);
      });

    var row = 1;
    for (final v in ordenados) {
      final fecha = v.fechaReferencia;
      final fechaStr =
          fecha == null ? '' : AppFormatters.formatearFecha(fecha);
      final nombre = v.choferNombre ?? empleados[v.choferDni]?.nombre ?? '';
      final kgDescTotal = v.tramos.fold<double>(
        0,
        (acc, t) => acc + (t.kgDescargados ?? 0),
      );

      _setText(hoja, 0, row, fechaStr);
      _setText(hoja, 1, row, nombre);
      _setText(hoja, 2, row, v.choferDni);
      _setText(hoja, 3, row, v.vehiculoId ?? '');
      _setText(hoja, 4, row, v.engancheId ?? '');
      _setInt(hoja, 5, row, v.cantidadTramos);
      _setText(hoja, 6, row, v.rutaEtiqueta);
      if (kgDescTotal > 0) {
        _setInt(hoja, 7, row, kgDescTotal.round());
      }
      _setMonto(hoja, 8, row, v.montoVecchi);
      _setMonto(hoja, 9, row, v.montoChofer);
      _setMonto(hoja, 10, row, v.montoChoferRedondeado);
      _setMonto(hoja, 11, row, v.gastosTotal);
      _setText(hoja, 12, row, v.liquidado ? 'SÍ' : 'NO');
      _setText(hoja, 13, row, v.estado.etiqueta);

      row++;
    }

    xu.autoFitColumnas(hoja, headers.length, row);
  }

  static void _llenarHojaAdelantos(
    ex.Excel excel, {
    required List<AdelantoChofer> adelantos,
    required Map<String, EmpleadoLiquidacion> empleados,
  }) {
    final hoja = excel['ADELANTOS'];
    final headers = [
      'FECHA',
      'CHOFER',
      'DNI',
      'MONTO',
      'MEDIO DE PAGO',
      'OBSERVACIÓN',
      'VIAJE ID',
      'RECIBO N°',
      'IMPRESO',
    ];
    for (var i = 0; i < headers.length; i++) {
      final cell = hoja.cell(
          ex.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = ex.TextCellValue(headers[i]);
      cell.cellStyle = ex.CellStyle(
        bold: true,
        backgroundColorHex: ex.ExcelColor.fromHexString('#EF6C00'),
        fontColorHex: ex.ExcelColor.fromHexString('#FFFFFF'),
      );
    }

    final ordenados = [...adelantos]..sort((a, b) => a.fecha.compareTo(b.fecha));

    var row = 1;
    for (final a in ordenados) {
      final nombre = a.choferNombre ?? empleados[a.choferDni]?.nombre ?? '';
      _setText(hoja, 0, row, AppFormatters.formatearFecha(a.fecha));
      _setText(hoja, 1, row, nombre);
      _setText(hoja, 2, row, a.choferDni);
      _setMonto(hoja, 3, row, a.monto);
      _setText(hoja, 4, row, a.medioPago.etiqueta);
      _setText(hoja, 5, row, a.observacion ?? '');
      _setText(hoja, 6, row, a.viajeId ?? '');
      if (a.numeroRecibo != null) {
        _setText(hoja, 7, row, a.numeroRecibo.toString().padLeft(6, '0'));
      }
      _setText(
        hoja,
        8,
        row,
        a.impresoEn == null
            ? 'NO'
            : AppFormatters.formatearFechaHoraSinSegundos(a.impresoEn),
      );

      row++;
    }

    xu.autoFitColumnas(hoja, headers.length, row);
  }

  // ===========================================================================
  // HELPERS DE CELDA
  // ===========================================================================

  static void _setText(ex.Sheet hoja, int col, int row, String v) {
    hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
            .value =
        ex.TextCellValue(v);
  }

  static void _setInt(ex.Sheet hoja, int col, int row, int v) {
    final cell = hoja.cell(
        ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    cell.value = ex.IntCellValue(v);
    cell.cellStyle = ex.CellStyle(numberFormat: xu.formatoARSinDecimales);
  }

  static void _setMonto(
    ex.Sheet hoja,
    int col,
    int row,
    double v, {
    bool bold = false,
  }) {
    final cell = hoja.cell(
        ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    cell.value = ex.DoubleCellValue(v);
    cell.cellStyle = ex.CellStyle(
      numberFormat: xu.formatoAR,
      bold: bold,
    );
  }

  // ===========================================================================
  // OTROS
  // ===========================================================================

  @visibleForTesting
  static String slugSeguro(String raw) {
    final s = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[áä]'), 'a')
        .replaceAll(RegExp(r'[éë]'), 'e')
        .replaceAll(RegExp(r'[íï]'), 'i')
        .replaceAll(RegExp(r'[óö]'), 'o')
        .replaceAll(RegExp(r'[úü]'), 'u')
        .replaceAll('ñ', 'n')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    // Recortar sobre la longitud del string YA transformado (NO raw.length):
    // los replaceAll colapsan runs y recortan puntas, así que el slug puede
    // quedar más corto que el original. Usar raw.length pedía más caracteres
    // de los que quedaron → RangeError y la liquidación NO se generaba.
    // Ej: "Vecchi S.R.L." (13) → "vecchi_s_r_l" (12). Auditoría 2026-05-22.
    return s.length > 32 ? s.substring(0, 32) : s;
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
            Text('Generando reporte de liquidación...'),
          ],
        ),
        backgroundColor: Colors.blueGrey,
      ),
    );
  }
}
