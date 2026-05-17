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
  /// Controller del campo "producto libre" — solo se usa cuando la
  /// empresa origen NO tiene productos catalogados (fallback). Vive
  /// en el state del tramo (no se recrea en cada build) para no
  /// perder el foco al tipear.
  final TextEditingController productoLibreCtrl;
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

  /// Gastos extraordinarios del tramo (peajes, lavado, viáticos, etc.)
  /// — desde 2026-05-13 viven por tramo, no por viaje.
  List<GastoViaje> gastos;

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
    List<GastoViaje>? gastos,
  })  : productoLibreCtrl = TextEditingController(text: producto ?? ''),
        descripcionCargaCtrl =
            TextEditingController(text: descripcionCarga ?? ''),
        kgCargadosCtrl = TextEditingController(text: kgCargados ?? ''),
        remitoNumeroCtrl = TextEditingController(text: remitoNumero ?? ''),
        kgDescargadosCtrl = TextEditingController(text: kgDescargados ?? ''),
        gastos = gastos ?? [];

  factory _TramoEditState.vacio() {
    return _TramoEditState._(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
    );
  }

  // `cloneFrom` se quitó 2026-05-14 junto con el botón "duplicar tramo"
  // (ver _TramoCard). Si vuelve a necesitarse, copiaba: tarifa, producto
  // y descripcionCarga — fechas/kg/remito quedaban vacíos.

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
      gastos: List.of(t.gastos),
    );
  }

  void dispose() {
    productoLibreCtrl.dispose();
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
      gastos: List.of(gastos),
    );
  }
}

// =============================================================================
// _TramoCard — un tramo en el form (card con todos sus campos)
// =============================================================================

class _TramoCard extends StatelessWidget {
  final int numero;
  final _TramoEditState state;
  /// Mensaje de warning sobre las fechas del propio tramo (descarga
  /// anterior a carga). Null si no hay problema. Calculado por el
  /// padre, no por este widget — así el padre puede usar la misma
  /// función al guardar para mostrar un resumen.
  final String? warningFechasInternas;
  final bool puedeEliminar;
  final VoidCallback onEliminar;
  final VoidCallback onCambio;

  const _TramoCard({
    super.key,
    required this.numero,
    required this.state,
    required this.warningFechasInternas,
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
      // Botones "↑ ↓ duplicar" del header se quitaron 2026-05-14 por
      // pedido de Santiago — innecesarios en la práctica. Queda solo
      // el "eliminar" para el caso de tramo sobrante.
      trailing: puedeEliminar
          ? IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: AppColors.accentRed, size: 18),
              onPressed: onEliminar,
              tooltip: 'Eliminar tramo',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(6),
            )
          : null,
      children: [
        // Warning de fechas internas (descarga < carga). Lo ponemos
        // arriba del todo así el operador lo ve al volver a revisar
        // el tramo. Es NO bloqueante — el guardado igual procede.
        if (warningFechasInternas != null)
          _BannerEncadenamiento(mensaje: warningFechasInternas!),
        // Tarifa. Antes era un DropdownButtonFormField simple — con el
        // catálogo creciendo se volvió impráctico (Santiago 2026-05-13:
        // "hay muchas tarifas creadas"). Ahora es un campo tappeable
        // que abre un modal sheet con buscador token-based filtrando
        // por empresas, ubicaciones y dador, mismo patrón que la
        // lista de tarifas.
        InkWell(
          onTap: () async {
            final elegida = await _abrirSelectorTarifa(
              context,
              tarifaActual: tarifa,
            );
            if (elegida == null) return;
            state.tarifa = elegida;
            // Si cambió la tarifa, reseteamos el producto (porque
            // viene de empresa origen distinta).
            state.producto = null;
            onCambio();
          },
          borderRadius: BorderRadius.circular(4),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Tarifa',
              border: const OutlineInputBorder(),
              suffixIcon: Icon(
                tarifa == null ? Icons.search : Icons.edit_outlined,
                size: 20,
              ),
            ),
            isEmpty: tarifa == null,
            child: tarifa == null
                ? null
                : Text(
                    '${tarifa.ubicacionOrigenEtiqueta} → '
                    '${tarifa.ubicacionDestinoEtiqueta} '
                    '(${tarifa.unidadTarifa.etiqueta})',
                    style: const TextStyle(color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
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
        // Si la empresa NO tiene productos catalogados, cae a texto
        // libre usando `productoLibreCtrl` (persistente del tramo).
        _DropdownProducto(
          empresaOrigenId: tarifa?.empresaOrigenId,
          valor: state.producto,
          libreCtrl: state.productoLibreCtrl,
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
          onChanged: (_) => onCambio(),
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
          onChanged: (_) => onCambio(),
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

        // ─── Gastos extraordinarios DEL TRAMO ─────────────────────
        // Cada tramo tiene sus propios gastos (refactor 2026-05-13).
        // Antes vivían a nivel viaje pero un viaje multi-tramo tiene
        // peajes / lavados distintos por tramo, así que se separan.
        const SizedBox(height: 16),
        _SeccionGastos(
          gastos: state.gastos,
          onChanged: (l) {
            state.gastos = l;
            onCambio();
          },
          enmarcadoComoSubseccion: true,
        ),
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

/// Banner amarillo que avisa cuando el origen de un tramo no encadena
/// con el destino del anterior. NO bloquea — es un warning informativo
/// (hay casos legítimos: el tractor pasa por la base entre tramos).
/// Visualmente se inserta ENTRE dos cards de tramo.
class _BannerEncadenamiento extends StatelessWidget {
  final String mensaje;
  const _BannerEncadenamiento({required this.mensaje});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.accentAmber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: AppColors.accentAmber.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_outlined,
              size: 18, color: AppColors.accentAmber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              mensaje,
              style: const TextStyle(
                color: AppColors.accentAmber,
                fontSize: 12,
              ),
            ),
          ),
        ],
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
  /// Controller para el fallback de texto libre (cuando la empresa
  /// origen no tiene productos catalogados). Debe vivir en el state
  /// del padre — si se crea acá en cada build, se pierde el foco al
  /// tipear (cada keystroke triggerea setState).
  final TextEditingController libreCtrl;
  final ValueChanged<String?> onChanged;

  const _DropdownProducto({
    required this.empresaOrigenId,
    required this.valor,
    required this.libreCtrl,
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
          // para no bloquear al operador. El controller viene de
          // afuera (persistente) para no perder foco en cada keystroke.
          return TextField(
            controller: libreCtrl,
            decoration: const InputDecoration(
              labelText: 'Producto (libre — la empresa no tiene catálogo)',
              border: OutlineInputBorder(),
            ),
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
            label: 'Facturado a empresa',
            valor: '\$${AppFormatters.formatearMonto(montos!.montoVecchi)}',
          ),
          _LineaResumen(
            label:
                'Comisión chofer (${montos!.comisionChoferPct.toStringAsFixed(0)}%)',
            valor: '\$${AppFormatters.formatearMonto(montos!.montoChofer)}',
          ),
          _LineaResumen(
            label: 'Comisión chofer (redondeada)',
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
  /// Hook genérico para auto-save del borrador. Se invoca cuando
  /// cambia algún campo "menor" (texto del motivo) que no tiene
  /// callback dedicado pero igual queremos persistirlo.
  final VoidCallback onCambio;

  const _SeccionEstado({
    required this.estado,
    required this.motivoCtrl,
    required this.fechaPostergadoA,
    required this.onEstadoChanged,
    required this.onFechaChanged,
    required this.onCambio,
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
        // Estados removidos 2026-05-14 (Santiago): "cancelado" y
        // "postergado". Si querés cancelar un viaje, ahora lo borrás
        // (soft-delete con motivo). Postergar = se queda en planeado
        // hasta que se haga.
      ],
    );
  }
}

/// Selector de chofer con autocomplete (type-ahead). El operador
/// tipea cualquier subcadena del nombre (ej. "PER" → PEREZ JUAN, etc.)
/// y la lista se filtra en vivo. Reemplazó al `DropdownButtonFormField`
/// el 2026-05-14 (Santiago: "tendría que tener un sistema donde vaya
/// filtrando a medida que voy apretando las letras del nombre").
///
/// Stateful porque necesitamos manejar nuestro propio TextEditingController
/// + FocusNode para:
/// 1. Pre-cargar el nombre del chofer en modo edición.
/// 2. Sincronizar el texto si `widget.nombre` cambia desde fuera (carga
///    async del viaje).
/// 3. Revertir el texto del field si el operador tipea algo y se va sin
///    seleccionar — evita texto huérfano que no corresponde al chofer
///    realmente asignado.
class _SeccionChofer extends StatefulWidget {
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
  State<_SeccionChofer> createState() => _SeccionChoferState();
}

class _SeccionChoferState extends State<_SeccionChofer> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.nombre ?? '');
    _focusNode = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _SeccionChofer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Caso típico: el form arrancó con `nombre = null` (alta o aún no
    // se cargó el doc del viaje), después llega async y hay que sync
    // el field. Solo lo hacemos si el field NO tiene foco — sino el
    // operador estaría tipeando y le interrumpiríamos.
    if (oldWidget.nombre != widget.nombre && !_focusNode.hasFocus) {
      _controller.text = widget.nombre ?? '';
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) {
      // Si tipearon algo y se fueron sin seleccionar, restauramos el
      // valor confirmado (evita inconsistencia visual: el field mostrando
      // "PER" cuando en realidad está asignado "GARCIA MARIA").
      final esperado = widget.nombre ?? '';
      if (_controller.text != esperado) {
        _controller.text = esperado;
      }
    }
  }

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
            // Orden alfabético por NOMBRE (case-insensitive). Client-side
            // para evitar tener que crear índice compuesto (ROL + NOMBRE)
            // en Firestore — son ~50 choferes, el sort es instantáneo.
            final docs = List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(
              snap.data?.docs ?? const [],
            )..sort((a, b) {
                final na = (a.data()['NOMBRE'] ?? '').toString().toUpperCase();
                final nb = (b.data()['NOMBRE'] ?? '').toString().toUpperCase();
                return na.compareTo(nb);
              });

            return RawAutocomplete<QueryDocumentSnapshot<Map<String, dynamic>>>(
              textEditingController: _controller,
              focusNode: _focusNode,
              displayStringForOption: (d) =>
                  (d.data()['NOMBRE'] ?? '').toString(),
              optionsBuilder: (value) {
                final q = value.text.trim().toUpperCase();
                if (q.isEmpty) return docs;
                // Match por subcadena en cualquier lugar del nombre
                // ("PER" matchea "PEREZ" y "ALPER", "GAR" matchea
                // "GARCIA" y "FERNANDEZ GARCIA", etc.).
                return docs.where((d) {
                  final n = (d.data()['NOMBRE'] ?? '').toString().toUpperCase();
                  return n.contains(q);
                });
              },
              onSelected: (d) {
                final data = d.data();
                final dn = (data['DNI'] ?? d.id).toString();
                widget.onChanged(
                  dn,
                  (data['NOMBRE'] ?? dn).toString(),
                  data['VEHICULO']?.toString(),
                  data['ENGANCHE']?.toString(),
                );
                // Quitamos foco para que el listener acomode el texto
                // si hace falta (en este caso ya quedó bien por la
                // selección, pero también dispara la lógica del padre
                // que pasa al próximo campo).
                _focusNode.unfocus();
              },
              fieldViewBuilder: (ctx, ctrl, fn, onSubmit) {
                return TextField(
                  controller: ctrl,
                  focusNode: fn,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: 'Chofer',
                    hintText: 'Tipeá para filtrar (ej. PEREZ)',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    border: const OutlineInputBorder(),
                    suffixIcon: ctrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            tooltip: 'Limpiar',
                            onPressed: () {
                              ctrl.clear();
                              fn.requestFocus();
                            },
                          ),
                  ),
                );
              },
              optionsViewBuilder: (ctx, onSel, options) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 6,
                    color: Theme.of(context).colorScheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: Colors.white.withAlpha(20)),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 280,
                        maxWidth: 360,
                      ),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (ctx, idx) {
                          final d = options.elementAt(idx);
                          final data = d.data();
                          final nom = (data['NOMBRE'] ?? '').toString();
                          final esActual =
                              (data['DNI'] ?? d.id).toString() == widget.dni;
                          return InkWell(
                            onTap: () => onSel(d),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              child: Row(
                                children: [
                                  Icon(
                                    esActual
                                        ? Icons.check_circle
                                        : Icons.person_outline,
                                    size: 16,
                                    color: esActual
                                        ? AppColors.accentGreen
                                        : Colors.white54,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      nom,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
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
    // Formatter que solo permite letras+digitos, hace UPPER y quita
    // espacios/guiones — para que la patente quede normalizada al
    // formato canonico (UPPERCASE sin separadores) que matchea las
    // queries a SITRACK_POSICIONES / VOLVO_ALERTAS / VEHICULOS.
    // (auditoria 2026-05-17: antes aceptaba "ab-123-cd" → no matcheaba.)
    final patenteFormatter = FilteringTextInputFormatter.allow(
      RegExp(r'[A-Za-z0-9]'),
    );
    return _SeccionCard(
      titulo: 'UNIDAD',
      icono: Icons.local_shipping_outlined,
      children: [
        TextField(
          controller: vehiculoCtrl,
          decoration: const InputDecoration(
            labelText: 'Patente tractor',
            border: OutlineInputBorder(),
            hintText: 'AB123CD o ABC123',
          ),
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [patenteFormatter, _UpperCaseFormatter()],
          maxLength: 7,
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: engancheCtrl,
          decoration: const InputDecoration(
            labelText: 'Patente enganche',
            border: OutlineInputBorder(),
            hintText: 'AB123CD o ABC123',
          ),
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [patenteFormatter, _UpperCaseFormatter()],
          maxLength: 7,
          onChanged: (_) => onChanged(),
        ),
      ],
    );
  }
}

/// Formatter que fuerza UPPERCASE en cada keystroke. Necesario porque
/// `textCapitalization: TextCapitalization.characters` solo aplica al
/// teclado mobile — en desktop / paste no convierte.
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}

// `_SeccionAdelanto` (alta inline) removida del form de viaje el
// 2026-05-13. Los adelantos pasaron a ser entidad propia
// (`ADELANTOS_CHOFER`) con su propia pantalla. El operador crea el
// adelanto desde LOGÍSTICA → ADELANTOS y, opcionalmente, lo ASOCIA al
// viaje desde la sección `_SeccionAdelantoAsociado` (dropdown).

/// Dropdown para ASOCIAR un adelanto preexistente al viaje. Muestra:
///   - "(sin adelanto asociado)" como opción default.
///   - Cada adelanto del chofer seleccionado que esté libre (sin
///     `viaje_id`) O que ya esté asociado a ESTE viaje (modo edición).
///
/// Si todavía no se eligió chofer, se muestra un mensaje pidiendo
/// que se seleccione uno primero — los adelantos viven por DNI, no
/// tiene sentido listar.
///
/// La sección NO permite crear adelantos nuevos. Si el operador
/// quiere un adelanto que todavía no existe, lo crea desde
/// `LogisticaAdelantosScreen` y vuelve a este form.
class _SeccionAdelantoAsociado extends StatelessWidget {
  final String? choferDni;
  /// Si es edición, traemos los adelantos ya asociados a este viaje
  /// además de los libres. Null en modo alta.
  final String? viajeIdActual;
  final String? adelantoSeleccionadoId;
  final ValueChanged<String?> onChanged;

  const _SeccionAdelantoAsociado({
    required this.choferDni,
    required this.viajeIdActual,
    required this.adelantoSeleccionadoId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _SeccionCard(
      titulo: 'ADELANTO ASOCIADO (OPCIONAL)',
      icono: Icons.payments_outlined,
      children: [
        if (choferDni == null || choferDni!.isEmpty)
          const Text(
            'Seleccioná un chofer primero — los adelantos viven por chofer.',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          )
        else
          StreamBuilder<List<AdelantoChofer>>(
            stream: AdelantosService.streamAdelantosPorChofer(choferDni!),
            builder: (ctx, snap) {
              if (snap.hasError) {
                return Text(
                  'Error cargando adelantos: ${snap.error}',
                  style: const TextStyle(
                      color: AppColors.accentRed, fontSize: 12),
                );
              }
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(minHeight: 2),
                );
              }
              // Filtro client-side: adelantos sin viaje O ya
              // asociados a ESTE viaje. Los asociados a otro viaje
              // se excluyen — no queremos robarle el adelanto a otro
              // viaje sin querer.
              final candidatos = snap.data!
                  .where((a) =>
                      a.viajeId == null ||
                      a.viajeId!.isEmpty ||
                      a.viajeId == viajeIdActual)
                  .toList();
              if (candidatos.isEmpty) {
                return const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'No hay adelantos libres de este chofer.',
                      style:
                          TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Si necesitás crear uno, andá a LOGÍSTICA → '
                      'ADELANTOS y volvé.',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                );
              }
              return DropdownButtonFormField<String?>(
                initialValue: adelantoSeleccionadoId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Adelanto del chofer',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('(sin adelanto asociado)'),
                  ),
                  ...candidatos.map((a) {
                    final fecha = AppFormatters.formatearFecha(a.fecha);
                    final monto = AppFormatters.formatearMonto(a.monto);
                    final medio = a.medioPago.etiqueta;
                    final obs = a.observacion?.trim().isNotEmpty == true
                        ? ' · ${a.observacion!.trim()}'
                        : '';
                    return DropdownMenuItem<String?>(
                      value: a.id,
                      child: Text(
                        '$fecha · \$ $monto · $medio$obs',
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }),
                ],
                onChanged: onChanged,
              );
            },
          ),
      ],
    );
  }
}

class _SeccionGastos extends StatelessWidget {
  final List<GastoViaje> gastos;
  final ValueChanged<List<GastoViaje>> onChanged;
  /// Si verdadero, el widget se renderea como sub-bloque inline (sin
  /// el chrome de `_SeccionCard` con título + ícono propios). Usado
  /// cuando la sección va ADENTRO de la card de un tramo — no
  /// queremos un card-dentro-de-card. Default `false` (compat con
  /// otros sitios que pudieran usar `_SeccionGastos` aislado).
  final bool enmarcadoComoSubseccion;

  const _SeccionGastos({
    required this.gastos,
    required this.onChanged,
    this.enmarcadoComoSubseccion = false,
  });

  Future<void> _agregar(BuildContext context) async {
    final montoCtrl = TextEditingController();
    final detalleCtrl = TextEditingController();
    DateTime fecha = DateTime.now();
    bool ok = false;
    try {
      ok = (await showDialog<bool>(
            context: context,
            builder: (dCtx) => _buildAgregarGastoDialog(
              dCtx, montoCtrl, detalleCtrl, fecha, (d) => fecha = d,
            ),
          )) ??
          false;
    } finally {
      // Dispose controllers SIEMPRE — auditoria 2026-05-17, antes leaks
      // de 2 controllers por dialog cancelado.
      montoCtrl.dispose();
      detalleCtrl.dispose();
    }
    if (ok) {
      final monto = AppFormatters.parsearMiles(montoCtrl.text)?.toDouble() ?? 0;
      // NOTA: montoCtrl ya fue disposed arriba pero su .text es String
      // (no requiere el ctrl vivo). Lo mismo detalleCtrl.text abajo.
      if (monto <= 0) return;
      const capGasto = 1000000;
      if (monto > capGasto) {
        if (!context.mounted) return;
        AppFeedback.errorOn(
          ScaffoldMessenger.of(context),
          'Gasto excesivo (max ${AppFormatters.formatearMonto(capGasto)}).',
        );
        return;
      }
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

  Widget _buildAgregarGastoDialog(
    BuildContext dCtx,
    TextEditingController montoCtrl,
    TextEditingController detalleCtrl,
    DateTime fecha,
    void Function(DateTime) onFechaChange,
  ) {
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
              onChanged: (d) {
                if (d != null) {
                  setStateDialog(() {
                    onFechaChange(d);
                  });
                }
              },
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
  }

  // (Implementacion legacy de _agregar con leak de controllers
  // eliminada 2026-05-17 — ver `_agregar` arriba con dispose correcto.)

  @override
  Widget build(BuildContext context) {
    final total = gastos.fold<double>(0, (a, g) => a + g.monto);
    final children = <Widget>[
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
              'Total gastos del tramo',
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
    ];
    if (enmarcadoComoSubseccion) {
      // Inline dentro de la card del tramo: solo título chico +
      // contenido. Sin card propia para no anidar.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SubseccionTitulo('GASTOS EXTRAORDINARIOS'),
          const SizedBox(height: 8),
          ...children,
        ],
      );
    }
    // Compat — si en algún lugar se usa standalone, queda como antes.
    return _SeccionCard(
      titulo: 'GASTOS EXTRAORDINARIOS',
      icono: Icons.receipt_long_outlined,
      children: children,
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
    // Si la tarifa todavía no tiene monto cargado (caso típico:
    // operador armó la tarifa con $0 porque no se sabía y la va a
    // editar después), avisamos en ámbar — el viaje se puede crear
    // igual, los cálculos van a dar 0 y se actualizan cuando se
    // edite la tarifa + se vuelva a guardar el viaje.
    final sinMonto = t.tarifaReal == 0 || t.tarifaChofer == 0;
    final color = sinMonto ? AppColors.accentAmber : AppColors.accentGreen;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
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
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (sinMonto) ...[
            const SizedBox(height: 4),
            const Row(
              children: [
                Icon(Icons.warning_amber_outlined,
                    size: 14, color: AppColors.accentAmber),
                SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Tarifa pendiente de definir — actualizá la tarifa '
                    'y volvé a guardar el viaje cuando sepas el monto.',
                    style: TextStyle(
                      color: AppColors.accentAmber,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ],
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

// =============================================================================
// SELECTOR DE TARIFA con buscador
// =============================================================================

/// Abre un modal sheet con buscador para elegir tarifa. Lo usa
/// `_TramoCard` cuando el operador toca el campo "Tarifa" del tramo.
/// El selector reemplazó al `DropdownButtonFormField` simple a partir
/// del 2026-05-13 — con > 30 tarifas el dropdown se volvía
/// impráctico (scroll infinito sin filtro).
///
/// Devuelve la tarifa elegida o `null` si el operador cerró el sheet
/// sin elegir.
Future<TarifaLogistica?> _abrirSelectorTarifa(
  BuildContext context, {
  required TarifaLogistica? tarifaActual,
}) {
  return showModalBottomSheet<TarifaLogistica>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _TarifaPickerSheet(tarifaActualId: tarifaActual?.id),
  );
}

/// Sheet con TextField de búsqueda + lista filtrada de tarifas
/// activas. El filtro es token-based (case-insensitive) contra
/// empresa origen / destino, ubicación origen / destino, dador.
/// Mismo patrón que la pantalla `LogisticaTarifasScreen`.
class _TarifaPickerSheet extends StatefulWidget {
  /// Si está seteado, el item correspondiente se marca con un check
  /// para que el operador sepa cuál ya tiene elegido.
  final String? tarifaActualId;
  const _TarifaPickerSheet({required this.tarifaActualId});

  @override
  State<_TarifaPickerSheet> createState() => _TarifaPickerSheetState();
}

class _TarifaPickerSheetState extends State<_TarifaPickerSheet> {
  final _ctrl = TextEditingController();
  String _filtro = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<TarifaLogistica> _aplicarFiltro(List<TarifaLogistica> tarifas) {
    if (_filtro.trim().isEmpty) return tarifas;
    final f = _filtro.trim().toUpperCase();
    return tarifas.where((t) {
      return t.empresaOrigenNombre.toUpperCase().contains(f) ||
          t.empresaDestinoNombre.toUpperCase().contains(f) ||
          t.ubicacionOrigenEtiqueta.toUpperCase().contains(f) ||
          t.ubicacionDestinoEtiqueta.toUpperCase().contains(f) ||
          (t.dadorNombre?.toUpperCase().contains(f) ?? false) ||
          (t.producto?.toUpperCase().contains(f) ?? false);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    // El sheet ocupa hasta ~80% de la pantalla. El `viewInsets` del
    // bottom evita que el teclado tape el campo de búsqueda en
    // mobile.
    final media = MediaQuery.of(context);
    final altoMax = media.size.height * 0.85;
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: altoMax),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle visual del sheet.
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'ELEGIR TARIFA',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
            ),
            // Buscador.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: 'Buscar por empresa, ubicación, dador, producto…',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  suffixIcon: _filtro.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _ctrl.clear();
                            setState(() => _filtro = '');
                          },
                        ),
                ),
                onChanged: (v) => setState(() => _filtro = v),
              ),
            ),
            // Lista de tarifas filtrada.
            Expanded(
              child: StreamBuilder<List<TarifaLogistica>>(
                stream: LogisticaService.streamTarifas(soloActivas: true),
                builder: (ctx, snap) {
                  if (snap.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Error: ${snap.error}',
                          style: const TextStyle(color: AppColors.accentRed),
                        ),
                      ),
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final filtradas = _aplicarFiltro(snap.data!);
                  if (filtradas.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _filtro.isEmpty
                              ? 'No hay tarifas activas cargadas.'
                              : 'Sin coincidencias con "$_filtro".',
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    itemCount: filtradas.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: Colors.white12),
                    itemBuilder: (_, i) {
                      final t = filtradas[i];
                      final esActual = t.id == widget.tarifaActualId;
                      return _ItemTarifaPicker(
                        tarifa: t,
                        esActual: esActual,
                        onTap: () => Navigator.of(context).pop(t),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Item del listado de tarifas en el picker. Muestra la ruta + dador
/// + tarifas (real / chofer) + producto, con look compacto pero
/// legible. Si es la tarifa ya elegida actualmente, se marca con
/// un check verde.
class _ItemTarifaPicker extends StatelessWidget {
  final TarifaLogistica tarifa;
  final bool esActual;
  final VoidCallback onTap;

  const _ItemTarifaPicker({
    required this.tarifa,
    required this.esActual,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final origen = tarifa.origenDisplay;
    final destino = tarifa.destinoDisplay;
    final unidad = tarifa.unidadTarifa.etiqueta;
    final sufijo = tarifa.unidadTarifa.sufijoMonto;
    final montoReal = AppFormatters.formatearMonto(tarifa.tarifaReal);
    final montoChofer = AppFormatters.formatearMonto(tarifa.tarifaChofer);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$origen → $destino',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$unidad · Vecchi \$ $montoReal$sufijo · Chofer \$ $montoChofer$sufijo',
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (tarifa.dadorNombre?.isNotEmpty == true ||
                      tarifa.producto?.isNotEmpty == true) ...[
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (tarifa.dadorNombre?.isNotEmpty == true)
                          'Dador: ${tarifa.dadorNombre}',
                        if (tarifa.producto?.isNotEmpty == true)
                          'Producto: ${tarifa.producto}',
                      ].join(' · '),
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (esActual)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.check_circle,
                    color: AppColors.accentGreen, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}
