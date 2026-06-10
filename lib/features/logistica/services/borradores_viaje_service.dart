import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/app_logger.dart';
import '../models/viaje.dart';

/// Persistencia del borrador del form de viaje. Sirve para que si el
/// operador empieza a cargar un viaje y se cierra la app, no se
/// pierdan los datos. Al volver a entrar al form, le ofrecemos
/// recuperar lo que tenía.
///
/// 1 doc por (operador, viajeId). Para modo alta, `viajeId` lógico
/// es `"nuevo"` — así no acumulamos borradores huérfanos.
///
/// Lo que NO se guarda en el borrador:
///   - Archivos de remito pendientes de subida (Uint8List grandes —
///     no caben en Firestore y serían un costo innecesario). Si el
///     operador había pickeado un remito que todavía no subió, lo
///     pierde y tiene que volver a pickear.
///   - Texto crudo de los TextEditingController (kg, remito_numero,
///     descripción). Se reconstruye desde el `TramoViaje` serializado.
class BorradoresViajeService {
  BorradoresViajeService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const String _coleccion = 'BORRADORES_VIAJE';

  /// Doc id estable. `viajeIdOriginal == null` → modo alta.
  static String _docId({
    required String operadorDni,
    String? viajeIdOriginal,
  }) =>
      '${operadorDni}_${viajeIdOriginal ?? 'nuevo'}';

  /// Guarda (o sobrescribe) el borrador del operador. Llamarlo con
  /// debounce desde el form — no querés mil writes seguidos al
  /// tipear. Idempotente.
  ///
  /// Persiste:
  ///   - chofer (dni + nombre snapshot).
  ///   - vehículo / enganche (texto crudo del form, ya en uppercase).
  ///   - estado (`PLANEADO` / `EN_CURSO` / etc.) + motivo cancelación
  ///     + fecha postergado a (si aplican).
  ///   - lista completa de tramos (cada uno con tarifa + kg + fechas
  ///     + gastos). Reusa el `TramoViaje.toMap()` existente.
  ///   - ids de los adelantos asociados (si tildó alguno).
  ///   - timestamp `actualizado_en` para mostrar cuándo fue el último
  ///     auto-save al user al ofrecer recuperar.
  static Future<void> guardar({
    required String operadorDni,
    String? viajeIdOriginal,
    required String? choferDni,
    required String? choferNombre,
    required String? vehiculoId,
    required String? engancheId,
    required List<TramoViaje> tramos,
    required EstadoViaje estado,
    required String? motivoCancelacion,
    required DateTime? fechaPostergadoA,
    required List<String> adelantosAsociadosIds,
  }) async {
    if (operadorDni.isEmpty) {
      throw ArgumentError('operadorDni vacío.');
    }
    // No persistir borradores totalmente vacíos — sino el operador
    // ve un "tenés un borrador" cuando en realidad nunca tocó nada.
    final hayDatos = (choferDni != null && choferDni.isNotEmpty) ||
        tramos.any((t) => t.tarifaId.isNotEmpty);
    if (!hayDatos) {
      // No-op: nada que guardar.
      return;
    }
    final data = <String, dynamic>{
      'operador_dni': operadorDni,
      'viaje_id_original': viajeIdOriginal,
      'chofer_dni': choferDni,
      'chofer_nombre': choferNombre,
      'vehiculo_id': vehiculoId,
      'enganche_id': engancheId,
      'estado': estado.codigo,
      'motivo_cancelacion': motivoCancelacion,
      'fecha_postergado_a': fechaPostergadoA == null
          ? null
          : Timestamp.fromDate(fechaPostergadoA),
      'tramos': tramos.map((t) => t.toMap()).toList(),
      'adelantos_asociados_ids': adelantosAsociadosIds,
      'actualizado_en': FieldValue.serverTimestamp(),
    };
    final ref = _db.collection(_coleccion).doc(_docId(
          operadorDni: operadorDni,
          viajeIdOriginal: viajeIdOriginal,
        ));
    await ref.set(data, SetOptions(merge: false));
    AppLogger.log(
      'Borrador viaje guardado: operador=$operadorDni '
      'modo=${viajeIdOriginal == null ? "alta" : "edicion:$viajeIdOriginal"} '
      'tramos=${tramos.length}',
    );
  }

  /// Lee el borrador para un (operador, viajeIdOriginal). Devuelve
  /// null si no existe. Devuelve el doc data crudo (con `tramos` como
  /// lista de maps) — el caller decide cómo reconstruir el form.
  static Future<BorradorViaje?> leer({
    required String operadorDni,
    String? viajeIdOriginal,
  }) async {
    if (operadorDni.isEmpty) return null;
    final snap = await _db
        .collection(_coleccion)
        .doc(_docId(operadorDni: operadorDni, viajeIdOriginal: viajeIdOriginal))
        .get();
    if (!snap.exists) return null;
    return BorradorViaje.fromMap(snap.data() ?? const {});
  }

  /// Borra el borrador (lo llama el form después de un guardado
  /// exitoso, o cuando el operador descarta explícito). Idempotente.
  static Future<void> eliminar({
    required String operadorDni,
    String? viajeIdOriginal,
  }) async {
    if (operadorDni.isEmpty) return;
    await _db
        .collection(_coleccion)
        .doc(_docId(operadorDni: operadorDni, viajeIdOriginal: viajeIdOriginal))
        .delete();
    AppLogger.log(
      'Borrador viaje eliminado: operador=$operadorDni '
      'modo=${viajeIdOriginal == null ? "alta" : "edicion:$viajeIdOriginal"}',
    );
  }
}

/// Borrador deserializado — wrapper que expone los campos típicos del
/// form para que `LogisticaViajeFormScreen._cargarSiEdicion` los
/// reconstruya sin tener que reimplementar el parsing.
class BorradorViaje {
  final String? choferDni;
  final String? choferNombre;
  final String? vehiculoId;
  final String? engancheId;
  final EstadoViaje estado;
  final String? motivoCancelacion;
  final DateTime? fechaPostergadoA;
  final List<TramoViaje> tramos;
  final List<String> adelantosAsociadosIds;
  final DateTime? actualizadoEn;

  const BorradorViaje({
    required this.choferDni,
    required this.choferNombre,
    required this.vehiculoId,
    required this.engancheId,
    required this.estado,
    required this.motivoCancelacion,
    required this.fechaPostergadoA,
    required this.tramos,
    required this.adelantosAsociadosIds,
    required this.actualizadoEn,
  });

  factory BorradorViaje.fromMap(Map<String, dynamic> d) {
    final tramosRaw = d['tramos'] as List? ?? const [];
    final tramos = tramosRaw
        .map((t) => TramoViaje.fromMap(Map<String, dynamic>.from(t as Map)))
        .toList();
    return BorradorViaje(
      choferDni: d['chofer_dni']?.toString(),
      choferNombre: d['chofer_nombre']?.toString(),
      vehiculoId: d['vehiculo_id']?.toString(),
      engancheId: d['enganche_id']?.toString(),
      estado: EstadoViaje.fromCodigo(d['estado']?.toString()),
      motivoCancelacion: d['motivo_cancelacion']?.toString(),
      fechaPostergadoA: (d['fecha_postergado_a'] as Timestamp?)?.toDate(),
      tramos: tramos,
      adelantosAsociadosIds: _leerAdelantosIds(d),
      actualizadoEn: (d['actualizado_en'] as Timestamp?)?.toDate(),
    );
  }

  /// Lee la lista de adelantos asociados del borrador. Compat retro:
  /// los borradores creados antes del 2026-06-10 guardaban un único
  /// `adelanto_asociado_id` (string). Si está el array nuevo, lo
  /// usamos; sino caemos al campo singular viejo (un borrador en vuelo
  /// al momento del deploy sigue hidratando bien).
  static List<String> _leerAdelantosIds(Map<String, dynamic> d) {
    final lista = d['adelantos_asociados_ids'];
    if (lista is List) {
      return lista
          .map((e) => e?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    }
    final viejo = d['adelanto_asociado_id']?.toString();
    return (viejo != null && viejo.isNotEmpty) ? [viejo] : const [];
  }
}
