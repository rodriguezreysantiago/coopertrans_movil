import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/tarifa_logistica.dart';
import '../models/viaje.dart';
import '../services/logistica_service.dart';
import '../services/viajes_service.dart';
import '../utils/calculos_viaje.dart';

/// Form full-screen para alta y edición de viajes. 8 secciones
/// agrupadas vertical-arriba-abajo, validación en línea, recompute
/// de montos en vivo al cambiar inputs.
///
/// Si recibe `arguments={'viajeId': '...'}` carga el viaje para
/// editar; si no, es alta. El estado por default al crear es
/// PLANEADO (decisión Santiago 2026-05-09 — el viaje todavía no
/// arrancó y puede no realizarse).
class LogisticaViajeFormScreen extends StatefulWidget {
  /// Si null, modo "alta". Si trae id, carga el viaje para editar.
  final String? viajeId;

  const LogisticaViajeFormScreen({super.key, this.viajeId});

  @override
  State<LogisticaViajeFormScreen> createState() =>
      _LogisticaViajeFormScreenState();
}

class _LogisticaViajeFormScreenState extends State<LogisticaViajeFormScreen> {
  // ─── Estado del form ───
  TarifaLogistica? _tarifa;
  String? _choferDni;
  String? _choferNombre;
  final _vehiculoCtrl = TextEditingController();
  final _engancheCtrl = TextEditingController();
  final _cargaTransportadaCtrl = TextEditingController();

  DateTime? _fechaCarga;
  final _kgCargadosCtrl = TextEditingController();

  DateTime? _fechaDescarga;
  final _remitoNumeroCtrl = TextEditingController();
  String? _remitoUrl;
  String? _remitoPathStorage;
  String? _remitoNombreLocal; // para mostrar el nombre del archivo recién pickeado
  Uint8List? _remitoBytesPendientes;
  String? _remitoExtPendiente;
  String? _remitoMimePendiente;
  final _kgDescargadosCtrl = TextEditingController();

  final _adelantoMontoCtrl = TextEditingController();
  DateTime? _adelantoFecha;
  final _adelantoObsCtrl = TextEditingController();

  List<GastoViaje> _gastos = [];

  EstadoViaje _estado = EstadoViaje.planeado;
  final _motivoCancelacionCtrl = TextEditingController();
  DateTime? _fechaPostergadoA;

  // ─── Lifecycle ───
  bool _cargando = true;
  bool _guardando = false;
  String? _errorCarga;

  bool get _esEdicion => widget.viajeId != null;

  @override
  void initState() {
    super.initState();
    _cargarSiEdicion();
  }

  @override
  void dispose() {
    _vehiculoCtrl.dispose();
    _engancheCtrl.dispose();
    _cargaTransportadaCtrl.dispose();
    _kgCargadosCtrl.dispose();
    _remitoNumeroCtrl.dispose();
    _kgDescargadosCtrl.dispose();
    _adelantoMontoCtrl.dispose();
    _adelantoObsCtrl.dispose();
    _motivoCancelacionCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarSiEdicion() async {
    if (!_esEdicion) {
      setState(() => _cargando = false);
      return;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection(AppCollections.viajesLogistica)
          .doc(widget.viajeId!)
          .get();
      if (!snap.exists) {
        setState(() {
          _cargando = false;
          _errorCarga = 'El viaje no existe.';
        });
        return;
      }
      final v = Viaje.fromMap(snap.id, snap.data()!);

      // Cargar la tarifa referenciada para tener todos sus datos.
      final tSnap = await LogisticaService.tarifasCol.doc(v.tarifaId).get();
      if (tSnap.exists) {
        _tarifa = TarifaLogistica.fromMap(tSnap.id, tSnap.data()!);
      }

      _choferDni = v.choferDni;
      _choferNombre = v.choferNombre;
      _vehiculoCtrl.text = v.vehiculoId ?? '';
      _engancheCtrl.text = v.engancheId ?? '';
      _cargaTransportadaCtrl.text = v.cargaTransportada ?? '';
      _fechaCarga = v.fechaCarga;
      if (v.kgCargados != null) {
        _kgCargadosCtrl.text =
            AppFormatters.formatearMiles(v.kgCargados!.toInt());
      }
      _fechaDescarga = v.fechaDescarga;
      _remitoNumeroCtrl.text = v.remitoNumero ?? '';
      _remitoUrl = v.remitoUrl;
      _remitoPathStorage = v.remitoPathStorage;
      if (v.kgDescargados != null) {
        _kgDescargadosCtrl.text =
            AppFormatters.formatearMiles(v.kgDescargados!.toInt());
      }
      if (v.adelantoMonto != null) {
        _adelantoMontoCtrl.text =
            AppFormatters.formatearMiles(v.adelantoMonto!.toInt());
      }
      _adelantoFecha = v.adelantoFecha;
      _adelantoObsCtrl.text = v.adelantoObservacion ?? '';
      _gastos = List.of(v.gastos);
      _estado = v.estado;
      _motivoCancelacionCtrl.text = v.motivoCancelacion ?? '';
      _fechaPostergadoA = v.fechaPostergadoA;

      setState(() => _cargando = false);
    } catch (e) {
      setState(() {
        _cargando = false;
        _errorCarga = 'Error cargando viaje: $e';
      });
    }
  }

  // ─── Cálculos en vivo ───
  MontosViaje? get _montosCalc {
    if (_tarifa == null) return null;
    final kgC = AppFormatters.parsearMiles(_kgCargadosCtrl.text);
    final kgD = AppFormatters.parsearMiles(_kgDescargadosCtrl.text);
    final ade = AppFormatters.parsearMiles(_adelantoMontoCtrl.text) ?? 0;
    return CalculosViaje.calcularTodo(
      unidadTarifa: _tarifa!.unidadTarifa,
      tarifaReal: _tarifa!.tarifaReal,
      tarifaChofer: _tarifa!.tarifaChofer,
      kgCargados: kgC?.toDouble(),
      kgDescargados: kgD?.toDouble(),
      adelanto: ade.toDouble(),
      gastos: _gastos,
    );
  }

  // ─── Guardar ───
  Future<void> _guardar() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_tarifa == null) {
      AppFeedback.warningOn(messenger, 'Seleccioná una tarifa.');
      return;
    }
    if (_choferDni == null || _choferDni!.isEmpty) {
      AppFeedback.warningOn(messenger, 'Asigná un chofer.');
      return;
    }

    setState(() => _guardando = true);
    try {
      final dniActual = PrefsService.dni;
      final kgC = AppFormatters.parsearMiles(_kgCargadosCtrl.text)?.toDouble();
      final kgD =
          AppFormatters.parsearMiles(_kgDescargadosCtrl.text)?.toDouble();
      final ade = AppFormatters.parsearMiles(_adelantoMontoCtrl.text)?.toDouble();

      // Subir comprobante si quedó pendiente (recién pickeado).
      String? remitoUrlFinal = _remitoUrl;
      String? remitoPathFinal = _remitoPathStorage;
      if (_remitoBytesPendientes != null && _remitoExtPendiente != null) {
        // Si era alta, todavía no tenemos viajeId — hacemos un upload
        // con un id temporal que después renombramos. Más simple:
        // creamos primero el viaje sin remito, después subimos y
        // updateamos. Así el path lleva el id real.
      }

      String viajeId;
      if (_esEdicion) {
        await ViajesService.actualizarViaje(
          viajeId: widget.viajeId!,
          tarifa: _tarifa!,
          choferDni: _choferDni!,
          choferNombre: _choferNombre,
          vehiculoId: _vehiculoCtrl.text.trim().isEmpty
              ? null
              : _vehiculoCtrl.text.trim().toUpperCase(),
          engancheId: _engancheCtrl.text.trim().isEmpty
              ? null
              : _engancheCtrl.text.trim().toUpperCase(),
          cargaTransportada: _cargaTransportadaCtrl.text.trim().isEmpty
              ? null
              : _cargaTransportadaCtrl.text.trim(),
          fechaCarga: _fechaCarga,
          kgCargados: kgC,
          fechaDescarga: _fechaDescarga,
          kgDescargados: kgD,
          remitoNumero: _remitoNumeroCtrl.text.trim().isEmpty
              ? null
              : _remitoNumeroCtrl.text.trim(),
          remitoUrl: remitoUrlFinal,
          remitoPathStorage: remitoPathFinal,
          adelantoMonto: ade,
          adelantoFecha: _adelantoFecha,
          adelantoObservacion: _adelantoObsCtrl.text.trim().isEmpty
              ? null
              : _adelantoObsCtrl.text.trim(),
          gastos: _gastos,
          estado: _estado,
          motivoCancelacion: _motivoCancelacionCtrl.text.trim().isEmpty
              ? null
              : _motivoCancelacionCtrl.text.trim(),
          fechaPostergadoA: _fechaPostergadoA,
          actualizadoPorDni: dniActual,
        );
        viajeId = widget.viajeId!;
      } else {
        viajeId = await ViajesService.crearViaje(
          tarifa: _tarifa!,
          choferDni: _choferDni!,
          choferNombre: _choferNombre,
          vehiculoId: _vehiculoCtrl.text.trim().isEmpty
              ? null
              : _vehiculoCtrl.text.trim().toUpperCase(),
          engancheId: _engancheCtrl.text.trim().isEmpty
              ? null
              : _engancheCtrl.text.trim().toUpperCase(),
          cargaTransportada: _cargaTransportadaCtrl.text.trim().isEmpty
              ? null
              : _cargaTransportadaCtrl.text.trim(),
          fechaCarga: _fechaCarga,
          kgCargados: kgC,
          fechaDescarga: _fechaDescarga,
          kgDescargados: kgD,
          remitoNumero: _remitoNumeroCtrl.text.trim().isEmpty
              ? null
              : _remitoNumeroCtrl.text.trim(),
          adelantoMonto: ade,
          adelantoFecha: _adelantoFecha,
          adelantoObservacion: _adelantoObsCtrl.text.trim().isEmpty
              ? null
              : _adelantoObsCtrl.text.trim(),
          gastos: _gastos,
          estado: _estado,
          motivoCancelacion: _motivoCancelacionCtrl.text.trim().isEmpty
              ? null
              : _motivoCancelacionCtrl.text.trim(),
          fechaPostergadoA: _fechaPostergadoA,
          creadoPorDni: dniActual,
        );
      }

      // Subir comprobante si lo hay (después de tener el viajeId real).
      if (_remitoBytesPendientes != null && _remitoExtPendiente != null) {
        final res = await ViajesService.subirRemito(
          viajeId: viajeId,
          bytes: _remitoBytesPendientes!,
          extension: _remitoExtPendiente!,
          contentType: _remitoMimePendiente,
        );
        // Actualizar el doc con la url + path (update separado).
        await FirebaseFirestore.instance
            .collection(AppCollections.viajesLogistica)
            .doc(viajeId)
            .update({
          'remito_url': res.url,
          'remito_path_storage': res.path,
        });
      }

      if (!mounted) return;
      AppFeedback.successOn(messenger,
          _esEdicion ? 'Viaje actualizado.' : 'Viaje creado.');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        AppFeedback.errorOn(messenger, 'Error al guardar: $e');
      }
    }
  }

  Future<void> _pickRemito() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    if (f.bytes == null) return;
    final ext = (f.extension ?? 'pdf').toLowerCase();
    final mime = ext == 'pdf' ? 'application/pdf' : 'image/$ext';
    setState(() {
      _remitoBytesPendientes = f.bytes;
      _remitoExtPendiente = ext;
      _remitoMimePendiente = mime;
      _remitoNombreLocal = f.name;
    });
  }

  // ─── Build ───
  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const AppScaffold(
        title: 'Viaje',
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_errorCarga != null) {
      return AppScaffold(
        title: 'Viaje',
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _errorCarga!,
              style: const TextStyle(color: AppColors.accentRed),
            ),
          ),
        ),
      );
    }

    return AppScaffold(
      title: _esEdicion ? 'Editar viaje' : 'Nuevo viaje',
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SeccionTarifa(
              tarifa: _tarifa,
              onChanged: (t) => setState(() => _tarifa = t),
            ),
            const SizedBox(height: 12),
            _SeccionChofer(
              dni: _choferDni,
              nombre: _choferNombre,
              onChanged: (dni, nombre, vehiculo, enganche) => setState(() {
                _choferDni = dni;
                _choferNombre = nombre;
                // Auto-llenar las patentes con las que tiene asignadas
                // el chofer en EMPLEADOS/{dni}.VEHICULO/.ENGANCHE.
                // Caso típico: el viaje sale con la unidad habitual del
                // chofer. Si va con otra, el operador la cambia desde
                // los selectores de la sección 3 (que filtran solo
                // patentes activas). Pisamos los TextField cualquiera
                // sea el contenido previo: cambiar de chofer casi
                // siempre implica cambio de unidad.
                _vehiculoCtrl.text = vehiculo ?? '';
                _engancheCtrl.text = enganche ?? '';
              }),
            ),
            const SizedBox(height: 12),
            _SeccionUnidad(
              vehiculoCtrl: _vehiculoCtrl,
              engancheCtrl: _engancheCtrl,
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 12),
            _SeccionCarga(
              fecha: _fechaCarga,
              kgCargadosCtrl: _kgCargadosCtrl,
              cargaTransportadaCtrl: _cargaTransportadaCtrl,
              tarifa: _tarifa,
              onFechaChanged: (d) => setState(() => _fechaCarga = d),
              onKgChanged: () => setState(() {}),
            ),
            const SizedBox(height: 12),
            _SeccionDescarga(
              fecha: _fechaDescarga,
              remitoNumeroCtrl: _remitoNumeroCtrl,
              kgDescargadosCtrl: _kgDescargadosCtrl,
              tarifa: _tarifa,
              remitoUrl: _remitoUrl,
              remitoNombreLocal: _remitoNombreLocal,
              onFechaChanged: (d) => setState(() => _fechaDescarga = d),
              onKgChanged: () => setState(() {}),
              onPickRemito: _pickRemito,
            ),
            const SizedBox(height: 12),
            _SeccionAdelanto(
              montoCtrl: _adelantoMontoCtrl,
              fecha: _adelantoFecha,
              obsCtrl: _adelantoObsCtrl,
              onMontoChanged: () => setState(() {}),
              onFechaChanged: (d) => setState(() => _adelantoFecha = d),
            ),
            const SizedBox(height: 12),
            _SeccionGastos(
              gastos: _gastos,
              onChanged: (l) => setState(() => _gastos = l),
            ),
            const SizedBox(height: 12),
            _SeccionEstado(
              estado: _estado,
              motivoCtrl: _motivoCancelacionCtrl,
              fechaPostergadoA: _fechaPostergadoA,
              onEstadoChanged: (e) => setState(() => _estado = e),
              onFechaChanged: (d) => setState(() => _fechaPostergadoA = d),
            ),
            const SizedBox(height: 12),
            _SeccionResumen(montos: _montosCalc),
            const SizedBox(height: 24),
            _BotonesGuardar(
              guardando: _guardando,
              onGuardar: _guardar,
              onCancelar: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SECCIONES (cada una un AppCard con título)
// =============================================================================

class _SeccionTarifa extends StatelessWidget {
  final TarifaLogistica? tarifa;
  final ValueChanged<TarifaLogistica?> onChanged;
  const _SeccionTarifa({required this.tarifa, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return _SeccionCard(
      titulo: '1. TARIFA',
      icono: Icons.price_change_outlined,
      children: [
        StreamBuilder<List<TarifaLogistica>>(
          stream: LogisticaService.streamTarifas(soloActivas: true),
          builder: (ctx, snap) {
            final lista = snap.data ?? const <TarifaLogistica>[];
            return DropdownButtonFormField<String>(
              initialValue: tarifa?.id,
              decoration: const InputDecoration(
                labelText: 'Seleccioná una tarifa activa',
                border: OutlineInputBorder(),
              ),
              isExpanded: true,
              items: lista
                  .map(
                    (t) => DropdownMenuItem(
                      value: t.id,
                      child: Text(
                        '${t.ubicacionOrigenEtiqueta} → ${t.ubicacionDestinoEtiqueta} '
                        '(${t.unidadTarifa.etiqueta})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (id) {
                final t = lista.firstWhere(
                  (x) => x.id == id,
                  orElse: () => lista.first,
                );
                onChanged(t);
              },
            );
          },
        ),
        if (tarifa != null) ...[
          const SizedBox(height: 8),
          _ResumenTarifa(t: tarifa!),
        ],
      ],
    );
  }
}

class _ResumenTarifa extends StatelessWidget {
  final TarifaLogistica t;
  const _ResumenTarifa({required this.t});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.accentGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.accentGreen.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${t.empresaOrigenNombre} → ${t.empresaDestinoNombre}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            'Vecchi: \$${AppFormatters.formatearMonto(t.tarifaReal)}'
            '${t.unidadTarifa.sufijoMonto}  ·  '
            'Chofer: \$${AppFormatters.formatearMonto(t.tarifaChofer)}'
            '${t.unidadTarifa.sufijoMonto}',
            style: const TextStyle(
              color: AppColors.accentGreen,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _SeccionChofer extends StatelessWidget {
  final String? dni;
  final String? nombre;

  /// Callback al cambiar la selección de chofer. Pasa DNI + nombre del
  /// empleado + las patentes (vehículo + enganche) que tiene asignadas
  /// en su legajo `EMPLEADOS/{dni}`. Las patentes se usan para
  /// auto-llenar la sección "3. UNIDAD" — el operador puede después
  /// cambiarlas si el viaje va con otra unidad. Decisión Vecchi
  /// 2026-05-11: el caso típico es que el chofer va con su unidad
  /// asignada; el override es excepcional pero tiene que estar
  /// disponible.
  final void Function(
    String dni,
    String? nombre,
    String? vehiculoAsignado,
    String? engancheAsignado,
  ) onChanged;
  const _SeccionChofer({
    required this.dni,
    required this.nombre,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _SeccionCard(
      titulo: '2. CHOFER',
      icono: Icons.person_outline,
      children: [
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection(AppCollections.empleados)
              .where('ROL', isEqualTo: 'CHOFER')
              .snapshots(),
          builder: (ctx, snap) {
            final docs = snap.data?.docs ?? const [];
            // Filtrar activos en cliente para no requerir índice.
            final activos = docs
                .where((d) => d.data()['ACTIVO'] != false)
                .toList()
              ..sort((a, b) => (a.data()['NOMBRE'] ?? '')
                  .toString()
                  .compareTo((b.data()['NOMBRE'] ?? '').toString()));
            return DropdownButtonFormField<String>(
              initialValue: dni,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Chofer',
                border: OutlineInputBorder(),
              ),
              items: activos
                  .map(
                    (d) => DropdownMenuItem(
                      value: d.id,
                      child: Text(
                        '${d.data()['NOMBRE'] ?? d.id} (DNI ${d.id})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (sel) {
                if (sel == null) return;
                final doc = activos.firstWhere((d) => d.id == sel);
                final data = doc.data();
                final vehiculo =
                    (data['VEHICULO'] ?? '').toString().trim().toUpperCase();
                final enganche =
                    (data['ENGANCHE'] ?? '').toString().trim().toUpperCase();
                onChanged(
                  doc.id,
                  data['NOMBRE']?.toString(),
                  vehiculo.isEmpty ? null : vehiculo,
                  enganche.isEmpty ? null : enganche,
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class _SeccionUnidad extends StatelessWidget {
  final TextEditingController vehiculoCtrl;
  final TextEditingController engancheCtrl;
  final VoidCallback onChanged;
  const _SeccionUnidad({
    required this.vehiculoCtrl,
    required this.engancheCtrl,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _SeccionCard(
      titulo: '3. UNIDAD (opcional)',
      icono: Icons.local_shipping_outlined,
      children: [
        // Auto-fill al seleccionar chofer + dropdown con autocomplete
        // para cambiarla. La idea: el caso típico es viajar con la
        // unidad asignada del chofer (que ya viene pre-llenada desde
        // _SeccionChofer.onChanged). Para los casos excepcionales
        // donde se manda con OTRA unidad, el operador escribe las
        // primeras letras de la patente y el autocomplete sugiere
        // solo unidades activas del tipo correspondiente. Antes era
        // TextField libre — fácil tipear patentes que no existen o
        // están dadas de baja, sin guidance.
        _PatenteSelector(
          controller: vehiculoCtrl,
          label: 'Patente tractor (ej: ABC123)',
          tipoFiltro: _TipoPatente.tractor,
          onChanged: onChanged,
        ),
        const SizedBox(height: 8),
        _PatenteSelector(
          controller: engancheCtrl,
          label: 'Patente enganche (opcional)',
          tipoFiltro: _TipoPatente.enganche,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

enum _TipoPatente { tractor, enganche }

/// Autocomplete de patentes que filtra solo unidades activas del tipo
/// correspondiente (tractor o enganche). Si el operador tipea algo que
/// NO está en la lista, igual lo acepta (caso raro: unidad recién
/// cargada en otro proceso, patente de unidad ajena, etc.) — el
/// autocomplete es asistencia, no validación bloqueante.
class _PatenteSelector extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final _TipoPatente tipoFiltro;
  final VoidCallback onChanged;

  const _PatenteSelector({
    required this.controller,
    required this.label,
    required this.tipoFiltro,
    required this.onChanged,
  });

  @override
  State<_PatenteSelector> createState() => _PatenteSelectorState();
}

class _PatenteSelectorState extends State<_PatenteSelector> {
  /// Cache local de patentes activas del tipo correspondiente. Se
  /// rellena via StreamBuilder y se usa como fuente del Autocomplete.
  /// Mantener esto separado del builder permite que el Autocomplete
  /// no se reconstruya en cada keystroke (lo cual lo hace lento).
  List<String> _patentesDisponibles = const [];

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .snapshots(),
      builder: (ctx, snap) {
        final docs = snap.data?.docs ?? const [];
        // Filtros en cliente (defensivo + evita índices compuestos):
        //   1. ACTIVO != false (soft-delete)
        //   2. TIPO según selector (tractor solo, o cualquier enganche)
        final filtrados = docs.where((d) {
          final data = d.data();
          if (data['ACTIVO'] == false) return false;
          final tipo = (data['TIPO'] ?? '').toString().toUpperCase();
          if (widget.tipoFiltro == _TipoPatente.tractor) {
            return tipo == AppTiposVehiculo.tractor;
          }
          return AppTiposVehiculo.enganches.contains(tipo);
        }).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
        _patentesDisponibles = filtrados.map((d) => d.id).toList();

        return Autocomplete<String>(
          // Evita el wrapper Material default; usamos nuestro TextField.
          fieldViewBuilder: (context, fieldCtrl, fieldFocus, onSubmit) {
            // Sincronizar el controller del padre con el del Autocomplete:
            // si el padre cambia el text (auto-fill por chofer), reflejarlo.
            if (fieldCtrl.text != widget.controller.text) {
              fieldCtrl.text = widget.controller.text;
              fieldCtrl.selection = TextSelection.collapsed(
                offset: fieldCtrl.text.length,
              );
            }
            return TextField(
              controller: fieldCtrl,
              focusNode: fieldFocus,
              decoration: InputDecoration(
                labelText: widget.label,
                border: const OutlineInputBorder(),
                suffixIcon: const Icon(Icons.arrow_drop_down),
              ),
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                LengthLimitingTextInputFormatter(8),
              ],
              onChanged: (val) {
                widget.controller.text = val.toUpperCase();
                widget.onChanged();
              },
            );
          },
          optionsBuilder: (textEditingValue) {
            final query = textEditingValue.text.trim().toUpperCase();
            if (query.isEmpty) return _patentesDisponibles;
            return _patentesDisponibles.where(
              (p) => p.toUpperCase().contains(query),
            );
          },
          onSelected: (selected) {
            widget.controller.text = selected;
            widget.onChanged();
          },
          // Display que se ve mientras se tipea: mostrar la patente como
          // "ABC123" sin texto extra, para que la pantalla quede limpia.
          displayStringForOption: (p) => p,
        );
      },
    );
  }
}

class _SeccionCarga extends StatelessWidget {
  final DateTime? fecha;
  final TextEditingController kgCargadosCtrl;
  final TextEditingController cargaTransportadaCtrl;
  final TarifaLogistica? tarifa;
  final ValueChanged<DateTime?> onFechaChanged;
  final VoidCallback onKgChanged;

  const _SeccionCarga({
    required this.fecha,
    required this.kgCargadosCtrl,
    required this.cargaTransportadaCtrl,
    required this.tarifa,
    required this.onFechaChanged,
    required this.onKgChanged,
  });

  @override
  Widget build(BuildContext context) {
    final esTn = tarifa?.unidadTarifa == UnidadTarifa.porTonelada;
    return _SeccionCard(
      titulo: '4. CARGA',
      icono: Icons.upload_outlined,
      children: [
        _BotonFecha(
          label: 'Fecha de carga',
          fecha: fecha,
          onChanged: onFechaChanged,
        ),
        const SizedBox(height: 8),
        if (esTn) ...[
          TextField(
            controller: kgCargadosCtrl,
            decoration: const InputDecoration(
              labelText: 'Kg cargados',
              suffixText: 'kg',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [AppFormatters.inputMiles],
            onChanged: (_) => onKgChanged(),
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: cargaTransportadaCtrl,
          decoration: const InputDecoration(
            labelText: 'Descripción de la carga (qué se transporta)',
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
        ),
      ],
    );
  }
}

class _SeccionDescarga extends StatelessWidget {
  final DateTime? fecha;
  final TextEditingController remitoNumeroCtrl;
  final TextEditingController kgDescargadosCtrl;
  final TarifaLogistica? tarifa;
  final String? remitoUrl;
  final String? remitoNombreLocal;
  final ValueChanged<DateTime?> onFechaChanged;
  final VoidCallback onKgChanged;
  final VoidCallback onPickRemito;

  const _SeccionDescarga({
    required this.fecha,
    required this.remitoNumeroCtrl,
    required this.kgDescargadosCtrl,
    required this.tarifa,
    required this.remitoUrl,
    required this.remitoNombreLocal,
    required this.onFechaChanged,
    required this.onKgChanged,
    required this.onPickRemito,
  });

  @override
  Widget build(BuildContext context) {
    final esTn = tarifa?.unidadTarifa == UnidadTarifa.porTonelada;
    return _SeccionCard(
      titulo: '5. DESCARGA',
      icono: Icons.download_outlined,
      children: [
        _BotonFecha(
          label: 'Fecha de descarga',
          fecha: fecha,
          onChanged: onFechaChanged,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: remitoNumeroCtrl,
          decoration: const InputDecoration(
            labelText: 'Número de remito',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onPickRemito,
          icon: const Icon(Icons.attach_file, size: 18),
          label: Text(
            remitoNombreLocal ??
                (remitoUrl != null ? 'Reemplazar comprobante' : 'Subir comprobante firmado (PDF / foto)'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (remitoUrl != null && remitoNombreLocal == null) ...[
          const SizedBox(height: 4),
          const Text(
            '✓ Comprobante ya cargado.',
            style: TextStyle(color: AppColors.accentGreen, fontSize: 11),
          ),
        ],
        if (esTn) ...[
          const SizedBox(height: 8),
          TextField(
            controller: kgDescargadosCtrl,
            decoration: const InputDecoration(
              labelText: 'Kg descargados (cifra final para liquidar)',
              suffixText: 'kg',
              border: OutlineInputBorder(),
              helperText:
                  'Si está vacío, se calcula con kg cargados (estimado).',
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [AppFormatters.inputMiles],
            onChanged: (_) => onKgChanged(),
          ),
        ],
      ],
    );
  }
}

class _SeccionAdelanto extends StatelessWidget {
  final TextEditingController montoCtrl;
  final DateTime? fecha;
  final TextEditingController obsCtrl;
  final VoidCallback onMontoChanged;
  final ValueChanged<DateTime?> onFechaChanged;

  const _SeccionAdelanto({
    required this.montoCtrl,
    required this.fecha,
    required this.obsCtrl,
    required this.onMontoChanged,
    required this.onFechaChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _SeccionCard(
      titulo: '6. ADELANTO AL CHOFER',
      icono: Icons.payments_outlined,
      children: [
        TextField(
          controller: montoCtrl,
          decoration: const InputDecoration(
            labelText: 'Monto del adelanto',
            prefixText: '\$ ',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          inputFormatters: [AppFormatters.inputMiles],
          onChanged: (_) => onMontoChanged(),
        ),
        const SizedBox(height: 8),
        _BotonFecha(
          label: 'Fecha del adelanto',
          fecha: fecha,
          onChanged: onFechaChanged,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: obsCtrl,
          decoration: const InputDecoration(
            labelText: 'Observación (opcional)',
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
        ),
      ],
    );
  }
}

class _SeccionGastos extends StatelessWidget {
  final List<GastoViaje> gastos;
  final ValueChanged<List<GastoViaje>> onChanged;

  const _SeccionGastos({required this.gastos, required this.onChanged});

  Future<void> _agregar(BuildContext ctx) async {
    final res = await showModalBottomSheet<GastoViaje>(
      context: ctx,
      isScrollControlled: true,
      builder: (_) => const _BottomSheetGasto(),
    );
    if (res == null) return;
    onChanged([...gastos, res]);
  }

  void _eliminar(int idx) {
    final l = List.of(gastos);
    l.removeAt(idx);
    onChanged(l);
  }

  @override
  Widget build(BuildContext context) {
    final total = gastos.fold<double>(0, (a, g) => a + g.monto);
    return _SeccionCard(
      titulo: '7. GASTOS EXTRAORDINARIOS',
      icono: Icons.receipt_long_outlined,
      children: [
        if (gastos.isEmpty)
          const Text(
            'Sin gastos cargados.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        for (var i = 0; i < gastos.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                const Icon(Icons.add_circle_outline,
                    size: 14, color: AppColors.accentTeal),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    gastos[i].detalle?.isNotEmpty == true
                        ? '${gastos[i].detalle} (${AppFormatters.formatearFecha(gastos[i].fecha)})'
                        : 'Gasto del ${AppFormatters.formatearFecha(gastos[i].fecha)}',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                Text(
                  '\$ ${AppFormatters.formatearMonto(gastos[i].monto)}',
                  style: const TextStyle(
                    color: AppColors.accentTeal,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => _eliminar(i),
                  tooltip: 'Eliminar',
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => _agregar(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('AGREGAR GASTO'),
            ),
            const Spacer(),
            if (gastos.isNotEmpty)
              Text(
                'Total: \$ ${AppFormatters.formatearMonto(total)}',
                style: const TextStyle(
                  color: AppColors.accentTeal,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _BottomSheetGasto extends StatefulWidget {
  const _BottomSheetGasto();

  @override
  State<_BottomSheetGasto> createState() => _BottomSheetGastoState();
}

class _BottomSheetGastoState extends State<_BottomSheetGasto> {
  final _montoCtrl = TextEditingController();
  final _detalleCtrl = TextEditingController();
  DateTime _fecha = DateTime.now();

  @override
  void dispose() {
    _montoCtrl.dispose();
    _detalleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + viewInsets),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Nuevo gasto',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _montoCtrl,
            decoration: const InputDecoration(
              labelText: 'Monto',
              prefixText: '\$ ',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [AppFormatters.inputMiles],
            autofocus: true,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _detalleCtrl,
            decoration: const InputDecoration(
              labelText: 'Detalle (opcional, ej: peaje, combustible)',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 8),
          _BotonFecha(
            label: 'Fecha',
            fecha: _fecha,
            onChanged: (d) => setState(() => _fecha = d ?? DateTime.now()),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('CANCELAR'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    final monto = AppFormatters.parsearMiles(_montoCtrl.text);
                    if (monto == null || monto <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Ingresá un monto válido.')),
                      );
                      return;
                    }
                    Navigator.pop(
                      context,
                      GastoViaje(
                        monto: monto.toDouble(),
                        detalle: _detalleCtrl.text.trim().isEmpty
                            ? null
                            : _detalleCtrl.text.trim(),
                        fecha: _fecha,
                      ),
                    );
                  },
                  child: const Text('AGREGAR'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SeccionEstado extends StatelessWidget {
  final EstadoViaje estado;
  final TextEditingController motivoCtrl;
  final DateTime? fechaPostergadoA;
  final ValueChanged<EstadoViaje> onEstadoChanged;
  final ValueChanged<DateTime?> onFechaChanged;

  const _SeccionEstado({
    required this.estado,
    required this.motivoCtrl,
    required this.fechaPostergadoA,
    required this.onEstadoChanged,
    required this.onFechaChanged,
  });

  @override
  Widget build(BuildContext context) {
    final esCancelado = estado == EstadoViaje.cancelado;
    final esPostergado = estado == EstadoViaje.postergado;
    return _SeccionCard(
      titulo: '8. ESTADO',
      icono: Icons.flag_outlined,
      children: [
        DropdownButtonFormField<EstadoViaje>(
          initialValue: estado,
          decoration: const InputDecoration(
            labelText: 'Estado del viaje',
            border: OutlineInputBorder(),
          ),
          items: EstadoViaje.values
              .map(
                (e) => DropdownMenuItem(
                  value: e,
                  child: Text(e.etiqueta),
                ),
              )
              .toList(),
          onChanged: (v) {
            if (v != null) onEstadoChanged(v);
          },
        ),
        if (esCancelado || esPostergado) ...[
          const SizedBox(height: 8),
          TextField(
            controller: motivoCtrl,
            decoration: InputDecoration(
              labelText: esCancelado
                  ? 'Motivo de cancelación'
                  : 'Motivo de postergación',
              border: const OutlineInputBorder(),
              helperText: 'Ej: lluvia, problema mecánico, reprogramación cliente.',
            ),
            maxLines: 2,
          ),
        ],
        if (esPostergado) ...[
          const SizedBox(height: 8),
          _BotonFecha(
            label: 'Reprogramado a',
            fecha: fechaPostergadoA,
            onChanged: onFechaChanged,
          ),
        ],
      ],
    );
  }
}

class _SeccionResumen extends StatelessWidget {
  final MontosViaje? montos;
  const _SeccionResumen({required this.montos});

  @override
  Widget build(BuildContext context) {
    final m = montos;
    return _SeccionCard(
      titulo: 'RESUMEN (calculado en vivo)',
      icono: Icons.calculate_outlined,
      iconColor: AppColors.accentGreen,
      children: [
        if (m == null)
          const Text(
            'Seleccioná una tarifa para ver el cálculo.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          )
        else ...[
          _LineaResumen(
              label: 'Monto Vecchi',
              valor: '\$ ${AppFormatters.formatearMonto(m.montoVecchi)}'),
          _LineaResumen(
              label: 'Monto chofer (sin redondear)',
              valor: '\$ ${AppFormatters.formatearMonto(m.montoChofer)}'),
          _LineaResumen(
            label: 'Monto chofer redondeado',
            valor: '\$ ${AppFormatters.formatearMonto(m.montoChoferRedondeado)}',
            highlight: true,
          ),
          const Divider(height: 16),
          _LineaResumen(
              label: 'Adelanto',
              valor: '−\$ ${AppFormatters.formatearMonto(_adelantoFromUI())}'),
          _LineaResumen(
              label: 'Gastos',
              valor: '+\$ ${AppFormatters.formatearMonto(m.gastosTotal)}'),
          const Divider(height: 16),
          _LineaResumen(
            label: 'LIQUIDACIÓN AL CHOFER',
            valor: '\$ ${AppFormatters.formatearMonto(m.liquidacionChofer)}',
            highlight: true,
          ),
        ],
      ],
    );
  }

  // Helper: el monto del adelanto se infiere del cálculo (ya entra
  // al liquidacionChofer pero no se expone aparte). Como precaución
  // visual, sumamos al label "Adelanto" el monto deducido.
  double _adelantoFromUI() {
    if (montos == null) return 0;
    return (montos!.montoChoferRedondeado + montos!.gastosTotal -
            montos!.liquidacionChofer)
        .clamp(0, double.infinity);
  }
}

class _LineaResumen extends StatelessWidget {
  final String label;
  final String valor;
  final bool highlight;
  const _LineaResumen({
    required this.label,
    required this.valor,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
          Expanded(
            flex: 5,
            child: Text(
              valor,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: highlight ? AppColors.accentGreen : Colors.white,
                fontSize: highlight ? 14 : 12,
                fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BotonesGuardar extends StatelessWidget {
  final bool guardando;
  final VoidCallback onGuardar;
  final VoidCallback onCancelar;

  const _BotonesGuardar({
    required this.guardando,
    required this.onGuardar,
    required this.onCancelar,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: guardando ? null : onCancelar,
            child: const Text('CANCELAR'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: ElevatedButton.icon(
            onPressed: guardando ? null : onGuardar,
            icon: guardando
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: Text(guardando ? 'GUARDANDO...' : 'GUARDAR'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentGreen,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// PRIMITIVAS
// =============================================================================

class _SeccionCard extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final Color? iconColor;
  final List<Widget> children;

  const _SeccionCard({
    required this.titulo,
    required this.icono,
    this.iconColor,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, size: 18, color: iconColor ?? Colors.white60),
              const SizedBox(width: 6),
              Text(
                titulo,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _BotonFecha extends StatelessWidget {
  final String label;
  final DateTime? fecha;
  final ValueChanged<DateTime?> onChanged;

  const _BotonFecha({
    required this.label,
    required this.fecha,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: fecha ?? DateTime.now(),
          firstDate: DateTime(DateTime.now().year - 2),
          lastDate: DateTime(DateTime.now().year + 1),
          locale: const Locale('es', 'AR'),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: fecha == null
              ? const Icon(Icons.calendar_today, size: 18)
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => onChanged(null),
                ),
        ),
        child: Text(
          fecha == null ? 'Sin fecha' : AppFormatters.formatearFecha(fecha),
          style: TextStyle(
            color: fecha == null ? Colors.white54 : Colors.white,
          ),
        ),
      ),
    );
  }
}
