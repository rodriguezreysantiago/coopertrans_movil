// Tests del versionado de tarifas por DOS vigencias independientes (real +
// chofer), 2026-06-11.
//
// Foco: la composición del precio por FECHA DE CARGA con líneas separadas
// (`vigenteEn`), la migración perezosa (formato nuevo, formato viejo combinado
// EN PRODUCCIÓN, y pre-versionado), la derivación FIEL del `vigencias`
// combinado (compat con apps viejas que solo entienden ese array), y la
// composición que usan los recálculos masivos (`conTarifaReal` / `conTarifaChofer`
// sobre el snapshot del tramo). Maneja PLATA — un bug acá liquida de más o de
// menos.
//
// Los recálculos end-to-end (filtro `liquidado`, WriteBatch) usan
// FirebaseFirestore.instance y se validan en smoke manual; acá testeamos la
// lógica PURA que componen (patrón del proyecto: extraer la lógica del I/O).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/logistica/models/tarifa_logistica.dart';
import 'package:coopertrans_movil/features/logistica/models/viaje.dart';

/// Construye una tarifa con las dos líneas de vigencia dadas (los campos
/// planos solo importan para el fallback defensivo de `vigenteEn`).
TarifaLogistica _tarifa({
  List<VigenciaReal> vigenciasReal = const [],
  List<VigenciaChofer> vigenciasChofer = const [],
  TipoCargaLogistica tipoCarga = TipoCargaLogistica.propia,
  UnidadTarifa unidad = UnidadTarifa.porTonelada,
  double tarifaRealPlana = 0,
  double tarifaChoferPlana = 0,
  int? km,
}) {
  return TarifaLogistica(
    id: 'T1',
    tipoCarga: tipoCarga,
    empresaOrigenId: 'eo',
    empresaOrigenNombre: 'ORIGEN SA',
    ubicacionOrigenId: 'uo',
    ubicacionOrigenEtiqueta: 'Bahía Blanca',
    empresaDestinoId: 'ed',
    empresaDestinoNombre: 'DESTINO SA',
    ubicacionDestinoId: 'ud',
    ubicacionDestinoEtiqueta: 'Olavarría',
    km: km,
    flete: FleteLogistica.origen,
    unidadTarifa: unidad,
    tarifaReal: tarifaRealPlana,
    tarifaChofer: tarifaChoferPlana,
    vigenciasReal: vigenciasReal,
    vigenciasChofer: vigenciasChofer,
  );
}

VigenciaReal _vReal(
  DateTime desde, {
  double real = 100,
  double? comisionDador,
  double? montoFijoDador,
}) {
  return VigenciaReal(
    desde: desde,
    tarifaReal: real,
    porcentajeComisionDador: comisionDador,
    montoFijoDador: montoFijoDador,
  );
}

VigenciaChofer _vChofer(
  DateTime desde, {
  double chofer = 40,
  double? montoFijoChofer,
}) {
  return VigenciaChofer(
    desde: desde,
    tarifaChofer: chofer,
    montoFijoChofer: montoFijoChofer,
  );
}

const _snapBase = TarifaSnapshot(
  origenEtiqueta: 'o',
  destinoEtiqueta: 'd',
  empresaOrigenNombre: 'O',
  empresaDestinoNombre: 'D',
  unidadTarifa: UnidadTarifa.porTonelada,
  tarifaReal: 100,
  tarifaChofer: 40,
);

void main() {
  group('VigenciaReal/VigenciaChofer.desde — normalización a día', () {
    test('el constructor trunca la hora a medianoche', () {
      expect(_vReal(DateTime(2026, 1, 15, 8, 30, 59)).desde,
          DateTime(2026, 1, 15));
      expect(_vChofer(DateTime(2026, 1, 15, 23, 59)).desde,
          DateTime(2026, 1, 15));
    });
  });

  group('TarifaLogistica.vigenteEn — composición real + chofer', () {
    final t = _tarifa(
      vigenciasReal: [
        _vReal(DateTime(2026, 1, 1), real: 100),
        _vReal(DateTime(2026, 1, 15), real: 120),
      ],
      vigenciasChofer: [
        _vChofer(DateTime(2026, 1, 1), chofer: 40),
        _vChofer(DateTime(2026, 1, 15), chofer: 48),
      ],
    );

    test('fecha entre dos vigencias toma la anterior vigente (ambos lados)',
        () {
      final v = t.vigenteEn(DateTime(2026, 1, 10));
      expect(v.tarifaReal, 100);
      expect(v.tarifaChofer, 40);
    });

    test('fecha posterior a la última toma la última', () {
      expect(t.vigenteEn(DateTime(2026, 1, 20)).tarifaReal, 120);
      expect(t.vigenteEn(DateTime(2026, 1, 20)).tarifaChofer, 48);
    });

    test('fecha exacta de una vigencia la toma a ella (no la anterior)', () {
      expect(t.vigenteEn(DateTime(2026, 1, 15)).tarifaReal, 120);
      expect(t.vigenteEn(DateTime(2026, 1, 15)).tarifaChofer, 48);
    });

    test('fecha anterior a la primera vigencia devuelve la primera', () {
      expect(t.vigenteEn(DateTime(2025, 12, 1)).tarifaReal, 100);
      expect(t.vigenteEn(DateTime(2025, 12, 1)).tarifaChofer, 40);
    });

    test('normaliza la fecha a día (hora no corre el límite)', () {
      expect(t.vigenteEn(DateTime(2026, 1, 14, 23, 59)).tarifaReal, 100);
      expect(t.vigenteEn(DateTime(2026, 1, 15, 0, 0)).tarifaReal, 120);
    });

    test('vigencia FUTURA no se aplica a fechas presentes', () {
      final tf = _tarifa(
        vigenciasReal: [
          _vReal(DateTime(2026, 1, 1), real: 100),
          _vReal(DateTime(2030, 1, 1), real: 200),
        ],
      );
      expect(tf.vigenteEn(DateTime(2026, 6, 4)).tarifaReal, 100);
    });

    test('una sola vigencia por lado: cualquier fecha la devuelve', () {
      final t1 = _tarifa(
        vigenciasReal: [_vReal(DateTime(2026, 3, 1), real: 77)],
        vigenciasChofer: [_vChofer(DateTime(2026, 3, 1), chofer: 33)],
      );
      expect(t1.vigenteEn(DateTime(2026, 1, 1)).tarifaReal, 77);
      expect(t1.vigenteEn(DateTime(2026, 12, 31)).tarifaChofer, 33);
    });

    test('robusto a desorden de las listas', () {
      final td = _tarifa(
        vigenciasReal: [
          _vReal(DateTime(2026, 3, 1), real: 200),
          _vReal(DateTime(2026, 1, 1), real: 100),
        ],
        vigenciasChofer: [_vChofer(DateTime(2026, 1, 1), chofer: 40)],
      );
      expect(td.vigenteEn(DateTime(2026, 2, 1)).tarifaReal, 100);
      expect(td.vigenteEn(DateTime(2026, 3, 15)).tarifaReal, 200);
    });

    test('listas vacías: fallback defensivo a los campos planos', () {
      final tv = _tarifa(tarifaRealPlana: 55, tarifaChoferPlana: 22);
      final v = tv.vigenteEn(DateTime(2026, 1, 1));
      expect(v.tarifaReal, 55);
      expect(v.tarifaChofer, 22);
    });

    test('REAL y CHOFER con FECHAS INDEPENDIENTES se componen por separado',
        () {
      // El caso que justifica todo el feature: real sube el 1/3 y el 10/3;
      // chofer sube SOLO el 5/3.
      final ti = _tarifa(
        vigenciasReal: [
          _vReal(DateTime(2026, 3, 1), real: 100),
          _vReal(DateTime(2026, 3, 10), real: 120),
        ],
        vigenciasChofer: [
          _vChofer(DateTime(2026, 3, 1), chofer: 40),
          _vChofer(DateTime(2026, 3, 5), chofer: 48),
        ],
      );
      // 3/3 → real 100 (1/3) + chofer 40 (1/3)
      final v3 = ti.vigenteEn(DateTime(2026, 3, 3));
      expect(v3.tarifaReal, 100);
      expect(v3.tarifaChofer, 40);
      // 6/3 → real 100 (1/3) + chofer 48 (5/3)
      final v6 = ti.vigenteEn(DateTime(2026, 3, 6));
      expect(v6.tarifaReal, 100);
      expect(v6.tarifaChofer, 48);
      expect(v6.desdeReal, DateTime(2026, 3, 1));
      expect(v6.desdeChofer, DateTime(2026, 3, 5));
      // 11/3 → real 120 (10/3) + chofer 48 (5/3)
      final v11 = ti.vigenteEn(DateTime(2026, 3, 11));
      expect(v11.tarifaReal, 120);
      expect(v11.tarifaChofer, 48);
    });
  });

  group('TarifaLogistica.fromMap — migración perezosa (a) > (b) > (c)', () {
    test('(c) doc SIN vigencias sintetiza 1 real + 1 chofer de los planos', () {
      final t = TarifaLogistica.fromMap('X', {
        'tipo_carga': 'PROPIA',
        'empresa_origen_id': 'eo',
        'tarifa_real': 100.0,
        'tarifa_chofer': 40.0,
        'unidad_tarifa': 'TN',
        'flete': 'ORIGEN',
        'vigente_desde': Timestamp.fromDate(DateTime(2026, 1, 1)),
      });
      expect(t.vigenciasReal.length, 1);
      expect(t.vigenciasChofer.length, 1);
      expect(t.vigenciasReal.first.tarifaReal, 100);
      expect(t.vigenciasChofer.first.tarifaChofer, 40);
      expect(t.vigenciasReal.first.desde, DateTime(2026, 1, 1));
    });

    test('(b) formato VIEJO combinado se descompone en las dos líneas', () {
      final t = TarifaLogistica.fromMap('X', {
        'tipo_carga': 'TERCEROS',
        'unidad_tarifa': 'TN',
        'flete': 'ORIGEN',
        // Desordenadas a propósito.
        'vigencias': [
          TarifaVigencia(
                  desde: DateTime(2026, 2, 1), tarifaReal: 120, tarifaChofer: 50)
              .toMap(),
          TarifaVigencia(
            desde: DateTime(2026, 1, 1),
            tarifaReal: 100,
            tarifaChofer: 40,
            porcentajeComisionDador: 12.5,
          ).toMap(),
        ],
      });
      expect(t.vigenciasReal.length, 2);
      expect(t.vigenciasChofer.length, 2);
      // Ordenadas asc por desde.
      expect(t.vigenciasReal.first.desde, DateTime(2026, 1, 1));
      expect(t.vigenciasReal.first.tarifaReal, 100);
      // El dador queda del lado real.
      expect(t.vigenciasReal.first.porcentajeComisionDador, 12.5);
      expect(t.vigenciasChofer.first.tarifaChofer, 40);
      // Mismas fechas en ambas líneas.
      expect(t.vigenciasChofer.last.desde, DateTime(2026, 2, 1));
    });

    test('(a) el formato nuevo GANA sobre el viejo combinado si conviven', () {
      final t = TarifaLogistica.fromMap('X', {
        'tipo_carga': 'PROPIA',
        'unidad_tarifa': 'TN',
        'flete': 'ORIGEN',
        'vigencias_real': [_vReal(DateTime(2026, 3, 1), real: 999).toMap()],
        'vigencias_chofer': [_vChofer(DateTime(2026, 3, 1), chofer: 111).toMap()],
        // Combinado viejo con otros valores → debe ignorarse.
        'vigencias': [
          TarifaVigencia(
                  desde: DateTime(2026, 1, 1), tarifaReal: 1, tarifaChofer: 1)
              .toMap(),
        ],
      });
      expect(t.vigenciasReal.length, 1);
      expect(t.vigenciasReal.first.tarifaReal, 999);
      expect(t.vigenciasChofer.first.tarifaChofer, 111);
    });

    test('(a) parsea ordenado asc por desde', () {
      final t = TarifaLogistica.fromMap('X', {
        'tipo_carga': 'PROPIA',
        'unidad_tarifa': 'TN',
        'flete': 'ORIGEN',
        'vigencias_real': [
          _vReal(DateTime(2026, 3, 1), real: 200).toMap(),
          _vReal(DateTime(2026, 1, 1), real: 100).toMap(),
        ],
      });
      expect(t.vigenciasReal.first.desde, DateTime(2026, 1, 1));
      expect(t.vigenciasReal.last.desde, DateTime(2026, 3, 1));
    });
  });

  group('TarifaLogistica.toMap — vigencias_real/chofer + derivado combinado',
      () {
    test('escribe las dos líneas + un `vigencias` combinado', () {
      final t = _tarifa(
        vigenciasReal: [_vReal(DateTime(2026, 1, 1), real: 100)],
        vigenciasChofer: [_vChofer(DateTime(2026, 1, 1), chofer: 40)],
      );
      final map = t.toMap();
      expect(map['vigencias_real'], isA<List>());
      expect(map['vigencias_chofer'], isA<List>());
      expect(map['vigencias'], isA<List>());
      // Round-trip por el formato nuevo conserva.
      final t2 = TarifaLogistica.fromMap('X', map);
      expect(t2.vigenciasReal.length, 1);
      expect(t2.vigenciasChofer.length, 1);
      expect(t2.vigenciasReal.first.tarifaReal, 100);
    });

    test('el `vigencias` derivado es FIEL (app vieja resuelve igual)', () {
      final t = _tarifa(
        vigenciasReal: [
          _vReal(DateTime(2026, 3, 1), real: 100),
          _vReal(DateTime(2026, 3, 10), real: 120),
        ],
        vigenciasChofer: [_vChofer(DateTime(2026, 3, 5), chofer: 48)],
      );
      final comb = t.toMap()['vigencias'] as List;
      // Unión de fechas: 1/3, 5/3, 10/3.
      expect(comb.length, 3);
      // Simular "app vieja": parsear SOLO `vigencias` (formato (b)).
      final vieja = TarifaLogistica.fromMap('X', {
        'tipo_carga': 'PROPIA',
        'unidad_tarifa': 'TN',
        'flete': 'ORIGEN',
        'vigencias': comb,
      });
      for (final f in [
        DateTime(2026, 2, 1),
        DateTime(2026, 3, 3),
        DateTime(2026, 3, 6),
        DateTime(2026, 3, 15),
      ]) {
        expect(vieja.vigenteEn(f).tarifaReal, t.vigenteEn(f).tarifaReal,
            reason: 'real en $f');
        expect(vieja.vigenteEn(f).tarifaChofer, t.vigenteEn(f).tarifaChofer,
            reason: 'chofer en $f');
      }
    });

    test('el derivado deduplica cuando ambos lados cambian el mismo día', () {
      final t = _tarifa(
        vigenciasReal: [
          _vReal(DateTime(2026, 3, 1), real: 100),
          _vReal(DateTime(2026, 3, 10), real: 120),
        ],
        vigenciasChofer: [
          _vChofer(DateTime(2026, 3, 1), chofer: 40),
          _vChofer(DateTime(2026, 3, 10), chofer: 50),
        ],
      );
      final comb = t.toMap()['vigencias'] as List;
      expect(comb.length, 2); // 1/3 y 10/3, sin duplicar
    });
  });

  group('TarifaSnapshot.fromTarifaEnFecha', () {
    final t = _tarifa(
      vigenciasReal: [
        _vReal(DateTime(2026, 1, 1), real: 100),
        _vReal(DateTime(2026, 1, 15), real: 120),
      ],
      vigenciasChofer: [
        _vChofer(DateTime(2026, 1, 1), chofer: 40),
        _vChofer(DateTime(2026, 1, 15), chofer: 48),
      ],
    );

    test('toma los importes de la vigencia de la fecha dada', () {
      final s1 = TarifaSnapshot.fromTarifaEnFecha(t, DateTime(2026, 1, 10));
      expect(s1.tarifaReal, 100);
      expect(s1.tarifaChofer, 40);
      final s2 = TarifaSnapshot.fromTarifaEnFecha(t, DateTime(2026, 1, 20));
      expect(s2.tarifaReal, 120);
      expect(s2.tarifaChofer, 48);
    });

    test('conserva los campos NO versionados (ruta/empresas)', () {
      final s = TarifaSnapshot.fromTarifaEnFecha(t, DateTime(2026, 1, 10));
      expect(s.origenEtiqueta, 'Bahía Blanca');
      expect(s.destinoEtiqueta, 'Olavarría');
      expect(s.empresaOrigenNombre, 'ORIGEN SA');
    });
  });

  group('TarifaSnapshot.conTarifaReal — preserva el chofer', () {
    test('cambia SOLO la real; preserva chofer/dador/no-versionados', () {
      const original = TarifaSnapshot(
        origenEtiqueta: 'Bahía Blanca',
        destinoEtiqueta: 'Olavarría',
        empresaOrigenNombre: 'ORIGEN SA',
        empresaDestinoNombre: 'DESTINO SA',
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 100,
        tarifaChofer: 40,
        montoFijoChofer: 999000, // override acordado a mano
        porcentajeComisionDador: 12.5,
        producto: 'ARENA',
        dadorNombre: 'DADOR SRL',
      );
      final nuevo = original.conTarifaReal(120);
      expect(nuevo.tarifaReal, 120);
      expect(nuevo.tarifaChofer, 40);
      expect(nuevo.montoFijoChofer, 999000);
      expect(nuevo.porcentajeComisionDador, 12.5);
      expect(nuevo.producto, 'ARENA');
      expect(nuevo.dadorNombre, 'DADOR SRL');
    });
  });

  group('TarifaSnapshot.conTarifaChofer — preserva la real, pisa el chofer',
      () {
    const original = TarifaSnapshot(
      origenEtiqueta: 'o',
      destinoEtiqueta: 'd',
      empresaOrigenNombre: 'O',
      empresaDestinoNombre: 'D',
      unidadTarifa: UnidadTarifa.porTonelada,
      tarifaReal: 100,
      tarifaChofer: 40,
      porcentajeComisionDador: 12.5,
      dadorNombre: 'DADOR',
      producto: 'ARENA',
    );

    test('cambia chofer + montoFijoChofer; preserva real/dador/no-versionados',
        () {
      final n = original.conTarifaChofer(tarifaChofer: 50, montoFijoChofer: null);
      expect(n.tarifaChofer, 50);
      expect(n.montoFijoChofer, isNull);
      expect(n.tarifaReal, 100);
      expect(n.porcentajeComisionDador, 12.5);
      expect(n.producto, 'ARENA');
      expect(n.dadorNombre, 'DADOR');
    });

    test('cambio de modo: de porcentaje a monto fijo', () {
      final n =
          original.conTarifaChofer(tarifaChofer: 0, montoFijoChofer: 555000);
      expect(n.montoFijoChofer, 555000);
      expect(n.tarifaChofer, 0);
    });

    test('cambio de modo: de monto fijo a porcentaje (limpia el fijo)', () {
      const conFijo = TarifaSnapshot(
        origenEtiqueta: 'o',
        destinoEtiqueta: 'd',
        empresaOrigenNombre: 'O',
        empresaDestinoNombre: 'D',
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 100,
        tarifaChofer: 0,
        montoFijoChofer: 555000,
      );
      final n = conFijo.conTarifaChofer(tarifaChofer: 40, montoFijoChofer: null);
      expect(n.montoFijoChofer, isNull);
      expect(n.tarifaChofer, 40);
    });

    test('PISA un override manual preexistente (decisión Santiago)', () {
      const conOverride = TarifaSnapshot(
        origenEtiqueta: 'o',
        destinoEtiqueta: 'd',
        empresaOrigenNombre: 'O',
        empresaDestinoNombre: 'D',
        unidadTarifa: UnidadTarifa.porTonelada,
        tarifaReal: 100,
        tarifaChofer: 40,
        montoFijoChofer: 777000, // ajuste a mano
      );
      final n = conOverride.conTarifaChofer(tarifaChofer: 45, montoFijoChofer: null);
      expect(n.montoFijoChofer, isNull); // override pisado
      expect(n.tarifaChofer, 45);
    });
  });

  group('Composición de los recálculos masivos (pura)', () {
    final t = _tarifa(
      vigenciasReal: [
        _vReal(DateTime(2026, 1, 1), real: 100),
        _vReal(DateTime(2026, 1, 15), real: 120),
      ],
      vigenciasChofer: [
        _vChofer(DateTime(2026, 1, 1), chofer: 40),
        _vChofer(DateTime(2026, 1, 15), chofer: 48),
      ],
    );

    test('recálculo REAL: 1ª quincena conserva la real vieja, chofer intacta',
        () {
      final vig = t.vigenteEn(DateTime(2026, 1, 10)); // real 100
      final nuevo = _snapBase.conTarifaReal(vig.tarifaReal);
      expect(nuevo.tarifaReal, 100);
      expect(nuevo.tarifaChofer, 40);
    });

    test('recálculo REAL: 2ª quincena sube la real, la chofer NO cambia', () {
      final vig = t.vigenteEn(DateTime(2026, 1, 20)); // real 120
      final nuevo = _snapBase.conTarifaReal(vig.tarifaReal);
      expect(nuevo.tarifaReal, 120);
      expect(nuevo.tarifaChofer, 40); // la del snapshot, NO 48
    });

    test('recálculo CHOFER: 2ª quincena sube el chofer, la real NO cambia', () {
      final vig = t.vigenteEn(DateTime(2026, 1, 20)); // chofer 48
      final nuevo = _snapBase.conTarifaChofer(
        tarifaChofer: vig.tarifaChofer,
        montoFijoChofer: vig.montoFijoChofer,
      );
      expect(nuevo.tarifaChofer, 48); // ahora SÍ cambia
      expect(nuevo.tarifaReal, 100); // real preservada
    });

    test('separación de lados: real y chofer no se pisan entre sí', () {
      // Aplicar real y después chofer deja AMBOS al día de la fecha.
      final vig = t.vigenteEn(DateTime(2026, 1, 20));
      final paso1 = _snapBase.conTarifaReal(vig.tarifaReal);
      final paso2 = paso1.conTarifaChofer(
        tarifaChofer: vig.tarifaChofer,
        montoFijoChofer: vig.montoFijoChofer,
      );
      expect(paso2.tarifaReal, 120);
      expect(paso2.tarifaChofer, 48);
    });

    test('idempotencia CHOFER: comparar el par detecta "ya al día"', () {
      final vig = t.vigenteEn(DateTime(2026, 1, 20));
      final r1 = _snapBase.conTarifaChofer(
        tarifaChofer: vig.tarifaChofer,
        montoFijoChofer: vig.montoFijoChofer,
      );
      // El chequeo de cambio del service: (chofer, montoFijo) del snap vs vig.
      final yaAlDia =
          vig.tarifaChofer == r1.tarifaChofer && vig.montoFijoChofer == r1.montoFijoChofer;
      expect(yaAlDia, isTrue); // tras aplicar, re-aplicar no cambiaría nada
      final r2 = r1.conTarifaChofer(
        tarifaChofer: vig.tarifaChofer,
        montoFijoChofer: vig.montoFijoChofer,
      );
      expect(r2.tarifaChofer, r1.tarifaChofer);
      expect(r2.montoFijoChofer, r1.montoFijoChofer);
    });
  });

  group('TarifaLogistica — km del recorrido (identidad, no versionado)', () {
    test('fromMap lee km entero; toMap lo persiste (round-trip)', () {
      final t = _tarifa(
        vigenciasReal: [_vReal(DateTime(2026, 1, 1))],
        vigenciasChofer: [_vChofer(DateTime(2026, 1, 1))],
        km: 450,
      );
      expect(t.km, 450);
      expect(t.toMap()['km'], 450);
      // Round-trip completo: re-parsear el map preserva el km.
      expect(TarifaLogistica.fromMap('T1', t.toMap()).km, 450);
    });

    test('km null no se escribe en el map y se relee como null', () {
      final t = _tarifa(
        vigenciasReal: [_vReal(DateTime(2026, 1, 1))],
        vigenciasChofer: [_vChofer(DateTime(2026, 1, 1))],
      );
      expect(t.km, isNull);
      expect(t.toMap().containsKey('km'), isFalse);
      expect(TarifaLogistica.fromMap('T1', t.toMap()).km, isNull);
    });

    test('fromMap castea un km guardado como double a int', () {
      // Firestore puede devolver un entero como double (450.0).
      final t = TarifaLogistica.fromMap('T1', const {
        'tipo_carga': 'PROPIA',
        'km': 450.0,
        'tarifa_real': 100,
        'tarifa_chofer': 40,
      });
      expect(t.km, 450);
      expect(t.km, isA<int>());
    });

    test('el km NO se mete en las vigencias (es identidad, no precio)', () {
      final t = _tarifa(
        vigenciasReal: [_vReal(DateTime(2026, 1, 1), real: 100)],
        vigenciasChofer: [_vChofer(DateTime(2026, 1, 1), chofer: 40)],
        km: 450,
      );
      final map = t.toMap();
      for (final v in (map['vigencias_real'] as List)) {
        expect((v as Map).containsKey('km'), isFalse);
      }
      for (final v in (map['vigencias'] as List)) {
        expect((v as Map).containsKey('km'), isFalse);
      }
    });
  });
}
