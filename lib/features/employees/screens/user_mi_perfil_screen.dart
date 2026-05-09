import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/storage_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/password_hasher.dart';
import '../../../shared/utils/phone_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';

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

  @override
  void initState() {
    super.initState();
    _perfilStream = FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .doc(widget.dni)
        .snapshots();
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

  void _mostrarDialogoClave(String passwordActual) {
    final antCtrl = TextEditingController();
    final nvaCtrl = TextEditingController();

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
              // ✅ Verificación contra el hash almacenado (Bcrypt o SHA-256).
              //    Antes se comparaba texto-plano vs hash, lo cual nunca era igual.
              if (!PasswordHasher.verify(
                  antCtrl.text, passwordActual)) {
                AppFeedback.error(context, 'La contraseña actual es incorrecta');
                return;
              }
              if (nvaCtrl.text.trim().length < 4) {
                AppFeedback.warning(context, 'Mínimo 4 caracteres');
                return;
              }
              Navigator.pop(dCtx);
              // ✅ Guardamos el hash Bcrypt, no la contraseña en plano.
              final nuevoHash =
                  PasswordHasher.hashBcrypt(nvaCtrl.text);
              // El callback no es async pero _ejecutarTarea devuelve un
              // Future; lo descartamos explícito para que quede claro
              // y para anticiparnos a versiones más estrictas del lint.
              unawaited(_ejecutarTarea(
                tarea: () async => FirebaseFirestore.instance
                    .collection(AppCollections.empleados)
                    .doc(widget.dni)
                    .update({'CONTRASEÑA': nuevoHash}),
                mensajeExito: 'Contraseña actualizada correctamente',
              ));
            },
            child: const Text('GUARDAR',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
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
              top: BorderSide(color: AppColors.accentGreen, width: 2)),
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
                  const Icon(Icons.camera_alt, color: AppColors.accentGreen),
              title: const Text('Tomar foto con la cámara',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _seleccionarImagen(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library,
                  color: AppColors.accentGreen),
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
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const AppLoadingState();
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const AppErrorState(
              title: 'Perfil no encontrado',
              subtitle: 'No se pudieron cargar tus datos.',
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
              const SizedBox(height: 8),
              _DatosCard(dni: widget.dni, data: data),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                onPressed: () =>
                    _mostrarDialogoClave(data['CONTRASEÑA'] ?? ''),
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
    final tieneFoto = fotoUrl != null && fotoUrl.isNotEmpty;

    return Column(
      children: [
        Stack(
          children: [
            CircleAvatar(
              radius: 65,
              backgroundColor: Colors.white10,
              backgroundImage: tieneFoto ? NetworkImage(fotoUrl) : null,
              child: !tieneFoto
                  ? const Icon(Icons.person,
                      size: 70, color: Colors.white24)
                  : null,
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
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen,
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
        const SizedBox(height: 4),
        const Text(
          'CHOFER PROFESIONAL',
          style: TextStyle(
            color: AppColors.accentGreen,
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
        Icon(icono, color: AppColors.accentGreen, size: 30),
        const SizedBox(height: 8),
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
          color: AppColors.accentGreen,
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

  const _DatosCard({required this.dni, required this.data});

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
          _InfoTile(
            label: 'TELÉFONO',
            // Mostramos sin el prefijo 549 que guardamos en Firestore
            // (más legible para el chofer).
            valor: PhoneFormatter.paraMostrar(data['TELEFONO']?.toString()),
            icon: Icons.phone_android,
          ),
          const _SeparadorTile(),
          _InfoTile(
            label: 'MAIL',
            valor: (data['MAIL'] ?? '—').toString(),
            icon: Icons.alternate_email,
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
