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

  /// Mínimo de filas de la grilla principal (viajes CONCLUIDOS +
  /// adelantos) + margen. Bajos a propósito (Santiago 2026-06-10:
  /// "demasiado espacio vacío") — las fórmulas del pie cubren el rango
  /// entero, así que agregar a mano sigue sumando.
  static const int _minFilasDatos = 6;
  static const int _margenFilasDatos = 1;

  /// Ídem para la sección OTROS VIAJES (EN_CURSO + PLANEADOS) — la
  /// "especulación" de fin de mes (Santiago 2026-06-10: se cargan
  /// viajes que se cree que se van a hacer, para que contabilidad
  /// proyecte los pagos). Más chica porque suele tener pocos.
  static const int _minFilasOtros = 3;
  static const int _margenFilasOtros = 1;

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
    Set<String> dnisPadron = const {},
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

    // Universo de hojas: el PADRÓN completo (todos los choferes activos
    // que pasan el filtro de empresa/chofer) ∪ los que tienen actividad.
    // Pedido Santiago 2026-06-10: que aparezcan TODOS los choferes —
    // los sin viajes/adelantos quedan con hoja vacía, lista para cargar
    // la especulación de fin de mes (como el archivo viejo). La unión
    // cubre el caso raro de un viaje con un DNI fuera del padrón.
    final dnis = <String>{
      ...dnisPadron,
      ...viajesPorChofer.keys,
      ...adelantosPorChofer.keys,
    }.toList()
      ..sort((a, b) => nombreDe(a).compareTo(nombreDe(b)));

    // Tamaños de grilla UNIFORMES entre todas las hojas — necesario
    // para que el espejo INDIRECT de CONSULTA sea consistente (su pie
    // nunca pisa el de otra hoja). Dos bloques:
    //   - principal: viajes CONCLUIDOS vs adelantos (el que tenga más).
    //   - otros: viajes EN_CURSO + PLANEADOS (la especulación).
    var maxPrincipal = 0;
    var maxOtros = 0;
    for (final dni in dnis) {
      final vs = viajesPorChofer[dni] ?? const <Viaje>[];
      final filasConcluidos = vs
          .where(_esConcluido)
          .fold<int>(0, (s, v) => s + v.tramos.length);
      final filasOtros = vs
          .where((v) => !_esConcluido(v))
          .fold<int>(0, (s, v) => s + v.tramos.length);
      final nAdel = (adelantosPorChofer[dni] ?? const []).length;
      maxPrincipal =
          math.max(maxPrincipal, math.max(filasConcluidos, nAdel));
      maxOtros = math.max(maxOtros, filasOtros);
    }
    final nDatos = math.max(_minFilasDatos, maxPrincipal + _margenFilasDatos);
    final nOtros = math.max(_minFilasOtros, maxOtros + _margenFilasOtros);

    // ─── Hojas cuaderno (una por chofer) ────────────────────────────
    final usados = <String>{'RESUMEN', 'VIAJES', 'ADELANTOS', 'CONSULTA'};
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
        nDatos: nDatos,
        nOtros: nOtros,
      );
      metas.add(meta);
    }

    _llenarResumen(excel, mes: mes, metas: metas);

    // CONSULTA: dropdown + espejo del chofer elegido. Se llena al final
    // (necesita los nombres de hoja). El data validation y el ocultado
    // de hojas van por XML (caller → excel_utils).
    _construirHojaConsulta(
        excel, metas: metas, mes: mes, nDatos: nDatos, nOtros: nOtros);

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

    _setMerged(hoja, 0, 0, 8, 0,
        ex.TextCellValue('RESUMEN CHOFERES — $mesStr'),
        _estilo(bold: true, size: 12, borde: false));

    // FINAL = firme (concluidos). OTROS VIAJES = especulación (en
    // curso/planeados). TOTAL EST. = lo que se proyecta pagar si se
    // concretan (Santiago 2026-06-10).
    const headers = [
      'CHOFER',
      'DNI',
      'BRUTO',
      'ADELANTOS',
      'GASTOS',
      'FINAL',
      'OTROS VIAJES',
      'TOTAL EST.',
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
      // BRUTO = ganancia concluidos (col P), GASTOS = col Q (tras intercalar
      // F.DESC/KM en el cuaderno).
      _set(hoja, 2, r, ex.FormulaCellValue('SUM($ref!P4:P$fin)'),
          _estilo(monto: true));
      _set(hoja, 3, r, ex.FormulaCellValue('SUM($ref!C4:C$fin)'),
          _estilo(monto: true));
      _set(hoja, 4, r, ex.FormulaCellValue('SUM($ref!Q4:Q$fin)'),
          _estilo(monto: true));
      _set(hoja, 5, r, ex.FormulaCellValue('C$f-D$f+E$f'),
          _estilo(bold: true, monto: true));
      // OTROS VIAJES = ganancia de en curso/planeados (especulación).
      _set(hoja, 6, r,
          ex.FormulaCellValue('SUM($ref!P${m.filaOtrosIni}:P${m.filaOtrosFin})'),
          _estilo(monto: true));
      _set(hoja, 7, r, ex.FormulaCellValue('F$f+G$f'),
          _estilo(bold: true, monto: true));
      _set(hoja, 8, r, ex.DoubleCellValue(m.facturado), _estilo(monto: true));
      r++;
    }

    // Fila TOTAL (solo si hay al menos un chofer).
    if (metas.isNotEmpty) {
      const primera = 3;
      final ultima = r; // r quedó en la fila TOTAL (1-based)
      _set(hoja, 0, r, ex.TextCellValue('TOTAL'),
          _estilo(bold: true, gris: true));
      _set(hoja, 1, r, ex.TextCellValue(''), _estilo(gris: true));
      for (var c = 2; c <= 8; c++) {
        final col = String.fromCharCode('A'.codeUnitAt(0) + c);
        _set(hoja, c, r,
            ex.FormulaCellValue('SUM($col$primera:$col$ultima)'),
            _estilo(bold: true, gris: true, monto: true));
      }
    }

    const anchos = [
      26.0, 11.0, 13.0, 12.0, 11.0, 13.0, 13.0, 13.0, 18.0,
    ];
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
    required int nDatos,
    required int nOtros,
  }) {
    final hoja = excel[nombreHoja];

    // Header (fila 1) + súper-header (fila 2) + headers de columna
    // (fila 3) compartidos con CONSULTA.
    _dibujarEncabezado(hoja, mes: mes, chofer: ex.TextCellValue(nombreChofer));

    // ─── Separar por estado ─────────────────────────────────────────
    // CONCLUIDOS arriba (lo firme); EN_CURSO + PLANEADOS abajo en OTROS
    // VIAJES (la especulación de fin de mes). Una fila por TRAMO.
    final concluidos = <({Viaje v, TramoViaje t})>[
      for (final v in viajes)
        if (_esConcluido(v))
          for (final t in v.tramos) (v: v, t: t),
    ];
    final otros = <({Viaje v, TramoViaje t})>[
      for (final v in viajes)
        if (!_esConcluido(v))
          for (final t in v.tramos) (v: v, t: t),
    ];

    final filaDatosFin = 3 + nDatos; // última fila de la grilla principal

    // ─── Grilla principal: concluidos (D-O) + adelantos (A-C) ───────
    var facturado = 0.0;
    for (var i = 0; i < nDatos; i++) {
      final r = 3 + i; // 0-based
      _setFilaAdelanto(hoja, r, i < adelantos.length ? adelantos[i] : null);
      final fila = i < concluidos.length ? concluidos[i] : null;
      if (fila != null && fila.t == fila.v.tramos.first) {
        facturado += fila.v.montoVecchi;
      }
      _setFilaViaje(hoja, r, fila, provincias);
    }

    // ─── Sección OTROS VIAJES (EN CURSO / PLANEADOS) ────────────────
    final filaOtrosTit = filaDatosFin + 2; // 1 fila de aire; 1-based
    final filaOtrosIni = filaOtrosTit + 1;
    final filaOtrosFin = filaOtrosTit + nOtros;
    _setMerged(hoja, 0, filaOtrosTit - 1, 16, filaOtrosTit - 1,
        ex.TextCellValue('OTROS VIAJES (EN CURSO / PLANEADOS)'),
        _estilo(bold: true, gris: true, align: ex.HorizontalAlign.Center));
    final stMontoBold = _estilo(bold: true, monto: true);
    final stCentrado = _estilo(align: ex.HorizontalAlign.Center);
    for (var i = 0; i < nOtros; i++) {
      final r = filaOtrosIni - 1 + i; // 0-based
      // A-C vacías (bordeadas) — los adelantos viven solo arriba.
      _set(hoja, 0, r, null, stCentrado);
      _set(hoja, 1, r, null, stCentrado);
      _set(hoja, 2, r, null, stMontoBold);
      _setFilaViaje(hoja, r, i < otros.length ? otros[i] : null, provincias);
    }

    _bloquePie(hoja,
        filaDatosFin: filaDatosFin,
        filaOtrosIni: filaOtrosIni,
        filaOtrosFin: filaOtrosFin);
    _aplicarAnchos(hoja);

    return _MetaHojaChofer(
      dni: dni,
      nombreChofer: nombreChofer,
      nombreHoja: nombreHoja,
      filaDatosFin: filaDatosFin,
      filaOtrosIni: filaOtrosIni,
      filaOtrosFin: filaOtrosFin,
      facturado: facturado,
    );
  }

  /// `true` si el viaje cuenta como FIRME (concluido) → grilla
  /// principal. El resto (en curso, planeado) va a OTROS VIAJES.
  static bool _esConcluido(Viaje v) => v.estado == EstadoViaje.concluido;

  /// Escribe el adelanto [ad] en las columnas A-C de la fila [r]
  /// (0-based). Si es null, deja las celdas vacías pero bordeadas.
  static void _setFilaAdelanto(ex.Sheet hoja, int r, AdelantoChofer? ad) {
    final stCentrado = _estilo(align: ex.HorizontalAlign.Center);
    _set(hoja, 0, r,
        ad == null
            ? null
            : ex.TextCellValue(AppFormatters.formatearFecha(ad.fecha)),
        stCentrado);
    _set(hoja, 1, r,
        ad?.numeroRecibo == null ? null : ex.IntCellValue(ad!.numeroRecibo!),
        stCentrado);
    _set(hoja, 2, r, ad == null ? null : ex.DoubleCellValue(ad.monto),
        _estilo(bold: true, monto: true));
  }

  /// Escribe un viaje/tramo [fila] en las columnas D-O de la fila [r]
  /// (0-based). Si es null, deja las celdas vacías pero bordeadas. La
  /// GANANCIA (N) lleva el FLOOR ya aplicado (igual que CalculosViaje);
  /// para EN_CURSO/PLANEADOS sin kg descargados usa los cargados como
  /// estimado — justo lo que contabilidad quiere para especular.
  static void _setFilaViaje(
    ex.Sheet hoja,
    int r,
    ({Viaje v, TramoViaje t})? fila,
    ResolverProvincias provincias,
  ) {
    final f = r + 1; // 1-based para fórmulas
    final stCelda = _estilo();
    final stMonto = _estilo(monto: true);
    final stMontoBold = _estilo(bold: true, monto: true);
    final stCentrado = _estilo(align: ex.HorizontalAlign.Center);
    final t = fila?.t;
    final snap = t?.tarifaSnapshot;

    _set(hoja, 3, r,
        t?.fechaCarga == null
            ? null
            : ex.TextCellValue(AppFormatters.formatearFecha(t!.fechaCarga)),
        stCentrado);
    _set(hoja, 4, r,
        (t?.remitoNumero?.trim().isNotEmpty ?? false)
            ? ex.TextCellValue(t!.remitoNumero!.trim())
            : null,
        stCentrado);
    final mercaderia = t?.producto ?? t?.descripcionCarga;
    _set(hoja, 5, r,
        mercaderia == null ? null : ex.TextCellValue(mercaderia), stCelda);
    _set(hoja, 6, r,
        snap == null
            ? null
            : ex.TextCellValue(stripParentesis(snap.origenEtiqueta)),
        stCelda);
    final provO = t == null ? '' : provincias.origenDe(t);
    _set(hoja, 7, r, provO.isEmpty ? null : ex.TextCellValue(provO),
        stCentrado);
    _set(hoja, 8, r,
        snap == null
            ? null
            : ex.TextCellValue(stripParentesis(snap.destinoEtiqueta)),
        stCelda);
    final provD = t == null ? '' : provincias.destinoDe(t);
    _set(hoja, 9, r, provD.isEmpty ? null : ex.TextCellValue(provD),
        stCentrado);

    // K-L (pedido Santiago 2026-06-11): fecha de descarga + km del tramo,
    // intercalados entre PROV. destino (J) y los kg (M). La fecha sale del
    // tramo; el km, de la tarifa del catálogo por tarifaId.
    _set(
        hoja,
        10,
        r,
        t?.fechaDescarga == null
            ? null
            : ex.TextCellValue(AppFormatters.formatearFecha(t!.fechaDescarga!)),
        stCentrado);
    final km = t == null ? null : provincias.kmDe(t);
    _set(hoja, 11, r, km == null ? null : ex.IntCellValue(km), stCentrado);

    // M-N: kg efectivo + diferencia de kg.
    final kg = _kgEfectivo(t);
    _set(hoja, 12, r, kg == null ? null : ex.DoubleCellValue(kg), stMonto);
    final dif = _difKg(t);
    _set(hoja, 13, r, dif == null ? null : ex.DoubleCellValue(dif), stMonto);

    // O: tarifa chofer (base del cálculo del chofer).
    _set(hoja, 14, r,
        snap == null ? null : ex.DoubleCellValue(snap.tarifaChofer), stMonto);

    // P: GANANCIA (FLOOR ya aplicado). La fórmula referencia kg en M y la
    // tarifa chofer en O (las columnas nuevas tras intercalar F.DESC/KM).
    final pct = _pctDe(fila?.v);
    final ex.CellValue? nValue;
    if (snap == null) {
      nValue = null;
    } else if (snap.montoFijoChofer != null) {
      nValue = ex.DoubleCellValue(_redondear5(snap.montoFijoChofer!));
    } else if (snap.unidadTarifa == UnidadTarifa.porViaje) {
      nValue = ex.FormulaCellValue('FLOOR(O$f*${_pctStr(pct)}%,5)');
    } else {
      nValue = ex.FormulaCellValue('FLOOR((M$f*O$f*${_pctStr(pct)}%)/1000,5)');
    }
    _set(hoja, 15, r, nValue, stMontoBold);

    // Q: gastos del tramo.
    final gastos = t?.gastosTotal ?? 0;
    _set(hoja, 16, r, gastos == 0 ? null : ex.DoubleCellValue(gastos),
        stMonto);
  }

  /// Encabezado común del cuaderno (filas 1-3), reutilizado por las
  /// hojas de chofer y por CONSULTA. [chofer] es el nombre (texto) en
  /// las hojas de chofer, o la celda del dropdown en CONSULTA.
  ///   Fila 1: "MES: <mes>"  ·  "CHOFER:"  ·  <chofer>
  ///   Fila 2: súper-header  ADELANTOS │ VIAJES
  ///   Fila 3: headers de columna
  static void _dibujarEncabezado(
    ex.Sheet hoja, {
    required DateTime mes,
    required ex.CellValue chofer,
  }) {
    final mesAnio = AppFormatters.formatearMes(mes).toUpperCase();
    final stTitulo = _estilo(bold: true, size: 12, gris: true, borde: false);

    // Fila 1: banner gris MES / CHOFER.
    _setMerged(hoja, 0, 0, 4, 0, ex.TextCellValue('MES: $mesAnio'), stTitulo);
    _set(hoja, 5, 0, ex.TextCellValue('CHOFER:'), stTitulo);
    _setMerged(hoja, 6, 0, 16, 0, chofer, stTitulo);

    // Fila 2: súper-header de las dos secciones.
    final stSuper =
        _estilo(bold: true, gris: true, align: ex.HorizontalAlign.Center);
    _setMerged(hoja, 0, 1, 2, 1, ex.TextCellValue('ADELANTOS'), stSuper);
    _setMerged(hoja, 3, 1, 16, 1, ex.TextCellValue('VIAJES'), stSuper);

    // Fila 3: headers de columna.
    final stHeader =
        _estilo(bold: true, gris: true, align: ex.HorizontalAlign.Center);
    for (var c = 0; c < _headersColumna.length; c++) {
      _set(hoja, c, 2, ex.TextCellValue(_headersColumna[c]), stHeader);
    }
  }

  /// Headers de las 17 columnas del cuaderno (A..Q). F. DESC y KM van
  /// intercalados entre PROV. destino (J) y KG (ahora M) — pedido Santiago
  /// 2026-06-11. Eso corre las columnas con fórmula: KG=M, DIF.KG=N,
  /// TARIFA=O, GANANCIA=P, GASTOS=Q (las fórmulas del pie/RESUMEN/cálculo
  /// se ajustaron a esas letras nuevas).
  static const List<String> _headersColumna = [
    'FECHA', 'RECIBO', 'IMPORTE', // A-C adelantos
    'F. CARGA', 'REMITO', 'MERCADERÍA', 'ORIGEN', 'PROV.', 'DESTINO',
    'PROV.', 'F. DESC', 'KM', // D-L: ruta + descarga + km
    'KG', 'DIF. KG', 'TARIFA', 'GANANCIA', 'GASTOS', // M-Q
  ];

  /// Anchos de las 15 columnas (parejos, sin la separadora rara del
  /// archivo viejo). Compartido por hojas de chofer y CONSULTA.
  static void _aplicarAnchos(ex.Sheet hoja) {
    const anchos = [
      11.0, 9.0, 12.0, // A-C adelantos
      11.0, 10.0, 15.0, 18.0, 8.0, 18.0, 8.0, // D-J f.carga..prov destino
      11.0, 8.0, // K-L f. desc + km
      9.0, 8.0, 11.0, 12.0, 10.0, // M-Q kg, dif kg, tarifa, ganancia, gastos
    ];
    for (var c = 0; c < anchos.length; c++) {
      hoja.setColumnWidth(c, anchos[c]);
    }
  }

  /// Redondeo a múltiplo de 5 inferior (igual que
  /// `CalculosViaje.redondearMultiploDe5Descendente`) para el monto
  /// fijo, que va como valor flat (no fórmula).
  static double _redondear5(double v) => (v / 5).floor() * 5.0;

  // ===================================================================
  // HOJA CONSULTA (dropdown + espejo INDIRECT)
  // ===================================================================

  /// Columna helper (0-based) donde van los nombres EXACTOS de hoja
  /// que alimentan el dropdown. Va a la derecha del cuaderno (Q=16) y
  /// se oculta por XML. El data validation referencia `S1:S{N}`.
  static const int _colListaChoferes = 18; // S

  /// Construye la hoja CONSULTA: un dropdown en G1 para elegir chofer
  /// y, debajo, su cuaderno completo ESPEJADO con fórmulas INDIRECT a
  /// la hoja del chofer elegido. Así administración no va hoja por hoja
  /// (pedido Santiago 2026-06-10) — las hojas por chofer quedan
  /// ocultas como fuente de datos.
  ///
  /// La grilla espeja celda a celda; el pie se RECALCULA sobre la
  /// propia grilla espejada reusando [_bloquePie], así los totales
  /// cuadran sin más INDIRECT. El nombre del chofer (G1) es el único
  /// dato "vivo": lo elige el dropdown y todas las fórmulas INDIRECT lo
  /// referencian con `$G$1`. [nDatos] = filas de grilla (uniforme entre
  /// todas las hojas, ver `construir`).
  static void _construirHojaConsulta(
    ex.Excel excel, {
    required List<_MetaHojaChofer> metas,
    required DateTime mes,
    required int nDatos,
    required int nOtros,
  }) {
    final hoja = excel['CONSULTA'];

    if (metas.isEmpty) {
      _set(hoja, 0, 0, ex.TextCellValue('Sin datos para el período.'),
          _estilo(bold: true, size: 12, borde: false));
      return;
    }

    // Encabezado compartido; en G1 va el valor inicial del dropdown
    // (primer chofer alfabético) para que el INDIRECT resuelva al abrir.
    _dibujarEncabezado(hoja,
        mes: mes, chofer: ex.TextCellValue(metas.first.nombreHoja));

    // Mismas posiciones que una hoja de chofer (el espejo apunta a las
    // mismas celdas, así que la estructura debe coincidir).
    final filaDatosFin = 3 + nDatos;
    final filaOtrosTit = filaDatosFin + 2;
    final filaOtrosIni = filaOtrosTit + 1;
    final filaOtrosFin = filaOtrosTit + nOtros;

    // ─── Grillas: espejo INDIRECT al chofer de G1 ───────────────────
    // Cada celda: =IF(INDIRECT("'"&$G$1&"'!A4")=0,"",INDIRECT(...)).
    // El IF(=0,"") deja en blanco lo vacío. Se espeja la grilla
    // principal (concluidos) y la de OTROS VIAJES; el título de la
    // sección es fijo.
    void espejar(int fIni, int fFin) {
      for (var f = fIni; f <= fFin; f++) {
        for (var c = 1; c <= 17; c++) {
          final ref = _refIndirect(_colLetra(c), f);
          final formula = 'IF(INDIRECT($ref)=0,"",INDIRECT($ref))';
          _set(hoja, c - 1, f - 1, ex.FormulaCellValue(formula),
              _estiloColGrilla(c));
        }
      }
    }

    espejar(4, filaDatosFin);
    _setMerged(hoja, 0, filaOtrosTit - 1, 16, filaOtrosTit - 1,
        ex.TextCellValue('OTROS VIAJES (EN CURSO / PLANEADOS)'),
        _estilo(bold: true, gris: true, align: ex.HorizontalAlign.Center));
    espejar(filaOtrosIni, filaOtrosFin);

    // Pie: recalcula sobre las grillas espejadas (reusa _bloquePie).
    _bloquePie(hoja,
        filaDatosFin: filaDatosFin,
        filaOtrosIni: filaOtrosIni,
        filaOtrosFin: filaOtrosFin);
    _aplicarAnchos(hoja);

    // ─── Columna helper S: nombres EXACTOS de hoja para el dropdown ──
    // Se oculta (ancho 0). El data validation referencia S1:S{N}. Usar
    // los nombres de HOJA (no el del RESUMEN) garantiza que el INDIRECT
    // resuelva aunque el nombre se haya saneado/recortado.
    for (var i = 0; i < metas.length; i++) {
      _set(hoja, _colListaChoferes, i, ex.TextCellValue(metas[i].nombreHoja),
          _estilo(borde: false));
    }
    hoja.setColumnWidth(_colListaChoferes, 0);
  }

  /// Letra de columna Excel para un índice 1-based (1→A … 15→O).
  static String _colLetra(int col1based) =>
      String.fromCharCode('A'.codeUnitAt(0) + col1based - 1);

  /// Construye la referencia interna de INDIRECT a la celda
  /// `<colLetra><fila>` de la hoja nombrada en `$G$1`:
  ///   "'"&$G$1&"'!A4"
  /// (comillas simples porque los nombres de hoja llevan espacios).
  static String _refIndirect(String colLetra, int fila) =>
      '"\'"&\$G\$1&"\'!$colLetra$fila"';

  /// Estilo de cada columna de la grilla (1-based), igual que en
  /// [_llenarHojaChofer]: centrado para fechas/recibo/provincia, monto
  /// para importes, bold para los acumulables del chofer.
  static ex.CellStyle _estiloColGrilla(int c) {
    switch (c) {
      case 3: // C importe adelanto
      case 16: // P ganancia
        return _estilo(bold: true, monto: true);
      case 13: // M kg
      case 14: // N dif kg
      case 15: // O tarifa
      case 17: // Q gastos
        return _estilo(monto: true);
      case 1: // A fecha adelanto
      case 2: // B recibo
      case 4: // D fecha carga
      case 5: // E remito
      case 8: // H prov origen
      case 10: // J prov destino
      case 11: // K fecha de descarga
      case 12: // L km del tramo
        return _estilo(align: ex.HorizontalAlign.Center);
      default: // F G I — texto
        return _estilo();
    }
  }

  /// Pie del cuaderno — bloque de liquidación con la lógica del archivo
  /// original (Santiago 2026-06-10): lo FIRME (concluidos) arriba, la
  /// ESPECULACIÓN (otros viajes) abajo:
  ///   GANANCIA VIAJES − ADELANTOS + GASTOS = NETO A PAGAR  (firme)
  ///   NETO A PAGAR + OTROS VIAJES = TOTAL ESTIMADO         (proyección)
  /// Tablita a la izquierda con bordes que cierran (_setMerged), fila
  /// de aire arriba. Los importes de los CONCLUIDOS salen de la grilla
  /// principal (filas 4..[filaDatosFin]); los de OTROS VIAJES de su
  /// propia sección ([filaOtrosIni]..[filaOtrosFin]).
  static void _bloquePie(
    ex.Sheet hoja, {
    required int filaDatosFin,
    required int filaOtrosIni,
    required int filaOtrosFin,
  }) {
    final stLabel = _estilo(bold: true);
    final stValor = _estilo(monto: true, align: ex.HorizontalAlign.Right);
    final stTituloGris =
        _estilo(bold: true, gris: true, align: ex.HorizontalAlign.Center);
    final stLabelDest = _estilo(bold: true, gris: true);
    final stValorDest = _estilo(
        bold: true, gris: true, monto: true, align: ex.HorizontalAlign.Right);

    final fTit = filaOtrosFin + 2; // 1 fila de aire tras OTROS VIAJES
    final fGan = fTit + 1;
    final fAdel = fGan + 1;
    final fGastos = fAdel + 1;
    final fNeto = fGastos + 1;
    final fOtros = fNeto + 1;
    final fTotal = fOtros + 1;

    _setMerged(hoja, 0, fTit - 1, 3, fTit - 1,
        ex.TextCellValue('LIQUIDACIÓN'), stTituloGris);

    void renglon(int f, String label, String formula, {bool dest = false}) {
      _setMerged(hoja, 0, f - 1, 1, f - 1, ex.TextCellValue(label),
          dest ? stLabelDest : stLabel);
      _setMerged(hoja, 2, f - 1, 3, f - 1, ex.FormulaCellValue(formula),
          dest ? stValorDest : stValor);
    }

    // Firme (concluidos). GANANCIA = col P, GASTOS = col Q (tras intercalar
    // F.DESC/KM); ADELANTOS sigue en C.
    renglon(fGan, 'GANANCIA VIAJES', 'SUM(P4:P$filaDatosFin)');
    renglon(fAdel, 'ADELANTOS (−)', 'SUM(C4:C$filaDatosFin)');
    renglon(fGastos, 'GASTOS (+)', 'SUM(Q4:Q$filaDatosFin)');
    renglon(fNeto, 'NETO A PAGAR', 'C$fGan-C$fAdel+C$fGastos', dest: true);
    // Especulación (en curso / planeados) + total proyectado.
    renglon(fOtros, 'OTROS VIAJES (+)', 'SUM(P$filaOtrosIni:P$filaOtrosFin)');
    renglon(fTotal, 'TOTAL ESTIMADO', 'C$fNeto+C$fOtros', dest: true);
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

  /// Mergea un rango y aplica [style] a TODAS sus celdas — no solo a la
  /// top-left. Clave para que los bordes CIERREN: la lib `excel` toma
  /// el borde de cada celda subyacente, así que un merge con estilo
  /// solo en la esquina queda "abierto" del lado opuesto (el bug de
  /// "bordes mal armados" del export 2026-06-10). El valor va solo en
  /// la celda top-left.
  static void _setMerged(
    ex.Sheet hoja,
    int col0,
    int row0,
    int col1,
    int row1,
    ex.CellValue? value,
    ex.CellStyle style,
  ) {
    hoja.merge(_ci(col0, row0), _ci(col1, row1));
    for (var r = row0; r <= row1; r++) {
      for (var c = col0; c <= col1; c++) {
        final cell = hoja.cell(_ci(c, r));
        if (c == col0 && r == row0 && value != null) cell.value = value;
        cell.cellStyle = style;
      }
    }
  }

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

  /// Última fila (1-based) de la grilla principal (CONCLUIDOS) — fin de
  /// los rangos `SUM(N4:N{filaDatosFin})` del firme.
  final int filaDatosFin;

  /// Primera y última fila (1-based) de la sección OTROS VIAJES (la
  /// especulación) — para `SUM(N{filaOtrosIni}:N{filaOtrosFin})`.
  final int filaOtrosIni;
  final int filaOtrosFin;

  /// Σ `montoVecchi` de los viajes del chofer (valor de la app — el
  /// cuaderno no tiene celda de facturación, así que va como número).
  final double facturado;

  const _MetaHojaChofer({
    required this.dni,
    required this.nombreChofer,
    required this.nombreHoja,
    required this.filaDatosFin,
    required this.filaOtrosIni,
    required this.filaOtrosFin,
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
///
/// Además resuelve los **km del recorrido** del tramo por su `tarifaId`
/// (mismo catálogo de tarifas) vía [kmDe] — se cargan a mano en la tarifa.
class ResolverProvincias {
  final Map<String, ({String origen, String destino})> _porTarifa;
  final Map<String, String> _porNombreUbicacion;

  /// Km del recorrido por id de tarifa (del mismo catálogo). null = la
  /// tarifa no tiene km cargado. Sale de `TarifaLogistica.km` — ver [kmDe].
  final Map<String, int?> _kmPorTarifa;

  ResolverProvincias._(
      this._porTarifa, this._porNombreUbicacion, this._kmPorTarifa);

  /// Resolver sin catálogos — todas las provincias salen vacías. Para
  /// cuando el fetch de catálogos falla (offline) o en tests.
  factory ResolverProvincias.vacio() => ResolverProvincias._({}, {}, {});

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
    final kmPorTarifa = <String, int?>{};
    for (final t in tarifas) {
      porTarifa[t.id] = (
        origen: provPorUbicacionId[t.ubicacionOrigenId] ?? '',
        destino: provPorUbicacionId[t.ubicacionDestinoId] ?? '',
      );
      kmPorTarifa[t.id] = t.km;
    }
    return ResolverProvincias._(porTarifa, porNombre, kmPorTarifa);
  }

  String origenDe(TramoViaje t) =>
      _porTarifa[t.tarifaId]?.origen ??
      _porEtiqueta(t.tarifaSnapshot.origenEtiqueta);

  String destinoDe(TramoViaje t) =>
      _porTarifa[t.tarifaId]?.destino ??
      _porEtiqueta(t.tarifaSnapshot.destinoEtiqueta);

  /// Km del recorrido del tramo: resuelto por la tarifa del catálogo
  /// (`tarifaId` → `TarifaLogistica.km`). null si la tarifa fue eliminada
  /// o no tiene km cargado. No hay fallback por etiqueta — el km no se
  /// puede inferir del nombre de la ubicación.
  int? kmDe(TramoViaje t) => _kmPorTarifa[t.tarifaId];

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
