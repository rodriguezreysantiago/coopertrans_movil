import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coopertrans_movil/features/administracion/models/vacacion.dart';
import 'package:coopertrans_movil/features/administracion/services/vacaciones_service.dart';

void main() {
  group('PeriodoVacaciones', () {
    test('días corridos inclusive (05-01 a 18-01 = 14)', () {
      final p = PeriodoVacaciones(
          inicio: DateTime(2026, 1, 5), fin: DateTime(2026, 1, 18));
      expect(p.dias, 14);
    });

    test('mismo día inicio=fin = 1 día', () {
      final p = PeriodoVacaciones(
          inicio: DateTime(2026, 3, 10), fin: DateTime(2026, 3, 10));
      expect(p.dias, 1);
    });

    test('normaliza a día (ignora la hora)', () {
      final p = PeriodoVacaciones(
          inicio: DateTime(2026, 1, 5, 23, 59), fin: DateTime(2026, 1, 6, 0, 1));
      expect(p.inicio, DateTime(2026, 1, 5));
      expect(p.fin, DateTime(2026, 1, 6));
      expect(p.dias, 2);
    });

    test('solapamiento se detecta', () {
      final a = PeriodoVacaciones(
          inicio: DateTime(2026, 1, 5), fin: DateTime(2026, 1, 18));
      final b = PeriodoVacaciones(
          inicio: DateTime(2026, 1, 15), fin: DateTime(2026, 1, 20));
      final c = PeriodoVacaciones(
          inicio: DateTime(2026, 2, 1), fin: DateTime(2026, 2, 8));
      expect(a.seSolapaCon(b), true);
      expect(a.seSolapaCon(c), false);
    });
  });

  group('Vacacion — derivados', () {
    Vacacion base({List<PeriodoVacaciones> periodos = const []}) => Vacacion(
          dni: '31584396',
          nombre: 'VILLARREAL CRISTIAN IVAN',
          anio: 2025,
          empresa: 'SRL',
          area: 'manejo',
          diasCorresponden: 21,
          periodos: periodos,
        );

    test('tomados suma los días de los períodos; restan = corresp - tomados',
        () {
      final v = base(periodos: [
        PeriodoVacaciones(inicio: DateTime(2026, 1, 5), fin: DateTime(2026, 1, 18)), // 14
        PeriodoVacaciones(inicio: DateTime(2026, 3, 23), fin: DateTime(2026, 3, 29)), // 7
      ]);
      expect(v.tomados, 21);
      expect(v.restan, 0);
    });

    test('restan negativo si cargaron de más (señal de error, no se clampa)',
        () {
      final v = base(periodos: [
        PeriodoVacaciones(inicio: DateTime(2026, 1, 1), fin: DateTime(2026, 1, 31)), // 31
      ]);
      expect(v.tomados, 31);
      expect(v.restan, 21 - 31);
    });

    test('docId determinístico <anio>_<dni>', () {
      expect(base().docId, '2025_31584396');
    });

    test('períodos quedan ordenados por inicio asc', () {
      final v = base(periodos: [
        PeriodoVacaciones(inicio: DateTime(2026, 3, 23), fin: DateTime(2026, 3, 29)),
        PeriodoVacaciones(inicio: DateTime(2026, 1, 5), fin: DateTime(2026, 1, 18)),
      ]);
      expect(v.periodos.first.inicio, DateTime(2026, 1, 5));
      expect(v.periodos.last.inicio, DateTime(2026, 3, 23));
    });

    test('tienePeriodosSolapados detecta tramos pisados', () {
      final solapado = base(periodos: [
        PeriodoVacaciones(inicio: DateTime(2026, 1, 5), fin: DateTime(2026, 1, 18)),
        PeriodoVacaciones(inicio: DateTime(2026, 1, 15), fin: DateTime(2026, 1, 25)),
      ]);
      final limpio = base(periodos: [
        PeriodoVacaciones(inicio: DateTime(2026, 1, 5), fin: DateTime(2026, 1, 18)),
        PeriodoVacaciones(inicio: DateTime(2026, 2, 1), fin: DateTime(2026, 2, 8)),
      ]);
      expect(solapado.tienePeriodosSolapados, true);
      expect(limpio.tienePeriodosSolapados, false);
    });
  });

  group('VacacionesService (fake_cloud_firestore)', () {
    late FakeFirebaseFirestore db;
    late VacacionesService svc;

    setUp(() {
      db = FakeFirebaseFirestore();
      svc = VacacionesService(db: db);
    });

    Vacacion nuevo(String dni, String nombre,
            {int anio = 2025,
            String area = 'manejo',
            List<PeriodoVacaciones> periodos = const []}) =>
        Vacacion(
          dni: dni,
          nombre: nombre,
          anio: anio,
          empresa: 'SRL',
          area: area,
          diasCorresponden: 21,
          periodos: periodos,
        );

    test('guardar + obtener roundtrip preserva períodos y derivados',
        () async {
      final v = nuevo('1', 'PEREZ JUAN', periodos: [
        PeriodoVacaciones(inicio: DateTime(2026, 1, 5), fin: DateTime(2026, 1, 18)),
      ]);
      await svc.guardar(v, actualizadoPorDni: '999');
      final leido = await svc.obtener('1', 2025);
      expect(leido, isNotNull);
      expect(leido!.nombre, 'PEREZ JUAN');
      expect(leido.periodos.length, 1);
      expect(leido.tomados, 14);
      expect(leido.restan, 7);
      expect(leido.actualizadoPorDni, '999');
    });

    test('guardar es idempotente por id determinístico (no duplica)',
        () async {
      await svc.guardar(nuevo('1', 'PEREZ JUAN'));
      await svc.guardar(nuevo('1', 'PEREZ J.')); // mismo dni+año
      final snap = await db.collection('VACACIONES').get();
      expect(snap.size, 1);
      expect((await svc.obtener('1', 2025))!.nombre, 'PEREZ J.');
    });

    test('streamPorAnio filtra por año y ordena por nombre', () async {
      await svc.guardar(nuevo('1', 'ZARATE', anio: 2025));
      await svc.guardar(nuevo('2', 'ALVAREZ', anio: 2025));
      await svc.guardar(nuevo('3', 'BENITEZ', anio: 2024)); // otro año
      final lista = await svc.streamPorAnio(2025).first;
      expect(lista.map((v) => v.nombre), ['ALVAREZ', 'ZARATE']);
    });

    test('tomados/restan se persisten para la vista de saldos', () async {
      await svc.guardar(nuevo('1', 'PEREZ', periodos: [
        PeriodoVacaciones(inicio: DateTime(2026, 1, 5), fin: DateTime(2026, 1, 11)), // 7
      ]));
      final raw =
          (await db.collection('VACACIONES').doc('2025_1').get()).data()!;
      expect(raw['tomados'], 7);
      expect(raw['restan'], 14);
    });

    test('agregarPeriodo suma sobre lo existente', () async {
      await svc.guardar(nuevo('1', 'PEREZ', periodos: [
        PeriodoVacaciones(inicio: DateTime(2026, 1, 5), fin: DateTime(2026, 1, 18)), // 14
      ]));
      await svc.agregarPeriodo(
        '1',
        2025,
        PeriodoVacaciones(inicio: DateTime(2026, 3, 23), fin: DateTime(2026, 3, 29)), // 7
      );
      final leido = await svc.obtener('1', 2025);
      expect(leido!.periodos.length, 2);
      expect(leido.tomados, 21);
    });

    test('eliminar borra el registro', () async {
      await svc.guardar(nuevo('1', 'PEREZ'));
      await svc.eliminar('1', 2025);
      expect(await svc.obtener('1', 2025), isNull);
    });
  });
}
