import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';

/// Se lanza cuando ya hay un cambio de asignación EN CURSO sobre el mismo
/// recurso (vehículo / chofer / enganche / tractor). La UI lo muestra como
/// "reintentá en unos segundos" — no es un error técnico.
class AsignacionEnCursoException implements Exception {
  final String mensaje;
  AsignacionEnCursoException(this.mensaje);
  @override
  String toString() => mensaje;
}

/// Mutex de OPERACIÓN para los cambios de asignación.
///
/// Por qué existe: `cambiarAsignacion` hace writes secuenciales (lee la
/// asignación activa, crea la nueva, cierra la vieja) SIN `runTransaction`
/// (prohibido en Windows desktop — abort() nativo). Dos cambios concurrentes
/// sobre la misma patente/chofer podían leer ambos "no hay activa" y crear dos
/// → 2 asignaciones activas, que rompen la atribución de eventos/multas.
///
/// Este helper toma un lock create-only por cada [recursos] ANTES de la
/// operación y lo libera al terminar. La unicidad real la garantiza la rule
/// `ASIGNACIONES_LOCKS` (`allow create` + `delete`, pero `update: if false`):
/// un `set` sobre un lock ya existente rebota con permission-denied, así que
/// el 2do cambio concurrente falla en vez de duplicar. El chequeo en código
/// (get + exists) cubre además el caso secuencial / 1-operador y los tests.
///
/// NO es un lock de estado (como los de Gomería, que viven mientras la posición
/// está ocupada): este existe SOLO durante la operación, por eso encaja con
/// "re-asignar una unidad ya ocupada" sin dejar candados permanentes. El
/// `expira_en` (~2 min) permite retomar un lock que quedó huérfano si el
/// proceso crasheó entre tomarlo y liberarlo.
Future<T> conMutexAsignacion<T>(
  FirebaseFirestore db,
  List<String> recursos,
  Future<T> Function() op,
) async {
  final col = db.collection(AppCollections.asignacionesLocks);
  final tomados = <DocumentReference<Map<String, dynamic>>>[];
  try {
    for (final recurso in recursos) {
      final ref = col.doc(recurso);
      final snap = await ref.get();
      if (snap.exists) {
        final expira = (snap.data()?['expira_en'] as Timestamp?)?.toDate();
        if (expira != null && expira.isAfter(DateTime.now())) {
          // Lock vigente → hay otra operación en curso sobre este recurso.
          throw AsignacionEnCursoException(
            'Hay otro cambio de asignación en curso para esta unidad o chofer. '
            'Esperá unos segundos y reintentá.',
          );
        }
        // Lock vencido (proceso anterior que crasheó) → liberar y retomar.
        await ref.delete();
      }
      // create (el doc no existe: o nunca existió, o lo borramos arriba). En
      // prod, si otro proceso lo creó entremedio, este set es un update y la
      // rule `update: if false` lo rebota → la operación falla sin duplicar.
      await ref.set(<String, dynamic>{
        'recurso': recurso,
        'tomado_en': FieldValue.serverTimestamp(),
        'expira_en':
            Timestamp.fromDate(DateTime.now().add(const Duration(minutes: 2))),
      });
      tomados.add(ref);
    }
    return await op();
  } finally {
    for (final ref in tomados) {
      try {
        await ref.delete();
      } catch (_) {
        // Best-effort: si el delete falla, el `expira_en` (~2 min) lo limpia.
      }
    }
  }
}
