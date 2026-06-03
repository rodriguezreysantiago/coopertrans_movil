import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/audit_log_service.dart';
import '../../../core/services/capabilities.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/digit_only_formatter.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/password_hasher.dart';
import '../../../shared/utils/upper_case_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/fecha_dialog.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Form de alta de un nuevo legajo de personal (chofer o admin).
class AdminPersonalFormScreen extends StatefulWidget {
  const AdminPersonalFormScreen({super.key});

  @override
  State<AdminPersonalFormScreen> createState() =>
      _AdminPersonalFormScreenState();
}

class _AdminPersonalFormScreenState
    extends State<AdminPersonalFormScreen> {
  final _formKey = GlobalKey<FormState>();

  final _dniCtrl = TextEditingController();
  final _nombreCtrl = TextEditingController();
  final _apodoCtrl = TextEditingController();
  final _cuilCtrl = TextEditingController();
  final _mailCtrl = TextEditingController();
  final _iButtonCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _domicilioCtrl = TextEditingController();

  // Datos de RRHH incorporados desde la planilla de personal (2026-06).
  // Opcionales al alta; se guardan como 'YYYY-MM-DD' igual que los
  // vencimientos. Edad/antigüedad se calculan, no se guardan.
  DateTime? _fechaNac;
  DateTime? _fechaIngreso;

  String _rol = AppRoles.chofer;
  String _area = AppAreas.manejo;
  // Catálogo único en `AppEmpresasEmpleadoras.catalogo` — el campo
  // `EMPRESA` se sigue guardando como string completo (`label`) para
  // no romper compat con docs existentes.
  String _empresa = AppEmpresasEmpleadoras.catalogo.first.label;
  bool _guardando = false;

  static List<String> get _empresas =>
      AppEmpresasEmpleadoras.catalogo.map((e) => e.label).toList();

  @override
  void dispose() {
    _dniCtrl.dispose();
    _nombreCtrl.dispose();
    _apodoCtrl.dispose();
    _cuilCtrl.dispose();
    _mailCtrl.dispose();
    _iButtonCtrl.dispose();
    _passCtrl.dispose();
    _domicilioCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFechaNac() async {
    final picked = await pickFecha(
      context,
      initial: _fechaNac,
      titulo: 'Fecha de nacimiento',
      minimo: DateTime(1940),
      maximo: DateTime.now(),
    );
    if (picked != null) setState(() => _fechaNac = picked);
  }

  Future<void> _pickFechaIngreso() async {
    final picked = await pickFecha(
      context,
      initial: _fechaIngreso,
      titulo: 'Fecha de ingreso',
      minimo: DateTime(1980),
      maximo: DateTime.now(),
    );
    if (picked != null) setState(() => _fechaIngreso = picked);
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
    if (_guardando) return;

    setState(() => _guardando = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      final dni = _dniCtrl.text.trim();

      // 1) Verificar que el DNI no exista
      final doc = await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(dni)
          .get();

      if (!mounted) return;

      if (doc.exists) {
        AppFeedback.errorOn(messenger, 'Este DNI ya está registrado.');
        setState(() => _guardando = false);
        return;
      }

      // 2) Crear el legajo
      // ✅ Hash Bcrypt de la contraseña inicial. El plain text NUNCA se
      //    guarda en Firestore.
      final passwordHash =
          PasswordHasher.hashBcrypt(_passCtrl.text.trim());

      await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(dni)
          .set({
        'NOMBRE': _nombreCtrl.text.trim().toUpperCase(),
        // Apodo opcional — vacío se guarda como null para distinguirlo
        // de string vacío del lado del bot/cron.
        'APODO': _apodoCtrl.text.trim().isEmpty
            ? null
            : _apodoCtrl.text.trim(),
        'CUIL': _cuilCtrl.text.trim(),
        // Datos de RRHH (planilla de personal). Opcionales al alta — se
        // completan/editan después desde la ficha. Fechas como 'YYYY-MM-DD'.
        'DOMICILIO': _domicilioCtrl.text.trim().isEmpty
            ? null
            : _domicilioCtrl.text.trim(),
        'FECHA_NACIMIENTO':
            _fechaNac != null ? AppFormatters.aIsoFechaLocal(_fechaNac!) : null,
        'FECHA_INGRESO': _fechaIngreso != null
            ? AppFormatters.aIsoFechaLocal(_fechaIngreso!)
            : null,
        'MAIL': _mailCtrl.text.trim().toLowerCase(),
        // Código del iButton/tarjeta Sitrack del chofer. Opcional al
        // alta — si no lo cargás ahora, lo sumás después desde la
        // ficha del chofer. Se guarda en MAYÚSCULAS porque los códigos
        // hex de iButton son uppercase (ej. "53A6B11D000000F4").
        'IBUTTON': _iButtonCtrl.text.trim().isEmpty
            ? null
            : _iButtonCtrl.text.trim().toUpperCase(),
        'CONTRASEÑA': passwordHash,
        'ROL': _rol,
        'AREA': _area,
        'EMPRESA': _empresa,
        // CUIT denormalizado: la regla de Firestore lo usa para dejar al chofer
        // leer SU propia empresa empleadora (Póliza ART, F.931, etc.).
        'EMPRESA_CUIT': AppEmpresasEmpleadoras.cuitDeStringEmpresa(_empresa),
        'VEHICULO': '-',
        'ENGANCHE': '-',
        'ARCHIVO_PERFIL': '-',
        // Soft-delete oficial vive en AppActivo.campo ('ACTIVO': bool).
        // Antes solo escribiamos 'estado_cuenta': 'ACTIVO' (string) que
        // no es lo que mira el resto del codebase. Funcionaba "por
        // accidente" porque AppActivo.esActivo devuelve true cuando
        // ACTIVO es null o ausente. Para evitar drift si alguien setea
        // ACTIVO=false dejando estado_cuenta='ACTIVO', ahora seteamos
        // ambos explicito (bool es la fuente de verdad).
        AppActivo.campo: true,
        'estado_cuenta': 'ACTIVO',
        'fecha_creacion': FieldValue.serverTimestamp(),
        'ultima_modificacion': FieldValue.serverTimestamp(),
      });

      // Audit log fire-and-forget: el admin ya tiene su feedback
      // visual; si falla el log, no rompemos el flujo.
      unawaited(AuditLog.registrar(
        accion: AuditAccion.crearChofer,
        entidad: 'EMPLEADOS',
        entidadId: dni,
        detalles: {
          'nombre': _nombreCtrl.text.trim().toUpperCase(),
          'rol': _rol,
          'area': _area,
          'empresa': _empresa,
        },
      ));

      // El widget puede haberse desmontado durante el await; si fue así,
      // no usamos messenger ni navigator (sus referencias quedaron stale).
      if (!mounted) return;

      AppFeedback.successOn(messenger, 'Empleado creado con éxito');
      navigator.pop();
    } catch (e, s) {
      if (!mounted) return;
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo crear el empleado. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
      setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: AppScaffold(
        title: 'Nuevo chofer',
        // Ctrl+S guarda (Windows-friendly).
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
              if (!_guardando) _guardar();
            },
          },
          child: Focus(
            autofocus: true,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxxl),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ─── DATOS PERSONALES ──────────────────────────────
                    const _SeccionEyebrow('Datos personales'),
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _FormInput(
                            label: 'DNI (Será el usuario)',
                            controller: _dniCtrl,
                            icon: Icons.badge,
                            isNumeric: true,
                            maxLength: 8,
                          ),
                          _FormInput(
                            label: 'Apellido(s) y nombre(s)',
                            controller: _nombreCtrl,
                            icon: Icons.person,
                            // ORDEN OBLIGATORIO: APELLIDO primero, después
                            // nombre. Así está toda la base existente y así
                            // espera el algoritmo que extrae el primer
                            // nombre del saludo. Ej: "PEREZ JUAN",
                            // "GONZALEZ RODRIGUEZ JUAN CARLOS". Si el chofer
                            // tiene 2 apellidos o 2 nombres y el algoritmo
                            // se confunde, cargar el campo APODO. Va en
                            // MAYÚSCULAS para uniformar la base.
                          ),
                          _FormInput(
                            label: 'Apodo (opcional, cómo le decís)',
                            controller: _apodoCtrl,
                            icon: Icons.tag_faces,
                            // El apodo respeta como lo tipea el admin (no
                            // mayúsculas) — al saludar conviene "Carlos"
                            // antes que "CARLOS".
                            toUpperCase: false,
                            isOptional: true,
                          ),
                          _FormInput(
                            label: 'CUIL (sin guiones)',
                            controller: _cuilCtrl,
                            icon: Icons.assignment_ind,
                            isNumeric: true,
                            maxLength: 11,
                            isCuil: true,
                          ),
                          _FormInput(
                            label: 'Domicilio (opcional)',
                            controller: _domicilioCtrl,
                            icon: Icons.home_outlined,
                            // Domicilio respeta como lo tipea el admin.
                            toUpperCase: false,
                            isOptional: true,
                          ),
                          _CampoFecha(
                            label: 'Fecha de nacimiento (opcional)',
                            icon: Icons.cake_outlined,
                            valor: _fechaNac,
                            onTap: _guardando ? null : _pickFechaNac,
                          ),
                          _CampoFecha(
                            label: 'Fecha de ingreso (opcional)',
                            icon: Icons.event_available_outlined,
                            valor: _fechaIngreso,
                            onTap: _guardando ? null : _pickFechaIngreso,
                            isLast: true,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),

                    // ─── CONTACTO Y ACCESO ─────────────────────────────
                    const _SeccionEyebrow('Contacto y acceso'),
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _FormInput(
                            label: 'Mail (opcional)',
                            controller: _mailCtrl,
                            icon: Icons.alternate_email,
                            // El mail va tal cual lo tipea el admin (sin
                            // mayúsculas).
                            toUpperCase: false,
                            isMail: true,
                          ),
                          _FormInput(
                            label: 'iButton Sitrack (opcional)',
                            controller: _iButtonCtrl,
                            icon: Icons.fingerprint,
                            // Código de la tarjeta/iButton que identifica al
                            // chofer en Sitrack. Lo encontrás en el portal
                            // Sitrack → ficha del chofer → "Identificación".
                            // Ej. "53A6B11D000000F4" (16 chars hex). Si
                            // todavía no se lo asignaron al chofer, dejá
                            // vacío y lo cargás después.
                            isOptional: true,
                          ),
                          _FormInput(
                            label: 'Contraseña inicial',
                            controller: _passCtrl,
                            icon: Icons.lock_outline,
                            textInputAction: TextInputAction.done,
                            isPassword: true,
                            isLast: true,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),

                    // ─── ASIGNACIÓN ────────────────────────────────────
                    const _SeccionEyebrow('Asignación'),
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _CampoLabel('Empresa asignada'),
                          _DropdownEmpresa(
                            value: _empresa,
                            empresas: _empresas,
                            enabled: !_guardando,
                            onChanged: (val) =>
                                setState(() => _empresa = val ?? _empresa),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          const AppHairline(),
                          const SizedBox(height: AppSpacing.lg),
                          const _CampoLabel('Rol en el sistema'),
                          const SizedBox(height: AppSpacing.sm),
                          _RoleSelector(
                            rol: _rol,
                            enabled: !_guardando,
                            // Al cambiar el rol, sugerimos el área default
                            // coherente (CHOFER → MANEJO, ADMIN →
                            // ADMINISTRACION, etc). El admin puede
                            // sobreescribir con el dropdown de área de abajo
                            // si quiere.
                            onChanged: (val) => setState(() {
                              _rol = val;
                              _area = AppAreas.defaultParaRol(val);
                            }),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          const _CampoLabel('Área en la empresa'),
                          const SizedBox(height: AppSpacing.sm),
                          _DropdownArea(
                            value: _area,
                            enabled: !_guardando,
                            onChanged: (val) =>
                                setState(() => _area = val ?? _area),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xxl),
                    _BotonGuardar(
                      guardando: _guardando,
                      onPressed: _guardar,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// COMPONENTES
// =============================================================================

/// Eyebrow de sección (DATOS PERSONALES / CONTACTO / ASIGNACIÓN) — precede
/// a cada AppCard del bento. Mismo gesto que el resto del módulo Núcleo.
class _SeccionEyebrow extends StatelessWidget {
  final String texto;
  const _SeccionEyebrow(this.texto);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs, bottom: AppSpacing.sm),
      child: AppEyebrow(texto),
    );
  }
}

/// Label de un campo dentro de una card (Empresa / Rol / Área). Usa el
/// eyebrow uppercase/mono del sistema para alinear con AppInput.
class _CampoLabel extends StatelessWidget {
  final String label;
  const _CampoLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: AppEyebrow(label),
    );
  }
}

class _FormInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final IconData icon;
  final bool isNumeric;
  final int? maxLength;
  final bool isCuil;
  final bool isMail;
  /// Si es true, el texto se transforma a MAYÚSCULAS mientras se tipea.
  /// Default true para que los campos de identificación (DNI, nombre,
  /// CUIL) queden uniformes. Antes se hacía con `textCapitalization`,
  /// pero eso rompe el Backspace en Windows desktop.
  final bool toUpperCase;
  /// Si es true, el campo puede quedar vacío sin error de validación.
  /// Default false: campo obligatorio. Usar para campos como APODO o
  /// teléfono opcional.
  final bool isOptional;
  /// Si es true, valida longitud mínima de 6 caracteres (auditoria
  /// 2026-05-17 — antes admin podia crear chofer con clave "1" y la
  /// mayoria de choferes nunca cambia la pass inicial).
  final bool isPassword;
  final TextInputAction textInputAction;

  /// Si es true, este campo es el ÚLTIMO de su card → sin padding inferior
  /// (la card ya aporta su inset de 20). Solo presentación; no afecta la
  /// lógica de entrada/validación.
  final bool isLast;

  const _FormInput({
    required this.label,
    required this.controller,
    required this.icon,
    this.isNumeric = false,
    this.maxLength,
    this.isCuil = false,
    this.isMail = false,
    this.toUpperCase = true,
    this.isOptional = false,
    this.isPassword = false,
    this.textInputAction = TextInputAction.next,
    this.isLast = false,
  });

  // Regex muy laxo, solo para evitar typos groseros (espacios, falta de @, etc.).
  static final RegExp _mailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.lg),
      child: TextFormField(
        controller: controller,
        maxLength: maxLength,
        // Contraseñas son case-sensitive — el keyboard no debe sugerir
        // texto (autocorrect/autofill apuntan a la contra del usuario).
        // `obscureText` muestra puntitos en lugar del plain text.
        obscureText: isPassword,
        autocorrect: !isPassword,
        enableSuggestions: !isPassword,
        keyboardType: isPassword
            ? TextInputType.visiblePassword
            : (isMail
                ? TextInputType.emailAddress
                : (isNumeric ? TextInputType.number : TextInputType.text)),
        textInputAction: textInputAction,
        // Formatters según el tipo de campo:
        // - Numérico (DNI, CUIL, teléfono): solo dígitos. El keyboardType
        //   number ayuda en mobile pero no garantiza nada en desktop ni
        //   en paste, por eso el DigitOnlyFormatter es la red real.
        // - Texto con toUpperCase: mayúsculas vivas, evitando
        //   `textCapitalization` que rompe Backspace en Windows.
        // - Contraseña: NUNCA forzar mayúsculas (auditoria 2026-05-18 —
        //   Santiago no podia cargar "Apple2026Demo!" porque el campo
        //   uppercaseaba todo y rompia el match contra bcrypt).
        inputFormatters: [
          if (isNumeric) DigitOnlyFormatter(maxLength: maxLength),
          if (!isNumeric && !isPassword && toUpperCase)
            UpperCaseInputFormatter(),
        ],
        style: AppType.body.copyWith(color: c.text),
        decoration: InputDecoration(
          counterText: '',
          labelText: label,
          prefixIcon: Icon(
            icon,
            color: c.brand,
            size: 20,
          ),
        ),
        validator: (value) {
          final v = value?.trim() ?? '';
          // El mail es opcional: si está vacío, OK. Si tiene texto, validamos.
          if (isMail) {
            if (v.isEmpty) return null;
            if (!_mailRegex.hasMatch(v)) return 'Mail inválido';
            return null;
          }
          if (v.isEmpty) {
            if (isOptional) return null;
            return 'Campo obligatorio';
          }
          if (isNumeric && v.length < (maxLength ?? 0)) {
            return 'Dato incompleto';
          }
          if (isCuil && v.length != 11) {
            return 'El CUIL debe tener 11 dígitos';
          }
          if (isPassword && v.length < 6) {
            return 'La contraseña debe tener al menos 6 caracteres';
          }
          return null;
        },
      ),
    );
  }
}

class _DropdownEmpresa extends StatelessWidget {
  final String value;
  final List<String> empresas;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  const _DropdownEmpresa({
    required this.value,
    required this.empresas,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: c.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: c.surface3,
          style: AppType.body.copyWith(color: c.text),
          items: empresas
              .map(
                (e) => DropdownMenuItem(
                  value: e,
                  child: Text(e, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }
}

/// Selector de rol del sistema. Migramos de SegmentedButton (binario)
/// a Dropdown porque ahora tenemos 4 roles que no entran cómodos en
/// segments horizontales:
///
///   CHOFER     → empleado de manejo con vehículo asignado.
///   PLANTA     → empleado sin vehículo (planta, taller, gomería).
///   SUPERVISOR → mando medio con permisos de gestión (no admin).
///   ADMIN      → control total.
class _RoleSelector extends StatelessWidget {
  final String rol;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _RoleSelector({
    required this.rol,
    required this.enabled,
    required this.onChanged,
  });

  /// Etiqueta auxiliar para describir cada rol en el dropdown.
  static String _descripcion(String r) {
    switch (r) {
      case AppRoles.chofer:
        return 'Personal de manejo (con vehículo)';
      case AppRoles.planta:
        return 'Sin vehículo (planta / taller / gomería)';
      case AppRoles.supervisor:
        return 'Gestión operativa (sin crear admins)';
      case AppRoles.admin:
        return 'Control total del sistema';
    }
    return '';
  }

  static IconData _icono(String r) {
    switch (r) {
      case AppRoles.chofer:
        return Icons.drive_eta;
      case AppRoles.planta:
        return Icons.engineering;
      case AppRoles.supervisor:
        return Icons.supervisor_account;
      case AppRoles.admin:
        return Icons.security;
    }
    return Icons.person;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final roles = AppRoles.todos.where((r) {
      if (r == AppRoles.admin &&
          !Capabilities.can(
              PrefsService.rol, Capability.asignarRolAdmin)) {
        return false;
      }
      return true;
    }).toList();

    return DropdownButtonFormField<String>(
      initialValue: rol,
      // isExpanded: true hace que el dropdown tome el ancho del parent,
      // dando un BoxConstraints bounded al Row interno. Sin esto, el
      // Row+Expanded del item seleccionado pegaba "RenderFlex unbounded
      // width" al renderizar (incidente Santiago 2026-05-18).
      isExpanded: true,
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.badge_outlined),
      ),
      // Para el item SELECCIONADO usamos un layout sin Expanded (texto
      // simple) — el Row+Expanded original solo se usa para los items
      // del DROPDOWN abierto, que sí tienen width bounded del menú.
      selectedItemBuilder: (context) => roles.map((r) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icono(r), size: 18, color: c.brand),
              const SizedBox(width: AppSpacing.md),
              Flexible(
                child: Text(
                  AppRoles.etiquetas[r] ?? r,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(color: c.text),
                ),
              ),
            ],
          ),
        );
      }).toList(),
      items: roles.map((r) {
        return DropdownMenuItem(
          value: r,
          child: Row(
            children: [
              Icon(_icono(r), size: 18, color: c.brand),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppRoles.etiquetas[r] ?? r,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body.copyWith(color: c.text),
                    ),
                    Text(
                      _descripcion(r),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.eyebrow,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
      onChanged: enabled ? (val) => val == null ? null : onChanged(val) : null,
    );
  }
}

/// Selector de área organizacional. Independiente del rol — define
/// dónde trabaja la persona (descriptivo, no afecta permisos).
class _DropdownArea extends StatelessWidget {
  final String value;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  const _DropdownArea({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.factory_outlined),
      ),
      items: AppAreas.todas.map((a) {
        return DropdownMenuItem(
          value: a,
          child: Text(
            AppAreas.etiquetas[a] ?? a,
            style: AppType.body.copyWith(color: c.text),
          ),
        );
      }).toList(),
      onChanged: enabled ? onChanged : null,
    );
  }
}

class _BotonGuardar extends StatelessWidget {
  final bool guardando;
  final VoidCallback onPressed;

  const _BotonGuardar({
    required this.guardando,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: 'Crear legajo',
      icon: Icons.person_add_alt_1,
      size: AppButtonSize.lg,
      expand: true,
      isLoading: guardando,
      onPressed: guardando ? null : onPressed,
    );
  }
}

/// Campo tappable de FECHA para el form de alta. Muestra la fecha elegida
/// (o un placeholder) con el mismo look que [_FormInput] (InputDecorator +
/// prefixIcon brand), y al tocar abre el date picker del sistema. `onTap`
/// null lo deshabilita (mientras se guarda).
class _CampoFecha extends StatelessWidget {
  final String label;
  final IconData icon;
  final DateTime? valor;
  final VoidCallback? onTap;
  final bool isLast;

  const _CampoFecha({
    required this.label,
    required this.icon,
    required this.valor,
    required this.onTap,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            prefixIcon: Icon(icon, color: c.brand, size: 20),
          ),
          child: Text(
            valor != null
                ? AppFormatters.formatearFecha(valor)
                : 'Sin especificar',
            style: AppType.body.copyWith(
              color: valor != null ? c.text : c.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
