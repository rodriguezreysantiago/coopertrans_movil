import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/digit_only_formatter.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/phone_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/foto_perfil_avatar.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
/// Perfil del chofer (vista del usuario, no admin).
///
/// Migrada al sistema de diseño unificado.
class UserMiPerfilScreen extends StatefulWidget {
  final String dni;
  const UserMiPerfilScreen({super.key, required this.dni});

  @override
  State<UserMiPerfilScreen> createState() => _UserMiPerfilScreenState();
}

class _UserMiPerfilScreenState extends State<UserMiPerfilScreen> {
  final StorageService _storageService = StorageService();
  late final Stream<DocumentSnapshot> _perfilStream;

  /// Pasa a `true` si pasan más de 10s sin que llegue el primer
  /// snapshot del stream. Se usa para mostrar UI degradada con datos
  /// cacheados de Prefs + banner "Conexión lenta", en lugar del
  /// "Perfil no encontrado" que asusta al chofer cuando su red está
  /// lenta (caso reportado con chofer 16969961 desde Android lento).
  bool _conexionLenta = false;
  Timer? _slowConnTimer;

  @override
  void initState() {
    super.initState();
    _perfilStream = FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .doc(widget.dni)
        .snapshots();
    _slowConnTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _conexionLenta = true);
    });
  }

  @override
  void dispose() {
    _slowConnTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // OPERACIONES (con loading + manejo de errores estándar)
  // ---------------------------------------------------------------------------

  Future<void> _ejecutarTarea({
    required Future<void> Function() tarea,
    required String mensajeExito,
  }) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    AppLoadingDialog.show(context);

    try {
      await tarea();
      if (!mounted) return;
      AppLoadingDialog.hide(navigator);
      AppFeedback.successOn(messenger, mensajeExito);
    } catch (e, s) {
      if (!mounted) return;
      AppLoadingDialog.hide(navigator);
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo guardar el cambio. Probá de nuevo en unos segundos.',
        tecnico: e,
        stack: s,
      );
    }
  }

  /// Update genérico de un campo del legajo (lo usa _DatosCard para
  /// editar inline TELÉFONO y MAIL). Reusa el patrón estándar
  /// `_ejecutarTarea` que ya muestra loading + feedback de error.
  Future<void> _actualizarCampoEmpleado(String campo, String valor) {
    return _ejecutarTarea(
      tarea: () async => FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(widget.dni)
          .update({campo: valor}),
      mensajeExito: 'Datos actualizados.',
    );
  }

  /// Llama a la Cloud Function callable `cambiarContrasenaChofer` que
  /// valida server-side la contrasena actual + hashea la nueva con bcrypt
  /// + persiste. Patron HTTPS directo (mismo que actualizarRol) porque
  /// `cloud_functions` no tiene impl Windows.
  Future<void> _cambiarContrasenaCallable({
    required String actual,
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
    const url = 'https://southamerica-east1-coopertrans-movil.cloudfunctions.net/'
        'cambiarContrasenaChofer';
    final response = await dio.post<Map<String, dynamic>>(
      url,
      data: {
        'data': {'actual': actual, 'nueva': nueva},
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
          'Error ${response.statusCode} al cambiar contrasena.';
      throw StateError(msg);
    }
  }

  void _mostrarDialogoClave() {
    final antCtrl = TextEditingController();
    final nvaCtrl = TextEditingController();
    // Cacheamos el messenger del scaffold acá (NO adentro del onPressed)
    // para evitar el riesgo del context "del padre del dialog" después
    // de cerrar el dialog.
    final messenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withAlpha(20)),
        ),
        title: const Text(
          'Cambiar contraseña',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: antCtrl,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Contraseña actual',
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: nvaCtrl,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Nueva contraseña',
              ),
            ),
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
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              // SEGURIDAD (auditoria 2026-05-17): la validacion de la
              // contraseña actual + el hashing + el update ahora viven
              // en la Cloud Function `cambiarContrasenaChofer`. Antes
              // todo se hacia client-side y un atacante con DevTools
              // podia saltarse el chequeo y escribir el hash directo.
              // La rule de EMPLEADOS YA NO permite update de CONTRASEÑA
              // desde cliente — solo Admin SDK (la callable).
              if (nvaCtrl.text.trim().length < 6) {
                AppFeedback.warningOn(messenger,
                    'La nueva contrasena debe tener al menos 6 caracteres');
                return;
              }
              Navigator.pop(dCtx);
              unawaited(_ejecutarTarea(
                tarea: () => _cambiarContrasenaCallable(
                  actual: antCtrl.text,
                  nueva: nvaCtrl.text,
                ),
                mensajeExito: 'Contrasena actualizada correctamente',
              ));
            },
            child: const Text('GUARDAR',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ).whenComplete(() {
      antCtrl.dispose();
      nvaCtrl.dispose();
    });
  }

  void _mostrarOpcionesFoto() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(25)),
          border: const Border(
              top: BorderSide(color: AppColors.success, width: 2)),
        ),
        child: SafeArea(
          child: Wrap(children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Actualizar foto',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            ListTile(
              leading:
                  const Icon(Icons.camera_alt, color: AppColors.success),
              title: const Text('Tomar foto con la cámara',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _seleccionarImagen(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library,
                  color: AppColors.success),
              title: const Text('Elegir de la galería',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _seleccionarImagen(ImageSource.gallery);
              },
            ),
            const SizedBox(height: 20),
          ]),
        ),
      ),
    );
  }

  Future<void> _seleccionarImagen(ImageSource source) async {
    final picker = ImagePicker();
    final image =
        await picker.pickImage(source: source, imageQuality: 50);
    if (image == null) return;
    if (!mounted) return;

    // _ejecutarTarea devuelve Future<void>: lo descartamos explícito
    // porque _seleccionarImagen ya cumplió su cometido (mostrar el
    // loading, hacer el upload y cerrar) — no necesitamos esperarlo.
    unawaited(_ejecutarTarea(
      tarea: () async {
        // Leemos los bytes del XFile (cross-platform: en Web el path es un
        // blob URL que no se puede abrir como dart:io.File).
        final bytes = await image.readAsBytes();
        final url = await _storageService.subirArchivo(
          bytes: bytes,
          nombreOriginal: image.name,
          rutaStorage: 'PERFILES/${widget.dni}.jpg',
        );
        await FirebaseFirestore.instance
            .collection(AppCollections.empleados)
            .doc(widget.dni)
            .update({'ARCHIVO_PERFIL': url});
      },
      mensajeExito: 'Foto de perfil actualizada',
    ));
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Mi Perfil',
      body: StreamBuilder<DocumentSnapshot>(
        stream: _perfilStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return AppErrorState(
              title: 'No se pudo cargar tu perfil',
              subtitle: snapshot.error.toString(),
            );
          }
          // Sin data todavía: si pasaron <10s, spinner. Si pasaron >10s
          // sin que Firestore responda, mostramos UI degradada con los
          // datos básicos cacheados de Prefs (nombre, apodo, rol) y un
          // banner avisando que la conexión es lenta. Ayuda muchísimo
          // a choferes con celus viejos o red mala — antes veían
          // "Perfil no encontrado" después del timeout y pensaban que
          // estaban mal dados de alta.
          if (snapshot.connectionState == ConnectionState.waiting ||
              !snapshot.hasData) {
            if (_conexionLenta) {
              return _PerfilOfflineFallback(dni: widget.dni);
            }
            return const AppLoadingState();
          }
          if (!snapshot.data!.exists) {
            // Si el doc realmente no existe (Firestore respondió,
            // doc=null), mostramos también el fallback con datos de
            // Prefs en lugar del "Perfil no encontrado" alarmante.
            // Este caso es excepcional: solo pasa si admin borró el
            // legajo entre login y abrir Mi Perfil.
            return _PerfilOfflineFallback(
              dni: widget.dni,
              motivo: 'Tu legajo no está disponible en este momento. '
                  'Contactá a administración.',
            );
          }

          // En lugar de un cast directo (que puede crashear si el
          // documento tiene un shape inesperado), validamos el tipo y
          // devolvemos un error amigable si algo viene mal.
          final raw = snapshot.data!.data();
          if (raw is! Map<String, dynamic>) {
            return const AppErrorState(
              title: 'Datos corruptos',
              subtitle:
                  'El formato de tu perfil no es válido. Contactá a administración.',
            );
          }
          final data = raw;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _Header(data: data, onEditarFoto: _mostrarOpcionesFoto),
              const SizedBox(height: 30),
              _EquipoCard(data: data),
              const SizedBox(height: 30),
              const _SectionTitle(label: 'Datos personales'),
              const SizedBox(height: AppSpacing.sm),
              _DatosCard(
                dni: widget.dni,
                data: data,
                onActualizarCampo: _actualizarCampoEmpleado,
              ),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                onPressed: () => _mostrarDialogoClave(),
                icon: const Icon(Icons.password_rounded),
                label: const Text(
                  'CAMBIAR MI CONTRASEÑA',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white.withAlpha(20),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                    side: const BorderSide(color: Colors.white24),
                  ),
                  elevation: 0,
                ),
              ),
              const SizedBox(height: 20),
            ],
          );
        },
      ),
    );
  }
}

// =============================================================================
// COMPONENTES INTERNOS
// =============================================================================

class _Header extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onEditarFoto;

  const _Header({required this.data, required this.onEditarFoto});

  @override
  Widget build(BuildContext context) {
    final fotoUrl = data['ARCHIVO_PERFIL'] as String?;

    return Column(
      children: [
        Stack(
          children: [
            FotoPerfilAvatar(
              url: fotoUrl,
              radius: 65,
              fondo: Colors.white10,
              iconColor: Colors.white24,
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(50),
                  onTap: onEditarFoto,
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: AppColors.success,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.surface,
                        width: 3,
                      ),
                    ),
                    child: const Icon(Icons.camera_alt,
                        size: 20, color: Colors.black),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          (data['NOMBRE'] ?? 'Usuario').toString(),
          // Nombres largos ("GONZALEZ RODRIGUEZ JUAN CARLOS") rompían
          // el header en mobile. 2 líneas + center + ellipsis.
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          'CHOFER PROFESIONAL',
          style: TextStyle(
            color: AppColors.success,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }
}

class _EquipoCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _EquipoCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(20),
      margin: EdgeInsets.zero,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _DatoEquipo(
            label: 'TRACTOR',
            valor: (data['VEHICULO'] ?? '—').toString(),
            icono: Icons.local_shipping,
          ),
          Container(width: 1, height: 50, color: Colors.white10),
          _DatoEquipo(
            label: 'ENGANCHE',
            valor: (data['ENGANCHE'] ?? '—').toString(),
            icono: Icons.grid_view,
          ),
        ],
      ),
    );
  }
}

class _DatoEquipo extends StatelessWidget {
  final String label;
  final String valor;
  final IconData icono;

  const _DatoEquipo({
    required this.label,
    required this.valor,
    required this.icono,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icono, color: AppColors.success, size: 30),
        const SizedBox(height: AppSpacing.sm),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: Colors.white54,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          valor,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
            fontSize: 18,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String label;
  const _SectionTitle({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 10),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: AppColors.success,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

class _DatosCard extends StatelessWidget {
  final String dni;
  final Map<String, dynamic> data;

  /// Callback que persiste el cambio inline en Firestore
  /// (`{campo: valor}` sobre el doc del legajo). Lo provee el screen
  /// para reusar `_ejecutarTarea` (loading + feedback estándar).
  final Future<void> Function(String campo, String valor) onActualizarCampo;

  const _DatosCard({
    required this.dni,
    required this.data,
    required this.onActualizarCampo,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          _InfoTile(
            label: 'RAZÓN SOCIAL',
            valor: (data['EMPRESA'] ?? '—').toString(),
            icon: Icons.business,
          ),
          const _SeparadorTile(),
          _InfoTile(
            label: 'DNI / LEGAJO',
            valor: AppFormatters.formatearDNI(dni),
            icon: Icons.badge,
          ),
          const _SeparadorTile(),
          _InfoTile(
            label: 'CUIL',
            valor: AppFormatters.formatearCUIL(data['CUIL'] ?? '—'),
            icon: Icons.assignment_ind,
          ),
          const _SeparadorTile(),
          // TELÉFONO editable: el chofer puede actualizar su número de
          // contacto sin pasar por la oficina (caso típico: cambió de
          // chip o número). Mostramos sin el prefijo 549 (más legible),
          // y al guardar lo normalizamos con PhoneFormatter.paraGuardar
          // para que el bot WhatsApp lo pueda usar tal cual.
          _InfoTileEditable(
            label: 'TELÉFONO',
            valor: PhoneFormatter.paraMostrar(data['TELEFONO']?.toString()),
            icon: Icons.phone_android,
            inputFormatters: [DigitOnlyFormatter()],
            keyboardType: TextInputType.phone,
            aplicarMayusculas: false,
            hint: 'Ej. 2914567890 (sin 0 ni 15)',
            onSave: (v) =>
                onActualizarCampo('TELEFONO', PhoneFormatter.paraGuardar(v)),
          ),
          const _SeparadorTile(),
          // MAIL editable: idem teléfono, el chofer puede corregir o
          // actualizar su mail. Sin mayúsculas (los mails son case-
          // insensitive pero por convención se guardan en lowercase).
          _InfoTileEditable(
            label: 'MAIL',
            valor: (data['MAIL'] ?? '—').toString(),
            icon: Icons.alternate_email,
            keyboardType: TextInputType.emailAddress,
            aplicarMayusculas: false,
            transformarLowercase: true,
            hint: 'tu@email.com',
            onSave: (v) => onActualizarCampo('MAIL', v),
          ),
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String label;
  final String valor;
  final IconData icon;

  const _InfoTile({
    required this.label,
    required this.valor,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white54, size: 22),
      title: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          color: Colors.white54,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
      subtitle: Text(
        valor,
        // RAZÓN SOCIAL puede ser larga ("VECCHI ARIEL Y …"). 2 líneas
        // + ellipsis para que el ListTile no rompa en mobile.
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      dense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    );
  }
}

class _SeparadorTile extends StatelessWidget {
  const _SeparadorTile();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      color: Colors.white10,
      indent: 60,
      height: 1,
    );
  }
}

/// Variante de [_InfoTile] que es tappable para editar el valor inline.
///
/// Mismo look & feel que el read-only para que la card mantenga
/// consistencia visual, con un icono `edit_note` verde a la derecha
/// que indica al chofer que puede tocarlo. Al hacer tap se abre un
/// dialog modal con un `TextField` pre-cargado y seleccionado.
///
/// Diseño deliberado:
/// - Mismo `_InfoTile` por dentro (icon + label + value en 2 líneas).
/// - Trailing `edit_note` accentGreen → marca visual de "editable".
/// - El callback `onSave` recibe el texto trimeado y transformado
///   (mayúsculas o lowercase según flags). El parent decide cómo
///   normalizarlo antes de persistir (ej. PhoneFormatter.paraGuardar).
class _InfoTileEditable extends StatelessWidget {
  final String label;
  final String valor;
  final IconData icon;
  final ValueChanged<String> onSave;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputType? keyboardType;
  final bool aplicarMayusculas;
  final bool transformarLowercase;
  final String? hint;

  const _InfoTileEditable({
    required this.label,
    required this.valor,
    required this.icon,
    required this.onSave,
    this.inputFormatters,
    this.keyboardType,
    this.aplicarMayusculas = false,
    this.transformarLowercase = false,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white54, size: 22),
      title: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          color: Colors.white54,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
      subtitle: Text(
        valor.isEmpty ? '—' : valor,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: const Icon(
        Icons.edit_note,
        color: AppColors.success,
        size: 22,
      ),
      dense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      onTap: () => _mostrarDialogo(context),
    );
  }

  void _mostrarDialogo(BuildContext context) {
    // Si el valor actual es el placeholder "—" (sin dato cargado),
    // arrancamos el TextField vacío para que el chofer no tenga que
    // borrar el guion antes de tipear.
    final textoInicial = (valor == '—' || valor == '-') ? '' : valor;
    final controller = TextEditingController(text: textoInicial)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: textoInicial.length,
      );

    String transformar(String raw) {
      var t = raw.trim();
      if (aplicarMayusculas) t = t.toUpperCase();
      if (transformarLowercase) t = t.toLowerCase();
      return t;
    }

    showDialog<void>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withAlpha(20)),
        ),
        title: Text(
          'Editar $label',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: aplicarMayusculas
              ? TextCapitalization.characters
              : TextCapitalization.none,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: hint ?? 'Escribí el nuevo valor',
            hintStyle: const TextStyle(color: Colors.white38),
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear, color: Colors.white54),
              tooltip: 'Vaciar campo',
              onPressed: controller.clear,
            ),
          ),
          onSubmitted: (_) {
            Navigator.pop(dCtx);
            onSave(transformar(controller.text));
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('CANCELAR',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(dCtx);
              onSave(transformar(controller.text));
            },
            child: const Text('GUARDAR',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      // Cuando el dialog se cierra (por cualquier vía: GUARDAR,
      // CANCELAR, back, tap-outside) descartamos el controller para
      // evitar el leak de memoria que motivó esta auditoría.
    ).whenComplete(controller.dispose);
  }
}

/// UI degradada que se muestra cuando Firestore no responde en 10s o
/// el doc no existe. En lugar de "Perfil no encontrado" (alarmante),
/// mostramos lo que sabemos del chofer cacheado en Prefs (nombre,
/// apodo, rol) + un banner de conexión lenta + indicador de carga.
///
/// El stream sigue activo en background: si en algún momento Firestore
/// responde, el StreamBuilder padre re-renderiza con los datos
/// completos y este widget desaparece solo.
class _PerfilOfflineFallback extends StatelessWidget {
  final String dni;
  final String? motivo;

  const _PerfilOfflineFallback({required this.dni, this.motivo});

  @override
  Widget build(BuildContext context) {
    final nombre = PrefsService.nombre.trim();
    final apodo = PrefsService.apodo.trim();
    final rol = PrefsService.rol.trim();
    final dniFmt = AppFormatters.formatearDNI(dni);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Banner naranja avisando que estamos en modo limitado.
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.warning.withAlpha(40),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.warning.withAlpha(120)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.signal_wifi_bad_outlined,
                  color: AppColors.warning),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      motivo == null
                          ? 'Conexión lenta'
                          : 'Datos incompletos',
                      style: const TextStyle(
                        color: AppColors.warning,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      motivo ??
                          'Estamos mostrando los datos básicos mientras '
                              'cargan los detalles. Si tarda mucho, probá '
                              'cambiar de red (WiFi / datos móviles).',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),

        // Header básico con avatar + nombre. Sin foto (no la tenemos
        // del Prefs, solo del legajo Firestore).
        Center(
          child: Column(
            children: [
              CircleAvatar(
                radius: 50,
                backgroundColor: Colors.white.withAlpha(20),
                child: Text(
                  (apodo.isNotEmpty ? apodo : nombre)
                      .characters
                      .firstOrNull
                      ?.toUpperCase() ??
                      '?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                apodo.isNotEmpty ? apodo : nombre,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              if (apodo.isNotEmpty && nombre.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  nombre,
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 30),

        // Datos básicos disponibles sin Firestore.
        _FallbackTile(label: 'DNI', valor: dniFmt),
        if (rol.isNotEmpty) _FallbackTile(label: 'Rol', valor: rol),

        const SizedBox(height: 30),

        // Si solo es conexión lenta, mostramos indicador de carga
        // discreto al pie — el stream sigue intentando.
        if (motivo == null)
          const Center(
            child: Column(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.info,
                  ),
                ),
                SizedBox(height: 10),
                Text(
                  'Cargando datos completos…',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FallbackTile extends StatelessWidget {
  final String label;
  final String valor;

  const _FallbackTile({required this.label, required this.valor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              valor,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
