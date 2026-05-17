import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../core/services/audit_log_service.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/fecha_dialog.dart';
import '../../asignaciones/services/asignacion_enganche_service.dart';
import '../../asignaciones/services/asignacion_vehiculo_service.dart';

// =============================================================================
// SERVICIO DE ACTUALIZACIÓN — NAMESPACE VehiculoActions
//
// Centraliza las operaciones que tocan Firestore/Storage para gestión de
// flota desde el bottom sheet de detalle del vehículo.
//
// Espejo conceptual de `EmpleadoActions` (papeles del chofer): cada
// inline-edit del sheet de detalle delega acá. Centralizamos para que:
// - Cada update lleve `fecha_ultima_actualizacion` para trackear cambios.
// - Audit log fire-and-forget (`AuditAccion.editarVehiculo`) en bitácora.
// - Manejo de errores con SnackBar consistente.
//
// **Lo que NO hace este servicio**: la sincronización con Volvo
// (`VolvoApiService`), uploads ad-hoc fuera de papeles, ni la lógica del
// odómetro retroactivo (TELEMETRIA_HISTORICO). Eso queda en sus servicios
// dedicados.
// =============================================================================

enum _FuenteArchivoVehiculo { camara, galeria, archivo }

class VehiculoActions {
  VehiculoActions._();

  /// Actualiza un campo simple en el doc del vehículo. `valor` puede
  /// ser `null` para limpiar el campo.
  static Future<void> dato(
    BuildContext context,
    String patente,
    String campo,
    dynamic valor,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final pat = patente.trim().toUpperCase();
    if (pat.isEmpty) {
      AppFeedback.errorOn(messenger, 'Patente vacía.');
      return;
    }
    try {
      await FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .doc(pat)
          .update({
        campo: valor,
        'fecha_ultima_actualizacion': FieldValue.serverTimestamp(),
      });
      unawaited(AuditLog.registrar(
        accion: AuditAccion.editarVehiculo,
        entidad: 'VEHICULOS',
        entidadId: pat,
        detalles: {'campo': campo, 'nuevo_valor': valor?.toString() ?? ''},
      ));
      AppFeedback.successOn(messenger, 'Actualizado: $campo');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo actualizar $campo. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  /// Sheet con opciones para gestionar un vencimiento del vehículo
  /// (RTO, Seguro, Extintor Cabina, Extintor Exterior): editar fecha,
  /// ver el archivo cargado, o subir/reemplazar el archivo.
  ///
  /// Espejo del `EmpleadoActions.documento` que usa la ficha de
  /// personal — mismo UX para el admin.
  static void documento(
    BuildContext context, {
    required String patente,
    required String etiqueta,
    required String campoFecha,
    required String campoUrl,
    required String? fechaActual,
    required String? urlActual,
  }) {
    final pat = patente.trim().toUpperCase();
    final navigator = Navigator.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (bCtx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
          border: const Border(
              top: BorderSide(color: AppColors.accentGreen, width: 2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              etiqueta,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 15),
            ListTile(
              leading:
                  const Icon(Icons.event_note, color: AppColors.accentBlue),
              title: const Text('Editar fecha de vencimiento',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                navigator.pop();
                _seleccionarFecha(context, pat, campoFecha, fechaActual);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.visibility, color: AppColors.accentGreen),
              title: const Text('Ver documento digital',
                  style: TextStyle(color: Colors.white)),
              enabled: urlActual != null &&
                  urlActual.isNotEmpty &&
                  urlActual != '-',
              onTap: () {
                navigator.pop();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PreviewScreen(
                      url: urlActual!,
                      titulo: '$etiqueta - $pat',
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file,
                  color: AppColors.accentOrange),
              title: Text(
                urlActual != null &&
                        urlActual.isNotEmpty &&
                        urlActual != '-'
                    ? 'Reemplazar archivo cargado'
                    : 'Subir archivo nuevo',
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                'Foto o PDF',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              onTap: () {
                navigator.pop();
                _reemplazarDocumento(
                  context: context,
                  patente: pat,
                  etiqueta: etiqueta,
                  campoUrl: campoUrl,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ===== privados ==========================================================

  static Future<void> _seleccionarFecha(
    BuildContext context,
    String patente,
    String campo,
    String? fechaActual,
  ) async {
    final initial = AppFormatters.tryParseFecha(fechaActual ?? '');
    final picked = await pickFecha(
      context,
      initial: initial,
      titulo:
          'Vencimiento ${campo.replaceAll("VENCIMIENTO_", "").replaceAll("_", " ")}',
    );
    if (picked != null && context.mounted) {
      final nuevaFecha = AppFormatters.aIsoFechaLocal(picked);
      await dato(context, patente, campo, nuevaFecha);
    }
  }

  /// Sheet de origen del archivo (cámara / galería / PDF) y upload.
  static Future<void> _reemplazarDocumento({
    required BuildContext context,
    required String patente,
    required String etiqueta,
    required String campoUrl,
  }) async {
    final picker = ImagePicker();

    final fuente = await showModalBottomSheet<_FuenteArchivoVehiculo>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sCtx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(sCtx).colorScheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(25)),
          border: const Border(
              top: BorderSide(color: AppColors.accentGreen, width: 2)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  etiqueta,
                  style: const TextStyle(
                    color: AppColors.accentGreen,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              ListTile(
                leading:
                    const Icon(Icons.camera_alt, color: AppColors.accentGreen),
                title: const Text('Tomar foto con la cámara',
                    style: TextStyle(color: Colors.white)),
                onTap: () =>
                    Navigator.pop(sCtx, _FuenteArchivoVehiculo.camara),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library,
                    color: AppColors.accentBlue),
                title: const Text('Foto desde la galería',
                    style: TextStyle(color: Colors.white)),
                onTap: () =>
                    Navigator.pop(sCtx, _FuenteArchivoVehiculo.galeria),
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf,
                    color: AppColors.accentRed),
                title: const Text('PDF / archivo del dispositivo',
                    style: TextStyle(color: Colors.white)),
                onTap: () =>
                    Navigator.pop(sCtx, _FuenteArchivoVehiculo.archivo),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );

    if (fuente == null) return;
    if (!context.mounted) return;

    Uint8List? bytes;
    String nombreOriginal = '';
    String extension = 'jpg';

    switch (fuente) {
      case _FuenteArchivoVehiculo.camara:
      case _FuenteArchivoVehiculo.galeria:
        final source = fuente == _FuenteArchivoVehiculo.camara
            ? ImageSource.camera
            : ImageSource.gallery;
        final img = await picker.pickImage(source: source, imageQuality: 60);
        if (img == null) return;
        bytes = await img.readAsBytes();
        nombreOriginal = img.name;
        extension = 'jpg';
        break;
      case _FuenteArchivoVehiculo.archivo:
        final res = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
          withData: true,
        );
        final picked = res?.files.singleOrNull;
        if (picked == null || picked.bytes == null) return;
        bytes = picked.bytes;
        nombreOriginal = picked.name;
        extension = picked.extension?.toLowerCase() ?? 'pdf';
        break;
    }

    if (!context.mounted) return;
    if (bytes == null) return;
    final storagePath =
        'VEHICULOS/$patente/${campoUrl}_${DateTime.now().millisecondsSinceEpoch}.$extension';
    await _subirArchivo(
        context, patente, bytes, nombreOriginal, storagePath, campoUrl);
  }

  static Future<void> _subirArchivo(
    BuildContext context,
    String patente,
    Uint8List bytes,
    String nombreOriginal,
    String storagePath,
    String dbCampo,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      AppFeedback.infoOn(messenger, 'Subiendo archivo...');
      final downloadUrl = await StorageService().subirArchivo(
        bytes: bytes,
        nombreOriginal: nombreOriginal,
        rutaStorage: storagePath,
      );
      if (context.mounted) {
        await dato(context, patente, dbCampo, downloadUrl);
      }
    } catch (e, s) {
      if (context.mounted) {
        AppFeedback.errorTecnicoOn(
          messenger,
          usuario:
              'No se pudo subir el archivo. Verificá tu conexión y probá de nuevo.',
          tecnico: e,
          stack: s,
        );
      }
    }
  }

  // ===========================================================================
  // SOFT-DELETE: dar de baja / reactivar
  // ===========================================================================

  /// Da de baja un vehículo SIN borrar el doc:
  ///   1. Si tiene chofer asignado, cierra esa asignación.
  ///   2. Si es TRACTOR con enganche acoplado, cierra esa asignación.
  ///   3. Si es ENGANCHE acoplado a un tractor, cierra la asignación.
  ///   4. Borra los archivos de Storage (ARCHIVO_*) best-effort.
  ///   5. Vacía los campos VENCIMIENTO_* y ARCHIVO_* en el doc.
  ///   6. Setea ACTIVO=false + metadata.
  ///
  /// Al [reactivar] más tarde, los vencimientos quedan vacíos y el
  /// admin tiene que cargar todo de nuevo. La asignación con un chofer
  /// NO se restaura.
  static Future<void> darDeBaja(
    BuildContext context, {
    required String patente,
    required String? motivo,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final pat = patente.trim().toUpperCase();
    if (pat.isEmpty) {
      AppFeedback.errorOn(messenger, 'Patente vacía.');
      return;
    }

    final adminDni = PrefsService.dni;
    final db = FirebaseFirestore.instance;
    final vehRef = db.collection(AppCollections.vehiculos).doc(pat);

    try {
      final snap = await vehRef.get();
      if (!snap.exists) {
        AppFeedback.errorOn(messenger, 'Vehículo $pat no existe.');
        return;
      }
      final data = snap.data() ?? const <String, dynamic>{};
      final tipo = (data['TIPO'] ?? '').toString().toUpperCase();

      // 1) Si tiene chofer asignado, cerrar esa asignación.
      // Buscamos por EMPLEADOS.VEHICULO == patente (espejo) — la
      // cascade del enganche la hace AsignacionVehiculoService solo.
      try {
        final qChofer = await db
            .collection(AppCollections.empleados)
            .where('VEHICULO', isEqualTo: pat)
            .limit(1)
            .get();
        if (qChofer.docs.isNotEmpty) {
          final dniChofer = qChofer.docs.first.id;
          await AsignacionVehiculoService().cambiarAsignacion(
            choferDni: dniChofer,
            nuevaPatente: null,
            asignadoPorDni: adminDni,
            motivo: 'Baja del vehículo',
          );
        }
      } catch (e) {
        // ignore: avoid_print
        print('darDeBaja vehículo: cerrar asig chofer falló: $e');
      }

      // 2/3) Cerrar asignación de enganche según el tipo.
      try {
        if (tipo == AppTiposVehiculo.tractor) {
          // Buscar enganche actualmente acoplado a este tractor.
          final qEng = await db
              .collection(AppCollections.asignacionesEnganche)
              .where('tractor_id', isEqualTo: pat)
              .where('hasta', isNull: true)
              .limit(1)
              .get();
          if (qEng.docs.isNotEmpty) {
            final engancheId =
                qEng.docs.first.data()['enganche_id']?.toString();
            if (engancheId != null && engancheId.isNotEmpty) {
              await AsignacionEngancheService().cambiarAsignacion(
                engancheId: engancheId,
                nuevoTractorId: null,
                asignadoPorDni: adminDni,
                motivo: 'Baja del tractor',
              );
            }
          }
        } else {
          // ENGANCHE: cerrar su asignación activa con el tractor que tenga.
          await AsignacionEngancheService().cambiarAsignacion(
            engancheId: pat,
            nuevoTractorId: null,
            asignadoPorDni: adminDni,
            motivo: 'Baja del enganche',
          );
        }
      } catch (e) {
        // ignore: avoid_print
        print('darDeBaja vehículo: cerrar asig enganche falló: $e');
      }

      // 4) Borrar archivos de Storage (best-effort).
      final specs = AppVencimientos.forTipo(tipo);
      final urlsParaBorrar = <String>[
        for (final s in specs) (data[s.campoArchivo] ?? '').toString(),
        (data['ARCHIVO_FOTO'] ?? '').toString(),
      ];
      for (final url in urlsParaBorrar) {
        if (url.isEmpty || url == '-') continue;
        try {
          await FirebaseStorage.instance.refFromURL(url).delete();
        } catch (e) {
          // ignore: avoid_print
          print('darDeBaja vehículo: no pude borrar $url: $e');
        }
      }

      // 5 + 6) Vaciar VENCIMIENTO_*/ARCHIVO_* y marcar ACTIVO=false.
      final updates = <String, dynamic>{
        AppActivo.campo: false,
        AppActivo.campoBajaEn: FieldValue.serverTimestamp(),
        AppActivo.campoBajaPorDni: adminDni,
        if (motivo != null && motivo.trim().isNotEmpty)
          AppActivo.campoBajaMotivo: motivo.trim(),
        AppActivo.campoReactivadoEn: null,
        AppActivo.campoReactivadoPorDni: null,
        // Foto del vehículo borrada también.
        'ARCHIVO_FOTO': null,
        // Estado liberado por si alguien todavía lo lee desde acá.
        'ESTADO': 'LIBRE',
        'fecha_ultima_actualizacion': FieldValue.serverTimestamp(),
      };
      for (final s in specs) {
        updates[s.campoFecha] = null;
        updates[s.campoArchivo] = null;
      }
      await vehRef.update(updates);

      unawaited(AuditLog.registrar(
        accion: AuditAccion.darDeBajaVehiculo,
        entidad: 'VEHICULOS',
        entidadId: pat,
        detalles: {
          if (motivo != null && motivo.trim().isNotEmpty)
            'motivo': motivo.trim(),
          'archivos_borrados': urlsParaBorrar
              .where((u) => u.isNotEmpty && u != '-')
              .length,
        },
      ));

      AppFeedback.successOn(messenger, 'Vehículo dado de baja.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo dar de baja el vehículo. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  /// Reactiva un vehículo dado de baja. Setea ACTIVO=true + metadata.
  /// Los vencimientos quedan vacíos. NO se restaura asignación con chofer.
  static Future<void> reactivar(
    BuildContext context, {
    required String patente,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final pat = patente.trim().toUpperCase();
    if (pat.isEmpty) {
      AppFeedback.errorOn(messenger, 'Patente vacía.');
      return;
    }
    final adminDni = PrefsService.dni;
    try {
      await FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .doc(pat)
          .update({
        AppActivo.campo: true,
        AppActivo.campoReactivadoEn: FieldValue.serverTimestamp(),
        AppActivo.campoReactivadoPorDni: adminDni,
        'fecha_ultima_actualizacion': FieldValue.serverTimestamp(),
      });
      unawaited(AuditLog.registrar(
        accion: AuditAccion.reactivarVehiculo,
        entidad: 'VEHICULOS',
        entidadId: pat,
        detalles: const {},
      ));
      AppFeedback.successOn(
          messenger, 'Vehículo reactivado. Cargá los vencimientos.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo reactivar el vehículo. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  /// Confirm dialog antes de dar de baja. Pide motivo opcional.
  static Future<void> confirmarYDarDeBaja(
    BuildContext context, {
    required String patente,
  }) async {
    final motivoCtrl = TextEditingController();
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        title: const Text('Dar de baja el vehículo',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$patente quedará INACTIVO.\n\n'
              'Se cerrarán las asignaciones de chofer y enganche, y se '
              'borrarán todos los vencimientos y archivos cargados.\n\n'
              'Al reactivarlo más adelante hay que volver a cargar todo.',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: motivoCtrl,
              maxLength: 200,
              maxLines: 2,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Motivo (opcional)',
                hintText: 'Ej. baja del parque, vendido, etc.',
                labelStyle: TextStyle(color: Colors.white54),
                hintStyle: TextStyle(color: Colors.white24),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('DAR DE BAJA',
                style: TextStyle(
                  color: AppColors.accentRed,
                  fontWeight: FontWeight.bold,
                )),
          ),
        ],
      ),
    );
    if (confirmado != true) {
      motivoCtrl.dispose();
      return;
    }
    final motivoTxt = motivoCtrl.text;
    motivoCtrl.dispose();
    if (!context.mounted) return;
    await darDeBaja(context, patente: patente, motivo: motivoTxt);
  }

  /// Confirm dialog para reactivar.
  static Future<void> confirmarYReactivar(
    BuildContext context, {
    required String patente,
  }) async {
    final ok = await AppConfirmDialog.show(
      context,
      title: 'Reactivar vehículo',
      message:
          '$patente va a volver a estar ACTIVO. Los vencimientos quedan vacíos '
          'hasta que los cargues. La asignación con chofer NO se restaura.',
      confirmLabel: 'REACTIVAR',
    );
    if (ok != true) return;
    if (!context.mounted) return;
    await reactivar(context, patente: patente);
  }
}
