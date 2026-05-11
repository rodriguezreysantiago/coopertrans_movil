import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/app_logger.dart';
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
  static Stream<List<Viaje>> streamViajes({
    bool incluirInactivos = false,
    int? limit,
  }) {
    Query<Map<String, dynamic>> q = _col.orderBy('creado_en', descending: true);
    if (!incluirInactivos) {
      q = q.where('activo', isEqualTo: true);
    }
    if (limit != null) q = q.limit(limit);
    return q.snapshots().map(
          (snap) => snap.docs.map((d) => Viaje.fromMap(d.id, d.data())).toList(),
        );
  }

  /// Stream de viajes filtrados por chofer. Útil para el tablero
  /// "viajes de Pérez Juan en el último mes".
  static Stream<List<Viaje>> streamViajesPorChofer(
    String dni, {
    int? limit,
  }) {
    Query<Map<String, dynamic>> q = _col
        .where('chofer_dni', isEqualTo: dni)
        .where('activo', isEqualTo: true)
        .orderBy('creado_en', descending: true);
    if (limit != null) q = q.limit(limit);
    return q.snapshots().map(
          (snap) => snap.docs.map((d) => Viaje.fromMap(d.id, d.data())).toList(),
        );
  }

  static Stream<Viaje?> streamViaje(String id) {
    return _col.doc(id).snapshots().map(
          (snap) => snap.exists ? Viaje.fromDoc(snap) : null,
        );
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
    List<GastoViaje> gastos = const [],
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
    final montos = CalculosViaje.calcularTodoMultiTramo(
      tramos: tramos,
      adelanto: adelantoMonto ?? 0,
      gastos: gastos,
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
      if (ultimo.kgDescargados != null)
        'kg_descargados': ultimo.kgDescargados,
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
      'gastos': gastos.map((g) => g.toMap()).toList(),

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
    List<GastoViaje> gastos = const [],
    EstadoViaje estado = EstadoViaje.planeado,
    String? motivoCancelacion,
    DateTime? fechaPostergadoA,
    double? comisionPct,
    required String actualizadoPorDni,
  }) async {
    if (tramos.isEmpty) {
      throw ArgumentError('El viaje debe tener al menos 1 tramo.');
    }
    final montos = CalculosViaje.calcularTodoMultiTramo(
      tramos: tramos,
      adelanto: adelantoMonto ?? 0,
      gastos: gastos,
      comisionPct: comisionPct,
    );
    final primero = tramos.first;
    final ultimo = tramos.last;

    final data = <String, dynamic>{
      'tramos': tramos.map((t) => t.toMap()).toList(),

      // Denormalización (sobreescribir aún si null para que queries
      // que filtran por estos campos vean el estado actual).
      'tarifa_id': primero.tarifaId,
      'tarifa_snapshot': primero.tarifaSnapshot.toMap(),
      'fecha_carga': primero.fechaCarga == null
          ? null
          : Timestamp.fromDate(primero.fechaCarga!),
      'kg_cargados': primero.kgCargados,
      'carga_transportada':
          primero.descripcionCarga ?? primero.producto,
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
      'motivo_cancelacion': motivoCancelacion,
      'fecha_postergado_a':
          fechaPostergadoA == null ? null : Timestamp.fromDate(fechaPostergadoA),
      'adelanto_monto': adelantoMonto,
      'adelanto_fecha':
          adelantoFecha == null ? null : Timestamp.fromDate(adelantoFecha),
      'adelanto_observacion': adelantoObservacion,
      'gastos': gastos.map((g) => g.toMap()).toList(),

      'monto_vecchi': montos.montoVecchi,
      'monto_chofer': montos.montoChofer,
      'monto_chofer_redondeado': montos.montoChoferRedondeado,
      'comision_chofer_pct': montos.comisionChoferPct,
      'gastos_total': montos.gastosTotal,
      'liquidacion_chofer': montos.liquidacionChofer,
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': actualizadoPorDni,
    };

    await _col.doc(viajeId).update(data);
    AppLogger.log('Viaje actualizado: $viajeId tramos=${tramos.length}');
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
    AppLogger.log('Viaje soft-deleted: $viajeId');
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
    AppLogger.log('Viaje reactivado: $viajeId');
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
    await ref.putData(bytes, metadata);
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
