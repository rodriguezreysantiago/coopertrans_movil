import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
// `flutter/services` re-exporta Uint8List (dart:typed_data) — lo usa
// `_subirArchivo` para los uploads cross-platform.
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/audit_log_service.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/digit_only_formatter.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/phone_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/fecha_dialog.dart';
import '../../asignaciones/services/asignacion_enganche_service.dart';
import '../../asignaciones/services/asignacion_vehiculo_service.dart';

// =============================================================================
// SERVICIOS DE ACTUALIZACIÓN — NAMESPACE EmpleadoActions
//
// Centraliza las operaciones que tocan Firestore/Storage para gestión de
// personal desde las pantallas de admin (dialogs, sheets, audit, feedback).
//
// Capa UI-aware: abre showModalBottomSheet, levanta SnackBars, registra
// `AuditLog`, etc. La app trabaja directamente con `Map<String,dynamic>`
// desde Firestore — no hay capa intermedia de modelos tipados.
//
// Originalmente vivía como `_Actualizar` privado dentro de
// `admin_personal_lista_screen.dart`. Extraído acá para bajar de 1295
// líneas a ~740 ese archivo y permitir reuso desde otras pantallas.
// =============================================================================

enum _FuenteArchivoChofer { camara, galeria, archivo }

class EmpleadoActions {
  EmpleadoActions._();

  /// Actualiza un campo simple en EMPLEADOS.
  static Future<void> dato(
    BuildContext context,
    String dni,
    String campo,
    dynamic valor,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final cambios = <String, dynamic>{
        campo: valor,
        'fecha_ultima_actualizacion': FieldValue.serverTimestamp(),
      };
      // Al editar la EMPRESA, denormalizamos el CUIT en EMPRESA_CUIT para que la
      // regla de Firestore deje al chofer leer SU propia empresa empleadora.
      if (campo == 'EMPRESA') {
        cambios['EMPRESA_CUIT'] =
            AppEmpresasEmpleadoras.cuitDeStringEmpresa(valor?.toString());
      }
      await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(dni.trim())
          .update(cambios);
      unawaited(AuditLog.registrar(
        accion: AuditAccion.editarChofer,
        entidad: 'EMPLEADOS',
        entidadId: dni.trim(),
        detalles: {'campo': campo, 'nuevo_valor': valor?.toString() ?? ''},
      ));
      AppFeedback.successOn(messenger, 'Dato actualizado: $campo');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo actualizar $campo. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  /// Guarda el TELÉFONO normalizado en EMPLEADOS, pero NO pisa el número
  /// bueno si el admin tipeó algo que no es un teléfono AR válido.
  ///
  /// El bug 2026-05-20 (teléfono de Errazu "se guardaba vacío") tenía dos
  /// patas: (1) `paraGuardar` mutilaba números legítimos con "15" — ya
  /// arreglado en el formatter; (2) cuando la entrada normaliza a "" pero
  /// el admin SÍ tipeó algo, igual se guardaba "" y el toast decía
  /// "guardado" → confusión. Acá cortamos esa segunda pata: si tipeó algo
  /// y no es un teléfono válido, avisamos y no tocamos el dato. Vaciar a
  /// propósito (campo en blanco) sigue funcionando → guarda "".
  static Future<void> telefono(
    BuildContext context,
    String dni,
    String raw,
  ) async {
    final normalizado = PhoneFormatter.paraGuardar(raw);
    if (raw.trim().isNotEmpty && normalizado.isEmpty) {
      AppFeedback.errorOn(
        ScaffoldMessenger.of(context),
        'Número de teléfono inválido. Revisá los dígitos (no se guardó).',
      );
      return;
    }
    await dato(context, dni, 'TELEFONO', normalizado);
  }

  /// Endpoint del callable `actualizarRolEmpleado`. Mismo patrón que
  /// AuditLog y volvoProxy — llamamos por HTTPS directo con Dio porque
  /// el plugin oficial `cloud_functions` no tiene impl Windows.
  static const String _endpointActualizarRol =
      'https://southamerica-east1-coopertrans-movil.cloudfunctions.net/actualizarRolEmpleado';

  /// Endpoint del callable `renombrarEmpleadoDni`.
  static const String _endpointRenombrarDni =
      'https://southamerica-east1-coopertrans-movil.cloudfunctions.net/renombrarEmpleadoDni';

  static Dio? _dioCallable;
  static Dio get _httpCallable => _dioCallable ??= Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          sendTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 12),
        ),
      );

  /// Actualiza ROL y/o ÁREA de un empleado vía Cloud Function. La
  /// function valida server-side que el caller sea ADMIN, actualiza
  /// Firestore Y refresca el custom claim del usuario afectado para
  /// que su próximo getIdToken(true) traiga el rol nuevo.
  ///
  /// Pasar `null` en alguno de los dos campos significa "no tocar".
  /// Pero al menos uno debe venir poblado.
  static Future<void> actualizarRol(
    BuildContext context,
    String dni, {
    String? nuevoRol,
    String? nuevaArea,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    if (nuevoRol == null && nuevaArea == null) return;
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        AppFeedback.errorOn(messenger, 'Sin sesión activa.');
        return;
      }
      final idToken = await user.getIdToken();
      if (idToken == null || idToken.isEmpty) {
        AppFeedback.errorOn(messenger, 'No se pudo obtener el token de sesión.');
        return;
      }

      final response = await _httpCallable.post<Map<String, dynamic>>(
        _endpointActualizarRol,
        data: {
          // Protocolo callable: payload va envuelto en `data`.
          'data': {
            'dni': dni.trim(),
            if (nuevoRol != null) 'rol': nuevoRol,
            if (nuevaArea != null) 'area': nuevaArea,
          },
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          validateStatus: (_) => true,
          responseType: ResponseType.json,
        ),
      );

      if (response.statusCode == null || response.statusCode! >= 400) {
        final err = response.data?['error'] as Map<String, dynamic>?;
        final mensaje = err?['message']?.toString() ??
            'Error ${response.statusCode} al actualizar rol.';
        // 403 → permission denied; lo decimos en lenguaje del usuario.
        final txtUI = response.statusCode == 403
            ? 'Solo ADMIN puede cambiar roles.'
            : mensaje;
        AppFeedback.errorOn(messenger, txtUI);
        return;
      }

      final result = response.data?['result'] as Map<String, dynamic>?;
      unawaited(AuditLog.registrar(
        accion: AuditAccion.editarChofer,
        entidad: 'EMPLEADOS',
        entidadId: dni.trim(),
        detalles: {
          'campo': nuevoRol != null ? 'ROL/AREA' : 'AREA',
          'rol_nuevo': result?['rol']?.toString() ?? '',
          'area_nueva': result?['area']?.toString() ?? '',
        },
      ));
      final mensaje = nuevoRol != null
          ? 'Rol actualizado a ${nuevoRol.toLowerCase()}'
          : 'Área actualizada';
      AppFeedback.successOn(messenger, mensaje);
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo actualizar el rol. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  /// Renombra el DNI de un empleado mal cargado.
  ///
  /// El DNI es el doc id de EMPLEADOS, así que no se puede editar inline
  /// como un campo cualquiera — hay que crear un doc nuevo, cascadear
  /// las referencias en otras colecciones (ASIGNACIONES_VEHICULO,
  /// VOLVO_ALERTAS, COLA_WHATSAPP) y borrar el viejo. Todo eso lo hace
  /// la Cloud Function `renombrarEmpleadoDni`. Acá pedimos el DNI nuevo
  /// (si no vino ya tipeado), pedimos confirmación y disparamos.
  ///
  /// [dniNuevoSugerido]: si la UI ya capturó el DNI nuevo (por ejemplo
  /// al editar el campo "DNI" inline en la ficha), saltamos el primer
  /// dialog y vamos directo a la confirmación. Si es null, abrimos un
  /// input dialog para pedirlo.
  ///
  /// La operación es destructiva y solo ADMIN puede ejecutarla. La rule
  /// se valida también server-side en la function.
  static Future<void> renombrarDni(
    BuildContext context,
    String dniViejo, {
    String? dniNuevoSugerido,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // ─── Resolver el DNI nuevo: viene del caller o lo pedimos. ─────
    String? dniNuevo;
    if (dniNuevoSugerido != null) {
      final candidato = dniNuevoSugerido.trim().replaceAll(RegExp(r'\D'), '');
      if (candidato.length < 7 || candidato.length > 8) {
        AppFeedback.errorOn(messenger,
            'El DNI nuevo debe tener 7 u 8 dígitos.');
        return;
      }
      if (candidato == dniViejo) {
        // No-op limpio: el admin "confirmó" sin cambiar nada.
        return;
      }
      dniNuevo = candidato;
    } else {
      final ctrl = TextEditingController();
      final formKey = GlobalKey<FormState>();
      try {
        dniNuevo = await showDialog<String>(
          context: context,
          builder: (dCtx) => AlertDialog(
            title: const Text('Cambiar DNI'),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DNI actual: $dniViejo',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: ctrl,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [DigitOnlyFormatter(maxLength: 8)],
                    decoration: const InputDecoration(
                      labelText: 'DNI nuevo',
                      prefixIcon: Icon(Icons.badge),
                    ),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.length < 7 || t.length > 8) {
                        return 'Tiene que tener 7 u 8 dígitos';
                      }
                      if (t == dniViejo) return 'Es igual al DNI actual';
                      return null;
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dCtx).pop(),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (formKey.currentState?.validate() ?? false) {
                    Navigator.of(dCtx).pop(ctrl.text.trim());
                  }
                },
                child: const Text('Continuar'),
              ),
            ],
          ),
        );
      } finally {
        ctrl.dispose();
      }
    }

    if (dniNuevo == null || dniNuevo.isEmpty) {
      AppFeedback.errorOn(messenger, 'No se ingresó un DNI nuevo.');
      return;
    }
    // Si el contexto se desmontó (raro pero puede pasar si el sheet
    // del chofer se cerró por algún motivo), avisamos por snackbar
    // para que el admin no quede sin saber qué pasó.
    if (!context.mounted) {
      AppFeedback.errorOn(messenger,
          'La ficha del chofer se cerró antes de poder confirmar.');
      return;
    }

    // ─── Dialog de confirmación: "se actualiza en la base de datos" ─
    final confirmar = await showDialog<bool>(
      // Usamos el navigator capturado al inicio: aunque `context` pueda
      // estar en algún estado raro post-pop del dialog de edición, el
      // navigator capturado es estable. El linter no puede saberlo —
      // de ahí la supresión.
      // ignore: use_build_context_synchronously
      context: navigator.context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Confirmar cambio de DNI'),
        content: Text(
          '¿Cambiar el DNI de este empleado de $dniViejo a $dniNuevo?\n\n'
          'Se va a actualizar en la base de datos: el legajo se recrea '
          'con el DNI nuevo y se sincronizan las asignaciones, alertas '
          'Volvo y mensajes pendientes. La operación NO se puede '
          'deshacer y el chofer va a tener que volver a loguear con el '
          'DNI nuevo.',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dCtx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentRed,
              foregroundColor: Colors.white,
            ),
            child: const Text('SÍ, ACTUALIZAR'),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    // ─── Llamada a la Cloud Function ───────────────────────────────
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        AppFeedback.errorOn(messenger, 'Sin sesión activa.');
        return;
      }
      final idToken = await user.getIdToken();
      if (idToken == null || idToken.isEmpty) {
        AppFeedback.errorOn(messenger, 'No se pudo obtener el token de sesión.');
        return;
      }

      final response = await _httpCallable.post<Map<String, dynamic>>(
        _endpointRenombrarDni,
        data: {
          'data': {
            'dniViejo': dniViejo,
            'dniNuevo': dniNuevo,
          },
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          validateStatus: (_) => true,
          responseType: ResponseType.json,
        ),
      );

      if (response.statusCode == null || response.statusCode! >= 400) {
        final err = response.data?['error'] as Map<String, dynamic>?;
        final mensaje = err?['message']?.toString() ??
            'Error ${response.statusCode} al renombrar.';
        AppFeedback.errorOn(messenger, mensaje);
        return;
      }

      final result = response.data?['result'] as Map<String, dynamic>?;
      final cascada = (result?['cascada'] as List?) ?? const [];
      final resumen = cascada
          .map((c) {
            final m = c as Map<String, dynamic>;
            final col = m['coleccion'] ?? '';
            final n = m['actualizados'] ?? 0;
            final err = m['error'];
            return err == null ? '$col: $n' : '$col: ERROR';
          })
          .join(', ');

      unawaited(AuditLog.registrar(
        accion: AuditAccion.editarChofer,
        entidad: 'EMPLEADOS',
        entidadId: dniNuevo,
        detalles: {
          'campo': 'DNI',
          'dni_viejo': dniViejo,
          'dni_nuevo': dniNuevo,
          'cascada': resumen,
        },
      ));

      AppFeedback.successOn(
        messenger,
        'Renombrado OK ($dniViejo → $dniNuevo). $resumen',
      );

      // Cierra el sheet de detalle del chofer viejo (el doc ya no existe).
      // El admin abre el del DNI nuevo desde la lista cuando quiera.
      navigator.pop();
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo renombrar el DNI. La operación se cancela.',
        tecnico: e,
        stack: s,
      );
    }
  }

  /// Abre un sheet con opciones para gestionar la foto de perfil.
  static Future<void> fotoPerfil(
    BuildContext context,
    String dni,
    String? urlActual,
  ) async {
    final picker = ImagePicker();
    final navigator = Navigator.of(context);

    // El Future de showModalBottomSheet se completa cuando el sheet
    // se cierra. Acá solo lo abrimos y nos vamos — la lógica de subir
    // la foto vive dentro de los onTap de los ListTile, no dependemos
    // del valor de retorno.
    unawaited(showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (bCtx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(25)),
          border: const Border(
              top: BorderSide(color: AppColors.success, width: 2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Foto de perfil',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 15),
            ListTile(
              leading: const Icon(Icons.visibility, color: AppColors.accentBlue),
              title: const Text('Ver foto actual',
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
                      titulo: 'Foto de $dni',
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library,
                  color: AppColors.success),
              title: const Text('Subir nueva desde galería',
                  style: TextStyle(color: Colors.white)),
              onTap: () async {
                navigator.pop();
                final image = await picker.pickImage(
                  source: ImageSource.gallery,
                  imageQuality: 50,
                );
                if (image != null && context.mounted) {
                  // readAsBytes() es cross-platform; image.path en Web es un
                  // blob URL que no se puede abrir como dart:io.File.
                  final bytes = await image.readAsBytes();
                  if (!context.mounted) return;
                  await _subirArchivo(
                    context,
                    dni,
                    bytes,
                    image.name,
                    'perfiles/$dni.jpg',
                    'ARCHIVO_PERFIL',
                  );
                }
              },
            ),
          ],
        ),
      ),
    ));
  }

  /// Sube los bytes de un archivo a Storage y guarda la URL en Firestore.
  /// Detecta el contentType según la extensión vía `StorageService` —
  /// que es cross-platform (no usa `dart:io.File`).
  static Future<void> _subirArchivo(
    BuildContext context,
    String id,
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
        await dato(context, id, dbCampo, downloadUrl);
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

  /// Abre un sheet para que el admin elija de dónde tomar el archivo
  /// (cámara, galería, o PDF/imagen del dispositivo) y lo sube.
  /// Pensado para reemplazar papeles del chofer (licencia, ART, etc.).
  static Future<void> _reemplazarDocumentoChofer({
    required BuildContext context,
    required String dni,
    required String etiqueta,
    required String campoUrl,
  }) async {
    final picker = ImagePicker();

    final fuente = await showModalBottomSheet<_FuenteArchivoChofer>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sCtx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(sCtx).colorScheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(25)),
          border: const Border(
              top: BorderSide(color: AppColors.success, width: 2)),
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
                    color: AppColors.success,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              ListTile(
                leading:
                    const Icon(Icons.camera_alt, color: AppColors.success),
                title: const Text('Tomar foto con la cámara',
                    style: TextStyle(color: Colors.white)),
                onTap: () =>
                    Navigator.pop(sCtx, _FuenteArchivoChofer.camara),
              ),
              ListTile(
                leading:
                    const Icon(Icons.photo_library, color: AppColors.accentBlue),
                title: const Text('Foto desde la galería',
                    style: TextStyle(color: Colors.white)),
                onTap: () =>
                    Navigator.pop(sCtx, _FuenteArchivoChofer.galeria),
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf,
                    color: AppColors.accentRed),
                title: const Text('PDF / archivo del dispositivo',
                    style: TextStyle(color: Colors.white)),
                onTap: () =>
                    Navigator.pop(sCtx, _FuenteArchivoChofer.archivo),
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
      case _FuenteArchivoChofer.camara:
      case _FuenteArchivoChofer.galeria:
        final source = fuente == _FuenteArchivoChofer.camara
            ? ImageSource.camera
            : ImageSource.gallery;
        final img = await picker.pickImage(source: source, imageQuality: 60);
        if (img == null) return;
        // readAsBytes(): cross-platform (Web devuelve blob bytes, no File).
        bytes = await img.readAsBytes();
        nombreOriginal = img.name;
        extension = 'jpg';
        break;
      case _FuenteArchivoChofer.archivo:
        // withData: true para que `bytes` venga poblado en Web también.
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

    // Después del picker viene otro await: revalidamos contra el mismo
    // BuildContext que vamos a pasar a _subirArchivo (el lint pide eso).
    if (!context.mounted) return;
    if (bytes == null) return;
    final storagePath =
        'EMPLEADOS/$dni/${campoUrl}_${DateTime.now().millisecondsSinceEpoch}.$extension';
    await _subirArchivo(
        context, dni, bytes, nombreOriginal, storagePath, campoUrl);
  }

  /// Sheet con opciones para gestionar un documento (fecha + archivo).
  static void documento(
    BuildContext context, {
    required String dni,
    required String etiqueta,
    required String campoFecha,
    required String campoUrl,
    required String? fechaActual,
    required String? urlActual,
  }) {
    final navigator = Navigator.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (bCtx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(25)),
          border: const Border(
              top: BorderSide(color: AppColors.success, width: 2)),
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
                _seleccionarFecha(context, dni, campoFecha, fechaActual);
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility, color: AppColors.success),
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
                      titulo: '$etiqueta - $dni',
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
                'Foto o PDF — sin pasar por el flujo de revisión',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              onTap: () {
                navigator.pop();
                _reemplazarDocumentoChofer(
                  context: context,
                  dni: dni,
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

  static Future<void> _seleccionarFecha(
    BuildContext context,
    String dni,
    String campo,
    String? fechaActual,
  ) async {
    final initial = AppFormatters.tryParseFecha(fechaActual ?? '');
    final picked = await pickFecha(
      context,
      initial: initial,
      titulo: 'Vencimiento ${campo.replaceAll("VENCIMIENTO_", "").replaceAll("_", " ")}',
    );
    if (picked != null && context.mounted) {
      final nuevaFecha = AppFormatters.aIsoFechaLocal(picked);
      await dato(context, dni, campo, nuevaFecha);
    }
  }

  /// Selector de unidad (tractor o enganche).
  static void unidad(
    BuildContext context,
    String dni,
    String campo,
    String patenteActual,
  ) {
    final tipos = (campo == 'VEHICULO')
        ? <String>[AppTiposVehiculo.tractor]
        : AppTiposVehiculo.enganches;
    // Capturamos el messenger del scaffold padre antes de abrir el dialog;
    // lo usamos después del batch.commit para mostrar feedback al admin
    // (ScaffoldMessenger.of(dCtx) no aplica una vez cerrado el dialog).
    final messenger = ScaffoldMessenger.of(context);
    final esTractor = campo == 'VEHICULO';
    final etiquetaUnidad = esTractor ? 'tractor' : 'enganche';

    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text("Asignar $etiquetaUnidad"),
        content: SizedBox(
          width: double.maxFinite,
          height: 350,
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection(AppCollections.vehiculos)
                .where('TIPO', whereIn: tipos)
                .snapshots(),
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const Center(
                  child: CircularProgressIndicator(
                      color: AppColors.success),
                );
              }

              final unidades = snap.data!.docs;

              Future<void> procesarCambio(String? nueva) async {
                final db = FirebaseFirestore.instance;
                final cleanActual = patenteActual.trim();
                final hayActualValido = cleanActual.isNotEmpty &&
                    cleanActual != '-' &&
                    cleanActual != 'S/D';
                final desvincular = (nueva == null || nueva == '-');

                // Guard contra no-ops antes de tocar Firestore.
                final misma = !desvincular && nueva == cleanActual;
                final yaSinUnidad = desvincular && !hayActualValido;
                if (misma || yaSinUnidad) {
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  return;
                }

                try {
                  if (esTractor) {
                    // Tractor: pasa por el servicio centralizado, que
                    // mantiene el log temporal en ASIGNACIONES_VEHICULO,
                    // los espejos en EMPLEADOS/VEHICULOS y dispara el
                    // audit. Resuelve también un mini-bug donde dos
                    // choferes podían apuntar a la misma patente.
                    final adminUid =
                        FirebaseAuth.instance.currentUser?.uid ?? '';
                    await AsignacionVehiculoService().cambiarAsignacion(
                      choferDni: dni,
                      nuevaPatente: nueva,
                      asignadoPorDni: adminUid,
                    );
                  } else {
                    // Enganche (batea/tolva/bivuelco/tanque): batch
                    // directo para los espejos en EMPLEADOS y VEHICULOS,
                    // + AsignacionEngancheService para registrar el log
                    // temporal en ASIGNACIONES_ENGANCHE (Fase 0 del
                    // módulo Gomería 2026-05-04 — sin esto no se puede
                    // calcular km recorridos por cubiertas de enganche).
                    final batch = db.batch();
                    if (!desvincular) {
                      batch.update(
                        db.collection(AppCollections.vehiculos).doc(nueva),
                        {'ESTADO': 'OCUPADO'},
                      );
                      batch.update(
                        db.collection(AppCollections.empleados).doc(dni),
                        {campo: nueva},
                      );
                    } else {
                      batch.update(
                        db.collection(AppCollections.empleados).doc(dni),
                        {campo: '-'},
                      );
                    }
                    if (hayActualValido) {
                      batch.update(
                        db.collection(AppCollections.vehiculos).doc(cleanActual),
                        {'ESTADO': 'LIBRE'},
                      );
                    }
                    await batch.commit();

                    // Registro en ASIGNACIONES_ENGANCHE: necesita el
                    // tractor actual del chofer para asociar enganche↔
                    // tractor. Si el chofer no tiene tractor asignado,
                    // skipeamos — no tiene sentido enganche sin tractor.
                    final empSnap = await db
                        .collection(AppCollections.empleados)
                        .doc(dni)
                        .get();
                    final tractorActual = (empSnap.data()?['VEHICULO'] ?? '')
                        .toString()
                        .trim()
                        .toUpperCase();
                    final tieneTractor =
                        tractorActual.isNotEmpty && tractorActual != '-';
                    if (tieneTractor) {
                      final adminUid =
                          FirebaseAuth.instance.currentUser?.uid ?? '';
                      final svc = AsignacionEngancheService();
                      try {
                        // Cerrar asignación del enganche anterior (si
                        // existía) — ese enganche queda desenganchado.
                        if (hayActualValido && cleanActual.isNotEmpty) {
                          await svc.cambiarAsignacion(
                            engancheId: cleanActual,
                            nuevoTractorId: null,
                            asignadoPorDni: adminUid,
                          );
                        }
                        // Abrir asignación del enganche nuevo en el
                        // tractor del chofer (si no es desvincular).
                        if (!desvincular) {
                          await svc.cambiarAsignacion(
                            engancheId: nueva,
                            nuevoTractorId: tractorActual,
                            asignadoPorDni: adminUid,
                          );
                        }
                      } catch (e) {
                        debugPrint(
                          'Aviso: registro en ASIGNACIONES_ENGANCHE falló '
                          '(no bloquea el cambio): $e',
                        );
                      }
                    }

                    unawaited(AuditLog.registrar(
                      accion: desvincular
                          ? AuditAccion.desvincularEquipo
                          : AuditAccion.asignarEquipo,
                      entidad: 'EMPLEADOS',
                      entidadId: dni,
                      detalles: {
                        'campo': campo,
                        'unidad_anterior': cleanActual,
                        'unidad_nueva': nueva ?? '',
                      },
                    ));
                  }

                  if (ctx.mounted) Navigator.of(ctx).pop();

                  // Feedback de éxito: distinto copy según haya sido
                  // desvinculación o asignación nueva.
                  final mensaje = desvincular
                      ? 'Se desvinculó el $etiquetaUnidad de este chofer.'
                      : 'Se asignó el $etiquetaUnidad $nueva.';
                  AppFeedback.successOn(messenger, mensaje);
                } catch (e, s) {
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  AppFeedback.errorTecnicoOn(
                    messenger,
                    usuario:
                        'No se pudo guardar la asignación. Probá de nuevo.',
                    tecnico: e,
                    stack: s,
                  );
                }
              }

              return ListView.builder(
                itemCount: unidades.length + 1,
                itemBuilder: (ctx, idx) {
                  if (idx == 0) {
                    return ListTile(
                      leading:
                          const Icon(Icons.link_off, color: AppColors.accentRed),
                      title: const Text(
                        'DESVINCULAR',
                        style: TextStyle(
                          color: AppColors.accentRed,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      // Confirmación destructiva: desvincular cambia el
                      // legajo del chofer Y libera la unidad. Si toca por
                      // error y no avisamos, el equipo queda mal asignado
                      // y nadie se entera hasta que el chofer reclame.
                      onTap: () async {
                        final ok = await AppConfirmDialog.show(
                          context,
                          title: '¿Desvincular $etiquetaUnidad?',
                          message:
                              'El chofer va a quedar sin $etiquetaUnidad asignado y la unidad vuelve a estado LIBRE.',
                          confirmLabel: 'DESVINCULAR',
                          destructive: true,
                          icon: Icons.link_off,
                        );
                        if (ok == true) {
                          await procesarCambio(null);
                        }
                      },
                    );
                  }

                  final vDoc = unidades[idx - 1];
                  final vData = vDoc.data() as Map<String, dynamic>;
                  final patente = vDoc.id.trim();

                  // Filtrar unidades ocupadas (excepto la actual del chofer)
                  if (vData['ESTADO'] == 'OCUPADO' &&
                      patente != patenteActual.trim()) {
                    return const SizedBox.shrink();
                  }

                  return ListTile(
                    title: Text(
                      patente,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14),
                    ),
                    trailing: patente == patenteActual.trim()
                        ? const Icon(Icons.check_circle,
                            color: AppColors.success)
                        : null,
                    onTap: () => procesarCambio(patente),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // SOFT-DELETE: dar de baja / reactivar
  // ===========================================================================

  /// Da de baja al empleado SIN borrar el doc:
  ///   1. Cierra asignación activa de vehículo (vía AsignacionVehiculoService).
  ///   2. Cierra asignación activa de enganche.
  ///   3. Borra los archivos de Storage (ARCHIVO_*) y la foto de perfil
  ///      (best-effort — si alguno falla, log y sigue).
  ///   4. Vacía los campos VENCIMIENTO_* y ARCHIVO_* en el doc.
  ///   5. Setea ACTIVO=false + metadata (BAJA_EN, BAJA_POR_DNI, BAJA_MOTIVO).
  ///
  /// Al reactivar más tarde con [reactivar], el empleado queda con los
  /// vencimientos vacíos — el admin tiene que cargar todo de nuevo.
  /// La unidad NO se restaura (asumimos que pudo haber pasado a otro chofer).
  static Future<void> darDeBaja(
    BuildContext context, {
    required String dni,
    required String? motivo,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final dniLimpio = dni.trim();
    if (dniLimpio.isEmpty) {
      AppFeedback.errorOn(messenger, 'DNI vacío.');
      return;
    }

    final adminDni = PrefsService.dni;
    final empRef = FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .doc(dniLimpio);

    try {
      final snap = await empRef.get();
      if (!snap.exists) {
        AppFeedback.errorOn(messenger, 'Empleado $dniLimpio no existe.');
        return;
      }
      final data = snap.data() ?? const <String, dynamic>{};

      // 1) Cerrar asignación de vehículo (si tenía).
      try {
        await AsignacionVehiculoService().cambiarAsignacion(
          choferDni: dniLimpio,
          nuevaPatente: null,
          asignadoPorDni: adminDni,
          motivo: 'Baja del empleado',
        );
      } catch (e) {
        // Reportamos al logger con DNI hasheado (PII safe) en vez de
        // print() crudo que dejaba el DNI plano en logcat / Crashlytics.
        AppLogger.recordError(e, StackTrace.current,
            reason: 'darDeBaja: cerrar asig vehiculo fallo');
      }

      // 2) Cerrar asignación de enganche (si tenía un enganche directo).
      final engancheActual =
          (data['ENGANCHE'] ?? '').toString().trim();
      if (engancheActual.isNotEmpty && engancheActual != '-') {
        try {
          await AsignacionEngancheService().cambiarAsignacion(
            engancheId: engancheActual,
            nuevoTractorId: null,
            asignadoPorDni: adminDni,
            motivo: 'Baja del empleado dueño del enganche',
          );
        } catch (e) {
          AppLogger.recordError(e, StackTrace.current,
              reason: 'darDeBaja: cerrar asig enganche fallo');
        }
      }

      // 3) Borrar archivos de Storage (best-effort).
      final urlsParaBorrar = <String>[
        for (final sufijo in AppDocsEmpleado.etiquetas.values)
          (data['ARCHIVO_$sufijo'] ?? '').toString(),
        (data['ARCHIVO_FOTO_PERFIL'] ?? '').toString(),
      ];
      for (final url in urlsParaBorrar) {
        if (url.isEmpty || url == '-') continue;
        try {
          await FirebaseStorage.instance.refFromURL(url).delete();
        } catch (e) {
          // No incluimos la URL en el log porque contiene un token de
          // acceso temporal — solo la razon generica.
          AppLogger.recordError(e, StackTrace.current,
              reason: 'darDeBaja: borrar archivo Storage fallo');
        }
      }

      // 4 + 5) Vaciar VENCIMIENTO_*/ARCHIVO_* y marcar ACTIVO=false.
      final updates = <String, dynamic>{
        AppActivo.campo: false,
        AppActivo.campoBajaEn: FieldValue.serverTimestamp(),
        AppActivo.campoBajaPorDni: adminDni,
        if (motivo != null && motivo.trim().isNotEmpty)
          AppActivo.campoBajaMotivo: motivo.trim(),
        // Limpiar reactivación previa (si alguien fue reactivado y vuelve a baja).
        AppActivo.campoReactivadoEn: null,
        AppActivo.campoReactivadoPorDni: null,
        // Limpiar foto de perfil.
        'ARCHIVO_FOTO_PERFIL': null,
        // Garantizamos que el espejo de unidad quede limpio.
        'VEHICULO': '-',
        'ENGANCHE': '-',
        'fecha_ultima_actualizacion': FieldValue.serverTimestamp(),
      };
      for (final sufijo in AppDocsEmpleado.etiquetas.values) {
        updates['VENCIMIENTO_$sufijo'] = null;
        updates['ARCHIVO_$sufijo'] = null;
      }
      await empRef.update(updates);

      unawaited(AuditLog.registrar(
        accion: AuditAccion.darDeBajaEmpleado,
        entidad: 'EMPLEADOS',
        entidadId: dniLimpio,
        detalles: {
          if (motivo != null && motivo.trim().isNotEmpty)
            'motivo': motivo.trim(),
          'archivos_borrados': urlsParaBorrar
              .where((u) => u.isNotEmpty && u != '-')
              .length,
        },
      ));

      AppFeedback.successOn(messenger, 'Empleado dado de baja.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo dar de baja al empleado. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  /// Reactiva un empleado dado de baja. Setea ACTIVO=true + metadata.
  /// Los vencimientos quedan vacíos — el admin debe cargarlos de nuevo.
  /// La unidad NO se restaura.
  static Future<void> reactivar(
    BuildContext context, {
    required String dni,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final dniLimpio = dni.trim();
    if (dniLimpio.isEmpty) {
      AppFeedback.errorOn(messenger, 'DNI vacío.');
      return;
    }
    final adminDni = PrefsService.dni;
    try {
      await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(dniLimpio)
          .update({
        AppActivo.campo: true,
        AppActivo.campoReactivadoEn: FieldValue.serverTimestamp(),
        AppActivo.campoReactivadoPorDni: adminDni,
        'fecha_ultima_actualizacion': FieldValue.serverTimestamp(),
      });
      unawaited(AuditLog.registrar(
        accion: AuditAccion.reactivarEmpleado,
        entidad: 'EMPLEADOS',
        entidadId: dniLimpio,
        detalles: const {},
      ));
      AppFeedback.successOn(
          messenger, 'Empleado reactivado. Cargá los vencimientos.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo reactivar al empleado. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  /// Confirm dialog antes de dar de baja. Pide motivo opcional.
  /// Si confirma, llama a [darDeBaja]. Pensado para el bottom sheet de
  /// detalle del empleado.
  static Future<void> confirmarYDarDeBaja(
    BuildContext context, {
    required String dni,
    required String nombreVisible,
  }) async {
    final motivoCtrl = TextEditingController();
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        title: const Text('Dar de baja al empleado',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$nombreVisible quedará INACTIVO.\n\n'
              'Se cerrarán sus asignaciones de vehículo y enganche, y '
              'se borrarán todos sus vencimientos y archivos cargados.\n\n'
              'Al reactivarlo más adelante, los vencimientos quedan vacíos '
              'y hay que volver a cargar todo.',
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
                hintText: 'Ej. renuncia, vacaciones largas, etc.',
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
    await darDeBaja(context, dni: dni, motivo: motivoTxt);
  }

  /// Confirm dialog para reactivar.
  static Future<void> confirmarYReactivar(
    BuildContext context, {
    required String dni,
    required String nombreVisible,
  }) async {
    final ok = await AppConfirmDialog.show(
      context,
      title: 'Reactivar empleado',
      message:
          '$nombreVisible va a volver a estar ACTIVO. Los vencimientos quedan '
          'vacíos hasta que los cargues. La unidad NO se restaura.',
      confirmLabel: 'REACTIVAR',
    );
    if (ok != true) return;
    if (!context.mounted) return;
    await reactivar(context, dni: dni);
  }

  /// Resetea la contraseña de un empleado (caso: el empleado se la olvido).
  /// Llama a la Cloud Function callable `resetearContrasenaEmpleadoAdmin`
  /// que valida server-side que el caller sea ADMIN/SUPERVISOR. La pass
  /// nueva queda hasheada con bcrypt. Revoca tokens del afectado para
  /// forzar re-login.
  ///
  /// Patron HTTPS directo (mismo que `cambiarContrasenaChofer` en
  /// user_mi_perfil) porque `cloud_functions` plugin no tiene impl
  /// Windows. Auth via getIdToken().
  static Future<void> resetearContrasenaCallable({
    required String dni,
    required String nueva,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Sin sesion activa.');
    }
    final idToken = await user.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw StateError('No se pudo obtener el token de sesion.');
    }
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ));
    const url =
        'https://southamerica-east1-coopertrans-movil.cloudfunctions.net/'
        'resetearContrasenaEmpleadoAdmin';
    final response = await dio.post<Map<String, dynamic>>(
      url,
      data: {
        'data': {'dni': dni, 'nueva': nueva},
      },
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $idToken',
        },
        validateStatus: (_) => true,
      ),
    );
    if (response.statusCode == null || response.statusCode! >= 400) {
      final err = response.data?['error'] as Map<String, dynamic>?;
      final msg = err?['message']?.toString() ??
          'Error ${response.statusCode} al resetear contrasena.';
      throw StateError(msg);
    }
  }

  /// Dialog UI que el admin abre desde el sheet de detalle del empleado.
  /// Pide la nueva contrasena (twice + confirm), llama al callable, y
  /// muestra feedback al admin para que se la pase al chofer.
  static Future<void> confirmarYResetearContrasena(
    BuildContext context, {
    required String dni,
    required String nombreVisible,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final nuevaCtrl = TextEditingController();
    final repetirCtrl = TextEditingController();
    String? errorTxt;

    final confirmada = await showDialog<String?>(
      context: context,
      builder: (dCtx) => StatefulBuilder(
        builder: (sCtx, setSt) => AlertDialog(
          backgroundColor: Theme.of(dCtx).colorScheme.surface,
          title: const Text(
            'Resetear contraseña',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Vas a setearle una contraseña nueva a $nombreVisible. '
                'El chofer va a tener que re-loguear y vos le tenes que '
                'pasar la pass nueva en persona o por WhatsApp privado.',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nuevaCtrl,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Nueva contraseña',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: repetirCtrl,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Repetir contraseña',
                ),
              ),
              if (errorTxt != null) ...[
                const SizedBox(height: 8),
                Text(
                  errorTxt!,
                  style: const TextStyle(color: AppColors.accentRed, fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dCtx),
              child: const Text('CANCELAR',
                  style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentAmber,
                foregroundColor: Colors.black,
              ),
              onPressed: () {
                final a = nuevaCtrl.text;
                final b = repetirCtrl.text;
                if (a.length < 6) {
                  setSt(() => errorTxt =
                      'La contraseña debe tener al menos 6 caracteres.');
                  return;
                }
                if (a != b) {
                  setSt(() => errorTxt = 'Las contraseñas no coinciden.');
                  return;
                }
                Navigator.pop(dCtx, a);
              },
              child: const Text('RESETEAR',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
    nuevaCtrl.dispose();
    repetirCtrl.dispose();
    if (confirmada == null || confirmada.isEmpty) return;
    try {
      await resetearContrasenaCallable(dni: dni, nueva: confirmada);
      AppFeedback.successOn(
        messenger,
        'Contraseña reseteada. Pasale la nueva al chofer en persona.',
      );
    } catch (e) {
      AppFeedback.errorOn(
        messenger,
        e is StateError ? e.message : 'Error: $e',
      );
    }
  }
}
