import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' as ex;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import 'excel_utils.dart' as xu;
import 'report_save_helper.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Reporte de Novedades (admin) — exporta solo respuestas REG y MAL
/// de los CHECKLISTS de los últimos 45 días.
///
/// Cada doc de CHECKLISTS contiene un mapa `RESPUESTAS` con los items
/// del checklist y su estado (BIEN / REG / MAL). Para no inundar el
/// reporte con todas las respuestas BIEN, exportamos solo las que
/// requieren atención (REG o MAL).
///
/// El reporte tiene UNA fila por cada item con problema (no una por
/// checklist). Eso permite filtrar/ordenar fácil por DOMINIO, ITEM o
/// ESTADO sin perder granularidad.
class ReportChecklistService {
  ReportChecklistService._();

  /// Cantidad de días de histórico a incluir en el reporte. Hardcoded
  /// como "freno de mano" anti-costos: traer 45 días con miles de
  /// docs de checklist es trivial; traer histórico completo (años)
  /// puede explotar el bill de Firestore.
  static const _diasHistorico = 45;

  static Future<void> mostrarOpcionesYGenerar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);

    if (kIsWeb) {
      AppFeedback.warningOn(messenger,
          'Los reportes Excel solo están disponibles en Windows y Android.');
      return;
    }

    // Confirmación rápida — sin checkboxes (las 7 columnas del
    // checklist son siempre necesarias para investigar la novedad).
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(dCtx).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withAlpha(20)),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Reporte de Novedades',
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Items con estado REG o MAL en los últimos $_diasHistorico días',
              style: AppType.eyebrow.copyWith(color: AppColors.warning),
            ),
          ],
        ),
        content: Text(
          'Cada fila es un item del checklist marcado como REG o MAL '
          'por un chofer en los últimos 45 días. Incluye fecha, '
          'patente, tipo de unidad, chofer, item, estado y observación.',
          style: AppType.label.copyWith(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('CANCELAR',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('GENERAR EXCEL'),
          ),
        ],
      ),
    );

    if (confirmar != true || !context.mounted) return;
    _notificarProgreso(messenger);
    await _ejecutarGeneracion(messenger);
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
            Text('Procesando datos de checklists...'),
          ],
        ),
        backgroundColor: Colors.blueGrey,
      ),
    );
  }

  // ===========================================================================
  // GENERACIÓN
  // ===========================================================================

  static Future<void> _ejecutarGeneracion(
      ScaffoldMessengerState messenger) async {
    try {
      // Filtro por fecha: traer solo los checklists recientes para
      // no descargar miles de docs históricos sin sentido.
      final limiteCarga =
          DateTime.now().subtract(const Duration(days: _diasHistorico));

      final snapshot = await FirebaseFirestore.instance
          .collection(AppCollections.checklists)
          .where('FECHA', isGreaterThan: Timestamp.fromDate(limiteCarga))
          .orderBy('FECHA', descending: true)
          .get();

      final excel = ex.Excel.createExcel();
      excel.rename('Sheet1', 'NOVEDADES');
      final hoja = excel['NOVEDADES'];

      final headerStyle = ex.CellStyle(
        bold: true,
        backgroundColorHex: ex.ExcelColor.fromHexString('#1A3A5A'),
        fontColorHex: ex.ExcelColor.fromHexString('#FFFFFF'),
        horizontalAlign: ex.HorizontalAlign.Center,
      );

      // Cabeceras en fila 0. Renombrado: DOMINIO → PATENTE para
      // consistencia con el resto del proyecto (toda la app usa
      // PATENTE; "DOMINIO" era terminología legal/RTA pero la oficina
      // habla de patentes).
      const titulos = [
        'FECHA',
        'PATENTE',
        'TIPO',
        'CHOFER',
        'ITEM',
        'ESTADO',
        'OBSERVACION',
      ];
      for (var i = 0; i < titulos.length; i++) {
        final cell = hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
        cell.value = ex.TextCellValue(titulos[i]);
        cell.cellStyle = headerStyle;
      }

      // Filas de datos: 1 por item con estado REG o MAL.
      var currentRow = 1;
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final Map respuestas = data['RESPUESTAS'] ?? {};
        final Map observaciones = data['OBSERVACIONES'] ?? {};

        var fechaStr = '-';
        if (data['FECHA'] != null) {
          fechaStr = AppFormatters.formatearFecha(
              (data['FECHA'] as Timestamp).toDate());
        }
        final patente = (data['DOMINIO'] ?? '').toString();
        final tipo = (data['TIPO'] ?? '').toString();
        final chofer = (data['NOMBRE'] ?? '').toString();

        respuestas.forEach((item, estado) {
          final estadoStr = estado.toString();
          if (estadoStr != 'REG' && estadoStr != 'MAL') return;

          final obs = (observaciones[item] ?? '').toString();
          _setText(hoja, 0, currentRow, fechaStr);
          _setText(hoja, 1, currentRow, patente);
          _setText(hoja, 2, currentRow, tipo);
          _setText(hoja, 3, currentRow, chofer);
          _setText(hoja, 4, currentRow, item.toString());
          _setEstado(hoja, 5, currentRow, estadoStr);
          _setText(hoja, 6, currentRow, obs);
          currentRow++;
        });
      }

      xu.autoFitColumnas(hoja, titulos.length, currentRow);

      final fileBytes = excel.save();
      if (fileBytes != null) {
        final patched = xu.aplicarAutoFilterAlXlsx(fileBytes);
        await ReportSaveHelper.guardarYAbrir(
          bytes: patched,
          nombreDefault: ReportSaveHelper.nombreUnico('Novedades'),
          messenger: messenger,
          textoCompartir: '📋 Reporte de Novedades — Coopertrans Móvil\n'
              'Generado el ${AppFormatters.formatearFechaHoraCorta(DateTime.now())}',
        );
      }
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo generar el reporte de checklists. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  // ===========================================================================
  // HELPERS DE CELDAS
  // ===========================================================================

  static void _setText(ex.Sheet hoja, int col, int row, String value) {
    hoja
        .cell(ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
        .value = ex.TextCellValue(value);
  }

  /// Estado coloreado: REG = naranja (atención), MAL = rojo (crítico).
  /// Hace evidente la severidad sin tener que leer la palabra.
  static void _setEstado(ex.Sheet hoja, int col, int row, String estado) {
    final cell = hoja
        .cell(ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    cell.value = ex.TextCellValue(estado);
    if (estado == 'MAL') {
      cell.cellStyle = ex.CellStyle(
        backgroundColorHex: ex.ExcelColor.fromHexString('#D32F2F'),
        fontColorHex: ex.ExcelColor.fromHexString('#FFFFFF'),
        bold: true,
      );
    } else if (estado == 'REG') {
      cell.cellStyle = ex.CellStyle(
        backgroundColorHex: ex.ExcelColor.fromHexString('#EF6C00'),
        fontColorHex: ex.ExcelColor.fromHexString('#FFFFFF'),
        bold: true,
      );
    }
  }
}
