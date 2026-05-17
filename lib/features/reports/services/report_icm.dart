// Reporte Excel del módulo ICM — pensado para presentar en auditorías
// YPF y para análisis interno de Vecchi.
//
// 3 hojas:
//   1. RESUMEN FLOTA — una fila por semana (ICM promedio + distribución).
//   2. DETALLE CHOFERES — chofer × semana con ICM, categoría, eventos.
//   3. TOP — top 5 mejores y top 5 peores de la última semana cerrada.
//
// Lee de `ICM_SEMANAL/{YYYY-WW}` (poblado por la scheduled function
// `recomputeIcmSemanalScheduled` cada lunes 6 AM ART). Para semanas
// que aún no tienen agregado pre-calculado, hace fallback al cálculo
// on-the-fly desde SITRACK_EVENTOS (mismo path que el cliente).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' as ex;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../icm/services/icm_calculator.dart';
import '../../icm/services/icm_historico_service.dart';
import 'excel_utils.dart' as xu;
import 'report_save_helper.dart';

class ReportIcmService {
  ReportIcmService._();

  static Future<void> mostrarOpcionesYGenerar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);

    if (kIsWeb) {
      AppFeedback.warningOn(messenger,
          'Los reportes Excel solo están disponibles en Windows y Android.');
      return;
    }

    final cantSemanas = await _mostrarDialogoSemanas(context);
    if (cantSemanas == null || !context.mounted) return;

    _notificarProgreso(messenger);
    await _ejecutarGeneracion(
      cantidadSemanas: cantSemanas,
      messenger: messenger,
    );
  }

  // ---------------------------------------------------------------------------
  // DIALOG DE OPCIONES
  // ---------------------------------------------------------------------------

  static Future<int?> _mostrarDialogoSemanas(BuildContext context) {
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        title: const Text('Reporte ICM — Cantidad de semanas'),
        content: const Text(
          'Cuántas semanas hacia atrás incluir en el reporte. La semana '
          'actual (aún en curso) entra siempre como última fila.',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 4),
            child: const Text('4 semanas'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 8),
            child: const Text('8 semanas'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentRed,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, 12),
            child: const Text('12 semanas'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // GENERACIÓN
  // ---------------------------------------------------------------------------

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
            Text('Generando reporte ICM...'),
          ],
        ),
        backgroundColor: Colors.blueGrey,
        duration: Duration(seconds: 60),
      ),
    );
  }

  static Future<void> _ejecutarGeneracion({
    required int cantidadSemanas,
    required ScaffoldMessengerState messenger,
  }) async {
    try {
      final db = FirebaseFirestore.instance;

      // Lookup nombres de empleados (para fallback on-the-fly)
      final empSnap = await db.collection('EMPLEADOS').get();
      final nombrePorDni = <String, String>{};
      for (final d in empSnap.docs) {
        final data = d.data();
        final dni = (data['DNI'] ?? d.id).toString();
        final nombre = (data['NOMBRE'] ?? '').toString().trim();
        if (nombre.isNotEmpty) nombrePorDni[dni] = nombre;
      }

      // Cargar histórico de la flota
      final historico = await IcmHistoricoService.historicoFlota(
        db: db,
        nombrePorDni: nombrePorDni,
        cantidadSemanas: cantidadSemanas,
      );
      if (historico.isEmpty) {
        messenger.hideCurrentSnackBar();
        AppFeedback.warningOn(messenger,
            'No hay datos suficientes para generar el reporte.');
        return;
      }

      // Cargar detalle por chofer de TODAS las semanas (queremos el
      // detalle completo en la hoja 2). Para cada semana, traemos los
      // choferes desde ICM_SEMANAL/{YYYY-WW}.choferes[]. Si no existe
      // (semana actual), hacemos ranking on-the-fly.
      final detallePorSemana = <String, List<Map<String, dynamic>>>{};
      for (final s in historico) {
        final id = _isoWeekId(s.semanaInicio);
        final snap = await db.collection('ICM_SEMANAL').doc(id).get();
        if (snap.exists && (snap.data()?['choferes'] as List?) != null) {
          detallePorSemana[id] = ((snap.data()!['choferes'] as List)
              .cast<Map<String, dynamic>>());
        } else {
          // Fallback: calculator on-the-fly (mismas semanas, mismos
          // choferes que aparecerían en el resumen)
          final inicio = s.semanaInicio.millisecondsSinceEpoch;
          final fin = inicio + 7 * 24 * 60 * 60 * 1000;
          final ranking = await IcmCalculator.calcularRanking(
            db: db,
            desdeMs: inicio,
            hastaMs: fin,
            nombrePorDni: nombrePorDni,
          );
          detallePorSemana[id] = ranking
              .map((c) => {
                    'dni': c.choferDni,
                    'nombre': c.choferNombre,
                    'icm': c.icm,
                    'total_eventos': c.totalEventos,
                    'ratio_100km': c.infraccionesPor100Km,
                    'categoria': _catLabel(c.categoria),
                  })
              .toList();
        }
      }

      final bytes = _construirExcel(
        historico: historico,
        detallePorSemana: detallePorSemana,
      );

      messenger.hideCurrentSnackBar();
      final ts = DateTime.now();
      final nombre =
          'ICM_Coopertrans_${intl.DateFormat('yyyy-MM-dd_HHmm').format(ts)}.xlsx';
      await ReportSaveHelper.guardarYAbrir(
        bytes: bytes,
        nombreDefault: nombre,
        messenger: messenger,
      );
    } catch (e, s) {
      messenger.hideCurrentSnackBar();
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo generar el reporte de ICM. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // EXCEL
  // ---------------------------------------------------------------------------

  static List<int> _construirExcel({
    required List<IcmSemanaFlota> historico,
    required Map<String, List<Map<String, dynamic>>> detallePorSemana,
  }) {
    final excel = ex.Excel.createExcel();
    // La hoja default "Sheet1" la borramos al final.

    _hojaResumenFlota(excel, historico);
    _hojaDetalleChoferes(excel, historico, detallePorSemana);
    _hojaTopMejoresPeores(excel, historico.last);

    excel.delete('Sheet1');

    final bytes = excel.save();
    if (bytes == null) {
      throw StateError('No se pudo serializar el Excel.');
    }
    return xu.aplicarAutoFilterAlXlsx(bytes);
  }

  static void _hojaResumenFlota(
    ex.Excel excel,
    List<IcmSemanaFlota> historico,
  ) {
    final hoja = excel['RESUMEN FLOTA'];
    final headers = [
      'SEMANA',
      'ICM PROMEDIO',
      'CHOFERES ACTIVOS',
      'TOTAL EVENTOS',
      'VERDES (>=80)',
      'AMARILLOS (60-79)',
      'ROJOS (<60)',
    ];
    for (var i = 0; i < headers.length; i++) {
      final cell = hoja.cell(ex.CellIndex.indexByColumnRow(
          columnIndex: i, rowIndex: 0));
      cell.value = ex.TextCellValue(headers[i]);
      cell.cellStyle = ex.CellStyle(
        bold: true,
        backgroundColorHex: ex.ExcelColor.fromHexString('#0EA5E9'),
        fontColorHex: ex.ExcelColor.white,
      );
    }
    for (var r = 0; r < historico.length; r++) {
      final s = historico[r];
      final row = r + 1;
      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .value = ex.TextCellValue(s.labelSemana);
      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .value = ex.DoubleCellValue(double.parse(s.icmPromedio.toStringAsFixed(1)));
      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row))
          .value = ex.IntCellValue(s.choferesActivos);
      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row))
          .value = ex.IntCellValue(s.totalEventos);
      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row))
          .value = ex.IntCellValue(s.choferesVerdes);
      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row))
          .value = ex.IntCellValue(s.choferesAmarillos);
      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row))
          .value = ex.IntCellValue(s.choferesRojos);
    }
    xu.autoFitColumnas(hoja, headers.length, historico.length + 1);
  }

  static void _hojaDetalleChoferes(
    ex.Excel excel,
    List<IcmSemanaFlota> historico,
    Map<String, List<Map<String, dynamic>>> detallePorSemana,
  ) {
    final hoja = excel['DETALLE CHOFERES'];
    final headers = [
      'SEMANA',
      'CHOFER',
      'DNI',
      'ICM',
      'CATEGORÍA',
      'TOTAL EVENTOS',
      'INFRACCIONES / 100 KM',
    ];
    for (var i = 0; i < headers.length; i++) {
      final cell = hoja.cell(ex.CellIndex.indexByColumnRow(
          columnIndex: i, rowIndex: 0));
      cell.value = ex.TextCellValue(headers[i]);
      cell.cellStyle = ex.CellStyle(
        bold: true,
        backgroundColorHex: ex.ExcelColor.fromHexString('#0EA5E9'),
        fontColorHex: ex.ExcelColor.white,
      );
    }
    var row = 1;
    for (final s in historico) {
      final id = _isoWeekId(s.semanaInicio);
      final choferes = detallePorSemana[id] ?? const [];
      // Ordenar por ICM ascendente (peor primero) para que Molina vea
      // primero los choferes a abordar.
      final sorted = [...choferes]
        ..sort((a, b) {
          final aIcm = (a['icm'] as num?)?.toDouble() ?? 0;
          final bIcm = (b['icm'] as num?)?.toDouble() ?? 0;
          return aIcm.compareTo(bIcm);
        });
      for (final c in sorted) {
        hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
            .value = ex.TextCellValue(s.labelSemana);
        hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
            .value = ex.TextCellValue((c['nombre'] ?? '').toString());
        hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row))
            .value = ex.TextCellValue((c['dni'] ?? '').toString());
        hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row))
            .value = ex.DoubleCellValue(
                ((c['icm'] as num?)?.toDouble() ?? 0).roundToDouble());
        hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row))
            .value = ex.TextCellValue((c['categoria'] ?? '').toString());
        hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row))
            .value = ex.IntCellValue(
                (c['total_eventos'] as num?)?.toInt() ?? 0);
        hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row))
            .value = ex.DoubleCellValue(
                ((c['ratio_100km'] as num?)?.toDouble() ?? 0));
        row++;
      }
    }
    xu.autoFitColumnas(hoja, headers.length, row);
  }

  static void _hojaTopMejoresPeores(
    ex.Excel excel,
    IcmSemanaFlota ultima,
  ) {
    final hoja = excel['TOP'];
    // Header sección "Mejores"
    hoja.cell(ex.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
      ..value = ex.TextCellValue('TOP 5 MEJORES — ${ultima.labelSemana}')
      ..cellStyle = ex.CellStyle(
        bold: true,
        backgroundColorHex: ex.ExcelColor.fromHexString('#16A34A'),
        fontColorHex: ex.ExcelColor.white,
      );
    _escribirHeadersTop(hoja, 1);
    for (var i = 0; i < ultima.top5Mejores.length; i++) {
      _escribirFilaTop(hoja, 2 + i, i + 1, ultima.top5Mejores[i]);
    }
    final filaSep = 2 + ultima.top5Mejores.length + 2;
    hoja.cell(ex.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: filaSep))
      ..value = ex.TextCellValue('TOP 5 PEORES — ${ultima.labelSemana}')
      ..cellStyle = ex.CellStyle(
        bold: true,
        backgroundColorHex: ex.ExcelColor.fromHexString('#DC2626'),
        fontColorHex: ex.ExcelColor.white,
      );
    _escribirHeadersTop(hoja, filaSep + 1);
    for (var i = 0; i < ultima.top5Peores.length; i++) {
      _escribirFilaTop(hoja, filaSep + 2 + i, i + 1, ultima.top5Peores[i]);
    }
    xu.autoFitColumnas(
        hoja, 4, filaSep + 2 + ultima.top5Peores.length + 1);
  }

  static void _escribirHeadersTop(ex.Sheet hoja, int row) {
    const headers = ['POSICIÓN', 'CHOFER', 'DNI', 'ICM'];
    for (var i = 0; i < headers.length; i++) {
      hoja.cell(ex.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: row))
        ..value = ex.TextCellValue(headers[i])
        ..cellStyle = ex.CellStyle(bold: true);
    }
  }

  static void _escribirFilaTop(
    ex.Sheet hoja,
    int row,
    int posicion,
    IcmChofer c,
  ) {
    hoja.cell(ex.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
        .value = ex.IntCellValue(posicion);
    hoja.cell(ex.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
        .value = ex.TextCellValue(c.choferNombre);
    hoja.cell(ex.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row))
        .value = ex.TextCellValue(c.choferDni);
    hoja.cell(ex.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row))
        .value = ex.DoubleCellValue(c.icm.roundToDouble());
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  /// ID semana ISO 8601 ("YYYY-WNN"). Mismo algoritmo que el cron
  /// server-side y que `IcmHistoricoService._isoWeekId`.
  static String _isoWeekId(DateTime d) {
    final target = DateTime.utc(d.year, d.month, d.day);
    final dayNum = (target.weekday + 6) % 7;
    final thursday = target.add(Duration(days: 3 - dayNum));
    final firstThursday = DateTime.utc(thursday.year, 1, 4);
    final firstThursdayDayNum = (firstThursday.weekday + 6) % 7;
    final week = 1 +
        ((thursday.difference(firstThursday).inDays - 3 + firstThursdayDayNum) /
                7)
            .round();
    return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
  }

  static String _catLabel(CategoriaIcm c) {
    switch (c) {
      case CategoriaIcm.bajo:
        return 'BAJO';
      case CategoriaIcm.medio:
        return 'MEDIO';
      case CategoriaIcm.alto:
        return 'ALTO';
      case CategoriaIcm.sinDatos:
        return 'sin datos';
    }
  }
}
