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
import '../models/empresa_logistica.dart';
import '../models/tarifa_logistica.dart';
import '../models/viaje.dart';
import '../services/logistica_service.dart';
import '../services/viajes_service.dart';
import '../utils/calculos_viaje.dart';

/// Form full-screen para alta y edición de viajes **multi-tramo**.
///
/// Layout (decisión Santiago 2026-05-11):
///   1. **Resumen** arriba (totales en vivo).
///   2. **Estado** del viaje.
///   3. **Chofer + Unidad** (chofer auto-llena unidad asignada).
///   4. **Adelanto** al chofer.
///   5. **Gastos extraordinarios**.
///   6. **Tramos** — uno o varios, con botón "+ AGREGAR TRAMO".
///
/// Cada tramo tiene su propia tarifa, fechas, kgs, producto y remito.
/// Caso típico: un viaje físico con varias cargas/descargas
/// intermedias (B.Blanca → Olavarría → Tres Arroyos → …).
class LogisticaViajeFormScreen extends StatefulWidget {
  /// Si null, modo "alta". Si trae id, carga el viaje para editar.
  final String? viajeId;

  const LogisticaViajeFormScreen({super.key, this.viajeId});

  @override
  State<LogisticaViajeFormScreen> createState() =>
      _LogisticaViajeFormScreenState();
}

class _LogisticaViajeFormScreenState extends State<LogisticaViajeFormScreen> {
  // ─── Datos compartidos del viaje ───
  String? _choferDni;
  String? _choferNombre;
  final _vehiculoCtrl = TextEditingController();
  final _engancheCtrl = TextEditingController();

  final _adelantoMontoCtrl = TextEditingController();
  DateTime? _adelantoFecha;
  final _adelantoObsCtrl = TextEditingController();

  List<GastoViaje> _gastos = [];

  EstadoViaje _estado = EstadoViaje.planeado;
  final _motivoCancelacionCtrl = TextEditingController();
  DateTime? _fechaPostergadoA;

  // ─── Tramos (1 o más) ───
  final List<_TramoEditState> _tramos = [];

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
    _adelantoMontoCtrl.dispose();
    _adelantoObsCtrl.dispose();
    _motivoCancelacionCtrl.dispose();
    for (final t in _tramos) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> _cargarSiEdicion() async {
    if (!_esEdicion) {
      // Alta: arrancamos con un tramo vacío.
      _tramos.add(_TramoEditState.vacio());
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

      _choferDni = v.choferDni;
      _choferNombre = v.choferNombre;
      _vehiculoCtrl.text = v.vehiculoId ?? '';
      _engancheCtrl.text = v.engancheId ?? '';
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

      // Hidratar tramos. Para cada uno necesitamos resolver la tarifa
      // (para reusar el dropdown del catálogo). Si la tarifa ya no
      // existe en el catálogo (fue borrada), reconstruimos una tarifa
      // dummy a partir del snapshot que tiene el tramo persistido.
      for (final t in v.tramos) {
        TarifaLogistica? tarifa;
        try {
          final tSnap = await LogisticaService.tarifasCol.doc(t.tarifaId).get();
          if (tSnap.exists) {
            tarifa = TarifaLogistica.fromMap(tSnap.id, tSnap.data()!);
          }
        } catch (_) {
          // ignoramos errores de red por tarifa — la usamos del snapshot
        }
        _tramos.add(_TramoEditState.fromTramoViaje(t, tarifa));
      }

      // Si por alguna razón el viaje viejo no tenía tramos (corrupción
      // o doc vacío), agregamos uno vacío para que el operador pueda
      // editar al menos.
      if (_tramos.isEmpty) {
        _tramos.add(_TramoEditState.vacio());
      }

      setState(() => _cargando = false);
    } catch (e) {
      setState(() {
        _cargando = false;
        _errorCarga = 'Error cargando viaje: $e';
      });
    }
  }

  /// Cálculos del resumen — suma los montos de todos los tramos con
  /// tarifa elegida + descuenta adelanto + suma gastos. Si ningún
  /// tramo tiene tarifa, devuelve null y el resumen muestra "—".
  MontosViaje? get _montosCalc {
    final tramosConTarifa = _tramos
        .where((t) => t.tarifa != null)
        .map((t) => t.toTramoViaje())
        .toList();
    if (tramosConTarifa.isEmpty) return null;
    final ade =
        AppFormatters.parsearMiles(_adelantoMontoCtrl.text)?.toDouble() ?? 0;
    return CalculosViaje.calcularTodoMultiTramo(
      tramos: tramosConTarifa,
      adelanto: ade,
      gastos: _gastos,
    );
  }

  Future<void> _sugerirAdelantoUltimoViaje(String dni) async {
    try {
      final ultimo = await ViajesService.ultimoViajeDeChofer(dni);
      if (!mounted) return;
      final monto = ultimo?.adelantoMonto ?? 0;
      if (monto <= 0) return;
      setState(() {
        _adelantoMontoCtrl.text = AppFormatters.formatearMiles(monto.toInt());
        final obs = ultimo?.adelantoObservacion?.trim();
        if (obs != null && obs.isNotEmpty && _adelantoObsCtrl.text.isEmpty) {
          _adelantoObsCtrl.text = obs;
        }
      });
    } catch (_) {/* best-effort */}
  }

  void _agregarTramo() {
    setState(() => _tramos.add(_TramoEditState.vacio()));
  }

  void _eliminarTramo(int index) {
    if (_tramos.length <= 1) return;
    final t = _tramos.removeAt(index);
    t.dispose();
    setState(() {});
  }

  // ─── Guardar ───
  Future<void> _guardar() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_choferDni == null || _choferDni!.isEmpty) {
      AppFeedback.warningOn(messenger, 'Asigná un chofer.');
      return;
    }
    if (_tramos.isEmpty) {
      AppFeedback.warningOn(messenger, 'El viaje debe tener al menos 1 tramo.');
      return;
    }
    final sinTarifa = _tramos.any((t) => t.tarifa == null);
    if (sinTarifa) {
      AppFeedback.warningOn(
        messenger,
        'Todos los tramos deben tener tarifa seleccionada.',
      );
      return;
    }

    setState(() => _guardando = true);
    try {
      final dniActual = PrefsService.dni;
      final ade =
          AppFormatters.parsearMiles(_adelantoMontoCtrl.text)?.toDouble();

      // Construir lista de tramos para persistir.
      final tramosViaje = _tramos.map((t) => t.toTramoViaje()).toList();

      String viajeId;
      if (_esEdicion) {
        await ViajesService.actualizarViaje(
          viajeId: widget.viajeId!,
          tramos: tramosViaje,
          choferDni: _choferDni!,
          choferNombre: _choferNombre,
          vehiculoId: _vehiculoCtrl.text.trim().isEmpty
              ? null
              : _vehiculoCtrl.text.trim().toUpperCase(),
          engancheId: _engancheCtrl.text.trim().isEmpty
              ? null
              : _engancheCtrl.text.trim().toUpperCase(),
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
          tramos: tramosViaje,
          choferDni: _choferDni!,
          choferNombre: _choferNombre,
          vehiculoId: _vehiculoCtrl.text.trim().isEmpty
              ? null
              : _vehiculoCtrl.text.trim().toUpperCase(),
          engancheId: _engancheCtrl.text.trim().isEmpty
              ? null
              : _engancheCtrl.text.trim().toUpperCase(),
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

      // Subir remitos pendientes de los tramos (los que el operador
      // pickeó pero todavía no se subieron porque no había viajeId).
      var requiereUpdateRemitos = false;
      final List<TramoViaje> tramosFinal = List.of(tramosViaje);
      for (var i = 0; i < _tramos.length; i++) {
        final edit = _tramos[i];
        if (edit.remitoBytesPendientes != null &&
            edit.remitoExtPendiente != null) {
          final res = await ViajesService.subirRemito(
            viajeId: viajeId,
            bytes: edit.remitoBytesPendientes!,
            extension: edit.remitoExtPendiente!,
            contentType: edit.remitoMimePendiente,
          );
          tramosFinal[i] = tramosFinal[i].copyWith(
            remitoUrl: res.url,
            remitoPathStorage: res.path,
          );
          requiereUpdateRemitos = true;
        }
      }
      if (requiereUpdateRemitos) {
        // Re-escribimos los tramos con las URLs reales. NO recalculamos
        // montos — el contenido del remito no afecta los montos.
        await FirebaseFirestore.instance
            .collection(AppCollections.viajesLogistica)
            .doc(viajeId)
            .update({
          'tramos': tramosFinal.map((t) => t.toMap()).toList(),
          // Denormalizar último tramo también.
          'remito_url': tramosFinal.last.remitoUrl,
          'remito_path_storage': tramosFinal.last.remitoPathStorage,
        });
      }

      if (!mounted) return;
      AppFeedback.successOn(
        messenger,
        _esEdicion ? 'Viaje actualizado.' : 'Viaje creado.',
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        AppFeedback.errorOn(messenger, 'Error al guardar: $e');
      }
    }
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
            // 1. RESUMEN (arriba — totales en vivo).
            _SeccionResumen(montos: _montosCalc),
            const SizedBox(height: 12),

            // 2. ESTADO.
            _SeccionEstado(
              estado: _estado,
              motivoCtrl: _motivoCancelacionCtrl,
              fechaPostergadoA: _fechaPostergadoA,
              onEstadoChanged: (e) => setState(() => _estado = e),
              onFechaChanged: (d) => setState(() => _fechaPostergadoA = d),
            ),
            const SizedBox(height: 12),

            // 3. CHOFER + UNIDAD.
            _SeccionChofer(
              dni: _choferDni,
              nombre: _choferNombre,
              onChanged: (dni, nombre, vehiculo, enganche) {
                setState(() {
                  _choferDni = dni;
                  _choferNombre = nombre;
                  _vehiculoCtrl.text = vehiculo ?? '';
                  _engancheCtrl.text = enganche ?? '';
                });
                if (!_esEdicion) {
                  _sugerirAdelantoUltimoViaje(dni);
                }
              },
            ),
            const SizedBox(height: 12),
            _SeccionUnidad(
              vehiculoCtrl: _vehiculoCtrl,
              engancheCtrl: _engancheCtrl,
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 12),

            // 4. ADELANTO.
            _SeccionAdelanto(
              montoCtrl: _adelantoMontoCtrl,
              fecha: _adelantoFecha,
              obsCtrl: _adelantoObsCtrl,
              onMontoChanged: () => setState(() {}),
              onFechaChanged: (d) => setState(() => _adelantoFecha = d),
            ),
            const SizedBox(height: 12),

            // 5. GASTOS EXTRAORDINARIOS.
            _SeccionGastos(
              gastos: _gastos,
              onChanged: (l) => setState(() => _gastos = l),
            ),
            const SizedBox(height: 12),

            // 6. TRAMOS (uno o varios).
            ..._tramos.asMap().entries.map((entry) {
              final index = entry.key;
              final tramo = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _TramoCard(
                  key: ValueKey(tramo.id),
                  numero: index + 1,
                  state: tramo,
                  puedeEliminar: _tramos.length > 1,
                  onEliminar: () => _eliminarTramo(index),
                  onCambio: () => setState(() {}),
                ),
              );
            }),
            _BotonAgregarTramo(onPressed: _agregarTramo),
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
// _TramoEditState — encapsula los controllers y el state de un tramo
// =============================================================================

class _TramoEditState {
  /// Identificador local estable (para el ValueKey de Flutter).
  final String id;

  TarifaLogistica? tarifa;
  String? producto;
  final TextEditingController descripcionCargaCtrl;
  DateTime? fechaCarga;
  final TextEditingController kgCargadosCtrl;

  DateTime? fechaDescarga;
  final TextEditingController remitoNumeroCtrl;
  final TextEditingController kgDescargadosCtrl;
  String? remitoUrl;
  String? remitoPathStorage;
  String? remitoNombreLocal;
  Uint8List? remitoBytesPendientes;
  String? remitoExtPendiente;
  String? remitoMimePendiente;

  _TramoEditState._({
    required this.id,
    this.tarifa,
    this.producto,
    String? descripcionCarga,
    this.fechaCarga,
    String? kgCargados,
    this.fechaDescarga,
    String? remitoNumero,
    String? kgDescargados,
    this.remitoUrl,
    this.remitoPathStorage,
  })  : descripcionCargaCtrl =
            TextEditingController(text: descripcionCarga ?? ''),
        kgCargadosCtrl = TextEditingController(text: kgCargados ?? ''),
        remitoNumeroCtrl = TextEditingController(text: remitoNumero ?? ''),
        kgDescargadosCtrl = TextEditingController(text: kgDescargados ?? '');

  factory _TramoEditState.vacio() {
    return _TramoEditState._(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
    );
  }

  factory _TramoEditState.fromTramoViaje(
    TramoViaje t,
    TarifaLogistica? tarifaResuelta,
  ) {
    return _TramoEditState._(
      id: t.id,
      tarifa: tarifaResuelta,
      producto: t.producto,
      descripcionCarga: t.descripcionCarga,
      fechaCarga: t.fechaCarga,
      kgCargados: t.kgCargados == null
          ? null
          : AppFormatters.formatearMiles(t.kgCargados!.toInt()),
      fechaDescarga: t.fechaDescarga,
      remitoNumero: t.remitoNumero,
      kgDescargados: t.kgDescargados == null
          ? null
          : AppFormatters.formatearMiles(t.kgDescargados!.toInt()),
      remitoUrl: t.remitoUrl,
      remitoPathStorage: t.remitoPathStorage,
    );
  }

  void dispose() {
    descripcionCargaCtrl.dispose();
    kgCargadosCtrl.dispose();
    remitoNumeroCtrl.dispose();
    kgDescargadosCtrl.dispose();
  }

  TramoViaje toTramoViaje() {
    final kgC = AppFormatters.parsearMiles(kgCargadosCtrl.text)?.toDouble();
    final kgD = AppFormatters.parsearMiles(kgDescargadosCtrl.text)?.toDouble();
    return TramoViaje(
      id: id,
      tarifaId: tarifa!.id,
      tarifaSnapshot: TarifaSnapshot.fromTarifa(tarifa!),
      producto: producto?.trim().isEmpty ?? true ? null : producto!.trim(),
      descripcionCarga: descripcionCargaCtrl.text.trim().isEmpty
          ? null
          : descripcionCargaCtrl.text.trim(),
      fechaCarga: fechaCarga,
      kgCargados: kgC,
      fechaDescarga: fechaDescarga,
      remitoNumero: remitoNumeroCtrl.text.trim().isEmpty
          ? null
          : remitoNumeroCtrl.text.trim(),
      remitoUrl: remitoUrl,
      remitoPathStorage: remitoPathStorage,
      kgDescargados: kgD,
    );
  }
}

// =============================================================================
// _TramoCard — un tramo en el form (card con todos sus campos)
// =============================================================================

class _TramoCard extends StatelessWidget {
  final int numero;
  final _TramoEditState state;
  final bool puedeEliminar;
  final VoidCallback onEliminar;
  final VoidCallback onCambio;

  const _TramoCard({
    super.key,
    required this.numero,
    required this.state,
    required this.puedeEliminar,
    required this.onEliminar,
    required this.onCambio,
  });

  Future<void> _pickRemito(BuildContext context) async {
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
    state.remitoBytesPendientes = f.bytes;
    state.remitoExtPendiente = ext;
    state.remitoMimePendiente = mime;
    state.remitoNombreLocal = f.name;
    onCambio();
  }

  @override
  Widget build(BuildContext context) {
    final esTn = state.tarifa?.unidadTarifa == UnidadTarifa.porTonelada;
    final tarifa = state.tarifa;
    return _SeccionCard(
      titulo: 'TRAMO $numero',
      icono: Icons.alt_route_outlined,
      trailing: puedeEliminar
          ? IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: AppColors.accentRed),
              onPressed: onEliminar,
              tooltip: 'Eliminar tramo',
              visualDensity: VisualDensity.compact,
            )
          : null,
      children: [
        // Tarifa.
        StreamBuilder<List<TarifaLogistica>>(
          stream: LogisticaService.streamTarifas(soloActivas: true),
          builder: (ctx, snap) {
            final lista = snap.data ?? const <TarifaLogistica>[];
            return DropdownButtonFormField<String>(
              initialValue: tarifa?.id,
              decoration: const InputDecoration(
                labelText: 'Tarifa',
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
                state.tarifa = t;
                // Si cambió la tarifa, reseteamos el producto (porque
                // viene de empresa origen distinta).
                state.producto = null;
                onCambio();
              },
            );
          },
        ),
        if (tarifa != null) ...[
          const SizedBox(height: 8),
          _ResumenTarifa(t: tarifa),
        ],
        const SizedBox(height: 12),

        // CARGA — fecha + kg + producto + descripción libre.
        const _SubseccionTitulo('CARGA'),
        const SizedBox(height: 8),
        _BotonFecha(
          label: 'Fecha de carga',
          fecha: state.fechaCarga,
          onChanged: (d) {
            state.fechaCarga = d;
            onCambio();
          },
        ),
        if (esTn) ...[
          const SizedBox(height: 8),
          TextField(
            controller: state.kgCargadosCtrl,
            decoration: const InputDecoration(
              labelText: 'Kg cargados',
              suffixText: 'kg',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [AppFormatters.inputMiles],
            onChanged: (_) => onCambio(),
          ),
        ],
        const SizedBox(height: 8),
        // Producto — dropdown poblado con productos de la empresa
        // origen de la tarifa. Si no hay tarifa, queda deshabilitado.
        _DropdownProducto(
          empresaOrigenId: tarifa?.empresaOrigenId,
          valor: state.producto,
          onChanged: (p) {
            state.producto = p;
            onCambio();
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: state.descripcionCargaCtrl,
          decoration: const InputDecoration(
            labelText: 'Descripción / observación (opcional)',
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
        ),
        const SizedBox(height: 16),

        // DESCARGA — fecha + remito + comprobante + kg descargados.
        const _SubseccionTitulo('DESCARGA'),
        const SizedBox(height: 8),
        _BotonFecha(
          label: 'Fecha de descarga',
          fecha: state.fechaDescarga,
          onChanged: (d) {
            state.fechaDescarga = d;
            onCambio();
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: state.remitoNumeroCtrl,
          decoration: const InputDecoration(
            labelText: 'Número de remito',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _pickRemito(context),
          icon: const Icon(Icons.attach_file, size: 18),
          label: Text(
            state.remitoNombreLocal ??
                (state.remitoUrl != null
                    ? 'Reemplazar comprobante'
                    : 'Subir comprobante firmado (PDF / foto)'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (state.remitoUrl != null && state.remitoNombreLocal == null) ...[
          const SizedBox(height: 4),
          const Text(
            '✓ Comprobante ya cargado.',
            style: TextStyle(color: AppColors.accentGreen, fontSize: 11),
          ),
        ],
        if (esTn) ...[
          const SizedBox(height: 8),
          TextField(
            controller: state.kgDescargadosCtrl,
            decoration: const InputDecoration(
              labelText: 'Kg descargados (cifra final para liquidar)',
              suffixText: 'kg',
              border: OutlineInputBorder(),
              helperText:
                  'Si está vacío, se calcula con kg cargados (estimado).',
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [AppFormatters.inputMiles],
            onChanged: (_) => onCambio(),
          ),
        ],
      ],
    );
  }
}

class _BotonAgregarTramo extends StatelessWidget {
  final VoidCallback onPressed;
  const _BotonAgregarTramo({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.add),
      label: const Text('AGREGAR TRAMO'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accentBlue,
        side: const BorderSide(color: AppColors.accentBlue),
        padding: const EdgeInsets.symmetric(vertical: 14),
        textStyle: const TextStyle(
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

// =============================================================================
// _DropdownProducto — productos de la empresa origen de la tarifa
// =============================================================================

class _DropdownProducto extends StatelessWidget {
  final String? empresaOrigenId;
  final String? valor;
  final ValueChanged<String?> onChanged;

  const _DropdownProducto({
    required this.empresaOrigenId,
    required this.valor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (empresaOrigenId == null || empresaOrigenId!.isEmpty) {
      return const TextField(
        enabled: false,
        decoration: InputDecoration(
          labelText: 'Producto (elegí primero una tarifa)',
          border: OutlineInputBorder(),
        ),
      );
    }
    return FutureBuilder<EmpresaLogistica?>(
      future: LogisticaService.empresaPorId(empresaOrigenId!),
      builder: (ctx, snap) {
        final productos = snap.data?.productos ?? const <String>[];
        if (snap.connectionState == ConnectionState.waiting) {
          return const InputDecorator(
            decoration: InputDecoration(
              labelText: 'Producto',
              border: OutlineInputBorder(),
            ),
            child: SizedBox(
              height: 20,
              child: LinearProgressIndicator(),
            ),
          );
        }
        if (productos.isEmpty) {
          // Empresa sin productos catalogados — caer a texto libre
          // para no bloquear al operador.
          return TextField(
            decoration: const InputDecoration(
              labelText: 'Producto (libre — la empresa no tiene catálogo)',
              border: OutlineInputBorder(),
            ),
            controller: TextEditingController(text: valor ?? ''),
            onChanged: onChanged,
          );
        }
        // Si el valor actual no está en la lista (ej. se cargó un
        // producto libre y después se catalogaron otros), lo agregamos
        // a la lista para que no se pierda.
        final items = List<String>.from(productos);
        if (valor != null && valor!.isNotEmpty && !items.contains(valor)) {
          items.add(valor!);
        }
        return DropdownButtonFormField<String>(
          initialValue: items.contains(valor) ? valor : null,
          decoration: const InputDecoration(
            labelText: 'Producto',
            border: OutlineInputBorder(),
          ),
          isExpanded: true,
          items: items
              .map((p) => DropdownMenuItem(value: p, child: Text(p)))
              .toList(),
          onChanged: onChanged,
        );
      },
    );
  }
}

// =============================================================================
// SECCIONES COMPARTIDAS (sin cambios significativos del form viejo)
// =============================================================================

class _SeccionResumen extends StatelessWidget {
  final MontosViaje? montos;
  const _SeccionResumen({required this.montos});

  @override
  Widget build(BuildContext context) {
    return _SeccionCard(
      titulo: 'RESUMEN',
      icono: Icons.summarize_outlined,
      children: [
        if (montos == null)
          const Text(
            'Agregá al menos 1 tramo con tarifa para ver el cálculo.',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          )
        else ...[
          _LineaResumen(
            label: 'Facturado a Vecchi',
            valor: '\$${AppFormatters.formatearMonto(montos!.montoVecchi)}',
          ),
          _LineaResumen(
            label: 'Tarifa chofer (bruto)',
            valor: '\$${AppFormatters.formatearMonto(montos!.montoChofer)}',
          ),
          _LineaResumen(
            label: 'Tarifa chofer (redondeada)',
            valor:
                '\$${AppFormatters.formatearMonto(montos!.montoChoferRedondeado)}',
            destacado: true,
          ),
          _LineaResumen(
            label: 'Gastos extras',
            valor: '+ \$${AppFormatters.formatearMonto(montos!.gastosTotal)}',
          ),
          const Divider(color: Colors.white24, height: 16),
          _LineaResumen(
            label: 'Liquidación final al chofer',
            valor:
                '\$${AppFormatters.formatearMonto(montos!.liquidacionChofer)}',
            destacado: true,
          ),
        ],
      ],
    );
  }
}

class _LineaResumen extends StatelessWidget {
  final String label;
  final String valor;
  final bool destacado;
  const _LineaResumen({
    required this.label,
    required this.valor,
    this.destacado = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: destacado ? Colors.white : Colors.white70,
                fontSize: 13,
              ),
            ),
          ),
          Text(
            valor,
            style: TextStyle(
              color: destacado ? AppColors.accentGreen : Colors.white,
              fontSize: destacado ? 16 : 14,
              fontWeight: destacado ? FontWeight.bold : FontWeight.normal,
            ),
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
    return _SeccionCard(
      titulo: 'ESTADO',
      icono: Icons.flag_outlined,
      children: [
        DropdownButtonFormField<EstadoViaje>(
          initialValue: estado,
          decoration: const InputDecoration(
            labelText: 'Estado',
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
          onChanged: (e) {
            if (e != null) onEstadoChanged(e);
          },
        ),
        if (estado == EstadoViaje.cancelado) ...[
          const SizedBox(height: 8),
          TextField(
            controller: motivoCtrl,
            decoration: const InputDecoration(
              labelText: 'Motivo de cancelación',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
        ],
        if (estado == EstadoViaje.postergado) ...[
          const SizedBox(height: 8),
          _BotonFecha(
            label: 'Postergado al',
            fecha: fechaPostergadoA,
            onChanged: onFechaChanged,
          ),
        ],
      ],
    );
  }
}

class _SeccionChofer extends StatelessWidget {
  final String? dni;
  final String? nombre;
  final void Function(String dni, String nombre, String? vehiculo,
      String? enganche) onChanged;

  const _SeccionChofer({
    required this.dni,
    required this.nombre,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _SeccionCard(
      titulo: 'CHOFER',
      icono: Icons.person_outline,
      children: [
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection(AppCollections.empleados)
              .where('ROL', isEqualTo: 'CHOFER')
              .snapshots(),
          builder: (ctx, snap) {
            final docs = snap.data?.docs ?? const [];
            final items = docs.map((d) {
              final data = d.data();
              final dn = (data['DNI'] ?? d.id).toString();
              final nom = (data['NOMBRE'] ?? dn).toString();
              return DropdownMenuItem(
                value: dn,
                child: Text(nom, overflow: TextOverflow.ellipsis),
              );
            }).toList();
            return DropdownButtonFormField<String>(
              initialValue: dni,
              decoration: const InputDecoration(
                labelText: 'Chofer',
                border: OutlineInputBorder(),
              ),
              isExpanded: true,
              items: items,
              onChanged: (val) {
                if (val == null) return;
                final doc = docs.firstWhere(
                  (d) => (d.data()['DNI'] ?? d.id).toString() == val,
                );
                final data = doc.data();
                onChanged(
                  val,
                  (data['NOMBRE'] ?? val).toString(),
                  data['VEHICULO']?.toString(),
                  data['ENGANCHE']?.toString(),
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
      titulo: 'UNIDAD',
      icono: Icons.local_shipping_outlined,
      children: [
        TextField(
          controller: vehiculoCtrl,
          decoration: const InputDecoration(
            labelText: 'Patente tractor',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.characters,
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: engancheCtrl,
          decoration: const InputDecoration(
            labelText: 'Patente enganche',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.characters,
          onChanged: (_) => onChanged(),
        ),
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
      titulo: 'ADELANTO AL CHOFER',
      icono: Icons.payments_outlined,
      children: [
        TextField(
          controller: montoCtrl,
          decoration: const InputDecoration(
            labelText: 'Monto adelanto',
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
            labelText: 'Observación / concepto',
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

  Future<void> _agregar(BuildContext context) async {
    final montoCtrl = TextEditingController();
    final detalleCtrl = TextEditingController();
    DateTime fecha = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) {
        return StatefulBuilder(builder: (sCtx, setStateDialog) {
          return AlertDialog(
            backgroundColor: Theme.of(dCtx).colorScheme.surface,
            title: const Text('Agregar gasto'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: montoCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Monto',
                    prefixText: '\$ ',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [AppFormatters.inputMiles],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: detalleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Detalle (peaje, combustible, etc.)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                _BotonFecha(
                  label: 'Fecha del gasto',
                  fecha: fecha,
                  onChanged: (d) => setStateDialog(() {
                    if (d != null) fecha = d;
                  }),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dCtx).pop(false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dCtx).pop(true),
                child: const Text('Agregar'),
              ),
            ],
          );
        });
      },
    );
    if (ok == true) {
      final monto = AppFormatters.parsearMiles(montoCtrl.text)?.toDouble() ?? 0;
      if (monto <= 0) return;
      final nuevo = GastoViaje(
        monto: monto,
        detalle: detalleCtrl.text.trim().isEmpty
            ? null
            : detalleCtrl.text.trim(),
        fecha: fecha,
      );
      onChanged([...gastos, nuevo]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = gastos.fold<double>(0, (a, g) => a + g.monto);
    return _SeccionCard(
      titulo: 'GASTOS EXTRAORDINARIOS',
      icono: Icons.receipt_long_outlined,
      children: [
        if (gastos.isEmpty)
          const Text(
            'Sin gastos cargados.',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          )
        else
          ...gastos.asMap().entries.map((entry) {
            final i = entry.key;
            final g = entry.value;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  const Icon(Icons.add_circle_outline,
                      size: 16, color: AppColors.accentGreen),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${g.detalle ?? 'Gasto'} '
                      '(${AppFormatters.formatearFecha(g.fecha)})',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '\$${AppFormatters.formatearMonto(g.monto)}',
                    style: const TextStyle(
                      color: AppColors.accentGreen,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: Colors.white54),
                    onPressed: () {
                      final nueva = List<GastoViaje>.from(gastos)..removeAt(i);
                      onChanged(nueva);
                    },
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            );
          }),
        if (gastos.isNotEmpty) ...[
          const Divider(color: Colors.white24, height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total gastos',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              Text(
                '\$${AppFormatters.formatearMonto(total)}',
                style: const TextStyle(
                  color: AppColors.accentGreen,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _agregar(context),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('AGREGAR GASTO'),
        ),
      ],
    );
  }
}

// =============================================================================
// WIDGETS COMUNES (Card, fecha, etc.)
// =============================================================================

class _SeccionCard extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final List<Widget> children;
  final Widget? trailing;

  const _SeccionCard({
    required this.titulo,
    required this.icono,
    required this.children,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icono, color: AppColors.accentBlue, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  titulo,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    letterSpacing: 1,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _SubseccionTitulo extends StatelessWidget {
  final String texto;
  const _SubseccionTitulo(this.texto);

  @override
  Widget build(BuildContext context) {
    return Text(
      texto,
      style: const TextStyle(
        color: Colors.white60,
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
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

  Future<void> _pick(BuildContext context) async {
    final hoy = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: fecha ?? hoy,
      firstDate: DateTime(hoy.year - 2),
      lastDate: DateTime(hoy.year + 2),
    );
    if (d != null) onChanged(d);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _pick(context),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        child: Text(
          fecha == null ? 'Sin asignar' : AppFormatters.formatearFecha(fecha!),
          style: const TextStyle(color: Colors.white),
        ),
      ),
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
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            onPressed: guardando ? null : onGuardar,
            child: guardando
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('GUARDAR'),
          ),
        ),
      ],
    );
  }
}
