import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' as ex;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import 'excel_utils.dart' as xu;
import 'report_save_helper.dart';

/// Reportes Excel del módulo Gomería. 3 informes:
///
/// 1. **Estado actual** — 1 fila por posición ocupada de toda la flota.
///    Snapshot de qué cubierta hay en cada posición de cada unidad,
///    con info de modelo, vida, km recorridos hasta hoy, última lectura
///    de presión/banda. Útil para inventario físico vs sistema.
///
/// 2. **Histórico de recapados** — 1 fila por evento (todos los envíos
///    a recapar, abiertos y cerrados). Permite calcular tasa de
///    recapado exitoso por proveedor, costo promedio, días en taller.
///
/// 3. **Costo por km por modelo** — agrupado por modelo, solo cubiertas
///    YA RETIRADAS (vida útil completa) y NO LEGACY (datos reales).
///    Permite responder "¿qué modelo me está dando mejor costo por km?".
///    En las primeras semanas/meses va a estar vacío hasta que la
///    cohort 2 (cubiertas reales reemplazando las legacy) acumule
///    suficientes retiros.
class ReportGomeriaService {
  ReportGomeriaService._();

  // ===========================================================================
  // ENTRY POINT — diálogo de selección de reporte
  // ===========================================================================

  static Future<void> mostrarOpcionesYGenerar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (kIsWeb) {
      AppFeedback.warningOn(messenger,
          'Los reportes Excel solo están disponibles en Windows y Android.');
      return;
    }

    final eleccion = await showDialog<_ReporteGomeria>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(dCtx).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withAlpha(20)),
        ),
        title: const Text(
          'Reporte de Gomería',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _OpcionTile(
              titulo: 'Estado actual de la flota',
              detalle:
                  '1 fila por posición ocupada. Patente, posición, '
                  'cubierta, modelo, vidas, km, última lectura.',
              onTap: () => Navigator.pop(dCtx, _ReporteGomeria.estadoFlota),
            ),
            const SizedBox(height: 8),
            _OpcionTile(
              titulo: 'Histórico de recapados',
              detalle:
                  '1 fila por envío a recapar. Cubierta, proveedor, '
                  'fechas, días en taller, costo, resultado.',
              onTap: () => Navigator.pop(dCtx, _ReporteGomeria.recapados),
            ),
            const SizedBox(height: 8),
            _OpcionTile(
              titulo: 'Costo por km por modelo',
              detalle:
                  'Solo cubiertas retiradas + no legacy. Compara qué '
                  'modelo rinde mejor por peso. Vacío hasta que entre '
                  'cohort 2 con vida útil completa.',
              onTap: () => Navigator.pop(dCtx, _ReporteGomeria.costoPorKm),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('CANCELAR',
                style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );

    if (eleccion == null || !context.mounted) return;
    _notificarProgreso(messenger);
    try {
      switch (eleccion) {
        case _ReporteGomeria.estadoFlota:
          await _generarEstadoFlota(messenger);
        case _ReporteGomeria.recapados:
          await _generarRecapados(messenger);
        case _ReporteGomeria.costoPorKm:
          await _generarCostoPorKm(messenger);
      }
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo generar el reporte de gomería. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
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
            Text('Generando reporte de gomería...'),
          ],
        ),
        backgroundColor: Colors.blueGrey,
      ),
    );
  }

  // ===========================================================================
  // 1. ESTADO ACTUAL DE LA FLOTA
  // ===========================================================================

  static Future<void> _generarEstadoFlota(
      ScaffoldMessengerState messenger) async {
    final db = FirebaseFirestore.instance;

    // Todas las instalaciones activas (hasta == null) = posiciones
    // ocupadas. Para flotas grandes esto puede traer 1000+ docs;
    // Firestore acepta hasta 30k por query — tenemos margen.
    final instSnap = await db
        .collection(AppCollections.cubiertasInstaladas)
        .where('hasta', isNull: true)
        .get();

    // Excluidos: tanques + tractores asociados. Los neumáticos de
    // esas unidades no los administramos.
    final excluidos = await ExcluidosService.cargar(db: db);

    // Cargar VEHICULOS y CUBIERTAS en bloque para joinear sin N+1.
    final vehicSnap = await db.collection(AppCollections.vehiculos).get();
    final vehiculos = <String, Map<String, dynamic>>{
      for (final d in vehicSnap.docs) d.id: d.data(),
    };

    final cubiertaIds = instSnap.docs
        .map((d) => (d.data()['cubierta_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    final cubiertas = <String, Map<String, dynamic>>{};
    // Firestore `whereIn` permite máximo 30 ids por query — paginamos.
    for (var i = 0; i < cubiertaIds.length; i += 30) {
      final chunk = cubiertaIds.skip(i).take(30).toList();
      final snap = await db
          .collection(AppCollections.cubiertas)
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      for (final d in snap.docs) {
        cubiertas[d.id] = d.data();
      }
    }

    final excel = ex.Excel.createExcel();
    excel.rename('Sheet1', 'ESTADO ACTUAL');
    final hoja = excel['ESTADO ACTUAL'];

    final headerStyle = ex.CellStyle(
      bold: true,
      backgroundColorHex: ex.ExcelColor.fromHexString('#1A3A5A'),
      fontColorHex: ex.ExcelColor.fromHexString('#FFFFFF'),
      horizontalAlign: ex.HorizontalAlign.Center,
    );
    final numStyle = ex.CellStyle(numberFormat: xu.formatoARSinDecimales);

    const titulos = [
      'PATENTE',
      'TIPO UNIDAD',
      'POSICION',
      'CUBIERTA',
      'MODELO',
      'TIPO USO',
      'VIDAS',
      'INSTALADA EL',
      'DIAS EN POSICION',
      'KM AL INSTALAR',
      'ULTIMA PRESION (PSI)',
      'ULTIMA BANDA (mm)',
      'LEGACY',
    ];
    for (var i = 0; i < titulos.length; i++) {
      final cell =
          hoja.cell(ex.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = ex.TextCellValue(titulos[i]);
      cell.cellStyle = headerStyle;
    }

    var row = 1;
    final ahora = DateTime.now();
    // Ordenar por patente para que el reporte sea legible al scrollear.
    final docsOrdenados = instSnap.docs.toList()
      ..sort((a, b) => (a.data()['unidad_id'] ?? '')
          .toString()
          .compareTo((b.data()['unidad_id'] ?? '').toString()));

    for (final d in docsOrdenados) {
      final inst = d.data();
      final patente = (inst['unidad_id'] ?? '').toString();
      // Skip cubiertas instaladas en unidades excluidas (tanqueros).
      if (ExcluidosService.esExcluido(excluidos, patente: patente)) {
        continue;
      }
      final unidad = vehiculos[patente] ?? const <String, dynamic>{};
      final cubierta = cubiertas[(inst['cubierta_id'] ?? '').toString()] ??
          const <String, dynamic>{};

      final desde = (inst['desde'] as Timestamp?)?.toDate();
      final dias =
          desde == null ? null : ahora.difference(desde).inDays;
      final kmInst = (inst['km_unidad_al_instalar'] as num?)?.toDouble();
      final presion = (inst['ultima_presion_psi'] as num?)?.toInt();
      final banda =
          (inst['ultima_profundidad_banda_mm'] as num?)?.toDouble();
      final esLegacy = (inst['legacy_inicial'] == true) ||
          (cubierta['legacy_inicial'] == true);

      final fila = [
        ex.TextCellValue(patente),
        ex.TextCellValue((unidad['TIPO'] ?? '—').toString()),
        ex.TextCellValue((inst['posicion'] ?? '').toString()),
        ex.TextCellValue((inst['cubierta_codigo'] ?? '').toString()),
        ex.TextCellValue((cubierta['modelo_etiqueta'] ??
                inst['modelo_etiqueta'] ??
                '—')
            .toString()),
        ex.TextCellValue((cubierta['tipo_uso'] ?? '—').toString()),
        ex.IntCellValue((cubierta['vidas'] as num?)?.toInt() ?? 0),
        ex.TextCellValue(
            desde == null ? '—' : AppFormatters.formatearFecha(desde)),
        dias == null ? ex.TextCellValue('—') : ex.IntCellValue(dias),
        kmInst == null
            ? ex.TextCellValue('—')
            : ex.DoubleCellValue(kmInst),
        presion == null ? ex.TextCellValue('—') : ex.IntCellValue(presion),
        banda == null ? ex.TextCellValue('—') : ex.DoubleCellValue(banda),
        ex.TextCellValue(esLegacy ? 'SI' : 'NO'),
      ];

      for (var c = 0; c < fila.length; c++) {
        final cell = hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row));
        cell.value = fila[c];
        // Aplicar formato AR a las columnas numéricas (km).
        if (c == 9 && kmInst != null) {
          cell.cellStyle = numStyle;
        }
      }
      row++;
    }

    xu.autoFitColumnas(hoja, titulos.length, row);
    await _guardarYAbrir(excel, 'Gomeria_EstadoActual', messenger);
  }

  // ===========================================================================
  // 2. HISTÓRICO DE RECAPADOS
  // ===========================================================================

  static Future<void> _generarRecapados(
      ScaffoldMessengerState messenger) async {
    final db = FirebaseFirestore.instance;
    final snap = await db
        .collection(AppCollections.cubiertasRecapados)
        .orderBy('fecha_envio', descending: true)
        .get();

    final excel = ex.Excel.createExcel();
    excel.rename('Sheet1', 'RECAPADOS');
    final hoja = excel['RECAPADOS'];

    final headerStyle = ex.CellStyle(
      bold: true,
      backgroundColorHex: ex.ExcelColor.fromHexString('#1A3A5A'),
      fontColorHex: ex.ExcelColor.fromHexString('#FFFFFF'),
      horizontalAlign: ex.HorizontalAlign.Center,
    );
    final montoStyle = ex.CellStyle(numberFormat: xu.formatoAR);

    const titulos = [
      'CUBIERTA',
      'VIDA RECAPADO',
      'PROVEEDOR',
      'FECHA ENVIO',
      'FECHA RETORNO',
      'DIAS EN TALLER',
      'COSTO',
      'RESULTADO',
      'NOTAS',
    ];
    for (var i = 0; i < titulos.length; i++) {
      final cell =
          hoja.cell(ex.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = ex.TextCellValue(titulos[i]);
      cell.cellStyle = headerStyle;
    }

    var row = 1;
    for (final d in snap.docs) {
      final r = d.data();
      final envio = (r['fecha_envio'] as Timestamp?)?.toDate();
      final retorno = (r['fecha_retorno'] as Timestamp?)?.toDate();
      final dias = (envio != null && retorno != null)
          ? retorno.difference(envio).inDays
          : null;
      final costo = (r['costo'] as num?)?.toDouble();

      final fila = [
        ex.TextCellValue((r['cubierta_codigo'] ?? '').toString()),
        ex.IntCellValue((r['vida_recapado'] as num?)?.toInt() ?? 0),
        ex.TextCellValue((r['proveedor'] ?? '').toString()),
        ex.TextCellValue(
            envio == null ? '—' : AppFormatters.formatearFecha(envio)),
        ex.TextCellValue(retorno == null
            ? 'EN PROCESO'
            : AppFormatters.formatearFecha(retorno)),
        dias == null ? ex.TextCellValue('—') : ex.IntCellValue(dias),
        costo == null ? ex.TextCellValue('—') : ex.DoubleCellValue(costo),
        ex.TextCellValue((r['resultado'] ?? '—').toString()),
        ex.TextCellValue((r['notas'] ?? '').toString()),
      ];

      for (var c = 0; c < fila.length; c++) {
        final cell = hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row));
        cell.value = fila[c];
        if (c == 6 && costo != null) {
          cell.cellStyle = montoStyle;
        }
      }
      row++;
    }

    xu.autoFitColumnas(hoja, titulos.length, row);
    await _guardarYAbrir(excel, 'Gomeria_Recapados', messenger);
  }

  // ===========================================================================
  // 3. COSTO POR KM POR MODELO
  // ===========================================================================
  //
  // Solo cubiertas RETIRADAS (vida útil completa, sino el costo por km
  // está sesgado bajo) y NO LEGACY (las legacy no tienen costo de
  // compra real ni km histórico). Agrupado por modelo. Costo total =
  // precio_compra + sum(costo de recapados de esa cubierta).

  static Future<void> _generarCostoPorKm(
      ScaffoldMessengerState messenger) async {
    final db = FirebaseFirestore.instance;

    // Todas las cubiertas no legacy. Filtramos en cliente porque
    // queremos las que estén estado != INSTALADA (es decir retiradas
    // del ciclo activo) y un legacy_inicial != true. Firestore no
    // permite múltiples queries OR sin armar N requests.
    final cubSnap =
        await db.collection(AppCollections.cubiertas).get();

    // ID → modelo_id, km_acumulados, precio_compra, vidas, modelo_etiqueta.
    final cubData = <String, Map<String, dynamic>>{};
    for (final d in cubSnap.docs) {
      final data = d.data();
      if (data['legacy_inicial'] == true) continue;
      // Estado de la cubierta:
      // - INSTALADA: aún en uso, sus km no son finales — excluida.
      // - EN_DEPOSITO / EN_RECAPADO / DESCARTADA: vida útil parcial o
      //   completa registrada.
      // Para el promedio "costo por km de vida útil" usamos solo
      // DESCARTADA (= ciclo cerrado). El resto se cuenta como
      // "en circulación".
      final estado = (data['estado'] ?? '').toString();
      if (estado != 'DESCARTADA') continue;
      cubData[d.id] = data;
    }

    // Sumar costos de recapado por cubierta.
    final costosRecapado = <String, double>{};
    if (cubData.isNotEmpty) {
      // No podemos hacer un único `whereIn` con > 30 ids — paginamos.
      final ids = cubData.keys.toList();
      for (var i = 0; i < ids.length; i += 30) {
        final chunk = ids.skip(i).take(30).toList();
        final snap = await db
            .collection(AppCollections.cubiertasRecapados)
            .where('cubierta_id', whereIn: chunk)
            .get();
        for (final d in snap.docs) {
          final data = d.data();
          final cid = (data['cubierta_id'] ?? '').toString();
          final costo = (data['costo'] as num?)?.toDouble();
          if (costo != null) {
            costosRecapado[cid] = (costosRecapado[cid] ?? 0) + costo;
          }
        }
      }
    }

    // Agrupar por modelo_id.
    final agrupado = <String, _AcumuladoModelo>{};
    for (final entry in cubData.entries) {
      final cubId = entry.key;
      final data = entry.value;
      final modeloId = (data['modelo_id'] ?? '').toString();
      if (modeloId.isEmpty) continue;
      final acc = agrupado.putIfAbsent(
        modeloId,
        () => _AcumuladoModelo(
          modeloEtiqueta: (data['modelo_etiqueta'] ?? '—').toString(),
          tipoUso: (data['tipo_uso'] ?? '—').toString(),
        ),
      );
      acc.cubiertasDescartadas++;
      acc.kmTotal += (data['km_acumulados'] as num?)?.toDouble() ?? 0;
      acc.costoCompraTotal +=
          (data['precio_compra'] as num?)?.toDouble() ?? 0;
      acc.costoRecapadosTotal += costosRecapado[cubId] ?? 0;
    }

    final excel = ex.Excel.createExcel();
    excel.rename('Sheet1', 'COSTO POR KM');
    final hoja = excel['COSTO POR KM'];

    final headerStyle = ex.CellStyle(
      bold: true,
      backgroundColorHex: ex.ExcelColor.fromHexString('#1A3A5A'),
      fontColorHex: ex.ExcelColor.fromHexString('#FFFFFF'),
      horizontalAlign: ex.HorizontalAlign.Center,
    );
    final montoStyle = ex.CellStyle(numberFormat: xu.formatoAR);
    final kmStyle = ex.CellStyle(numberFormat: xu.formatoARSinDecimales);

    const titulos = [
      'MODELO',
      'TIPO USO',
      'CUBIERTAS DESCARTADAS',
      'KM TOTAL',
      'COSTO COMPRA',
      'COSTO RECAPADOS',
      'COSTO TOTAL',
      'COSTO POR KM',
    ];
    for (var i = 0; i < titulos.length; i++) {
      final cell =
          hoja.cell(ex.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = ex.TextCellValue(titulos[i]);
      cell.cellStyle = headerStyle;
    }

    var row = 1;
    final ordenado = agrupado.entries.toList()
      ..sort((a, b) => a.value.modeloEtiqueta
          .compareTo(b.value.modeloEtiqueta));

    for (final entry in ordenado) {
      final acc = entry.value;
      final costoTotal = acc.costoCompraTotal + acc.costoRecapadosTotal;
      final costoPorKm = acc.kmTotal > 0 ? costoTotal / acc.kmTotal : null;

      final fila = [
        ex.TextCellValue(acc.modeloEtiqueta),
        ex.TextCellValue(acc.tipoUso),
        ex.IntCellValue(acc.cubiertasDescartadas),
        ex.DoubleCellValue(acc.kmTotal),
        ex.DoubleCellValue(acc.costoCompraTotal),
        ex.DoubleCellValue(acc.costoRecapadosTotal),
        ex.DoubleCellValue(costoTotal),
        costoPorKm == null
            ? ex.TextCellValue('—')
            : ex.DoubleCellValue(costoPorKm),
      ];

      for (var c = 0; c < fila.length; c++) {
        final cell = hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row));
        cell.value = fila[c];
        if (c == 3) cell.cellStyle = kmStyle;
        if (c >= 4 && c <= 7 && (c != 7 || costoPorKm != null)) {
          cell.cellStyle = montoStyle;
        }
      }
      row++;
    }

    xu.autoFitColumnas(hoja, titulos.length, row);
    await _guardarYAbrir(excel, 'Gomeria_CostoPorKm', messenger);
  }

  // ===========================================================================
  // GUARDAR + ABRIR
  // ===========================================================================

  static Future<void> _guardarYAbrir(
    ex.Excel excel,
    String prefijo,
    ScaffoldMessengerState messenger,
  ) async {
    final fileBytes = excel.save();
    if (fileBytes == null) return;
    final patched = xu.aplicarAutoFilterAlXlsx(fileBytes);
    await ReportSaveHelper.guardarYAbrir(
      bytes: patched,
      nombreDefault: ReportSaveHelper.nombreUnico(prefijo),
      messenger: messenger,
      textoCompartir: '$prefijo — Coopertrans Móvil',
    );
  }
}

// ===========================================================================
// HELPERS / TYPES
// ===========================================================================

enum _ReporteGomeria { estadoFlota, recapados, costoPorKm }

class _AcumuladoModelo {
  final String modeloEtiqueta;
  final String tipoUso;
  int cubiertasDescartadas = 0;
  double kmTotal = 0;
  double costoCompraTotal = 0;
  double costoRecapadosTotal = 0;

  _AcumuladoModelo({
    required this.modeloEtiqueta,
    required this.tipoUso,
  });
}

class _OpcionTile extends StatelessWidget {
  final String titulo;
  final String detalle;
  final VoidCallback onTap;

  const _OpcionTile({
    required this.titulo,
    required this.detalle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: AppColors.brandSoft.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.description_outlined,
                    size: 16, color: AppColors.brandSoft),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    titulo,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              detalle,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
