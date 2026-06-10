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
  EstadoViaje estado = EstadoViaje.concluido,
}) {
  return Viaje(
    id: id,
    tramos: tramos,
    choferDni: dni,
    choferNombre: nombre,
    estado: estado,
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
      // V3 EN CURSO → va a la sección OTROS VIAJES (especulación), no a
      // la grilla principal. Su facturado NO suma al RESUMEN (solo
      // cuentan los concluidos).
      final viaje3 = viajeDe(
        id: 'V3',
        estado: EstadoViaje.enCurso,
        montoVecchi: 900000,
        tramos: [
          TramoViaje(
            id: 't3',
            tarifaId: 'T1',
            tarifaSnapshot: snapTn(tarifaChofer: 60000),
            producto: 'MAIZ',
            fechaCarga: DateTime(2026, 5, 18),
            kgCargados: 33000,
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
        viajes: [viaje1, viaje2, viaje3],
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

    // Layout rediseñado 2026-06-10: 15 columnas (A-O), una sola
    // GANANCIA (N), dropdown en G1, pie compacto. nDatos uniforme =
    // max(contenido)+margen con piso 6. Fixture: DIAZ tiene 4 filas de
    // viaje → maxContenido 4 → nDatos 6 → filaDatosFin 9.

    test('CONSULTA: dropdown en G1 + grilla espejada con INDIRECT', () {
      final s = relectura.sheets['CONSULTA']!;
      // G1 arranca con el primer chofer (alfabético) para que el
      // INDIRECT resuelva al abrir.
      expect(textoDe(s, 'G1'), 'ALTAMIRANDA RAUL');
      final fa = formulaDe(s, 'A4');
      expect(fa, contains('INDIRECT'));
      expect(fa, contains(r'$G$1'));
      // Columna helper S con los nombres EXACTOS de hoja (fuente del
      // dropdown), ordenados alfabéticamente.
      expect(textoDe(s, 'S1'), 'ALTAMIRANDA RAUL');
      expect(textoDe(s, 'S2'), 'DIAZ MARIO');
    });

    test('header del cuaderno: MES y CHOFER', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      expect(textoDe(s, 'A1'), 'MES: MAYO 2026');
      expect(textoDe(s, 'F1'), 'CHOFER:');
      expect(textoDe(s, 'G1'), 'DIAZ MARIO');
      // Súper-header de secciones + headers de columna clave.
      expect(textoDe(s, 'A2'), 'ADELANTOS');
      expect(textoDe(s, 'D2'), 'VIAJES');
      expect(textoDe(s, 'N3'), 'GANANCIA');
      expect(textoDe(s, 'O3'), 'GASTOS');
    });

    test('fila de viaje TN: kg, tarifa y GANANCIA (col N, ya redondeada)',
        () {
      final s = relectura.sheets['DIAZ MARIO']!;
      expect(textoDe(s, 'D4'), '02/05/2026');
      expect(textoDe(s, 'E4'), '291824');
      expect(textoDe(s, 'F4'), 'UREA');
      expect(textoDe(s, 'G4'), 'B.BLANCA'); // sin paréntesis de localidad
      expect(textoDe(s, 'I4'), 'NECOCHEA');
      expect(numeroDe(s, 'K4'), 34700); // descargados priorizan
      expect(numeroDe(s, 'L4'), 300); // dif = cargados − descargados
      expect(numeroDe(s, 'M4'), 58106); // base del cálculo del chofer
      // Una sola columna GANANCIA con el FLOOR ya aplicado.
      expect(formulaDe(s, 'N4'), 'FLOOR((K4*M4*18%)/1000,5)');
      expect(numeroDe(s, 'O4'), 11200); // gastos
    });

    test('tramo en curso: kg cargados como estimado', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      expect(numeroDe(s, 'K5'), 30000);
      expect(formulaDe(s, 'N5'), 'FLOOR((K5*M5*18%)/1000,5)');
    });

    test('tramo con monto fijo: valor flat redondeado en N', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      expect(numeroDe(s, 'N6'), 100000);
    });

    test('tramo por viaje: FLOOR(tarifa × pct) sin kg', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      expect(numeroDe(s, 'M7'), 200000);
      expect(formulaDe(s, 'N7'), 'FLOOR(M7*18%,5)');
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

    test('separación: el viaje EN CURSO va a OTROS VIAJES, no arriba', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      // Grilla principal (4..9) = solo CONCLUIDOS (4 tramos: V1 + V2x3).
      // V3 (en curso, MAIZ) NO está arriba.
      for (var f = 4; f <= 9; f++) {
        expect(textoDe(s, 'F$f'), isNot('MAIZ'));
      }
      // Sección OTROS VIAJES: título en fila 11, datos desde 12.
      expect(textoDe(s, 'A11'), 'OTROS VIAJES (EN CURSO / PLANEADOS)');
      expect(textoDe(s, 'F12'), 'MAIZ'); // el en curso, abajo
      expect(formulaDe(s, 'N12'), 'FLOOR((K12*M12*18%)/1000,5)');
    });

    test('pie: NETO firme (concluidos) + OTROS = TOTAL ESTIMADO', () {
      final s = relectura.sheets['DIAZ MARIO']!;
      // filaDatosFin=9; OTROS 12..14; pie desde 16.
      final fGan = filaConLabel(s, 'GANANCIA VIAJES');
      expect(formulaDe(s, 'C$fGan'), 'SUM(N4:N9)'); // solo concluidos
      final fAdel = filaConLabel(s, 'ADELANTOS (−)');
      expect(formulaDe(s, 'C$fAdel'), 'SUM(C4:C9)');
      final fGastos = filaConLabel(s, 'GASTOS (+)');
      expect(formulaDe(s, 'C$fGastos'), 'SUM(O4:O9)');
      final fNeto = filaConLabel(s, 'NETO A PAGAR');
      expect(formulaDe(s, 'C$fNeto'), 'C$fGan-C$fAdel+C$fGastos');
      // Especulación: ganancia de OTROS VIAJES (12..14).
      final fOtros = filaConLabel(s, 'OTROS VIAJES (+)');
      expect(formulaDe(s, 'C$fOtros'), 'SUM(N12:N14)');
      final fTotal = filaConLabel(s, 'TOTAL ESTIMADO');
      expect(formulaDe(s, 'C$fTotal'), 'C$fNeto+C$fOtros');
    });

    test('RESUMEN: firme (FINAL) + especulación (OTROS / TOTAL EST.)', () {
      final s = relectura.sheets['RESUMEN']!;
      expect(textoDe(s, 'A2'), 'CHOFER');
      expect(textoDe(s, 'F2'), 'FINAL');
      expect(textoDe(s, 'G2'), 'OTROS VIAJES');
      expect(textoDe(s, 'H2'), 'TOTAL EST.');
      // DIAZ en fila 4 (ALTAMIRANDA primero, alfabético).
      expect(textoDe(s, 'A4'), 'DIAZ MARIO');
      expect(formulaDe(s, 'C4'), "SUM('DIAZ MARIO'!N4:N9)"); // bruto concluidos
      expect(formulaDe(s, 'E4'), "SUM('DIAZ MARIO'!O4:O9)"); // gastos
      expect(formulaDe(s, 'F4'), 'C4-D4+E4'); // FINAL firme
      expect(formulaDe(s, 'G4'), "SUM('DIAZ MARIO'!N12:N14)"); // otros
      expect(formulaDe(s, 'H4'), 'F4+G4'); // total estimado
      // FACTURADO (col I ahora) = solo concluidos.
      expect(numeroDe(s, 'I4'), 2082000 + 1800000);
      expect(textoDe(s, 'A5'), 'TOTAL');
      expect(formulaDe(s, 'H5'), 'SUM(H3:H4)');
    });

    test('chofer solo con adelantos genera hoja igual', () {
      final s = relectura.sheets['ALTAMIRANDA RAUL']!;
      expect(textoDe(s, 'A4'), '05/05/2026');
      expect(numeroDe(s, 'C4'), 50000);
      expect(celda(s, 'D4'), isNull); // sin viajes
    });
  });

  group('construir — padrón completo', () {
    test('un chofer del padrón sin actividad genera hoja vacía + dropdown',
        () {
      // PADRÓN con 3 choferes; solo 1 tiene un viaje. Los otros 2 deben
      // tener hoja igual (pedido Santiago 2026-06-10: todos los choferes
      // para cargar la especulación).
      final wb = ReportPlanillaChofer.construir(
        viajes: [
          viajeDe(
            id: 'V1',
            dni: '111',
            nombre: 'ACTIVO UNO',
            tramos: [
              TramoViaje(
                id: 't',
                tarifaId: 'T1',
                tarifaSnapshot: snapTn(),
                fechaCarga: DateTime(2026, 6, 2),
                kgCargados: 30000,
                kgDescargados: 30000,
              ),
            ],
          ),
        ],
        adelantos: const [],
        empleados: const {
          '111': EmpleadoLiquidacion(
              dni: '111', nombre: 'ACTIVO UNO', empresaCuit: null),
          '222': EmpleadoLiquidacion(
              dni: '222', nombre: 'SIN NADA DOS', empresaCuit: null),
          '333': EmpleadoLiquidacion(
              dni: '333', nombre: 'SIN NADA TRES', empresaCuit: null),
        },
        mes: DateTime(2026, 6, 1),
        provincias: ResolverProvincias.vacio(),
        dnisPadron: {'111', '222', '333'},
      );
      final wbDec = ex.Excel.decodeBytes(wb.excel.save()!);
      // Las 3 hojas existen (aunque 2 estén vacías).
      expect(wbDec.sheets.keys, contains('ACTIVO UNO'));
      expect(wbDec.sheets.keys, contains('SIN NADA DOS'));
      expect(wbDec.sheets.keys, contains('SIN NADA TRES'));
      expect(wb.cantidadChoferes, 3);
      // El dropdown (columna helper S de CONSULTA) lista a los 3.
      final consulta = wbDec.sheets['CONSULTA']!;
      final s = [
        for (var i = 1; i <= 3; i++)
          consulta
              .cell(ex.CellIndex.indexByString('S$i'))
              .value
              .toString()
      ];
      expect(s, containsAll(['ACTIVO UNO', 'SIN NADA DOS', 'SIN NADA TRES']));
      // La hoja vacía no tiene viajes ni adelantos en la grilla.
      final vacia = wbDec.sheets['SIN NADA DOS']!;
      expect(vacia.cell(ex.CellIndex.indexByString('A4')).value, isNull);
      expect(vacia.cell(ex.CellIndex.indexByString('D4')).value, isNull);
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
