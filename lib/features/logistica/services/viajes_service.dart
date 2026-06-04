import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/app_logger.dart';
import '../models/tarifa_logistica.dart';
import '../models/viaje.dart';
import '../utils/calculos_viaje.dart';

/// CRUD del módulo Viajes — alta, edición, soft-delete, comprobante
/// de remito en Storage. Toda la persistencia pasa por acá para
/// garantizar que los cálculos de montos sean coherentes (siempre
/// recomputados via `CalculosViaje.calcularTodo` antes de escribir).
///
/// Storage: el comprobante firmado del remito vive en
/// `gs://{bucket}/RemitosViaje/{viajeId}_{ts}.{ext}`. Borrar el viaje
/// (soft-delete) NO borra el archivo de Storage — queda para
/// auditoría / posibles reactivaciones.
class ViajesService {
  ViajesService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseStorage _storage = FirebaseStorage.instance;

  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AppCollections.viajesLogistica);

  // ===========================================================================
  // QUERIES
  // ===========================================================================

  /// Stream de todos los viajes activos, ordenados por fecha de carga
  /// descendente (más recientes arriba). Si `incluirInactivos = true`,
  /// trae también los soft-deleted — útil para auditoría.
  ///
  /// `limit` default 200 (auditoria 2026-05-16). Antes era null →
  /// bajaba TODA la colección en cada rebuild del stream. Con 100
  /// viajes/mes × 12 meses = 1200 docs → cada snapshot parseaba todo
  /// (RAM mobile + Firestore reads). Para casos de reporte que sí
  /// necesitan todo, el caller puede pasar `limit: 0` para forzar sin
  /// limit o un numero alto explicito.
  ///
  /// Auditoria 2026-05-17: filtra client-side los viajes legacy con
  /// `estado='CANCELADO'` o `'POSTERGADO'` (estados removidos 2026-05-14).
  /// Sin esto aparecian como PLANEADO en la lista — operador podia
  /// re-asignar un viaje cancelado.
  static Stream<List<Viaje>> streamViajes({
    bool incluirInactivos = false,
    int? limit = 200,
  }) {
    Query<Map<String, dynamic>> q = _col.orderBy('creado_en', descending: true);
    if (!incluirInactivos) {
      q = q.where('activo', isEqualTo: true);
    }
    if (limit != null && limit > 0) q = q.limit(limit);
    return q.snapshots().map((snap) {
      final filtrados = snap.docs.where((d) {
        final estadoRaw = (d.data()['estado'] ?? '').toString();
        return estadoRaw != 'CANCELADO' && estadoRaw != 'POSTERGADO';
      });
      return filtrados.map((d) => Viaje.fromMap(d.id, d.data())).toList();
    });
  }

  /// Stream de viajes filtrados por chofer. Útil para el tablero
  /// "viajes de Pérez Juan en el último mes".
  /// Aplica el mismo filtro legacy CANCELADO/POSTERGADO que [streamViajes].
  static Stream<List<Viaje>> streamViajesPorChofer(
    String dni, {
    int? limit,
  }) {
    Query<Map<String, dynamic>> q = _col
        .where('chofer_dni', isEqualTo: dni)
        .where('activo', isEqualTo: true)
        .orderBy('creado_en', descending: true);
    if (limit != null) q = q.limit(limit);
    return q.snapshots().map((snap) {
      final filtrados = snap.docs.where((d) {
        final estadoRaw = (d.data()['estado'] ?? '').toString();
        return estadoRaw != 'CANCELADO' && estadoRaw != 'POSTERGADO';
      });
      return filtrados.map((d) => Viaje.fromMap(d.id, d.data())).toList();
    });
  }

  static Stream<Viaje?> streamViaje(String id) {
    return _col.doc(id).snapshots().map(
          (snap) => snap.exists ? Viaje.fromDoc(snap) : null,
        );
  }

  /// Busca viajes activos del chofer creados en las últimas
  /// `ventana` que comparten al menos un `tarifaId` con la lista que
  /// se pasa. Pensado para detectar duplicados al guardar — caso
  /// "operador cargó el mismo viaje 2 veces sin darse cuenta".
  ///
  /// Reusa el índice `chofer_dni + activo + creado_en DESC` que ya
  /// existe (mismo de `ultimoViajeDeChofer`).
  ///
  /// Devuelve hasta 5 candidatos (no esperamos más en 24h).
  static Future<List<Viaje>> buscarPosiblesDuplicados({
    required String choferDni,
    required List<String> tarifaIds,
    Duration ventana = const Duration(hours: 24),
  }) async {
    if (choferDni.isEmpty || tarifaIds.isEmpty) return const [];
    final corte = Timestamp.fromDate(DateTime.now().subtract(ventana));
    final snap = await _col
        .where('chofer_dni', isEqualTo: choferDni)
        .where('activo', isEqualTo: true)
        .where('creado_en', isGreaterThan: corte)
        .orderBy('creado_en', descending: true)
        .limit(10)
        .get();
    if (snap.docs.isEmpty) return const [];
    final tarifaIdsSet = tarifaIds.toSet();
    final candidatos = <Viaje>[];
    for (final d in snap.docs) {
      final v = Viaje.fromMap(d.id, d.data());
      // Comparte tarifa con alguno de los nuevos tramos.
      final compartido = v.tramos.any((t) => tarifaIdsSet.contains(t.tarifaId));
      if (compartido) candidatos.add(v);
      if (candidatos.length >= 5) break;
    }
    return candidatos;
  }

  /// Devuelve el último viaje activo del chofer (ordenado por
  /// creado_en desc), o null si nunca tuvo viaje. One-shot, no
  /// stream — pensado para usar como "sugerencia" cuando el
  /// operador selecciona chofer en el form de viaje nuevo: del
  /// último viaje sacamos el adelanto típico que llevó (algunos
  /// choferes siempre llevan $100k, otros nunca llevan, etc.).
  ///
  /// Reusa el mismo índice que `streamViajesPorChofer`
  /// (chofer_dni ASC + activo ASC + creado_en DESC).
  static Future<Viaje?> ultimoViajeDeChofer(String dni) async {
    final snap = await _col
        .where('chofer_dni', isEqualTo: dni)
        .where('activo', isEqualTo: true)
        .orderBy('creado_en', descending: true)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    final d = snap.docs.first;
    return Viaje.fromMap(d.id, d.data());
  }

  // ===========================================================================
  // ALTA / EDICIÓN
  // ===========================================================================

  /// Crea un viaje nuevo multi-tramo. La tarifa de cada tramo se
  /// persiste como snapshot — cambios futuros en `TARIFAS_LOGISTICA`
  /// no afectan este viaje.
  ///
  /// Recomputa todos los montos via `CalculosViaje.calcularTodoMultiTramo`.
  /// Suma sobre todos los tramos.
  ///
  /// Estado inicial por default: `PLANEADO`.
  ///
  /// Para preservar queries existentes que filtran por `fecha_carga`,
  /// `chofer_dni`, `monto_*`, etc., **denormalizamos al nivel del doc**
  /// los campos del primer tramo + agregados. Los `tramos: [...]`
  /// quedan también en el doc como fuente de verdad para multi-tramo.
  static Future<String> crearViaje({
    required List<TramoViaje> tramos,
    required String choferDni,
    String? choferNombre,
    String? vehiculoId,
    String? engancheId,
    double? adelantoMonto,
    DateTime? adelantoFecha,
    String? adelantoObservacion,
    EstadoViaje estado = EstadoViaje.planeado,
    String? motivoCancelacion,
    DateTime? fechaPostergadoA,
    double? comisionPct,
    required String creadoPorDni,
    String? creadoPorNombre,
  }) async {
    if (tramos.isEmpty) {
      throw ArgumentError('El viaje debe tener al menos 1 tramo.');
    }
    // Los gastos viven adentro de cada tramo desde 2026-05-13 — el
    // helper los suma solo si no le pasamos `gastos` explícito.
    final montos = CalculosViaje.calcularTodoMultiTramo(
      tramos: tramos,
      adelanto: adelantoMonto ?? 0,
      comisionPct: comisionPct,
    );
    final primero = tramos.first;
    final ultimo = tramos.last;

    final docRef = _col.doc();
    final data = <String, dynamic>{
      // ─── Multi-tramo (fuente de verdad) ───
      'tramos': tramos.map((t) => t.toMap()).toList(),

      // ─── Denormalización del primer tramo (compat queries) ───
      'tarifa_id': primero.tarifaId,
      'tarifa_snapshot': primero.tarifaSnapshot.toMap(),
      if (primero.fechaCarga != null)
        'fecha_carga': Timestamp.fromDate(primero.fechaCarga!),
      if (primero.kgCargados != null) 'kg_cargados': primero.kgCargados,
      if (primero.descripcionCarga != null)
        'carga_transportada': primero.descripcionCarga
      else if (primero.producto != null)
        'carga_transportada': primero.producto,
      // ─── Denormalización del último tramo (compat queries) ───
      if (ultimo.fechaDescarga != null)
        'fecha_descarga': Timestamp.fromDate(ultimo.fechaDescarga!),
      if (ultimo.kgDescargados != null) 'kg_descargados': ultimo.kgDescargados,
      if (ultimo.remitoNumero != null) 'remito_numero': ultimo.remitoNumero,
      if (ultimo.remitoUrl != null) 'remito_url': ultimo.remitoUrl,
      if (ultimo.remitoPathStorage != null)
        'remito_path_storage': ultimo.remitoPathStorage,

      // ─── Datos compartidos del viaje ───
      'chofer_dni': choferDni,
      if (choferNombre != null) 'chofer_nombre': choferNombre,
      if (vehiculoId != null) 'vehiculo_id': vehiculoId,
      if (engancheId != null) 'enganche_id': engancheId,
      'estado': estado.codigo,
      if (motivoCancelacion != null) 'motivo_cancelacion': motivoCancelacion,
      if (fechaPostergadoA != null)
        'fecha_postergado_a': Timestamp.fromDate(fechaPostergadoA),
      if (adelantoMonto != null) 'adelanto_monto': adelantoMonto,
      if (adelantoFecha != null)
        'adelanto_fecha': Timestamp.fromDate(adelantoFecha),
      if (adelantoObservacion != null)
        'adelanto_observacion': adelantoObservacion,
      // Gastos ya van adentro de `tramos[i].gastos` — no se persisten
      // al nivel viaje. El `gastos_total` snapshot SÍ se persiste
      // para que LIQUIDACIÓN sume sin recalcular.

      // ─── Agregados (sumas sobre tramos) ───
      'monto_vecchi': montos.montoVecchi,
      'monto_chofer': montos.montoChofer,
      'monto_chofer_redondeado': montos.montoChoferRedondeado,
      'comision_chofer_pct': montos.comisionChoferPct,
      'gastos_total': montos.gastosTotal,
      'liquidacion_chofer': montos.liquidacionChofer,

      // ─── Auditoría ───
      'liquidado': false,
      'creado_en': FieldValue.serverTimestamp(),
      'creado_por_dni': creadoPorDni,
      if (creadoPorNombre != null) 'creado_por_nombre': creadoPorNombre,
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': creadoPorDni,
      'activo': true,
    };

    await docRef.set(data);
    AppLogger.log(
      'Viaje creado: ${docRef.id} chofer=$choferDni tramos=${tramos.length}',
    );
    return docRef.id;
  }

  /// Actualiza un viaje multi-tramo. Recomputa montos sumando todos
  /// los tramos. Reescribe el array completo de tramos (sin merge —
  /// el caller pasa la lista actualizada con tramos agregados,
  /// eliminados o editados).
  static Future<void> actualizarViaje({
    required String viajeId,
    required List<TramoViaje> tramos,
    required String choferDni,
    String? choferNombre,
    String? vehiculoId,
    String? engancheId,
    double? adelantoMonto,
    DateTime? adelantoFecha,
    String? adelantoObservacion,
    EstadoViaje estado = EstadoViaje.planeado,
    String? motivoCancelacion,
    DateTime? fechaPostergadoA,
    double? comisionPct,
    required String actualizadoPorDni,
  }) async {
    if (tramos.isEmpty) {
      throw ArgumentError('El viaje debe tener al menos 1 tramo.');
    }
    final data = _construirDataActualizacion(
      tramos: tramos,
      choferDni: choferDni,
      choferNombre: choferNombre,
      vehiculoId: vehiculoId,
      engancheId: engancheId,
      adelantoMonto: adelantoMonto,
      adelantoFecha: adelantoFecha,
      adelantoObservacion: adelantoObservacion,
      estado: estado,
      motivoCancelacion: motivoCancelacion,
      fechaPostergadoA: fechaPostergadoA,
      comisionPct: comisionPct,
      actualizadoPorDni: actualizadoPorDni,
    );
    await _col.doc(viajeId).update(data);
    AppLogger.log('Viaje actualizado: $viajeId tramos=${tramos.length}');
  }

  /// Arma el data-map de ACTUALIZACIÓN de un viaje (recomputa montos via
  /// `CalculosViaje`). Extraído de [actualizarViaje] para que el recálculo
  /// masivo por cambio de tarifa ([recalcularViajesNoLiquidadosConTarifa])
  /// reuse EXACTAMENTE la misma denormalización + montos, sin divergir ni
  /// pisar datos operativos del tramo.
  static Map<String, dynamic> _construirDataActualizacion({
    required List<TramoViaje> tramos,
    required String choferDni,
    String? choferNombre,
    String? vehiculoId,
    String? engancheId,
    double? adelantoMonto,
    DateTime? adelantoFecha,
    String? adelantoObservacion,
    EstadoViaje estado = EstadoViaje.planeado,
    String? motivoCancelacion,
    DateTime? fechaPostergadoA,
    double? comisionPct,
    required String actualizadoPorDni,
  }) {
    // Gastos viven adentro de cada tramo (refactor 2026-05-13).
    final montos = CalculosViaje.calcularTodoMultiTramo(
      tramos: tramos,
      adelanto: adelantoMonto ?? 0,
      comisionPct: comisionPct,
    );
    final primero = tramos.first;
    final ultimo = tramos.last;

    return <String, dynamic>{
      'tramos': tramos.map((t) => t.toMap()).toList(),

      // Denormalización (sobreescribir aún si null para que queries
      // que filtran por estos campos vean el estado actual).
      'tarifa_id': primero.tarifaId,
      'tarifa_snapshot': primero.tarifaSnapshot.toMap(),
      'fecha_carga': primero.fechaCarga == null
          ? null
          : Timestamp.fromDate(primero.fechaCarga!),
      'kg_cargados': primero.kgCargados,
      'carga_transportada': primero.descripcionCarga ?? primero.producto,
      'fecha_descarga': ultimo.fechaDescarga == null
          ? null
          : Timestamp.fromDate(ultimo.fechaDescarga!),
      'kg_descargados': ultimo.kgDescargados,
      'remito_numero': ultimo.remitoNumero,
      'remito_url': ultimo.remitoUrl,
      'remito_path_storage': ultimo.remitoPathStorage,

      'chofer_dni': choferDni,
      'chofer_nombre': choferNombre,
      'vehiculo_id': vehiculoId,
      'enganche_id': engancheId,
      'estado': estado.codigo,
      // Solo seteamos motivo/postergado si el caller pasa valor — antes
      // se sobrescribían siempre con null, borrando el motivo/postergado
      // existente sin warning.
      if (motivoCancelacion != null) 'motivo_cancelacion': motivoCancelacion,
      if (fechaPostergadoA != null)
        'fecha_postergado_a': Timestamp.fromDate(fechaPostergadoA),
      // Adelanto legacy embebido en el viaje (campos `adelanto_*`).
      // Desde 2026-05-13 los adelantos viven en ADELANTOS_CHOFER pero
      // hay viajes legacy con adelanto_monto persistido. Si el caller
      // pasa null (caso normal en el form nuevo) NO los pisamos —
      // antes se sobrescribían con null y se perdía el snapshot
      // histórico del adelanto, descuadrando la liquidación impresa.
      if (adelantoMonto != null) 'adelanto_monto': adelantoMonto,
      if (adelantoFecha != null)
        'adelanto_fecha': Timestamp.fromDate(adelantoFecha),
      if (adelantoObservacion != null)
        'adelanto_observacion': adelantoObservacion,
      // Gastos van adentro de cada `tramos[i].gastos`. Sin
      // duplicación al nivel raíz.

      'monto_vecchi': montos.montoVecchi,
      'monto_chofer': montos.montoChofer,
      'monto_chofer_redondeado': montos.montoChoferRedondeado,
      'comision_chofer_pct': montos.comisionChoferPct,
      'gastos_total': montos.gastosTotal,
      'liquidacion_chofer': montos.liquidacionChofer,
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': actualizadoPorDni,
    };
  }

  /// Recalcula los viajes ACTIVOS y NO liquidados que usan [tarifa] en
  /// algún tramo, re-resolviendo el snapshot de esos tramos por la FECHA
  /// DE CARGA del tramo (la versión de la tarifa que regía esa fecha).
  /// Preserva los campos NO versionados del snapshot (ruta/dador/etc.) y el
  /// `montoFijoChofer` (posible override manual del operador). Los viajes
  /// liquidados NUNCA se tocan. Idempotente: re-correrlo da el mismo
  /// resultado. Devuelve cuántos viajes se actualizaron.
  ///
  /// Lo dispara `LogisticaService.registrarNuevoPrecio` tras registrar una
  /// vigencia. Client-side + WriteBatch (NO runTransaction — bug Windows),
  /// en lotes de 500 (límite de Firestore).
  static Future<int> recalcularViajesNoLiquidadosConTarifa(
    TarifaLogistica tarifa, {
    required String porDni,
  }) async {
    if (tarifa.id.isEmpty) return 0;
    final snap = await _col.where('activo', isEqualTo: true).get();
    final ahora = DateTime.now();
    final updates = <String, Map<String, dynamic>>{};
    for (final doc in snap.docs) {
      final data = doc.data();
      // Los viajes ya liquidados NO se tocan (ya se le pagó al chofer).
      // Filtramos por `liquidado`, NO por estado: un CONCLUIDO todavía
      // no liquidado SÍ se recalcula.
      if (data['liquidado'] == true) continue;
      final v = Viaje.fromMap(doc.id, data);
      if (!v.tramos.any((t) => t.tarifaId == tarifa.id)) continue;
      // Re-resolver SOLO los tramos de esta tarifa, por su fecha de carga.
      // Los demás tramos quedan intactos. `copyWithImportes` preserva
      // ruta/dador/etc. y el montoFijoChofer (override del operador).
      final nuevosTramos = v.tramos.map((t) {
        if (t.tarifaId != tarifa.id) return t;
        final vig = tarifa.vigenteEn(t.fechaCarga ?? ahora);
        return t.copyWith(
          tarifaSnapshot: t.tarifaSnapshot.copyWithImportes(
            tarifaReal: vig.tarifaReal,
            tarifaChofer: vig.tarifaChofer,
            porcentajeComisionDador: vig.porcentajeComisionDador,
            montoFijoDador: vig.montoFijoDador,
          ),
        );
      }).toList();
      updates[doc.id] = _construirDataActualizacion(
        tramos: nuevosTramos,
        choferDni: v.choferDni,
        choferNombre: v.choferNombre,
        vehiculoId: v.vehiculoId,
        engancheId: v.engancheId,
        adelantoMonto: v.adelantoMonto,
        adelantoFecha: v.adelantoFecha,
        adelantoObservacion: v.adelantoObservacion,
        estado: v.estado,
        motivoCancelacion: v.motivoCancelacion,
        fechaPostergadoA: v.fechaPostergadoA,
        comisionPct: v.comisionChoferPct,
        actualizadoPorDni: porDni,
      );
    }
    if (updates.isEmpty) return 0;
    // WriteBatch en lotes de 500 (límite Firestore). Si un lote falla, la
    // vigencia ya quedó registrada en la tarifa → re-correr este método es
    // idempotente y completa lo que faltó.
    final entries = updates.entries.toList();
    for (var i = 0; i < entries.length; i += 500) {
      final batch = _db.batch();
      for (final e in entries.skip(i).take(500)) {
        batch.update(_col.doc(e.key), e.value);
      }
      await batch.commit();
    }
    AppLogger.log(
      'Recalculados ${updates.length} viaje(s) por nuevo precio de '
      'tarifa ${tarifa.id}',
    );
    return updates.length;
  }

  /// Marca el viaje como liquidado. Sin tocar montos — la liquidación
  /// es solo un flag operativo ("ya le pagamos al chofer").
  static Future<void> marcarLiquidado({
    required String viajeId,
    required String liquidadoPorDni,
  }) async {
    await _col.doc(viajeId).update({
      'liquidado': true,
      'liquidado_en': FieldValue.serverTimestamp(),
      'liquidado_por_dni': liquidadoPorDni,
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': liquidadoPorDni,
    });
  }

  static Future<void> desmarcarLiquidado({
    required String viajeId,
    required String actualizadoPorDni,
  }) async {
    await _col.doc(viajeId).update({
      'liquidado': false,
      'liquidado_en': null,
      'liquidado_por_dni': null,
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': actualizadoPorDni,
    });
  }

  // ===========================================================================
  // SOFT-DELETE
  // ===========================================================================

  /// Desasocia los adelantos que apuntaban a [viajeId] (viaje_id → null) y
  /// marca el motivo en [campoMarca]. NO borra los adelantos: el adelanto se
  /// dio igual, vuelve a quedar suelto (pedido Santiago 2026-06). Devuelve
  /// cuántos liberó.
  static Future<int> _desasociarAdelantos(
      String viajeId, String campoMarca) async {
    final adelantosQ = await _db
        .collection(AppCollections.adelantosChofer)
        .where('viaje_id', isEqualTo: viajeId)
        .get();
    if (adelantosQ.docs.isEmpty) return 0;
    final batch = _db.batch();
    for (final ad in adelantosQ.docs) {
      batch.update(ad.reference, {
        'viaje_id': FieldValue.delete(),
        'actualizado_en': FieldValue.serverTimestamp(),
        campoMarca: viajeId,
      });
    }
    await batch.commit();
    return adelantosQ.docs.length;
  }

  /// Soft-delete: marca `activo: false` con razón y auditoría. Los
  /// viajes borrados no aparecen en el listado por default. Para
  /// reactivar, llamar `reactivar`.
  ///
  /// Decisión Santiago 2026-05-09: NUNCA hard-delete desde la app.
  /// La data tiene valor histórico (auditoría, reportes de cohort,
  /// reconstrucción si hay un error de carga).
  static Future<void> borrarViaje({
    required String viajeId,
    required String borradoPorDni,
    String? motivo,
  }) async {
    await _col.doc(viajeId).update({
      'activo': false,
      'borrado_en': FieldValue.serverTimestamp(),
      'borrado_por_dni': borradoPorDni,
      if (motivo != null) 'motivo_borrado': motivo,
    });
    // El adelanto asociado se dio igual: lo DESASOCIAMOS (vuelve a suelto) pero
    // NO lo borramos (pedido Santiago 2026-06). Si después se reactiva el
    // viaje, `reactivarViaje` lo vuelve a asociar.
    final liberados =
        await _desasociarAdelantos(viajeId, 'liberado_por_borrar_viaje');
    AppLogger.log(
        'Viaje soft-deleted: $viajeId (adelantos desasociados: $liberados)');
  }

  static Future<void> reactivarViaje({
    required String viajeId,
    required String reactivadoPorDni,
  }) async {
    await _col.doc(viajeId).update({
      'activo': true,
      'borrado_en': null,
      'borrado_por_dni': null,
      'motivo_borrado': null,
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': reactivadoPorDni,
    });
    // Re-asociar los adelantos que se liberaron al borrar ESTE viaje y siguen
    // sueltos (si el operador los re-asignó a otro viaje mientras tanto, no los
    // tocamos: solo re-asociamos los que quedaron con viaje_id vacío).
    final q = await _db
        .collection(AppCollections.adelantosChofer)
        .where('liberado_por_borrar_viaje', isEqualTo: viajeId)
        .get();
    final reasociar = q.docs
        .where((d) => (d.data()['viaje_id'] ?? '').toString().isEmpty)
        .toList();
    if (reasociar.isNotEmpty) {
      final batch = _db.batch();
      for (final ad in reasociar) {
        batch.update(ad.reference, {
          'viaje_id': viajeId,
          'liberado_por_borrar_viaje': FieldValue.delete(),
          'actualizado_en': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    }
    AppLogger.log(
        'Viaje reactivado: $viajeId (adelantos re-asociados: ${reasociar.length})');
  }

  /// Hard-delete del viaje: borra el doc completo de Firestore y
  /// limpia los archivos de remito asociados en Storage.
  ///
  /// **Solo se usa durante etapa de testing** (Santiago 2026-05-12)
  /// para limpiar viajes de prueba que ensucian la liquidación.
  /// El flujo recomendado es:
  ///   1. Soft-delete primero (`borrarViaje`) → queda con activo=false.
  ///   2. Recién después, si NO se necesita preservar histórico,
  ///      `eliminarViajeDefinitivo` que destruye el doc.
  ///
  /// Esto previene borrados accidentales: hace falta confirmar dos
  /// veces.
  ///
  /// Storage cleanup: si el viaje tenía comprobantes de remito
  /// subidos, los borramos también (multi-tramo: itera todos los
  /// tramos). Best-effort — si falla algún delete de Storage, lo
  /// loggeamos pero seguimos con el delete del doc.
  static Future<void> eliminarViajeDefinitivo(String viajeId) async {
    if (viajeId.isEmpty) {
      throw ArgumentError('viajeId vacío.');
    }
    // Leer el doc primero para sacar las paths de Storage.
    final snap = await _col.doc(viajeId).get();
    if (!snap.exists) {
      // Ya no existe — operación idempotente.
      AppLogger.log('eliminarViajeDefinitivo: viaje $viajeId no existía.');
      return;
    }
    final data = snap.data() ?? {};

    // Recolectar las paths de remito a borrar. Multi-tramo: cada
    // tramo puede tener su `remito_path_storage`. Single-tramo
    // legacy: la path está al nivel del doc.
    final pathsRemitos = <String>{};
    final tramos = data['tramos'] as List?;
    if (tramos != null) {
      for (final t in tramos) {
        if (t is Map) {
          final p = t['remito_path_storage'];
          if (p is String && p.isNotEmpty) pathsRemitos.add(p);
        }
      }
    }
    final pathLegacy = data['remito_path_storage'];
    if (pathLegacy is String && pathLegacy.isNotEmpty) {
      pathsRemitos.add(pathLegacy);
    }

    // Borrar remitos de Storage en paralelo (best-effort).
    if (pathsRemitos.isNotEmpty) {
      await Future.wait(pathsRemitos.map(borrarRemitoStorage));
    }

    // Desasociar adelantos que referenciaban este viaje (auditoria
    // 2026-05-18): sin esto, el adelanto queda apuntando a un viajeId
    // fantasma. NO se borran — el adelanto se dio igual, vuelve a suelto.
    final liberados =
        await _desasociarAdelantos(viajeId, 'liberado_por_eliminar_viaje');

    // Hard-delete del doc.
    await _col.doc(viajeId).delete();
    AppLogger.log(
      'Viaje eliminado definitivamente: $viajeId '
      '(remitos limpiados: ${pathsRemitos.length}, '
      'adelantos liberados: $liberados)',
    );
  }

  // ===========================================================================
  // STORAGE — comprobante de remito firmado
  // ===========================================================================

  /// Sube el comprobante de remito firmado a Storage. Devuelve
  /// `(downloadUrl, path)` — el caller persiste ambos en
  /// `remito_url` y `remito_path_storage` para poder borrar después
  /// si reemplaza el comprobante.
  ///
  /// `extension` debe incluir el punto: `.pdf`, `.jpg`, `.png`.
  static Future<({String url, String path})> subirRemito({
    required String viajeId,
    required Uint8List bytes,
    required String extension,
    String? contentType,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = extension.startsWith('.') ? extension : '.$extension';
    final path = 'RemitosViaje/${viajeId}_$ts$ext';
    final ref = _storage.ref().child(path);
    final metadata = SettableMetadata(
      contentType: contentType ?? 'application/octet-stream',
    );
    // Timeout 30s (auditoria 2026-05-17): antes una red lenta o
    // intermitente dejaba la UI colgada esperando putData() para
    // siempre. Mismo umbral que StorageService.subirArchivo.
    await ref.putData(bytes, metadata).timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        throw TimeoutException(
          'La conexión es demasiado lenta para subir el remito.',
        );
      },
    );
    final url = await ref.getDownloadURL();
    return (url: url, path: path);
  }

  /// Elimina el archivo de Storage al rechazar / reemplazar un
  /// comprobante. Best-effort: si falla (archivo ya borrado, etc.),
  /// loguea pero no rompe el flujo. NO se llama desde
  /// `borrarViaje` — soft-delete preserva el archivo.
  static Future<void> borrarRemitoStorage(String pathStorage) async {
    try {
      await _storage.ref().child(pathStorage).delete();
    } catch (e, st) {
      AppLogger.recordError(e, st,
          reason: 'Borrar remito storage: $pathStorage');
    }
  }
}
