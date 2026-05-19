import 'dart:async';

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
import '../models/adelanto_chofer.dart';
import '../models/empresa_logistica.dart';
import '../models/tarifa_logistica.dart';
import '../models/viaje.dart';
import '../services/adelantos_service.dart';
import '../services/borradores_viaje_service.dart';
import '../services/logistica_service.dart';
import '../services/viajes_service.dart';
import '../utils/calculos_viaje.dart';

// ─── Split del archivo principal (refactor 2026-05-18) ───
//
// Originalmente este archivo tenia 2823 LOC con 24 classes en un solo lugar.
// Split en 5 archivos `part of` para que cada uno apunte a ~500 LOC tematica
// y un crash del analyzer / debugger apunte a un alcance manejable.
//
// Privacidad compartida: los `_Xxx` privados son visibles entre todos los
// part files (forman la misma library).
//
// Estructura:
//   logistica_viaje_form_screen.dart     <- principal: imports + state machine
//   logistica_viaje_form_tramos.dart     <- _TramoEditState + _TramoCard +
//                                            _BotonAgregarTramo +
//                                            _BannerEncadenamiento + _DropdownProducto
//   logistica_viaje_form_secciones.dart  <- _SeccionResumen + _SeccionEstado +
//                                            _SeccionChofer + _SeccionUnidad +
//                                            _SeccionAdelantoAsociado + _UpperCaseFormatter
//   logistica_viaje_form_gastos.dart     <- _SeccionGastos (gastos por tramo)
//   logistica_viaje_form_widgets.dart    <- _SeccionCard + _SubseccionTitulo +
//                                            _BotonFecha + _ResumenTarifa + _BotonesGuardar
//   logistica_viaje_form_tarifa_picker.dart <- _abrirSelectorTarifa +
//                                                _TarifaPickerSheet + _ItemTarifaPicker
part 'logistica_viaje_form_tramos.dart';
part 'logistica_viaje_form_secciones.dart';
part 'logistica_viaje_form_gastos.dart';
part 'logistica_viaje_form_widgets.dart';
part 'logistica_viaje_form_tarifa_picker.dart';

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

  // Adelanto: la sección de alta inline se removió 2026-05-13 (ahora
  // viven en `ADELANTOS_CHOFER`). El 2026-05-13 también se agregó la
  // posibilidad de ASOCIAR un adelanto preexistente al viaje desde
  // este form — `_adelantoAsociadoId` es el doc id elegido en el
  // dropdown. `_adelantoAsociadoIdInicial` guarda el valor con el que
  // se abrió el form (modo edición), para calcular el delta al
  // guardar y hacer solo el update mínimo (asociar/desasociar).
  String? _adelantoAsociadoId;
  String? _adelantoAsociadoIdInicial;

  // Gastos: desde 2026-05-13 viven en cada `_TramoEditState`, no más
  // a nivel viaje. Cada `_TramoCard` tiene su propio `_SeccionGastos`.

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

  // ─── Auto-guardar borrador ───
  // Timer debounced que persiste el estado del form a
  // `BORRADORES_VIAJE/{dni}_{viajeId|nuevo}` cuando hay cambios.
  // Sin esto, si se cierra la app cargando un viaje multi-tramo, se
  // perdían 10+ minutos de tipeo (pedido Santiago 2026-05-13).
  Timer? _borradorTimer;
  static const Duration _borradorDebounce = Duration(seconds: 10);
  bool _hayCambiosSinPersistir = false;
  bool _yaAvisoRecuperar = false;

  @override
  void initState() {
    super.initState();
    _cargarSiEdicion();
  }

  @override
  void dispose() {
    _borradorTimer?.cancel();
    // Si hay cambios que no llegaron al timer (operador cerró el form
    // < 10s después de tipear), disparamos el save fire-and-forget.
    // El SDK de Firestore mantiene su propia cola de writes y completa
    // aunque este widget se haya disposeado — la app sigue viva.
    if (_hayCambiosSinPersistir) {
      // Snapshot del state ANTES de disposear los controllers — sino
      // el save async lee texto de TextEditingController ya cerrado.
      final operadorDni = PrefsService.dni;
      final viajeIdOriginal = widget.viajeId;
      final choferDni = _choferDni;
      final choferNombre = _choferNombre;
      final vehiculoId = _vehiculoCtrl.text.trim().isEmpty
          ? null
          : _vehiculoCtrl.text.trim().toUpperCase();
      final engancheId = _engancheCtrl.text.trim().isEmpty
          ? null
          : _engancheCtrl.text.trim().toUpperCase();
      final estado = _estado;
      final motivoCancelacion = _motivoCancelacionCtrl.text.trim().isEmpty
          ? null
          : _motivoCancelacionCtrl.text.trim();
      final fechaPostergadoA = _fechaPostergadoA;
      final adelantoAsociadoId = _adelantoAsociadoId;
      final tramosViaje = _tramos
          .where((t) => t.tarifa != null)
          .map((t) => t.toTramoViaje())
          .toList(growable: false);
      // Detached future — no await en dispose.
      // ignore: discarded_futures
      BorradoresViajeService.guardar(
        operadorDni: operadorDni,
        viajeIdOriginal: viajeIdOriginal,
        choferDni: choferDni,
        choferNombre: choferNombre,
        vehiculoId: vehiculoId,
        engancheId: engancheId,
        tramos: tramosViaje,
        estado: estado,
        motivoCancelacion: motivoCancelacion,
        fechaPostergadoA: fechaPostergadoA,
        adelantoAsociadoId: adelantoAsociadoId,
      ).catchError((_) {/* best-effort */});
    }
    _vehiculoCtrl.dispose();
    _engancheCtrl.dispose();
    _motivoCancelacionCtrl.dispose();
    for (final t in _tramos) {
      t.dispose();
    }
    super.dispose();
  }

  /// Programa un save del borrador con debounce. Lo invoca el resto
  /// del form cuando hay cambios. Si llaman 10 veces seguidas en 5s,
  /// solo se persiste 1 vez al pasar 10s sin nuevas invocaciones.
  void _programarGuardadoBorrador() {
    _hayCambiosSinPersistir = true;
    _borradorTimer?.cancel();
    _borradorTimer = Timer(_borradorDebounce, _persistirBorradorAhora);
  }

  /// Persiste el estado actual del form al borrador. Best-effort —
  /// si falla (sin internet, etc.) no rompe el flow del form.
  Future<void> _persistirBorradorAhora() async {
    if (!_hayCambiosSinPersistir) return;
    _hayCambiosSinPersistir = false;
    try {
      final tramosViaje = _tramos
          .where((t) => t.tarifa != null)
          .map((t) => t.toTramoViaje())
          .toList();
      await BorradoresViajeService.guardar(
        operadorDni: PrefsService.dni,
        viajeIdOriginal: widget.viajeId,
        choferDni: _choferDni,
        choferNombre: _choferNombre,
        vehiculoId: _vehiculoCtrl.text.trim().isEmpty
            ? null
            : _vehiculoCtrl.text.trim().toUpperCase(),
        engancheId: _engancheCtrl.text.trim().isEmpty
            ? null
            : _engancheCtrl.text.trim().toUpperCase(),
        tramos: tramosViaje,
        estado: _estado,
        motivoCancelacion: _motivoCancelacionCtrl.text.trim().isEmpty
            ? null
            : _motivoCancelacionCtrl.text.trim(),
        fechaPostergadoA: _fechaPostergadoA,
        adelantoAsociadoId: _adelantoAsociadoId,
      );
    } catch (_) {
      // Best-effort. Si falla, el operador no se entera — el
      // borrador queda con el estado del último save exitoso.
    }
  }

  Future<void> _eliminarBorrador() async {
    _borradorTimer?.cancel();
    _hayCambiosSinPersistir = false;
    try {
      await BorradoresViajeService.eliminar(
        operadorDni: PrefsService.dni,
        viajeIdOriginal: widget.viajeId,
      );
    } catch (_) {
      // Idem — best-effort.
    }
  }

  /// Chequea si quedó un borrador del operador para este viaje (o para
  /// "nuevo" en modo alta). Si existe, ofrece recuperarlo. Se llama una
  /// sola vez al terminar la carga inicial — `_yaAvisoRecuperar` evita
  /// loops si el operador reabre o si por algún motivo se vuelve a
  /// invocar.
  Future<void> _chequearBorradorAlIniciar() async {
    if (_yaAvisoRecuperar) return;
    _yaAvisoRecuperar = true;
    try {
      final dni = PrefsService.dni;
      if (dni.isEmpty) return;
      final borrador = await BorradoresViajeService.leer(
        operadorDni: dni,
        viajeIdOriginal: widget.viajeId,
      );
      if (borrador == null || !mounted) return;
      // Si el borrador está totalmente vacío (chofer null + sin tramos
      // con tarifa), no vale la pena ofrecer recuperar — lo borramos
      // silencioso así no molesta más.
      final hayContenido = (borrador.choferDni != null &&
              borrador.choferDni!.isNotEmpty) ||
          borrador.tramos.any((t) => t.tarifaId.isNotEmpty);
      if (!hayContenido) {
        await BorradoresViajeService.eliminar(
          operadorDni: dni,
          viajeIdOriginal: widget.viajeId,
        );
        return;
      }
      final aceptar = await _mostrarDialogRecuperar(borrador);
      if (!mounted) return;
      if (aceptar != true) {
        // Operador descartó — borrar para no volver a preguntar.
        await BorradoresViajeService.eliminar(
          operadorDni: dni,
          viajeIdOriginal: widget.viajeId,
        );
        return;
      }
      await _hidratarDesdeBorrador(borrador);
    } catch (_) {
      // Best-effort. Si falla leer/dialog/etc., el form sigue con lo
      // que tenía cargado del viaje (o vacío en alta).
    }
  }

  /// Dialog "¿Recuperar borrador?". Devuelve true si el operador
  /// quiere recuperar, false si quiere descartar, null si lo cerró
  /// con back (lo tratamos como descartar).
  Future<bool?> _mostrarDialogRecuperar(BorradorViaje b) {
    final cuando = b.actualizadoEn == null
        ? 'fecha desconocida'
        : AppFormatters.formatearFechaHoraSinSegundos(b.actualizadoEn!);
    final cantTramos = b.tramos.length;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dCtx) {
        return AlertDialog(
          title: const Text('Recuperar borrador'),
          content: Text(
            'Encontramos un borrador sin guardar de este viaje '
            '(actualizado $cuando, $cantTramos tramo(s)).\n\n'
            '¿Querés recuperarlo o descartarlo?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: const Text('DESCARTAR'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: const Text('RECUPERAR'),
            ),
          ],
        );
      },
    );
  }

  /// Reemplaza el estado actual del form con lo que tenga el borrador.
  /// Resuelve la tarifa de cada tramo igual que `_cargarSiEdicion`
  /// (mirando el catálogo). Notifica al operador con un snackbar.
  Future<void> _hidratarDesdeBorrador(BorradorViaje b) async {
    // Limpiar tramos actuales antes de reemplazar (sino fugamos
    // controllers de TextEditingController).
    for (final t in _tramos) {
      t.dispose();
    }
    _tramos.clear();

    _choferDni = b.choferDni;
    _choferNombre = b.choferNombre;
    _vehiculoCtrl.text = b.vehiculoId ?? '';
    _engancheCtrl.text = b.engancheId ?? '';
    _estado = b.estado;
    _motivoCancelacionCtrl.text = b.motivoCancelacion ?? '';
    _fechaPostergadoA = b.fechaPostergadoA;
    _adelantoAsociadoId = b.adelantoAsociadoId;

    // Performance: paralelizar lookups de tarifa al restaurar borrador
    // (auditoria 2026-05-17 — antes secuencial). Mismo patron que el
    // load del viaje en linea ~378.
    final tarifaSnaps = await Future.wait(b.tramos.map((t) async {
      try {
        return await LogisticaService.tarifasCol.doc(t.tarifaId).get();
      } catch (_) {
        return null;
      }
    }));
    for (var i = 0; i < b.tramos.length; i++) {
      final t = b.tramos[i];
      final tSnap = tarifaSnaps[i];
      TarifaLogistica? tarifa;
      if (tSnap != null && tSnap.exists) {
        tarifa = TarifaLogistica.fromMap(tSnap.id, tSnap.data()!);
      }
      _tramos.add(_TramoEditState.fromTramoViaje(t, tarifa));
    }
    if (_tramos.isEmpty) {
      _tramos.add(_TramoEditState.vacio());
    }

    if (!mounted) return;
    setState(() {});
    AppFeedback.successOn(
      ScaffoldMessenger.of(context),
      'Borrador recuperado.',
    );
  }

  Future<void> _cargarSiEdicion() async {
    if (!_esEdicion) {
      // Alta: arrancamos con un tramo vacío.
      _tramos.add(_TramoEditState.vacio());
      setState(() => _cargando = false);
      // Después del primer render, ofrecer recuperar borrador si hay.
      await _chequearBorradorAlIniciar();
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
      // Adelantos antes vivían en el viaje (`v.adelantoMonto` etc.).
      // Ahora viven en ADELANTOS_CHOFER. Los campos del viaje siguen
      // accesibles vía getters de compat pero NO se editan más desde
      // este form — la pantalla LogisticaAdelantosScreen los gestiona.
      // Gastos: cada tramo los carga en su `_TramoEditState.gastos`
      // (refactor 2026-05-13). Aviaje viejo con gastos al nivel raíz
      // los heredó el primer tramo vía `Viaje.fromMap`, así que acá
      // no hay que hacer nada extra.
      _estado = v.estado;
      _motivoCancelacionCtrl.text = v.motivoCancelacion ?? '';
      _fechaPostergadoA = v.fechaPostergadoA;

      // Hidratar tramos. Para cada uno necesitamos resolver la tarifa
      // (para reusar el dropdown del catálogo). Si la tarifa ya no
      // existe en el catálogo (fue borrada), reconstruimos una tarifa
      // dummy a partir del snapshot que tiene el tramo persistido.
      //
      // Performance (auditoria 2026-05-17): antes hacia N round-trips
      // secuenciales (1 por tramo). Para viaje multi-tramo con 5
      // tramos, 5 lecturas Firestore en serie ≈ 1-2s de espera. Ahora
      // disparamos en paralelo con Future.wait — 1 round-trip de
      // latencia para los N tarifas.
      final tarifaSnaps = await Future.wait(v.tramos.map((t) async {
        try {
          return await LogisticaService.tarifasCol.doc(t.tarifaId).get();
        } catch (_) {
          return null;
        }
      }));
      for (var i = 0; i < v.tramos.length; i++) {
        final t = v.tramos[i];
        final tSnap = tarifaSnaps[i];
        TarifaLogistica? tarifa;
        if (tSnap != null && tSnap.exists) {
          tarifa = TarifaLogistica.fromMap(tSnap.id, tSnap.data()!);
        }
        _tramos.add(_TramoEditState.fromTramoViaje(t, tarifa));
      }

      // Si por alguna razón el viaje viejo no tenía tramos (corrupción
      // o doc vacío), agregamos uno vacío para que el operador pueda
      // editar al menos.
      if (_tramos.isEmpty) {
        _tramos.add(_TramoEditState.vacio());
      }

      // Hidratar el adelanto asociado. Si hay uno con
      // `viaje_id == widget.viajeId`, lo seteamos como selección
      // inicial del dropdown. Sin esto, en modo edición el dropdown
      // arrancaría en "(sin adelanto)" aún si el viaje ya tenía uno
      // asociado desde antes.
      try {
        final adAsociado =
            await AdelantosService.getPorViaje(widget.viajeId!);
        if (adAsociado != null) {
          _adelantoAsociadoId = adAsociado.id;
          _adelantoAsociadoIdInicial = adAsociado.id;
        }
      } catch (_) {
        // No es fatal — el operador puede asociar uno nuevo igual.
      }

      setState(() => _cargando = false);
      // Igual que en alta: chequear borrador previo si el operador
      // estaba editando este viaje y cerró la app a mitad de camino.
      await _chequearBorradorAlIniciar();
    } catch (e) {
      setState(() {
        _cargando = false;
        _errorCarga = 'Error cargando viaje: $e';
      });
    }
  }

  /// Cálculos del resumen — suma los montos de todos los tramos con
  /// tarifa elegida + suma gastos. Adelanto removido del form 2026-05-13
  /// (vive en colección propia ahora). El resumen acá muestra el bruto
  /// del chofer sin descontar adelantos — la pantalla LIQUIDACIÓN sí
  /// los suma del rango cuando se cierra el mes.
  MontosViaje? get _montosCalc {
    final tramosConTarifa = _tramos
        .where((t) => t.tarifa != null)
        .map((t) => t.toTramoViaje())
        .toList();
    if (tramosConTarifa.isEmpty) return null;
    // Gastos van adentro de cada tramo desde 2026-05-13 — el helper
    // los suma solo si no pasamos `gastos` explícito.
    return CalculosViaje.calcularTodoMultiTramo(
      tramos: tramosConTarifa,
      adelanto: 0,
    );
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

  // _moverTramoArriba / _moverTramoAbajo / _duplicarTramo se quitaron
  // 2026-05-14 junto con sus botones del header de TRAMO (Santiago:
  // "innecesario"). Si en algún momento se vuelven a necesitar, mirar
  // git history — la lógica era trivial (swap + insert con clone).

  /// Devuelve un mensaje de warning si el origen del tramo `actual`
  /// no encadena con el destino del tramo `anterior`. Devuelve null
  /// si encadenan bien o si no se puede determinar (algún tramo sin
  /// tarifa). Es un WARNING, NO un error — hay casos legítimos donde
  /// el tractor pasa por la base entre tramos, así que no bloquea
  /// el guardado.
  ///
  /// Criterio: comparamos por `ubicacion*Id`, no por empresa,
  /// porque dentro de una empresa puede haber varias plantas y la
  /// "ruta lógica" del viaje cambia entre ellas.
  String? _validarEncadenamiento(
    _TramoEditState anterior,
    _TramoEditState actual,
  ) {
    final tarA = anterior.tarifa;
    final tarB = actual.tarifa;
    if (tarA == null || tarB == null) return null;
    if (tarA.ubicacionDestinoId == tarB.ubicacionOrigenId) return null;
    return 'El origen no coincide con el destino del tramo anterior '
        '(${tarA.ubicacionDestinoEtiqueta} → ${tarB.ubicacionOrigenEtiqueta}). '
        'Revisá si está bien.';
  }

  /// Warning si la fecha de descarga es ANTERIOR a la fecha de carga
  /// dentro del mismo tramo. Si alguna de las dos es null (caso típico
  /// "todavía no descargó"), no se valida. NO bloquea — solo advierte.
  /// Pedido Santiago 2026-05-13: validar fechas pero no kg
  /// ("muchas veces no sabemos los kg que cargan hasta que regresan").
  String? _validarFechasInternasTramo(_TramoEditState t) {
    final c = t.fechaCarga;
    final d = t.fechaDescarga;
    if (c == null || d == null) return null;
    // Comparamos día calendario, no instantáneo (las fechas no llevan
    // hora — son DatePicker). `isBefore` es estricto: igual día = OK.
    final cd = DateTime(c.year, c.month, c.day);
    final dd = DateTime(d.year, d.month, d.day);
    if (dd.isBefore(cd)) {
      return 'La fecha de descarga (${AppFormatters.formatearFecha(d)}) es '
          'anterior a la fecha de carga (${AppFormatters.formatearFecha(c)}). '
          'Revisá si está bien.';
    }
    return null;
  }

  /// Dialog "Encontramos viajes parecidos — ¿es distinto?". Lista
  /// los candidatos con fecha + chofer + ruta del primer tramo.
  /// Devuelve true si el operador confirma "es distinto, guardar
  /// igual", false si quiere revisar.
  Future<bool?> _mostrarDialogDuplicados(List<Viaje> candidatos) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dCtx) {
        return AlertDialog(
          title: const Text('Posibles duplicados'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Encontramos ${candidatos.length} '
                  'viaje${candidatos.length == 1 ? "" : "s"} del mismo '
                  'chofer en las últimas 24h con alguna tarifa en común:',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                ...candidatos.map((v) {
                  final fecha = v.fechaReferencia == null
                      ? 's/fecha'
                      : AppFormatters.formatearFecha(v.fechaReferencia!);
                  // `rutaEtiqueta` ya maneja multi-tramo (orig → … → dest).
                  final ruta = v.tramos.isEmpty ? 'sin ruta' : v.rutaEtiqueta;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_outlined,
                            size: 16, color: AppColors.accentAmber),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '$fecha · $ruta',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 8),
                const Text(
                  '¿Es un viaje distinto?',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: const Text('REVISAR'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: const Text('SÍ, GUARDAR IGUAL'),
            ),
          ],
        );
      },
    );
  }

  /// Warning si la fecha de carga del tramo `actual` es ANTERIOR a la
  /// fecha de descarga del tramo `anterior`. Si falta alguna fecha,
  /// no se valida. NO bloquea.
  String? _validarFechasEntreTramos(
    _TramoEditState anterior,
    _TramoEditState actual,
  ) {
    final descPrev = anterior.fechaDescarga;
    final cargaCurr = actual.fechaCarga;
    if (descPrev == null || cargaCurr == null) return null;
    final dp = DateTime(descPrev.year, descPrev.month, descPrev.day);
    final cc = DateTime(cargaCurr.year, cargaCurr.month, cargaCurr.day);
    if (cc.isBefore(dp)) {
      return 'La carga de este tramo '
          '(${AppFormatters.formatearFecha(cargaCurr)}) es anterior a la '
          'descarga del tramo anterior '
          '(${AppFormatters.formatearFecha(descPrev)}). Revisá si está bien.';
    }
    return null;
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

    // Detección de duplicados — solo modo ALTA (en edición, el viaje
    // YA existe, no puede ser duplicado de sí mismo trivialmente).
    // Si hay candidatos, mostramos un dialog y dejamos al operador
    // decidir si igual quiere crearlo (NO bloqueamos — puede ser
    // legítimo: viaje 2 del día con misma ruta).
    if (!_esEdicion) {
      final tarifaIds = _tramos
          .map((t) => t.tarifa!.id)
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList(growable: false);
      try {
        final candidatos = await ViajesService.buscarPosiblesDuplicados(
          choferDni: _choferDni!,
          tarifaIds: tarifaIds,
        );
        if (!mounted) return;
        if (candidatos.isNotEmpty) {
          final continuar = await _mostrarDialogDuplicados(candidatos);
          if (continuar != true) return;
        }
      } catch (e) {
        // Si la query falla (sin internet, etc.), NO bloqueamos el
        // guardado — la detección es best-effort.
        // ignore: avoid_print
        AppFeedback.warningOn(
          messenger,
          'No se pudo chequear duplicados ($e). Guardando igual.',
        );
      }
    }

    setState(() => _guardando = true);
    try {
      final dniActual = PrefsService.dni;

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
          // Adelanto: removido del form 2026-05-13. Si el viaje viejo
          // ya tenía adelantoMonto/Fecha/Observacion, el service NO
          // los pisa porque le pasamos null (acepta null). Si querés
          // limpiar campos legacy, hay que hacerlo desde un script
          // de migración aparte.
          adelantoMonto: null,
          adelantoFecha: null,
          adelantoObservacion: null,
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
          // Adelantos en colección aparte desde 2026-05-13. Si el
          // operador necesita registrar un adelanto para este viaje,
          // lo hace después desde Logística → Adelantos.
          adelantoMonto: null,
          adelantoFecha: null,
          adelantoObservacion: null,
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

      // Sincronizar asociación del adelanto. Lo hacemos DESPUÉS de
      // tener el `viajeId` confirmado (sirve tanto para alta como
      // edición). Tres casos:
      //   1. Cambió a otro adelanto: desasociar el anterior + asociar
      //      el nuevo (2 writes).
      //   2. Se eligió uno y antes no había: asociar (1 write).
      //   3. Se sacó la asociación: desasociar el anterior (1 write).
      // Si no cambió respecto del valor inicial, no se hace nada
      // (idempotente).
      if (_adelantoAsociadoId != _adelantoAsociadoIdInicial) {
        try {
          if (_adelantoAsociadoIdInicial != null) {
            await AdelantosService.setViajeAsociado(
              adelantoId: _adelantoAsociadoIdInicial!,
              viajeId: null,
              actualizadoPorDni: dniActual,
            );
          }
          if (_adelantoAsociadoId != null) {
            await AdelantosService.setViajeAsociado(
              adelantoId: _adelantoAsociadoId!,
              viajeId: viajeId,
              actualizadoPorDni: dniActual,
            );
          }
        } catch (e) {
          // El viaje YA quedó guardado. Si falla la asociación del
          // adelanto avisamos pero no rompemos el flujo — el operador
          // puede reasociar entrando a Editar.
          if (mounted) {
            AppFeedback.warningOn(
              messenger,
              'Viaje guardado, pero falló asociar el adelanto: $e',
            );
          }
        }
      }

      // El viaje quedó guardado en firme — el borrador ya no sirve.
      // Lo borramos para que la próxima vez que el operador entre al
      // form no le ofrezca recuperar algo viejo.
      await _eliminarBorrador();

      if (!mounted) return;
      AppFeedback.successOn(
        messenger,
        _esEdicion ? 'Viaje actualizado.' : 'Viaje creado.',
      );
      Navigator.of(context).pop();
    } catch (e, s) {
      if (mounted) {
        setState(() => _guardando = false);
        AppFeedback.errorTecnicoOn(
          messenger,
          usuario: 'No se pudo guardar el viaje. Probá de nuevo.',
          tecnico: e,
          stack: s,
        );
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
      // Atajo Ctrl+S para guardar (auditoria 2026-05-17, util en Windows
      // desktop donde el operador trabaja teclado-only). Si ya esta
      // guardando no hace nada — evita doble submit.
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (!_guardando) _guardar();
          },
        },
        child: Focus(
          autofocus: true,
          child: SingleChildScrollView(
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
              onEstadoChanged: (e) {
                setState(() => _estado = e);
                _programarGuardadoBorrador();
              },
              onFechaChanged: (d) {
                setState(() => _fechaPostergadoA = d);
                _programarGuardadoBorrador();
              },
              onCambio: _programarGuardadoBorrador,
            ),
            const SizedBox(height: 12),

            // 3. CHOFER + UNIDAD.
            _SeccionChofer(
              dni: _choferDni,
              nombre: _choferNombre,
              onChanged: (dni, nombre, vehiculo, enganche) {
                setState(() {
                  // Si cambia el chofer, el adelanto previamente
                  // seleccionado pertenece a OTRO chofer (los adelantos
                  // viven por DNI). Lo limpiamos para que el operador
                  // elija uno del chofer nuevo si corresponde.
                  if (dni != _choferDni) {
                    _adelantoAsociadoId = null;
                  }
                  _choferDni = dni;
                  _choferNombre = nombre;
                  _vehiculoCtrl.text = vehiculo ?? '';
                  _engancheCtrl.text = enganche ?? '';
                });
                _programarGuardadoBorrador();
                // _sugerirAdelantoUltimoViaje removido el 2026-05-13:
                // los adelantos ya no viven en el viaje, así que no
                // tiene sentido sugerir el adelanto del último viaje.
              },
            ),
            const SizedBox(height: 12),
            _SeccionUnidad(
              vehiculoCtrl: _vehiculoCtrl,
              engancheCtrl: _engancheCtrl,
              onChanged: () {
                setState(() {});
                _programarGuardadoBorrador();
              },
            ),
            const SizedBox(height: 12),

            // 4. ADELANTO ASOCIADO (opcional). Si el operador ya
            // creó un adelanto antes de armar el viaje (caso típico:
            // le pagó al chofer en mano y después arma el viaje al
            // que pertenece), lo elige acá. La sección de ALTA de
            // adelantos sigue viviendo en `LogisticaAdelantosScreen`
            // — esto es solo ASOCIACIÓN.
            _SeccionAdelantoAsociado(
              choferDni: _choferDni,
              viajeIdActual: widget.viajeId,
              adelantoSeleccionadoId: _adelantoAsociadoId,
              onChanged: (id) {
                setState(() => _adelantoAsociadoId = id);
                _programarGuardadoBorrador();
              },
            ),
            const SizedBox(height: 12),

            // GASTOS EXTRAORDINARIOS: removidos del nivel viaje el
            // 2026-05-13. Cada tramo ahora carga sus propios gastos
            // (peajes, lavado, etc.) en su propia `_SeccionGastos`
            // dentro de la card del tramo. La sección viaje-level
            // que estaba acá se eliminó.

            // 5. TRAMOS (uno o varios — cada uno con sus gastos).
            ..._tramos.asMap().entries.expand((entry) {
              final index = entry.key;
              final tramo = entry.value;
              // Banners entre tramos: encadenamiento de ubicaciones +
              // fechas cronológicas. Ambos son WARNINGs, NO bloquean
              // — el operador puede ignorarlos (caso "el tractor pasó
              // por la base entre tramos" o "fechas se cargan después").
              final widgets = <Widget>[];
              if (index > 0) {
                final prev = _tramos[index - 1];
                final wEnc = _validarEncadenamiento(prev, tramo);
                if (wEnc != null) {
                  widgets.add(_BannerEncadenamiento(mensaje: wEnc));
                }
                final wFechas = _validarFechasEntreTramos(prev, tramo);
                if (wFechas != null) {
                  widgets.add(_BannerEncadenamiento(mensaje: wFechas));
                }
              }
              widgets.add(Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _TramoCard(
                  key: ValueKey(tramo.id),
                  numero: index + 1,
                  state: tramo,
                  warningFechasInternas: _validarFechasInternasTramo(tramo),
                  puedeEliminar: _tramos.length > 1,
                  onEliminar: () {
                    _eliminarTramo(index);
                    _programarGuardadoBorrador();
                  },
                  onCambio: () {
                    setState(() {});
                    _programarGuardadoBorrador();
                  },
                ),
              ));
              return widgets;
            }),
            _BotonAgregarTramo(onPressed: () {
              _agregarTramo();
              _programarGuardadoBorrador();
            }),
            const SizedBox(height: 24),

            _BotonesGuardar(
              guardando: _guardando,
              onGuardar: _guardar,
              onCancelar: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }
}
