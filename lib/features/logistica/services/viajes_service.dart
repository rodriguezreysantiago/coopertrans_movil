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

  // ===========================================================================
  // ALTA / EDICIÓN
  // ===========================================================================

  /// Crea un viaje nuevo. La tarifa se persiste como snapshot —
  /// cambios futuros en `TARIFAS_LOGISTICA` no afectan este viaje.
  ///
  /// Recomputa todos los montos via `CalculosViaje.calcularTodo`. El
  /// caller no debe pasar montos calculados; se ignoran si los pasa.
  ///
  /// Estado inicial: `PROGRAMADO` (se transiciona manualmente desde
  /// el form a EN_CURSO / COMPLETADO según corresponda).
  static Future<String> crearViaje({
    required TarifaLogistica tarifa,
    required String choferDni,
    String? choferNombre,
    String? vehiculoId,
    String? engancheId,
    String? cargaTransportada,
    DateTime? fechaCarga,
    double? kgCargados,
    DateTime? fechaDescarga,
    double? kgDescargados,
    String? remitoNumero,
    String? remitoUrl,
    String? remitoPathStorage,
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
    final montos = CalculosViaje.calcularTodo(
      unidadTarifa: tarifa.unidadTarifa,
      tarifaReal: tarifa.tarifaReal,
      tarifaChofer: tarifa.tarifaChofer,
      kgCargados: kgCargados,
      kgDescargados: kgDescargados,
      adelanto: adelantoMonto ?? 0,
      gastos: gastos,
      comisionPct: comisionPct,
    );

    final docRef = _col.doc();
    final data = <String, dynamic>{
      'tarifa_id': tarifa.id,
      'tarifa_snapshot': TarifaSnapshot.fromTarifa(tarifa).toMap(),
      'chofer_dni': choferDni,
      if (choferNombre != null) 'chofer_nombre': choferNombre,
      if (vehiculoId != null) 'vehiculo_id': vehiculoId,
      if (engancheId != null) 'enganche_id': engancheId,
      'estado': estado.codigo,
      if (motivoCancelacion != null) 'motivo_cancelacion': motivoCancelacion,
      if (fechaPostergadoA != null)
        'fecha_postergado_a': Timestamp.fromDate(fechaPostergadoA),
      if (fechaCarga != null) 'fecha_carga': Timestamp.fromDate(fechaCarga),
      if (kgCargados != null) 'kg_cargados': kgCargados,
      if (fechaDescarga != null)
        'fecha_descarga': Timestamp.fromDate(fechaDescarga),
      if (kgDescargados != null) 'kg_descargados': kgDescargados,
      if (remitoNumero != null) 'remito_numero': remitoNumero,
      if (remitoUrl != null) 'remito_url': remitoUrl,
      if (remitoPathStorage != null) 'remito_path_storage': remitoPathStorage,
      if (cargaTransportada != null) 'carga_transportada': cargaTransportada,
      if (adelantoMonto != null) 'adelanto_monto': adelantoMonto,
      if (adelantoFecha != null)
        'adelanto_fecha': Timestamp.fromDate(adelantoFecha),
      if (adelantoObservacion != null)
        'adelanto_observacion': adelantoObservacion,
      'gastos': gastos.map((g) => g.toMap()).toList(),
      'monto_vecchi': montos.montoVecchi,
      'monto_chofer': montos.montoChofer,
      'monto_chofer_redondeado': montos.montoChoferRedondeado,
      'comision_chofer_pct': montos.comisionChoferPct,
      'gastos_total': montos.gastosTotal,
      'liquidacion_chofer': montos.liquidacionChofer,
      'liquidado': false,
      'creado_en': FieldValue.serverTimestamp(),
      'creado_por_dni': creadoPorDni,
      if (creadoPorNombre != null) 'creado_por_nombre': creadoPorNombre,
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': creadoPorDni,
      'activo': true,
    };

    await docRef.set(data);
    AppLogger.log('Viaje creado: ${docRef.id} chofer=$choferDni');
    return docRef.id;
  }

  /// Actualiza campos del viaje. Recomputa montos siempre — si el
  /// caller cambió la tarifa, los kgs, adelanto o gastos, todos los
  /// montos se recalculan en sincronía.
  ///
  /// Si el caller quiere actualizar SOLO ciertos campos sin tocar
  /// otros, debe pasar los originales explícitamente. Para edición
  /// pequeña (ej. solo el remito_numero), usar `actualizarCampos`.
  static Future<void> actualizarViaje({
    required String viajeId,
    required TarifaLogistica tarifa,
    required String choferDni,
    String? choferNombre,
    String? vehiculoId,
    String? engancheId,
    String? cargaTransportada,
    DateTime? fechaCarga,
    double? kgCargados,
    DateTime? fechaDescarga,
    double? kgDescargados,
    String? remitoNumero,
    String? remitoUrl,
    String? remitoPathStorage,
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
    final montos = CalculosViaje.calcularTodo(
      unidadTarifa: tarifa.unidadTarifa,
      tarifaReal: tarifa.tarifaReal,
      tarifaChofer: tarifa.tarifaChofer,
      kgCargados: kgCargados,
      kgDescargados: kgDescargados,
      adelanto: adelantoMonto ?? 0,
      gastos: gastos,
      comisionPct: comisionPct,
    );

    final data = <String, dynamic>{
      'tarifa_id': tarifa.id,
      'tarifa_snapshot': TarifaSnapshot.fromTarifa(tarifa).toMap(),
      'chofer_dni': choferDni,
      'chofer_nombre': choferNombre,
      'vehiculo_id': vehiculoId,
      'enganche_id': engancheId,
      'estado': estado.codigo,
      'motivo_cancelacion': motivoCancelacion,
      'fecha_postergado_a':
          fechaPostergadoA == null ? null : Timestamp.fromDate(fechaPostergadoA),
      'fecha_carga':
          fechaCarga == null ? null : Timestamp.fromDate(fechaCarga),
      'kg_cargados': kgCargados,
      'fecha_descarga':
          fechaDescarga == null ? null : Timestamp.fromDate(fechaDescarga),
      'kg_descargados': kgDescargados,
      'remito_numero': remitoNumero,
      'remito_url': remitoUrl,
      'remito_path_storage': remitoPathStorage,
      'carga_transportada': cargaTransportada,
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
    AppLogger.log('Viaje actualizado: $viajeId');
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
