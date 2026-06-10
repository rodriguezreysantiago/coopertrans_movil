// Helpers compartidos por todos los reportes Excel.
//
// Centralizamos acá todo lo que repetiríamos en cada report_*.dart:
// el parche de AutoFilter sobre el XML del .xlsx (la lib `excel` no
// expone API), el cálculo manual de auto-fit (porque setColumnAutoFit
// solo flagea sin calcular), y el format code argentino para números.
//
// Si en el futuro migramos a otra librería de Excel (syncfusion, etc.),
// estos helpers desaparecen — pero la API expuesta es genérica y los
// callers no necesitan cambiar.

import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as ex;

/// Formato numérico argentino: 1.234.567,89 (punto miles, coma
/// decimal). El prefijo `[$-2C0A]` fuerza el locale es-AR
/// independiente de la configuración regional de la PC del lector.
const formatoAR = ex.CustomNumericNumFormat(
  formatCode: r'[$-2C0A]#,##0.00',
);

/// Formato numérico argentino sin decimales (1.234.567). Para
/// columnas tipo "KM" donde no aporta el .89 final.
const formatoARSinDecimales = ex.CustomNumericNumFormat(
  formatCode: r'[$-2C0A]#,##0',
);

/// Decodifica el .xlsx (ZIP), inyecta `<autoFilter ref="A1:Z10000"/>`
/// en cada worksheet después de `</sheetData>`, y re-empaqueta. El
/// resultado: Excel activa los filtros automáticamente al abrir el
/// archivo (sin tener que hacer Ctrl+Shift+L manual).
///
/// Con [soloHojas] el parche aplica únicamente a las hojas con esos
/// nombres (p. ej. los anexos tabulares de la planilla de viajes —
/// las hojas cuaderno tienen headers merged en la fila 1 y un
/// autofilter ahí queda roto visualmente). El mapeo nombre → archivo
/// sale de `xl/workbook.xml` + `xl/_rels/workbook.xml.rels`; si por
/// algún motivo no se puede resolver, NO se inyecta nada (mejor sin
/// filtros que filtros en hojas con layout).
///
/// La librería `excel` 4.0.6 no expone API para AutoFilter (issue
/// abierto en su repo hace 20+ meses). Migrar a syncfusion_flutter_xlsio
/// requiere licencia comercial — Vecchi no califica para Community
/// License (>10 empleados típicos en transporte). Solución: parche
/// directo al XML.
List<int> aplicarAutoFilterAlXlsx(List<int> bytes, {Set<String>? soloHojas}) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final patron = RegExp(r'^xl/worksheets/sheet\d+\.xml$');

  // null → todas las hojas (comportamiento histórico). Si hay filtro,
  // resolvemos qué archivos sheetN.xml corresponden a esos nombres.
  Set<String>? archivosPermitidos;
  if (soloHojas != null) {
    archivosPermitidos = _archivosDeHojas(archive, soloHojas);
  }

  final out = Archive();
  for (final file in archive.files) {
    final aplicar = file.isFile &&
        patron.hasMatch(file.name) &&
        (archivosPermitidos == null ||
            archivosPermitidos.contains(file.name));
    if (aplicar) {
      final content = utf8.decode(file.content as List<int>);
      final modified = _inyectarAutoFilter(content);
      final newBytes = utf8.encode(modified);
      out.addFile(ArchiveFile(file.name, newBytes.length, newBytes));
    } else {
      out.addFile(file);
    }
  }
  final encoded = ZipEncoder().encode(out);
  // Defensa: si por algún motivo encode devuelve null (no debería con
  // un Archive válido), devolvemos los bytes originales — el archivo
  // se abre sin AutoFilter pero al menos no se rompe.
  return encoded ?? bytes;
}

/// Resuelve los paths `xl/worksheets/sheetN.xml` de las hojas cuyos
/// nombres están en [nombres]. Dos pasos sobre los XML del paquete:
///   1. `xl/workbook.xml`: `<sheet name="X" … r:id="rIdN"/>` → rId.
///   2. `xl/_rels/workbook.xml.rels`: rId → `Target="worksheets/…"`.
/// Si algo no matchea, la hoja simplemente no entra al set (y el
/// caller no le inyecta autofilter).
Set<String> _archivosDeHojas(Archive archive, Set<String> nombres) {
  String? leer(String path) {
    for (final f in archive.files) {
      if (f.isFile && f.name == path) {
        return utf8.decode(f.content as List<int>);
      }
    }
    return null;
  }

  final workbook = leer('xl/workbook.xml');
  final rels = leer('xl/_rels/workbook.xml.rels');
  if (workbook == null || rels == null) return {};

  // name → rId (los atributos pueden venir en cualquier orden, así que
  // capturamos ambos por separado dentro del tag <sheet …/>).
  final ridPorNombre = <String, String>{};
  for (final m in RegExp(r'<sheet\b[^>]*/?>').allMatches(workbook)) {
    final tag = m.group(0)!;
    final name = RegExp(r'name="([^"]*)"').firstMatch(tag)?.group(1);
    final rid = RegExp(r'r:id="([^"]*)"').firstMatch(tag)?.group(1);
    if (name != null && rid != null) ridPorNombre[_unescapeXml(name)] = rid;
  }

  // rId → target normalizado a path absoluto dentro del zip.
  final targetPorRid = <String, String>{};
  for (final m in RegExp(r'<Relationship\b[^>]*/?>').allMatches(rels)) {
    final tag = m.group(0)!;
    final id = RegExp(r'Id="([^"]*)"').firstMatch(tag)?.group(1);
    final target = RegExp(r'Target="([^"]*)"').firstMatch(tag)?.group(1);
    if (id != null && target != null) {
      targetPorRid[id] =
          target.startsWith('/') ? target.substring(1) : 'xl/$target';
    }
  }

  final out = <String>{};
  for (final nombre in nombres) {
    final rid = ridPorNombre[nombre];
    final target = rid == null ? null : targetPorRid[rid];
    if (target != null) out.add(target);
  }
  return out;
}

String _unescapeXml(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// Configura la hoja CONSULTA de la planilla de viajes y oculta las
/// hojas por chofer, en una sola pasada sobre el .xlsx (ZIP). Dos
/// cambios que la lib `excel` 4.0.6 no expone:
///   1. **Data validation** tipo lista en [celdaDropdown] de
///      [hojaConsulta], con la lista de choferes en `S1:S{N}` (la
///      columna helper que arma `ReportPlanillaChofer`). Esto crea el
///      menú desplegable para elegir chofer.
///   2. **Ocultar** las [hojasAOcultar] (las 44 por chofer) → quedan
///      como fuente de datos del RESUMEN y del espejo INDIRECT de
///      CONSULTA, sin ensuciar la barra de pestañas.
///
/// Si algo no se puede resolver (XML inesperado), devuelve los bytes
/// sin ese cambio — mejor un archivo sin dropdown que uno corrupto.
List<int> configurarConsultaYOcultarHojas(
  List<int> bytes, {
  required String hojaConsulta,
  required String celdaDropdown,
  required int cantidadChoferes,
  required Set<String> hojasAOcultar,
}) {
  if (cantidadChoferes <= 0) return bytes;
  final archive = ZipDecoder().decodeBytes(bytes);
  final archivosConsulta = _archivosDeHojas(archive, {hojaConsulta});

  final out = Archive();
  for (final file in archive.files) {
    if (file.isFile && file.name == 'xl/workbook.xml') {
      final xml = utf8.decode(file.content as List<int>);
      final mod = _ocultarHojasEnWorkbook(xml, hojasAOcultar);
      final nb = utf8.encode(mod);
      out.addFile(ArchiveFile(file.name, nb.length, nb));
    } else if (file.isFile && archivosConsulta.contains(file.name)) {
      final xml = utf8.decode(file.content as List<int>);
      final mod = _inyectarDataValidation(
        xml,
        celda: celdaDropdown,
        rango: '\$S\$1:\$S\$$cantidadChoferes',
      );
      final nb = utf8.encode(mod);
      out.addFile(ArchiveFile(file.name, nb.length, nb));
    } else {
      out.addFile(file);
    }
  }
  final encoded = ZipEncoder().encode(out);
  return encoded ?? bytes;
}

/// Pone `state="hidden"` en cada `<sheet name="X" …/>` de workbook.xml
/// cuyo nombre esté en [nombres]. La lib `excel` ya emite
/// `state="visible"` en cada sheet, así que REEMPLAZAMOS ese atributo
/// (no alcanza con insertarlo: quedaría duplicado y se ignora).
String _ocultarHojasEnWorkbook(String xml, Set<String> nombres) {
  return xml.replaceAllMapped(RegExp(r'<sheet\b[^>]*/>'), (m) {
    final tag = m.group(0)!;
    final name = RegExp(r'name="([^"]*)"').firstMatch(tag)?.group(1);
    if (name == null || !nombres.contains(_unescapeXml(name))) return tag;
    if (tag.contains('state=')) {
      return tag.replaceFirst(RegExp(r'state="[^"]*"'), 'state="hidden"');
    }
    return tag.replaceFirst('<sheet', '<sheet state="hidden"');
  });
}

/// Inyecta una data validation tipo lista en [celda], con la fuente en
/// [rango] (mismo-hoja, sin comillas → es un rango de celdas). Va
/// DESPUÉS de `</mergeCells>` (orden OOXML: mergeCells < dataValidations
/// < pageMargins); si la hoja no tuviera merges, después de
/// `</sheetData>`. Idempotente.
String _inyectarDataValidation(
  String xml, {
  required String celda,
  required String rango,
}) {
  if (xml.contains('<dataValidations')) return xml;
  final dv = '<dataValidations count="1">'
      '<dataValidation type="list" allowBlank="1" showInputMessage="1" '
      'showErrorMessage="1" sqref="$celda">'
      '<formula1>$rango</formula1>'
      '</dataValidation></dataValidations>';
  if (xml.contains('</mergeCells>')) {
    return xml.replaceFirst('</mergeCells>', '</mergeCells>$dv');
  }
  return xml.replaceFirst('</sheetData>', '</sheetData>$dv');
}

/// Inyecta `<autoFilter ref="A1:Z10000"/>` en el XML de un worksheet.
/// El elemento debe ir DESPUÉS de `</sheetData>` (orden requerido por
/// el spec OOXML — sino Excel rechaza el archivo como corrupto).
///
/// Rango "A1:Z10000": amplio para cubrir cualquier reporte razonable
/// (Excel ignora celdas vacías al filtrar). Si el reporte tiene > 26
/// columnas o > 10000 filas, ampliar.
String _inyectarAutoFilter(String xml) {
  if (xml.contains('<autoFilter ')) return xml;
  return xml.replaceFirst(
    '</sheetData>',
    '</sheetData><autoFilter ref="A1:Z10000"/>',
  );
}

/// Auto-fit de columnas calculado manual: para cada columna, ancho =
/// max(largo_título, max_largo_celda) + 2 chars de padding.
///
/// Por qué no usar `setColumnAutoFit` de la lib: ese solo marca un
/// flag y delega el cálculo a Excel al abrir. Excel suele truncar
/// headers largos. Calculando acá garantizamos que tanto el título
/// como cualquier celda entran sin truncado.
///
/// Para celdas DoubleCellValue/IntCellValue, simulamos el formato AR
/// (1.234.567,89) para estimar el ancho visual real, no solo los
/// dígitos crudos.
void autoFitColumnas(ex.Sheet hoja, int numCols, int numRows) {
  for (var col = 0; col < numCols; col++) {
    var maxLen = 0;
    for (var row = 0; row < numRows; row++) {
      final cell = hoja.cell(ex.CellIndex.indexByColumnRow(
          columnIndex: col, rowIndex: row));
      final len = _anchoCelda(cell);
      if (len > maxLen) maxLen = len;
    }
    final ancho = (maxLen < 6 ? 6 : maxLen) + 2;
    hoja.setColumnWidth(col, ancho.toDouble());
  }
}

int _anchoCelda(ex.Data cell) {
  final value = cell.value;
  if (value == null) return 0;
  if (value is ex.TextCellValue) {
    return value.value.toString().length;
  }
  if (value is ex.DoubleCellValue) {
    return _renderArgFormatLength(value.value);
  }
  if (value is ex.IntCellValue) {
    return _renderArgFormatLength(value.value.toDouble());
  }
  return value.toString().length;
}

int _renderArgFormatLength(double value) {
  final fixed = value.toStringAsFixed(2); // "1234567.89"
  final partes = fixed.split('.');
  final entera = partes[0].replaceAll('-', '');
  final puntos = ((entera.length - 1) ~/ 3); // separadores de miles
  final signo = value < 0 ? 1 : 0;
  return entera.length + puntos + 1 /* coma */ + 2 /* decimales */ + signo;
}
