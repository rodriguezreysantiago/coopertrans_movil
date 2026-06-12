// Tests del parseo de OdometroDia (TELEMETRIA_HISTORICO).
//
// Regresión auditoría 2026-06-12: los writers (CF telemetriaSnapshot y
// guardarSnapshotsDiarios) graban `fecha` como Timestamp, pero el modelo
// la consumía con `as String?` → null → '' → agruparPorMes descartaba
// TODOS los registros y la tabla de consumo mensual quedaba vacía, con
// los labels del eje X del gráfico en blanco.
//
// Usa fake_cloud_firestore para fabricar DocumentSnapshots reales (el
// factory recibe el snapshot entero porque también lee el doc.id).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/vehicles/services/odometros_service.dart';

void main() {
  late FakeFirebaseFirestore fake;

  setUp(() {
    fake = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> doc(
    String id,
    Map<String, dynamic> data,
  ) async {
    final ref = fake.collection('TELEMETRIA_HISTORICO').doc(id);
    await ref.set(data);
    return ref.get();
  }

  group('OdometroDia.fromDoc — campo fecha (regresión Timestamp vs String)', () {
    test('fecha como Timestamp (formato real de los writers) → la saca '
        'del doc ID, no queda vacía', () async {
      // Medianoche ART = 03:00 UTC, como graba la CF.
      final snap = await doc('AB123CD_2026-06-10', {
        'patente': 'AB123CD',
        'fecha': Timestamp.fromDate(DateTime.utc(2026, 6, 10, 3)),
        'km': 412345.0,
        'litros_acumulados': 98765.0,
      });
      final od = OdometroDia.fromDoc(snap, deltaKm: 250, deltaLitros: 80);
      expect(od.fecha, '2026-06-10',
          reason: 'antes del fix quedaba "" y el mes se descartaba');
      expect(od.fecha.length >= 7, isTrue,
          reason: 'agruparPorMes exige length >= 7 para no descartar');
      expect(od.kmAcumulado, 412345.0);
    });

    test('fecha como String → passthrough literal', () async {
      final snap = await doc('AB123CD_2026-06-09', {
        'patente': 'AB123CD',
        'fecha': '2026-06-09',
        'km': 412095.0,
        'litros_acumulados': 98685.0,
      });
      final od = OdometroDia.fromDoc(snap, deltaKm: 0, deltaLitros: 0);
      expect(od.fecha, '2026-06-09');
    });

    test('sin campo fecha → cae al doc ID igual', () async {
      final snap = await doc('AC987ZZ_2026-05-31', {
        'patente': 'AC987ZZ',
        'km': 100.0,
        'litros_acumulados': 10.0,
      });
      final od = OdometroDia.fromDoc(snap, deltaKm: 0, deltaLitros: 0);
      expect(od.fecha, '2026-05-31');
    });

    test('doc ID sin fecha + Timestamp → formatea el Timestamp (local)', () async {
      // ID malformado a propósito: obliga el fallback 3.
      final local = DateTime(2026, 6, 8); // medianoche local del device
      final snap = await doc('doc-suelto', {
        'patente': 'AB123CD',
        'fecha': Timestamp.fromDate(local),
        'km': 1.0,
        'litros_acumulados': 1.0,
      });
      final od = OdometroDia.fromDoc(snap, deltaKm: 0, deltaLitros: 0);
      expect(od.fecha, '2026-06-08');
    });

    test('sin fecha y sin ID parseable → "" (y agruparPorMes lo descarta '
        'sin romper)', () async {
      final snap = await doc('doc-suelto-2', {
        'patente': 'AB123CD',
        'km': 1.0,
        'litros_acumulados': 1.0,
      });
      final od = OdometroDia.fromDoc(snap, deltaKm: 0, deltaLitros: 0);
      expect(od.fecha, '');
    });
  });
}
