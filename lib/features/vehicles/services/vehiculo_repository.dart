import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import 'volvo_api_service.dart';

class VehiculoRepository {
  final FirebaseFirestore _db;
  final VolvoApiService _api;

  VehiculoRepository({
    FirebaseFirestore? firestore,
    VolvoApiService? api,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _api = api ?? VolvoApiService();

  // ================= COLLECTION =================

  static const String collection = AppCollections.vehiculos;

  // ================= STREAM CACHE =================

  final Map<String, Stream<QuerySnapshot>> _streamsCache = {};

  Stream<QuerySnapshot> getVehiculosPorTipo(String tipo) {
    return _streamsCache.putIfAbsent(
      tipo,
      () => _db
          .collection(collection)
          .where('TIPO', isEqualTo: tipo)
          .snapshots(),
    );
  }

  Stream<QuerySnapshot> getVehiculosPorTipos(List<String> tipos) {
    final key = tipos.join(',');

    return _streamsCache.putIfAbsent(
      key,
      () => _db
          .collection(collection)
          .where('TIPO', whereIn: tipos)
          .snapshots(),
    );
  }

  // 🔥 opcional: limpieza manual de cache
  void clearStreamCache() {
    _streamsCache.clear();
  }

  // ================= FIRESTORE =================

  Future<void> actualizarKilometraje({
    required String patente,
    required double km,
  }) async {
    await _db.collection(collection).doc(patente).update({
      'KM_ACTUAL': km,
      'ULTIMA_SINCRO': FieldValue.serverTimestamp(),
      'SINCRO_TIPO': 'AUTO',
    });
  }

  /// Persiste un snapshot completo de telemetría: KM, combustible y
  /// autonomía. Solo escribe los campos que vienen no-nulos para evitar
  /// borrar datos buenos con un null transitorio (típico cuando el camión
  /// está en zona sin cobertura y el response llega incompleto).
  Future<void> actualizarTelemetria({
    required String patente,
    double? km,
    double? nivelCombustiblePct,
    double? nivelAdbluePct,
    double? autonomiaKm,
    double? serviceDistanceKm,
  }) async {
    final updates = <String, dynamic>{
      'ULTIMA_SINCRO': FieldValue.serverTimestamp(),
      'SINCRO_TIPO': 'AUTO',
    };

    if (km != null) updates['KM_ACTUAL'] = km;
    if (nivelCombustiblePct != null) {
      updates['NIVEL_COMBUSTIBLE'] = nivelCombustiblePct;
      updates['ULTIMA_LECTURA_COMBUSTIBLE'] = FieldValue.serverTimestamp();
    }
    if (nivelAdbluePct != null) {
      updates['NIVEL_ADBLUE'] = nivelAdbluePct;
      updates['ULTIMA_LECTURA_ADBLUE'] = FieldValue.serverTimestamp();
    }
    if (autonomiaKm != null) updates['AUTONOMIA_KM'] = autonomiaKm;
    // serviceDistance puede ser negativo (vencido) — lo guardamos igual.
    // El consumidor (pantalla de mantenimiento) lo interpreta como KM
    // restantes al próximo service programado.
    if (serviceDistanceKm != null) {
      updates['SERVICE_DISTANCE_KM'] = serviceDistanceKm;
    }

    // Solo escribimos si hay algo más que el timestamp; sino estaríamos
    // tocando Firestore sin razón.
    if (updates.length <= 2) return;

    await _db.collection(collection).doc(patente).update(updates);
  }

  Future<void> actualizarCampos({
    required String patente,
    required Map<String, dynamic> data,
  }) async {
    await _db.collection(collection).doc(patente).update(data);
  }

  Future<void> actualizarEstado(String patente, String estado) async {
    await _db.collection(collection).doc(patente).update({
      'ESTADO': estado,
    });
  }

  // ================= PAGINACIÓN =================

  /// Trae vehículos paginados ordenados por patente (ID del documento).
  /// Pasar [lastDocument] para traer la siguiente página.
  Future<QuerySnapshot> getPaginados({
    required int limit,
    DocumentSnapshot? lastDocument,
  }) async {
    Query query =
        _db.collection(collection).orderBy(FieldPath.documentId).limit(limit);

    if (lastDocument != null) {
      query = query.startAfterDocument(lastDocument);
    }

    return await query.get();
  }

  // ================= VOLVO CACHE =================

  List<dynamic>? _cacheVolvo;
  DateTime? _lastFetchVolvo;

  /// Si hay un fetch en curso, los callers concurrentes esperan al MISMO
  /// future en lugar de hacer polling con Future.delayed. Esto elimina el
  /// busy-loop y previene race conditions.
  Completer<List<dynamic>>? _inFlightFetch;

  /// Trae la flota de Volvo con cache de 5 minutos.
  /// Si dos llamadas concurrentes llegan a la vez, ambas reciben el mismo
  /// resultado (single-flight pattern).
  Future<List<dynamic>> traerFlotaVolvo() async {
    // 1) Cache válido (< 5 min) → devolver de inmediato.
    if (_cacheVolvo != null &&
        _lastFetchVolvo != null &&
        DateTime.now().difference(_lastFetchVolvo!).inMinutes < 5) {
      return _cacheVolvo!;
    }

    // 2) Hay un fetch en curso → engancharse al mismo future.
    final inFlight = _inFlightFetch;
    if (inFlight != null) {
      return inFlight.future;
    }

    // 3) Disparar nuevo fetch y guardarlo como "in flight".
    final completer = Completer<List<dynamic>>();
    _inFlightFetch = completer;

    try {
      final data = await _api.traerDatosFlota();
      _cacheVolvo = data;
      _lastFetchVolvo = DateTime.now();
      completer.complete(data);
      return data;
    } catch (e) {
      // Ante error, devolvemos el cache anterior si existe.
      // Importante: NO completamos el completer con error (para que las
      // llamadas concurrentes tampoco fallen).
      final fallback = _cacheVolvo ?? <dynamic>[];
      completer.complete(fallback);
      return fallback;
    } finally {
      _inFlightFetch = null;
    }
  }

  // El manager pega directo a `_api.traerTelemetria` cuando necesita
  // datos frescos de un VIN. Antes había un wrapper `traerKmDesdeApi`
  // que solo envolvía en try-catch — se removió porque era redundante.

  // ===========================================================================
  // SNAPSHOTS HISTÓRICOS — colección TELEMETRIA_HISTORICO
  // ===========================================================================

  static const String collectionHistorico = AppCollections.telemetriaHistorico;

  /// Itera el [cacheVolvo] y guarda un snapshot histórico por unidad
  /// para el día de hoy.
  ///
  /// El doc tiene id determinístico `{patente}_{YYYY-MM-DD}`, así que
  /// llamadas múltiples en el mismo día sobreescriben el doc del día
  /// con el último valor (last-write-wins). Eso es lo que queremos
  /// para que `snapshot[día] = último litro_acumulado del día`.
  ///
  /// El reporte de consumo después calcula:
  ///   litros_período = snapshot[hasta] − snapshot[desde − 1]
  ///
  /// Idempotente y barato: una flota chica genera ~30 docs/día.
  Future<void> guardarSnapshotsDiarios(List<dynamic> cacheVolvo) async {
    if (cacheVolvo.isEmpty) return;

    // Construimos un map VIN → patente cruzando con Firestore. El cache
    // de Volvo solo trae VINs; necesitamos la patente para que el id
    // del doc histórico sea legible y consistente con el resto de la app.
    final vehiculos = await _db.collection(collection).get();
    final vinToPatente = <String, String>{};
    for (final doc in vehiculos.docs) {
      final data = doc.data();
      final vin = (data['VIN'] ?? '').toString().trim().toUpperCase();
      if (vin.isNotEmpty && vin != '-') {
        vinToPatente[vin] = doc.id;
      }
    }

    final hoy = DateTime.now();
    final fecha = DateTime(hoy.year, hoy.month, hoy.day);
    final fechaTxt =
        '${fecha.year}-${fecha.month.toString().padLeft(2, '0')}-${fecha.day.toString().padLeft(2, '0')}';

    // Usamos batch para reducir round-trips. Firestore acepta hasta 500
    // ops por batch — para una flota chica nunca llegamos.
    final batch = _db.batch();
    var contadosEscritos = 0;

    for (final v in cacheVolvo) {
      final vin = (v['vin'] ?? '').toString().trim().toUpperCase();
      if (vin.isEmpty) continue;
      final patente = vinToPatente[vin];
      if (patente == null) continue;

      // Litros acumulados — viene del campo Volvo `accumulatedData.totalFuelConsumption`.
      final acc = v['accumulatedData'];
      double litros = 0;
      if (acc is Map) {
        litros = ((acc['totalFuelConsumption'] ?? 0) as num).toDouble();
      }

      // Odómetro — Volvo lo entrega en metros. La cache prioriza
      // `hrTotalVehicleDistance` que es el odómetro de alta resolución.
      final metros = (v['hrTotalVehicleDistance'] ??
              v['lastKnownOdometer'] ??
              0) as num;
      final km = metros.toDouble() / 1000;

      // Sin telemetría útil no escribimos: ahorra storage y evita ruido
      // en el reporte (un snapshot con 0/0 se ve como una caída a cero).
      if (litros == 0 && km == 0) continue;

      final docId = '${patente}_$fechaTxt';
      batch.set(_db.collection(collectionHistorico).doc(docId), {
        'patente': patente,
        'vin': vin,
        'fecha': Timestamp.fromDate(fecha),
        'litros_acumulados': litros,
        'km': km,
        'timestamp': FieldValue.serverTimestamp(),
      });
      contadosEscritos++;
    }

    if (contadosEscritos == 0) return;
    await batch.commit();
  }
}