// Tests del versionado de tarifas por vigencia (2026-06).
//
// Foco: la resolución del precio por FECHA DE CARGA (`vigenteEn`), la
// migración perezosa de tarifas legacy (sin `vigencias`), y la composición
// EXACTA que usa el recálculo masivo de viajes (`conTarifaReal` sobre el
// snapshot del tramo: SOLO la tarifa real de la vigencia que regía en la
// fecha de carga; la chofer no se toca). Maneja PLATA — un bug acá liquida
// de más o de menos.
//
// El recálculo end-to-end (filtro `liquidado`, WriteBatch) usa
// FirebaseFirestore.instance y se valida en smoke manual; acá testeamos la
// lógica PURA que ese recálculo compone (patrón del proyecto: extraer la
// lógica del I/O y testear la pura).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/logistica/models/tarifa_logistica.dart';
import 'package:coopertrans_movil/features/logistica/models/viaje.dart';

/// Construye una tarifa con las [vigencias] dadas (los campos planos no
/// importan para los tests de vigencias — `vigenteEn` usa la lista).
TarifaLogistica _tarifa({
  List<TarifaVigencia> vigencias = const [],
  TipoCargaLogistica tipoCarga = TipoCargaLogistica.propia,
  UnidadTarifa unidad = UnidadTarifa.porTonelada,
  double tarifaRealPlana = 0,
  double tarifaChoferPlana = 0,
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
    flete: FleteLogistica.origen,
    unidadTarifa: unidad,
    tarifaReal: tarifaRealPlana,
    tarifaChofer: tarifaChoferPlana,
    vigencias: vigencias,
  );
}

TarifaVigencia _vig(
  DateTime desde, {
  double real = 100,
  double chofer = 40,
  double? montoFijoChofer,
  double? comisionDador,
  double? montoFijoDador,
}) {
  return TarifaVigencia(
    desde: desde,
    tarifaReal: real,
    tarifaChofer: chofer,
    montoFijoChofer: montoFijoChofer,
    porcentajeComisionDador: comisionDador,
    montoFijoDador: montoFijoDador,
  );
}

void main() {
  group('TarifaVigencia.desde — normalización a día', () {
    test('el constructor trunca la hora a medianoche', () {
      final v = _vig(DateTime(2026, 1, 15, 8, 30, 59));
      expect(v.desde, DateTime(2026, 1, 15));
    });
  });

  group('TarifaLogistica.vigenteEn', () {
    final t = _tarifa(vigencias: [
      _vig(DateTime(2026, 1, 1), real: 100, chofer: 40),
      _vig(DateTime(2026, 1, 15), real: 120, chofer: 48),
    ]);

    test('fecha entre dos vigencias toma la anterior vigente', () {
      expect(t.vigenteEn(DateTime(2026, 1, 10)).tarifaReal, 100);
      expect(t.vigenteEn(DateTime(2026, 1, 10)).tarifaChofer, 40);
    });

    test('fecha posterior a la última toma la última', () {
      expect(t.vigenteEn(DateTime(2026, 1, 20)).tarifaReal, 120);
    });

    test('fecha exacta de una vigencia la toma a ella (no la anterior)', () {
      expect(t.vigenteEn(DateTime(2026, 1, 15)).tarifaReal, 120);
    });

    test('fecha anterior a la primera vigencia devuelve la primera', () {
      expect(t.vigenteEn(DateTime(2025, 12, 1)).tarifaReal, 100);
    });

    test('normaliza la fecha a día (hora no corre el límite)', () {
      // 14-ene 23:59 todavía es precio viejo; 15-ene 00:00 ya es el nuevo.
      expect(t.vigenteEn(DateTime(2026, 1, 14, 23, 59)).tarifaReal, 100);
      expect(t.vigenteEn(DateTime(2026, 1, 15, 0, 0)).tarifaReal, 120);
    });

    test('vigencia FUTURA no se aplica a fechas presentes', () {
      final tf = _tarifa(vigencias: [
        _vig(DateTime(2026, 1, 1), real: 100),
        _vig(DateTime(2030, 1, 1), real: 200),
      ]);
      expect(tf.vigenteEn(DateTime(2026, 6, 4)).tarifaReal, 100);
    });

    test('una sola vigencia: cualquier fecha la devuelve', () {
      final t1 = _tarifa(vigencias: [_vig(DateTime(2026, 3, 1), real: 77)]);
      expect(t1.vigenteEn(DateTime(2026, 1, 1)).tarifaReal, 77);
      expect(t1.vigenteEn(DateTime(2026, 12, 31)).tarifaReal, 77);
    });

    test('lista vacía: fallback defensivo a los campos planos', () {
      final tv = _tarifa(tarifaRealPlana: 55, tarifaChoferPlana: 22);
      final v = tv.vigenteEn(DateTime(2026, 1, 1));
      expect(v.tarifaReal, 55);
      expect(v.tarifaChofer, 22);
    });
  });

  group('TarifaLogistica.fromMap — migración perezosa + vigencias', () {
    test('doc SIN vigencias sintetiza 1 desde los campos planos', () {
      final t = TarifaLogistica.fromMap('X', {
        'tipo_carga': 'PROPIA',
        'empresa_origen_id': 'eo',
        'tarifa_real': 100.0,
        'tarifa_chofer': 40.0,
        'unidad_tarifa': 'TN',
        'flete': 'ORIGEN',
        'vigente_desde': Timestamp.fromDate(DateTime(2026, 1, 1)),
      });
      expect(t.vigencias.length, 1);
      expect(t.vigencias.first.tarifaReal, 100);
      expect(t.vigencias.first.desde, DateTime(2026, 1, 1));
    });

    test('doc CON vigencias las parsea y ordena asc por desde', () {
      final t = TarifaLogistica.fromMap('X', {
        'tipo_carga': 'PROPIA',
        'unidad_tarifa': 'TN',
        'flete': 'ORIGEN',
        // Desordenadas a propósito: deben quedar [ene, mar].
        'vigencias': [
          _vig(DateTime(2026, 3, 1), real: 200).toMap(),
          _vig(DateTime(2026, 1, 1), real: 100).toMap(),
        ],
      });
      expect(t.vigencias.length, 2);
      expect(t.vigencias.first.desde, DateTime(2026, 1, 1));
      expect(t.vigencias.last.desde, DateTime(2026, 3, 1));
      // Y vigenteEn resuelve bien aunque vinieran desordenadas.
      expect(t.vigenteEn(DateTime(2026, 2, 1)).tarifaReal, 100);
      expect(t.vigenteEn(DateTime(2026, 3, 15)).tarifaReal, 200);
    });

    test('toMap serializa vigencias (round-trip persiste la migración)', () {
      final t = TarifaLogistica.fromMap('X', {
        'tipo_carga': 'PROPIA',
        'unidad_tarifa': 'TN',
        'flete': 'ORIGEN',
        'tarifa_real': 100.0,
        'tarifa_chofer': 40.0,
        'vigente_desde': Timestamp.fromDate(DateTime(2026, 1, 1)),
      });
      final map = t.toMap();
      expect(map['vigencias'], isA<List>());
      expect((map['vigencias'] as List).length, 1);
      // Re-parsear el toMap conserva la vigencia.
      final t2 = TarifaLogistica.fromMap('X', map);
      expect(t2.vigencias.length, 1);
      expect(t2.vigencias.first.tarifaReal, 100);
    });
  });

  group('TarifaSnapshot.fromTarifaEnFecha', () {
    final t = _tarifa(vigencias: [
      _vig(DateTime(2026, 1, 1), real: 100, chofer: 40),
      _vig(DateTime(2026, 1, 15), real: 120, chofer: 48),
    ]);

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

  group('TarifaSnapshot.conTarifaReal', () {
    test('cambia SOLO la tarifa real; preserva chofer/dador/no-versionados',
        () {
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
      // Solo la real cambió.
      expect(nuevo.tarifaReal, 120);
      // Chofer + comisión dador + no-versionados intactos.
      expect(nuevo.tarifaChofer, 40);
      expect(nuevo.montoFijoChofer, 999000);
      expect(nuevo.porcentajeComisionDador, 12.5);
      expect(nuevo.producto, 'ARENA');
      expect(nuevo.origenEtiqueta, 'Bahía Blanca');
      expect(nuevo.dadorNombre, 'DADOR SRL');
    });
  });

  group('Composición del recálculo masivo (pura) — SOLO tarifa real', () {
    // Reproduce ViajesService.recalcularViajesNoLiquidadosConTarifa para UN
    // tramo: vig = tarifa.vigenteEn(fechaCarga); snap.conTarifaReal(vig.tarifaReal).
    // La tarifa del chofer del viaje NUNCA se toca (decisión Santiago).
    final t = _tarifa(vigencias: [
      _vig(DateTime(2026, 1, 1), real: 100, chofer: 40),
      _vig(DateTime(2026, 1, 15), real: 120, chofer: 48),
    ]);
    const snap = TarifaSnapshot(
      origenEtiqueta: 'o',
      destinoEtiqueta: 'd',
      empresaOrigenNombre: 'O',
      empresaDestinoNombre: 'D',
      unidadTarifa: UnidadTarifa.porTonelada,
      tarifaReal: 100,
      tarifaChofer: 40,
      montoFijoChofer: 555000, // override
    );

    test('tramo cargado en la 1ª quincena conserva la real vieja', () {
      final vig = t.vigenteEn(DateTime(2026, 1, 10)); // real 100
      final nuevo = snap.conTarifaReal(vig.tarifaReal);
      expect(nuevo.tarifaReal, 100);
      expect(nuevo.tarifaChofer, 40); // chofer intacta
      expect(nuevo.montoFijoChofer, 555000); // override intacto
    });

    test('tramo en 2ª quincena: sube la real, la CHOFER NO cambia', () {
      final vig = t.vigenteEn(DateTime(2026, 1, 20)); // real 120, chofer 48
      final nuevo = snap.conTarifaReal(vig.tarifaReal);
      expect(nuevo.tarifaReal, 120); // la real subió
      // La chofer sigue 40 (la del snapshot), NO 48 (la de la vigencia).
      expect(nuevo.tarifaChofer, 40);
      expect(nuevo.montoFijoChofer, 555000);
    });

    test('idempotente: aplicar dos veces da el mismo resultado', () {
      final vig = t.vigenteEn(DateTime(2026, 1, 20));
      final r1 = snap.conTarifaReal(vig.tarifaReal);
      final r2 = r1.conTarifaReal(vig.tarifaReal);
      expect(r2.tarifaReal, r1.tarifaReal);
      expect(r2.tarifaChofer, r1.tarifaChofer);
    });
  });
}
