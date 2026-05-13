import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/app_logger.dart';
import '../models/adelanto_chofer.dart';

/// CRUD de adelantos al chofer (`ADELANTOS_CHOFER`). Independiente del
/// módulo de Viajes — un adelanto puede o no estar atado a un viaje.
///
/// La numeración del comprobante (`numero_recibo`) la asigna la Cloud
/// Function callable `asignarNumeroReciboAdelanto` server-side al
/// primer imprimir, NO desde acá. Ver `recibos_adelanto_service.dart`.
class AdelantosService {
  AdelantosService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AppCollections.adelantosChofer);

  // ===========================================================================
  // QUERIES
  // ===========================================================================

  /// Stream de todos los adelantos, ordenados por fecha descendente
  /// (más recientes arriba). Si `limit` se pasa, lo aplica.
  static Stream<List<AdelantoChofer>> streamAdelantos({int? limit}) {
    Query<Map<String, dynamic>> q = _col.orderBy('fecha', descending: true);
    if (limit != null) q = q.limit(limit);
    return q.snapshots().map(
          (snap) =>
              snap.docs.map((d) => AdelantoChofer.fromMap(d.id, d.data())).toList(),
        );
  }

  /// Stream de adelantos filtrados por chofer. Útil para "todos los
  /// adelantos de Pérez Juan en el último mes" en LIQUIDACIÓN.
  /// Requiere índice compuesto `chofer_dni ASC + fecha DESC`.
  static Stream<List<AdelantoChofer>> streamAdelantosPorChofer(
    String dni, {
    int? limit,
  }) {
    Query<Map<String, dynamic>> q = _col
        .where('chofer_dni', isEqualTo: dni)
        .orderBy('fecha', descending: true);
    if (limit != null) q = q.limit(limit);
    return q.snapshots().map(
          (snap) =>
              snap.docs.map((d) => AdelantoChofer.fromMap(d.id, d.data())).toList(),
        );
  }

  /// One-shot get de adelantos en un rango de fechas. Lo usa la
  /// pantalla LIQUIDACIÓN para sumar los adelantos del chofer en el
  /// mes elegido. Requiere índice compuesto
  /// `chofer_dni ASC + fecha ASC`.
  static Future<List<AdelantoChofer>> getAdelantosEnRango({
    required DateTime desde,
    required DateTime hasta,
    String? choferDni,
  }) async {
    Query<Map<String, dynamic>> q = _col
        .where('fecha',
            isGreaterThanOrEqualTo: Timestamp.fromDate(desde),
            isLessThanOrEqualTo: Timestamp.fromDate(hasta));
    if (choferDni != null) {
      q = q.where('chofer_dni', isEqualTo: choferDni);
    }
    final snap = await q.get();
    return snap.docs
        .map((d) => AdelantoChofer.fromMap(d.id, d.data()))
        .toList();
  }

  /// Stream-version de [getAdelantosEnRango]. La pantalla LIQUIDACIÓN
  /// lo usa para que los KPIs se actualicen automáticamente cuando el
  /// operador agrega/edita un adelanto en otra pestaña/dispositivo.
  ///
  /// El filtro por `choferDnis` se aplica client-side porque
  /// Firestore no soporta `whereIn` + range query en el mismo índice
  /// (limitación conocida). Si la lista de DNIs es > 30, se rompería
  /// el `whereIn` directo igual.
  static Stream<List<AdelantoChofer>> streamAdelantosEnRango({
    required DateTime desde,
    required DateTime hasta,
    Set<String>? choferDnis,
  }) {
    final q = _col.where('fecha',
        isGreaterThanOrEqualTo: Timestamp.fromDate(desde),
        isLessThanOrEqualTo: Timestamp.fromDate(hasta));
    return q.snapshots().map((snap) {
      final adelantos =
          snap.docs.map((d) => AdelantoChofer.fromMap(d.id, d.data())).toList();
      if (choferDnis == null) return adelantos;
      return adelantos.where((a) => choferDnis.contains(a.choferDni)).toList();
    });
  }

  static Stream<AdelantoChofer?> streamAdelanto(String id) {
    return _col.doc(id).snapshots().map(
          (snap) => snap.exists ? AdelantoChofer.fromDoc(snap) : null,
        );
  }

  // ===========================================================================
  // ALTA / EDICIÓN
  // ===========================================================================

  /// Crea un adelanto nuevo. Tira [ArgumentError] si monto ≤ 0.
  static Future<String> crearAdelanto({
    required String choferDni,
    String? choferNombre,
    required DateTime fecha,
    required double monto,
    String? observacion,
    MedioPagoAdelanto medioPago = MedioPagoAdelanto.efectivo,
    String? viajeId,
    required String creadoPorDni,
    String? creadoPorNombre,
  }) async {
    if (monto <= 0) {
      throw ArgumentError('El monto debe ser mayor a 0.');
    }
    if (choferDni.trim().isEmpty) {
      throw ArgumentError('El chofer es obligatorio.');
    }

    final docRef = _col.doc();
    final data = <String, dynamic>{
      'chofer_dni': choferDni,
      if (choferNombre != null) 'chofer_nombre': choferNombre,
      'fecha': Timestamp.fromDate(fecha),
      'monto': monto,
      if (observacion != null && observacion.trim().isNotEmpty)
        'observacion': observacion.trim(),
      'medio_pago': medioPago.codigo,
      if (viajeId != null && viajeId.trim().isNotEmpty) 'viaje_id': viajeId,
      // Estado de pago: los adelantos nuevos arrancan en pendiente.
      // El resumen PDF de "pendientes" los va a listar hasta que el
      // operador los marque pagados (en bulk al imprimir o uno a
      // uno desde la card).
      'pagado': false,
      'creado_en': FieldValue.serverTimestamp(),
      'creado_por_dni': creadoPorDni,
      if (creadoPorNombre != null) 'creado_por_nombre': creadoPorNombre,
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': creadoPorDni,
    };

    await docRef.set(data);
    AppLogger.log(
      'Adelanto creado: ${docRef.id} chofer=$choferDni monto=$monto '
      'medio=${medioPago.codigo}',
    );
    return docRef.id;
  }

  /// Actualiza campos del adelanto. NO toca `numero_recibo` ni
  /// `impreso_en` (esos los gestiona la Cloud Function de impresión).
  static Future<void> actualizarAdelanto({
    required String adelantoId,
    required String choferDni,
    String? choferNombre,
    required DateTime fecha,
    required double monto,
    String? observacion,
    MedioPagoAdelanto medioPago = MedioPagoAdelanto.efectivo,
    String? viajeId,
    required String actualizadoPorDni,
  }) async {
    if (monto <= 0) {
      throw ArgumentError('El monto debe ser mayor a 0.');
    }

    final data = <String, dynamic>{
      'chofer_dni': choferDni,
      'chofer_nombre': choferNombre,
      'fecha': Timestamp.fromDate(fecha),
      'monto': monto,
      'observacion': observacion?.trim().isEmpty ?? true
          ? null
          : observacion!.trim(),
      'medio_pago': medioPago.codigo,
      'viaje_id': viajeId?.trim().isEmpty ?? true ? null : viajeId!.trim(),
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': actualizadoPorDni,
    };

    await _col.doc(adelantoId).update(data);
    AppLogger.log('Adelanto actualizado: $adelantoId');
  }

  /// Asocia un adelanto a un viaje (set `viaje_id`). Lo usa el form
  /// de viaje cuando el operador elige un adelanto preexistente del
  /// chofer en el dropdown "ADELANTO ASOCIADO". Pasando `viajeId=null`
  /// desasocia (limpia el campo con `FieldValue.delete()`, así el
  /// adelanto queda "libre" para asociarse a otro viaje).
  ///
  /// NO toca el resto de los campos (monto, fecha, observación,
  /// medio de pago, número de recibo). Idempotente: si ya estaba
  /// asociado al mismo viaje, no hace nada visible.
  static Future<void> setViajeAsociado({
    required String adelantoId,
    required String? viajeId,
    required String actualizadoPorDni,
  }) async {
    if (adelantoId.isEmpty) {
      throw ArgumentError('adelantoId vacío.');
    }
    final data = <String, dynamic>{
      'viaje_id': viajeId == null || viajeId.trim().isEmpty
          ? FieldValue.delete()
          : viajeId.trim(),
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': actualizadoPorDni,
    };
    await _col.doc(adelantoId).update(data);
    AppLogger.log(
      'Adelanto $adelantoId asociación viaje → ${viajeId ?? "(libre)"}',
    );
  }

  /// Devuelve el adelanto asociado a un viaje (si existe). La hace el
  /// form de viaje al cargar en modo edición para hidratar el
  /// dropdown "ADELANTO ASOCIADO" con la selección actual.
  /// Devuelve null si no hay ninguno (caso normal — la mayoría de
  /// viajes no van a tener adelanto asociado).
  ///
  /// El modelo soporta a lo sumo UN adelanto por viaje desde la UI
  /// (el dropdown es single-select). Si por alguna razón hay varios
  /// docs con el mismo viaje_id (data corrupta), tomamos el primero.
  static Future<AdelantoChofer?> getPorViaje(String viajeId) async {
    if (viajeId.isEmpty) return null;
    final snap = await _col
        .where('viaje_id', isEqualTo: viajeId)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    return AdelantoChofer.fromDoc(snap.docs.first);
  }

  /// Toggle del estado `pagado` de un adelanto. Si `pagado == true`,
  /// registra `pagado_en` con server timestamp y `pagado_por_dni`.
  /// Si pasamos `pagado == false`, limpia ambos.
  ///
  /// Idempotente: llamar 2 veces con el mismo valor no rompe nada
  /// (solo actualiza `actualizado_en`).
  static Future<void> setPagado({
    required String adelantoId,
    required bool pagado,
    required String marcadoPorDni,
  }) async {
    if (adelantoId.isEmpty) {
      throw ArgumentError('adelantoId vacío.');
    }
    final data = <String, dynamic>{
      'pagado': pagado,
      if (pagado)
        'pagado_en': FieldValue.serverTimestamp()
      else
        'pagado_en': FieldValue.delete(),
      if (pagado)
        'pagado_por_dni': marcadoPorDni
      else
        'pagado_por_dni': FieldValue.delete(),
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': marcadoPorDni,
    };
    await _col.doc(adelantoId).update(data);
    AppLogger.log(
      'Adelanto $adelantoId → pagado=$pagado por $marcadoPorDni',
    );
  }

  /// Marca varios adelantos como pagados en una sola operación (batch).
  /// Usado por el flujo "imprimí el resumen → marcame todos como
  /// pagados". Tira si la lista está vacía.
  static Future<void> marcarPagadosBulk({
    required List<String> adelantoIds,
    required String marcadoPorDni,
  }) async {
    if (adelantoIds.isEmpty) return;
    // Firestore acepta 500 ops por batch; las listas reales son chicas
    // (< 30 adelantos típicamente) así que 1 batch alcanza. Si en algún
    // momento se vuelve > 500, partir en chunks.
    final batch = _db.batch();
    for (final id in adelantoIds) {
      batch.update(_col.doc(id), {
        'pagado': true,
        'pagado_en': FieldValue.serverTimestamp(),
        'pagado_por_dni': marcadoPorDni,
        'actualizado_en': FieldValue.serverTimestamp(),
        'actualizado_por_dni': marcadoPorDni,
      });
    }
    await batch.commit();
    AppLogger.log(
      'Adelantos marcados como pagados: ${adelantoIds.length} '
      '(por $marcadoPorDni)',
    );
  }

  /// Hard-delete del adelanto. Idempotente (si no existe, no hace nada).
  /// El operador puede borrar adelantos cargados por error. Si ya tenía
  /// `numero_recibo` impreso, ese correlativo queda quemado (no se
  /// reusa) — auditoría correcta.
  static Future<void> eliminarAdelanto(String adelantoId) async {
    if (adelantoId.isEmpty) {
      throw ArgumentError('adelantoId vacío.');
    }
    await _col.doc(adelantoId).delete();
    AppLogger.log('Adelanto eliminado: $adelantoId');
  }
}
