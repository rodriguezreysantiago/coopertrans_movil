import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../core/services/audit_log_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/digit_only_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';

/// Form de alta de un nuevo vehículo (tractor / batea / tolva).
class AdminVehiculoAltaScreen extends StatefulWidget {
  const AdminVehiculoAltaScreen({super.key});

  @override
  State<AdminVehiculoAltaScreen> createState() =>
      _AdminVehiculoAltaScreenState();
}

class _AdminVehiculoAltaScreenState
    extends State<AdminVehiculoAltaScreen> {
  final _formKey = GlobalKey<FormState>();

  final _patenteCtrl = TextEditingController();
  final _marcaCtrl = TextEditingController();
  final _modeloCtrl = TextEditingController();
  final _anioCtrl = TextEditingController();
  final _vinCtrl = TextEditingController();

  String _tipo = 'TRACTOR';
  String _empresa =
      'VECCHI ARIEL Y VECCHI GRACIELA S.R.L: (30-70910015-3)';
  bool _guardando = false;

  static const _empresas = [
    'VECCHI ARIEL Y VECCHI GRACIELA S.R.L: (30-70910015-3)',
    'SUCESION DE VECCHI CARLOS LUIS: (20-08569424-4)',
  ];

  @override
  void initState() {
    super.initState();
    // Pre-cargamos marca por defecto VOLVO (el 95% de la flota es VOLVO).
    _marcaCtrl.text = 'VOLVO';
  }

  @override
  void dispose() {
    _patenteCtrl.dispose();
    _marcaCtrl.dispose();
    _modeloCtrl.dispose();
    _anioCtrl.dispose();
    _vinCtrl.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
    if (_guardando) return;

    setState(() => _guardando = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final patente =
        _patenteCtrl.text.trim().toUpperCase().replaceAll(' ', '');

    try {
      // 1) ¿Ya existe?
      final doc = await FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .doc(patente)
          .get();

      if (doc.exists) {
        if (!mounted) return;
        AppFeedback.errorOn(messenger, 'Esta patente ya está registrada en la flota.');
        setState(() => _guardando = false);
        return;
      }

      // 2) Crear el vehículo
      // Inicializamos los campos de vencimiento (fecha vacía + archivo
      // "-") según los specs del tipo. Así un tractor recién creado
      // arranca con los 4 vencimientos listos y un enganche con los 2.
      final initialFields = <String, dynamic>{
        'DOMINIO': patente,
        'TIPO': _tipo,
        'MARCA': _marcaCtrl.text.trim().toUpperCase(),
        'MODELO': _modeloCtrl.text.trim().toUpperCase(),
        'ANIO': int.tryParse(_anioCtrl.text.trim()) ?? 0,
        'VIN': _tipo == 'TRACTOR'
            ? _vinCtrl.text.trim().toUpperCase()
            : '-',
        'EMPRESA': _empresa,
        'ESTADO': 'LIBRE',
        'KM_ACTUAL': 0,
        'fecha_alta': FieldValue.serverTimestamp(),
      };
      for (final spec in AppVencimientos.forTipo(_tipo)) {
        initialFields[spec.campoFecha] = '';
        initialFields[spec.campoArchivo] = '-';
      }

      await FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .doc(patente)
          .set(initialFields);

      unawaited(AuditLog.registrar(
        accion: AuditAccion.crearVehiculo,
        entidad: 'VEHICULOS',
        entidadId: patente,
        detalles: {
          'tipo': _tipo,
          'marca': _marcaCtrl.text.trim().toUpperCase(),
          'modelo': _modeloCtrl.text.trim().toUpperCase(),
          'empresa': _empresa,
        },
      ));

      if (!mounted) return;
      AppFeedback.successOn(messenger, 'Unidad registrada con éxito');
      navigator.pop();
    } catch (e, s) {
      if (!mounted) return;
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo registrar la unidad. Probá de nuevo.',
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
        title: 'Alta de Nueva Unidad',
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
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _VInput(
                  label: 'Patente / Dominio',
                  controller: _patenteCtrl,
                  icon: Icons.pin,
                  hint: 'Ej: AA123BB o AAA123',
                  isPatente: true,
                ),
                const _LabelCampo('Tipo de unidad'),
                const SizedBox(height: 10),
                _SelectorTipo(
                  tipo: _tipo,
                  enabled: !_guardando,
                  onChanged: (val) {
                    setState(() {
                      _tipo = val;
                      // Limpiamos el VIN si cambia a un acoplado
                      if (val != 'TRACTOR') _vinCtrl.clear();
                      // Marca: para TRACTOR Vecchi opera 100% VOLVO;
                      // para acoplados (BATEA, TOLVA, BIVUELCO,
                      // TANQUE) la marca varía — dejamos el campo
                      // editable y limpiamos el default VOLVO si se
                      // cambia desde TRACTOR. Si vuelve a TRACTOR
                      // restauramos el default.
                      if (val == 'TRACTOR') {
                        if (_marcaCtrl.text.trim().isEmpty) {
                          _marcaCtrl.text = 'VOLVO';
                        }
                      } else {
                        if (_marcaCtrl.text.trim().toUpperCase() ==
                            'VOLVO') {
                          _marcaCtrl.clear();
                        }
                      }
                    });
                  },
                ),
                const SizedBox(height: 25),
                _VInput(
                  label: 'Marca',
                  controller: _marcaCtrl,
                  icon: Icons.factory,
                  // TRACTOR es siempre VOLVO en la flota Vecchi (read
                  // only); para acoplados la marca es libre.
                  readOnly: _tipo == 'TRACTOR',
                ),
                _VInput(
                  label: 'Modelo',
                  controller: _modeloCtrl,
                  icon: Icons.commute,
                ),
                _VInput(
                  label: 'Año (modelo)',
                  controller: _anioCtrl,
                  icon: Icons.calendar_today,
                  isNumeric: true,
                  maxLength: 4,
                  isAnio: true,
                ),
                if (_tipo == 'TRACTOR')
                  _VInput(
                    label: 'Código VIN',
                    controller: _vinCtrl,
                    icon: Icons.fingerprint,
                    hint: 'Obligatorio (17 caracteres)',
                    isVin: true,
                    textInputAction: TextInputAction.done,
                  ),
                const _LabelCampo('Empresa propietaria'),
                const SizedBox(height: 10),
                _DropdownEmpresa(
                  value: _empresa,
                  empresas: _empresas,
                  enabled: !_guardando,
                  onChanged: (val) =>
                      setState(() => _empresa = val ?? _empresa),
                ),
                const SizedBox(height: 40),
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
// COMPONENTES (similares a admin_personal_form pero con validaciones de patente/VIN/año)
// =============================================================================

class _LabelCampo extends StatelessWidget {
  final String label;
  const _LabelCampo(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 11,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

class _VInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final IconData icon;
  final bool isNumeric;
  final String? hint;
  final int? maxLength;
  final bool isVin;
  final bool isPatente;
  final bool isAnio;
  final bool readOnly;
  final TextInputAction textInputAction;

  const _VInput({
    required this.label,
    required this.controller,
    required this.icon,
    this.isNumeric = false,
    this.hint,
    this.maxLength,
    this.isVin = false,
    this.isPatente = false,
    this.isAnio = false,
    this.readOnly = false,
    this.textInputAction = TextInputAction.next,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: TextFormField(
        controller: controller,
        keyboardType:
            isNumeric ? TextInputType.number : TextInputType.text,
        textInputAction: textInputAction,
        maxLength: maxLength,
        readOnly: readOnly,
        textCapitalization: TextCapitalization.characters,
        // En campos numéricos (ej. año) filtramos cualquier no-dígito.
        // El keyboardType ayuda en mobile pero no garantiza nada en
        // desktop ni cuando el usuario pega del clipboard.
        inputFormatters: isNumeric
            ? [DigitOnlyFormatter(maxLength: maxLength)]
            : null,
        style: TextStyle(
          color: readOnly ? Colors.white54 : Colors.white,
          fontSize: 14,
        ),
        decoration: InputDecoration(
          counterText: '',
          labelText: label,
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.white24, fontSize: 11),
          prefixIcon: Icon(
            icon,
            color: readOnly
                ? Colors.white24
                : Theme.of(context).colorScheme.primary,
            size: 20,
          ),
        ),
        validator: (value) {
          if (value == null || value.trim().isEmpty) {
            return 'Campo obligatorio';
          }
          if (isPatente) {
            final regex = RegExp(r'^([A-Z]{2}\d{3}[A-Z]{2}|[A-Z]{3}\d{3})$');
            final clean =
                value.trim().toUpperCase().replaceAll(' ', '');
            if (!regex.hasMatch(clean)) {
              return 'Formato inválido (Ej: AA123BB o AAA123)';
            }
          }
          if (isAnio) {
            final anio = int.tryParse(value.trim());
            if (anio == null) return 'Ingrese un año válido';
            if (anio < 2015) {
              return 'Solo se admiten unidades modelo 2015 en adelante';
            }
            if (anio > DateTime.now().year + 1) {
              return 'Año fuera de rango';
            }
          }
          if (isVin && value.trim().length != 17) {
            return 'El código VIN debe tener exactamente 17 caracteres';
          }
          return null;
        },
      ),
    );
  }
}

class _SelectorTipo extends StatelessWidget {
  final String tipo;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _SelectorTipo({
    required this.tipo,
    required this.enabled,
    required this.onChanged,
  });

  // Mapeo tipo → icono. Centralizado acá porque es solo para esta UI;
  // si se reutiliza en otra pantalla, se mueve a app_constants.dart.
  static const Map<String, IconData> _iconos = {
    'TRACTOR': Icons.local_shipping,
    'BATEA': Icons.view_agenda,
    'TOLVA': Icons.difference,
    'BIVUELCO': Icons.unfold_more,
    'TANQUE': Icons.propane_tank,
  };

  // Etiqueta capitalizada (primera letra mayúscula, resto minúscula).
  String _label(String t) => t.isEmpty
      ? t
      : '${t[0].toUpperCase()}${t.substring(1).toLowerCase()}';

  @override
  Widget build(BuildContext context) {
    const tipos = AppTiposVehiculo.seleccionables;
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: tipos.map((t) {
          final seleccionado = tipo == t;
          return ChoiceChip(
            avatar: Icon(
              _iconos[t] ?? Icons.directions_car,
              size: 16,
              color: seleccionado
                  ? Colors.black
                  : Theme.of(context).colorScheme.primary,
            ),
            label: Text(
              _label(t),
              style: TextStyle(
                fontSize: 12,
                color: seleccionado ? Colors.black : Colors.white,
                fontWeight:
                    seleccionado ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            selected: seleccionado,
            onSelected:
                enabled ? (selected) => onChanged(t) : null,
          );
        }).toList(),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(15)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: Theme.of(context).colorScheme.surface,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          items: empresas
              .map((e) => DropdownMenuItem(
                    value: e,
                    child: Text(e, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: enabled ? onChanged : null,
        ),
      ),
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
    return SizedBox(
      width: double.infinity,
      height: 55,
      child: ElevatedButton.icon(
        onPressed: guardando ? null : onPressed,
        icon: guardando
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
            : const Icon(Icons.cloud_upload),
        label: Text(
          guardando ? 'REGISTRANDO...' : 'REGISTRAR EN FLOTA',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.success,
          foregroundColor: Colors.black,
          disabledBackgroundColor: AppColors.success.withAlpha(100),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
