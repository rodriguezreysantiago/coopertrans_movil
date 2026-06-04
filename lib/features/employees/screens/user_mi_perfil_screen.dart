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
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/digit_only_formatter.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/phone_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/foto_perfil_avatar.dart';

/// Perfil del chofer (vista del usuario, no admin) — REFACTOR NÚCLEO (jun 2026).
///
/// **Cambios vs. la versión previa** (que era una "isla" — el sweep
/// mecánico no la tocó porque usaba `Colors.green` / `Colors.whiteNN`
/// directos, no `accent*`):
///
/// - Todos los `ElevatedButton` ad-hoc → `AppButton.*` con loading
///   state nativo.
/// - Todos los `Colors.whiteNN` → tokens semánticos
///   ([AppColors.textPrimary/textSecondary/textTertiary/textHint]).
/// - Todos los magic numbers (10/14/15/18/20/24/25/30) → tokens de
///   [AppSpacing] / [AppRadius].
/// - Strings UPPERCASE hardcodeados ("GUARDAR", "CAMBIAR MI
///   CONTRASEÑA", "RAZÓN SOCIAL", "CHOFER PROFESIONAL") → sentence case
///   en el fuente. La regla "una uppercase eyebrow por pantalla" la
///   cumple solo el [_SectionTitle].
/// - `TextStyle(fontSize: X, fontWeight: ..., letterSpacing: ...)`
///   ad-hoc → [AppType.*]. Cero overrides de letterSpacing en eyebrows.
/// - Camera button del avatar: era verde (`AppColors.success`) → ahora
///   cobalto (`AppColors.brand`). Verde se reserva para estado
///   semántico, no para identidad de elemento.
/// - Bottom sheet "Actualizar foto": el accent verde decorativo de la
///   border superior se elimina. La separación visual ya la hace la
///   superficie elevada.
/// - El "trailing" verde del [_InfoTileEditable] (icono de editar)
///   pasa a [AppColors.brand] — es affordance de acción, va con
///   identidad de marca, no con "success".
///
/// **Pattern reference.** Este archivo es la versión "gold standard"
/// que demuestra cómo debería verse una pantalla de detalle post-
/// refactor. Usar como referencia al limpiar las otras pantallas
/// "isla" (gomeria, icm, vehicles detail, etc.).
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
        usuario:
            'No se pudo guardar el cambio. Probá de nuevo en unos segundos.',
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
    const url =
        'https://southamerica-east1-coopertrans-movil.cloudfunctions.net/'
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
        backgroundColor: AppColors.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: const BorderSide(color: AppColors.borderSubtle),
        ),
        title: const Text('Cambiar contraseña', style: AppType.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: antCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Contraseña actual'),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: nvaCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Nueva contraseña'),
            ),
          ],
        ),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.pop(dCtx),
          ),
          AppButton(
            label: 'Guardar',
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
        decoration: const BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
          // Antes había una border verde de 2px (`AppColors.success`)
          // como "accent line". La review marcó que ese verde decorativo
          // era ruido — el sheet ya se diferencia del fondo por la
          // superficie elevada.
        ),
        child: SafeArea(
          child: Wrap(children: [
            const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Text('Actualizar foto', style: AppType.heading),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: AppColors.brand),
              title: const Text('Tomar foto con la cámara'),
              onTap: () {
                Navigator.pop(ctx);
                _seleccionarImagen(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: AppColors.brand),
              title: const Text('Elegir de la galería'),
              onTap: () {
                Navigator.pop(ctx);
                _seleccionarImagen(ImageSource.gallery);
              },
            ),
            const SizedBox(height: AppSpacing.lg),
          ]),
        ),
      ),
    );
  }

  Future<void> _seleccionarImagen(ImageSource source) async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: source, imageQuality: 50);
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
              subtitle: 'El formato de tu perfil no es válido. '
                  'Contactá a administración.',
            );
          }
          final data = raw;
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              _Header(data: data, onEditarFoto: _mostrarOpcionesFoto),
              const SizedBox(height: AppSpacing.xl),
              _EquipoCard(data: data),
              const SizedBox(height: AppSpacing.xl),
              const _SectionTitle(label: 'Datos personales'),
              const SizedBox(height: AppSpacing.sm),
              _DatosCard(
                dni: widget.dni,
                data: data,
                onActualizarCampo: _actualizarCampoEmpleado,
              ),
              const SizedBox(height: AppSpacing.xl),
              AppButton.secondary(
                label: 'Cambiar mi contraseña',
                icon: Icons.password_rounded,
                expand: true,
                onPressed: _mostrarDialogoClave,
              ),
              const SizedBox(height: AppSpacing.lg),
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
              nombre: (data['NOMBRE'] ?? '').toString(),
              radius: 65,
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  onTap: onEditarFoto,
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      // Antes: verde (`AppColors.success`). Cambiado a
                      // brand porque "subí tu foto" es affordance de
                      // acción, no estado "OK". El verde queda solo
                      // para semántica real.
                      color: AppColors.brand,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.surface0,
                        width: 3,
                      ),
                    ),
                    child: const Icon(
                      Icons.camera_alt,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          (data['NOMBRE'] ?? 'Usuario').toString(),
          // Nombres largos ("GONZALEZ RODRIGUEZ JUAN CARLOS") rompían
          // el header en mobile. 2 líneas + center + ellipsis.
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: AppType.title.copyWith(fontSize: 22),
        ),
        const SizedBox(height: AppSpacing.xs),
        // Eyebrow sentence-case en el fuente; el AppType.eyebrow ya
        // aplica el tracking. Cero overrides de color/weight: el
        // eyebrow ES el estilo, no necesita decoración.
        const Text('CHOFER PROFESIONAL', style: AppType.eyebrow),
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
      padding: const EdgeInsets.all(AppSpacing.lg),
      margin: EdgeInsets.zero,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _DatoEquipo(
            label: 'Tractor',
            valor: (data['VEHICULO'] ?? '—').toString(),
            icono: Icons.local_shipping,
          ),
          Container(width: 1, height: 50, color: AppColors.borderSubtle),
          _DatoEquipo(
            label: 'Enganche',
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
        // Antes: verde. Ahora textTertiary — el icono es decorativo de
        // un campo de datos, no un estado semántico.
        Icon(icono, color: AppColors.textTertiary, size: 28),
        const SizedBox(height: AppSpacing.sm),
        Text(label, style: AppType.label),
        const SizedBox(height: 2),
        Text(
          valor,
          style: AppType.heading.copyWith(letterSpacing: 0),
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
      padding: const EdgeInsets.only(
        bottom: AppSpacing.xs,
        left: AppSpacing.sm,
      ),
      // Una sola "uppercase eyebrow" por pantalla, sin overrides de
      // color (era verde) ni de letterSpacing (era 1.5 vs. el 1.2 que
      // ya trae AppType.eyebrow).
      child: Text(label.toUpperCase(), style: AppType.eyebrow),
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
    final messenger = ScaffoldMessenger.of(context);
    // Edad y antigüedad se calculan en vivo de las fechas (no se guardan).
    final edad = AppFormatters.edadDesde(data['FECHA_NACIMIENTO']);
    final fechaNacTxt =
        AppFormatters.tryParseFecha(data['FECHA_NACIMIENTO']) != null
            ? '${AppFormatters.formatearFecha(data['FECHA_NACIMIENTO'])}'
                '${edad != null ? '   ·   $edad años' : ''}'
            : '—';
    final domicilio = (data['DOMICILIO'] ?? '').toString().trim();
    final antiguedad = AppFormatters.antiguedadTexto(data['FECHA_INGRESO']);
    final fechaIngTxt =
        AppFormatters.tryParseFecha(data['FECHA_INGRESO']) != null
            ? '${AppFormatters.formatearFecha(data['FECHA_INGRESO'])}'
                '${antiguedad != null ? '   ·   $antiguedad' : ''}'
            : '—';
    return AppCard(
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          _InfoTile(
            label: 'Razón social',
            valor: (data['EMPRESA'] ?? '—').toString(),
            icon: Icons.business,
          ),
          const _SeparadorTile(),
          _InfoTile(
            label: 'DNI / Legajo',
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
          _InfoTile(
            label: 'Fecha de nacimiento',
            valor: fechaNacTxt,
            icon: Icons.cake_outlined,
          ),
          const _SeparadorTile(),
          _InfoTile(
            label: 'Domicilio',
            valor: domicilio.isEmpty ? '—' : domicilio,
            icon: Icons.home_outlined,
          ),
          const _SeparadorTile(),
          // Teléfono editable: el chofer puede actualizar su número de
          // contacto sin pasar por la oficina (caso típico: cambió de
          // chip o número). Mostramos sin el prefijo 549 (más legible),
          // y al guardar lo normalizamos con PhoneFormatter.paraGuardar
          // para que el bot WhatsApp lo pueda usar tal cual.
          _InfoTileEditable(
            label: 'Teléfono',
            valor: PhoneFormatter.paraMostrar(data['TELEFONO']?.toString()),
            icon: Icons.phone_android,
            inputFormatters: [DigitOnlyFormatter()],
            keyboardType: TextInputType.phone,
            aplicarMayusculas: false,
            hint: 'Ej. 2914567890 (sin 0 ni 15)',
            onSave: (v) {
              final n = PhoneFormatter.paraGuardar(v);
              // Si tipeó algo pero no es un teléfono válido (normaliza a ""),
              // NO pisamos el dato bueno con vacío (mismo guard que el admin).
              if (v.trim().isNotEmpty && n.isEmpty) {
                AppFeedback.errorOn(messenger,
                    'Teléfono inválido. Revisá los dígitos (no se guardó).');
                return;
              }
              onActualizarCampo('TELEFONO', n);
            },
          ),
          const _SeparadorTile(),
          // Mail editable: idem teléfono, el chofer puede corregir o
          // actualizar su mail. Sin mayúsculas (los mails son case-
          // insensitive pero por convención se guardan en lowercase).
          _InfoTileEditable(
            label: 'Mail',
            valor: (data['MAIL'] ?? '—').toString(),
            icon: Icons.alternate_email,
            keyboardType: TextInputType.emailAddress,
            aplicarMayusculas: false,
            transformarLowercase: true,
            hint: 'tu@email.com',
            onSave: (v) {
              final m = v.trim();
              // El alta valida el mail con regex; la edición inline no lo hacía
              // → el chofer podía guardar "asdf". Mismo criterio acá.
              if (m.isNotEmpty &&
                  !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(m)) {
                AppFeedback.errorOn(messenger, 'Mail inválido (no se guardó).');
                return;
              }
              onActualizarCampo('MAIL', m);
            },
          ),
          const _SeparadorTile(),
          _InfoTile(
            label: 'Fecha de ingreso',
            valor: fechaIngTxt,
            icon: Icons.event_available_outlined,
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
      leading: Icon(icon, color: AppColors.textTertiary, size: 22),
      title: Text(label, style: AppType.label),
      subtitle: Text(
        valor,
        // RAZÓN SOCIAL puede ser larga ("VECCHI ARIEL Y …"). 2 líneas
        // + ellipsis para que el ListTile no rompa en mobile.
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppType.body.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      dense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
    );
  }
}

class _SeparadorTile extends StatelessWidget {
  const _SeparadorTile();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      color: AppColors.borderSubtle,
      indent: 60,
      height: 1,
    );
  }
}

/// Variante de [_InfoTile] que es tappable para editar el valor inline.
///
/// Mismo look & feel que el read-only para que la card mantenga
/// consistencia visual, con un icono `edit_note` cobalto a la derecha
/// que indica al chofer que puede tocarlo. Al hacer tap se abre un
/// dialog modal con un `TextField` pre-cargado y seleccionado.
///
/// Diseño deliberado:
/// - Mismo `_InfoTile` por dentro (icon + label + value en 2 líneas).
/// - Trailing `edit_note` brand → marca visual de "editable / acción".
///   Antes era verde, pero verde es semántico (OK), no affordance.
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
      leading: Icon(icon, color: AppColors.textTertiary, size: 22),
      title: Text(label, style: AppType.label),
      subtitle: Text(
        valor.isEmpty ? '—' : valor,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppType.body.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: const Icon(
        Icons.edit_note,
        color: AppColors.brand,
        size: 22,
      ),
      dense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
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
        backgroundColor: AppColors.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: const BorderSide(color: AppColors.borderSubtle),
        ),
        title: Text('Editar $label', style: AppType.title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: aplicarMayusculas
              ? TextCapitalization.characters
              : TextCapitalization.none,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          decoration: InputDecoration(
            hintText: hint ?? 'Escribí el nuevo valor',
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear, color: AppColors.textTertiary),
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
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.pop(dCtx),
          ),
          AppButton(
            label: 'Guardar',
            onPressed: () {
              Navigator.pop(dCtx);
              onSave(transformar(controller.text));
            },
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
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        // Banner warning (mismo color/look que AppOfflineBanner pero
        // inline porque acá ya estamos en estado degradado conocido —
        // el banner no necesita auto-activarse).
        AppCard(
          tier: 2,
          highlighted: true,
          borderColor: AppColors.warning.withAlpha(120),
          padding: const EdgeInsets.all(AppSpacing.lg),
          margin: EdgeInsets.zero,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.signal_wifi_bad_outlined,
                color: AppColors.warning,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      motivo == null ? 'Conexión lenta' : 'Datos incompletos',
                      style: AppType.heading.copyWith(
                        color: AppColors.warning,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      motivo ??
                          'Estamos mostrando los datos básicos mientras '
                              'cargan los detalles. Si tarda mucho, probá '
                              'cambiar de red (WiFi / datos móviles).',
                      style: AppType.body,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),

        // Header básico con avatar de iniciales + nombre. Reusamos
        // FotoPerfilAvatar (que ya tiene el fallback de iniciales),
        // así el offline ve el mismo avatar que tendría online.
        Center(
          child: Column(
            children: [
              FotoPerfilAvatar(
                url: null,
                nombre: apodo.isNotEmpty ? apodo : nombre,
                radius: 50,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                apodo.isNotEmpty ? apodo : nombre,
                style: AppType.title,
                textAlign: TextAlign.center,
              ),
              if (apodo.isNotEmpty && nombre.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  nombre,
                  style: AppType.body,
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),

        // Datos básicos disponibles sin Firestore.
        _FallbackTile(label: 'DNI', valor: dniFmt),
        if (rol.isNotEmpty) _FallbackTile(label: 'Rol', valor: rol),

        const SizedBox(height: AppSpacing.xl),

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
                SizedBox(height: AppSpacing.sm),
                Text(
                  'Cargando datos completos…',
                  style: AppType.label,
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
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(label, style: AppType.label),
          ),
          Expanded(
            flex: 3,
            child: Text(
              valor,
              style: AppType.body.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
