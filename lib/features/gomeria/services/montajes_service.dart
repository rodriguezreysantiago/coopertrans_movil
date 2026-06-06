import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/app_logger.dart';
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
  CollectionReference<Map<String, dynamic>> get _retirosLock =>
      _db.collection(AppCollections.gomeriaRetirosLock);

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

  /// Stock actual EN VIVO (para la UI de depósito).
  Stream<List<StockItem>> streamStock() {
    return _movs.snapshots().map((s) => calcularStock(
        s.docs.map((d) => StockMovimiento.fromMap(d.id, d.data())).toList()));
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

  /// Emite un movimiento de stock. Si se pasa [docId], usa un id
  /// DETERMINÍSTICO con `set` (en vez de `add`), de modo que reemitir el mismo
  /// movimiento (p.ej. dos retiros concurrentes del mismo montaje) produzca UN
  /// solo documento → el stock se ajusta una sola vez (idempotencia sin
  /// runTransaction). Sin [docId] usa `add` (id aleatorio, comportamiento de
  /// siempre para compras/ajustes/etc.).
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
    String? docId,
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
    if (docId != null) {
      await _movs.doc(docId).set(mov.toMap());
    } else {
      await _movs.add(mov.toMap());
    }
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
  ///
  /// DECISIÓN DELIBERADA (no es un bug): NO se valida `recibidas` contra cuánto
  /// se mandó a recapar. El stock se lleva por CANTIDADES, no por lotes: este
  /// servicio no rastrea "cuántas de vida N están afuera en el proveedor" ni
  /// liga envío↔retorno, y los retornos suelen ser PARCIALES y escalonados
  /// (vuelven 2 hoy, 1 la semana que viene). Un tope acá podría rebotar un
  /// retorno legítimo. La consistencia la da el conteo de inventario físico
  /// periódico (`ajustarInventario`), que es el control de verdad — mismo
  /// criterio que el resto del módulo. Si en el futuro se modela el recapado
  /// por lotes (saldo enviado por SKU), acá iría la validación contra ese saldo.
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
    // 2b) Regla de VIDA: algunas posiciones solo admiten cubiertas nuevas.
    //     (Vecchi 2026-06-05: en el enganche, las recapadas van SOLO en el
    //     primer eje; los ejes 2 y 3 solo nuevas.)
    if (!pos.permiteRecapada && vida >= 2) {
      throw MontajeException(
          'La posición ${pos.etiqueta} solo admite cubiertas NUEVAS '
          '(las recapadas van solo en el primer eje del enganche).');
    }
    // 3) Validar stock disponible del SKU.
    final disp = await stockDisponible(modeloId: modeloId, vida: vida);
    if (disp <= 0) {
      throw MontajeException(
          'No hay stock de "$modeloEtiqueta" (vida $vida) en el depósito.');
    }
    // 4) Posición libre: el lock NO debe existir. Si existe, verificamos que
    //    de verdad haya un montaje activo en esa unidad+posición. Si el lock
    //    está HUÉRFANO (quedó de un retirar/rotar cuyo `delete` best-effort
    //    falló: la posición se muestra "vacía" en el esquema pero el lock la
    //    traba), lo borramos y seguimos en lugar de rechazar para siempre.
    final lockRef = _locks.doc(_posLockId(unidadId, posicion));
    final lockSnap = await lockRef.get();
    if (lockSnap.exists) {
      final qActivo = await _montajes
          .where('unidad_id', isEqualTo: unidadId)
          .where('posicion', isEqualTo: posicion)
          .where('hasta', isNull: true)
          .limit(1)
          .get();
      if (qActivo.docs.isNotEmpty) {
        // Ocupada de verdad: hay una cubierta activa ahí.
        throw MontajeException(
            'La posición $posicion de $unidadId ya está ocupada.');
      }
      // Lock huérfano: sin montaje activo. Liberarlo para destrabar la
      // posición. Si el delete falla, el set de abajo igual rebota (rule
      // `update: if false`) y queda como estaba — no empeoramos nada.
      AppLogger.recordError(
        StateError('Lock huérfano en $unidadId/$posicion (sin montaje activo)'),
        StackTrace.current,
        reason: 'gomeria.montar: limpiando lock huérfano',
      );
      try {
        await lockRef.delete();
      } catch (_) {/* best-effort: el set de abajo decide */}
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
      // Re-check anti-carrera (TOCTOU): el lock asegura unicidad de POSICIÓN,
      // NO de stock. Dos posiciones distintas montando el último ejemplar del
      // mismo SKU en paralelo pueden dejar el stock negativo. No revertimos
      // (más writes + riesgo); lo registramos para que quede traza y el
      // inventario físico lo corrija. Best-effort: no debe tumbar el montaje.
      try {
        final dispPost = await stockDisponible(modeloId: modeloId, vida: vida);
        if (dispPost < 0) {
          AppLogger.recordError(
            StateError(
                'Stock negativo tras montar: $modeloEtiqueta (vida $vida) = $dispPost'),
            StackTrace.current,
            reason: 'gomeria.montar: carrera de stock multi-posición',
          );
        }
      } catch (_) {/* re-check best-effort */}
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
  ///
  /// IDEMPOTENTE ante dos retiros concurrentes del MISMO montaje (doble-tap /
  /// 2 tablets): el chequeo `esActivo` tiene una ventana TOCTOU (ambos leen
  /// `hasta == null` antes de que el primero cierre), así que el +1 al stock
  /// se protege con un LOCK de cierre dedicado (`GOMERIA_RETIROS_LOCK`, docId
  /// = montajeId, rule `update: if false`): el primero que crea el lock emite
  /// el movimiento; el segundo choca con el lock y NO vuelve a sumar. Mismo
  /// patrón que el lock de posición — sin runTransaction (prohibido en
  /// Windows).
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

    // Tomar el lock de cierre ANTES de tocar el stock. Esto es lo que hace
    // idempotente al +1: si dos retiros del mismo montaje corren a la par,
    // solo uno crea el lock; el otro rebota acá (en producción por la rule
    // `update: if false`; en código por el get previo) y sale sin sumar.
    final lockRetiroRef = _retirosLock.doc(montajeId);
    final lockRetiroSnap = await lockRetiroRef.get();
    if (lockRetiroSnap.exists) {
      throw MontajeException('El montaje $montajeId ya estaba retirado.');
    }
    await lockRetiroRef.set({
      'montaje_id': montajeId,
      'fecha': FieldValue.serverTimestamp(),
      'retirado_por_dni': supervisorDni,
    });

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

    // Stock: solo el destino DEPÓSITO devuelve la cubierta al stock. Doble
    // candado contra el +1 fantasma de dos retiros concurrentes del mismo
    // montaje: (1) el lock de cierre tomado arriba, y (2) un docId
    // DETERMINÍSTICO para el movimiento (`retiro_<montajeId>`), de modo que aun
    // si por una carrera se llegase a emitir dos veces, ambos `set` colapsan
    // en UN solo documento y el stock suma +1 una sola vez. Esto cubre incluso
    // el caso fake/sin-rules donde el get-then-set del lock no es atómico.
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
        docId: 'retiro_$montajeId',
      );
    }
  }

  /// Rota la cubierta de [montajeId] a [posicionDestino] de la MISMA unidad.
  /// El km "viaja" con la cubierta: como es la misma unidad, se conservan
  /// `desde` y `km_unidad_al_montar` (solo cambia `posicion`), así el % de
  /// vida sigue siendo continuo. NO toca stock (las cubiertas no pasan por el
  /// depósito).
  ///
  /// Si el destino está OCUPADO hace SWAP (las dos cubiertas intercambian de
  /// posición). Valida que el tipo de uso y la regla de recapada de cada
  /// cubierta sean compatibles con su nueva posición.
  Future<void> rotar({
    required String montajeId,
    required String posicionDestino,
    required String supervisorDni,
    String? supervisorNombre,
  }) async {
    final refA = _montajes.doc(montajeId);
    final snapA = await refA.get();
    if (!snapA.exists) {
      throw MontajeException('El montaje no existe.');
    }
    final mA = Montaje.fromMap(snapA.id, snapA.data());
    if (!mA.esActivo) {
      throw MontajeException('La cubierta ya fue retirada.');
    }
    final codigoOrigen = mA.posicion;
    if (codigoOrigen == posicionDestino) {
      throw MontajeException('La cubierta ya está en esa posición.');
    }

    final posOrigen = posicionPorCodigo[codigoOrigen];
    final posDest = posicionPorCodigo[posicionDestino];
    if (posOrigen == null || posDest == null) {
      throw MontajeException('Posición desconocida.');
    }
    if (posDest.tipoUnidad != mA.unidadTipo) {
      throw MontajeException(
          'La posición destino no pertenece a un ${mA.unidadTipo.codigo}.');
    }
    // La cubierta que se mueve tiene que entrar en el destino.
    _validarCompatible(posDest, mA.tipoUso, mA.vida);

    final lockDestRef = _locks.doc(_posLockId(mA.unidadId, posicionDestino));
    final lockDestSnap = await lockDestRef.get();

    if (lockDestSnap.exists) {
      // SWAP — el destino está ocupado: buscamos su montaje activo.
      final qDest = await _montajes
          .where('unidad_id', isEqualTo: mA.unidadId)
          .where('posicion', isEqualTo: posicionDestino)
          .where('hasta', isNull: true)
          .limit(1)
          .get();
      if (qDest.docs.isEmpty) {
        throw MontajeException(
            'La posición destino está bloqueada pero sin cubierta activa. '
            'Revisá manualmente.');
      }
      final mB = Montaje.fromMap(qDest.docs.first.id, qDest.docs.first.data());
      // La cubierta del destino tiene que poder venir a la posición origen.
      _validarCompatible(posOrigen, mB.tipoUso, mB.vida);
      // Intercambiar posiciones. Los locks de ambas posiciones ya existen y
      // siguen marcándolas ocupadas → no se tocan.
      await refA.update({'posicion': posicionDestino});
      await _montajes.doc(mB.id).update({'posicion': codigoOrigen});
      return;
    }

    // Destino LIBRE: reservar el lock destino, mover, liberar el origen.
    await lockDestRef.set({
      'unidad_id': mA.unidadId,
      'posicion': posicionDestino,
      'desde': FieldValue.serverTimestamp(),
    });
    await refA.update({'posicion': posicionDestino});
    try {
      await _locks.doc(_posLockId(mA.unidadId, codigoOrigen)).delete();
    } catch (_) {
      /* best-effort: posición origen queda como "ocupada" huérfana */
    }
  }

  /// Valida que una cubierta de [tipoUso]/[vida] pueda ir en [pos]: mismo
  /// tipo de uso (STRICT) y, si es recapada (vida ≥ 2), que la posición lo
  /// permita. Lanza [MontajeException] si no.
  void _validarCompatible(
      PosicionCubierta pos, TipoUsoCubierta tipoUso, int vida) {
    if (pos.tipoUsoRequerido != tipoUso) {
      throw MontajeException(
          'No se puede poner una cubierta ${tipoUso.etiqueta} en una '
          'posición ${pos.tipoUsoRequerido.etiqueta}.');
    }
    if (!pos.permiteRecapada && vida >= 2) {
      throw MontajeException(
          'La posición ${pos.etiqueta} solo admite cubiertas nuevas '
          '(las recapadas van solo en el primer eje del enganche).');
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
        .map(
            (s) => s.docs.map((d) => Montaje.fromMap(d.id, d.data())).toList());
  }

  // ===========================================================================
  // KM EN VIVO (alimenta el semáforo de la UI)
  // ===========================================================================

  /// km recorrido de la cubierta de cada posición activa de una unidad.
  /// Devuelve `{codigoPosicion: km}` (null por posición si no se pudo calcular).
  /// Tractor: `KM_ACTUAL − km_al_montar`. Enganche: cálculo robusto cruzando
  /// las duplas tractor↔enganche con el odómetro histórico del tractor (los
  /// enganches no tienen odómetro propio). Se pasa a `construirEstadoUnidad`.
  Future<Map<String, double?>> kmRecorridoPorPosicion({
    required String unidadId,
    required TipoUnidadCubierta unidadTipo,
    required List<Montaje> montajesActivos,
  }) async {
    final out = <String, double?>{};
    if (montajesActivos.isEmpty) return out;

    if (unidadTipo == TipoUnidadCubierta.tractor) {
      final kmActual = await _kmActualTractor(unidadId);
      for (final m in montajesActivos) {
        final base = m.kmUnidadAlMontar;
        out[m.posicion] =
            (kmActual != null && base != null) ? (kmActual - base) : null;
      }
      return out;
    }

    // Enganche: km robusto por montaje (desde su montaje hasta ahora).
    final ahora = DateTime.now();
    for (final m in montajesActivos) {
      out[m.posicion] = await _kmEnganche(unidadId, m.desde, ahora);
    }
    return out;
  }

  /// Km de CIERRE de un montaje al retirarlo: el odómetro de la unidad
  /// (`kmUnidadAlRetirar`) y los km que rodó la cubierta (`kmRecorridos`).
  /// Mismo criterio que el servicio viejo (`GomeriaService.retirar`):
  ///
  /// - **Tractor**: `kmUnidadAlRetirar = KM_ACTUAL`; `kmRecorridos =
  ///   KM_ACTUAL − kmUnidadAlMontar` (clamp a 0 si el odómetro retrocedió por
  ///   un sync Volvo erróneo / reset manual). Si falta el `KM_ACTUAL` o el
  ///   `kmUnidadAlMontar`, ambos quedan `null`.
  /// - **Enganche**: no tiene odómetro propio → `kmUnidadAlRetirar = null`;
  ///   `kmRecorridos` sale del cálculo robusto cruzando las duplas
  ///   tractor↔enganche con el odómetro histórico del tractor (`_kmEnganche`).
  ///
  /// La cuenta vive acá (no en la UI) para no duplicar la lógica sensible que
  /// alimenta el reporte costo/km, y para reusar los helpers ya validados.
  Future<({double? kmUnidadAlRetirar, double? kmRecorridos})> kmCierreRetiro(
      Montaje montaje) async {
    if (montaje.unidadTipo == TipoUnidadCubierta.tractor) {
      final kmActual = await _kmActualTractor(montaje.unidadId);
      final base = montaje.kmUnidadAlMontar;
      double? recorridos;
      if (kmActual != null && base != null) {
        final diff = kmActual - base;
        recorridos = diff < 0 ? 0 : diff;
      }
      return (kmUnidadAlRetirar: kmActual, kmRecorridos: recorridos);
    }
    // Enganche: sin odómetro propio. km robusto desde el montaje hasta ahora.
    final recorridos =
        await _kmEnganche(montaje.unidadId, montaje.desde, DateTime.now());
    return (kmUnidadAlRetirar: null, kmRecorridos: recorridos);
  }

  Future<double?> _kmActualTractor(String unidadId) async {
    final snap =
        await _db.collection(AppCollections.vehiculos).doc(unidadId).get();
    final km = (snap.data()?['KM_ACTUAL'] as num?)?.toDouble();
    return (km != null && km > 0) ? km : null;
  }

  /// km que rodó un enganche en [desde, hasta] cruzando `ASIGNACIONES_ENGANCHE`
  /// con `TELEMETRIA_HISTORICO` del tractor. Mismo algoritmo robusto validado
  /// 2026-05-29 (`gomeria_service`); duplicado a propósito para no tocar el
  /// servicio viejo — se unifica cuando se borre el viejo. Devuelve `null` si
  /// no se pudo calcular NADA (distinto de 0 km reales).
  Future<double?> _kmEnganche(
      String engancheId, DateTime desde, DateTime hasta) async {
    final snap = await _db
        .collection(AppCollections.asignacionesEnganche)
        .where('enganche_id', isEqualTo: engancheId)
        .where('desde', isLessThanOrEqualTo: Timestamp.fromDate(hasta))
        .get();
    double total = 0;
    var contadas = 0;
    var sinDatos = 0;
    for (final d in snap.docs) {
      final data = d.data();
      final aDesde = (data['desde'] as Timestamp?)?.toDate();
      final aHasta = (data['hasta'] as Timestamp?)?.toDate();
      final tractorId = data['tractor_id']?.toString();
      if (aDesde == null || tractorId == null || tractorId.isEmpty) continue;
      if (aHasta != null && !aHasta.isAfter(desde)) continue; // terminó antes
      final inicio = aDesde.isBefore(desde) ? desde : aDesde;
      final fin = (aHasta == null || aHasta.isAfter(hasta)) ? hasta : aHasta;
      final odoIni = await _odometroTractorEnFecha(tractorId, inicio);
      final odoFin = await _odometroTractorEnFecha(tractorId, fin);
      if (odoIni == null || odoFin == null) {
        sinDatos++;
        continue;
      }
      final diff = odoFin - odoIni;
      if (diff > 0) {
        total += diff;
        contadas++;
      }
    }
    if (contadas == 0 && sinDatos > 0) return null;
    return total;
  }

  Future<double?> _odometroTractorEnFecha(String tractorId, DateTime fecha,
      {int ventanaDias = 7}) async {
    for (var off = 0; off <= ventanaDias; off++) {
      final cands = off == 0
          ? <DateTime>[fecha]
          : <DateTime>[
              fecha.subtract(Duration(days: off)),
              fecha.add(Duration(days: off)),
            ];
      for (final f in cands) {
        final snap = await _db
            .collection(AppCollections.telemetriaHistorico)
            .doc(_telemetriaDocId(tractorId, f))
            .get();
        if (!snap.exists) continue;
        final km = (snap.data()?['km'] as num?)?.toDouble();
        if (km != null && km > 0) return km;
      }
    }
    return null;
  }

  static String _telemetriaDocId(String patente, DateTime fecha) {
    final f = fecha.toLocal();
    final y = f.year.toString().padLeft(4, '0');
    final m = f.month.toString().padLeft(2, '0');
    final d = f.day.toString().padLeft(2, '0');
    return '${patente}_$y-$m-$d';
  }
}
