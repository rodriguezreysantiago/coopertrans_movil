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
  /// (más recientes arriba). `limit` default 300 (auditoria 2026-05-16).
  /// Antes era null → bajaba TODA la colección en cada rebuild. Pasar
  /// `limit: 0` para forzar sin limit en casos puntuales (reporte
  /// historico completo).
  static Stream<List<AdelantoChofer>> streamAdelantos({int? limit = 300}) {
    Query<Map<String, dynamic>> q = _col.orderBy('fecha', descending: true);
    if (limit != null && limit > 0) q = q.limit(limit);
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
  ///
  /// **Excluye soft-deleted por default** — un adelanto eliminado no
  /// es deuda válida del chofer y no se suma a la liquidación.
  static Future<List<AdelantoChofer>> getAdelantosEnRango({
    required DateTime desde,
    required DateTime hasta,
    String? choferDni,
    bool incluirEliminados = false,
  }) async {
    // CRITICO (auditoria 2026-05-17): antes usabamos `isLessThanOrEqualTo`
    // que generaba doble cuenta en bordes de mes. Un adelanto del 1ro
    // de junio a las 00:00:00 ART entraba en mayo (cuando filtro tenia
    // hasta=1-jun 00:00) Y en junio (cuando filtro tenia desde=1-jun
    // 00:00). El chofer veia descontado el mismo adelanto en 2 meses
    // consecutivos. Ahora `isLessThan` consistente con la convencion
    // [desde, hasta) que usa el resto del modulo (viajes_service).
    Query<Map<String, dynamic>> q = _col
        .where('fecha',
            isGreaterThanOrEqualTo: Timestamp.fromDate(desde),
            isLessThan: Timestamp.fromDate(hasta));
    if (choferDni != null) {
      q = q.where('chofer_dni', isEqualTo: choferDni);
    }
    final snap = await q.get();
    final list = snap.docs
        .map((d) => AdelantoChofer.fromMap(d.id, d.data()))
        .toList();
    if (incluirEliminados) return list;
    return list.where((a) => !a.eliminado).toList();
  }

  /// Stream-version de [getAdelantosEnRango]. La pantalla LIQUIDACIÓN
  /// lo usa para que los KPIs se actualicen automáticamente cuando el
  /// operador agrega/edita un adelanto en otra pestaña/dispositivo.
  ///
  /// El filtro por `choferDnis` se aplica client-side porque
  /// Firestore no soporta `whereIn` + range query en el mismo índice
  /// (limitación conocida). Si la lista de DNIs es > 30, se rompería
  /// el `whereIn` directo igual.
  ///
  /// **Excluye soft-deleted por default** — un adelanto eliminado no
  /// es deuda válida del chofer y no se suma a la liquidación.
  static Stream<List<AdelantoChofer>> streamAdelantosEnRango({
    required DateTime desde,
    required DateTime hasta,
    Set<String>? choferDnis,
    bool incluirEliminados = false,
  }) {
    // Misma fix del bug de doble cuenta en bordes de mes — ver
    // getAdelantosEnRango. Rango semi-abierto [desde, hasta).
    final q = _col.where('fecha',
        isGreaterThanOrEqualTo: Timestamp.fromDate(desde),
        isLessThan: Timestamp.fromDate(hasta));
    return q.snapshots().map((snap) {
      var adelantos =
          snap.docs.map((d) => AdelantoChofer.fromMap(d.id, d.data())).toList();
      if (!incluirEliminados) {
        adelantos = adelantos.where((a) => !a.eliminado).toList();
      }
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

  /// Crea N cuotas mensuales de un adelanto. Genera N docs
  /// `ADELANTOS_CHOFER` con el mismo `grupo_cuotas_id` (uuid común) y
  /// fechas escalonadas mes a mes (mismo día del mes siguiente).
  ///
  /// Reparto del monto:
  ///   - `montoPorCuota = floor5(montoTotal / cuotas)` (redondeo a
  ///     múltiplo de 5 inmediatamente inferior, consistente con la
  ///     regla de redondeo del cálculo de viajes).
  ///   - Si hay resto sin asignar, la PRIMERA cuota lleva la
  ///     diferencia (para que el chofer cobre exactamente el monto
  ///     total acordado).
  ///   - Ejemplo: $100 en 3 cuotas → floor5(33.33) = 30. Resto = 100 −
  ///     30×3 = 10 → cuota 1: $40, cuota 2: $30, cuota 3: $30.
  ///
  /// Fechas: cada cuota es el mismo día del mes siguiente. Si el día
  /// no existe en el mes destino (31 enero + 1 mes), cae al último
  /// día del mes destino (28 o 29 feb según bisiesto).
  ///
  /// Devuelve la lista de IDs de adelantos creados (en orden cuota
  /// 1, 2, …, N) y el `grupoCuotasId` común.
  ///
  /// Pedido Santiago 2026-05-19: descuentos en hasta 6 cuotas con
  /// 1 recibo único que detalla el plan completo.
  static Future<({String grupoCuotasId, List<String> adelantoIds})>
      crearAdelantosEnCuotas({
    required String choferDni,
    String? choferNombre,
    required DateTime fechaPrimera,
    required double montoTotal,
    required int cuotas,
    String? observacion,
    MedioPagoAdelanto medioPago = MedioPagoAdelanto.efectivo,
    String? viajeId,
    required String creadoPorDni,
    String? creadoPorNombre,
  }) async {
    if (montoTotal <= 0) {
      throw ArgumentError('El monto total debe ser mayor a 0.');
    }
    if (cuotas < 2 || cuotas > 6) {
      throw ArgumentError('Las cuotas deben estar entre 2 y 6.');
    }
    if (choferDni.trim().isEmpty) {
      throw ArgumentError('El chofer es obligatorio.');
    }

    final montos = repartirEnCuotas(montoTotal: montoTotal, cuotas: cuotas);
    final fechas = List<DateTime>.generate(
      cuotas,
      (i) => sumarMesesPreservandoDia(fechaPrimera, i),
    );

    // ID único del grupo (timestamp + suffix random — sin uuid lib).
    final grupoCuotasId = 'gc_'
        '${DateTime.now().microsecondsSinceEpoch}'
        '_${(_db.collection('_').doc().id).substring(0, 6)}';

    final batch = _db.batch();
    final ids = <String>[];
    for (var i = 0; i < cuotas; i++) {
      final docRef = _col.doc();
      ids.add(docRef.id);
      batch.set(docRef, <String, dynamic>{
        'chofer_dni': choferDni,
        if (choferNombre != null) 'chofer_nombre': choferNombre,
        'fecha': Timestamp.fromDate(fechas[i]),
        'monto': montos[i],
        if (observacion != null && observacion.trim().isNotEmpty)
          'observacion': observacion.trim(),
        'medio_pago': medioPago.codigo,
        if (viajeId != null && viajeId.trim().isNotEmpty) 'viaje_id': viajeId,
        'pagado': false,
        // Campos de cuota
        'grupo_cuotas_id': grupoCuotasId,
        'cuota_numero': i + 1,
        'cuotas_total': cuotas,
        'creado_en': FieldValue.serverTimestamp(),
        'creado_por_dni': creadoPorDni,
        if (creadoPorNombre != null) 'creado_por_nombre': creadoPorNombre,
        'actualizado_en': FieldValue.serverTimestamp(),
        'actualizado_por_dni': creadoPorDni,
      });
    }
    await batch.commit();
    AppLogger.log(
      'Plan cuotas creado: grupo=$grupoCuotasId chofer=$choferDni '
      'monto_total=$montoTotal cuotas=$cuotas montos=$montos',
    );
    return (grupoCuotasId: grupoCuotasId, adelantoIds: ids);
  }

  /// Trae todas las cuotas de un grupo (incluidas pagadas/eliminadas)
  /// ordenadas por número. Útil para el recibo único del plan.
  static Future<List<AdelantoChofer>> obtenerCuotasDelGrupo(
    String grupoCuotasId,
  ) async {
    final snap = await _col
        .where('grupo_cuotas_id', isEqualTo: grupoCuotasId)
        .get();
    final lista = snap.docs
        .map((d) => AdelantoChofer.fromMap(d.id, d.data()))
        .toList()
      ..sort((a, b) => (a.cuotaNumero ?? 0).compareTo(b.cuotaNumero ?? 0));
    return lista;
  }

  /// Reparte un monto total en N cuotas. Las cuotas 2..N son SIEMPRE múltiplo
  /// de 5 — consistente con la regla de redondeo del módulo. La PRIMERA cuota
  /// lleva la diferencia (resto del floor) para que la suma total cobrada
  /// coincida EXACTAMENTE con el `montoTotal` acordado. Por eso, si
  /// `montoTotal` no es múltiplo de 5 (p. ej. tiene decimales o no termina en
  /// 0/5), la cuota 1 puede no ser múltiplo de 5 — preferimos esa "imperfección
  /// visual" antes que descuadrar la plata (aclaración auditoría 2026-05-22).
  ///
  /// Visible para tests.
  static List<double> repartirEnCuotas({
    required double montoTotal,
    required int cuotas,
  }) {
    // Redondeo a múltiplo de 5 descendente — misma regla que viajes
    final montoBase = ((montoTotal / cuotas) / 5).floor() * 5.0;
    final asignado = montoBase * cuotas;
    final resto = montoTotal - asignado;
    final montos = List<double>.filled(cuotas, montoBase);
    // El resto va a la primera cuota (asegurando que la suma == total
    // acordado). Si resto = 0, todas las cuotas son iguales.
    montos[0] = montoBase + resto;
    return montos;
  }

  /// Suma N meses a una fecha preservando el día del mes. Si el día
  /// no existe en el mes destino (ej. 31 enero + 1 mes), cae al
  /// último día del mes destino (28/29 feb).
  ///
  /// Visible para tests.
  static DateTime sumarMesesPreservandoDia(DateTime base, int meses) {
    if (meses == 0) return base;
    final mesObjetivo = base.month + meses;
    final anioObjetivo = base.year + ((mesObjetivo - 1) ~/ 12);
    final mesNormalizado = ((mesObjetivo - 1) % 12) + 1;
    // Último día del mes destino (día 0 del mes siguiente)
    final ultimoDia =
        DateTime(anioObjetivo, mesNormalizado + 1, 0).day;
    final dia = base.day > ultimoDia ? ultimoDia : base.day;
    return DateTime(
      anioObjetivo,
      mesNormalizado,
      dia,
      base.hour,
      base.minute,
      base.second,
    );
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

  /// **Soft delete** del adelanto. NO borra físicamente — marca el doc
  /// con `eliminado: true` + metadata. Pedido Santiago 2026-05-14:
  /// quedan visibles con filtro "Mostrar eliminados" para que se vea
  /// por qué se quemó cada número de recibo. Idempotente (si ya
  /// estaba eliminado, sobrescribe metadata).
  ///
  /// El `motivo` es opcional. Si es null o vacío string, se persiste
  /// como cadena vacía — no rompe la lectura.
  ///
  /// Si tenía `numero_recibo` impreso, ese correlativo queda quemado
  /// igual (el counter es server-side y no se reusa) — la diferencia
  /// es que ahora se ve POR QUÉ.
  static Future<void> eliminarAdelanto({
    required String adelantoId,
    required String eliminadoPorDni,
    String? motivo,
  }) async {
    if (adelantoId.isEmpty) {
      throw ArgumentError('adelantoId vacío.');
    }
    final motivoSan = (motivo ?? '').trim();
    await _col.doc(adelantoId).set({
      'eliminado': true,
      'eliminado_en': FieldValue.serverTimestamp(),
      'eliminado_por_dni': eliminadoPorDni,
      'eliminado_motivo': motivoSan,
    }, SetOptions(merge: true));
    AppLogger.log(
      'Adelanto soft-deleted: $adelantoId '
      '(por $eliminadoPorDni${motivoSan.isEmpty ? "" : ", motivo: $motivoSan"})',
    );
  }

  /// Revierte un soft delete previo. El operador puede haber eliminado
  /// por error y querer recuperar. Limpia los 4 campos de eliminación.
  static Future<void> restaurarAdelanto(String adelantoId) async {
    if (adelantoId.isEmpty) {
      throw ArgumentError('adelantoId vacío.');
    }
    await _col.doc(adelantoId).set({
      'eliminado': false,
      'eliminado_en': FieldValue.delete(),
      'eliminado_por_dni': FieldValue.delete(),
      'eliminado_motivo': FieldValue.delete(),
    }, SetOptions(merge: true));
    AppLogger.log('Adelanto restaurado: $adelantoId');
  }
}
