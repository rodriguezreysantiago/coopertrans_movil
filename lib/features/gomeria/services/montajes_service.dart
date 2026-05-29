import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../constants/posiciones.dart';
import '../models/montaje.dart';
import '../models/stock_movimiento.dart';

/// Error de negocio del flujo de montajes (posición ocupada, tipo de uso
/// incompatible, sin stock, etc.). La UI lo muestra como mensaje al gomero.
class MontajeException implements Exception {
  final String mensaje;
  MontajeException(this.mensaje);
  @override
  String toString() => mensaje;
}

/// Servicio del modelo NUEVO de gomería (rediseño 2026-05-29): cubiertas por
/// posición + km + marca, stock por cantidades. NO serializa cubiertas
/// individuales y NO usa `runTransaction` (prohibido en Windows — ver
/// `feedback_windows_cloud_firestore_bugs`). La unicidad de posición se
/// garantiza con un lock cuya rule es `allow update: if false`: un `set`
/// sobre un lock existente rebota con permission-denied en producción. Acá
/// además chequeamos en código (cubre el caso 1-supervisor y los tests).
///
/// Coexiste con `GomeriaService` (viejo, serializado) hasta migrar.
class MontajesService {
  final FirebaseFirestore _db;

  MontajesService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  static String _posLockId(String unidadId, String posicion) =>
      '${unidadId}__$posicion';

  CollectionReference<Map<String, dynamic>> get _montajes =>
      _db.collection(AppCollections.gomeriaMontajes);
  CollectionReference<Map<String, dynamic>> get _movs =>
      _db.collection(AppCollections.gomeriaStockMovimientos);
  CollectionReference<Map<String, dynamic>> get _locks =>
      _db.collection(AppCollections.gomeriaPosicionesActivas);

  // ===========================================================================
  // STOCK
  // ===========================================================================

  /// Registra una compra: `cantidad` cubiertas NUEVAS (vida 1) entran al
  /// depósito. Emite un movimiento `compra` con `delta = +cantidad`.
  Future<void> comprar({
    required String modeloId,
    required String modeloEtiqueta,
    int cantidad = 1,
    required String supervisorDni,
    String? supervisorNombre,
    String? motivo,
  }) async {
    if (cantidad <= 0) {
      throw MontajeException('La cantidad a comprar debe ser mayor a 0.');
    }
    await _emitirMovimiento(
      tipo: TipoMovimientoStock.compra,
      modeloId: modeloId,
      modeloEtiqueta: modeloEtiqueta,
      vida: 1,
      delta: cantidad,
      supervisorDni: supervisorDni,
      supervisorNombre: supervisorNombre,
      motivo: motivo,
    );
  }

  /// Stock actual por SKU (modelo+vida), calculado de todos los movimientos.
  Future<List<StockItem>> stockActual() async {
    final snap = await _movs.get();
    final movs =
        snap.docs.map((d) => StockMovimiento.fromMap(d.id, d.data())).toList();
    return calcularStock(movs);
  }

  /// Cantidad disponible en depósito de un SKU específico.
  Future<int> stockDisponible({
    required String modeloId,
    required int vida,
  }) async {
    final snap = await _movs.where('modelo_id', isEqualTo: modeloId).get();
    var total = 0;
    for (final d in snap.docs) {
      final m = StockMovimiento.fromMap(d.id, d.data());
      if (m.vida == vida) total += m.delta;
    }
    return total;
  }

  Future<void> _emitirMovimiento({
    required TipoMovimientoStock tipo,
    required String modeloId,
    required String modeloEtiqueta,
    required int vida,
    required int delta,
    required String supervisorDni,
    String? supervisorNombre,
    String? motivo,
    String? refUnidad,
    String? refPosicion,
  }) async {
    final mov = StockMovimiento(
      id: '',
      tipo: tipo,
      modeloId: modeloId,
      modeloEtiqueta: modeloEtiqueta,
      vida: vida,
      delta: delta,
      fecha: DateTime.now(),
      responsableDni: supervisorDni,
      responsableNombre: supervisorNombre,
      motivo: motivo,
      refUnidad: refUnidad,
      refPosicion: refPosicion,
    );
    await _movs.add(mov.toMap());
  }

  /// Ajuste por INVENTARIO FÍSICO (control anti-robo). El gomero contó
  /// `cantidadFisica` cubiertas de un SKU; comparamos con el stock teórico y,
  /// si difieren, emitimos un movimiento `ajuste` con el delta. Devuelve la
  /// diferencia (física − teórica): negativa = faltante, positiva = sobrante.
  Future<int> ajustarInventario({
    required String modeloId,
    required String modeloEtiqueta,
    required int vida,
    required int cantidadFisica,
    required String supervisorDni,
    String? supervisorNombre,
  }) async {
    if (cantidadFisica < 0) {
      throw MontajeException('La cantidad contada no puede ser negativa.');
    }
    final teorico = await stockDisponible(modeloId: modeloId, vida: vida);
    final delta = cantidadFisica - teorico;
    if (delta != 0) {
      await _emitirMovimiento(
        tipo: TipoMovimientoStock.ajuste,
        modeloId: modeloId,
        modeloEtiqueta: modeloEtiqueta,
        vida: vida,
        delta: delta,
        supervisorDni: supervisorDni,
        supervisorNombre: supervisorNombre,
        motivo: 'Inventario físico: contado $cantidadFisica, teórico $teorico',
      );
    }
    return delta;
  }

  /// Da de baja `cantidad` cubiertas del depósito (sin pasar por una posición).
  Future<void> descartarDeDeposito({
    required String modeloId,
    required String modeloEtiqueta,
    required int vida,
    int cantidad = 1,
    required String supervisorDni,
    String? supervisorNombre,
    String? motivo,
  }) async {
    await _salidaDeposito(
      tipo: TipoMovimientoStock.descarte,
      modeloId: modeloId,
      modeloEtiqueta: modeloEtiqueta,
      vida: vida,
      cantidad: cantidad,
      supervisorDni: supervisorDni,
      supervisorNombre: supervisorNombre,
      motivo: motivo,
    );
  }

  /// Manda `cantidad` cubiertas del depósito al proveedor a recapar (salen
  /// del stock). Vuelven con [recibirDeRecapado].
  Future<void> mandarARecapar({
    required String modeloId,
    required String modeloEtiqueta,
    required int vida,
    int cantidad = 1,
    required String supervisorDni,
    String? supervisorNombre,
    String? motivo,
  }) async {
    await _salidaDeposito(
      tipo: TipoMovimientoStock.aRecapado,
      modeloId: modeloId,
      modeloEtiqueta: modeloEtiqueta,
      vida: vida,
      cantidad: cantidad,
      supervisorDni: supervisorDni,
      supervisorNombre: supervisorNombre,
      motivo: motivo,
    );
  }

  /// Recibe cubiertas del proveedor de recapado: `recibidas` vuelven al
  /// depósito con vida +1 (las descartadas por el proveedor no vuelven, no
  /// generan movimiento). `vidaPrevia` es la vida con la que se enviaron.
  Future<void> recibirDeRecapado({
    required String modeloId,
    required String modeloEtiqueta,
    required int vidaPrevia,
    required int recibidas,
    required String supervisorDni,
    String? supervisorNombre,
    String? motivo,
  }) async {
    if (recibidas < 0) {
      throw MontajeException('La cantidad recibida no puede ser negativa.');
    }
    if (recibidas == 0) return;
    await _emitirMovimiento(
      tipo: TipoMovimientoStock.deRecapado,
      modeloId: modeloId,
      modeloEtiqueta: modeloEtiqueta,
      vida: vidaPrevia + 1,
      delta: recibidas,
      supervisorDni: supervisorDni,
      supervisorNombre: supervisorNombre,
      motivo: motivo,
    );
  }

  /// Helper común de salidas del depósito (recapado / descarte): valida que
  /// haya stock suficiente y emite el movimiento negativo.
  Future<void> _salidaDeposito({
    required TipoMovimientoStock tipo,
    required String modeloId,
    required String modeloEtiqueta,
    required int vida,
    required int cantidad,
    required String supervisorDni,
    String? supervisorNombre,
    String? motivo,
  }) async {
    if (cantidad <= 0) {
      throw MontajeException('La cantidad debe ser mayor a 0.');
    }
    final disp = await stockDisponible(modeloId: modeloId, vida: vida);
    if (disp < cantidad) {
      throw MontajeException(
          'No hay stock suficiente de "$modeloEtiqueta": hay $disp, pedís $cantidad.');
    }
    await _emitirMovimiento(
      tipo: tipo,
      modeloId: modeloId,
      modeloEtiqueta: modeloEtiqueta,
      vida: vida,
      delta: -cantidad,
      supervisorDni: supervisorDni,
      supervisorNombre: supervisorNombre,
      motivo: motivo,
    );
  }

  // ===========================================================================
  // MONTAJES
  // ===========================================================================

  /// Monta una cubierta del depósito (modelo+vida) en una posición de una
  /// unidad. Valida posición libre + tipo de uso (STRICT) + stock disponible.
  /// Crea el lock de posición, el `Montaje` activo y descuenta el stock.
  /// Devuelve el id del montaje creado.
  Future<String> montar({
    required String unidadId,
    required TipoUnidadCubierta unidadTipo,
    required String posicion,
    required String modeloId,
    required String modeloEtiqueta,
    required TipoUsoCubierta tipoUso,
    int vida = 1,
    int? kmVidaEstimada,
    double? kmUnidadAlMontar,
    required String supervisorDni,
    String? supervisorNombre,
  }) async {
    // 1) Validar que la posición exista y sea del tipo de unidad correcto.
    final pos = posicionPorCodigo[posicion];
    if (pos == null) {
      throw MontajeException('Posición desconocida: $posicion');
    }
    if (pos.tipoUnidad != unidadTipo) {
      throw MontajeException(
          'La posición $posicion no pertenece a un ${unidadTipo.codigo}.');
    }
    // 2) Validación STRICT tipo de uso vs posición (decisión Santiago).
    if (pos.tipoUsoRequerido != tipoUso) {
      throw MontajeException(
          'No se puede montar una cubierta ${tipoUso.etiqueta} en una '
          'posición ${pos.tipoUsoRequerido.etiqueta}.');
    }
    // 3) Validar stock disponible del SKU.
    final disp = await stockDisponible(modeloId: modeloId, vida: vida);
    if (disp <= 0) {
      throw MontajeException(
          'No hay stock de "$modeloEtiqueta" ($vida=vida) en el depósito.');
    }
    // 4) Posición libre: el lock NO debe existir.
    final lockRef = _locks.doc(_posLockId(unidadId, posicion));
    final lockSnap = await lockRef.get();
    if (lockSnap.exists) {
      throw MontajeException(
          'La posición $posicion de $unidadId ya está ocupada.');
    }

    // 5) Crear el lock. En producción la rule `update: if false` garantiza
    //    que una carrera entre 2 clientes rebote acá.
    await lockRef.set({
      'unidad_id': unidadId,
      'posicion': posicion,
      'desde': FieldValue.serverTimestamp(),
    });

    // 6) Crear el montaje + descontar stock. Si algo falla, limpiamos el
    //    lock (best-effort) para no dejar la posición bloqueada.
    try {
      final montaje = Montaje(
        id: '',
        unidadId: unidadId,
        unidadTipo: unidadTipo,
        posicion: posicion,
        modeloId: modeloId,
        modeloEtiqueta: modeloEtiqueta,
        tipoUso: tipoUso,
        vida: vida,
        kmVidaEstimada: kmVidaEstimada,
        desde: DateTime.now(),
        hasta: null,
        kmUnidadAlMontar: kmUnidadAlMontar,
        kmUnidadAlRetirar: null,
        kmRecorridos: null,
        montadoPorDni: supervisorDni,
        montadoPorNombre: supervisorNombre,
        retiradoPorDni: null,
        retiradoPorNombre: null,
        motivoRetiro: null,
        destino: null,
      );
      final ref = await _montajes.add(montaje.toMapNuevo());

      await _emitirMovimiento(
        tipo: TipoMovimientoStock.montaje,
        modeloId: modeloId,
        modeloEtiqueta: modeloEtiqueta,
        vida: vida,
        delta: -1,
        supervisorDni: supervisorDni,
        supervisorNombre: supervisorNombre,
        refUnidad: unidadId,
        refPosicion: posicion,
      );
      return ref.id;
    } catch (e) {
      // Cleanup best-effort del lock para no dejar la posición trabada.
      try {
        await lockRef.delete();
      } catch (_) {/* nada que hacer */}
      rethrow;
    }
  }

  /// Retira la cubierta de un montaje activo. Cierra el montaje (con km y
  /// motivo), libera el lock de posición y, si el destino es el depósito,
  /// suma 1 al stock del SKU. Recapado/descarte no tocan el stock de
  /// depósito (la cubierta va directo del vehículo al proveedor/baja).
  Future<void> retirar({
    required String montajeId,
    required MotivoRetiro motivo,
    required DestinoRetiro destino,
    double? kmUnidadAlRetirar,
    double? kmRecorridos,
    required String supervisorDni,
    String? supervisorNombre,
  }) async {
    final ref = _montajes.doc(montajeId);
    final snap = await ref.get();
    if (!snap.exists) {
      throw MontajeException('El montaje $montajeId no existe.');
    }
    final montaje = Montaje.fromMap(snap.id, snap.data());
    if (!montaje.esActivo) {
      throw MontajeException('El montaje $montajeId ya estaba retirado.');
    }

    // Cerrar el montaje.
    await ref.update({
      'hasta': FieldValue.serverTimestamp(),
      'km_unidad_al_retirar': kmUnidadAlRetirar,
      'km_recorridos': kmRecorridos,
      'motivo_retiro': motivo.codigo,
      'destino': destino.codigo,
      'retirado_por_dni': supervisorDni,
      'retirado_por_nombre': supervisorNombre,
    });

    // Liberar el lock de posición.
    try {
      await _locks.doc(_posLockId(montaje.unidadId, montaje.posicion)).delete();
    } catch (_) {/* best-effort */}

    // Stock: solo el destino DEPÓSITO devuelve la cubierta al stock.
    if (destino == DestinoRetiro.deposito) {
      await _emitirMovimiento(
        tipo: TipoMovimientoStock.retiroADeposito,
        modeloId: montaje.modeloId,
        modeloEtiqueta: montaje.modeloEtiqueta,
        vida: montaje.vida,
        delta: 1,
        supervisorDni: supervisorDni,
        supervisorNombre: supervisorNombre,
        refUnidad: montaje.unidadId,
        refPosicion: montaje.posicion,
      );
    }
  }

  // ===========================================================================
  // LECTURA
  // ===========================================================================

  /// Montajes ACTIVOS (hasta == null) de una unidad — para pintar el esquema.
  Stream<List<Montaje>> streamMontajesActivosPorUnidad(String unidadId) {
    return _montajes
        .where('unidad_id', isEqualTo: unidadId)
        .where('hasta', isNull: true)
        .snapshots()
        .map((s) => s.docs.map((d) => Montaje.fromMap(d.id, d.data())).toList());
  }
}
