import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:coopertrans_movil/core/constants/app_constants.dart';
import 'package:coopertrans_movil/features/asignaciones/services/asignacion_mutex.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mutex de operación de los cambios de asignación (auditoría 2026-06).
/// Previene que 2 cambios concurrentes sobre la misma patente/chofer dejen
/// 2 asignaciones activas. Acá testeamos el guard en código (get+exists);
/// la unicidad ante carrera REAL la garantiza la rule `update: if false`.
void main() {
  Future<bool> existeLock(FakeFirebaseFirestore db, String recurso) async {
    final snap =
        await db.collection(AppCollections.asignacionesLocks).doc(recurso).get();
    return snap.exists;
  }

  group('conMutexAsignacion', () {
    test('caso normal: ejecuta la op (con el lock tomado) y lo libera al final',
        () async {
      final db = FakeFirebaseFirestore();
      var corrio = false;
      final r = await conMutexAsignacion(db, ['vehiculo_ABC123'], () async {
        corrio = true;
        // Durante la op el lock DEBE existir.
        expect(await existeLock(db, 'vehiculo_ABC123'), isTrue);
        return 42;
      });
      expect(corrio, isTrue);
      expect(r, 42);
      // Al terminar, el lock se liberó.
      expect(await existeLock(db, 'vehiculo_ABC123'), isFalse);
    });

    test('lock vigente (otra op en curso): rebota y NO ejecuta la op', () async {
      final db = FakeFirebaseFirestore();
      await db
          .collection(AppCollections.asignacionesLocks)
          .doc('vehiculo_ABC123')
          .set({
        'expira_en':
            Timestamp.fromDate(DateTime.now().add(const Duration(minutes: 2))),
      });
      var corrio = false;
      await expectLater(
        conMutexAsignacion(db, ['vehiculo_ABC123'], () async {
          corrio = true;
        }),
        throwsA(isA<AsignacionEnCursoException>()),
      );
      expect(corrio, isFalse);
    });

    test('lock VENCIDO (crash anterior): lo retoma, ejecuta y libera', () async {
      final db = FakeFirebaseFirestore();
      await db
          .collection(AppCollections.asignacionesLocks)
          .doc('vehiculo_ABC123')
          .set({
        'expira_en':
            Timestamp.fromDate(DateTime.now().subtract(const Duration(minutes: 5))),
      });
      var corrio = false;
      await conMutexAsignacion(db, ['vehiculo_ABC123'], () async {
        corrio = true;
      });
      expect(corrio, isTrue);
      expect(await existeLock(db, 'vehiculo_ABC123'), isFalse);
    });

    test('libera el lock aunque la op lance', () async {
      final db = FakeFirebaseFirestore();
      await expectLater(
        conMutexAsignacion(db, ['chofer_111'], () async {
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
      expect(await existeLock(db, 'chofer_111'), isFalse);
    });

    test('toma TODOS los recursos y los libera al terminar', () async {
      final db = FakeFirebaseFirestore();
      await conMutexAsignacion(db, ['vehiculo_A', 'chofer_1'], () async {
        expect(await existeLock(db, 'vehiculo_A'), isTrue);
        expect(await existeLock(db, 'chofer_1'), isTrue);
      });
      expect(await existeLock(db, 'vehiculo_A'), isFalse);
      expect(await existeLock(db, 'chofer_1'), isFalse);
    });
  });
}
