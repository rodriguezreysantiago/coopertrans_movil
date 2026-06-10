// Tests de la planilla de cuadernos (ReportPlanillaChofer) — réplica
// del Excel histórico de administración. Patrón: generar el workbook
// COMPLETO en memoria, guardarlo a bytes y RELEERLO con package:excel
// para verificar celdas, fórmulas y estructura — end-to-end real sin
// Firestore ni UI.

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as ex;
import 'package:flutter_test/flutter_test.dart';

import 'package:coopertrans_movil/features/logistica/models/adelanto_chofer.dart';
import 'package:coopertrans_movil/features/logistica/models/tarifa_logistica.dart';
import 'package:coopertrans_movil/features/logistica/models/ubicacion_logistica.dart';
import 'package:coopertrans_movil/features/logistica/models/viaje.dart';
import 'package:coopertrans_movil/features/logistica/services/liquidacion_service.dart'
    show EmpleadoLiquidacion;
import 'package:coopertrans_movil/features/logistica/services/report_planilla_chofer.dart';
import 'package:coopertrans_movil/features/reports/services/excel_utils.dart'
    as xu;

// ─── Fixtures ────────────────────────────────────────────────────────

TarifaSnapshot snapTn({
  double tarifaChofer = 58106,
  double tarifaReal = 60000,
  String origen = 'B.BLANCA (BAHIA BLANCA)',
  String destino = 'NECOCHEA',
}) {
  return TarifaSnapshot(
    origenEtiqueta: origen,
    destinoEtiqueta: destino,
    empresaOrigenNombre: 'PROFERTIL',
    empresaDestinoNombre: 'CLIENTE SA',
    unidadTarifa: UnidadTarifa.porTonelada,
    tarifaReal: tarifaReal,
    tarifaChofer: tarifaChofer,
  );
}

Viaje viajeDe({
  required String id,
  required List<TramoViaje> tramos,
  String dni = '123',
  String nombre = 'DIAZ MARIO',
  double montoVecchi = 0,
  double pct = 18,
}) {
  return Viaje(
    id: id,
    tramos: tramos,
    choferDni: dni,
    choferNombre: nombre,
    estado: EstadoViaje.concluido,
    montoVecchi: montoVecchi,
    montoChofer: 0,
    montoChoferRedondeado: 0,
    comisionChoferPct: pct,
    gastosTotal: 0,
    liquidacionChofer: 0,
  );
}

AdelantoChofer adelantoDe({
  required String id,
  String dni = '123',
  String nombre = 'DIAZ MARIO',
  required DateTime fecha,
  required double monto,
  int? recibo,
}) {
  return AdelantoChofer(
    id: id,
    choferDni: dni,
    choferNombre: nombre,
    fecha: fecha,
    monto: monto,
    numeroRecibo: recibo,
  );
}

// ─── Helpers de lectura ──────────────────────────────────────────────

ex.CellValue? celda(ex.Sheet s, String ref) =>
    s.cell(ex.CellIndex.indexByString(ref)).value;

String? formulaDe(ex.Sheet s, String ref) {
  final v = celda(s, ref);
  return v is ex.FormulaCellValue ? v.formula : null;
}

String? textoDe(ex.Sheet s, String ref) {
  final v = celda(s, ref);
  return v is ex.TextCellValue ? v.value.toString() : null;
}

double? numeroDe(ex.Sheet s, String ref) {
  final v = celda(s, ref);
  if (v is ex.DoubleCellValue) return v.value;
  if (v is ex.IntCellValue) return v.value.toDouble();
  return null;
}

/// Fila Excel (1-based) cuya columna A contiene exactamente [texto].
int filaConLabel(ex.Sheet s, String texto) {
  for (var r = 0; r < s.maxRows; r++) {
    final v = s
        .cell(ex.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r))
        .value;
    if (v is ex.TextCellValue && v.value.toString() == texto) return r + 1;
  }
  fail('No se encontró la fila con label "$texto"');
}

void main() {
  group('ReportPlanillaChofer.construir', () {
    late ex.Excel relectura;

    setUpAll(() {
      // Chofer DIAZ MARIO: 2 viajes (single TN + multi con fijo y
      // por-viaje) + 2 adelantos. Chofer ALTAMIRANDA: solo adelanto
      // (caso adelanto de sueldo sin viajes).
      final viaje1 = viajeDe(
        id: 'V1',
        montoVecchi: 2082000,
        tramos: [
          TramoViaje(
            id: 't1',
            tarifaId: 'T1',
            tarifaSnapshot: snapTn(),
            producto: 'UREA',
            fechaCarga: DateTime(2026, 5, 2),
            kgCargados: 35000,
            kgDescargados: 34700,
            remitoNumero: '291824',
            gastos: [GastoViaje(monto: 11200, fecha: DateTime(2026, 5, 2))],
          ),
        ],
      );
      final viaje2 = viajeDe(
        id: 'V2',
        montoVecchi: 1800000,
        tramos: [
          // En curso: sin descarga → kg cargados como estimado.
          TramoViaje(
            id: 't2a',
            tarifaId: 'T2',
            tarifaSnapshot: snapTn(tarifaChofer: 50000),
            fechaCarga: DateTime(2026, 5, 10),
            kgCargados: 30000,
          ),
          // Monto fijo del chofer: flat, sin fórmula de %.
          TramoViaje(
            id: 't2b',
            tarifaId: 'T3',
            tarifaSnapshot: snapTn().copyWith(montoFijoChofer: 100000.0),
            fechaCarga: DateTime(2026, 5, 11),
          ),
          // Por viaje: tarifa flat × pct, sin kg.
          TramoViaje(
            id: 't2c',
            tarifaId: 'T4',
            tarifaSnapshot: const TarifaSnapshot(
              origenEtiqueta: 'ESTHER',
              destinoEtiqueta: 'AÑELO',
              empresaOrigenNombre: 'ARENERA',
              empresaDestinoNombre: 'YPF',
              unidadTarifa: UnidadTarifa.porViaje,
              tarifaReal: 250000,
              tarifaChofer: 200000,
            ),
            fechaCarga: DateTime(2026, 5, 12),
          ),
        ],
      );
      final adelantos = [
        adelantoDe(
            id: 'A1',
            fecha: DateTime(2026, 5, 1),
            monto: 100000,
            recibo: 79103),
        adelantoDe(id: 'A2', fecha: DateTime(2026, 5, 14), monto: 150000),
        adelantoDe(
            id: 'A3',
            dni: '456',
            nombre: 'ALTAMIRANDA RAUL',
            fecha: DateTime(2026, 5, 5),
            monto: 50000),
      ];

      final wb = ReportPlanillaChofer.construir(
        viajes: [viaje1, viaje2],
        adelantos: adelantos,
        empleados: const {
          '123': EmpleadoLiquidacion(
              dni: '123', nombre: 'DIAZ MARIO', empresaCuit: null),
          '456': EmpleadoLiquidacion(
              dni: '456', nombre: 'ALTAMIRANDA RAUL', empresaCuit: null),
        },
        mes: DateTime(2026, 5, 1),
        provincias: ResolverProvincias.vacio(),
      );
      final bytes = wb.excel.save();
      expect(bytes, isNotNull);
      relectura = ex.Excel.decodeBytes(bytes!);
    });

    test('estructura de hojas: CONSULTA primero + una por chofer', () {
      final hojas = relectura.sheets.keys.toList();
      expect(hojas.first, 'CONSULTA'); // hoja de dropdown va primera
      expect(hojas, contains('RESUMEN'));
      expect(hojas, contains('DIAZ MARIO'));
      expect(hojas, contains('ALTAMIRANDA RAUL'));
    });

    test('CONSULTA: dropdown en H1 + grilla espejada con INDIRECT', () {
      final s = relectura.sheets['CONSULTA']!;
      // H1 arranca con el primer chofer (alfabético) para que el
      // INDIRECT resuelva al abrir.
      expect(textoDe(s, 'H1'), 'ALTAMIRANDA RAUL');
      // La grilla espeja la hoja del chofer elegido vía INDIRECT.
      final fa = formulaDe(s, 'A4');
      expect(fa, contains('INDIRECT'));
      expect(fa, contains(r'$H$1'));
      // Columna helper S con los nombres EXACTOS de hoja (fuente del
      // dropdown), ordenados alfabéticamente.
      expect(textoDe(s, 'S1'), 'ALTAMIRANDA RAUL');
      expect(textoDe(s, 'S2'), 'DIAZ MARIO');
    });

    test('header del cuaderno: mes, año y chofer', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      expect(textoDe(s, 'A1'), 'CORRESPONDE A MES');
      expect(textoDe(s, 'C1'), 'MAYO');
      expect(textoDe(s, 'E1'), 'AÑO');
      expect(numeroDe(s, 'F1'), 2026);
      expect(textoDe(s, 'H1'), 'DIAZ MARIO');
    });

    test('fila de viaje TN: kg descargados, tarifa chofer y fórmulas', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      expect(textoDe(s, 'D4'), '02/05/2026');
      expect(textoDe(s, 'E4'), '291824');
      expect(textoDe(s, 'F4'), 'UREA');
      expect(textoDe(s, 'G4'), 'B.BLANCA'); // sin paréntesis de localidad
      expect(textoDe(s, 'I4'), 'NECOCHEA');
      expect(numeroDe(s, 'K4'), 34700); // descargados priorizan
      expect(numeroDe(s, 'L4'), 300); // dif = cargados − descargados
      expect(numeroDe(s, 'M4'), 58106); // base del cálculo del chofer
      expect(formulaDe(s, 'O4'), '(K4*M4*18%)/1000');
      expect(formulaDe(s, 'P4'), 'FLOOR(O4,5)');
      expect(numeroDe(s, 'Q4'), 11200);
    });

    test('tramo en curso: kg cargados como estimado', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      expect(numeroDe(s, 'K5'), 30000);
      expect(formulaDe(s, 'O5'), '(K5*M5*18%)/1000');
    });

    test('tramo con monto fijo: valor flat + FLOOR igual', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      expect(numeroDe(s, 'O6'), 100000);
      expect(formulaDe(s, 'P6'), 'FLOOR(O6,5)');
    });

    test('tramo por viaje: tarifa flat × pct sin kg', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      expect(numeroDe(s, 'M7'), 200000);
      expect(formulaDe(s, 'O7'), 'M7*18%');
    });

    test('adelantos en columnas A-C en paralelo a los viajes', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      expect(textoDe(s, 'A4'), '01/05/2026');
      expect(numeroDe(s, 'B4'), 79103);
      expect(numeroDe(s, 'C4'), 100000);
      expect(textoDe(s, 'A5'), '14/05/2026');
      expect(celda(s, 'B5'), isNull); // sin recibo asignado
      expect(numeroDe(s, 'C5'), 150000);
    });

    test('pie: cuentas de la planilla histórica con fórmulas vivas', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      // 4 filas de tramos y 2 adelantos → rige el mínimo de 12 filas
      // de datos: rango 4..15.
      final fBruto = filaConLabel(s, 'BRUTO');
      expect(formulaDe(s, 'C$fBruto'), 'SUM(P4:P15)');
      final fAdel = filaConLabel(s, 'ADELANTOS');
      expect(formulaDe(s, 'C$fAdel'), 'SUM(C4:C15)');
      final fNeto = filaConLabel(s, 'NETO');
      expect(formulaDe(s, 'C$fNeto'), 'C$fBruto-C$fAdel');
      final fGastos = filaConLabel(s, 'GASTOS');
      expect(formulaDe(s, 'C$fGastos'), 'SUM(Q4:Q15)');
      final fSubt = filaConLabel(s, 'SUB-TOTAL');
      expect(formulaDe(s, 'C$fSubt'), 'C$fNeto+C$fGastos');
      // Secciones manuales presentes.
      filaConLabel(s, 'OTROS VIAJES');
      filaConLabel(s, 'LIQUIDACION PARCIAL');
      filaConLabel(s, 'DESCUENTOS');
    });

    test('RESUMEN: fórmulas cross-sheet, FINAL y TOTAL', () {
      final s = relectura.sheets['RESUMEN']!;
      expect(textoDe(s, 'A2'), 'CHOFER');
      // Orden alfabético: ALTAMIRANDA primero.
      expect(textoDe(s, 'A3'), 'ALTAMIRANDA RAUL');
      expect(textoDe(s, 'B3'), '456');
      expect(formulaDe(s, 'C3'), "SUM('ALTAMIRANDA RAUL'!P4:P15)");
      expect(textoDe(s, 'A4'), 'DIAZ MARIO');
      expect(formulaDe(s, 'D4'), "SUM('DIAZ MARIO'!C4:C15)");
      expect(formulaDe(s, 'F4'), 'C4-D4+E4');
      // FACTURADO A EMPRESA: valor de la app (suma de montoVecchi).
      expect(numeroDe(s, 'G4'), 2082000 + 1800000);
      expect(textoDe(s, 'A5'), 'TOTAL');
      expect(formulaDe(s, 'C5'), 'SUM(C3:C4)');
      expect(formulaDe(s, 'G5'), 'SUM(G3:G4)');
    });

    test('chofer solo con adelantos genera hoja igual', () {
      final s = relectura.sheets['ALTAMIRANDA RAUL']!;
      expect(textoDe(s, 'A4'), '05/05/2026');
      expect(numeroDe(s, 'C4'), 50000);
      expect(celda(s, 'D4'), isNull); // sin viajes
    });
  });

  group('nombreHojaSeguro', () {
    test('saca caracteres inválidos para nombre de hoja', () {
      expect(
        ReportPlanillaChofer.nombreHojaSeguro("PE[RE]Z: *J/U\\AN?'", {}),
        'PE RE Z J U AN',
      );
    });

    test('recorta a 31 caracteres', () {
      final largo = 'A' * 40;
      expect(ReportPlanillaChofer.nombreHojaSeguro(largo, {}).length, 31);
    });

    test('vacío cae a CHOFER', () {
      expect(ReportPlanillaChofer.nombreHojaSeguro('***', {}), 'CHOFER');
    });

    test('colisiones agregan sufijo (case-insensitive)', () {
      final usados = {'DIAZ MARIO', 'RESUMEN'};
      expect(
        ReportPlanillaChofer.nombreHojaSeguro('Diaz Mario', usados),
        'Diaz Mario (2)',
      );
    });
  });

  group('refHoja', () {
    test('siempre entre comillas, escapando apóstrofes', () {
      expect(ReportPlanillaChofer.refHoja('DIAZ MARIO'), "'DIAZ MARIO'");
      expect(ReportPlanillaChofer.refHoja("D'ALESSANDRO"), "'D''ALESSANDRO'");
    });
  });

  group('stripParentesis', () {
    test('saca paréntesis y normaliza espacios', () {
      expect(
        ReportPlanillaChofer.stripParentesis('B.BLANCA (BAHIA BLANCA)'),
        'B.BLANCA',
      );
      expect(
        ReportPlanillaChofer.stripParentesis('ACA (LA BALLENERA) PUERTO'),
        'ACA PUERTO',
      );
    });
  });

  group('ResolverProvincias', () {
    final ubicaciones = [
      UbicacionLogistica.fromMap('U1', {
        'nombre': 'B.BLANCA',
        'localidad': 'Bahía Blanca',
        'provincia': 'Buenos Aires',
      }),
      UbicacionLogistica.fromMap('U2', {
        'nombre': 'AÑELO',
        'localidad': 'Añelo',
        'provincia': 'Neuquén',
      }),
    ];
    final tarifas = [
      TarifaLogistica.fromMap('T1', {
        'ubicacion_origen_id': 'U1',
        'ubicacion_destino_id': 'U2',
      }),
    ];
    final resolver =
        ResolverProvincias(tarifas: tarifas, ubicaciones: ubicaciones);

    TramoViaje tramoCon({required String tarifaId, String origen = 'X'}) {
      return TramoViaje(
        id: 't',
        tarifaId: tarifaId,
        tarifaSnapshot: snapTn(origen: origen),
      );
    }

    test('camino normal: tarifaId → ubicación → provincia abreviada', () {
      final t = tramoCon(tarifaId: 'T1');
      expect(resolver.origenDe(t), 'BS.AS');
      expect(resolver.destinoDe(t), 'NQN');
    });

    test('tarifa eliminada: fallback por etiqueta del snapshot', () {
      final t = tramoCon(
          tarifaId: 'NO_EXISTE', origen: 'B.BLANCA (BAHIA BLANCA)');
      expect(resolver.origenDe(t), 'BS.AS');
    });

    test('sin match → vacío (la columna queda en blanco)', () {
      final t = tramoCon(tarifaId: 'NO_EXISTE', origen: 'DESCONOCIDA');
      expect(resolver.origenDe(t), '');
      expect(ResolverProvincias.vacio().origenDe(t), '');
    });
  });

  group('abreviarProvincia', () {
    test('provincias frecuentes al estilo planilla vieja', () {
      expect(ResolverProvincias.abreviarProvincia('Buenos Aires'), 'BS.AS');
      expect(ResolverProvincias.abreviarProvincia('SANTA FE'), 'STA FE');
      expect(ResolverProvincias.abreviarProvincia('Neuquén'), 'NQN');
      expect(ResolverProvincias.abreviarProvincia('neuquen'), 'NQN');
      expect(ResolverProvincias.abreviarProvincia('Córdoba'), 'CBA');
      expect(ResolverProvincias.abreviarProvincia('La Pampa'), 'LA PAMPA');
    });

    test('saca el prefijo "Provincia de/del" (bug export 2026-06-10)', () {
      // Las ubicaciones cargan la provincia inconsistente; antes esto
      // daba el feo "Provinci" (recorte crudo a 8). Ahora resuelve bien.
      expect(ResolverProvincias.abreviarProvincia('Provincia de Buenos Aires'),
          'BS.AS');
      expect(
          ResolverProvincias.abreviarProvincia('Provincia del Neuquén'), 'NQN');
      expect(ResolverProvincias.abreviarProvincia('PROVINCIA DE SANTA FE'),
          'STA FE');
      expect(ResolverProvincias.abreviarProvincia('Provincia de La Pampa'),
          'LA PAMPA');
      expect(
          ResolverProvincias.abreviarProvincia('Provincia de Río Negro'),
          'RIO NEG.');
    });

    test('vacía → vacía; desconocida → title-case (no el crudo "Provinci")',
        () {
      expect(ResolverProvincias.abreviarProvincia(''), '');
      expect(ResolverProvincias.abreviarProvincia('  '), '');
      // Desconocida real: title-case recortado a 10, legible — nunca el
      // "Provinci" crudo del bug.
      final r = ResolverProvincias.abreviarProvincia('Algarrobistán');
      expect(r, isNot('Provinci'));
      expect(r.length, lessThanOrEqualTo(10));
      expect(r, 'Algarrobis');
    });
  });

  group('aplicarAutoFilterAlXlsx selectivo', () {
    List<int> workbookDePrueba() {
      final wb = ex.Excel.createExcel();
      wb.rename('Sheet1', 'UNO');
      for (final nombre in ['UNO', 'DOS', 'TRES']) {
        wb[nombre]
            .cell(ex.CellIndex.indexByString('A1'))
            .value = ex.TextCellValue('header');
      }
      return wb.save()!;
    }

    int contarAutoFilters(List<int> bytes) {
      final archive = ZipDecoder().decodeBytes(bytes);
      var total = 0;
      for (final f in archive.files) {
        if (f.isFile && RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name)) {
          final xml = utf8.decode(f.content as List<int>);
          if (xml.contains('<autoFilter ')) total++;
        }
      }
      return total;
    }

    test('sin filtro: todas las hojas (comportamiento histórico)', () {
      expect(contarAutoFilters(xu.aplicarAutoFilterAlXlsx(workbookDePrueba())),
          3);
    });

    test('soloHojas limita la inyección a las hojas pedidas', () {
      final bytes = xu.aplicarAutoFilterAlXlsx(
        workbookDePrueba(),
        soloHojas: {'DOS'},
      );
      expect(contarAutoFilters(bytes), 1);
    });

    test('hoja inexistente: no se inyecta nada', () {
      final bytes = xu.aplicarAutoFilterAlXlsx(
        workbookDePrueba(),
        soloHojas: {'NO_EXISTE'},
      );
      expect(contarAutoFilters(bytes), 0);
    });
  });

  group('configurarConsultaYOcultarHojas', () {
    List<int> workbookConConsulta() {
      final wb = ex.Excel.createExcel();
      wb.rename('Sheet1', 'CONSULTA');
      for (final nombre in ['CONSULTA', 'CHOFER A', 'CHOFER B', 'RESUMEN']) {
        wb[nombre]
            .cell(ex.CellIndex.indexByString('A1'))
            .value = ex.TextCellValue('x');
      }
      return wb.save()!;
    }

    String workbookXml(List<int> bytes) {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final f in archive.files) {
        if (f.isFile && f.name == 'xl/workbook.xml') {
          return utf8.decode(f.content as List<int>);
        }
      }
      fail('no se encontró xl/workbook.xml');
    }

    int contarDataValidations(List<int> bytes) {
      final archive = ZipDecoder().decodeBytes(bytes);
      var total = 0;
      for (final f in archive.files) {
        if (f.isFile &&
            RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name)) {
          final xml = utf8.decode(f.content as List<int>);
          if (xml.contains('<dataValidations')) total++;
        }
      }
      return total;
    }

    test('oculta las hojas pedidas y deja visibles CONSULTA + RESUMEN', () {
      final bytes = xu.configurarConsultaYOcultarHojas(
        workbookConConsulta(),
        hojaConsulta: 'CONSULTA',
        celdaDropdown: 'H1',
        cantidadChoferes: 2,
        hojasAOcultar: {'CHOFER A', 'CHOFER B'},
      );
      final xml = workbookXml(bytes);
      // Las dos de chofer ocultas...
      expect(
        RegExp(r'<sheet state="hidden" name="CHOFER A"').hasMatch(xml),
        isTrue,
      );
      expect(
        RegExp(r'<sheet state="hidden" name="CHOFER B"').hasMatch(xml),
        isTrue,
      );
      // ...CONSULTA y RESUMEN NO.
      expect(
        RegExp(r'<sheet state="hidden" name="CONSULTA"').hasMatch(xml),
        isFalse,
      );
      expect(
        RegExp(r'<sheet state="hidden" name="RESUMEN"').hasMatch(xml),
        isFalse,
      );
    });

    test('agrega la data validation (dropdown) solo en CONSULTA', () {
      final bytes = xu.configurarConsultaYOcultarHojas(
        workbookConConsulta(),
        hojaConsulta: 'CONSULTA',
        celdaDropdown: 'H1',
        cantidadChoferes: 2,
        hojasAOcultar: {'CHOFER A', 'CHOFER B'},
      );
      // Exactamente 1 hoja con dataValidations.
      expect(contarDataValidations(bytes), 1);
      // Con el rango correcto S1:S{N} y la celda H1.
      final archive = ZipDecoder().decodeBytes(bytes);
      final consultaFile = archive.files.firstWhere(
        (f) =>
            f.isFile &&
            RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name) &&
            utf8.decode(f.content as List<int>).contains('<dataValidations'),
      );
      final xml = utf8.decode(consultaFile.content as List<int>);
      expect(xml, contains('sqref="H1"'));
      expect(xml, contains(r'<formula1>$S$1:$S$2</formula1>'));
      expect(xml, contains('type="list"'));
    });

    test('cantidadChoferes 0 → no toca nada (defensivo)', () {
      final original = workbookConConsulta();
      final bytes = xu.configurarConsultaYOcultarHojas(
        original,
        hojaConsulta: 'CONSULTA',
        celdaDropdown: 'H1',
        cantidadChoferes: 0,
        hojasAOcultar: {'CHOFER A'},
      );
      expect(bytes, original);
    });
  });
}
