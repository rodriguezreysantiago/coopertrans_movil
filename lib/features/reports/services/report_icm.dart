// Reporte Excel del módulo ICM — pensado para presentar en auditorías
// YPF y para análisis interno de Vecchi.
//
// Usa el ICM **oficial de Sitrack** (`ICM_OFICIAL/{YYYY-MM}`, ingerido a
// diario por `sitrack_sync/sync_icm.py`) — el MISMO número que YPF audita
// en su tablero. Escala: MÁS BAJO = MEJOR. Antes este reporte calculaba el
// CESVI interno (semanal), que daba números optimistas que no coincidían
// con el tablero de YPF — peligroso justo en una auditoría.
//
// 3 hojas:
//   1. RESUMEN — flota: ICM general, distancia/tiempo, infracciones,
//      distribución por severidad + comparativa con el mes anterior.
//   2. CHOFERES — una fila por chofer (peor→mejor): ICM, urbano/no-urbano,
//      severidad, infracciones, excesos, conducción agresiva, km, horas.
//   3. UNIDADES — una fila por patente.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' as ex;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;

import '../../../core/services/excluidos_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../icm/services/icm_oficial_service.dart';
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

    final offset = await _mostrarDialogoMes(context);
    if (offset == null || !context.mounted) return;

    _notificarProgreso(messenger);
    await _ejecutarGeneracion(offsetMeses: offset, messenger: messenger);
  }

  // ---------------------------------------------------------------------------
  // DIALOG DE OPCIONES
  // ---------------------------------------------------------------------------

  static Future<int?> _mostrarDialogoMes(BuildContext context) {
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        title: const Text('Reporte ICM oficial — Mes'),
        content: const Text(
          'El ICM oficial de Sitrack se cierra por mes. Elegí qué mes '
          'exportar. El mes en curso se va completando día a día.',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, -1),
            child: const Text('Mes anterior'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, 0),
            child: const Text('Mes actual'),
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
    required int offsetMeses,
    required ScaffoldMessengerState messenger,
  }) async {
    try {
      final db = FirebaseFirestore.instance;

      // Excluir tanqueros + testers de las listas (no de los totales
      // auditados de Sitrack, que se muestran tal cual).
      final excluidos = await ExcluidosService.cargar(db: db);
      excluir(String dni) =>
          ExcluidosService.esExcluido(excluidos, dni: dni);
      excluirPat(String pat) =>
          ExcluidosService.esExcluido(excluidos, patente: pat);

      final idSel = IcmOficialService.periodoId(offsetMeses: offsetMeses);
      final idPrev =
          IcmOficialService.periodoId(offsetMeses: offsetMeses - 1);
      final cargados = await Future.wait([
        IcmOficialService.cargarPeriodo(db, idSel,
            excluirDni: excluir, excluirPatente: excluirPat),
        IcmOficialService.cargarPeriodo(db, idPrev,
            excluirDni: excluir, excluirPatente: excluirPat),
      ]);
      final periodo = cargados[0];
      final prev = cargados[1];

      if (periodo == null || periodo.vacio) {
        messenger.hideCurrentSnackBar();
        AppFeedback.warningOn(
          messenger,
          'Aún no hay datos del ICM oficial de '
          '${IcmOficialService.labelPeriodo(idSel)}. Se sincroniza a diario.',
        );
        return;
      }

      final bytes = _construirExcel(periodo: periodo, prev: prev);

      messenger.hideCurrentSnackBar();
      final nombre = 'ICM_Oficial_${periodo.periodo}_'
          '${intl.DateFormat('yyyy-MM-dd_HHmm').format(DateTime.now())}.xlsx';
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
    required IcmOficialPeriodo periodo,
    required IcmOficialPeriodo? prev,
  }) {
    final excel = ex.Excel.createExcel();

    _hojaResumen(excel, periodo, prev);
    _hojaChoferes(excel, periodo);
    _hojaUnidades(excel, periodo);

    excel.delete('Sheet1');

    final bytes = excel.save();
    if (bytes == null) {
      throw StateError('No se pudo serializar el Excel.');
    }
    return xu.aplicarAutoFilterAlXlsx(bytes);
  }

  static final _headerStyle = ex.CellStyle(
    bold: true,
    backgroundColorHex: ex.ExcelColor.fromHexString('#0EA5E9'),
    fontColorHex: ex.ExcelColor.white,
  );

  static void _setHeader(ex.Sheet hoja, int col, int row, String txt) {
    hoja.cell(ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
      ..value = ex.TextCellValue(txt)
      ..cellStyle = _headerStyle;
  }

  static void _setTxt(ex.Sheet hoja, int col, int row, String txt) {
    hoja
        .cell(ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
        .value = ex.TextCellValue(txt);
  }

  static void _setNum(ex.Sheet hoja, int col, int row, double v,
      {ex.CellStyle? style}) {
    final cell = hoja
        .cell(ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    cell.value = ex.DoubleCellValue(v);
    if (style != null) cell.cellStyle = style;
  }

  static void _setInt(ex.Sheet hoja, int col, int row, int v) {
    hoja
        .cell(ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
        .value = ex.IntCellValue(v);
  }

  static final _styleKm =
      ex.CellStyle(numberFormat: xu.formatoARSinDecimales);

  // ── Hoja 1: RESUMEN ────────────────────────────────────────────────
  static void _hojaResumen(
    ex.Excel excel,
    IcmOficialPeriodo p,
    IcmOficialPeriodo? prev,
  ) {
    final hoja = excel['RESUMEN'];
    _setHeader(hoja, 0, 0, 'CAMPO');
    _setHeader(hoja, 1, 0, 'VALOR');

    final c = p.conteoPorSeveridad;
    final altos = c[SeveridadIcm.alto] ?? 0;
    final medios = c[SeveridadIcm.medio] ?? 0;
    final bajos = (c[SeveridadIcm.bajo] ?? 0) +
        (c[SeveridadIcm.sinInfracciones] ?? 0);

    final filas = <List<dynamic>>[
      ['Período', IcmOficialService.labelPeriodo(p.periodo)],
      ['Rango', '${p.fechaDesde} a ${p.fechaHasta}'],
      ['ICM flota (oficial Sitrack) — más bajo = mejor', p.icmGeneral],
      if (prev != null && !prev.vacio) ...[
        ['ICM mes anterior', prev.icmGeneral],
        [
          'Variación vs mes anterior',
          '${p.icmGeneral - prev.icmGeneral >= 0 ? '+' : ''}'
              '${(p.icmGeneral - prev.icmGeneral).toStringAsFixed(1)} pts '
              '(${p.icmGeneral < prev.icmGeneral ? 'mejoró' : p.icmGeneral > prev.icmGeneral ? 'empeoró' : 'sin cambios'})',
        ],
      ],
      ['Choferes activos / total', '${p.choferesActivos} / ${p.choferesTotal}'],
      ['Distancia total (km)', p.distanciaTotalKm],
      ['Tiempo total (h)', p.tiempoTotalH],
      ['Infracciones altas', p.infraccionesAltas],
      ['Infracciones medias', p.infraccionesMedias],
      ['Infracciones leves', p.infraccionesLeves],
      ['Choferes severidad ALTA', altos],
      ['Choferes severidad MEDIA', medios],
      ['Choferes severidad BAJA / sin infracciones', bajos],
      ['Fuente', 'Tablero ICM oficial de Sitrack (auditado por YPF)'],
    ];

    for (var i = 0; i < filas.length; i++) {
      final row = i + 1;
      _setTxt(hoja, 0, row, filas[i][0].toString());
      final val = filas[i][1];
      if (val is int) {
        _setInt(hoja, 1, row, val);
      } else if (val is double) {
        _setNum(hoja, 1, row, val,
            style: filas[i][0].toString().contains('km')
                ? _styleKm
                : null);
      } else {
        _setTxt(hoja, 1, row, val.toString());
      }
    }
    xu.autoFitColumnas(hoja, 2, filas.length + 1);
  }

  // ── Hoja 2: CHOFERES ───────────────────────────────────────────────
  static void _hojaChoferes(ex.Excel excel, IcmOficialPeriodo p) {
    final hoja = excel['CHOFERES'];
    const headers = [
      'ICM',
      'SEVERIDAD',
      'CHOFER',
      'DNI',
      'ICM URBANO',
      'ICM NO URBANO',
      'INF. ALTAS',
      'INF. MEDIAS',
      'INF. LEVES',
      'EXCESOS VEL.',
      'COND. AGRESIVA',
      'DISTANCIA (KM)',
      'TIEMPO (H)',
    ];
    for (var i = 0; i < headers.length; i++) {
      _setHeader(hoja, i, 0, headers[i]);
    }
    // Peor→mejor (incluye los "sin actividad" al final).
    final filas = p.choferesParaRanking;
    for (var r = 0; r < filas.length; r++) {
      final c = filas[r];
      final row = r + 1;
      _setNum(hoja, 0, row, c.icm);
      _setTxt(hoja, 1, row, c.severidadLabel);
      _setTxt(hoja, 2, row, c.nombre);
      _setTxt(hoja, 3, row, c.dni);
      _setNum(hoja, 4, row, c.icmUrbano);
      _setNum(hoja, 5, row, c.icmNoUrbano);
      _setInt(hoja, 6, row, c.infAltas);
      _setInt(hoja, 7, row, c.infMedias);
      _setInt(hoja, 8, row, c.infLeves);
      _setInt(hoja, 9, row, c.excesosVelocidad);
      _setInt(hoja, 10, row, c.conduccionAgresiva);
      _setNum(hoja, 11, row, c.distanciaKm, style: _styleKm);
      _setNum(hoja, 12, row, c.tiempoH);
    }
    xu.autoFitColumnas(hoja, headers.length, filas.length + 1);
  }

  // ── Hoja 3: UNIDADES ───────────────────────────────────────────────
  static void _hojaUnidades(ex.Excel excel, IcmOficialPeriodo p) {
    final hoja = excel['UNIDADES'];
    const headers = [
      'ICM',
      'SEVERIDAD',
      'PATENTE',
      'ICM URBANO',
      'ICM NO URBANO',
      'INF. ALTAS',
      'INF. MEDIAS',
      'INF. LEVES',
      'DISTANCIA (KM)',
      'TIEMPO (H)',
    ];
    for (var i = 0; i < headers.length; i++) {
      _setHeader(hoja, i, 0, headers[i]);
    }
    for (var r = 0; r < p.vehiculos.length; r++) {
      final v = p.vehiculos[r];
      final row = r + 1;
      _setNum(hoja, 0, row, v.icm);
      _setTxt(hoja, 1, row, v.severidadLabel);
      _setTxt(hoja, 2, row, v.patente);
      _setNum(hoja, 3, row, v.icmUrbano);
      _setNum(hoja, 4, row, v.icmNoUrbano);
      _setInt(hoja, 5, row, v.infAltas);
      _setInt(hoja, 6, row, v.infMedias);
      _setInt(hoja, 7, row, v.infLeves);
      _setNum(hoja, 8, row, v.distanciaKm, style: _styleKm);
      _setNum(hoja, 9, row, v.tiempoH);
    }
    xu.autoFitColumnas(hoja, headers.length, p.vehiculos.length + 1);
  }
}
