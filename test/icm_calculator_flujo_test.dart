// Tests de integración del flujo CESVI completo de
// IcmCalculator.calcularRanking — lee SITRACK_EVENTOS de Firestore
// (fake), agrupa por (chofer, día ART), calcula km por patente y
// combina por chofer.
//
// **Rediseño 2026-05-22**: la unidad ya NO es la jornada del vigilador
// (estaba rota). Ahora bucket por día, km POR PATENTE (odómetro de
// eventos de movimiento) y SIN fatiga (no hay señal real). La FÓRMULA
// pura (pesos, agrupación 8+9, promedio ponderado km) está cubierta por
// `icm_cesvi_test.dart`. Acá testeamos el wiring de Firestore + el
// bucketing por día + la atribución de km por patente.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/icm/services/icm_calculator.dart';

void main() {
  /// Inserta un evento sintético en SITRACK_EVENTOS.
  Future<void> insertarEvento(
    FakeFirebaseFirestore db, {
    required String driverDni,
    required String patente,
    required int eventId,
    required double odometer,
    required DateTime reportDate,
    double? speed,
    double? cartLimit,
    String areaType = 'rural',
    String eventName = 'Evento test',
  }) async {
    await db.collection('SITRACK_EVENTOS').add({
      'driver_dni': driverDni,
      'asset_id': patente,
      'event_id': eventId,
      'event_name': eventName,
      'odometer': odometer,
      'report_date': Timestamp.fromDate(reportDate),
      'speed': speed,
      'cartography_limit_speed': cartLimit,
      'area_type': areaType,
    });
  }

  // Rango que cubre el día 2026-05-10 con margen ART (UTC-3): tomamos
  // un día antes y uno después para que el bucketing por día ART caiga
  // siempre dentro del rango independientemente del TZ del runner.
  final desdeMs = DateTime.utc(2026, 5, 9).millisecondsSinceEpoch;
  final hastaMs = DateTime.utc(2026, 5, 12).millisecondsSinceEpoch;

  group('IcmCalculator.calcularRanking — flujo por (chofer, día)', () {
    test('1 chofer limpio con km → ICM 100 (sin fatiga)', () async {
      final db = FakeFirebaseFirestore();
      final t = DateTime.utc(2026, 5, 10, 12, 0);
      // 2 eventos de movimiento (no CESVI) → dan el km de la patente.
      await insertarEvento(db,
          driverDni: '111', patente: 'AB1', eventId: 283,
          odometer: 100, reportDate: t);
      await insertarEvento(db,
          driverDni: '111', patente: 'AB1', eventId: 283,
          odometer: 350, reportDate: t.add(const Duration(hours: 2)));
      final r = await IcmCalculator.calcularRanking(
        db: db,
        desdeMs: desdeMs,
        hastaMs: hastaMs,
        nombrePorDni: {'111': 'TEST CHOFER'},
      );
      expect(r.length, 1);
      expect(r[0].choferDni, '111');
      expect(r[0].choferNombre, 'TEST CHOFER');
      expect(r[0].kmRecorridos, 250); // 350 - 100
      // Sin infracciones y sin fatiga → ICM 100.
      expect(r[0].icm, 100);
      expect(r[0].categoria, CategoriaIcm.bajo);
    });

    test('frenadas/aceleraciones bajan el ICM (CESVI puro)', () async {
      final db = FakeFirebaseFirestore();
      final t = DateTime.utc(2026, 5, 10, 12, 0);
      // 2 frenadas (-5.8×2 = -11.6) + 1 aceleración (-2.8) = -14.4
      await insertarEvento(db,
          driverDni: '111', patente: 'AB1', eventId: 67,
          odometer: 100, reportDate: t.add(const Duration(minutes: 10)));
      await insertarEvento(db,
          driverDni: '111', patente: 'AB1', eventId: 67,
          odometer: 105, reportDate: t.add(const Duration(minutes: 20)));
      await insertarEvento(db,
          driverDni: '111', patente: 'AB1', eventId: 66,
          odometer: 150, reportDate: t.add(const Duration(minutes: 30)));
      final r = await IcmCalculator.calcularRanking(
        db: db,
        desdeMs: desdeMs,
        hastaMs: hastaMs,
        nombrePorDni: const {},
      );
      expect(r.length, 1);
      expect(r[0].totalEventos, 3); // 2 frenadas + 1 aceleración
      expect(r[0].icm, closeTo(85.6, 0.01)); // 100 - 14.4
      // 85.6 < 91 → MEDIO con umbrales YPF.
      expect(r[0].categoria, CategoriaIcm.medio);
    });

    test('eventos NO CESVI (1006 salida carril) NO descuentan ICM', () async {
      final db = FakeFirebaseFirestore();
      final t = DateTime.utc(2026, 5, 10, 12, 0);
      for (var i = 0; i < 10; i++) {
        await insertarEvento(db,
            driverDni: '111', patente: 'AB1', eventId: 1006,
            odometer: 100.0 + i * 5,
            reportDate: t.add(Duration(minutes: 10 + i)));
      }
      final r = await IcmCalculator.calcularRanking(
        db: db,
        desdeMs: desdeMs,
        hastaMs: hastaMs,
        nombrePorDni: const {},
      );
      expect(r.length, 1);
      expect(r[0].totalEventos, 0); // 1006 NO cuenta
      expect(r[0].icm, 100);
    });

    test('chofer con poco km igual aparece (no hay filtro km mínimo)', () async {
      final db = FakeFirebaseFirestore();
      final t = DateTime.utc(2026, 5, 10, 12, 0);
      // Solo 5 km recorridos — antes se descartaba, ahora cuenta.
      await insertarEvento(db,
          driverDni: '111', patente: 'AB1', eventId: 283,
          odometer: 100, reportDate: t);
      await insertarEvento(db,
          driverDni: '111', patente: 'AB1', eventId: 283,
          odometer: 105, reportDate: t.add(const Duration(minutes: 30)));
      final r = await IcmCalculator.calcularRanking(
        db: db,
        desdeMs: desdeMs,
        hastaMs: hastaMs,
        nombrePorDni: const {},
      );
      expect(r.length, 1);
      expect(r[0].kmRecorridos, 5);
      expect(r[0].icm, 100); // sin infracciones
    });

    test('km se reparte entre choferes que comparten patente el mismo día',
        () async {
      final db = FakeFirebaseFirestore();
      final t = DateTime.utc(2026, 5, 10, 6, 0);
      // Patente CC1 recorre 100→300 (200 km) en el día. Chofer X tiene 3
      // eventos, chofer Y tiene 1 → X se lleva 150 km, Y 50 km (prorrateo).
      await insertarEvento(db,
          driverDni: 'X', patente: 'CC1', eventId: 283,
          odometer: 100, reportDate: t);
      await insertarEvento(db,
          driverDni: 'X', patente: 'CC1', eventId: 283,
          odometer: 180, reportDate: t.add(const Duration(hours: 1)));
      await insertarEvento(db,
          driverDni: 'X', patente: 'CC1', eventId: 283,
          odometer: 220, reportDate: t.add(const Duration(hours: 2)));
      await insertarEvento(db,
          driverDni: 'Y', patente: 'CC1', eventId: 283,
          odometer: 300, reportDate: t.add(const Duration(hours: 4)));
      final r = await IcmCalculator.calcularRanking(
        db: db,
        desdeMs: desdeMs,
        hastaMs: hastaMs,
        nombrePorDni: const {},
      );
      final x = r.firstWhere((c) => c.choferDni == 'X');
      final y = r.firstWhere((c) => c.choferDni == 'Y');
      expect(x.kmRecorridos, closeTo(150, 0.01)); // 200 * 3/4
      expect(y.kmRecorridos, closeTo(50, 0.01)); // 200 * 1/4
    });

    test('múltiples choferes ordenados peor primero', () async {
      final db = FakeFirebaseFirestore();
      final t = DateTime.utc(2026, 5, 10, 12, 0);
      // Chofer A: limpio → ICM 100
      await insertarEvento(db,
          driverDni: 'A', patente: 'AA1', eventId: 283,
          odometer: 100, reportDate: t);
      await insertarEvento(db,
          driverDni: 'A', patente: 'AA1', eventId: 283,
          odometer: 400, reportDate: t.add(const Duration(hours: 2)));
      // Chofer B: 3 frenadas (-17.4) → ICM 82.6
      for (var i = 0; i < 3; i++) {
        await insertarEvento(db,
            driverDni: 'B', patente: 'BB1', eventId: 67,
            odometer: 200.0 + i * 10,
            reportDate: t.add(Duration(minutes: 30 + i * 10)),
            speed: 60, cartLimit: 80, areaType: 'urban');
      }
      await insertarEvento(db,
          driverDni: 'B', patente: 'BB1', eventId: 283,
          odometer: 500, reportDate: t.add(const Duration(hours: 2)));
      final r = await IcmCalculator.calcularRanking(
        db: db,
        desdeMs: desdeMs,
        hastaMs: hastaMs,
        nombrePorDni: const {'A': 'Alfa', 'B': 'Beta'},
      );
      expect(r.length, 2);
      // Peor ICM primero: B (-17.4 → 82.6)
      expect(r[0].choferDni, 'B');
      expect(r[0].icm, closeTo(82.6, 0.01));
      expect(r[0].icm, lessThan(r[1].icm));
      // A: limpio → ICM 100
      expect(r[1].choferDni, 'A');
      expect(r[1].icm, 100);
    });

    test('chofer con evento CESVI aparece aunque km=0', () async {
      final db = FakeFirebaseFirestore();
      // Una sola frenada, odómetro estático → km 0 pero la infracción
      // NO se pierde (peso mínimo 1 en la combinación).
      await insertarEvento(db,
          driverDni: '111', patente: 'AB1', eventId: 67,
          odometer: 100, reportDate: DateTime.utc(2026, 5, 10, 12, 0),
          speed: 60, cartLimit: 80, areaType: 'urban');
      final r = await IcmCalculator.calcularRanking(
        db: db,
        desdeMs: desdeMs,
        hastaMs: hastaMs,
        nombrePorDni: const {},
      );
      expect(r.length, 1);
      expect(r[0].totalEventos, 1);
      expect(r[0].icm, closeTo(94.2, 0.01)); // 100 - 5.8
    });

    test('rango vacío → ranking vacío', () async {
      final db = FakeFirebaseFirestore();
      final r = await IcmCalculator.calcularRanking(
        db: db,
        desdeMs: desdeMs,
        hastaMs: hastaMs,
        nombrePorDni: const {},
      );
      expect(r, isEmpty);
    });

    test('fallback de nombre cuando DNI no está en map', () async {
      final db = FakeFirebaseFirestore();
      final t = DateTime.utc(2026, 5, 10, 12, 0);
      await insertarEvento(db,
          driverDni: '999', patente: 'AB1', eventId: 283,
          odometer: 100, reportDate: t);
      await insertarEvento(db,
          driverDni: '999', patente: 'AB1', eventId: 283,
          odometer: 200, reportDate: t.add(const Duration(hours: 1)));
      final r = await IcmCalculator.calcularRanking(
        db: db,
        desdeMs: desdeMs,
        hastaMs: hastaMs,
        nombrePorDni: const {}, // sin mapping
      );
      expect(r.length, 1);
      expect(r[0].choferNombre, 'DNI 999'); // fallback
    });
  });
}
