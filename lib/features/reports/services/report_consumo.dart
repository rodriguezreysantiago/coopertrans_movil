import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' as ex;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import 'excel_utils.dart' as xu;
import 'report_save_helper.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Reporte de Consumo de Combustible (admin).
///
/// Cruza la flota de Firestore con dos fuentes de telemetría:
///
/// - **`TELEMETRIA_HISTORICO`** (Firestore): snapshots diarios que el
///   AutoSync guarda al final de cada ciclo, con `litros_acumulados`
///   y `km` por unidad por día. Si el rango pedido cae dentro de los
///   días que ya tienen snapshot, el reporte calcula litros y KM
///   reales del **período** restando los snapshots de inicio y fin.
///
/// - **Cache Volvo en memoria** (`accumulatedData.totalFuelConsumption`):
///   fallback cuando para una unidad no hay snapshots todavía (recién
///   se trackea, o el día elegido es anterior al inicio del histórico).
///   En ese caso el reporte muestra el acumulado total del vehículo y
///   marca la fila con "S/D (acum.)" para que el admin sepa que ese
///   dato no es del período.
///
/// El Excel sale con dos hojas:
///
/// - **DETALLE**: tabla con todas las unidades, una columna por opción
///   marcada en el dialog.
/// - **RANKING**: top 10 unidades más consumidoras del período (filtra
///   las que no tienen datos del período válidos), con barra Unicode
///   proporcional al máximo. El package `excel` no soporta charts
///   nativos, así que el barra se renderiza con caracteres `█`.
class ReportConsumoService {
  ReportConsumoService._();

  /// Cache de la fecha mínima del histórico de telemetría. Se calcula
  /// la primera vez que se abre el dialog del reporte y queda en memoria
  /// por el resto de la sesión — la fecha del snapshot más viejo no
  /// cambia (el bot solo agrega snapshots nuevos, nunca borra los
  /// viejos en este horizonte). Si en el futuro se implementa retención
  /// automática de TELEMETRIA_HISTORICO, invalidar este cache.
  static DateTime? _fechaMinHistoricoCache;
  static Future<DateTime?>? _fechaMinHistoricoFuture;

  /// Devuelve la fecha del snapshot más antiguo en TELEMETRIA_HISTORICO,
  /// o `null` si la colección está vacía o el query falla. Cacheada por
  /// sesión.
  static Future<DateTime?> _fechaMinHistorico() {
    if (_fechaMinHistoricoCache != null) {
      return Future.value(_fechaMinHistoricoCache);
    }
    return _fechaMinHistoricoFuture ??= () async {
      try {
        final snap = await FirebaseFirestore.instance
            .collection(AppCollections.telemetriaHistorico)
            .orderBy('fecha', descending: false)
            .limit(1)
            .get();
        if (snap.docs.isEmpty) return null;
        final ts = snap.docs.first.data()['fecha'];
        if (ts is! Timestamp) return null;
        final fecha = ts.toDate();
        _fechaMinHistoricoCache = fecha;
        return fecha;
      } catch (_) {
        // Si el query falla (sin permisos, sin red), no romper el dialog.
        // El warning simplemente no aparece — comportamiento equivalente
        // al anterior a esta feature.
        return null;
      }
    }();
  }

  static Future<void> mostrarOpcionesYGenerar(
    BuildContext context,
    List<dynamic> cacheVolvo,
  ) async {
    final messenger = ScaffoldMessenger.of(context);

    if (kIsWeb) {
      AppFeedback.warningOn(messenger,
          'Los reportes Excel solo están disponibles en Windows y Android.');
      return;
    }

    // ============= 1) Rango de fechas (default: mes en curso) =============
    final hoy = DateTime.now();
    DateTime desde = DateTime(hoy.year, hoy.month, 1);
    DateTime hasta = hoy;

    // ============= 2) Columnas a incluir =============
    // Solo columnas relevantes para el análisis de combustible:
    // identificación (PATENTE, MODELO), métricas de consumo
    // (KM ACTUAL, LITROS TOTALES, PROMEDIO L/100KM) y estado de la
    // sincronización (ULTIMA SINCRONIZACION, ESTADO CONEXION).
    //
    // Excluidas — no afectan el cálculo:
    //   - TIPO: siempre TRACTOR (ya filtrado a nivel de query).
    //   - MARCA: siempre Volvo en esta flota.
    //   - VIN: identificador interno de Volvo, no aporta al análisis.
    //   - EMPRESA: info organizacional.
    //   - ESTADO CONEXION: el dato útil es la última sincronización
    //     (si está reciente = conectado), no un flag binario duplicado.
    final Map<String, bool> opciones = {
      "PATENTE": true,
      "MODELO": true,
      "LITROS": true,
      "KILOMETROS": true,
      "PROMEDIO": true,
      "ULTIMA SINCRONIZACION": true,
    };

    final confirmar = await _mostrarDialogoOpciones(
      context: context,
      desde: desde,
      hasta: hasta,
      opciones: opciones,
      onRangoCambiado: (d, h) {
        desde = d;
        hasta = h;
      },
    );

    if (confirmar != true || !context.mounted) return;

    _notificarProgreso(messenger);
    await _ejecutarGeneracion(
      desde: desde,
      hasta: hasta,
      filtros: opciones,
      cacheVolvo: cacheVolvo,
      messenger: messenger,
    );
  }

  /// Muestra el dialog de opciones (rango + columnas). Devuelve `true`
  /// si el admin confirmó "GENERAR".
  ///
  /// El dialog se mantiene como `StatefulBuilder` porque las dos fechas
  /// y los checkboxes se actualizan in-place — no queremos cerrar y
  /// reabrir el dialog para cambiar una fecha.
  static Future<bool?> _mostrarDialogoOpciones({
    required BuildContext context,
    required DateTime desde,
    required DateTime hasta,
    required Map<String, bool> opciones,
    required void Function(DateTime, DateTime) onRangoCambiado,
  }) {
    DateTime localDesde = desde;
    DateTime localHasta = hasta;

    return showDialog<bool>(
      context: context,
      builder: (dCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Theme.of(ctx).colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withAlpha(20)),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Reporte de Consumo",
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                "Litros y promedio L/100km por unidad",
                style: AppType.eyebrow.copyWith(color: Colors.white54),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _LabelSeccion('Rango de fechas'),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 4),
                  child: Text(
                    'Tocá el botón para abrir el calendario. '
                    'Marcá la fecha de inicio y después la de fin '
                    'en el mismo grid.',
                    style: AppType.eyebrow.copyWith(color: Colors.white70),
                  ),
                ),
                _BotonRangoFecha(
                  desde: localDesde,
                  hasta: localHasta,
                  onPick: (d, h) {
                    setDialogState(() {
                      localDesde = d;
                      localHasta = h;
                    });
                    onRangoCambiado(localDesde, localHasta);
                  },
                ),
                _WarningHistoricoLimitado(desdeSeleccionado: localDesde),
                const SizedBox(height: AppSpacing.sm),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Los litros y km del período se calculan a partir de '
                    'los snapshots diarios. Si una unidad todavía no '
                    'tiene snapshots dentro del rango, se reporta el '
                    'acumulado total marcado como "(acum.)".',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text("CANCELAR",
                  style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: const Text("GENERAR EXCEL"),
            ),
          ],
        ),
      ),
    );
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
            Text("Generando reporte de consumo..."),
          ],
        ),
        backgroundColor: Colors.blueGrey,
      ),
    );
  }

  // ===========================================================================
  // GENERACIÓN DEL EXCEL
  // ===========================================================================

  static Future<void> _ejecutarGeneracion({
    required DateTime desde,
    required DateTime hasta,
    required Map<String, bool> filtros,
    required List<dynamic> cacheVolvo,
    required ScaffoldMessengerState messenger,
  }) async {
    try {
      // Index Volvo por VIN para búsqueda O(1) por unidad de Firestore.
      final volvoMap = <String, dynamic>{
        for (final v in cacheVolvo)
          (v['vin']?.toString().toUpperCase() ?? ''): v,
      };

      final db = FirebaseFirestore.instance;

      // Snapshots históricos del rango ampliado.
      // Pedimos desde 30 días antes de `desde` para tener un buen
      // candidato como "inicio" (el AutoSync se ejecuta cada minuto
      // pero a veces hay días sin sync por feriados o caídas de Volvo).
      final desdeAmpliado = desde.subtract(const Duration(days: 30));
      final hastaAmpliado = hasta.add(const Duration(days: 1));
      final snapshotsHistoricos = await db
          .collection(AppCollections.telemetriaHistorico)
          .where('fecha',
              isGreaterThanOrEqualTo: Timestamp.fromDate(desdeAmpliado))
          .where('fecha',
              isLessThanOrEqualTo: Timestamp.fromDate(hastaAmpliado))
          .get();

      // Agrupamos los snapshots por patente, ordenados por fecha
      // ascendente. Después por cada unidad sacamos:
      //   - inicio = último snapshot con fecha <= desde
      //   - fin    = último snapshot con fecha <= hasta
      // Si solo hay uno, no podemos calcular diferencia (la unidad
      // arrancó tracking dentro del rango).
      final porPatente = <String, List<_Snapshot>>{};
      for (final doc in snapshotsHistoricos.docs) {
        final data = doc.data();
        final patente = (data['patente'] ?? '').toString();
        if (patente.isEmpty) continue;
        final ts = data['fecha'];
        if (ts is! Timestamp) continue;
        porPatente.putIfAbsent(patente, () => []).add(_Snapshot(
              fecha: ts.toDate(),
              litros: (data['litros_acumulados'] ?? 0).toDouble(),
              km: (data['km'] ?? 0).toDouble(),
            ));
      }
      for (final list in porPatente.values) {
        list.sort((a, b) => a.fecha.compareTo(b.fecha));
      }

      // Solo tractores: los enganches (BATEA, TOLVA, ACOPLADO, etc.)
      // no tienen motor, no tienen VIN cargado en la cuenta de Volvo
      // y siempre saldrían con "0 (acum.)" inflando el reporte con
      // ruido. El reporte de consumo es específico de unidades con
      // motor — los enganches se reportan en su propio reporte de
      // flota.
      final snapshot = await db
          .collection(AppCollections.vehiculos)
          .where('TIPO', isEqualTo: AppTiposVehiculo.tractor)
          .get();
      // Excluidos: tractores asignados a choferes tanqueros. No
      // consumimos combustible de unidades que no controlamos —
      // mezclarlos en el ranking distorsiona los promedios.
      final excluidos = await ExcluidosService.cargar(db: db);

      final excel = ex.Excel.createExcel();
      excel.rename('Sheet1', 'DETALLE');
      final hojaDetalle = excel['DETALLE'];

      final headerStyle = ex.CellStyle(
        bold: true,
        backgroundColorHex: ex.ExcelColor.fromHexString("#1A3A5A"),
        fontColorHex: ex.ExcelColor.fromHexString("#FFFFFF"),
        horizontalAlign: ex.HorizontalAlign.Center,
      );
      final numStyle = ex.CellStyle(numberFormat: xu.formatoAR);

      // Sin header informativo arriba — el admin aplica AutoFilter
      // (Ctrl+Shift+L) directamente sobre la fila 0 y filtra/ordena
      // como cualquier tabla. El rango se ve en el nombre del archivo.

      // Cabeceras dinámicas en fila 0 — datos desde fila 1.
      final titulos = <String>[];
      filtros.forEach((key, val) {
        if (val) titulos.add(key);
      });

      const filaCabecera = 0;
      const filaInicioDatos = 1;

      for (var i = 0; i < titulos.length; i++) {
        final cell = hojaDetalle.cell(ex.CellIndex.indexByColumnRow(
            columnIndex: i, rowIndex: filaCabecera));
        cell.value = ex.TextCellValue(titulos[i]);
        cell.cellStyle = headerStyle;
      }

      // ============= Filas de datos =============
      // Acumulamos también una lista intermedia para construir el Ranking
      // sin recorrer Firestore dos veces.
      final filas = <_FilaConsumo>[];
      var currentRow = filaInicioDatos;
      for (final doc in snapshot.docs) {
        final data = doc.data();
        // Soft-delete: vehiculos dados de baja se excluyen del reporte.
        if (!AppActivo.esActivo(data)) continue;
        // Excluidos: ver comentario arriba.
        if (ExcluidosService.esExcluido(excluidos, patente: doc.id)) continue;
        final patente = doc.id;
        final vin = (data['VIN'] ?? '').toString().trim().toUpperCase();
        final volvoData = volvoMap[vin];
        final fila = _FilaConsumo.from(
          patente: patente,
          data: data,
          volvoData: volvoData,
          historicos: porPatente[patente] ?? const [],
          desde: desde,
          hasta: hasta,
        );
        filas.add(fila);

        var col = 0;
        for (final titulo in titulos) {
          final cell = hojaDetalle.cell(ex.CellIndex.indexByColumnRow(
              columnIndex: col++, rowIndex: currentRow));
          _writeColumna(cell, titulo, fila, numStyle);
        }
        currentRow++;
      }

      xu.autoFitColumnas(hojaDetalle, titulos.length, currentRow);

      // ============= Hoja RANKING (top 10 más consumidores) =============
      _construirHojaRanking(excel, filas);

      // ============= Guardar y abrir =============
      final fileBytes = excel.save();
      if (fileBytes != null) {
        final patched = xu.aplicarAutoFilterAlXlsx(fileBytes);
        // Sufijo extra con el rango de fechas para reconocer reportes
        // de distintos períodos cuando hay varios en la carpeta.
        final rango = '${DateFormat('yyyyMMdd').format(desde)}_'
            '${DateFormat('yyyyMMdd').format(hasta)}';
        await ReportSaveHelper.guardarYAbrir(
          bytes: patched,
          nombreDefault: ReportSaveHelper.nombreUnico(
            'Consumo',
            sufijoExtra: rango,
          ),
          messenger: messenger,
          textoCompartir: '⛽ Reporte de consumo de combustible — '
              '${AppFormatters.formatearFecha(desde)} a ${AppFormatters.formatearFecha(hasta)}',
        );
      }
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo generar el reporte de consumo. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  /// Escribe el valor de una columna específica en la celda según el
  /// título lógico. Mantenemos esto en un switch separado para que sumar
  /// columnas nuevas sea agregar una rama y un key en `filtros`.
  static void _writeColumna(
    ex.Data cell,
    String titulo,
    _FilaConsumo f,
    ex.CellStyle numStyle,
  ) {
    switch (titulo) {
      case 'PATENTE':
        cell.value = ex.TextCellValue(f.patente);
        break;
      case 'MODELO':
        cell.value = ex.TextCellValue(f.modelo);
        break;
      case 'LITROS':
        if (f.esPeriodo) {
          // Redondeamos a 2 decimales — el API trae mililitros pero
          // un consumo del período se lee mejor en L.cc.
          cell.value = ex.DoubleCellValue(
              double.parse(f.litros.toStringAsFixed(2)));
          cell.cellStyle = numStyle;
        } else {
          cell.value =
              ex.TextCellValue('${f.litros.round()} (acum.)');
        }
        break;
      case 'KILOMETROS':
        if (f.esPeriodo) {
          // Redondeamos a 1 decimal — la API Volvo da km con precisión
          // de metros pero para un reporte humano alcanza con .x.
          cell.value = ex.DoubleCellValue(
              double.parse(f.km.toStringAsFixed(1)));
          cell.cellStyle = numStyle;
        } else {
          // Sin histórico no podemos saber km del período. Mostramos
          // el odómetro actual marcado para que el admin no lo cuente
          // como "km recorridos".
          cell.value = ex.TextCellValue('${f.km.round()} (acum.)');
        }
        break;
      case 'PROMEDIO':
        // L/100km — métrica estándar de eficiencia (cuanto más bajo,
        // mejor). Tractores cargados típicamente en 30-40.
        cell.value = ex.DoubleCellValue(
            double.parse(f.consumoLPor100Km.toStringAsFixed(2)));
        cell.cellStyle = numStyle;
        break;
      case 'ULTIMA SINCRONIZACION':
        cell.value = ex.TextCellValue(f.ultimaSync);
        break;
    }
  }

  /// Construye la hoja "RANKING" con TODA la flota ordenada por
  /// consumo L/100km (de peor a mejor — los más altos consumen más
  /// combustible cada 100 km, son los que conviene revisar primero).
  ///
  /// Para visualizar la magnitud sin un chart nativo, agregamos una
  /// columna "BARRA" con caracteres `█` proporcionales al peor caso
  /// (la unidad más ineficiente). Es el truco clásico de "in-cell bar
  /// chart" — funciona en cualquier Excel y en LibreOffice sin macros.
  static void _construirHojaRanking(
      ex.Excel excel, List<_FilaConsumo> filas) {
    final hoja = excel['RANKING'];

    final headerStyle = ex.CellStyle(
      bold: true,
      backgroundColorHex: ex.ExcelColor.fromHexString("#5A1A1A"),
      fontColorHex: ex.ExcelColor.fromHexString("#FFFFFF"),
      horizontalAlign: ex.HorizontalAlign.Center,
    );

    // Solo unidades con datos REALES del período (esPeriodo && km > 0).
    // Sin km no se puede calcular L/100km. Las que tienen solo
    // acumulado no compiten porque la métrica del período no aplica.
    // Ordenamos descendente por L/100km — los peores arriba.
    final ranking = filas
        .where((f) => f.esPeriodo && f.km > 0 && f.consumoLPor100Km > 0)
        .toList()
      ..sort((a, b) => b.consumoLPor100Km.compareTo(a.consumoLPor100Km));

    // Cabeceras en fila 0 (sin título de hoja arriba — más limpio
    // para aplicar AutoFilter directo). Orden de columnas numéricas:
    // LITROS, KILOMETROS, PROMEDIO (consistente con la hoja DETALLE).
    const titulos = [
      '#',
      'PATENTE',
      'MODELO',
      'LITROS',
      'KILOMETROS',
      'PROMEDIO',
      'BARRA'
    ];
    for (var i = 0; i < titulos.length; i++) {
      final cell = hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = ex.TextCellValue(titulos[i]);
      cell.cellStyle = headerStyle;
    }

    if (ranking.isEmpty) {
      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1))
          .value = ex.TextCellValue(
              'Sin snapshots históricos en el rango (todavía). El ranking '
              'aparece después de unos días de tracking activo.');
      return;
    }

    final maxConsumo = ranking.first.consumoLPor100Km;
    final numStyle = ex.CellStyle(numberFormat: xu.formatoAR);

    for (var i = 0; i < ranking.length; i++) {
      final f = ranking[i];
      final fila = i + 1;

      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: fila))
          .value = ex.IntCellValue(i + 1);
      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: fila))
          .value = ex.TextCellValue(f.patente);
      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: fila))
          .value = ex.TextCellValue(f.modelo);

      // Orden: LITROS (col 3), KILOMETROS (col 4), PROMEDIO (col 5).
      // Coincide con el orden en la hoja DETALLE para que el lector
      // recorra ambas hojas con la misma estructura mental.
      final litrosCell = hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: fila));
      litrosCell.value = ex.DoubleCellValue(
          double.parse(f.litros.toStringAsFixed(2)));
      litrosCell.cellStyle = numStyle;

      final kmCell = hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: fila));
      kmCell.value = ex.DoubleCellValue(
          double.parse(f.km.toStringAsFixed(1)));
      kmCell.cellStyle = numStyle;

      final consumoCell = hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: fila));
      consumoCell.value = ex.DoubleCellValue(
          double.parse(f.consumoLPor100Km.toStringAsFixed(2)));
      consumoCell.cellStyle = numStyle;

      // Barra unicode: ancho proporcional al peor consumo (más L/100km
      // = barra más larga). Hasta 30 caracteres.
      final ratio = maxConsumo == 0 ? 0.0 : f.consumoLPor100Km / maxConsumo;
      final ancho = (ratio * 30).round();
      final barra = '█' * ancho;
      hoja
          .cell(ex.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: fila))
          .value = ex.TextCellValue(barra);
    }

    xu.autoFitColumnas(hoja, titulos.length, ranking.length + 1);
  }
}

// =============================================================================
// MODELO INTERNO DE FILA
// =============================================================================

/// Snapshot histórico mínimo para los cálculos de período.
class _Snapshot {
  final DateTime fecha;
  final double litros;
  final double km;

  const _Snapshot({
    required this.fecha,
    required this.litros,
    required this.km,
  });
}

/// Tira en una sola estructura los datos de un vehículo + Volvo + el
/// período calculado desde los snapshots históricos.
class _FilaConsumo {
  final String patente;
  final String tipo;
  final String marca;
  final String modelo;
  final String vin;
  final String empresa;
  final double km;
  final double litros;

  /// Si `true`, los `litros` y `km` corresponden al período pedido
  /// (calculados como diferencia de snapshots). Si `false`, son el
  /// total acumulado del vehículo y el reporte los marca con
  /// "S/D (acum.)" para que el admin lo distinga.
  final bool esPeriodo;

  final String ultimaSync;
  final bool conectado;

  const _FilaConsumo({
    required this.patente,
    required this.tipo,
    required this.marca,
    required this.modelo,
    required this.vin,
    required this.empresa,
    required this.km,
    required this.litros,
    required this.esPeriodo,
    required this.ultimaSync,
    required this.conectado,
  });

  /// Consumo en L/100km — métrica estándar de flotas (cuántos litros
  /// se gastan cada 100 km). Cuanto más bajo, más eficiente. Tractores
  /// cargados típicamente caen en 30-40 L/100km.
  ///
  /// Devuelve 0 si km == 0 (vehículo parado, evita división por cero).
  double get consumoLPor100Km => km > 0 ? (litros / km) * 100.0 : 0.0;

  factory _FilaConsumo.from({
    required String patente,
    required Map<String, dynamic> data,
    required dynamic volvoData,
    required List<_Snapshot> historicos,
    required DateTime desde,
    required DateTime hasta,
  }) {
    // Default = acumulado (fallback). Si después detectamos que hay
    // suficiente histórico para calcular período real, lo reemplazamos.
    var km = (data['KM_ACTUAL'] ?? 0.0).toDouble();
    var litros = 0.0;
    var esPeriodo = false;

    if (volvoData != null && volvoData['accumulatedData'] != null) {
      litros = (volvoData['accumulatedData']['totalFuelConsumption'] ?? 0.0)
          .toDouble();
    }

    // Si hay al menos 2 snapshots (uno antes/igual a `desde` y otro
    // antes/igual a `hasta`), podemos calcular consumo del período.
    // Si solo hay uno, la unidad recién arrancó tracking y queda como
    // acumulado.
    if (historicos.isNotEmpty) {
      _Snapshot? inicio;
      _Snapshot? fin;
      for (final s in historicos) {
        if (!s.fecha.isAfter(desde)) inicio = s; // ≤ desde
        if (!s.fecha.isAfter(hasta)) fin = s; // ≤ hasta
      }
      // Si no hay snapshot anterior a `desde`, tomamos el primero
      // disponible como inicio (la unidad arrancó dentro del rango).
      // Eso da un consumo "casi del período" pero conviene marcarlo.
      inicio ??= historicos.first;
      if (fin != null && fin.fecha.isAfter(inicio.fecha)) {
        final litrosPeriodo = (fin.litros - inicio.litros)
            .clamp(0.0, double.infinity)
            .toDouble();
        final kmPeriodo =
            (fin.km - inicio.km).clamp(0.0, double.infinity).toDouble();
        // El ÚNICO caso que NO marcamos como período es km=0 CON litros>0
        // (el odómetro retrocedió, p.ej. corrección Volvo): el promedio
        // L/100km = (litros/km)*100 mostraría "0 km / X L / promedio 0", que
        // no reconcilia con sus propias columnas (es un reporte de auditoría)
        // → cae al fallback "(acum.)". El vehículo genuinamente parado
        // (sábado/feriado/taller) tiene km=0 Y litros=0: ESO sí es un período
        // válido 0/0 (reportarlo como acumulado histórico sería misleading,
        // decisión previa que se conserva).
        if (kmPeriodo > 0 || litrosPeriodo <= 0) {
          litros = litrosPeriodo;
          km = kmPeriodo;
          esPeriodo = true;
        }
      }
    }

    var ultimaSync = '-';
    if (volvoData != null) {
      // El endpoint /vehiclestatuses (que usamos via traerEstadosFlota)
      // devuelve `createdDateTime` (cuando el vehículo generó el dato)
      // y `receivedDateTime` (cuando llegó al server Volvo). Preferimos
      // createdDateTime que es lo más cercano a "cuándo se midió esto".
      // Fallback a triggerTimestamp/samplingTime por si algún caso
      // todavía pasa data del endpoint legacy /vehicles.
      final ts = (volvoData['createdDateTime'] ??
              volvoData['receivedDateTime'] ??
              volvoData['triggerTimestamp'] ??
              volvoData['samplingTime'] ??
              '')
          .toString();
      if (ts.isNotEmpty) {
        final dt = DateTime.tryParse(ts);
        if (dt != null) {
          ultimaSync = AppFormatters.formatearFechaHoraCorta(dt);
        }
      }
    }

    return _FilaConsumo(
      patente: patente,
      tipo: (data['TIPO'] ?? '').toString(),
      marca: (data['MARCA'] ?? '').toString(),
      modelo: (data['MODELO'] ?? '').toString(),
      vin: (data['VIN'] ?? '').toString().toUpperCase(),
      empresa: (data['EMPRESA'] ?? '').toString(),
      km: km,
      litros: litros,
      esPeriodo: esPeriodo,
      ultimaSync: ultimaSync,
      conectado: volvoData != null,
    );
  }
}

// =============================================================================
// COMPONENTES DEL DIALOG
// =============================================================================

class _LabelSeccion extends StatelessWidget {
  final String texto;
  const _LabelSeccion(this.texto);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        texto.toUpperCase(),
        style: const TextStyle(
          color: AppColors.success,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.3,
        ),
      ),
    );
  }
}

/// Un solo botón que abre `showDateRangePicker` de Material —
/// calendario unificado donde el admin marca primero la fecha de
/// inicio y después la de fin en el mismo flow. UX mejor que dos
/// pickers separados porque ve los dos extremos del rango en el
/// mismo calendario.
class _BotonRangoFecha extends StatelessWidget {
  final DateTime desde;
  final DateTime hasta;
  final void Function(DateTime desde, DateTime hasta) onPick;

  const _BotonRangoFecha({
    required this.desde,
    required this.hasta,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () async {
        final hoy = DateTime.now();
        // showDateRangePicker: en Windows abre full-screen con scroll
        // vertical de meses (Santiago lo prefiere así). El admin marca
        // un día como inicio y otro como fin en el mismo calendario,
        // y los días intermedios se resaltan automáticamente.
        final picked = await showDateRangePicker(
          context: context,
          initialDateRange: DateTimeRange(start: desde, end: hasta),
          firstDate: DateTime(hoy.year - 2, 1, 1),
          lastDate: hoy.add(const Duration(days: 1)),
          locale: const Locale('es', 'AR'),
          initialEntryMode: DatePickerEntryMode.calendar,
          helpText: 'Seleccioná el rango del reporte',
          saveText: 'CONFIRMAR',
          cancelText: 'CANCELAR',
          fieldStartLabelText: 'Desde',
          fieldEndLabelText: 'Hasta',
        );
        if (picked != null) onPick(picked.start, picked.end);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.success.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: AppColors.success.withAlpha(120), width: 1.5),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.date_range,
              color: AppColors.success,
              size: 26,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'RANGO DE FECHAS',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '${AppFormatters.formatearFecha(desde)}  a  ${AppFormatters.formatearFecha(hasta)}',
                    style: const TextStyle(
                      color: AppColors.success,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.edit_calendar,
              color: Colors.white54,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}

/// Banner de advertencia que aparece SOLO si la fecha "desde"
/// seleccionada en el dialog es ANTERIOR al snapshot más antiguo de
/// `TELEMETRIA_HISTORICO`. Sin esto, el reporte recortaba silencioso
/// los días sin data y confundía al admin (mostraba "958 km en un mes"
/// cuando en realidad solo había 4 días de histórico).
///
/// FutureBuilder cacheado: el lookup de la fecha mínima se hace una
/// sola vez por sesión (ver `ReportConsumoService._fechaMinHistorico`).
class _WarningHistoricoLimitado extends StatelessWidget {
  final DateTime desdeSeleccionado;

  const _WarningHistoricoLimitado({required this.desdeSeleccionado});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DateTime?>(
      future: ReportConsumoService._fechaMinHistorico(),
      builder: (ctx, snap) {
        // Sin data o cargando → no mostrar nada (silencioso para no
        // ensuciar el dialog mientras carga).
        if (!snap.hasData || snap.data == null) {
          return const SizedBox.shrink();
        }
        final fechaMin = snap.data!;
        // Si el "desde" elegido es posterior o igual al snapshot más
        // viejo, no hay nada que advertir.
        if (!desdeSeleccionado.isBefore(fechaMin)) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.warning.withAlpha(30),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: AppColors.warning.withAlpha(120)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline,
                    color: AppColors.warning, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'El histórico de telemetría arranca el ${AppFormatters.formatearFecha(fechaMin)}. '
                    'Los días anteriores al ${AppFormatters.formatearFecha(fechaMin)} no van a tener '
                    'data en el reporte (se reportan como "(acum.)" o vacíos).',
                    style: AppType.eyebrow.copyWith(color: AppColors.warning, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
