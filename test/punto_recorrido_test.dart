// Tests del mapeo de SITRACK_EVENTOS → PuntoRecorrido (la base de la
// trayectoria histórica de una unidad en el mapa de flota). Lógica PURA,
// sin emulator: solo Timestamp de cloud_firestore (construible en tests).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coopertrans_movil/features/fleet_map/models/punto_recorrido.dart';

void main() {
  final ts = Timestamp.fromDate(DateTime(2026, 6, 1, 10, 30));

  group('PuntoRecorrido.deDoc', () {
    test('mapea un evento válido', () {
      final p = PuntoRecorrido.deDoc({
        'latitude': -38.7,
        'longitude': -62.3,
        'report_date': ts,
        'gps_speed': 54,
        'heading': 120,
        'event_name': 'Cambio de curso',
        'ignition': 1,
      });
      expect(p, isNotNull);
      expect(p!.lat, -38.7);
      expect(p.lng, -62.3);
      expect(p.fecha, DateTime(2026, 6, 1, 10, 30));
      expect(p.velocidad, 54);
      expect(p.heading, 120);
      expect(p.evento, 'Cambio de curso');
      expect(p.ignition, isTrue);
    });

    test('descarta si falta lat o lng', () {
      expect(
          PuntoRecorrido.deDoc({'longitude': -62.3, 'report_date': ts}), isNull);
      expect(
          PuntoRecorrido.deDoc({'latitude': -38.7, 'report_date': ts}), isNull);
    });

    test('descarta (0,0) — GPS sin fix', () {
      expect(
        PuntoRecorrido.deDoc(
            {'latitude': 0, 'longitude': 0, 'report_date': ts}),
        isNull,
      );
    });

    test('NO descarta si solo una coordenada es 0', () {
      final p = PuntoRecorrido.deDoc(
          {'latitude': -38.7, 'longitude': 0, 'report_date': ts});
      expect(p, isNotNull);
    });

    test('descarta si falta report_date', () {
      expect(
        PuntoRecorrido.deDoc({'latitude': -38.7, 'longitude': -62.3}),
        isNull,
      );
    });

    test('prefiere gps_speed sobre speed', () {
      final p = PuntoRecorrido.deDoc({
        'latitude': -38.7,
        'longitude': -62.3,
        'report_date': ts,
        'gps_speed': 60,
        'speed': 99,
      });
      expect(p!.velocidad, 60);
    });

    test('usa speed si no hay gps_speed', () {
      final p = PuntoRecorrido.deDoc({
        'latitude': -38.7,
        'longitude': -62.3,
        'report_date': ts,
        'speed': 42,
      });
      expect(p!.velocidad, 42);
    });

    test('velocidad/heading null si no reportan', () {
      final p = PuntoRecorrido.deDoc(
          {'latitude': -38.7, 'longitude': -62.3, 'report_date': ts});
      expect(p!.velocidad, isNull);
      expect(p.heading, isNull);
      expect(p.evento, '');
      expect(p.ignition, isFalse);
    });

    test('ignition: 0 → false, true(bool) → true', () {
      final off = PuntoRecorrido.deDoc({
        'latitude': -38.7,
        'longitude': -62.3,
        'report_date': ts,
        'ignition': 0,
      });
      expect(off!.ignition, isFalse);
      final on = PuntoRecorrido.deDoc({
        'latitude': -38.7,
        'longitude': -62.3,
        'report_date': ts,
        'ignition': true,
      });
      expect(on!.ignition, isTrue);
    });

    test('lat/lng enteros también mapean (num → double)', () {
      final p = PuntoRecorrido.deDoc(
          {'latitude': -38, 'longitude': -62, 'report_date': ts});
      expect(p, isNotNull);
      expect(p!.lat, -38.0);
      expect(p.lng, -62.0);
    });
  });
}
