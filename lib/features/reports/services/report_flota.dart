import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' as ex;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import 'excel_utils.dart' as xu;
import 'report_save_helper.dart';

/// Reporte de Estado de Flota (admin).
///
/// Vista general de TODA la flota — tractores y enganches —
/// orientada a gestión operativa: vencimientos próximos, estado de
/// servicio (solo tractores), chofer asignado, kilometraje. NO incluye
/// análisis de combustible (eso está en el reporte de Consumo).
///
/// Las celdas de vencimiento se colorean según urgencia:
/// - Rojo: vencido (días < 0)
/// - Naranja: vence en ≤ 7 días
/// - Amarillo: vence en ≤ 30 días
/// - Sin color: > 30 días o sin fecha cargada.
///
/// El estado de servicio combina dato de Volvo (si está disponible)
/// con el cálculo manual `(ULTIMO_SERVICE_KM + 50.000) - KM_ACTUAL`.
class ReportFlotaService {
  ReportFlotaService._();

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

    // Confirmación rápida — sin checkboxes (las columnas son fijas y
    // todas relevantes). El admin solo confirma "GENERAR".
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(dCtx).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withAlpha(20)),
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Reporte de Flota',
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 4),
            Text(
              'Estado actual: vencimientos, services y asignaciones',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        content: const Text(
          'El reporte incluye TODAS las unidades (tractores y enganches) '
          'con: tipo, modelo, empresa, KM actual, chofer asignado, '
          'vencimientos (RTO, seguro, extintores) y estado de service.\n\n'
          'Las celdas de vencimiento se colorean según urgencia.',
          style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5),
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
    await _ejecutarGeneracion(cacheVolvo: cacheVolvo, messenger: messenger);
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
            Text('Generando reporte de flota...'),
          ],
        ),
        backgroundColor: Colors.blueGrey,
      ),
    );
  }

  // ===========================================================================
  // GENERACIÓN
  // ===========================================================================

  static Future<void> _ejecutarGeneracion({
    required List<dynamic> cacheVolvo,
    required ScaffoldMessengerState messenger,
  }) async {
    try {
      final db = FirebaseFirestore.instance;

      // Map VIN → estado Volvo (para serviceDistance si lo da el API).
      final volvoMap = <String, dynamic>{
        for (final v in cacheVolvo)
          (v['vin']?.toString().toUpperCase() ?? ''): v,
      };

      // Cargar EMPLEADOS para mapear patente → chofer asignado.
      final empleadosSnap =
          await db.collection(AppCollections.empleados).get();
      final choferPorPatente = <String, String>{};
      for (final doc in empleadosSnap.docs) {
        final data = doc.data();
        // Soft-delete: empleados dados de baja no se mapean.
        if (!AppActivo.esActivo(data)) continue;
        // Solo CHOFER + MANEJO tienen vehículo asignado real.
        // SUPERVISOR/ADMIN/PLANTA pueden tener el campo VEHICULO con
        // basura legacy — lo ignoramos.
        final rol = (data['ROL'] ?? '').toString().toUpperCase();
        if (rol != AppRoles.chofer && rol != AppRoles.usuarioLegacy) {
          continue;
        }
        final nombre = _resolverNombreChofer(data);
        final veh = (data['VEHICULO'] ?? '').toString().trim().toUpperCase();
        final eng = (data['ENGANCHE'] ?? '').toString().trim().toUpperCase();
        if (veh.isNotEmpty && veh != '-') {
          choferPorPatente[veh] = nombre;
        }
        if (eng.isNotEmpty && eng != '-') {
          choferPorPatente[eng] = nombre;
        }
      }

      // Cargar VEHICULOS (todos los tipos). Soft-delete: las unidades
      // dadas de baja se excluyen del reporte (no aparecen ni siquiera
      // en la sección "todas las unidades" del Excel).
      final vehiculosSnap =
          await db.collection(AppCollections.vehiculos).get();
      final vehiculosActivos = vehiculosSnap.docs
          .where((d) => AppActivo.esActivo(d.data()))
          .toList();

      // Construir filas con la lógica de cada vehículo.
      final filas = vehiculosActivos.map((doc) {
        final patente = doc.id;
        final data = doc.data();
        final vin = (data['VIN'] ?? '').toString().trim().toUpperCase();
        final volvoData = vin.isEmpty ? null : volvoMap[vin];
        return _FilaFlota.from(
          patente: patente,
          data: data,
          volvoData: volvoData,
          choferAsignado: choferPorPatente[patente.toUpperCase()],
        );
      }).toList()
        // Ordenamos: tractores primero, después enganches; dentro de
        // cada grupo alfabético por patente. Más fácil de leer.
        ..sort((a, b) {
          final tipoA = a.tipo == AppTiposVehiculo.tractor ? 0 : 1;
          final tipoB = b.tipo == AppTiposVehiculo.tractor ? 0 : 1;
          if (tipoA != tipoB) return tipoA - tipoB;
          return a.patente.compareTo(b.patente);
        });

      final excel = ex.Excel.createExcel();
      excel.rename('Sheet1', 'FLOTA');
      final hoja = excel['FLOTA'];

      final headerStyle = ex.CellStyle(
        bold: true,
        backgroundColorHex: ex.ExcelColor.fromHexString('#1A3A5A'),
        fontColorHex: ex.ExcelColor.fromHexString('#FFFFFF'),
        horizontalAlign: ex.HorizontalAlign.Center,
      );
      final numStyle = ex.CellStyle(numberFormat: xu.formatoARSinDecimales);

      // Cabeceras en fila 0 — orden pensado para que el ojo recorra
      // primero identificación, después datos operativos.
      const titulos = [
        'PATENTE',
        'TIPO',
        'MODELO',
        'EMPRESA',
        'CHOFER ASIGNADO',
        'KM ACTUAL',
        'VENC. RTO',
        'VENC. SEGURO',
        'VENC. EXT. CABINA',
        'VENC. EXT. EXTERIOR',
        'ULTIMO SERVICE (FECHA)',
        'ULTIMO SERVICE (KM)',
        'PROX. SERVICE EN (KM)',
        'ESTADO SERVICE',
      ];
      for (var i = 0; i < titulos.length; i++) {
        final cell = hoja
            .cell(ex.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
        cell.value = ex.TextCellValue(titulos[i]);
        cell.cellStyle = headerStyle;
      }

      // Filas de datos.
      for (var i = 0; i < filas.length; i++) {
        final f = filas[i];
        final row = i + 1;
        var col = 0;

        _setText(hoja, col++, row, f.patente);
        _setText(hoja, col++, row, f.tipo);
        _setText(hoja, col++, row, f.modelo);
        _setText(hoja, col++, row, f.empresa);
        _setText(hoja, col++, row, f.choferAsignado ?? '-');

        // KM ACTUAL — solo tractores tienen este dato útil.
        if (f.kmActual != null) {
          final cell = hoja.cell(
              ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
          cell.value = ex.DoubleCellValue(f.kmActual!);
          cell.cellStyle = numStyle;
        } else {
          _setText(hoja, col, row, '-');
        }
        col++;

        // 4 vencimientos — color según urgencia.
        _setVencimiento(hoja, col++, row, f.vencRto);
        _setVencimiento(hoja, col++, row, f.vencSeguro);
        _setVencimiento(hoja, col++, row, f.vencExtCabina);
        _setVencimiento(hoja, col++, row, f.vencExtExterior);

        // Service — solo tractores.
        _setText(hoja, col++, row, f.ultimoServiceFecha ?? '-');
        if (f.ultimoServiceKm != null) {
          final cell = hoja.cell(
              ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
          cell.value = ex.DoubleCellValue(f.ultimoServiceKm!);
          cell.cellStyle = numStyle;
        } else {
          _setText(hoja, col, row, '-');
        }
        col++;
        if (f.proxServiceEnKm != null) {
          final cell = hoja.cell(
              ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
          cell.value = ex.DoubleCellValue(f.proxServiceEnKm!);
          cell.cellStyle = numStyle;
        } else {
          _setText(hoja, col, row, '-');
        }
        col++;
        _setEstadoService(hoja, col++, row, f.estadoService);
      }

      xu.autoFitColumnas(hoja, titulos.length, filas.length + 1);

      final fileBytes = excel.save();
      if (fileBytes != null) {
        final patched = xu.aplicarAutoFilterAlXlsx(fileBytes);
        await ReportSaveHelper.guardarYAbrir(
          bytes: patched,
          nombreDefault: ReportSaveHelper.nombreUnico('Flota'),
          messenger: messenger,
          textoCompartir: '🚛 Reporte de Flota — Coopertrans Móvil',
        );
      }
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo generar el reporte de flota. Probá de nuevo.',
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

  /// Escribe la fecha de vencimiento con coloreo según urgencia.
  /// Si la fecha no se puede parsear, se muestra el string crudo sin color.
  static void _setVencimiento(
    ex.Sheet hoja,
    int col,
    int row,
    String? fechaStr,
  ) {
    final cell = hoja
        .cell(ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    if (fechaStr == null || fechaStr.isEmpty || fechaStr == '-') {
      cell.value = ex.TextCellValue('-');
      return;
    }
    final fechaFormateada = AppFormatters.formatearFecha(fechaStr);
    cell.value = ex.TextCellValue(fechaFormateada);

    final dias = AppFormatters.calcularDiasRestantes(fechaStr);
    if (dias == null) return; // sin parseo válido, no coloreamos
    if (dias < 0) {
      // Vencido — rojo intenso.
      cell.cellStyle = _bgStyle('#D32F2F', textWhite: true);
    } else if (dias <= 7) {
      // Crítico — naranja.
      cell.cellStyle = _bgStyle('#EF6C00', textWhite: true);
    } else if (dias <= 30) {
      // Atención — amarillo.
      cell.cellStyle = _bgStyle('#FBC02D');
    }
    // > 30 días → sin color (default).
  }

  /// Escribe el estado de servicio con coloreo según severidad.
  /// Texto en mayúsculas tipo "VENCIDO" / "URGENTE" / etc.
  static void _setEstadoService(
    ex.Sheet hoja,
    int col,
    int row,
    MantenimientoEstado? estado,
  ) {
    final cell = hoja
        .cell(ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    if (estado == null || estado == MantenimientoEstado.sinDato) {
      cell.value = ex.TextCellValue('-');
      return;
    }
    cell.value = ex.TextCellValue(estado.etiqueta.toUpperCase());
    switch (estado) {
      case MantenimientoEstado.vencido:
        cell.cellStyle = _bgStyle('#D32F2F', textWhite: true);
        break;
      case MantenimientoEstado.urgente:
        cell.cellStyle = _bgStyle('#EF6C00', textWhite: true);
        break;
      case MantenimientoEstado.programar:
        cell.cellStyle = _bgStyle('#FBC02D');
        break;
      case MantenimientoEstado.atencion:
        cell.cellStyle = _bgStyle('#9CCC65');
        break;
      case MantenimientoEstado.ok:
      case MantenimientoEstado.sinDato:
        // sin color
        break;
    }
  }

  static ex.CellStyle _bgStyle(String hex, {bool textWhite = false}) {
    return ex.CellStyle(
      backgroundColorHex: ex.ExcelColor.fromHexString(hex),
      fontColorHex: textWhite
          ? ex.ExcelColor.fromHexString('#FFFFFF')
          : ex.ExcelColor.fromHexString('#000000'),
      bold: true,
    );
  }

  static String _resolverNombreChofer(Map<String, dynamic> data) {
    final apodo = (data['APODO'] ?? '').toString().trim();
    if (apodo.isNotEmpty) return apodo;
    final nombre = (data['NOMBRE'] ?? '').toString().trim();
    return nombre.isEmpty ? '-' : nombre;
  }
}

// =============================================================================
// MODELO INTERNO DE FILA
// =============================================================================

/// Datos consolidados de un vehículo para una fila del reporte.
/// Mezcla el doc de Firestore con datos de Volvo y empleados.
class _FilaFlota {
  final String patente;
  final String tipo;
  final String modelo;
  final String empresa;
  final String? choferAsignado;
  final double? kmActual;
  final String? vencRto;
  final String? vencSeguro;
  final String? vencExtCabina;
  final String? vencExtExterior;
  final String? ultimoServiceFecha;
  final double? ultimoServiceKm;
  final double? proxServiceEnKm;
  final MantenimientoEstado? estadoService;

  const _FilaFlota({
    required this.patente,
    required this.tipo,
    required this.modelo,
    required this.empresa,
    required this.choferAsignado,
    required this.kmActual,
    required this.vencRto,
    required this.vencSeguro,
    required this.vencExtCabina,
    required this.vencExtExterior,
    required this.ultimoServiceFecha,
    required this.ultimoServiceKm,
    required this.proxServiceEnKm,
    required this.estadoService,
  });

  factory _FilaFlota.from({
    required String patente,
    required Map<String, dynamic> data,
    required dynamic volvoData,
    required String? choferAsignado,
  }) {
    final tipo = (data['TIPO'] ?? '').toString();
    final esTractor = tipo.toUpperCase() == AppTiposVehiculo.tractor;
    final modelo = (data['MODELO'] ?? '').toString();
    final empresa = (data['EMPRESA'] ?? '').toString();

    // KM_ACTUAL — los enganches no lo tienen útil.
    double? kmActual;
    if (esTractor) {
      final raw = data['KM_ACTUAL'];
      if (raw != null) {
        final n = raw is num ? raw.toDouble() : double.tryParse(raw.toString());
        if (n != null && n > 0) kmActual = n;
      }
    }

    // Vencimientos: aplicables a ambos tipos para RTO/SEGURO; solo
    // tractores para los extintores (los enganches no llevan).
    final vencRto = _stringOrNull(data['VENCIMIENTO_RTO']);
    final vencSeguro = _stringOrNull(data['VENCIMIENTO_SEGURO']);
    final vencExtCabina = esTractor
        ? _stringOrNull(data['VENCIMIENTO_EXTINTOR_CABINA'])
        : null;
    final vencExtExterior = esTractor
        ? _stringOrNull(data['VENCIMIENTO_EXTINTOR_EXTERIOR'])
        : null;

    // Service — solo tractores. ULTIMO_SERVICE_FECHA es texto/fecha,
    // ULTIMO_SERVICE_KM es número.
    String? ultimoServiceFecha;
    double? ultimoServiceKm;
    double? proxServiceEnKm;
    MantenimientoEstado? estadoService;
    if (esTractor) {
      ultimoServiceFecha = _stringOrNull(data['ULTIMO_SERVICE_FECHA']);
      if (ultimoServiceFecha != null) {
        ultimoServiceFecha = AppFormatters.formatearFecha(ultimoServiceFecha);
      }
      final rawKm = data['ULTIMO_SERVICE_KM'];
      if (rawKm != null) {
        final n =
            rawKm is num ? rawKm.toDouble() : double.tryParse(rawKm.toString());
        if (n != null && n > 0) ultimoServiceKm = n;
      }

      // Próximo service: preferimos el cálculo manual
      // (ULTIMO_SERVICE_KM + 50.000 - KM_ACTUAL) cuando hay datos
      // cargados a mano. Fallback al `serviceDistance` del API Volvo
      // si no hay manual. Manual gana porque el paquete UPTIME no
      // está activo y a veces el API devuelve valores absurdos —
      // ver _resolverServiceDistance en admin_mantenimiento_widgets.
      proxServiceEnKm = AppMantenimiento.serviceDistanceDesdeManual(
        ultimoServiceKm: ultimoServiceKm,
        kmActual: kmActual,
      );
      if (proxServiceEnKm == null) {
        double? distanceMetros;
        if (volvoData is Map) {
          final uptime = volvoData['uptimeData'];
          if (uptime is Map) {
            final raw = uptime['serviceDistance'];
            if (raw is num) distanceMetros = raw.toDouble();
          }
        }
        if (distanceMetros != null) proxServiceEnKm = distanceMetros / 1000.0;
      }
      estadoService = AppMantenimiento.clasificar(proxServiceEnKm);
    }

    return _FilaFlota(
      patente: patente,
      tipo: tipo,
      modelo: modelo,
      empresa: empresa,
      choferAsignado: choferAsignado,
      kmActual: kmActual,
      vencRto: vencRto,
      vencSeguro: vencSeguro,
      vencExtCabina: vencExtCabina,
      vencExtExterior: vencExtExterior,
      ultimoServiceFecha: ultimoServiceFecha,
      ultimoServiceKm: ultimoServiceKm,
      proxServiceEnKm: proxServiceEnKm,
      estadoService: estadoService,
    );
  }

  static String? _stringOrNull(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    if (s.isEmpty || s == '-' || s == 'null' || s.toUpperCase() == 'NAN') {
      return null;
    }
    return s;
  }
}
