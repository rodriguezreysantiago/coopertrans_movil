import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/audit_log_service.dart';
import '../../fleet_map/services/sitrack_snapshot_service.dart';
import '../models/asignacion_enganche.dart';
import '../models/asignacion_vehiculo.dart';

/// Un enganche que un chofer LLEVÓ (derivado chofer→tractor→enganche), con el
/// período EFECTIVO en que estuvieron juntos. Para la auditoría por chofer.
class EngancheLlevado {
  final String enganche;
  final String tractor;
  final DateTime desde;
  final DateTime? hasta;
  const EngancheLlevado({
    required this.enganche,
    required this.tractor,
    required this.desde,
    required this.hasta,
  });
}

/// Único punto de entrada para cambiar la asignación tractor↔enganche.
///
/// Espejo conceptual de [AsignacionVehiculoService] (chofer↔tractor)
/// pero para la relación tractor↔enganche. **Por qué existe:** sin este
/// registro temporal, no se puede calcular cuántos km recorrió una
/// cubierta de enganche. La cubierta está en el enganche, pero los km
/// los recorre el tractor — y un enganche puede pasar por varios
/// tractores en su vida útil.
///
/// **Modelo**: cada cambio cierra la asignación activa anterior
/// (`hasta = now`) y crea una nueva (`desde: now, hasta: null`).
///
/// **Sincronización con flujos existentes**: este servicio es el
/// destino final. Los callers son:
/// - Admin desde la app cuando asigna ENGANCHE a un chofer (via
///   `EmpleadoActions.enganche`): después de cambiar el espejo en
///   EMPLEADOS, llama a este servicio para registrar el cambio en
///   el log temporal usando el tractor actual del chofer.
/// - Aprobación de revisión `SOLICITUD_ENGANCHE` (via
///   `RevisionService.finalizarRevision`): idem.
/// - Cambio de tractor del chofer (via `AsignacionVehiculoService`):
///   si el chofer tenía un enganche, automáticamente se reasigna ese
///   enganche del tractor viejo al nuevo. Mantiene la coherencia.
class AsignacionEngancheService {
  final FirebaseFirestore _db;

  AsignacionEngancheService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  /// Convención del codebase: "sin asignar" se representa con `-`.
  static const String _sinAsignar = '-';

  /// Cambia la asignación del [engancheId] al [nuevoTractorId].
  ///
  /// - Si [nuevoTractorId] es `null`, vacío o `-`, desengancha
  ///   (queda sin tractor — solo cierra la asignación activa).
  /// - Si [nuevoTractorId] ya tenía OTRO enganche activo, ese enganche
  ///   queda también desenganchado (cierra su asignación). Esto evita
  ///   inconsistencias: un tractor solo puede tener UN enganche por vez.
  /// - Si el enganche ya estaba en ese tractor (no-op), retorna sin
  ///   tocar nada.
  ///
  /// La operación corre como writes secuenciales (NO usa runTransaction).
  /// Mismo motivo que [AsignacionVehiculoService.cambiarAsignacion]: el
  /// plugin C++ de cloud_firestore en Windows desktop crashea con
  /// abort() nativo cuando una runTransaction mezcla reads + tx.set +
  /// tx.update (ver `feedback_windows_cloud_firestore_bugs.md`).
  ///
  /// El audit log (fire-and-forget) se dispara después.
  Future<void> cambiarAsignacion({
    required String engancheId,
    required String? nuevoTractorId,
    required String asignadoPorDni,
    String? tractorModelo,
    String? asignadoPorNombre,
    String? motivo,
  }) async {
    final engancheLimpio = _normalizarPatente(engancheId);
    if (engancheLimpio == null) {
      throw ArgumentError('engancheId vacío');
    }
    final asignadorLimpio = asignadoPorDni.trim();
    if (asignadorLimpio.isEmpty) {
      throw ArgumentError('asignadoPorDni vacío');
    }

    final tractorNorm = _normalizarPatente(nuevoTractorId);
    final desenganchar = tractorNorm == null;

    // Pre-lectura del doc del enganche para validar que sea enganche
    // (no tractor — tractores no se enganchan a otros tractores).
    final engancheSnap =
        await _db.collection(AppCollections.vehiculos).doc(engancheLimpio).get();
    if (!engancheSnap.exists) {
      throw StateError('Vehículo $engancheLimpio no existe');
    }
    final engancheData = engancheSnap.data() ?? const <String, dynamic>{};
    final tipoEnganche = (engancheData['TIPO'] ?? '').toString().toUpperCase();
    if (tipoEnganche == AppTiposVehiculo.tractor) {
      throw StateError(
        '$engancheLimpio es TRACTOR, no se puede usar como enganche.',
      );
    }

    // Pre-lectura del tractor (si se está asignando uno) para validar y
    // tomar snapshot del modelo.
    String? tractorModeloFinal = tractorModelo;
    if (!desenganchar) {
      final tractorSnap = await _db
          .collection(AppCollections.vehiculos)
          .doc(tractorNorm)
          .get();
      if (!tractorSnap.exists) {
        throw StateError('Tractor $tractorNorm no existe');
      }
      final tractorData = tractorSnap.data() ?? const <String, dynamic>{};
      final tipoTractor = (tractorData['TIPO'] ?? '').toString().toUpperCase();
      if (tipoTractor != AppTiposVehiculo.tractor) {
        throw StateError(
          '$tractorNorm tiene TIPO=$tipoTractor, no es TRACTOR.',
        );
      }
      tractorModeloFinal ??= tractorData['MODELO']?.toString();
    }

    final asignadoPorNombreFinal =
        asignadoPorNombre ?? await _leerNombreEmpleado(asignadorLimpio);

    // === Lecturas en paralelo: asignación activa del enganche + del
    // tractor. Ambos `.get()` arrancan en paralelo al asignarse.
    final colAsig = _db.collection(AppCollections.asignacionesEnganche);
    final activaEngancheQF = colAsig
        .where('enganche_id', isEqualTo: engancheLimpio)
        .where('hasta', isNull: true)
        .limit(1)
        .get();
    final activaTractorQF = desenganchar
        ? null
        : colAsig
            .where('tractor_id', isEqualTo: tractorNorm)
            .where('hasta', isNull: true)
            .limit(1)
            .get();

    final activaEngancheQ = await activaEngancheQF;
    final activaTractorQ =
        activaTractorQF == null ? null : await activaTractorQF;

    final activaEngancheDoc =
        activaEngancheQ.docs.isEmpty ? null : activaEngancheQ.docs.first;
    final tractorActualEnganche =
        activaEngancheDoc?.data()['tractor_id']?.toString();
    final tractorAnterior = tractorActualEnganche;

    final activaTractorDoc =
        (activaTractorQ == null || activaTractorQ.docs.isEmpty)
            ? null
            : activaTractorQ.docs.first;
    final engancheActualTractor =
        activaTractorDoc?.data()['enganche_id']?.toString();

    // === No-ops.
    if (desenganchar && activaEngancheDoc == null) {
      return;
    }
    if (!desenganchar &&
        tractorActualEnganche == tractorNorm &&
        engancheActualTractor == engancheLimpio) {
      return;
    }

    final ahora = Timestamp.now();

    // === Snapshot de odómetro Sitrack del/los tractor(es) involucrado(s).
    // El "odómetro" en ASIGNACIONES_ENGANCHE es siempre el del TRACTOR
    // (el enganche no tiene odómetro propio — los km los acumula el
    // tractor que lo arrastra). Best-effort: si Sitrack no contesta,
    // queda null.
    final snapSvc = SitrackSnapshotService(firestore: _db);
    final snapTractorNuevoF =
        desenganchar ? null : snapSvc.obtener(tractorNorm);
    final snapTractorViejoF = (activaEngancheDoc != null &&
            tractorActualEnganche != null &&
            tractorActualEnganche.isNotEmpty &&
            tractorActualEnganche != _sinAsignar)
        ? snapSvc.obtener(tractorActualEnganche)
        : null;
    final snapTractorNuevo = snapTractorNuevoF == null
        ? SitrackSnapshot.empty
        : await snapTractorNuevoF;
    final snapTractorViejo = snapTractorViejoF == null
        ? SitrackSnapshot.empty
        : await snapTractorViejoF;

    // === Crear nueva asignación primero (minimiza ventana sin asignación).
    if (!desenganchar) {
      final nuevaRef = colAsig.doc();
      await nuevaRef.set(<String, dynamic>{
        'enganche_id': engancheLimpio,
        'tractor_id': tractorNorm,
        'tractor_modelo': tractorModeloFinal,
        'desde': ahora,
        'hasta': null,
        'asignado_por_dni': asignadorLimpio,
        'asignado_por_nombre': asignadoPorNombreFinal,
        // Snapshot del odómetro del TRACTOR al momento del enganche.
        // Permite calcular cuántos km del tractor cubrieron las
        // cubiertas del enganche durante este período (Fase 2 Gomería).
        if (snapTractorNuevo.odometer != null)
          'odometer_inicial': snapTractorNuevo.odometer,
        if (snapTractorNuevo.reportDate != null)
          'odometer_inicial_ts':
              Timestamp.fromDate(snapTractorNuevo.reportDate!),
        if (motivo != null && motivo.trim().isNotEmpty)
          'motivo': motivo.trim(),
      });
    }

    // === Cerrar asignación activa del enganche (si tenía). El odómetro
    // de cierre es el del tractor que TENÍA el enganche (el viejo).
    if (activaEngancheDoc != null) {
      final updateClose = <String, dynamic>{'hasta': ahora};
      if (snapTractorViejo.odometer != null) {
        updateClose['odometer_final'] = snapTractorViejo.odometer;
        if (snapTractorViejo.reportDate != null) {
          updateClose['odometer_final_ts'] =
              Timestamp.fromDate(snapTractorViejo.reportDate!);
        }
      }
      await activaEngancheDoc.reference.update(updateClose);
    }

    // === Cerrar asignación del tractor si tenía OTRO enganche. El
    // odómetro de cierre es el del tractor NUEVO (que es el mismo donde
    // ese OTRO enganche estaba hasta ahora — lo estamos liberando).
    if (activaTractorDoc != null &&
        activaTractorDoc.id != activaEngancheDoc?.id) {
      final updateClose = <String, dynamic>{'hasta': ahora};
      if (snapTractorNuevo.odometer != null) {
        updateClose['odometer_final'] = snapTractorNuevo.odometer;
        if (snapTractorNuevo.reportDate != null) {
          updateClose['odometer_final_ts'] =
              Timestamp.fromDate(snapTractorNuevo.reportDate!);
        }
      }
      await activaTractorDoc.reference.update(updateClose);
    }

    // === Espejo en VEHICULOS.ESTADO del enganche (LIBRE / OCUPADO).
    // Los enganches usan el mismo campo ESTADO que los tractores.
    // Antes este service no lo tocaba — quedaba "OCUPADO" forever
    // aunque la asignación estuviera cerrada. Best-effort, si falla
    // no bloqueamos.
    try {
      await _db.collection(AppCollections.vehiculos).doc(engancheLimpio).update(
        {'ESTADO': desenganchar ? 'LIBRE' : 'OCUPADO'},
      );
    } catch (e) {
      // ignore: avoid_print
      print('Aviso: actualizar ESTADO del enganche $engancheLimpio falló: $e');
    }

    // Si había OTRO enganche acoplado al tractor nuevo, ese se
    // desacopló automáticamente — liberamos su ESTADO también.
    if (activaTractorDoc != null &&
        activaTractorDoc.id != activaEngancheDoc?.id) {
      final otroEngancheId =
          activaTractorDoc.data()['enganche_id']?.toString();
      if (otroEngancheId != null && otroEngancheId.isNotEmpty) {
        try {
          await _db
              .collection(AppCollections.vehiculos)
              .doc(otroEngancheId)
              .update({'ESTADO': 'LIBRE'});
        } catch (e) {
          // ignore: avoid_print
          print(
              'Aviso: liberar ESTADO del otro enganche $otroEngancheId falló: $e');
        }
      }
    }

    // 6) Audit log fuera de la transaction (fire-and-forget).
    unawaited(AuditLog.registrar(
      accion: desenganchar
          ? AuditAccion.desvincularEquipo
          : AuditAccion.asignarEquipo,
      entidad: AppCollections.vehiculos,
      entidadId: engancheLimpio,
      detalles: {
        'campo': 'TRACTOR_ASIGNADO',
        'tractor_anterior': tractorAnterior ?? '',
        'tractor_nuevo': tractorNorm ?? '',
        if (motivo != null && motivo.trim().isNotEmpty) 'motivo': motivo.trim(),
      },
    ));
  }

  /// Devuelve la asignación que estaba activa para [engancheId] en
  /// el instante [fecha]. Usar para calcular km recorridos por una
  /// cubierta del enganche en una ventana temporal específica.
  ///
  /// Devuelve `null` si en ese momento no había nadie enganchado, o si
  /// el enganche no existe.
  Future<AsignacionEnganche?> obtenerTractorEnFecha({
    required String engancheId,
    required DateTime fecha,
  }) async {
    final patenteLimpia = engancheId.trim();
    if (patenteLimpia.isEmpty) return null;

    final fechaTs = Timestamp.fromDate(fecha);

    final snap = await _db
        .collection(AppCollections.asignacionesEnganche)
        .where('enganche_id', isEqualTo: patenteLimpia)
        .where('desde', isLessThanOrEqualTo: fechaTs)
        .orderBy('desde', descending: true)
        .limit(1)
        .get();

    if (snap.docs.isEmpty) return null;
    final candidata = AsignacionEnganche.fromDoc(snap.docs.first);

    if (candidata.hasta != null && !candidata.hasta!.isAfter(fecha)) {
      return null;
    }
    return candidata;
  }

  /// Enganches que un chofer LLEVÓ, derivados de sus asignaciones de tractor:
  /// para cada período chofer↔tractor, qué enganches estuvieron en ese tractor
  /// (solapando). Devuelve el período EFECTIVO (intersección chofer ∩ enganche),
  /// más reciente primero. 1 query por tractor (cardinalidad por chofer chica).
  /// Para la auditoría "por chofer".
  Future<List<EngancheLlevado>> enganchesLlevadosPorChofer(
    List<AsignacionVehiculo> asignacionesTractor,
  ) async {
    final out = <EngancheLlevado>[];
    for (final at in asignacionesTractor) {
      final tractor = at.vehiculoId.trim();
      if (tractor.isEmpty) continue;
      final snap = await _db
          .collection(AppCollections.asignacionesEnganche)
          .where('tractor_id', isEqualTo: tractor)
          .get();
      for (final d in snap.docs) {
        final ae = AsignacionEnganche.fromDoc(d);
        // Intersección [at.desde, at.hasta] ∩ [ae.desde, ae.hasta]
        // (hasta == null = período abierto/activo).
        final inicio = ae.desde.isAfter(at.desde) ? ae.desde : at.desde;
        DateTime? fin;
        if (at.hasta == null) {
          fin = ae.hasta;
        } else if (ae.hasta == null) {
          fin = at.hasta;
        } else {
          fin = at.hasta!.isBefore(ae.hasta!) ? at.hasta : ae.hasta;
        }
        if (fin == null || inicio.isBefore(fin)) {
          out.add(EngancheLlevado(
            enganche: ae.engancheId,
            tractor: tractor,
            desde: inicio,
            hasta: fin,
          ));
        }
      }
    }
    out.sort((a, b) => b.desde.compareTo(a.desde));
    return out;
  }

  /// Devuelve TODAS las asignaciones del [engancheId] que se solapan
  /// con la ventana `[desde, hasta]`. Cada item viene con sus fechas
  /// reales — no recortadas a la ventana. El caller debe recortar al
  /// calcular km (no contar tiempo fuera de la ventana).
  ///
  /// Usado por el cálculo de km recorridos por una cubierta de
  /// enganche: itera estos resultados y para cada tractor pide los km
  /// del período correspondiente.
  Future<List<AsignacionEnganche>> obtenerHistorialEnVentana({
    required String engancheId,
    required DateTime desde,
    required DateTime hasta,
  }) async {
    final patenteLimpia = engancheId.trim();
    if (patenteLimpia.isEmpty) return const <AsignacionEnganche>[];

    // Filtramos asignaciones que no terminaron antes del inicio de
    // la ventana. Es decir: hasta es null (activa) O hasta > desde.
    final desdeTs = Timestamp.fromDate(desde);
    final hastaTs = Timestamp.fromDate(hasta);

    // Asignaciones que empezaron antes del fin de la ventana.
    final snap = await _db
        .collection(AppCollections.asignacionesEnganche)
        .where('enganche_id', isEqualTo: patenteLimpia)
        .where('desde', isLessThanOrEqualTo: hastaTs)
        .orderBy('desde')
        .get();

    return snap.docs
        .map(AsignacionEnganche.fromDoc)
        .where((a) {
          // Filtramos las que terminaron antes del inicio de la ventana.
          if (a.hasta == null) return true;
          return a.hasta!.isAfter(desde) ||
              a.hasta!.isAtSameMomentAs(desde) ||
              a.hasta!.isAfter(desdeTs.toDate());
        })
        .toList();
  }

  /// Stream del historial completo de [engancheId] (más recientes
  /// primero). [limit] por default 50.
  Stream<List<AsignacionEnganche>> streamHistorialPorEnganche(
    String engancheId, {
    int limit = 50,
  }) {
    final patenteLimpia = engancheId.trim();
    if (patenteLimpia.isEmpty) {
      return Stream.value(const <AsignacionEnganche>[]);
    }
    return _db
        .collection(AppCollections.asignacionesEnganche)
        .where('enganche_id', isEqualTo: patenteLimpia)
        .orderBy('desde', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(AsignacionEnganche.fromDoc).toList());
  }

  /// Stream del historial completo de [tractorId].
  Stream<List<AsignacionEnganche>> streamHistorialPorTractor(
    String tractorId, {
    int limit = 50,
  }) {
    final patenteLimpia = tractorId.trim();
    if (patenteLimpia.isEmpty) {
      return Stream.value(const <AsignacionEnganche>[]);
    }
    return _db
        .collection(AppCollections.asignacionesEnganche)
        .where('tractor_id', isEqualTo: patenteLimpia)
        .orderBy('desde', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(AsignacionEnganche.fromDoc).toList());
  }

  /// Normaliza la patente recibida: limpia espacios, devuelve null si
  /// está vacía o representa "sin asignar".
  static String? _normalizarPatente(String? raw) {
    if (raw == null) return null;
    final t = raw.trim();
    if (t.isEmpty || t == _sinAsignar) return null;
    return t.toUpperCase();
  }

  /// Lee `EMPLEADOS/{dni}.NOMBRE`. Devuelve `null` si no existe o
  /// si la lectura falla (es snapshot opcional, no bloquea el cambio).
  Future<String?> _leerNombreEmpleado(String dni) async {
    try {
      final snap =
          await _db.collection(AppCollections.empleados).doc(dni).get();
      return snap.data()?['NOMBRE']?.toString();
    } catch (_) {
      return null;
    }
  }
}
