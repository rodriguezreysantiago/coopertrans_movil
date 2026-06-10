import 'dart:math' as math;

import 'package:excel/excel.dart' as ex;

import '../../../shared/utils/formatters.dart';
import '../models/adelanto_chofer.dart';
import '../models/tarifa_logistica.dart';
import '../models/ubicacion_logistica.dart';
import '../models/viaje.dart';
import 'liquidacion_service.dart' show EmpleadoLiquidacion;

/// Generador de la "planilla de cuadernos" mensual — réplica del Excel
/// histórico (`VIAJES VC <MES> <AÑO>.xlsm`) con el que administración
/// liquidaba a los choferes antes de la app. Pedido Vecchi 2026-06-10:
/// poder extraer de la app un archivo con el MISMO formato que conocen.
///
/// Estructura del workbook que arma [construir]:
///   1. `RESUMEN` — tabla choferes × (BRUTO / ADELANTOS / GASTOS /
///      FINAL) con fórmulas vivas que referencian las hojas de cada
///      chofer + DNI y FACTURADO A EMPRESA (estos dos no existían en
///      la planilla vieja — los agrega la app).
///   2. Una hoja POR CHOFER con el layout cuaderno:
///        columnas A-C  → adelantos (fecha / N° recibo / $)
///        columnas D-Q  → viajes, una fila por TRAMO (fecha, RTO/CP,
///                        mercadería, origen/prov, destino/prov, kg,
///                        dif kg, tarifa, G/VIAJE, redondeado, gastos)
///        pie           → BRUTO − ADELANTOS + GASTOS = SUB-TOTAL,
///                        DESCUENTOS manuales, FINAL CUADERNOS,
///                        OTROS VIAJES y TOTAL.
///
/// **Fórmulas vivas, no valores congelados**: igual que la planilla
/// vieja, las celdas calculadas llevan fórmulas (`FLOOR`, `SUM`, …)
/// para que administración pueda retocar un kg o agregar una fila a
/// mano y el archivo siga cuadrando. La fórmula del monto del chofer
/// replica EXACTAMENTE la de la app (`CalculosViaje`):
///   - POR_TONELADA → `(K × tarifaChofer × pct%) / 1000` con la
///     tarifa chofer del snapshot en la columna M (en la planilla
///     vieja M llevaba "la tarifa" porque real y chofer eran la misma
///     base; acá va la chofer, que es la base real del cálculo).
///   - POR_VIAJE    → `tarifaChofer × pct%` (sin kg).
///   - Monto fijo   → valor flat (sin fórmula de %), como la app.
///   - Redondeo     → `FLOOR(monto, 5)` POR TRAMO, igual que
///     `redondearMultiploDe5Descendente` aplicado tramo a tramo
///     (decisión Santiago 2026-05-19) — la suma del pie cuadra con el
///     `montoChoferRedondeado` persistido.
///
/// Este archivo NO toca Firestore ni necesita BuildContext — recibe
/// todo en memoria para que los tests puedan generar y releer el
/// workbook completo. El wrapper con fetch + diálogo de guardado vive
/// en `report_liquidacion.dart`.
class ReportPlanillaChofer {
  ReportPlanillaChofer._();

  /// Comisión default cuando el viaje no trae un pct válido (mismo
  /// default operativo que `CalculosViaje.comisionChoferDefaultPct`).
  static const double _pctDefault = 18.0;

  /// Mínimo de filas de la grilla de datos (aunque el chofer tenga 2
  /// viajes) + margen extra sobre el máximo real. El aire deja lugar
  /// para agregar filas a mano — las fórmulas del pie cubren el rango
  /// completo, así que lo agregado suma solo.
  static const int _minFilasDatos = 12;
  static const int _margenFilasDatos = 3;

  // ─── Estilos base (Cambria, como la planilla original) ───────────

  static const String _font = 'Cambria';
  static final ex.ExcelColor _grisHeader = ex.ExcelColor.fromHexString(
    '#D9D9D9',
  );
  static const _numFmtMonto = ex.CustomNumericNumFormat(
    formatCode: r'[$-2C0A]#,##0',
  );

  static ex.Border get _thin => ex.Border(borderStyle: ex.BorderStyle.Thin);

  static ex.CellStyle _estilo({
    bool bold = false,
    int size = 8,
    bool borde = true,
    bool gris = false,
    bool monto = false,
    ex.HorizontalAlign align = ex.HorizontalAlign.Left,
  }) {
    return ex.CellStyle(
      fontFamily: _font,
      fontSize: size,
      bold: bold,
      horizontalAlign: align,
      backgroundColorHex: gris ? _grisHeader : ex.ExcelColor.none,
      leftBorder: borde ? _thin : null,
      rightBorder: borde ? _thin : null,
      topBorder: borde ? _thin : null,
      bottomBorder: borde ? _thin : null,
      numberFormat: monto ? _numFmtMonto : ex.NumFormat.standard_0,
    );
  }

  // ===================================================================
  // API
  // ===================================================================

  /// Construye el workbook completo. Devuelve el `Excel` + la lista de
  /// nombres de hoja por chofer (para que el caller las oculte por XML
  /// y arme el rango del dropdown de CONSULTA).
  ///
  /// Estructura (orden de pestañas): CONSULTA, [44 hojas chofer],
  /// RESUMEN, + los anexos que agrega el caller. Las hojas de chofer
  /// se ocultan post-save; quedan como fuente de datos del RESUMEN y
  /// del espejo INDIRECT de CONSULTA.
  ///
  /// [viajes] y [adelantos] vienen YA filtrados por la pantalla
  /// (mes + empresa empleadora + chofer + estado liquidación).
  static PlanillaWorkbook construir({
    required List<Viaje> viajes,
    required List<AdelantoChofer> adelantos,
    required Map<String, EmpleadoLiquidacion> empleados,
    required DateTime mes,
    required ResolverProvincias provincias,
  }) {
    final excel = ex.Excel.createExcel();
    // CONSULTA arranca como la 1ª hoja (Sheet1 renombrada). Se llena
    // al final, cuando ya tenemos los nombres de hoja de cada chofer.
    excel.rename('Sheet1', 'CONSULTA');

    // ─── Agrupar por chofer (unión de DNIs en viajes y adelantos) ───
    final viajesPorChofer = <String, List<Viaje>>{};
    for (final v in viajes) {
      viajesPorChofer.putIfAbsent(v.choferDni, () => []).add(v);
    }
    final adelantosPorChofer = <String, List<AdelantoChofer>>{};
    for (final a in adelantos) {
      adelantosPorChofer.putIfAbsent(a.choferDni, () => []).add(a);
    }

    String nombreDe(String dni) {
      final emp = empleados[dni]?.nombre;
      if (emp != null && emp.trim().isNotEmpty) return emp.trim();
      final deViaje = viajesPorChofer[dni]
          ?.map((v) => v.choferNombre)
          .whereType<String>()
          .firstOrNull;
      final deAdelanto = adelantosPorChofer[dni]
          ?.map((a) => a.choferNombre)
          .whereType<String>()
          .firstOrNull;
      return (deViaje ?? deAdelanto ?? 'DNI $dni').trim();
    }

    final dnis = <String>{
      ...viajesPorChofer.keys,
      ...adelantosPorChofer.keys,
    }.toList()
      ..sort((a, b) => nombreDe(a).compareTo(nombreDe(b)));

    // ─── Hojas cuaderno (una por chofer) ────────────────────────────
    final usados = <String>{'RESUMEN', 'VIAJES', 'ADELANTOS'};
    final metas = <_MetaHojaChofer>[];
    for (final dni in dnis) {
      final nombre = nombreDe(dni);
      final hoja = nombreHojaSeguro(nombre, usados);
      usados.add(hoja.toUpperCase());
      final vs = [...?viajesPorChofer[dni]]..sort(_compararViajes);
      final ads = [...?adelantosPorChofer[dni]]
        ..sort((a, b) => a.fecha.compareTo(b.fecha));
      final meta = _llenarHojaChofer(
        excel,
        nombreHoja: hoja,
        nombreChofer: nombre,
        dni: dni,
        mes: mes,
        viajes: vs,
        adelantos: ads,
        provincias: provincias,
      );
      metas.add(meta);
    }

    _llenarResumen(excel, mes: mes, metas: metas);

    // CONSULTA: dropdown + espejo del chofer elegido. Se llena al final
    // (necesita los nombres de hoja). El data validation y el ocultado
    // de hojas van por XML (caller → excel_utils).
    _construirHojaConsulta(excel, metas: metas, mes: mes);

    return PlanillaWorkbook(
      excel: excel,
      hojasChofer: metas.map((m) => m.nombreHoja).toList(),
      cantidadChoferes: metas.length,
    );
  }

  static int _compararViajes(Viaje a, Viaje b) {
    final fa = a.fechaReferencia;
    final fb = b.fechaReferencia;
    if (fa == null && fb == null) return 0;
    if (fa == null) return 1;
    if (fb == null) return -1;
    return fa.compareTo(fb);
  }

  // ===================================================================
  // HOJA RESUMEN
  // ===================================================================

  static void _llenarResumen(
    ex.Excel excel, {
    required DateTime mes,
    required List<_MetaHojaChofer> metas,
  }) {
    final hoja = excel['RESUMEN'];
    final mesStr = AppFormatters.formatearMes(mes).toUpperCase();

    hoja.merge(_ci(0, 0), _ci(6, 0));
    _set(hoja, 0, 0, ex.TextCellValue('RESUMEN CHOFERES — $mesStr'),
        _estilo(bold: true, size: 12, borde: false));

    const headers = [
      'CHOFER',
      'DNI',
      'BRUTO',
      'ADELANTOS',
      'GASTOS',
      'FINAL',
      'FACTURADO A EMPRESA',
    ];
    for (var c = 0; c < headers.length; c++) {
      _set(hoja, c, 1, ex.TextCellValue(headers[c]),
          _estilo(bold: true, gris: true, align: ex.HorizontalAlign.Center));
    }

    var r = 2; // 0-based → fila Excel 3
    for (final m in metas) {
      final f = r + 1; // fila Excel 1-based para fórmulas
      final ref = refHoja(m.nombreHoja);
      final fin = m.filaDatosFin;
      _set(hoja, 0, r, ex.TextCellValue(m.nombreChofer), _estilo());
      _set(hoja, 1, r, ex.TextCellValue(m.dni), _estilo());
      _set(hoja, 2, r, ex.FormulaCellValue('SUM($ref!P4:P$fin)'),
          _estilo(monto: true));
      _set(hoja, 3, r, ex.FormulaCellValue('SUM($ref!C4:C$fin)'),
          _estilo(monto: true));
      _set(hoja, 4, r, ex.FormulaCellValue('SUM($ref!Q4:Q$fin)'),
          _estilo(monto: true));
      _set(hoja, 5, r, ex.FormulaCellValue('C$f-D$f+E$f'),
          _estilo(bold: true, monto: true));
      _set(hoja, 6, r, ex.DoubleCellValue(m.facturado),
          _estilo(monto: true));
      r++;
    }

    // Fila TOTAL (solo si hay al menos un chofer — sin filas no hay
    // rango válido para las fórmulas).
    if (metas.isNotEmpty) {
      const primera = 3; // fila Excel de la primera fila de datos
      final ultima = r; // r quedó en la fila TOTAL (0-based) = última de datos 1-based
      _set(hoja, 0, r, ex.TextCellValue('TOTAL'),
          _estilo(bold: true, gris: true));
      _set(hoja, 1, r, ex.TextCellValue(''), _estilo(gris: true));
      for (var c = 2; c <= 6; c++) {
        final col = String.fromCharCode('A'.codeUnitAt(0) + c);
        _set(
            hoja,
            c,
            r,
            ex.FormulaCellValue('SUM($col$primera:$col$ultima)'),
            _estilo(bold: true, gris: true, monto: true));
      }
    }

    const anchos = [26.0, 11.0, 13.0, 13.0, 11.0, 13.0, 20.0];
    for (var c = 0; c < anchos.length; c++) {
      hoja.setColumnWidth(c, anchos[c]);
    }
  }

  // ===================================================================
  // HOJA CUADERNO DE UN CHOFER
  // ===================================================================

  static _MetaHojaChofer _llenarHojaChofer(
    ex.Excel excel, {
    required String nombreHoja,
    required String nombreChofer,
    required String dni,
    required DateTime mes,
    required List<Viaje> viajes,
    required List<AdelantoChofer> adelantos,
    required ResolverProvincias provincias,
  }) {
    final hoja = excel[nombreHoja];

    // ─── Fila 1: CORRESPONDE A MES | <MES> | AÑO | <AÑO> | CHOFER ───
    final mesNombre =
        AppFormatters.formatearMes(mes).split(' ').first.toUpperCase();
    final st1 = _estilo(bold: true, size: 12, borde: false);
    hoja.merge(_ci(0, 0), _ci(1, 0));
    _set(hoja, 0, 0, ex.TextCellValue('CORRESPONDE A MES'), st1);
    hoja.merge(_ci(2, 0), _ci(3, 0));
    _set(hoja, 2, 0, ex.TextCellValue(mesNombre),
        _estilo(bold: true, size: 12, borde: false,
            align: ex.HorizontalAlign.Center));
    _set(hoja, 4, 0, ex.TextCellValue('AÑO'), st1);
    _set(hoja, 5, 0, ex.IntCellValue(mes.year), st1);
    _set(hoja, 6, 0, ex.TextCellValue('CHOFER'), st1);
    hoja.merge(_ci(7, 0), _ci(16, 0));
    _set(hoja, 7, 0, ex.TextCellValue(nombreChofer), st1);

    // ─── Fila 3: headers de la grilla ───────────────────────────────
    const headers = [
      'FECHA', 'N° RECIBO', r'$', // adelantos
      'FECHA', 'RTO/CP', 'MERCADE.', 'ORIGEN', 'PROV.', 'DESTINO',
      'PROV.', 'KG', 'DIF /KG', 'TARIFA', '', 'G/VIAJE', 'G/VIAJE',
      'GASTOS',
    ];
    final stHeader =
        _estilo(bold: true, gris: true, align: ex.HorizontalAlign.Center);
    for (var c = 0; c < headers.length; c++) {
      _set(hoja, c, 2, ex.TextCellValue(headers[c]), stHeader);
    }

    // ─── Grilla de datos ────────────────────────────────────────────
    // Una fila por TRAMO (la planilla vieja era single-tramo: una fila
    // por viaje). Los adelantos van en paralelo en las columnas A-C.
    final filas = <({Viaje v, TramoViaje t})>[
      for (final v in viajes)
        for (final t in v.tramos) (v: v, t: t),
    ];
    final nDatos = math.max(
      _minFilasDatos,
      math.max(filas.length, adelantos.length) + _margenFilasDatos,
    );
    final filaDatosFin = 3 + nDatos; // última fila de datos (1-based)

    final stCelda = _estilo();
    final stMonto = _estilo(monto: true);
    final stMontoBold = _estilo(bold: true, monto: true);
    final stCentrado = _estilo(align: ex.HorizontalAlign.Center);

    var facturado = 0.0;
    for (var i = 0; i < nDatos; i++) {
      final r = 3 + i; // 0-based; fila Excel = r + 1
      final f = r + 1;

      // Columnas A-C: adelanto i (si hay).
      final ad = i < adelantos.length ? adelantos[i] : null;
      _set(
          hoja,
          0,
          r,
          ad == null
              ? null
              : ex.TextCellValue(AppFormatters.formatearFecha(ad.fecha)),
          stCentrado);
      _set(
          hoja,
          1,
          r,
          ad?.numeroRecibo == null
              ? null
              : ex.IntCellValue(ad!.numeroRecibo!),
          stCentrado);
      _set(hoja, 2, r, ad == null ? null : ex.DoubleCellValue(ad.monto),
          stMontoBold);

      // Columnas D-Q: tramo i (si hay).
      final fila = i < filas.length ? filas[i] : null;
      final t = fila?.t;
      final snap = t?.tarifaSnapshot;
      if (fila != null && fila.t == fila.v.tramos.first) {
        facturado += fila.v.montoVecchi;
      }

      _set(
          hoja,
          3,
          r,
          t?.fechaCarga == null
              ? null
              : ex.TextCellValue(AppFormatters.formatearFecha(t!.fechaCarga)),
          stCentrado);
      _set(
          hoja,
          4,
          r,
          (t?.remitoNumero?.trim().isNotEmpty ?? false)
              ? ex.TextCellValue(t!.remitoNumero!.trim())
              : null,
          stCentrado);
      final mercaderia = t?.producto ?? t?.descripcionCarga;
      _set(hoja, 5, r,
          mercaderia == null ? null : ex.TextCellValue(mercaderia), stCelda);
      _set(
          hoja,
          6,
          r,
          snap == null
              ? null
              : ex.TextCellValue(stripParentesis(snap.origenEtiqueta)),
          stCelda);
      final provO = t == null ? '' : provincias.origenDe(t);
      _set(hoja, 7, r, provO.isEmpty ? null : ex.TextCellValue(provO),
          stCentrado);
      _set(
          hoja,
          8,
          r,
          snap == null
              ? null
              : ex.TextCellValue(stripParentesis(snap.destinoEtiqueta)),
          stCelda);
      final provD = t == null ? '' : provincias.destinoDe(t);
      _set(hoja, 9, r, provD.isEmpty ? null : ex.TextCellValue(provD),
          stCentrado);

      // KG: lo que usa el cálculo (descargados con prioridad, cargados
      // como estimado en curso — misma regla que CalculosViaje).
      final kg = _kgEfectivo(t);
      _set(hoja, 10, r, kg == null ? null : ex.DoubleCellValue(kg), stMonto);
      final dif = _difKg(t);
      _set(hoja, 11, r, dif == null ? null : ex.DoubleCellValue(dif), stMonto);

      // TARIFA (M): la base del cálculo del chofer ($/TN o $/viaje).
      _set(
          hoja,
          12,
          r,
          snap == null ? null : ex.DoubleCellValue(snap.tarifaChofer),
          stMonto);
      _set(hoja, 13, r, null, stCelda); // N — vacía (layout histórico)

      // O (G/VIAJE) + P (redondeado): fórmulas vivas que replican
      // CalculosViaje (ver doc de la clase).
      final pct = _pctDe(fila?.v);
      final ex.CellValue oValue;
      if (snap == null) {
        // Fila vacía: fórmula estándar por tonelada, da 0 — igual que
        // la planilla vieja, lista para cargar un viaje a mano.
        oValue = ex.FormulaCellValue('(K$f*M$f*${_pctStr(_pctDefault)}%)/1000');
      } else if (snap.montoFijoChofer != null) {
        oValue = ex.DoubleCellValue(snap.montoFijoChofer!);
      } else if (snap.unidadTarifa == UnidadTarifa.porViaje) {
        oValue = ex.FormulaCellValue('M$f*${_pctStr(pct)}%');
      } else {
        oValue = ex.FormulaCellValue('(K$f*M$f*${_pctStr(pct)}%)/1000');
      }
      _set(hoja, 14, r, oValue, stMonto);
      _set(hoja, 15, r, ex.FormulaCellValue('FLOOR(O$f,5)'), stMontoBold);

      // Q: gastos del tramo.
      final gastos = t?.gastosTotal ?? 0;
      _set(hoja, 16, r, gastos == 0 ? null : ex.DoubleCellValue(gastos),
          stMonto);
    }

    _bloquePie(hoja, filaDatosFin: filaDatosFin);

    // ─── Anchos de columna (calibrados sobre la planilla original).
    // La M (TARIFA) va angosta pero visible — el archivo viejo la
    // escondía (ancho 0.1); acá la audiencia es la misma que ve las
    // tarifas en la app, y verla explica la fórmula de G/VIAJE. ───
    const anchos = [
      11.0, 9.0, 10.0, // A-C adelantos
      11.0, 9.5, 10.0, 16.0, 6.5, 16.0, 6.5, // D-J viaje
      7.5, 7.0, 6.0, 2.0, 11.0, 11.0, 9.0, // K-Q
    ];
    for (var c = 0; c < anchos.length; c++) {
      hoja.setColumnWidth(c, anchos[c]);
    }

    return _MetaHojaChofer(
      dni: dni,
      nombreChofer: nombreChofer,
      nombreHoja: nombreHoja,
      filaDatosFin: filaDatosFin,
      facturado: facturado,
    );
  }

  // ===================================================================
  // HOJA CONSULTA (dropdown + espejo INDIRECT)
  // ===================================================================

  /// Columna helper (0-based) donde van los nombres EXACTOS de hoja
  /// que alimentan el dropdown. Va a la derecha del cuaderno (Q=16) y
  /// se oculta por XML. El data validation referencia `S1:S{N}`.
  static const int _colListaChoferes = 18; // S

  /// Construye la hoja CONSULTA: un dropdown en H1 para elegir chofer
  /// y, debajo, su cuaderno completo ESPEJADO con fórmulas INDIRECT a
  /// la hoja del chofer elegido. Así administración no va hoja por hoja
  /// (pedido Santiago 2026-06-10) — las hojas por chofer quedan
  /// ocultas como fuente de datos.
  ///
  /// La grilla (A4:Q15) espeja celda a celda; el pie (BRUTO/ADELANTOS/
  /// …) se RECALCULA sobre la propia grilla espejada reusando
  /// [_bloquePie], así los totales cuadran sin más INDIRECT. El nombre
  /// del chofer (H1) es el único dato "vivo": lo elige el dropdown y
  /// todas las fórmulas INDIRECT lo referencian con `$H$1`.
  static void _construirHojaConsulta(
    ex.Excel excel, {
    required List<_MetaHojaChofer> metas,
    required DateTime mes,
  }) {
    final hoja = excel['CONSULTA'];

    if (metas.isEmpty) {
      _set(hoja, 0, 0, ex.TextCellValue('Sin datos para el período.'),
          _estilo(bold: true, size: 12, borde: false));
      return;
    }

    final mesNombre =
        AppFormatters.formatearMes(mes).split(' ').first.toUpperCase();
    final st1 = _estilo(bold: true, size: 12, borde: false);

    // ─── Fila 1: header con el dropdown en H1 ───────────────────────
    hoja.merge(_ci(0, 0), _ci(1, 0));
    _set(hoja, 0, 0, ex.TextCellValue('CORRESPONDE A MES'), st1);
    hoja.merge(_ci(2, 0), _ci(3, 0));
    _set(hoja, 2, 0, ex.TextCellValue(mesNombre),
        _estilo(bold: true, size: 12, borde: false,
            align: ex.HorizontalAlign.Center));
    _set(hoja, 4, 0, ex.TextCellValue('AÑO'), st1);
    _set(hoja, 5, 0, ex.IntCellValue(mes.year), st1);
    _set(hoja, 6, 0, ex.TextCellValue('CHOFER'), st1);
    // H1 = celda del dropdown. Valor inicial = primer chofer (para que
    // el INDIRECT resuelva al abrir). El data validation lo agrega el
    // caller por XML. Resaltada (gris + borde) para que se note que es
    // editable.
    hoja.merge(_ci(7, 0), _ci(16, 0));
    _set(hoja, 7, 0, ex.TextCellValue(metas.first.nombreHoja),
        _estilo(bold: true, size: 12, gris: true,
            align: ex.HorizontalAlign.Center));

    // ─── Fila 3: headers de columna (idénticos al cuaderno) ─────────
    const headers = [
      'FECHA', 'N° RECIBO', r'$',
      'FECHA', 'RTO/CP', 'MERCADE.', 'ORIGEN', 'PROV.', 'DESTINO',
      'PROV.', 'KG', 'DIF /KG', 'TARIFA', '', 'G/VIAJE', 'G/VIAJE',
      'GASTOS',
    ];
    final stHeader =
        _estilo(bold: true, gris: true, align: ex.HorizontalAlign.Center);
    for (var c = 0; c < headers.length; c++) {
      _set(hoja, c, 2, ex.TextCellValue(headers[c]), stHeader);
    }

    // ─── Grilla A4:Q15: espejo INDIRECT al chofer de H1 ─────────────
    // Cada celda: =IF(INDIRECT("'"&$H$1&"'!A4")=0,"",INDIRECT(...)).
    // El IF(=0,"") deja en blanco las filas sin datos (INDIRECT de
    // celda vacía devuelve 0); las fechas (texto) y montos (>0) se
    // muestran. 12 filas de grilla (4..15), 17 columnas (A..Q).
    const filaDatosFin = 15;
    for (var f = 4; f <= filaDatosFin; f++) {
      for (var c = 1; c <= 17; c++) {
        final ref = _refIndirect(_colLetra(c), f);
        final formula = 'IF(INDIRECT($ref)=0,"",INDIRECT($ref))';
        _set(hoja, c - 1, f - 1, ex.FormulaCellValue(formula),
            _estiloColGrilla(c));
      }
    }

    // ─── Pie: recalcula sobre la grilla espejada (reusa _bloquePie) ──
    _bloquePie(hoja, filaDatosFin: filaDatosFin);

    // ─── Anchos (mismos que el cuaderno) ────────────────────────────
    const anchos = [
      11.0, 9.0, 10.0,
      11.0, 9.5, 10.0, 16.0, 6.5, 16.0, 6.5,
      7.5, 7.0, 6.0, 2.0, 11.0, 11.0, 9.0,
    ];
    for (var c = 0; c < anchos.length; c++) {
      hoja.setColumnWidth(c, anchos[c]);
    }

    // ─── Columna helper S: nombres EXACTOS de hoja para el dropdown ──
    // Se oculta por XML. El data validation referencia S1:S{N}. Usar
    // los nombres de HOJA (no el nombre del RESUMEN) garantiza que el
    // INDIRECT resuelva aunque el nombre se haya saneado/recortado.
    for (var i = 0; i < metas.length; i++) {
      _set(hoja, _colListaChoferes, i, ex.TextCellValue(metas[i].nombreHoja),
          _estilo(borde: false));
    }
    // Ancho 0 → la columna helper queda invisible sin necesidad de
    // inyectar `hidden` en el XML. El dropdown la referencia igual (lee
    // los valores, no importa el ancho).
    hoja.setColumnWidth(_colListaChoferes, 0);
  }

  /// Letra de columna Excel para un índice 1-based (1→A … 17→Q). Solo
  /// cubre A-Z (suficiente para el cuaderno de 17 columnas).
  static String _colLetra(int col1based) =>
      String.fromCharCode('A'.codeUnitAt(0) + col1based - 1);

  /// Construye la referencia interna de INDIRECT a la celda
  /// `<colLetra><fila>` de la hoja nombrada en `$H$1`:
  ///   "'"&$H$1&"'!A4"
  /// (comillas simples porque los nombres de hoja llevan espacios).
  static String _refIndirect(String colLetra, int fila) =>
      '"\'"&\$H\$1&"\'!$colLetra$fila"';

  /// Estilo de cada columna de la grilla del cuaderno (1-based), igual
  /// que en [_llenarHojaChofer]: centrado para fechas/recibo/provincia,
  /// monto para importes, bold para los acumulables del chofer.
  static ex.CellStyle _estiloColGrilla(int c) {
    switch (c) {
      case 3: // C monto adelanto
      case 16: // P redondeado
        return _estilo(bold: true, monto: true);
      case 11: // K kg
      case 12: // L dif
      case 13: // M tarifa
      case 15: // O g/viaje
      case 17: // Q gastos
        return _estilo(monto: true);
      case 1: // A fecha adelanto
      case 2: // B recibo
      case 4: // D fecha viaje
      case 5: // E remito
      case 8: // H prov origen
      case 10: // J prov destino
        return _estilo(align: ex.HorizontalAlign.Center);
      default: // F G I N — texto
        return _estilo();
    }
  }

  /// Pie del cuaderno: OTROS VIAJES + LIQUIDACION PARCIAL con las
  /// mismas cuentas de la planilla histórica (fórmulas vivas):
  ///   BRUTO − ADELANTOS = NETO; NETO + GASTOS = SUB-TOTAL;
  ///   SUB-TOTAL − DESCUENTOS = FINAL CUADERNOS;
  ///   FINAL CUADERNOS + TOTAL OTROS VIAJES = TOTAL.
  static void _bloquePie(ex.Sheet hoja, {required int filaDatosFin}) {
    final stLabel = _estilo(bold: true, size: 10, borde: false);
    final stLabelGris =
        _estilo(bold: true, gris: true, align: ex.HorizontalAlign.Center);
    final stValor = _estilo(size: 14, monto: true);
    final stValorBold = _estilo(bold: true, size: 14, monto: true);
    final stInput = _estilo(monto: true);

    // OTROS VIAJES — slots manuales para viajes fuera del esquema.
    final rOtros = filaDatosFin + 1; // 1-based; índice 0-based = rOtros - 1
    hoja.merge(_ci(0, rOtros - 1), _ci(16, rOtros - 1));
    _set(hoja, 0, rOtros - 1, ex.TextCellValue('OTROS VIAJES'), stLabelGris);
    final ovIni = rOtros + 1;
    final ovFin = rOtros + 6;
    for (var f = ovIni; f <= ovFin; f++) {
      hoja.merge(_ci(3, f - 1), _ci(10, f - 1)); // D:K descripción
      _set(hoja, 3, f - 1, null, _estilo());
      hoja.merge(_ci(15, f - 1), _ci(16, f - 1)); // P:Q monto
      _set(hoja, 15, f - 1, null, stInput);
    }

    // LIQUIDACION PARCIAL — banner.
    final rBanner = ovFin + 2;
    hoja.merge(_ci(0, rBanner - 1), _ci(16, rBanner));
    _set(hoja, 0, rBanner - 1, ex.TextCellValue('LIQUIDACION PARCIAL'),
        stLabelGris);

    final fBruto = rBanner + 3;
    final fAdel = fBruto + 2;
    final fNeto = fAdel + 2;
    final fGastos = fNeto + 2;
    final fSubt = fGastos + 2;
    final fDesc = fSubt + 2; // label DESCUENTOS / TOTAL
    final dIni = fDesc + 1;
    final dFin = fDesc + 5; // 5 slots de descuentos manuales

    void labelYValor(int f, String label, String formula,
        {bool bold = false}) {
      _set(hoja, 0, f - 1, ex.TextCellValue(label), stLabel);
      hoja.merge(_ci(2, f - 1), _ci(3, f - 1));
      _set(hoja, 2, f - 1, ex.FormulaCellValue(formula),
          bold ? stValorBold : stValor);
    }

    labelYValor(fBruto, 'BRUTO', 'SUM(P4:P$filaDatosFin)', bold: true);
    labelYValor(fAdel, 'ADELANTOS', 'SUM(C4:C$filaDatosFin)', bold: true);
    labelYValor(fNeto, 'NETO', 'C$fBruto-C$fAdel', bold: true);
    labelYValor(fGastos, 'GASTOS', 'SUM(Q4:Q$filaDatosFin)', bold: true);
    labelYValor(fSubt, 'SUB-TOTAL', 'C$fNeto+C$fGastos', bold: true);

    // Descuentos manuales: monto en C:D + concepto libre en E:F.
    _set(hoja, 0, fDesc - 1, ex.TextCellValue('DESCUENTOS'), stLabel);
    for (var f = dIni; f <= dFin; f++) {
      hoja.merge(_ci(2, f - 1), _ci(3, f - 1));
      _set(hoja, 2, f - 1, null, stInput);
      hoja.merge(_ci(4, f - 1), _ci(5, f - 1));
      _set(hoja, 4, f - 1, null, _estilo());
    }

    // Columna derecha: FINAL CUADERNOS / TOTAL OTROS VIAJES / TOTAL.
    void labelDerecha(int f, String label) {
      hoja.merge(_ci(6, f - 1), _ci(16, f - 1));
      _set(hoja, 6, f - 1, ex.TextCellValue(label), stLabelGris);
    }

    void valorDerecha(int fIni, int fFin, String formula,
        {bool bold = false}) {
      hoja.merge(_ci(6, fIni - 1), _ci(16, fFin - 1));
      _set(
          hoja,
          6,
          fIni - 1,
          ex.FormulaCellValue(formula),
          (bold ? stValorBold : stValor)
              .copyWith(horizontalAlignVal: ex.HorizontalAlign.Center));
    }

    labelDerecha(fBruto, 'FINAL CUADERNOS');
    valorDerecha(fBruto + 1, fBruto + 2, 'C$fSubt-SUM(C$dIni:C$dFin)');
    labelDerecha(fNeto, 'TOTAL OTROS VIAJES');
    valorDerecha(fNeto + 1, fNeto + 2, 'SUM(P$ovIni:Q$ovFin)');
    labelDerecha(fDesc, 'TOTAL');
    valorDerecha(
      fDesc + 1,
      fDesc + 3,
      'G${fBruto + 1}+G${fNeto + 1}',
      bold: true,
    );
  }

  // ===================================================================
  // HELPERS (públicos para tests)
  // ===================================================================

  /// KG que alimenta el cálculo: descargados si están (> 0), sino
  /// cargados como estimado. Misma regla que `CalculosViaje`.
  static double? _kgEfectivo(TramoViaje? t) {
    if (t == null) return null;
    final desc = t.kgDescargados;
    if (desc != null && desc > 0) return desc;
    return t.kgCargados;
  }

  /// DIF/KG = cargados − descargados (faltante en destino). Solo si
  /// ambos kg existen y la diferencia no es cero.
  static double? _difKg(TramoViaje? t) {
    final c = t?.kgCargados;
    final d = t?.kgDescargados;
    if (c == null || d == null) return null;
    final dif = c - d;
    return dif == 0 ? null : dif;
  }

  /// Pct de comisión del viaje. Si el viaje reporta 0 (todos los
  /// tramos con monto fijo) las filas con fórmula no existen, pero por
  /// robustez devolvemos el default.
  static double _pctDe(Viaje? v) {
    final pct = v?.comisionChoferPct ?? _pctDefault;
    return pct > 0 ? pct : _pctDefault;
  }

  /// Formatea el pct para la fórmula: `18` → "18", `17.5` → "17.5".
  static String _pctStr(double pct) {
    return pct == pct.roundToDouble()
        ? pct.round().toString()
        : pct.toString();
  }

  /// Saca cualquier "(...)" de una etiqueta de ubicación — la versión
  /// compacta que usaba la planilla vieja ("B.BLANCA", no "BAHIA
  /// BLANCA - PROFERTIL (BAHIA BLANCA)"). Mismo helper que
  /// `TarifaSnapshot._stripParentesis` (privado allá).
  static String stripParentesis(String s) => s
      .replaceAll(RegExp(r'\s*\([^)]*\)\s*'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Nombre válido y único de hoja Excel: sin `[ ] : * ? / \ '`,
  /// máximo 31 chars, no vacío, sin repetir (case-insensitive contra
  /// [usados]). Colisiones → sufijo " (2)", " (3)", …
  static String nombreHojaSeguro(String nombre, Set<String> usados) {
    var base = nombre.replaceAll(RegExp(r"[\[\]:*?/\\']"), ' ').trim();
    base = base.replaceAll(RegExp(r'\s+'), ' ');
    if (base.isEmpty) base = 'CHOFER';
    if (base.length > 31) base = base.substring(0, 31).trim();
    final upperUsados = usados.map((u) => u.toUpperCase()).toSet();
    if (!upperUsados.contains(base.toUpperCase())) return base;
    for (var i = 2;; i++) {
      final sufijo = ' ($i)';
      final corte = math.min(base.length, 31 - sufijo.length);
      final candidato = '${base.substring(0, corte).trim()}$sufijo';
      if (!upperUsados.contains(candidato.toUpperCase())) return candidato;
    }
  }

  /// Referencia de hoja para fórmulas cross-sheet: siempre entre
  /// comillas simples (los nombres llevan espacios), escapando `'`.
  static String refHoja(String nombreHoja) {
    return "'${nombreHoja.replaceAll("'", "''")}'";
  }

  static ex.CellIndex _ci(int col, int row) =>
      ex.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row);

  static void _set(
    ex.Sheet hoja,
    int col,
    int row,
    ex.CellValue? value,
    ex.CellStyle style,
  ) {
    final cell = hoja.cell(_ci(col, row));
    if (value != null) cell.value = value;
    cell.cellStyle = style;
  }
}

/// Resultado de [ReportPlanillaChofer.construir]: el workbook + la
/// metadata que el caller necesita para el post-procesado XML (ocultar
/// las hojas de chofer y armar el dropdown de CONSULTA).
class PlanillaWorkbook {
  final ex.Excel excel;

  /// Nombres EXACTOS de las hojas por chofer (a ocultar por XML).
  final List<String> hojasChofer;

  /// Cantidad de choferes = filas de la lista del dropdown (`S1:S{N}`).
  final int cantidadChoferes;

  const PlanillaWorkbook({
    required this.excel,
    required this.hojasChofer,
    required this.cantidadChoferes,
  });
}

/// Metadata de una hoja cuaderno ya generada — la necesita el RESUMEN
/// para armar las fórmulas cross-sheet con los rangos correctos.
class _MetaHojaChofer {
  final String dni;
  final String nombreChofer;
  final String nombreHoja;

  /// Última fila (1-based) de la grilla de datos — fin de los rangos
  /// `SUM(P4:P{filaDatosFin})` etc.
  final int filaDatosFin;

  /// Σ `montoVecchi` de los viajes del chofer (valor de la app — el
  /// cuaderno no tiene celda de facturación, así que va como número).
  final double facturado;

  const _MetaHojaChofer({
    required this.dni,
    required this.nombreChofer,
    required this.nombreHoja,
    required this.filaDatosFin,
    required this.facturado,
  });
}

/// Resuelve la provincia de origen/destino de un tramo. El
/// `TarifaSnapshot` del tramo NO guarda provincia (solo etiquetas),
/// así que el dato sale de los catálogos:
///   1. `tarifaId` del tramo → tarifa del catálogo → `ubicacion*Id`
///      → ubicación → provincia. (Camino normal.)
///   2. Si la tarifa ya no existe (eliminada — los viajes históricos
///      siguen funcionando por snapshot): match de la etiqueta del
///      snapshot contra los nombres de ubicación del catálogo.
///   3. Sin match → string vacío (la columna PROV. queda en blanco;
///      el resto de la planilla no se ve afectado).
///
/// Las provincias se abrevian al estilo de la planilla vieja
/// ("BS.AS", "STA FE", "NQN") vía [abreviarProvincia].
class ResolverProvincias {
  final Map<String, ({String origen, String destino})> _porTarifa;
  final Map<String, String> _porNombreUbicacion;

  ResolverProvincias._(this._porTarifa, this._porNombreUbicacion);

  /// Resolver sin catálogos — todas las provincias salen vacías. Para
  /// cuando el fetch de catálogos falla (offline) o en tests.
  factory ResolverProvincias.vacio() => ResolverProvincias._({}, {});

  factory ResolverProvincias({
    required List<TarifaLogistica> tarifas,
    required List<UbicacionLogistica> ubicaciones,
  }) {
    final provPorUbicacionId = <String, String>{};
    final porNombre = <String, String>{};
    for (final u in ubicaciones) {
      final prov = abreviarProvincia(u.provincia);
      provPorUbicacionId[u.id] = prov;
      final clave = _normalizar(u.nombre);
      if (clave.isNotEmpty) porNombre[clave] = prov;
    }
    final porTarifa = <String, ({String origen, String destino})>{};
    for (final t in tarifas) {
      porTarifa[t.id] = (
        origen: provPorUbicacionId[t.ubicacionOrigenId] ?? '',
        destino: provPorUbicacionId[t.ubicacionDestinoId] ?? '',
      );
    }
    return ResolverProvincias._(porTarifa, porNombre);
  }

  String origenDe(TramoViaje t) =>
      _porTarifa[t.tarifaId]?.origen ??
      _porEtiqueta(t.tarifaSnapshot.origenEtiqueta);

  String destinoDe(TramoViaje t) =>
      _porTarifa[t.tarifaId]?.destino ??
      _porEtiqueta(t.tarifaSnapshot.destinoEtiqueta);

  String _porEtiqueta(String etiqueta) {
    final clave =
        _normalizar(ReportPlanillaChofer.stripParentesis(etiqueta));
    return _porNombreUbicacion[clave] ?? '';
  }

  static String _normalizar(String s) =>
      s.toUpperCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Abreviatura de provincia argentina al estilo de la planilla
  /// histórica. Robusto a la data sucia de la app: las ubicaciones
  /// cargan la provincia de formas inconsistentes ("Buenos Aires",
  /// "Provincia de Buenos Aires", "Provincia del Neuquén", …). Saca el
  /// prefijo "Provincia de/del/de la" antes de buscar, y si aún así no
  /// matchea, intenta por contención de un nombre conocido. Provincia
  /// desconocida → title-case recortado (no el crudo con prefijo, que
  /// daba el feo "Provinci" — bug detectado en el export 2026-06-10).
  static String abreviarProvincia(String provincia) {
    final p = provincia.trim();
    if (p.isEmpty) return '';
    var clave = _sinAcentos(_normalizar(p));
    // Sacar SOLO el prefijo "PROVINCIA DEL / DE " — NUNCA "DE LA",
    // porque "La Pampa" y "La Rioja" llevan el "La" como parte del
    // nombre ("Provincia de La Pampa" → "LA PAMPA", no "PAMPA"). "DEL"
    // antes que "DE " para no dejar la "L" colgada.
    clave = clave
        .replaceFirst(RegExp(r'^PROVINCIA DEL '), '')
        .replaceFirst(RegExp(r'^PROVINCIA DE '), '')
        .trim();

    final abrev = _abrevsProvincia[clave];
    if (abrev != null) return abrev;

    // Red de seguridad: si la clave CONTIENE el nombre de una provincia
    // conocida (variantes raras tipo "NQN - NEUQUEN"), usar esa. Solo
    // nombres ≥ 5 chars para no disparar falsos positivos.
    for (final e in _abrevsProvincia.entries) {
      if (e.key.length >= 5 && clave.contains(e.key)) return e.value;
    }

    // Desconocida: title-case del nombre YA limpio (sin prefijo),
    // recortado a 10 — legible, no el "Provinci" crudo.
    final base = clave.isEmpty ? _sinAcentos(_normalizar(p)) : clave;
    final titled = _titleCase(base);
    return titled.length > 10 ? titled.substring(0, 10).trim() : titled;
  }

  static String _sinAcentos(String s) => s
      .replaceAll('Á', 'A')
      .replaceAll('É', 'E')
      .replaceAll('Í', 'I')
      .replaceAll('Ó', 'O')
      .replaceAll('Ú', 'U')
      .replaceAll('Ü', 'U');

  static String _titleCase(String s) => s
      .split(' ')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');

  /// Diccionario de abreviaturas. Las claves son nombres de provincia
  /// YA normalizados (upper, sin acentos) y SIN el prefijo "Provincia
  /// de" (que [abreviarProvincia] saca antes de buscar).
  static const Map<String, String> _abrevsProvincia = {
    'BUENOS AIRES': 'BS.AS',
    'BS AS': 'BS.AS',
    'BS.AS': 'BS.AS',
    'BSAS': 'BS.AS',
    'CABA': 'CABA',
    'CIUDAD AUTONOMA DE BUENOS AIRES': 'CABA',
    'CIUDAD DE BUENOS AIRES': 'CABA',
    'CAPITAL FEDERAL': 'CABA',
    'SANTA FE': 'STA FE',
    'CORDOBA': 'CBA',
    'LA PAMPA': 'LA PAMPA',
    'RIO NEGRO': 'RIO NEG.',
    'NEUQUEN': 'NQN',
    'CHUBUT': 'CHUBUT',
    'MENDOZA': 'MZA',
    'SAN LUIS': 'S.LUIS',
    'SAN JUAN': 'S.JUAN',
    'ENTRE RIOS': 'E.RIOS',
    'CORRIENTES': 'CTES',
    'MISIONES': 'MNES',
    'CHACO': 'CHACO',
    'FORMOSA': 'FSA',
    'SANTIAGO DEL ESTERO': 'SGO EST.',
    'TUCUMAN': 'TUC',
    'SALTA': 'SALTA',
    'JUJUY': 'JUJUY',
    'CATAMARCA': 'CATA',
    'LA RIOJA': 'LA RIOJA',
    'SANTA CRUZ': 'STA CRUZ',
    'TIERRA DEL FUEGO': 'T.FUEGO',
  };
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
