import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
// `flutter/foundation` re-exporta Uint8List (de dart:typed_data) además de
// debugPrint, así que cubre los dos usos de este archivo en un solo import.
import 'package:flutter/foundation.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/storage_service.dart';
import '../../asignaciones/services/asignacion_enganche_service.dart';
import '../../asignaciones/services/asignacion_vehiculo_service.dart';

/// Plan de acciones a aplicar cuando una solicitud REVISIONES se aprueba.
///
/// Es el resultado de `planificarAprobacion(datos)` — una función pura
/// que NO toca Firestore. El caller ([RevisionService.finalizarRevision])
/// traduce este plan a operaciones reales (batch update / cambio de
/// asignación / etc.).
///
/// Separar el "qué hacer" del "cómo hacerlo" hace que la lógica de
/// negocio (calcular qué actualizar según el tipo de solicitud) sea
/// testeable sin mockear FirebaseFirestore + Storage + Auth.
class RevisionAprobadaPlan {
  /// Colección de destino del cambio (típicamente `EMPLEADOS`).
  final String colDestino;

  /// ID del doc en [colDestino] (típicamente DNI del chofer).
  final String idDoc;

  /// Campo original que se pidió actualizar (`VENCIMIENTO_*`,
  /// `SOLICITUD_VEHICULO`, `SOLICITUD_ENGANCHE`, etc.).
  final String campoAct;

  /// Campos a actualizar en `colDestino/idDoc`. Si está vacío, no se
  /// hace ningún update sobre el doc destino (caso típico:
  /// `SOLICITUD_VEHICULO` que delega todo a `AsignacionVehiculoService`).
  final Map<String, dynamic> camposDestino;

  /// Updates adicionales a hacer en VEHICULOS (campo `ESTADO`). Lista en
  /// lugar de Map para soportar 0, 1 o 2 vehículos — caso enganche
  /// puede tener nueva unidad → `OCUPADO` y vieja unidad → `LIBRE`.
  final List<({String patente, String estado})> vehiculosUpdates;

  /// Si no es `null`, hay que llamar a `AsignacionVehiculoService.
  /// cambiarAsignacion` con estos datos ANTES del batch (el servicio
  /// corre su propia transaction).
  final ({String choferDni, String nuevaPatente, String motivo})?
      asignacionRequest;

  /// Si no es `null`, hay que registrar el cambio en
  /// `ASIGNACIONES_ENGANCHE` después del batch (vía
  /// `AsignacionEngancheService`). El caller debe leer el tractor actual
  /// del chofer para asociarlo — la función pura no hace queries.
  final ({
    String choferDni,
    String engancheNuevo,
    String? engancheAnterior,
    String motivo,
  })? engancheRequest;

  const RevisionAprobadaPlan({
    required this.colDestino,
    required this.idDoc,
    required this.campoAct,
    this.camposDestino = const {},
    this.vehiculosUpdates = const [],
    this.asignacionRequest,
    this.engancheRequest,
  });
}

/// Función pura: planifica las acciones cuando una solicitud REVISIONES
/// se aprueba. **No toca Firestore.**
///
/// Throws [StateError] si los datos están incompletos (falta
/// `coleccion_destino`, `dni` o `campo` — los 3 son obligatorios para
/// construir el path del doc destino y Firestore reventaría con
/// `document path must be a non-empty string`).
///
/// Reglas según el campo de la solicitud:
/// - `VENCIMIENTO_*` → actualiza la fecha + el campo `ARCHIVO_*` espejo
///   + `ultima_auditoria` con `serverTimestamp()`.
/// - `SOLICITUD_VEHICULO` → delega a `AsignacionVehiculoService` (no
///   modifica el doc destino directo, devuelve `asignacionRequest`).
/// - `SOLICITUD_ENGANCHE` → setea `EMPLEADOS.ENGANCHE = nueva` +
///   actualiza `VEHICULOS.{nueva}.ESTADO = OCUPADO` y
///   `VEHICULOS.{anterior}.ESTADO = LIBRE` (skip si "-" o "SIN ASIGNAR").
/// - Cualquier otro campo → actualiza con `fecha_vencimiento`.
RevisionAprobadaPlan planificarAprobacion(Map<String, dynamic> datos) {
  final colDestino = (datos['coleccion_destino'] ?? '').toString().trim();
  final idDoc = (datos['dni'] ?? '').toString().trim();
  final campoAct = (datos['campo'] ?? '').toString().trim();

  if (colDestino.isEmpty || idDoc.isEmpty || campoAct.isEmpty) {
    throw StateError(
      'La solicitud está incompleta (faltan datos de destino o '
      'campo a actualizar). Se eliminó del listado.',
    );
  }

  if (campoAct.startsWith('VENCIMIENTO_')) {
    final campoArchivo = campoAct.replaceAll('VENCIMIENTO_', 'ARCHIVO_');
    return RevisionAprobadaPlan(
      colDestino: colDestino,
      idDoc: idDoc,
      campoAct: campoAct,
      camposDestino: {
        campoAct: datos['fecha_vencimiento'],
        campoArchivo: datos['url_archivo'],
        'ultima_auditoria': FieldValue.serverTimestamp(),
      },
    );
  }

  if (campoAct == 'SOLICITUD_VEHICULO') {
    final nuevaUnidad = (datos['patente'] ?? '').toString().trim();
    return RevisionAprobadaPlan(
      colDestino: colDestino,
      idDoc: idDoc,
      campoAct: campoAct,
      asignacionRequest: (
        choferDni: idDoc,
        nuevaPatente: nuevaUnidad,
        motivo: 'Aprobado desde REVISIONES',
      ),
    );
  }

  if (campoAct == 'SOLICITUD_ENGANCHE') {
    final nuevaUnidad = (datos['patente'] ?? '').toString().trim();
    final unidadActual = (datos['unidad_actual'] ?? '').toString().trim();
    final vehiculosUpdates = <({String patente, String estado})>[];
    if (nuevaUnidad.isNotEmpty && nuevaUnidad != '-') {
      vehiculosUpdates.add((patente: nuevaUnidad, estado: 'OCUPADO'));
    }
    final tieneUnidadAnteriorValida = unidadActual.isNotEmpty &&
        unidadActual != '-' &&
        unidadActual.toUpperCase() != 'SIN ASIGNAR';
    if (tieneUnidadAnteriorValida) {
      vehiculosUpdates.add((patente: unidadActual, estado: 'LIBRE'));
    }
    return RevisionAprobadaPlan(
      colDestino: colDestino,
      idDoc: idDoc,
      campoAct: campoAct,
      camposDestino: {'ENGANCHE': nuevaUnidad},
      vehiculosUpdates: vehiculosUpdates,
      // Sumamos engancheRequest para que `finalizarRevision` registre
      // en ASIGNACIONES_ENGANCHE (Fase 0 Gomería). El caller debe leer
      // el tractor del chofer (idDoc) para asociar enganche↔tractor.
      engancheRequest: (
        choferDni: idDoc,
        engancheNuevo: nuevaUnidad,
        engancheAnterior: tieneUnidadAnteriorValida ? unidadActual : null,
        motivo: 'Aprobado desde REVISIONES',
      ),
    );
  }

  // SEGURIDAD (2026-05-30): cualquier OTRO `campo` se RECHAZA. Antes el fallback
  // escribía {campo: fecha_vencimiento} con `campo` arbitrario controlado por
  // quien creó la solicitud → un chofer podía pedir campo:'ROL' (o 'ACTIVO',
  // 'EMPRESA_CUIT'...) y, al aprobar el admin, auto-promoverse a ADMIN. Solo se
  // aceptan VENCIMIENTO_* y las 2 solicitudes (ya manejadas arriba). Defensa en
  // profundidad: la rule de REVISIONES valida la misma whitelist en el create.
  throw StateError(
    'Campo de solicitud no permitido ("$campoAct"). Solo se aceptan '
    'renovaciones de vencimiento (VENCIMIENTO_*) o solicitudes de '
    'cambio de unidad/enganche.',
  );
}

/// Servicio del feature de revisiones.
///
/// Centraliza:
/// - **Chofer**: registrar una nueva solicitud de renovación de papel
///   (sube el archivo + crea el doc en `REVISIONES`).
/// - **Admin**: aprobar/rechazar revisiones (procesa el cambio en la
///   colección destino y elimina la solicitud).
/// - Stream paginado de pendientes.
///
/// Antes esto vivía en `core/services/firebase_service.dart` mezclado
/// con storage, empleados y paginación.
class RevisionService {
  final FirebaseFirestore _db;
  final FirebaseStorage _storage;
  final StorageService _storageService;

  RevisionService({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    StorageService? storageService,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance,
        _storageService = storageService ?? StorageService();

  // ===========================================================================
  // CHOFER → registrar solicitud
  // ===========================================================================

  /// Sube el comprobante a Storage y crea el documento de solicitud
  /// en la colección `REVISIONES`.
  ///
  /// [archivoBytes] son los bytes del archivo (cross-platform: el caller
  /// los obtiene de `XFile.readAsBytes()` o `FilePicker(withData: true)`).
  /// [nombreOriginal] se usa solo para extraer la extensión.
  Future<void> registrarSolicitud({
    required String dni,
    required String nombreUsuario,
    required String etiqueta,
    required String campo,
    required Uint8List archivoBytes,
    required String nombreOriginal,
    required String fechaS,
    required String coleccionDestino,
  }) async {
    // Defensa profunda: nunca dejamos crear solicitudes con campos críticos
    // vacíos. De lo contrario, después el admin no la puede aprobar porque
    // .doc('') revienta. Mejor fallar acá con mensaje claro.
    if (dni.trim().isEmpty ||
        campo.trim().isEmpty ||
        coleccionDestino.trim().isEmpty) {
      throw ArgumentError(
        'Solicitud incompleta: faltan dni, campo o coleccion_destino.',
      );
    }

    try {
      final extension = nombreOriginal.split('.').last.toLowerCase();
      final nombreArchivo =
          'REVISIONES/${dni}_${campo}_${DateTime.now().millisecondsSinceEpoch}.$extension';

      // Reutilizamos el StorageService genérico (incluye timeout y content-type)
      final url = await _storageService.subirArchivo(
        bytes: archivoBytes,
        nombreOriginal: nombreOriginal,
        rutaStorage: nombreArchivo,
      );

      await _db.collection(AppCollections.revisiones).add({
        'dni': dni.trim(),
        'nombre_usuario': nombreUsuario,
        'campo': campo,
        'coleccion_destino': coleccionDestino,
        'etiqueta': etiqueta,
        'fecha_vencimiento': fechaS,
        'url_archivo': url,
        'path_storage': nombreArchivo,
        'estado': 'PENDIENTE',
        'fecha_solicitud': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw Exception('Error al registrar solicitud: $e');
    }
  }

  // ===========================================================================
  // ADMIN → aprobar/rechazar
  // ===========================================================================

  /// Aprueba o rechaza una revisión.
  ///
  /// Si [aprobado]:
  /// - Para `VENCIMIENTO_*`: actualiza fecha + URL del archivo en el doc destino.
  /// - Para `SOLICITUD_VEHICULO/SOLICITUD_ENGANCHE`: cambia la asignación del
  ///   chofer y actualiza ESTADO de las unidades vieja/nueva.
  ///
  /// Si rechazada: borra el archivo de Storage para no acumular basura.
  ///
  /// En ambos casos, la solicitud se elimina al final (no quedan registros
  /// históricos). Si querés histórico, cambiar `delete` por un `update` con
  /// `estado: APROBADO`/`RECHAZADO`.
  Future<void> finalizarRevision({
    required String idSolicitud,
    required bool aprobado,
    Map<String, dynamic>? datos,
  }) async {
    // Sin id de la solicitud no podemos ni siquiera borrarla; abortamos
    // antes de tocar Firestore para evitar el "document path must be a
    // non-empty string" que se ve clarísimo en producción.
    if (idSolicitud.trim().isEmpty) {
      throw StateError('La solicitud no tiene ID válido.');
    }

    try {
      final batch = _db.batch();

      if (aprobado && datos != null) {
        // Toda la lógica de "qué actualizar según el tipo de solicitud"
        // vive en `planificarAprobacion`, que es función pura testeable.
        // Acá solo traducimos el plan a ops Firestore.
        RevisionAprobadaPlan plan;
        try {
          plan = planificarAprobacion(datos);
        } on StateError {
          // Datos incompletos: limpiamos la solicitud inválida y
          // re-lanzamos el StateError con el mensaje del planificador.
          await _db
              .collection(AppCollections.revisiones)
              .doc(idSolicitud)
              .delete();
          rethrow;
        }

        // Cambio de tractor: el servicio centralizado escribe
        // ASIGNACIONES_VEHICULO + EMPLEADOS.VEHICULO + VEHICULOS.ESTADO
        // + audit log en su propia transaction. Corre ANTES del batch
        // porque está fuera de él. La pequeña pérdida de atomicidad con
        // el delete de REVISIONES es aceptable: si falla en el medio,
        // re-aprobar es no-op idempotente.
        if (plan.asignacionRequest != null) {
          final adminUid = FirebaseAuth.instance.currentUser?.uid ?? '';
          await AsignacionVehiculoService().cambiarAsignacion(
            choferDni: plan.asignacionRequest!.choferDni,
            nuevaPatente: plan.asignacionRequest!.nuevaPatente,
            asignadoPorDni: adminUid,
            motivo: plan.asignacionRequest!.motivo,
          );
        }

        // Updates de ESTADO en VEHICULOS (caso enganche).
        for (final v in plan.vehiculosUpdates) {
          batch.update(
            _db.collection(AppCollections.vehiculos).doc(v.patente),
            {'ESTADO': v.estado},
          );
        }

        // Update al doc destino (típicamente EMPLEADOS/{dni}).
        if (plan.camposDestino.isNotEmpty) {
          batch.update(
            _db.collection(plan.colDestino).doc(plan.idDoc),
            plan.camposDestino,
          );
        }

        // Cambio de enganche: registramos en ASIGNACIONES_ENGANCHE
        // (Fase 0 Gomería). Necesitamos el tractor actual del chofer
        // para asociar enganche↔tractor. Si el chofer no tiene tractor,
        // skipeamos con warning — el enganche queda registrado en
        // EMPLEADOS pero sin asignación física a un tractor.
        if (plan.engancheRequest != null) {
          final req = plan.engancheRequest!;
          try {
            final empSnap = await _db
                .collection(AppCollections.empleados)
                .doc(req.choferDni)
                .get();
            final tractorActual = (empSnap.data()?['VEHICULO'] ?? '')
                .toString()
                .trim()
                .toUpperCase();
            final tieneTractor =
                tractorActual.isNotEmpty && tractorActual != '-';
            if (tieneTractor) {
              final adminUid = FirebaseAuth.instance.currentUser?.uid ?? '';
              final svc = AsignacionEngancheService();
              if (req.engancheAnterior != null) {
                await svc.cambiarAsignacion(
                  engancheId: req.engancheAnterior!,
                  nuevoTractorId: null,
                  asignadoPorDni: adminUid,
                  motivo: req.motivo,
                );
              }
              await svc.cambiarAsignacion(
                engancheId: req.engancheNuevo,
                nuevoTractorId: tractorActual,
                asignadoPorDni: adminUid,
                motivo: req.motivo,
              );
            } else {
              debugPrint(
                'Aviso: chofer ${req.choferDni} sin tractor asignado, '
                'no se registra ASIGNACIONES_ENGANCHE',
              );
            }
          } catch (e) {
            // No bloqueamos la aprobación de la revisión por un fallo
            // del log temporal — es defensivo.
            debugPrint('Aviso: ASIGNACIONES_ENGANCHE falló (no bloquea): $e');
          }
        }
      }

      // Si fue rechazada, borramos el archivo de Storage
      if (!aprobado &&
          datos != null &&
          datos['path_storage'] != null &&
          datos['path_storage'].toString().isNotEmpty) {
        try {
          await _storage.ref().child(datos['path_storage']).delete();
        } catch (e) {
          debugPrint('No se pudo borrar archivo: $e');
        }
      }

      // Eliminar la solicitud al cerrar el batch
      batch.delete(_db.collection(AppCollections.revisiones).doc(idSolicitud));
      await batch.commit();
    } on StateError {
      // Re-lanzamos los errores estructurados sin envolverlos: el caller
      // los muestra con su mensaje legible.
      rethrow;
    } catch (e) {
      throw Exception('Error al finalizar la revisión: $e');
    }
  }

  // ===========================================================================
  // STREAMS
  // ===========================================================================

  /// Stream de las primeras 50 solicitudes pendientes,
  /// ordenadas por fecha (más recientes primero).
  Stream<QuerySnapshot> getPendientes() {
    return _db
        .collection(AppCollections.revisiones)
        .where('estado', isEqualTo: 'PENDIENTE')
        .orderBy('fecha_solicitud', descending: true)
        .limit(50)
        .snapshots();
  }
}
