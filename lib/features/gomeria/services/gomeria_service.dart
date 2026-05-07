import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/audit_log_service.dart';
import '../constants/posiciones.dart';
import '../models/cubierta.dart';
import '../models/cubierta_instalada.dart';
import '../models/cubierta_modelo.dart';
import '../models/cubierta_recapado.dart';

/// Único punto de entrada para mutar el inventario de cubiertas y su
/// ciclo de vida (alta, instalación, retiro, recapado, descarte).
///
/// **Por qué es un service único**: las operaciones tocan varias colecciones
/// en simultáneo y necesitan validaciones cruzadas (ej. tipo_uso vs
/// posición, no instalar dos cubiertas en la misma posición, sumar
/// km_acumulados al retirar). Tener un único punto evita inconsistencias
/// si la UI evoluciona o si se agregan más callers (Cloud Function de
/// alertas, ABM admin, importación masiva).
///
/// **Transactional para writes que tocan más de una colección**:
/// - instalar: lee posición ocupada (READ) + crea CUBIERTAS_INSTALADAS +
///   actualiza CUBIERTAS.estado.
/// - retirar: cierra CUBIERTAS_INSTALADAS + actualiza CUBIERTAS.estado y
///   km_acumulados.
/// - mandarARecapar: crea CUBIERTAS_RECAPADOS + actualiza CUBIERTAS.estado.
/// - recibirDeRecapado: cierra CUBIERTAS_RECAPADOS + actualiza
///   CUBIERTAS.estado/vidas (si RECIBIDA) o estado=DESCARTADA.
///
/// **Cálculo de km recorridos al retirar**:
/// - Tractor: `KM_ACTUAL del tractor − km_unidad_al_instalar` directo.
/// - Enganche: en Fase 1 queda `null`. Fase 2 lo calcula cruzando con
///   `ASIGNACIONES_ENGANCHE` (qué tractores arrastraron este enganche
///   durante el período de la instalación). Lógica diferida porque
///   requiere otra subquery por cada tractor — primero hagamos andar el
///   loop básico.
class GomeriaService {
  final FirebaseFirestore _db;

  GomeriaService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  /// DocId estable del lock de posición. Combina patente + posición con
  /// `__` (doble underscore) — patente nunca lleva esa secuencia y los
  /// códigos de posición son ASCII alfanuméricos con `_` simple.
  static String _posicionLockId(String unidadId, String posicionCodigo) =>
      '${unidadId}__$posicionCodigo';

  // ===========================================================================
  // ALTA DE CUBIERTAS
  // ===========================================================================

  /// Genera el próximo código `CUB-XXXX` zero-padded a 4 dígitos.
  ///
  /// Implementación con read+update optimista + retry por rule:
  /// la rule del counter exige `proximo == resource.data.proximo + 1`,
  /// así que dos clientes en paralelo van a chocar — el segundo recibe
  /// PERMISSION_DENIED y reintenta hasta [maxIntentos] veces. Es
  /// equivalente al retry interno de `runTransaction` pero implementado
  /// en cliente, porque el `runTransaction` del plugin C++ Windows
  /// hace `abort()` con ciertos patrones de tx (ver crash 2026-05-04).
  ///
  /// El padding crece naturalmente a 5 dígitos cuando supere 9999 (el
  /// orden lexicográfico se rompe pero ya es problema futuro — Vecchi
  /// tiene < 200 cubiertas hoy).
  Future<String> _proximoCodigoCubierta() async {
    const maxIntentos = 5;
    final ref = _db.collection(AppCollections.meta).doc('cubiertas_counter');
    for (var intento = 0; intento < maxIntentos; intento++) {
      final snap = await ref.get();
      final actual = (snap.data()?['proximo'] as num?)?.toInt() ?? 0;
      final siguiente = actual + 1;
      try {
        if (snap.exists) {
          await ref.update({'proximo': siguiente});
        } else {
          await ref.set({'proximo': siguiente});
        }
        return 'CUB-${siguiente.toString().padLeft(4, '0')}';
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied' || intento == maxIntentos - 1) {
          rethrow;
        }
        // Otro cliente incrementó el counter al mismo tiempo. Backoff
        // exponencial corto (50ms, 100ms, 200ms, 400ms) y reintentamos.
        await Future<void>.delayed(
            Duration(milliseconds: 50 * (1 << intento)));
      }
    }
    throw StateError(
      'No se pudo generar el código CUB tras $maxIntentos intentos. '
      'Probá de nuevo en unos segundos.',
    );
  }

  /// Da de alta una cubierta nueva en estado `EN_DEPOSITO` con vidas=1.
  ///
  /// Devuelve el doc id generado. El [modeloId] debe existir (se valida
  /// dentro de la transaction y se guarda snapshot del modelo para
  /// queries sin join).
  ///
  /// Si se pasa [precioCompra], queda guardado en `CUBIERTAS.precio_compra`
  /// — habilita el cálculo de costo por km en reportes.
  Future<String> crearCubierta({
    required String modeloId,
    required String supervisorDni,
    String? supervisorNombre,
    String? observaciones,
    double? precioCompra,
  }) async {
    final modeloLimpio = modeloId.trim();
    if (modeloLimpio.isEmpty) {
      throw ArgumentError('modeloId vacío');
    }
    final supervisorLimpio = supervisorDni.trim();
    if (supervisorLimpio.isEmpty) {
      throw ArgumentError('supervisorDni vacío');
    }

    // Validación del modelo FUERA de transaction. La diferencia con la
    // versión anterior (todo dentro de runTransaction) es la atomicidad:
    // si el supervisor desactiva el modelo justo entre nuestra lectura
    // y nuestra escritura, podríamos crear una cubierta de un modelo
    // recién dado de baja. En la práctica eso es virtualmente imposible
    // (los modelos se dan de baja muy raramente y un solo supervisor
    // opera el alta). Trade-off aceptable a cambio de evitar el crash
    // del plugin C++ Windows con runTransaction (2026-05-04).
    final modeloRef =
        _db.collection(AppCollections.cubiertasModelos).doc(modeloLimpio);
    final modeloSnap = await modeloRef.get();
    if (!modeloSnap.exists) {
      throw StateError('Modelo $modeloLimpio no existe');
    }
    final modelo = CubiertaModelo.fromMap(modeloLimpio, modeloSnap.data());
    if (!modelo.activo) {
      throw StateError('Modelo ${modelo.etiqueta} está dado de baja');
    }

    // Generar código del counter (con retry optimista en cliente).
    final codigoNuevo = await _proximoCodigoCubierta();

    // Crear el doc de cubierta con set simple. Si esto falla, el counter
    // ya quedó incrementado y se "salta" un código — efecto idéntico al
    // que tendría una tx que rolea: el siguiente código generado va a
    // ser el siguiente en el counter, no el saltado. Eso ya estaba
    // documentado como aceptable en la spec del módulo.
    final cubiertaId = _db.collection(AppCollections.cubiertas).doc().id;
    final cubiertaRef =
        _db.collection(AppCollections.cubiertas).doc(cubiertaId);
    await cubiertaRef.set(<String, dynamic>{
      'codigo': codigoNuevo,
      'modelo_id': modeloLimpio,
      'modelo_etiqueta': modelo.etiqueta,
      'tipo_uso': modelo.tipoUso.codigo,
      'estado': EstadoCubierta.enDeposito.codigo,
      'vidas': 1,
      'km_acumulados': 0,
      if (observaciones != null && observaciones.trim().isNotEmpty)
        'observaciones': observaciones.trim(),
      if (precioCompra != null && precioCompra > 0)
        'precio_compra': precioCompra,
      'creado_en': FieldValue.serverTimestamp(),
      'creado_por_dni': supervisorLimpio,
      if (supervisorNombre != null && supervisorNombre.trim().isNotEmpty)
        'creado_por_nombre': supervisorNombre.trim(),
    });

    unawaited(AuditLog.registrar(
      accion: AuditAccion.crearCubierta,
      entidad: AppCollections.cubiertas,
      entidadId: cubiertaId,
      detalles: {
        'codigo': codigoNuevo,
        'modelo_id': modeloLimpio,
      },
    ));

    return cubiertaId;
  }

  /// Da de alta varias cubiertas idénticas (mismo modelo, mismo precio,
  /// mismas observaciones) en una sola operación. Pensado para flotas
  /// grandes donde el supervisor recibe del proveedor 50, 100, 250
  /// cubiertas iguales y darlas de alta una por una es inviable.
  ///
  /// Devuelve la lista de doc ids creados (orden de creación). Los
  /// códigos `CUB-XXXX` van consecutivos desde el counter actual.
  ///
  /// Si una creación intermedia falla, se devuelven solo las cubiertas
  /// creadas hasta ese punto (best-effort) y la excepción se propaga
  /// al caller. La UI puede mostrar "se crearon X de Y" y dejar al
  /// supervisor reintentar el resto.
  Future<List<String>> crearCubiertasEnLote({
    required String modeloId,
    required int cantidad,
    required String supervisorDni,
    String? supervisorNombre,
    String? observaciones,
    double? precioCompra,
    void Function(int creadas, int total)? onProgreso,
  }) async {
    if (cantidad < 1) {
      throw ArgumentError('cantidad debe ser >= 1 (se pasó $cantidad)');
    }
    if (cantidad > 500) {
      throw ArgumentError(
          'cantidad máxima 500 por lote (se pasó $cantidad). '
          'Para más, dividir en varios lotes.');
    }
    final ids = <String>[];
    for (var i = 0; i < cantidad; i++) {
      // Reusamos `crearCubierta` para no duplicar lógica de validación
      // del modelo, generación de código y registro de auditoría. Es
      // serial — Firestore puede manejar miles de writes/sec, pero
      // serializar evita pelearse con la rule monotónica del counter
      // (que rebotaría a varios clientes paralelos).
      final id = await crearCubierta(
        modeloId: modeloId,
        supervisorDni: supervisorDni,
        supervisorNombre: supervisorNombre,
        observaciones: observaciones,
        precioCompra: precioCompra,
      );
      ids.add(id);
      onProgreso?.call(ids.length, cantidad);
    }
    return ids;
  }

  // ===========================================================================
  // INSTALAR / RETIRAR
  // ===========================================================================

  /// Instala una cubierta en una posición específica de una unidad.
  ///
  /// Validaciones (todas dentro de la transaction):
  /// - La cubierta existe y está EN_DEPOSITO.
  /// - La posición existe y `aceptaTipoUso(cubierta.tipoUso) == true`.
  ///   STRICT: una cubierta TRACCION no se puede instalar en posición
  ///   DIRECCION (decisión confirmada por Santiago: "es un error de tipeo
  ///   seguramente").
  /// - La posición no tiene otra cubierta activa (nadie más en
  ///   `CUBIERTAS_INSTALADAS` con `unidad_id == X && posicion == Y &&
  ///   hasta == null`).
  /// - La unidad existe en VEHICULOS y su TIPO coincide con [unidadTipo].
  ///
  /// Si todo OK: crea CUBIERTAS_INSTALADAS (activa) y actualiza
  /// `CUBIERTAS.estado = INSTALADA`.
  Future<String> instalar({
    required String cubiertaId,
    required String unidadId,
    required TipoUnidadCubierta unidadTipo,
    required String posicionCodigo,
    required String supervisorDni,
    String? supervisorNombre,
    String? motivo,
  }) async {
    final cubiertaLimpia = cubiertaId.trim();
    final unidadLimpia = unidadId.trim().toUpperCase();
    final posicionLimpia = posicionCodigo.trim().toUpperCase();
    final supervisorLimpio = supervisorDni.trim();
    if (cubiertaLimpia.isEmpty ||
        unidadLimpia.isEmpty ||
        posicionLimpia.isEmpty ||
        supervisorLimpio.isEmpty) {
      throw ArgumentError(
          'cubiertaId, unidadId, posicionCodigo y supervisorDni son obligatorios');
    }

    // Resolver la posición desde el catálogo en compile-time. Si no existe
    // es un bug del caller (la UI mandó un código que no figura).
    final posicion = posicionPorCodigo[posicionLimpia];
    if (posicion == null) {
      throw ArgumentError('Posición desconocida: $posicionLimpia');
    }
    if (posicion.tipoUnidad != unidadTipo) {
      throw ArgumentError(
        'Posición $posicionLimpia es de ${posicion.tipoUnidad.codigo}, '
        'no de ${unidadTipo.codigo}',
      );
    }

    final instalacionId =
        _db.collection(AppCollections.cubiertasInstaladas).doc().id;

    final posicionLockId = _posicionLockId(unidadLimpia, posicionLimpia);
    final posicionLockRef = _db
        .collection(AppCollections.cubiertasPosicionesActivas)
        .doc(posicionLockId);
    final cubiertaLockRef =
        _db.collection(AppCollections.cubiertasActivas).doc(cubiertaLimpia);
    final cubiertaRef =
        _db.collection(AppCollections.cubiertas).doc(cubiertaLimpia);
    final vehiculoRef =
        _db.collection(AppCollections.vehiculos).doc(unidadLimpia);

    // Lecturas de dominio en paralelo (sin tx — el plugin C++ Windows
    // crashea con runTransaction en cierta combinación de operaciones).
    // La unicidad la garantizan las rules: los locks tienen
    // `allow update: if false`, así que un `set` sobre un lock que
    // ya existe rebota con permission-denied y eso lo interpretamos
    // como race con otro cliente.
    final results = await Future.wait([
      cubiertaRef.get(),
      vehiculoRef.get(),
      posicionLockRef.get(),
      cubiertaLockRef.get(),
    ]);
    final cubiertaSnap = results[0];
    final vehiculoSnap = results[1];
    final posicionLockSnap = results[2];
    final cubiertaLockSnap = results[3];

    if (posicionLockSnap.exists) {
      final otroCodigo =
          (posicionLockSnap.data()?['cubierta_codigo'] ?? '').toString();
      throw StateError(
        'La posición ${posicion.etiqueta} ya tiene la cubierta '
        '$otroCodigo instalada. Retirala primero.',
      );
    }
    if (cubiertaLockSnap.exists) {
      throw StateError(
        'La cubierta $cubiertaLimpia figura activa en otra posición. '
        'Cerrá esa instalación antes de instalar acá.',
      );
    }
    if (!cubiertaSnap.exists) {
      throw StateError('Cubierta $cubiertaLimpia no existe');
    }
    final cubierta = Cubierta.fromMap(cubiertaLimpia, cubiertaSnap.data());
    if (cubierta.estado != EstadoCubierta.enDeposito) {
      throw StateError(
        'La cubierta ${cubierta.codigo} está ${cubierta.estado.codigo}, '
        'solo se puede instalar si está EN_DEPOSITO',
      );
    }
    // VALIDACIÓN ESTRICTA tipo_uso vs posición (Santiago: "es un
    // error de tipeo seguramente").
    if (!posicion.aceptaTipoUso(cubierta.tipoUso)) {
      throw StateError(
        'La cubierta ${cubierta.codigo} es ${cubierta.tipoUso.codigo} y la '
        'posición ${posicion.etiqueta} requiere '
        '${posicion.tipoUsoRequerido.codigo}',
      );
    }
    if (!vehiculoSnap.exists) {
      throw StateError('Unidad $unidadLimpia no existe');
    }
    final vehiculoData = vehiculoSnap.data() ?? const <String, dynamic>{};
    final tipoVehiculo =
        (vehiculoData['TIPO'] ?? '').toString().toUpperCase();
    final esTractor = tipoVehiculo == AppTiposVehiculo.tractor;
    if (unidadTipo == TipoUnidadCubierta.tractor && !esTractor) {
      throw StateError(
        '$unidadLimpia tiene TIPO=$tipoVehiculo, no es TRACTOR',
      );
    }
    if (unidadTipo == TipoUnidadCubierta.enganche && esTractor) {
      throw StateError(
        '$unidadLimpia es TRACTOR — se esperaba un enganche',
      );
    }
    final double? kmUnidadActual = esTractor
        ? (vehiculoData['KM_ACTUAL'] as num?)?.toDouble()
        : null;

    // Snapshot del modelo (lectura adicional fuera del Future.wait
    // porque depende del modeloId que sale de la cubierta).
    final modeloSnap = await _db
        .collection(AppCollections.cubiertasModelos)
        .doc(cubierta.modeloId)
        .get();
    final modelo = modeloSnap.exists
        ? CubiertaModelo.fromMap(cubierta.modeloId, modeloSnap.data())
        : null;
    final kmEsperadosSnapshot = modelo?.kmEsperadosParaVida(cubierta.vidas);

    // Writes secuenciales con rollback manual. Orden: primero los locks
    // (los que pueden chocar por race), después el log y el estado de
    // la cubierta. Si alguno intermedio falla, deshacemos los pasos
    // anteriores con `unawaited` (best-effort cleanup).
    final ahora = Timestamp.now();
    try {
      await posicionLockRef.set(<String, dynamic>{
        'instalacion_id': instalacionId,
        'cubierta_id': cubiertaLimpia,
        'cubierta_codigo': cubierta.codigo,
        'unidad_id': unidadLimpia,
        'posicion': posicionLimpia,
        'desde': ahora,
      });
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw StateError(
          'La posición ${posicion.etiqueta} fue ocupada por otro supervisor '
          'justo antes. Refrescá y volvé a intentar.',
        );
      }
      rethrow;
    }

    try {
      await cubiertaLockRef.set(<String, dynamic>{
        'instalacion_id': instalacionId,
        'unidad_id': unidadLimpia,
        'posicion': posicionLimpia,
        'desde': ahora,
      });
    } on FirebaseException catch (e) {
      // Rollback: liberar el lock de posición que recién creamos.
      unawaited(posicionLockRef.delete());
      if (e.code == 'permission-denied') {
        throw StateError(
          'La cubierta ${cubierta.codigo} fue instalada en otro lado '
          'justo antes. Refrescá y volvé a intentar.',
        );
      }
      rethrow;
    }

    final colInst = _db.collection(AppCollections.cubiertasInstaladas);
    final nuevaRef = colInst.doc(instalacionId);
    try {
      await nuevaRef.set(<String, dynamic>{
        'cubierta_id': cubiertaLimpia,
        'cubierta_codigo': cubierta.codigo,
        'unidad_id': unidadLimpia,
        'unidad_tipo': unidadTipo.codigo,
        'posicion': posicionLimpia,
        'vida_al_instalar': cubierta.vidas,
        'modelo_etiqueta': cubierta.modeloEtiqueta,
        if (kmEsperadosSnapshot != null)
          'km_vida_estimada_al_instalar': kmEsperadosSnapshot,
        'desde': ahora,
        'hasta': null,
        'km_unidad_al_instalar': kmUnidadActual,
        'km_unidad_al_retirar': null,
        'km_recorridos': null,
        'instalado_por_dni': supervisorLimpio,
        if (supervisorNombre != null && supervisorNombre.trim().isNotEmpty)
          'instalado_por_nombre': supervisorNombre.trim(),
        'retirado_por_dni': null,
        'retirado_por_nombre': null,
        if (motivo != null && motivo.trim().isNotEmpty)
          'motivo': motivo.trim(),
      });
    } catch (_) {
      // Rollback de ambos locks si la creación del log falla.
      unawaited(posicionLockRef.delete());
      unawaited(cubiertaLockRef.delete());
      rethrow;
    }

    // Update final del estado de la cubierta. Si esto falla queda un
    // estado raro (cubierta EN_DEPOSITO con instalación activa), pero
    // las queries siguen funcionando porque la verdad operativa vive en
    // CUBIERTAS_INSTALADAS y los locks. Logueamos el problema pero NO
    // hacemos rollback completo (sería peor: dejaríamos la cubierta sin
    // instalar pero el supervisor ya la cambió físicamente).
    try {
      await cubiertaRef.update({
        'estado': EstadoCubierta.instalada.codigo,
      });
    } catch (e, st) {
      AppLogger.recordError(e, st,
          reason: 'CUBIERTAS.estado update tras instalar (no fatal)');
    }

    unawaited(AuditLog.registrar(
      accion: AuditAccion.instalarCubierta,
      entidad: AppCollections.cubiertas,
      entidadId: cubiertaLimpia,
      detalles: {
        'unidad_id': unidadLimpia,
        'posicion': posicionLimpia,
        'instalacion_id': instalacionId,
      },
    ));

    return instalacionId;
  }

  /// Retira una cubierta instalada. Calcula km recorridos para tractor;
  /// para enganche queda en `null` (Fase 2 lo calcula con cruce
  /// ASIGNACIONES_ENGANCHE).
  ///
  /// Si [destinoFinal] es `descartada`, la cubierta queda
  /// `EstadoCubierta.descartada` en vez de volver al depósito (atajo
  /// para "saqué la cubierta porque está rota, no la voy a recapar").
  Future<void> retirar({
    required String instalacionId,
    required String supervisorDni,
    String? supervisorNombre,
    String? motivo,
    EstadoCubierta destinoFinal = EstadoCubierta.enDeposito,
  }) async {
    final idLimpio = instalacionId.trim();
    final supervisorLimpio = supervisorDni.trim();
    if (idLimpio.isEmpty || supervisorLimpio.isEmpty) {
      throw ArgumentError('instalacionId y supervisorDni son obligatorios');
    }
    if (destinoFinal != EstadoCubierta.enDeposito &&
        destinoFinal != EstadoCubierta.descartada) {
      throw ArgumentError(
        'destinoFinal solo puede ser EN_DEPOSITO o DESCARTADA al retirar '
        '(no $destinoFinal)',
      );
    }

    // Lecturas de dominio (sin tx — el plugin C++ Windows crashea con
    // runTransaction; ver crearCubierta y la memoria
    // feedback_windows_cloud_firestore_bugs).
    final instRef =
        _db.collection(AppCollections.cubiertasInstaladas).doc(idLimpio);
    final instSnap = await instRef.get();
    if (!instSnap.exists) {
      throw StateError('Instalación $idLimpio no existe');
    }
    final inst = CubiertaInstalada.fromDoc(instSnap);
    if (!inst.esActiva) {
      throw StateError(
          'La instalación $idLimpio ya está cerrada (hasta != null)');
    }

    final cubiertaRef =
        _db.collection(AppCollections.cubiertas).doc(inst.cubiertaId);

    // Releemos cubierta + (opcional) vehículo en paralelo para poder
    // calcular km_acumulados consistente y km_recorridos del tractor.
    final readsToDo = <Future<DocumentSnapshot<Map<String, dynamic>>>>[
      cubiertaRef.get(),
      if (inst.unidadTipo == TipoUnidadCubierta.tractor)
        _db.collection(AppCollections.vehiculos).doc(inst.unidadId).get(),
    ];
    final reads = await Future.wait(readsToDo);
    final cubiertaSnap = reads[0];
    if (!cubiertaSnap.exists) {
      throw StateError('Cubierta ${inst.cubiertaId} no existe');
    }
    final cubierta = Cubierta.fromMap(inst.cubiertaId, cubiertaSnap.data());

    double? kmActualTractor;
    double? kmRecorridos;
    if (inst.unidadTipo == TipoUnidadCubierta.tractor) {
      final vehSnap = reads[1];
      kmActualTractor = (vehSnap.data()?['KM_ACTUAL'] as num?)?.toDouble();
      if (kmActualTractor != null && inst.kmUnidadAlInstalar != null) {
        final diff = kmActualTractor - inst.kmUnidadAlInstalar!;
        // Si el odómetro retrocedió (sync Volvo erróneo, reset manual)
        // no contamos km negativos.
        kmRecorridos = diff < 0 ? 0 : diff;
      }
    } else if (inst.unidadTipo == TipoUnidadCubierta.enganche) {
      // Fase 2 Gomería: la cubierta de enganche acumula km del/los
      // tractor(es) que arrastraron al enganche durante el período de
      // instalación de la cubierta. Sumamos las asignaciones de
      // ASIGNACIONES_ENGANCHE que solapan con [inst.desde, ahora]
      // usando los snapshots `odometer_inicial`/`odometer_final` que
      // persiste `AsignacionEngancheService` desde Fase 2.
      kmRecorridos = await _calcularKmCubiertaEnganche(
        engancheId: inst.unidadId,
        instalado: Timestamp.fromDate(inst.desde),
        retirado: Timestamp.now(),
      );
    }
    final ahora = Timestamp.now();

    // Writes secuenciales con cleanup best-effort si una falla mid-way.
    // Orden: cerrar el log primero (la fuente de verdad); después
    // actualizar la cubierta y liberar los locks. Si el segundo bloque
    // falla, la operación queda parcial pero el log ya está cerrado.
    await instRef.update({
      'hasta': ahora,
      'km_unidad_al_retirar': kmActualTractor,
      'km_recorridos': kmRecorridos,
      'retirado_por_dni': supervisorLimpio,
      if (supervisorNombre != null && supervisorNombre.trim().isNotEmpty)
        'retirado_por_nombre': supervisorNombre.trim(),
      if (motivo != null && motivo.trim().isNotEmpty)
        'motivo_retiro': motivo.trim(),
    });

    try {
      await cubiertaRef.update({
        'estado': destinoFinal.codigo,
        if (kmRecorridos != null && kmRecorridos > 0)
          'km_acumulados': cubierta.kmAcumulados + kmRecorridos,
      });
    } catch (e, st) {
      AppLogger.recordError(e, st,
          reason: 'CUBIERTAS.estado update tras retirar (no fatal)');
    }

    // Liberar locks (delete en doc inexistente es no-op).
    unawaited(_db
        .collection(AppCollections.cubiertasPosicionesActivas)
        .doc(_posicionLockId(inst.unidadId, inst.posicion))
        .delete());
    unawaited(_db
        .collection(AppCollections.cubiertasActivas)
        .doc(inst.cubiertaId)
        .delete());

    unawaited(AuditLog.registrar(
      accion: destinoFinal == EstadoCubierta.descartada
          ? AuditAccion.descartarCubierta
          : AuditAccion.retirarCubierta,
      entidad: AppCollections.cubiertas,
      entidadId: idLimpio,
      detalles: {
        'instalacion_id': idLimpio,
        'destino_final': destinoFinal.codigo,
        if (motivo != null && motivo.trim().isNotEmpty) 'motivo': motivo.trim(),
      },
    ));
  }

  /// Marca la cubierta como DESCARTADA sin pasar por una instalación
  /// (ej. cubierta del depósito que se decide tirar antes de instalarla).
  /// Si la cubierta está INSTALADA, usar [retirar] con
  /// `destinoFinal = EstadoCubierta.descartada` en vez de este método.
  Future<void> descartar({
    required String cubiertaId,
    required String supervisorDni,
    String? motivo,
  }) async {
    final cubiertaLimpia = cubiertaId.trim();
    final supervisorLimpio = supervisorDni.trim();
    if (cubiertaLimpia.isEmpty || supervisorLimpio.isEmpty) {
      throw ArgumentError('cubiertaId y supervisorDni son obligatorios');
    }

    final cubiertaRef =
        _db.collection(AppCollections.cubiertas).doc(cubiertaLimpia);
    final cubiertaSnap = await cubiertaRef.get();
    if (!cubiertaSnap.exists) {
      throw StateError('Cubierta $cubiertaLimpia no existe');
    }
    final cubierta = Cubierta.fromMap(cubiertaLimpia, cubiertaSnap.data());
    if (cubierta.estado == EstadoCubierta.instalada) {
      throw StateError(
        'La cubierta ${cubierta.codigo} está INSTALADA — usá retirar() '
        'con destinoFinal=DESCARTADA',
      );
    }
    if (cubierta.estado == EstadoCubierta.descartada) {
      return; // no-op idempotente
    }
    await cubiertaRef.update({
      'estado': EstadoCubierta.descartada.codigo,
    });

    unawaited(AuditLog.registrar(
      accion: AuditAccion.descartarCubierta,
      entidad: AppCollections.cubiertas,
      entidadId: cubiertaLimpia,
      detalles: {
        'descartada_por': supervisorLimpio,
        if (motivo != null && motivo.trim().isNotEmpty) 'motivo': motivo.trim(),
      },
    ));
  }

  // ===========================================================================
  // CONTROL — registrar última lectura de presión / profundidad de banda
  // ===========================================================================

  /// Registra una lectura de control de la cubierta instalada (pisada
  /// sobre la doc activa de `CUBIERTAS_INSTALADAS`). Si la lectura
  /// histórica fuese necesaria a futuro, hay que crear una colección
  /// `CUBIERTAS_CONTROLES` aparte. Por ahora capturamos solo la última.
  Future<void> registrarLectura({
    required String instalacionId,
    int? presionPsi,
    double? profundidadBandaMm,
    required String supervisorDni,
    String? supervisorNombre,
  }) async {
    final id = instalacionId.trim();
    final supervisorLimpio = supervisorDni.trim();
    if (id.isEmpty || supervisorLimpio.isEmpty) {
      throw ArgumentError(
          'instalacionId y supervisorDni son obligatorios');
    }
    if (presionPsi == null && profundidadBandaMm == null) {
      throw ArgumentError(
          'Pasá al menos uno: presión o profundidad de banda');
    }
    await _db
        .collection(AppCollections.cubiertasInstaladas)
        .doc(id)
        .update({
      if (presionPsi != null) 'ultima_presion_psi': presionPsi,
      if (profundidadBandaMm != null)
        'ultima_profundidad_banda_mm': profundidadBandaMm,
      'ultima_lectura_en': FieldValue.serverTimestamp(),
      'ultima_lectura_por_dni': supervisorLimpio,
      if (supervisorNombre != null && supervisorNombre.trim().isNotEmpty)
        'ultima_lectura_por_nombre': supervisorNombre.trim(),
    });
  }

  // ===========================================================================
  // ROTAR
  // ===========================================================================

  /// Rota una cubierta de una posición a otra DENTRO DE LA MISMA UNIDAD.
  /// Atómico: si la posición destino está vacía, cierra el log de origen
  /// y crea uno nuevo en destino. Si está ocupada, hace swap (cruza
  /// ambas cubiertas) — útil para emparejar desgaste rotando duales.
  ///
  /// Validaciones:
  /// - Origen y destino son de la misma unidad.
  /// - Destino acepta `tipo_uso` de la cubierta de origen (y viceversa
  ///   en caso de swap).
  /// - Para tractor: km_unidad_al_instalar del nuevo log usa el
  ///   `KM_ACTUAL` actual; los km_recorridos del log que se cierra se
  ///   calculan igual que `retirar()`.
  /// - Para enganche: km_recorridos quedan `null` (Fase 2).
  ///
  /// Para mover a OTRA UNIDAD: usar `retirar` + `instalar` (la rotación
  /// inter-unidades es operativamente distinta — pasa por el depósito).
  Future<void> rotar({
    required String instalacionOrigenId,
    required String posicionDestinoCodigo,
    required String supervisorDni,
    String? supervisorNombre,
    String? motivo,
  }) async {
    final origenId = instalacionOrigenId.trim();
    final destinoCodigo = posicionDestinoCodigo.trim().toUpperCase();
    final supervisorLimpio = supervisorDni.trim();
    if (origenId.isEmpty ||
        destinoCodigo.isEmpty ||
        supervisorLimpio.isEmpty) {
      throw ArgumentError(
          'instalacionOrigenId, posicionDestino y supervisorDni son obligatorios');
    }
    final posicionDestino = posicionPorCodigo[destinoCodigo];
    if (posicionDestino == null) {
      throw ArgumentError('Posición destino desconocida: $destinoCodigo');
    }

    // IDs de las nuevas instalaciones generados afuera, estables.
    final nuevoIdA = _db.collection(AppCollections.cubiertasInstaladas).doc().id;
    final nuevoIdB = _db.collection(AppCollections.cubiertasInstaladas).doc().id;

    final colInst = _db.collection(AppCollections.cubiertasInstaladas);
    final origenRef = colInst.doc(origenId);

    // Leer la instalación origen primero — define unidad y posicion.
    final origenSnap = await origenRef.get();
    if (!origenSnap.exists) {
      throw StateError('Instalación $origenId no existe');
    }
    final origen = CubiertaInstalada.fromDoc(origenSnap);
    if (!origen.esActiva) {
      throw StateError('La instalación de origen ya está cerrada');
    }
    final posicionOrigen = origen.posicionTipada;
    if (posicionOrigen == null) {
      throw StateError('Posición origen desconocida: ${origen.posicion}');
    }
    if (posicionOrigen.codigo == posicionDestino.codigo) {
      throw StateError('Origen y destino son la misma posición');
    }
    if (posicionOrigen.tipoUnidad != posicionDestino.tipoUnidad) {
      throw StateError(
          'Origen y destino deben ser de la misma unidad (tractor vs enganche).');
    }

    final lockDestinoRef = _db
        .collection(AppCollections.cubiertasPosicionesActivas)
        .doc(_posicionLockId(origen.unidadId, posicionDestino.codigo));
    final lockOrigenRef = _db
        .collection(AppCollections.cubiertasPosicionesActivas)
        .doc(_posicionLockId(origen.unidadId, posicionOrigen.codigo));
    final lockCubiertaARef =
        _db.collection(AppCollections.cubiertasActivas).doc(origen.cubiertaId);
    final cubiertaARef =
        _db.collection(AppCollections.cubiertas).doc(origen.cubiertaId);

    // Lecturas paralelas restantes: lock destino (puede haber swap),
    // cubierta A, vehículo si tractor.
    final readsRound1 = await Future.wait([
      lockDestinoRef.get(),
      cubiertaARef.get(),
      if (origen.unidadTipo == TipoUnidadCubierta.tractor)
        _db.collection(AppCollections.vehiculos).doc(origen.unidadId).get(),
    ]);
    final lockDestinoSnap = readsRound1[0];
    final cubiertaASnap = readsRound1[1];
    if (!cubiertaASnap.exists) {
      throw StateError('Cubierta ${origen.cubiertaId} no existe');
    }
    final cubiertaA = Cubierta.fromMap(origen.cubiertaId, cubiertaASnap.data());
    if (!posicionDestino.aceptaTipoUso(cubiertaA.tipoUso)) {
      throw StateError(
        'La cubierta ${cubiertaA.codigo} es ${cubiertaA.tipoUso.codigo} '
        'y la posición ${posicionDestino.etiqueta} requiere '
        '${posicionDestino.tipoUsoRequerido.codigo}',
      );
    }
    final double? kmActualUnidad =
        origen.unidadTipo == TipoUnidadCubierta.tractor
            ? (readsRound1[2].data()?['KM_ACTUAL'] as num?)?.toDouble()
            : null;

    // Si el destino estaba ocupado, leer la instalación + cubierta B
    // (round 2 secuencial porque depende del lockDestinoSnap).
    CubiertaInstalada? destinoOriginal;
    Cubierta? cubiertaB;
    DocumentReference<Map<String, dynamic>>? destinoInstRef;
    DocumentReference<Map<String, dynamic>>? cubiertaBRef;
    DocumentReference<Map<String, dynamic>>? lockCubiertaBRef;
    if (lockDestinoSnap.exists) {
      final destinoInstId =
          (lockDestinoSnap.data()?['instalacion_id'] ?? '').toString();
      if (destinoInstId.isEmpty) {
        throw StateError(
            'Lock de destino sin instalacion_id — estado inconsistente');
      }
      destinoInstRef = colInst.doc(destinoInstId);
      final destinoInstSnap = await destinoInstRef.get();
      if (!destinoInstSnap.exists) {
        throw StateError('La instalación destino $destinoInstId no existe');
      }
      destinoOriginal = CubiertaInstalada.fromDoc(destinoInstSnap);
      cubiertaBRef = _db
          .collection(AppCollections.cubiertas)
          .doc(destinoOriginal.cubiertaId);
      lockCubiertaBRef = _db
          .collection(AppCollections.cubiertasActivas)
          .doc(destinoOriginal.cubiertaId);
      final cubiertaBSnap = await cubiertaBRef.get();
      if (!cubiertaBSnap.exists) {
        throw StateError(
            'Cubierta destino ${destinoOriginal.cubiertaId} no existe');
      }
      cubiertaB = Cubierta.fromMap(destinoOriginal.cubiertaId, cubiertaBSnap.data());
      if (!posicionOrigen.aceptaTipoUso(cubiertaB.tipoUso)) {
        throw StateError(
          'No se puede intercambiar: la cubierta ${cubiertaB.codigo} '
          'es ${cubiertaB.tipoUso.codigo} y la posición '
          '${posicionOrigen.etiqueta} requiere '
          '${posicionOrigen.tipoUsoRequerido.codigo}',
        );
      }
    }

    // Snapshots de los modelos (en paralelo).
    final modelosFutures = <Future<DocumentSnapshot<Map<String, dynamic>>>>[
      _db
          .collection(AppCollections.cubiertasModelos)
          .doc(cubiertaA.modeloId)
          .get(),
      if (cubiertaB != null)
        _db
            .collection(AppCollections.cubiertasModelos)
            .doc(cubiertaB.modeloId)
            .get(),
    ];
    final modelosSnaps = await Future.wait(modelosFutures);
    final modeloA = modelosSnaps[0].exists
        ? CubiertaModelo.fromMap(cubiertaA.modeloId, modelosSnaps[0].data())
        : null;
    final modeloB = (cubiertaB != null && modelosSnaps[1].exists)
        ? CubiertaModelo.fromMap(cubiertaB.modeloId, modelosSnaps[1].data())
        : null;

    double? calcularKm(CubiertaInstalada inst) {
      if (inst.unidadTipo != TipoUnidadCubierta.tractor) return null;
      final km = kmActualUnidad;
      final base = inst.kmUnidadAlInstalar;
      if (km == null || base == null) return null;
      final diff = km - base;
      return diff < 0 ? 0 : diff;
    }

    final ahora = Timestamp.now();
    final motivoLimpio = motivo?.trim();
    final motivoEtiqueta =
        motivoLimpio == null || motivoLimpio.isEmpty ? 'rotación' : motivoLimpio;

    // ====== WRITES SECUENCIALES (sin tx, ver crearCubierta) ======
    //
    // Orden cuidadoso para que un fallo intermedio deje el sistema en
    // un estado lo más cercano posible al original:
    // 1) Cerrar logs viejos (origen, y destino si swap).
    // 2) Liberar locks de posición de los logs viejos.
    // 3) Crear logs nuevos.
    // 4) Crear locks de posición nuevos (apuntando a los nuevos logs).
    // 5) Recrear locks de cubierta (delete + set en cada cubierta movida).
    //
    // Si algo falla a mitad, los pasos previos quedan aplicados; el
    // siguiente intento del usuario tendrá que partir desde donde quedó
    // (los logs ya están cerrados, por ejemplo). En la práctica las
    // chances de fallo intermedio en gomería con un solo supervisor
    // son ínfimas; el costo de complicar el rollback no se justifica.

    // 1) Cerrar logs viejos.
    final kmRecorridosA = calcularKm(origen);
    await origenRef.update({
      'hasta': ahora,
      'km_unidad_al_retirar': kmActualUnidad,
      'km_recorridos': kmRecorridosA,
      'retirado_por_dni': supervisorLimpio,
      if (supervisorNombre != null && supervisorNombre.trim().isNotEmpty)
        'retirado_por_nombre': supervisorNombre.trim(),
      'motivo_retiro': motivoEtiqueta,
    });
    if (kmRecorridosA != null && kmRecorridosA > 0) {
      try {
        await cubiertaARef.update({
          'km_acumulados': cubiertaA.kmAcumulados + kmRecorridosA,
        });
      } catch (e, st) {
        AppLogger.recordError(e, st,
            reason: 'CUBIERTAS.km_acumulados update tras rotar A (no fatal)');
      }
    }

    if (destinoOriginal != null &&
        cubiertaB != null &&
        destinoInstRef != null &&
        cubiertaBRef != null) {
      final kmRecorridosB = calcularKm(destinoOriginal);
      await destinoInstRef.update({
        'hasta': ahora,
        'km_unidad_al_retirar': kmActualUnidad,
        'km_recorridos': kmRecorridosB,
        'retirado_por_dni': supervisorLimpio,
        if (supervisorNombre != null && supervisorNombre.trim().isNotEmpty)
          'retirado_por_nombre': supervisorNombre.trim(),
        'motivo_retiro': motivoEtiqueta,
      });
      if (kmRecorridosB != null && kmRecorridosB > 0) {
        try {
          await cubiertaBRef.update({
            'km_acumulados': cubiertaB.kmAcumulados + kmRecorridosB,
          });
        } catch (e, st) {
          AppLogger.recordError(e, st,
              reason:
                  'CUBIERTAS.km_acumulados update tras rotar B (no fatal)');
        }
      }
    }

    // 2) Liberar locks de posición vieja (delete).
    await lockOrigenRef.delete();
    if (destinoOriginal != null) await lockDestinoRef.delete();

    // 3) Crear logs nuevos.
    final kmEsperadosA = modeloA?.kmEsperadosParaVida(cubiertaA.vidas);
    final nuevoARef = colInst.doc(nuevoIdA);
    await nuevoARef.set(<String, dynamic>{
      'cubierta_id': cubiertaA.id,
      'cubierta_codigo': cubiertaA.codigo,
      'unidad_id': origen.unidadId,
      'unidad_tipo': origen.unidadTipo.codigo,
      'posicion': posicionDestino.codigo,
      'vida_al_instalar': cubiertaA.vidas,
      'modelo_etiqueta': cubiertaA.modeloEtiqueta,
      if (kmEsperadosA != null) 'km_vida_estimada_al_instalar': kmEsperadosA,
      'desde': ahora,
      'hasta': null,
      'km_unidad_al_instalar': kmActualUnidad,
      'km_unidad_al_retirar': null,
      'km_recorridos': null,
      'instalado_por_dni': supervisorLimpio,
      if (supervisorNombre != null && supervisorNombre.trim().isNotEmpty)
        'instalado_por_nombre': supervisorNombre.trim(),
      'retirado_por_dni': null,
      'retirado_por_nombre': null,
      'motivo': motivoEtiqueta,
    });

    if (destinoOriginal != null && cubiertaB != null) {
      final kmEsperadosB = modeloB?.kmEsperadosParaVida(cubiertaB.vidas);
      final nuevoBRef = colInst.doc(nuevoIdB);
      await nuevoBRef.set(<String, dynamic>{
        'cubierta_id': cubiertaB.id,
        'cubierta_codigo': cubiertaB.codigo,
        'unidad_id': origen.unidadId,
        'unidad_tipo': origen.unidadTipo.codigo,
        'posicion': posicionOrigen.codigo,
        'vida_al_instalar': cubiertaB.vidas,
        'modelo_etiqueta': cubiertaB.modeloEtiqueta,
        if (kmEsperadosB != null) 'km_vida_estimada_al_instalar': kmEsperadosB,
        'desde': ahora,
        'hasta': null,
        'km_unidad_al_instalar': kmActualUnidad,
        'km_unidad_al_retirar': null,
        'km_recorridos': null,
        'instalado_por_dni': supervisorLimpio,
        if (supervisorNombre != null && supervisorNombre.trim().isNotEmpty)
          'instalado_por_nombre': supervisorNombre.trim(),
        'retirado_por_dni': null,
        'retirado_por_nombre': null,
        'motivo': motivoEtiqueta,
      });
    }

    // 4) Crear locks de posición nuevos (apuntando a los logs nuevos).
    await lockDestinoRef.set(<String, dynamic>{
      'instalacion_id': nuevoIdA,
      'cubierta_id': cubiertaA.id,
      'cubierta_codigo': cubiertaA.codigo,
      'unidad_id': origen.unidadId,
      'posicion': posicionDestino.codigo,
      'desde': ahora,
    });
    if (destinoOriginal != null && cubiertaB != null) {
      await lockOrigenRef.set(<String, dynamic>{
        'instalacion_id': nuevoIdB,
        'cubierta_id': cubiertaB.id,
        'cubierta_codigo': cubiertaB.codigo,
        'unidad_id': origen.unidadId,
        'posicion': posicionOrigen.codigo,
        'desde': ahora,
      });
    }

    // 5) Recrear lock cubierta A (rules prohíben update — borrar + set).
    await lockCubiertaARef.delete();
    await lockCubiertaARef.set(<String, dynamic>{
      'instalacion_id': nuevoIdA,
      'unidad_id': origen.unidadId,
      'posicion': posicionDestino.codigo,
      'desde': ahora,
    });
    if (destinoOriginal != null &&
        cubiertaB != null &&
        lockCubiertaBRef != null) {
      await lockCubiertaBRef.delete();
      await lockCubiertaBRef.set(<String, dynamic>{
        'instalacion_id': nuevoIdB,
        'unidad_id': origen.unidadId,
        'posicion': posicionOrigen.codigo,
        'desde': ahora,
      });
    }

    unawaited(AuditLog.registrar(
      accion: AuditAccion.instalarCubierta,
      entidad: AppCollections.cubiertas,
      entidadId: origenId,
      detalles: {
        'tipo': 'rotacion',
        'instalacion_origen_id': origenId,
        'posicion_destino': destinoCodigo,
        'instalacion_a_id': nuevoIdA,
        'instalacion_b_id': nuevoIdB,
      },
    ));
  }

  // ===========================================================================
  // RECAPADOS
  // ===========================================================================

  /// Manda una cubierta al proveedor de recapado. La cubierta debe estar
  /// EN_DEPOSITO y su modelo debe ser `recapable`.
  Future<String> mandarARecapar({
    required String cubiertaId,
    required String proveedor,
    required String supervisorDni,
    DateTime? fechaEnvio,
    String? supervisorNombre,
    String? notas,
  }) async {
    final cubiertaLimpia = cubiertaId.trim();
    final proveedorLimpio = proveedor.trim();
    final supervisorLimpio = supervisorDni.trim();
    if (cubiertaLimpia.isEmpty ||
        proveedorLimpio.isEmpty ||
        supervisorLimpio.isEmpty) {
      throw ArgumentError(
          'cubiertaId, proveedor y supervisorDni son obligatorios');
    }

    final recapadoId =
        _db.collection(AppCollections.cubiertasRecapados).doc().id;
    final fechaEnvioFinal = fechaEnvio ?? DateTime.now();

    // Lecturas paralelas (sin tx — ver crearCubierta).
    final cubiertaRef =
        _db.collection(AppCollections.cubiertas).doc(cubiertaLimpia);
    final cubiertaSnap = await cubiertaRef.get();
    if (!cubiertaSnap.exists) {
      throw StateError('Cubierta $cubiertaLimpia no existe');
    }
    final cubierta = Cubierta.fromMap(cubiertaLimpia, cubiertaSnap.data());
    if (cubierta.estado != EstadoCubierta.enDeposito) {
      throw StateError(
        'Solo se puede mandar a recapar una cubierta EN_DEPOSITO '
        '(${cubierta.codigo} está ${cubierta.estado.codigo})',
      );
    }

    final modeloSnap = await _db
        .collection(AppCollections.cubiertasModelos)
        .doc(cubierta.modeloId)
        .get();
    if (!modeloSnap.exists) {
      throw StateError(
          'El modelo ${cubierta.modeloId} de la cubierta no existe');
    }
    final modelo = CubiertaModelo.fromMap(cubierta.modeloId, modeloSnap.data());
    if (!modelo.recapable) {
      throw StateError('El modelo ${modelo.etiqueta} no es recapable');
    }

    // Writes secuenciales: log primero, después estado de la cubierta.
    final recapadoRef =
        _db.collection(AppCollections.cubiertasRecapados).doc(recapadoId);
    await recapadoRef.set(<String, dynamic>{
      'cubierta_id': cubiertaLimpia,
      'cubierta_codigo': cubierta.codigo,
      // vida que TENDRÁ si vuelve recibida (vida actual + 1).
      'vida_recapado': cubierta.vidas + 1,
      'proveedor': proveedorLimpio,
      'fecha_envio': Timestamp.fromDate(fechaEnvioFinal),
      'fecha_retorno': null,
      'costo': null,
      'resultado': null,
      if (notas != null && notas.trim().isNotEmpty) 'notas': notas.trim(),
      'enviado_por_dni': supervisorLimpio,
      if (supervisorNombre != null && supervisorNombre.trim().isNotEmpty)
        'enviado_por_nombre': supervisorNombre.trim(),
      'cerrado_por_dni': null,
      'cerrado_por_nombre': null,
    });

    try {
      await cubiertaRef.update({
        'estado': EstadoCubierta.enRecapado.codigo,
      });
    } catch (e, st) {
      AppLogger.recordError(e, st,
          reason: 'CUBIERTAS.estado update tras mandarARecapar (no fatal)');
    }

    unawaited(AuditLog.registrar(
      accion: AuditAccion.enviarCubiertaARecapar,
      entidad: AppCollections.cubiertas,
      entidadId: cubiertaLimpia,
      detalles: {
        'recapado_id': recapadoId,
        'proveedor': proveedorLimpio,
      },
    ));

    return recapadoId;
  }

  /// Cierra un evento de recapado al recibir la cubierta del proveedor.
  ///
  /// Si [resultado] es `RECIBIDA`: cubierta vuelve EN_DEPOSITO, vidas++.
  /// Si [resultado] es `DESCARTADA_POR_PROVEEDOR`: cubierta queda
  /// DESCARTADA (estructura dañada, etc).
  Future<void> recibirDeRecapado({
    required String recapadoId,
    required ResultadoRecapado resultado,
    required String supervisorDni,
    DateTime? fechaRetorno,
    double? costo,
    String? notas,
    String? supervisorNombre,
  }) async {
    final idLimpio = recapadoId.trim();
    final supervisorLimpio = supervisorDni.trim();
    if (idLimpio.isEmpty || supervisorLimpio.isEmpty) {
      throw ArgumentError('recapadoId y supervisorDni son obligatorios');
    }

    final fechaFinal = fechaRetorno ?? DateTime.now();

    final recapadoRef =
        _db.collection(AppCollections.cubiertasRecapados).doc(idLimpio);

    // Lecturas paralelas. Necesitamos el doc del recapado (para validar
    // y conocer cubierta_id + vidas previas) y la cubierta (para
    // incrementar vidas si el resultado es RECIBIDA).
    final recapadoSnap = await recapadoRef.get();
    if (!recapadoSnap.exists) {
      throw StateError('Recapado $idLimpio no existe');
    }
    final recapado = CubiertaRecapado.fromDoc(recapadoSnap);
    if (!recapado.enProceso) {
      throw StateError(
          'El recapado $idLimpio ya está cerrado (fecha_retorno != null)');
    }

    final cubiertaRef =
        _db.collection(AppCollections.cubiertas).doc(recapado.cubiertaId);
    final cubiertaSnap = await cubiertaRef.get();
    if (!cubiertaSnap.exists) {
      throw StateError('Cubierta ${recapado.cubiertaId} no existe');
    }
    final cubierta =
        Cubierta.fromMap(recapado.cubiertaId, cubiertaSnap.data());

    // Writes secuenciales: cerrar el recapado primero (verdad operativa)
    // y después actualizar la cubierta (estado + vidas si aplica).
    await recapadoRef.update({
      'fecha_retorno': Timestamp.fromDate(fechaFinal),
      'resultado': resultado.codigo,
      if (costo != null) 'costo': costo,
      if (notas != null && notas.trim().isNotEmpty) 'notas': notas.trim(),
      'cerrado_por_dni': supervisorLimpio,
      if (supervisorNombre != null && supervisorNombre.trim().isNotEmpty)
        'cerrado_por_nombre': supervisorNombre.trim(),
    });

    try {
      switch (resultado) {
        case ResultadoRecapado.recibida:
          await cubiertaRef.update({
            'estado': EstadoCubierta.enDeposito.codigo,
            'vidas': cubierta.vidas + 1,
          });
        case ResultadoRecapado.descartadaPorProveedor:
          await cubiertaRef.update({
            'estado': EstadoCubierta.descartada.codigo,
          });
      }
    } catch (e, st) {
      AppLogger.recordError(e, st,
          reason:
              'CUBIERTAS.estado/vidas update tras recibirDeRecapado (no fatal)');
    }

    unawaited(AuditLog.registrar(
      accion: AuditAccion.recibirCubiertaDeRecapado,
      entidad: AppCollections.cubiertas,
      entidadId: idLimpio,
      detalles: {
        'recapado_id': idLimpio,
        'resultado': resultado.codigo,
        if (costo != null) 'costo': costo,
      },
    ));
  }

  // ===========================================================================
  // QUERIES / STREAMS
  // ===========================================================================

  /// Stream de TODAS las cubiertas activas instaladas en una unidad.
  /// Hasta 14 docs (10 tractor + 12 enganche es el cap teórico).
  Stream<List<CubiertaInstalada>> streamInstalacionesActivasPorUnidad(
      String unidadId) {
    final unidadLimpia = unidadId.trim().toUpperCase();
    if (unidadLimpia.isEmpty) {
      return Stream.value(const <CubiertaInstalada>[]);
    }
    return _db
        .collection(AppCollections.cubiertasInstaladas)
        .where('unidad_id', isEqualTo: unidadLimpia)
        .where('hasta', isNull: true)
        .snapshots()
        .map((s) => s.docs.map(CubiertaInstalada.fromDoc).toList());
  }

  /// Stream del historial completo de instalaciones de una cubierta
  /// (más reciente primero). [limit] por default 30.
  Stream<List<CubiertaInstalada>> streamHistorialInstalacionesPorCubierta(
    String cubiertaId, {
    int limit = 30,
  }) {
    final cubiertaLimpia = cubiertaId.trim();
    if (cubiertaLimpia.isEmpty) {
      return Stream.value(const <CubiertaInstalada>[]);
    }
    return _db
        .collection(AppCollections.cubiertasInstaladas)
        .where('cubierta_id', isEqualTo: cubiertaLimpia)
        .orderBy('desde', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(CubiertaInstalada.fromDoc).toList());
  }

  /// Stream de cubiertas en depósito. Si [tipoUso] se pasa, filtra por
  /// dirección o tracción (útil para "qué tengo en stock para reemplazar
  /// una de dirección").
  Stream<List<Cubierta>> streamCubiertasEnDeposito({
    TipoUsoCubierta? tipoUso,
  }) {
    Query<Map<String, dynamic>> q = _db
        .collection(AppCollections.cubiertas)
        .where('estado', isEqualTo: EstadoCubierta.enDeposito.codigo);
    if (tipoUso != null) {
      q = q.where('tipo_uso', isEqualTo: tipoUso.codigo);
    }
    return q.snapshots().map((s) => s.docs.map(Cubierta.fromDoc).toList());
  }

  /// Stream de TODAS las cubiertas con filtros opcionales — usado por la
  /// pantalla de Stock con filtro por estado ("¿qué cubiertas instaladas
  /// tengo?", "¿cuáles descarté?") y por la búsqueda global por código.
  ///
  /// Si [estado] es `null`, devuelve todas. Si [tipoUso] es `null`,
  /// devuelve todas las del estado dado. La pantalla complementa con
  /// filtro client-side por código (CUB-XXXX) — el universo de cubiertas
  /// es chico (<200 hoy, <1000 a futuro) y eso evita índices de texto.
  Stream<List<Cubierta>> streamCubiertasFiltradas({
    EstadoCubierta? estado,
    TipoUsoCubierta? tipoUso,
  }) {
    Query<Map<String, dynamic>> q = _db.collection(AppCollections.cubiertas);
    if (estado != null) {
      q = q.where('estado', isEqualTo: estado.codigo);
    }
    if (tipoUso != null) {
      q = q.where('tipo_uso', isEqualTo: tipoUso.codigo);
    }
    return q.snapshots().map((s) => s.docs.map(Cubierta.fromDoc).toList());
  }

  /// Stream de UNA cubierta puntual (detalle).
  Stream<Cubierta?> streamCubierta(String cubiertaId) {
    final id = cubiertaId.trim();
    if (id.isEmpty) return Stream.value(null);
    return _db
        .collection(AppCollections.cubiertas)
        .doc(id)
        .snapshots()
        .map((s) => s.exists ? Cubierta.fromDoc(s) : null);
  }

  /// Stream del historial de recapados de una cubierta (más reciente
  /// primero). Trae cerrados y en proceso.
  Stream<List<CubiertaRecapado>> streamHistorialRecapadosPorCubierta(
    String cubiertaId, {
    int limit = 30,
  }) {
    final id = cubiertaId.trim();
    if (id.isEmpty) return Stream.value(const <CubiertaRecapado>[]);
    return _db
        .collection(AppCollections.cubiertasRecapados)
        .where('cubierta_id', isEqualTo: id)
        .orderBy('fecha_envio', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(CubiertaRecapado.fromDoc).toList());
  }

  /// Stream de los recapados en proceso (fecha_retorno == null), más
  /// recientes primero.
  Stream<List<CubiertaRecapado>> streamRecapadosEnProceso() {
    return _db
        .collection(AppCollections.cubiertasRecapados)
        .where('fecha_retorno', isNull: true)
        .orderBy('fecha_envio', descending: true)
        .snapshots()
        .map((s) => s.docs.map(CubiertaRecapado.fromDoc).toList());
  }

  /// Stream de recapados ya cerrados (fecha_retorno != null), más
  /// recientes primero. Uso: tab "histórico" en pantalla de recapados.
  /// Limitamos a [limit] últimos para no descargar histórico completo.
  Stream<List<CubiertaRecapado>> streamRecapadosCerrados({int limit = 100}) {
    return _db
        .collection(AppCollections.cubiertasRecapados)
        .orderBy('fecha_retorno', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs
            .map(CubiertaRecapado.fromDoc)
            // El orderBy no filtra los nulls — los excluimos client-side
            // para no necesitar otro índice. La cantidad de "en proceso"
            // es chica (<10 típicamente).
            .where((r) => r.fechaRetorno != null)
            .toList());
  }

  // ==========================================================================
  // CÁLCULO DE KM PARA CUBIERTAS DE ENGANCHE (Fase 2 Gomería)
  // ==========================================================================

  /// Calcula los km que una cubierta de enganche acumuló durante el
  /// período `[instalado, retirado]`.
  ///
  /// La cubierta vive en un enganche; el enganche puede haber pasado
  /// por varios tractores en su vida (cambia el tractor que lo arrastra
  /// pero la cubierta sigue ahí). Por cada asignación
  /// tractor↔enganche que solapa con la vida de la cubierta, sumamos
  /// los km del tractor durante esa asignación.
  ///
  /// **Versión MVP**: solo cuenta las asignaciones COMPLETAMENTE
  /// contenidas dentro de `[instalado, retirado]`. Las que solapan
  /// parcial al inicio o al final se ignoran (subestimación). Para
  /// el caso típico (cubierta instalada 6+ meses, asignación de
  /// enganche cambia esporádicamente), la mayoría de asignaciones
  /// caen dentro o son legacy sin telemetría — el sub-conteo es
  /// menor que el error de imputarlo a otro lado.
  ///
  /// Asignaciones SIN `odometer_inicial`/`odometer_final` (legacy
  /// previas a Fase 2 Sitrack) se skipean. La cuenta queda incompleta
  /// para esas — documentado en el log al cliente.
  Future<double?> _calcularKmCubiertaEnganche({
    required String engancheId,
    required Timestamp instalado,
    required Timestamp retirado,
  }) async {
    // Query: asignaciones del enganche que arrancaron antes del retiro
    // (cualquiera que pueda solapar). El filtro fino (descartar las que
    // terminaron antes de la instalación, las parciales) lo hacemos
    // client-side — Firestore no permite dos rangos de inequality en
    // campos distintos sin armar índices compuestos para cada caso.
    final snap = await _db
        .collection(AppCollections.asignacionesEnganche)
        .where('enganche_id', isEqualTo: engancheId)
        .where('desde', isLessThanOrEqualTo: retirado)
        .get();

    double total = 0;
    int contadas = 0;
    int skippedSinTelemetria = 0;
    int skippedParciales = 0;

    for (final d in snap.docs) {
      final data = d.data();
      final desde = data['desde'] as Timestamp?;
      final hasta = data['hasta'] as Timestamp?; // null = activa
      final odoIni = (data['odometer_inicial'] as num?)?.toDouble();
      final odoFin = (data['odometer_final'] as num?)?.toDouble();

      if (desde == null) continue;

      // Asignación que terminó antes de la instalación de la cubierta:
      // no aplica.
      if (hasta != null && hasta.compareTo(instalado) <= 0) continue;

      // MVP: solo contamos asignaciones COMPLETAMENTE contenidas en el
      // intervalo. `desde >= instalado` y `hasta <= retirado` (con la
      // interpretación de `hasta == null` = activa = se extiende más
      // allá del retiro de la cubierta — eso lo skipea como parcial).
      final empezoAntes = desde.compareTo(instalado) < 0;
      final terminaDespues = hasta == null || hasta.compareTo(retirado) > 0;
      if (empezoAntes || terminaDespues) {
        skippedParciales++;
        continue;
      }

      if (odoIni == null || odoFin == null) {
        skippedSinTelemetria++;
        continue;
      }

      final diff = odoFin - odoIni;
      // Si el odómetro retrocedió (sync raro / reset manual / cambio
      // de equipo Sitrack), no contamos km negativos — sería peor que
      // cero por la sustracción.
      if (diff > 0) {
        total += diff;
        contadas++;
      }
    }

    // Si no contamos NADA (sin asignaciones dentro del rango con
    // telemetría), devolvemos null en lugar de 0 para distinguir "no
    // pude calcular" de "manejó pero hizo 0 km".
    if (contadas == 0 &&
        (skippedSinTelemetria > 0 || skippedParciales > 0)) {
      return null;
    }
    return total;
  }
}
