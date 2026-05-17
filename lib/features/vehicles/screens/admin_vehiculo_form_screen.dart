import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../core/services/storage_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/digit_only_formatter.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/fecha_dialog.dart';
import '../../asignaciones/screens/asignacion_historial_vehiculo_screen.dart';
import '../services/volvo_api_service.dart';
import 'diagnostico_volvo_screen.dart';

// Componentes visuales del form (8 widgets _X) extraídos para bajar de
// 1093 a ~630 lineas el archivo principal. Comparten privacidad y los
// imports de arriba via `part of`.
part 'admin_vehiculo_form_widgets.dart';

/// Form de edición de la ficha de un vehículo existente.
///
/// Permite:
/// - Editar datos técnicos (marca, modelo, año, VIN, KM)
/// - Cambiar empresa propietaria
/// - Sincronizar KM con Volvo Connect manualmente
/// - Editar fechas de RTO y Seguro
/// - Subir comprobantes (foto o PDF) para RTO y Seguro
class AdminVehiculoFormScreen extends StatefulWidget {
  final String vehiculoId;
  final Map<String, dynamic> datosIniciales;

  const AdminVehiculoFormScreen({
    super.key,
    required this.vehiculoId,
    required this.datosIniciales,
  });

  @override
  State<AdminVehiculoFormScreen> createState() =>
      _AdminVehiculoFormScreenState();
}

class _AdminVehiculoFormScreenState extends State<AdminVehiculoFormScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _isSaving = false;
  bool _isSyncing = false;

  late final TextEditingController _marcaCtrl;
  late final TextEditingController _modeloCtrl;
  late final TextEditingController _anioCtrl;
  late final TextEditingController _empresaCtrl;
  late final TextEditingController _vinCtrl;
  late final TextEditingController _kmCtrl;

  /// KM_ACTUAL guardado en Firestore al cargar el form. Sirve para
  /// detectar si el operador esta REDUCIENDO el odometro (probable
  /// typo) y pedir confirmacion antes de guardar (auditoria 2026-05-17).
  double? _kmActualDb;

  // ─── Mantenimiento preventivo (campos manuales) ───────────────────
  // Histórico del último service: lo carga el admin a mano cuando el
  // taller termina la visita. Se muestra en la pantalla de
  // mantenimiento como complemento al `serviceDistance` que viene de
  // Volvo en tiempo real.
  late final TextEditingController _ultimoServiceKmCtrl;
  String? _ultimoServiceFecha;

  /// Estado de los vencimientos, indexado por el nombre del campo de
  /// Firestore. Usar maps en lugar de variables individuales nos permite
  /// agregar nuevos vencimientos en el futuro tocando SOLO la lista
  /// `AppVencimientos`.
  final Map<String, String?> _fechas = {};
  final Map<String, String?> _urls = {};

  /// URL pública de la foto identificatoria del vehículo (campo
  /// `ARCHIVO_FOTO`). Es opcional — si no hay, la card cae a un ícono.
  String? _urlFoto;
  bool _subiendoFoto = false;

  /// Lista de vencimientos que aplica a este vehículo, según su tipo
  /// (tractor → 4 vencimientos; enganche → 2). Se calcula una sola vez
  /// en initState y se usa en _guardar y en build.
  late final List<VencimientoSpec> _vencimientos;

  @override
  void initState() {
    super.initState();
    final d = widget.datosIniciales;
    _marcaCtrl = TextEditingController(text: d['MARCA']?.toString() ?? '');
    _modeloCtrl =
        TextEditingController(text: d['MODELO']?.toString() ?? '');
    _anioCtrl = TextEditingController(
      text: (d['ANIO'] ?? d['AÑO'])?.toString() ?? '',
    );
    _empresaCtrl =
        TextEditingController(text: d['EMPRESA']?.toString() ?? '');
    _vinCtrl = TextEditingController(text: d['VIN']?.toString() ?? '');
    _kmCtrl =
        TextEditingController(text: d['KM_ACTUAL']?.toString() ?? '0');
    // Snapshot del km al cargar para detectar regresion en _guardar.
    final kmRaw = d['KM_ACTUAL'];
    _kmActualDb = kmRaw is num ? kmRaw.toDouble() : null;

    // Campos manuales del último service. Pueden venir vacíos si nunca
    // se cargaron (tractor recién dado de alta).
    _ultimoServiceKmCtrl = TextEditingController(
      text: d['ULTIMO_SERVICE_KM']?.toString() ?? '',
    );
    final fechaServiceRaw = d['ULTIMO_SERVICE_FECHA']?.toString();
    _ultimoServiceFecha = (fechaServiceRaw != null &&
            fechaServiceRaw.isNotEmpty &&
            fechaServiceRaw != '-')
        ? fechaServiceRaw
        : null;

    _vencimientos = AppVencimientos.forTipo(d['TIPO']?.toString());
    for (final spec in _vencimientos) {
      _fechas[spec.campoFecha] = d[spec.campoFecha]?.toString();
      _urls[spec.campoArchivo] = d[spec.campoArchivo]?.toString();
    }
    final fotoCruda = d['ARCHIVO_FOTO']?.toString();
    if (fotoCruda != null && fotoCruda.isNotEmpty && fotoCruda != '-') {
      _urlFoto = fotoCruda;
    }
  }

  @override
  void dispose() {
    _marcaCtrl.dispose();
    _modeloCtrl.dispose();
    _anioCtrl.dispose();
    _empresaCtrl.dispose();
    _vinCtrl.dispose();
    _kmCtrl.dispose();
    _ultimoServiceKmCtrl.dispose();
    super.dispose();
  }

  /// Abre el `pickFecha` para elegir cuándo se hizo el último service.
  /// La guardamos como String ISO ("YYYY-MM-DD") para ser consistentes
  /// con el resto de las fechas del proyecto.
  ///
  /// Restringe a fechas pasadas o de hoy — el último service no puede
  /// estar en el futuro. Si lo eligen, lo rechazamos con feedback.
  Future<void> _seleccionarFechaUltimoService() async {
    final messenger = ScaffoldMessenger.of(context);
    final initial = (_ultimoServiceFecha != null)
        ? AppFormatters.tryParseFecha(_ultimoServiceFecha!)
        : null;
    final picked = await pickFecha(
      context,
      initial: initial,
      titulo: 'Fecha del último service',
    );
    if (picked == null || !mounted) return;
    // Bug B3: si el admin elige fecha futura por error (typo en el year),
    // rechazamos. El picker no la limita por defecto.
    final hoy = DateTime.now();
    final hoyTruncado = DateTime(hoy.year, hoy.month, hoy.day);
    final pickedTruncado = DateTime(picked.year, picked.month, picked.day);
    if (pickedTruncado.isAfter(hoyTruncado)) {
      AppFeedback.warningOn(
        messenger,
        'La fecha del último service no puede estar en el futuro.',
      );
      return;
    }
    setState(() {
      _ultimoServiceFecha = AppFormatters.aIsoFechaLocal(picked);
    });
  }

  // ---------------------------------------------------------------------------
  // ACCIONES
  // ---------------------------------------------------------------------------

  /// Cambia o sube por primera vez la foto identificatoria del vehículo.
  ///
  /// El admin elige fuente (cámara o galería/archivo) con el mismo sheet
  /// que usamos para los comprobantes. Guardamos en Storage como
  /// `vehiculos/{patente}/foto.jpg` y actualizamos el campo
  /// `ARCHIVO_FOTO` en Firestore. La card de la lista se refresca solo
  /// porque escucha el doc en stream.
  Future<void> _cambiarFotoVehiculo() async {
    final messenger = ScaffoldMessenger.of(context);
    final source = await _elegirFuenteArchivo();
    if (source == null) return;

    Uint8List? bytes;
    String fileName = 'foto.jpg';

    if (source == _FuenteArchivo.camera) {
      final photo = await ImagePicker()
          .pickImage(source: ImageSource.camera, imageQuality: 60);
      if (photo != null) {
        bytes = await photo.readAsBytes();
      }
    } else {
      // Solo permitimos imágenes para foto de unidad — un PDF acá no
      // tiene sentido y rompería el preview circular en la card.
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png'],
        withData: true,
      );
      final picked = result?.files.singleOrNull;
      if (picked != null && picked.bytes != null) {
        bytes = picked.bytes;
        fileName = picked.name;
      }
    }

    if (bytes == null) return;
    if (!mounted) return;

    setState(() => _subiendoFoto = true);
    try {
      final path = 'vehiculos/${widget.vehiculoId.trim()}/foto.jpg';
      final url = await StorageService().subirArchivo(
        bytes: bytes,
        nombreOriginal: fileName,
        rutaStorage: path,
      );
      await FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .doc(widget.vehiculoId.trim())
          .update({'ARCHIVO_FOTO': url});

      if (!mounted) return;
      setState(() => _urlFoto = url);
      AppFeedback.successOn(messenger, 'Foto de la unidad actualizada');
    } catch (e) {
      if (mounted) {
        AppFeedback.errorOn(messenger, 'No se pudo subir la foto: $e');
      }
    } finally {
      if (mounted) setState(() => _subiendoFoto = false);
    }
  }

  Future<void> _subirDocumento(VencimientoSpec spec) async {
    final messenger = ScaffoldMessenger.of(context);
    final source = await _elegirFuenteArchivo();
    if (source == null) return;

    Uint8List? bytes;
    String fileName = '';

    if (source == _FuenteArchivo.camera) {
      final photo = await ImagePicker()
          .pickImage(source: ImageSource.camera, imageQuality: 50);
      if (photo != null) {
        // readAsBytes(): cross-platform (Web devuelve blob bytes).
        bytes = await photo.readAsBytes();
        // Nombre de archivo: usamos el campoArchivo (sin prefijo ARCHIVO_)
        // como tag para que sea fácil identificar el archivo en Storage.
        final tag = spec.campoArchivo.replaceFirst('ARCHIVO_', '');
        fileName = '${tag}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      }
    } else {
      // withData: true asegura que `bytes` venga poblado en Web también.
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        withData: true,
      );
      final picked = result?.files.singleOrNull;
      if (picked != null && picked.bytes != null) {
        bytes = picked.bytes;
        fileName = picked.name;
      }
    }

    if (bytes == null || fileName.isEmpty) return;

    setState(() => _isSaving = true);
    try {
      final path = 'vehiculos/${widget.vehiculoId.trim()}/$fileName';

      final downloadUrl = await StorageService().subirArchivo(
        bytes: bytes,
        nombreOriginal: fileName,
        rutaStorage: path,
      );

      if (!mounted) return;
      setState(() {
        _urls[spec.campoArchivo] = downloadUrl;
      });

      AppFeedback.infoOn(messenger, '${spec.etiqueta} cargado.');
    } catch (e) {
      if (mounted) {
        AppFeedback.errorOn(messenger, 'Error al subir: $e');
      }
    } finally {
      // Siempre reseteamos _isSaving — incluso si la subida falló o el
      // widget se desmontó (el chequeo de mounted protege el setState).
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<_FuenteArchivo?> _elegirFuenteArchivo() {
    return showModalBottomSheet<_FuenteArchivo>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
          border: const Border(
              top: BorderSide(color: AppColors.accentGreen, width: 2)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(15),
                child: Text(
                  'Adjuntar documento',
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
                title: const Text('Tomar foto',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(ctx, _FuenteArchivo.camera),
              ),
              ListTile(
                leading:
                    const Icon(Icons.file_present, color: AppColors.accentBlue),
                title: const Text('Seleccionar archivo (PDF/imagen)',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(ctx, _FuenteArchivo.fileSystem),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  void _abrirDiagnostico() {
    final vin = _vinCtrl.text.trim().toUpperCase();
    if (vin.length < 10) {
      AppFeedback.warning(context, 'Necesito un VIN válido para diagnosticar.');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DiagnosticoVolvoScreen(
          patente: widget.vehiculoId,
          vin: vin,
        ),
      ),
    );
  }

  Future<void> _sincronizarConVolvo() async {
    final messenger = ScaffoldMessenger.of(context);

    if (_vinCtrl.text.length < 10) {
      AppFeedback.warningOn(messenger, 'Se requiere un VIN válido (mínimo 10 caracteres)');
      return;
    }

    setState(() => _isSyncing = true);

    try {
      final metros = await VolvoApiService()
          .traerKilometrajeCualquierVia(_vinCtrl.text.trim().toUpperCase());

      if (!mounted) return;

      if (metros != null && metros > 0) {
        setState(() => _kmCtrl.text = (metros / 1000).toStringAsFixed(0));
        AppFeedback.successOn(messenger, '¡Sincronizado! KM actualizado.');
      } else {
        AppFeedback.warningOn(messenger, 'Unidad en reposo o no encontrada en Volvo.');
      }
    } catch (e) {
      debugPrint('Error sincro: $e');
      if (mounted) {
        AppFeedback.errorOn(messenger, 'Error de conexión con Volvo: $e');
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _seleccionarFecha(VencimientoSpec spec) async {
    final fechaActual = _fechas[spec.campoFecha];
    final initial = (fechaActual != null && fechaActual.isNotEmpty)
        ? AppFormatters.tryParseFecha(fechaActual)
        : null;

    final picked = await pickFecha(
      context,
      initial: initial,
      titulo: 'Vencimiento ${spec.etiqueta}',
    );

    if (picked != null && mounted) {
      setState(() {
        _fechas[spec.campoFecha] = AppFormatters.aIsoFechaLocal(picked);
      });
    }
  }

  void _seleccionarEmpresa() {
    const empresas = [
      'VECCHI ARIEL Y VECCHI GRACIELA S.R.L: (30-70910015-3)',
      'SUCESION DE VECCHI CARLOS LUIS: (20-08569424-4)',
    ];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Seleccionar empresa'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: empresas
              .map((e) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      e,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13),
                    ),
                    onTap: () {
                      setState(() => _empresaCtrl.text = e);
                      Navigator.pop(ctx);
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isSaving) return;

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Validaciones defensivas del form de EDIT (auditoria 2026-05-17):
    // el alta tiene validators robustos, el edit no — antes aceptaba
    // ANIO=0, ANIO=20025, KM negativo, KM=0, VIN de 5 chars, etc.
    final anioNuevo = int.tryParse(_anioCtrl.text.trim()) ?? 0;
    final anioActual = DateTime.now().year;
    if (anioNuevo < 1990 || anioNuevo > anioActual + 1) {
      AppFeedback.errorOn(messenger,
          'Año inválido: debe estar entre 1990 y ${anioActual + 1}.');
      return;
    }

    final kmNuevo = double.tryParse(_kmCtrl.text) ?? -1;
    if (kmNuevo < 0 || kmNuevo > 5000000) {
      AppFeedback.errorOn(messenger,
          'KM inválido: debe ser entre 0 y 5.000.000.');
      return;
    }
    // Aviso si el km nuevo es MENOR que el km guardado actualmente:
    // probable typo del operador. Pedir confirmacion antes de regresar
    // el odometro (rompe calculos de gomeria + alertas mantenimiento).
    if (_kmActualDb != null && kmNuevo < _kmActualDb! - 100) {
      final confirmado = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reducir kilometraje'),
          content: Text(
            'Estás bajando el odómetro de '
            '${_kmActualDb!.toInt()} a ${kmNuevo.toInt()} km. '
            '¿Es correcto? (esto rompe cálculos históricos)',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sí, reducir'),
            ),
          ],
        ),
      );
      if (confirmado != true) return;
    }

    final vinNuevo = _vinCtrl.text.trim().toUpperCase();
    if (vinNuevo.isNotEmpty && vinNuevo.length != 17) {
      AppFeedback.errorOn(messenger,
          'VIN inválido: debe tener exactamente 17 caracteres '
          '(o estar vacío). Recibí ${vinNuevo.length}.');
      return;
    }

    setState(() => _isSaving = true);

    bool guardadoOk = false;
    try {
      final id = widget.vehiculoId.trim().toUpperCase();
      final updates = <String, dynamic>{
        'MARCA': _marcaCtrl.text.trim().toUpperCase(),
        'MODELO': _modeloCtrl.text.trim().toUpperCase(),
        'ANIO': anioNuevo,
        'EMPRESA': _empresaCtrl.text.trim().toUpperCase(),
        'VIN': vinNuevo,
        'KM_ACTUAL': kmNuevo,
        'fecha_ultima_actualizacion': FieldValue.serverTimestamp(),
      };
      // Mantenimiento preventivo: campos manuales que el admin carga
      // cuando el taller termina el service. Si el campo está vacío,
      // guardamos null para limpiar el doc (no string vacío, así la
      // pantalla de mantenimiento puede distinguir "nunca cargado"
      // de "cargado en blanco").
      final ultimoServiceKmRaw = _ultimoServiceKmCtrl.text.trim();
      updates['ULTIMO_SERVICE_KM'] = ultimoServiceKmRaw.isEmpty
          ? null
          : double.tryParse(ultimoServiceKmRaw);
      updates['ULTIMO_SERVICE_FECHA'] = _ultimoServiceFecha;
      // Persistimos cada vencimiento iterando la lista — sumar uno
      // nuevo a AppVencimientos lo guarda automáticamente.
      for (final spec in _vencimientos) {
        updates[spec.campoFecha] = _fechas[spec.campoFecha] ?? '';
        updates[spec.campoArchivo] = _urls[spec.campoArchivo] ?? '-';
      }
      await FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .doc(id)
          .update(updates);
      guardadoOk = true;

      if (!mounted) return;
      AppFeedback.successOn(messenger, 'Ficha actualizada con éxito');
      navigator.pop();
    } catch (e) {
      if (mounted) {
        AppFeedback.errorOn(messenger, 'Error al guardar: $e');
      }
    } finally {
      // Solo reseteamos el flag si NO hicimos pop (si se hizo pop, la
      // pantalla se va a desmontar y no necesitamos tocar nada). Esto
      // garantiza que el botón vuelva a habilitarse si la operación falló.
      if (!guardadoOk && mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final esVolvo =
        _marcaCtrl.text.toUpperCase().contains('VOLVO');
    // El bloque de mantenimiento preventivo solo aplica a tractores —
    // los enganches no tienen ciclo de service por kilometraje.
    final esTractor =
        (widget.datosIniciales['TIPO']?.toString().toUpperCase() ?? '') ==
            'TRACTOR';

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: AppScaffold(
        title: 'Ficha: ${widget.vehiculoId}',
        actions: [
          if (esTractor)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Historial de asignaciones',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AsignacionHistorialVehiculoScreen(
                      patente: widget.vehiculoId,
                    ),
                  ),
                );
              },
            ),
        ],
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Identificación visual: foto circular grande + botón
              // "Cambiar foto". Para que el admin reconozca la unidad
              // en la lista por la foto antes que por la patente.
              _FotoUnidad(
                url: _urlFoto,
                subiendo: _subiendoFoto,
                onTap: _cambiarFotoVehiculo,
              ),
              const SizedBox(height: 24),
              const _SectionTitle('Información técnica'),
              _FInput(
                controller: _marcaCtrl,
                label: 'Marca del fabricante',
                icon: Icons.branding_watermark,
              ),
              _FInput(
                controller: _modeloCtrl,
                label: 'Modelo de la unidad',
                icon: Icons.directions_car,
              ),
              _FInput(
                controller: _anioCtrl,
                label: 'Año de fabricación',
                icon: Icons.calendar_today,
                isNumber: true,
              ),
              if (esVolvo) ...[
                const SizedBox(height: 8),
                _BloqueVolvo(
                  vinController: _vinCtrl,
                  isSyncing: _isSyncing,
                  onSync: _sincronizarConVolvo,
                  onDiagnostico: _abrirDiagnostico,
                ),
                const SizedBox(height: 16),
              ],
              _FInput(
                controller: _kmCtrl,
                label: 'Kilometraje actual',
                icon: Icons.speed,
                isNumber: true,
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 8),
              _EmpresaTile(
                empresa: _empresaCtrl.text,
                onTap: _seleccionarEmpresa,
              ),
              if (esTractor) ...[
                const SizedBox(height: 28),
                const _SectionTitle('Mantenimiento preventivo'),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    'Cargá los datos del último service realizado en el taller. '
                    'La distancia al próximo service la calcula Volvo automáticamente.',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
                const SizedBox(height: 8),
                _FInput(
                  controller: _ultimoServiceKmCtrl,
                  label: 'KM al hacer el último service',
                  icon: Icons.build,
                  isNumber: true,
                ),
                const SizedBox(height: 8),
                _FechaTileSimple(
                  label: 'Fecha del último service',
                  fecha: _ultimoServiceFecha,
                  icono: Icons.event_available,
                  onTap: _seleccionarFechaUltimoService,
                ),
              ],
              const SizedBox(height: 28),
              const _SectionTitle('Auditoría de vencimientos'),
              // Tiles generados desde la lista de specs: sumar un
              // VencimientoSpec a AppVencimientos.tractor / .enganche y
              // automáticamente aparece acá.
              for (int i = 0; i < _vencimientos.length; i++) ...[
                _DateTile(
                  label: 'Vencimiento ${_vencimientos[i].etiqueta}',
                  fecha: _fechas[_vencimientos[i].campoFecha],
                  url: _urls[_vencimientos[i].campoArchivo],
                  onTapDate: () => _seleccionarFecha(_vencimientos[i]),
                  onTapFile: () => _subirDocumento(_vencimientos[i]),
                  tituloVisor:
                      '${_vencimientos[i].etiqueta} ${widget.vehiculoId}',
                ),
                if (i < _vencimientos.length - 1)
                  const Divider(color: Colors.white10, height: 1),
              ],
              const SizedBox(height: 32),
              _BotonGuardar(
                guardando: _isSaving,
                onPressed: _guardar,
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

enum _FuenteArchivo { camera, fileSystem }

