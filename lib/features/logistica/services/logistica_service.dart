import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../models/empresa_logistica.dart';
import '../models/tarifa_logistica.dart';
import '../models/ubicacion_logistica.dart';
import 'viajes_service.dart';

/// CRUD del módulo Logística. Centraliza lógica de creación + auditoría
/// (creado_en/creado_por) + validaciones simples antes del write.
///
/// Nota Windows: este service NO usa `runTransaction`. La unicidad de
/// nombres por colección la garantizan las queries del cliente al crear
/// (mostramos error si ya existe). Si en el futuro hay race con
/// múltiples operadores creando exactamente el mismo nombre al mismo
/// tiempo, agregamos un doc-id determinista (slugify del nombre) para
/// que Firestore rechace el duplicado a nivel de doc, sin transactions.
class LogisticaService {
  LogisticaService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ─── EMPRESAS ──────────────────────────────────────────────────────────
  static CollectionReference<Map<String, dynamic>> get empresasCol =>
      _db.collection(AppCollections.empresasLogistica);

  /// Stream de empresas filtradas opcionalmente por tipo. Sin filtro
  /// devuelve todas (clientes + dadores).
  static Stream<List<EmpresaLogistica>> streamEmpresas({
    TipoEmpresaLogistica? tipo,
    bool soloActivas = false,
  }) {
    Query<Map<String, dynamic>> q = empresasCol.orderBy('nombre');
    if (tipo != null) q = q.where('tipo', isEqualTo: tipo.codigo);
    if (soloActivas) q = q.where('activa', isEqualTo: true);
    return q.snapshots().map(
          (s) => s.docs.map(EmpresaLogistica.fromDoc).toList(),
        );
  }

  /// One-shot get de una empresa por ID. Devuelve null si no existe.
  /// Pensado para poblar el dropdown de productos en el form de viaje
  /// (cada tramo lee la empresa origen de su tarifa para mostrar la
  /// lista de productos catalogados — campo `productos: List<String>`).
  static Future<EmpresaLogistica?> empresaPorId(String id) async {
    if (id.isEmpty) return null;
    final snap = await empresasCol.doc(id).get();
    final data = snap.data();
    if (!snap.exists || data == null) return null;
    return EmpresaLogistica.fromMap(snap.id, data);
  }

  /// Crea una empresa. Tira [StateError] si ya existe otra con el mismo
  /// nombre (case-insensitive) para evitar duplicados por typo.
  static Future<DocumentReference<Map<String, dynamic>>> crearEmpresa({
    required String nombre,
    required TipoEmpresaLogistica tipo,
    String? apodo,
    String? cuit,
    String? contacto,
    String? nombreContacto,
  }) async {
    final nombreNorm = nombre.trim().toUpperCase();
    if (nombreNorm.isEmpty) {
      throw ArgumentError('El nombre de la empresa no puede estar vacío.');
    }
    // Pre-check de unicidad por nombre. El campo `nombre` se persiste SIEMPRE
    // normalizado a upper (ver `add` abajo), así que una query puntual por
    // igualdad alcanza — antes se bajaba la colección entera para comparar en
    // cliente (full-collection read evitable, audit 2026-06-04). Best-effort
    // (sin transaction): suficiente para operadores humanos cargando de a uno.
    final dup = await empresasCol
        .where('nombre', isEqualTo: nombreNorm)
        .limit(1)
        .get();
    if (dup.docs.isNotEmpty) {
      throw StateError('Ya existe una empresa con ese nombre.');
    }
    final apodoTrim = apodo?.trim() ?? '';
    final nombreContactoTrim = nombreContacto?.trim() ?? '';
    return empresasCol.add({
      'nombre': nombreNorm,
      if (apodoTrim.isNotEmpty) 'apodo': apodoTrim,
      'tipo': tipo.codigo,
      if (cuit != null && cuit.trim().isNotEmpty) 'cuit': cuit.trim(),
      if (contacto != null && contacto.trim().isNotEmpty)
        'contacto': contacto.trim(),
      if (nombreContactoTrim.isNotEmpty) 'nombre_contacto': nombreContactoTrim,
      'activa': true,
      'creado_en': FieldValue.serverTimestamp(),
      'creado_por': PrefsService.dni,
    });
  }

  static Future<void> actualizarEmpresa({
    required String id,
    required Map<String, dynamic> cambios,
  }) async {
    await empresasCol.doc(id).update(cambios);
  }

  /// Cuenta cuántas tarifas usan esta empresa (como origen o destino).
  static Future<int> contarTarifasQueUsanEmpresa(String empresaId) async {
    if (empresaId.isEmpty) return 0;
    final results = await Future.wait([
      tarifasCol.where('empresa_origen_id', isEqualTo: empresaId).count().get(),
      tarifasCol
          .where('empresa_destino_id', isEqualTo: empresaId)
          .count()
          .get(),
    ]);
    return (results[0].count ?? 0) + (results[1].count ?? 0);
  }

  /// Cuenta cuántas ubicaciones tienen esta empresa asociada en su
  /// `empresa_ids`.
  static Future<int> contarUbicacionesQueUsanEmpresa(String empresaId) async {
    if (empresaId.isEmpty) return 0;
    final res = await ubicacionesCol
        .where('empresa_ids', arrayContains: empresaId)
        .count()
        .get();
    return res.count ?? 0;
  }

  /// Elimina (hard-delete) una empresa de Firestore. Antes verifica
  /// que no esté siendo referenciada por tarifas activas o por
  /// ubicaciones — sino tira [StateError] con mensaje accionable.
  ///
  /// Viajes históricos NO se rompen: cada viaje persiste
  /// `tarifa_snapshot` con el nombre de la empresa cacheado al
  /// momento del viaje (no apunta por id).
  static Future<void> eliminarEmpresa(String id) async {
    if (id.isEmpty) {
      throw ArgumentError('id de empresa vacío.');
    }
    final results = await Future.wait([
      contarTarifasQueUsanEmpresa(id),
      contarUbicacionesQueUsanEmpresa(id),
    ]);
    final enTarifas = results[0];
    final enUbicaciones = results[1];
    if (enTarifas > 0 || enUbicaciones > 0) {
      final partes = <String>[];
      if (enTarifas > 0) {
        partes.add('$enTarifas ${enTarifas == 1 ? "tarifa" : "tarifas"}');
      }
      if (enUbicaciones > 0) {
        partes.add(
          '$enUbicaciones ${enUbicaciones == 1 ? "ubicación" : "ubicaciones"}',
        );
      }
      throw StateError(
        'No se puede eliminar: la empresa está usada en ${partes.join(" y ")}. '
        'Primero borrá o reasigná esas referencias.',
      );
    }
    await empresasCol.doc(id).delete();
  }

  /// Setea la lista completa de productos de una empresa. Lista
  /// vacía → borra el campo productos (no queda lista vacía en
  /// Firestore para mantener docs livianos).
  static Future<void> setProductosDeEmpresa({
    required String id,
    required List<String> productos,
  }) async {
    final cambios = <String, dynamic>{};
    if (productos.isEmpty) {
      cambios['productos'] = FieldValue.delete();
    } else {
      // Trim + dedup case-insensitive (manteniendo grafía del
      // primer ingreso). Útil si el operador agrega "Soja" y
      // después "SOJA" — guardamos solo la primera grafía.
      final seen = <String>{};
      final limpios = <String>[];
      for (final p in productos) {
        final t = p.trim();
        if (t.isEmpty) continue;
        final key = t.toUpperCase();
        if (seen.contains(key)) continue;
        seen.add(key);
        limpios.add(t);
      }
      cambios['productos'] = limpios;
    }
    await empresasCol.doc(id).update(cambios);
  }

  // ─── UBICACIONES ───────────────────────────────────────────────────────
  static CollectionReference<Map<String, dynamic>> get ubicacionesCol =>
      _db.collection(AppCollections.ubicacionesLogistica);

  static Stream<List<UbicacionLogistica>> streamUbicaciones({
    bool soloActivas = false,
  }) {
    Query<Map<String, dynamic>> q = ubicacionesCol.orderBy('nombre');
    if (soloActivas) q = q.where('activa', isEqualTo: true);
    return q.snapshots().map(
          (s) => s.docs.map(UbicacionLogistica.fromDoc).toList(),
        );
  }

  static Future<DocumentReference<Map<String, dynamic>>> crearUbicacion({
    required String nombre,
    required String localidad,
    required String provincia,
    String? direccion,
    double? lat,
    double? lng,
    List<String> empresaIds = const [],
    List<String> empresaNombres = const [],
  }) async {
    final nombreNorm = nombre.trim().toUpperCase();
    if (nombreNorm.isEmpty) {
      throw ArgumentError('El nombre de la ubicación no puede estar vacío.');
    }
    if (localidad.trim().isEmpty || provincia.trim().isEmpty) {
      throw ArgumentError('Localidad y provincia son obligatorios.');
    }
    if (empresaIds.length != empresaNombres.length) {
      throw ArgumentError(
          'empresaIds y empresaNombres deben tener la misma longitud.');
    }
    // Pre-check unicidad: el "nombre" de una ubicación es el alias
    // operativo (ej. "Acopio Lartirigoyen — Tres Arroyos") y debe ser
    // único para que las tarifas no muestren ambigüedad. El nombre se
    // persiste normalizado a upper (ver `add` abajo) → query puntual por
    // igualdad en vez de bajar la colección entera (audit 2026-06-04).
    final dup = await ubicacionesCol
        .where('nombre', isEqualTo: nombreNorm)
        .limit(1)
        .get();
    if (dup.docs.isNotEmpty) {
      throw StateError('Ya existe una ubicación con ese nombre.');
    }
    return ubicacionesCol.add({
      'nombre': nombreNorm,
      'localidad': localidad.trim(),
      'provincia': provincia.trim(),
      if (direccion != null && direccion.trim().isNotEmpty)
        'direccion': direccion.trim(),
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (empresaIds.isNotEmpty) 'empresa_ids': empresaIds,
      if (empresaNombres.isNotEmpty) 'empresa_nombres': empresaNombres,
      'activa': true,
      'creado_en': FieldValue.serverTimestamp(),
      'creado_por': PrefsService.dni,
    });
  }

  /// Reescribe la lista completa de empresas asociadas a una ubicación.
  /// Acepta listas vacías para "quitar todas las empresas". Borra los
  /// campos legacy (`empresa_id`/`empresa_nombre`) si existían.
  static Future<void> setEmpresasDeUbicacion({
    required String id,
    required List<String> empresaIds,
    required List<String> empresaNombres,
  }) async {
    if (empresaIds.length != empresaNombres.length) {
      throw ArgumentError(
          'empresaIds y empresaNombres deben tener la misma longitud.');
    }
    final cambios = <String, dynamic>{
      // Borrar campos legacy si los tenía — el modelo de M:N
      // reemplaza al singular.
      'empresa_id': FieldValue.delete(),
      'empresa_nombre': FieldValue.delete(),
    };
    if (empresaIds.isEmpty) {
      cambios['empresa_ids'] = FieldValue.delete();
      cambios['empresa_nombres'] = FieldValue.delete();
    } else {
      cambios['empresa_ids'] = empresaIds;
      cambios['empresa_nombres'] = empresaNombres;
    }
    await ubicacionesCol.doc(id).update(cambios);
  }

  static Future<void> actualizarUbicacion({
    required String id,
    required Map<String, dynamic> cambios,
  }) async {
    await ubicacionesCol.doc(id).update(cambios);
  }

  /// Setea las ubicaciones asociadas a una empresa (sentido inverso
  /// del N:M — para el caso de uso "cada empresa tiene N ubicaciones
  /// de carga/descarga"). Actualiza el `empresa_ids` / `empresa_nombres`
  /// de cada ubicación afectada con un batch.
  ///
  /// `ubicacionIds` es la lista nueva. El service:
  ///   1. Lee qué ubicaciones tienen actualmente esta empresa
  ///      asociada (`empresa_ids array-contains empresaId`).
  ///   2. Calcula diff con la lista nueva: ubicaciones a agregar y a
  ///      quitar.
  ///   3. Hace los updates en un batch (atómico).
  ///
  /// El campo `empresa_nombres` se mantiene sincronizado: al agregar
  /// se appendea el nombre actual; al quitar se borra el del array
  /// (con `arrayRemove` matcheando string exacto). Si la empresa
  /// cambió de nombre y un doc viejo tiene el viejo, ese stale
  /// queda — se limpia entrando a la ubicación y re-asignando, no
  /// es bloqueante.
  static Future<void> setUbicacionesDeEmpresa({
    required String empresaId,
    required String empresaNombre,
    required List<String> ubicacionIds,
  }) async {
    if (empresaId.isEmpty) {
      throw ArgumentError('empresaId vacío.');
    }
    final actualesSnap = await ubicacionesCol
        .where('empresa_ids', arrayContains: empresaId)
        .get();
    final actuales = actualesSnap.docs.map((d) => d.id).toSet();
    final nuevas = ubicacionIds.toSet();
    final paraAgregar = nuevas.difference(actuales);
    final paraQuitar = actuales.difference(nuevas);

    if (paraAgregar.isEmpty && paraQuitar.isEmpty) return;

    final batch = _db.batch();
    for (final id in paraAgregar) {
      batch.update(ubicacionesCol.doc(id), {
        'empresa_ids': FieldValue.arrayUnion([empresaId]),
        'empresa_nombres': FieldValue.arrayUnion([empresaNombre]),
      });
    }
    for (final id in paraQuitar) {
      batch.update(ubicacionesCol.doc(id), {
        'empresa_ids': FieldValue.arrayRemove([empresaId]),
        'empresa_nombres': FieldValue.arrayRemove([empresaNombre]),
      });
    }
    await batch.commit();
  }

  /// Cuenta cuántas tarifas usan esta ubicación (como origen o destino).
  /// Útil antes de borrar — si > 0, NO se debe permitir hard-delete
  /// porque rompería los snapshots históricos de viajes pasados.
  static Future<int> contarTarifasQueUsanUbicacion(String ubicacionId) async {
    if (ubicacionId.isEmpty) return 0;
    // Firestore no soporta OR de queries en un solo round-trip;
    // hacemos 2 queries paralelas y sumamos los counts.
    final results = await Future.wait([
      tarifasCol
          .where('ubicacion_origen_id', isEqualTo: ubicacionId)
          .count()
          .get(),
      tarifasCol
          .where('ubicacion_destino_id', isEqualTo: ubicacionId)
          .count()
          .get(),
    ]);
    return (results[0].count ?? 0) + (results[1].count ?? 0);
  }

  /// Elimina (hard-delete) una ubicación de Firestore. Solo se permite
  /// si NO está siendo usada por ninguna tarifa — sino tira
  /// [StateError] con un mensaje accionable.
  ///
  /// Si la ubicación tiene viajes históricos asociados, esos viajes
  /// conservan el `tarifaSnapshot` con la etiqueta cacheada al momento
  /// del viaje (no se rompen). Por eso es seguro borrar acá: las
  /// tarifas son la única referencia "viva" que apunta por id.
  static Future<void> eliminarUbicacion(String id) async {
    if (id.isEmpty) {
      throw ArgumentError('id de ubicación vacío.');
    }
    final usos = await contarTarifasQueUsanUbicacion(id);
    if (usos > 0) {
      throw StateError(
        'No se puede eliminar: la ubicación está en $usos '
        '${usos == 1 ? "tarifa" : "tarifas"} activa(s). '
        'Primero borrá o reasigná esas tarifas.',
      );
    }
    await ubicacionesCol.doc(id).delete();
  }

  // ─── TARIFAS ───────────────────────────────────────────────────────────
  static CollectionReference<Map<String, dynamic>> get tarifasCol =>
      _db.collection(AppCollections.tarifasLogistica);

  /// Stream de tarifas. Por default ordenadas por `creado_en desc` (las
  /// nuevas arriba). Filtros opcionales para listado / búsqueda futura.
  static Stream<List<TarifaLogistica>> streamTarifas({
    bool soloActivas = false,
  }) {
    Query<Map<String, dynamic>> q =
        tarifasCol.orderBy('creado_en', descending: true);
    if (soloActivas) q = q.where('activa', isEqualTo: true);
    return q.snapshots().map(
          (s) => s.docs.map(TarifaLogistica.fromDoc).toList(),
        );
  }

  /// Crea una tarifa. Snapshot-ea nombres de empresa/ubicación al
  /// momento del create — si después se renombra una empresa/ubicación,
  /// la tarifa sigue mostrando el nombre que tenía cuando se creó (lo
  /// mismo que hace VOLVO_ALERTAS con el chofer al disparar el evento).
  static Future<DocumentReference<Map<String, dynamic>>> crearTarifa({
    required TipoCargaLogistica tipoCarga,
    String? dadorId,
    String? dadorNombre,
    double? porcentajeComisionDador,
    double? montoFijoDador,
    required String empresaOrigenId,
    required String empresaOrigenNombre,
    required String ubicacionOrigenId,
    required String ubicacionOrigenEtiqueta,
    required String empresaDestinoId,
    required String empresaDestinoNombre,
    required String ubicacionDestinoId,
    required String ubicacionDestinoEtiqueta,
    required FleteLogistica flete,
    required UnidadTarifa unidadTarifa,
    required double tarifaReal,
    required double tarifaChofer,
    double? montoFijoChofer,
    String? producto,
    String? notas,
  }) async {
    // Validaciones de negocio:
    if (tipoCarga == TipoCargaLogistica.terceros) {
      if (dadorId == null || dadorId.isEmpty) {
        throw ArgumentError(
            'Si la carga es de TERCEROS, el dador es obligatorio.');
      }
    }
    // 0 es válido = "tarifa por definir" (alineado con el form desde
    // 2026-05-14) y necesario para el modo "monto fijo por viaje", donde la
    // tarifa_chofer (%) no se usa y queda en 0. Solo rechazamos negativos.
    if (tarifaReal < 0 || tarifaChofer < 0) {
      throw ArgumentError('Las tarifas no pueden ser negativas.');
    }
    if (tarifaReal > 0 && tarifaChofer > 0 && tarifaChofer > tarifaReal) {
      throw ArgumentError(
          'La tarifa del chofer no puede superar la tarifa real.');
    }
    if (porcentajeComisionDador != null) {
      if (porcentajeComisionDador < 0 || porcentajeComisionDador > 100) {
        throw ArgumentError(
            'El porcentaje de comisión debe estar entre 0 y 100.');
      }
    }
    if (montoFijoDador != null && montoFijoDador <= 0) {
      throw ArgumentError('El monto fijo del dador debe ser mayor a 0.');
    }
    if (montoFijoChofer != null && montoFijoChofer <= 0) {
      throw ArgumentError(
          'El monto fijo del chofer debe ser mayor a 0 (dejá vacío para usar el 18%).');
    }

    // Primera vigencia del historial de precios — los importes del alta,
    // vigentes desde hoy. (`serverTimestamp()` no se permite dentro de un
    // array, así que `desde`/`registradoEn` van con client-time.)
    final ahora = DateTime.now();
    final vigenciaInicial = TarifaVigencia(
      desde: ahora,
      tarifaReal: tarifaReal,
      tarifaChofer: tarifaChofer,
      montoFijoChofer: montoFijoChofer,
      porcentajeComisionDador: porcentajeComisionDador,
      montoFijoDador: montoFijoDador,
      registradoEn: ahora,
      registradoPorDni: PrefsService.dni,
    );
    return tarifasCol.add({
      'tipo_carga': tipoCarga.codigo,
      if (dadorId != null) 'dador_id': dadorId,
      if (dadorNombre != null) 'dador_nombre': dadorNombre,
      if (porcentajeComisionDador != null)
        'porcentaje_comision_dador': porcentajeComisionDador,
      if (montoFijoDador != null) 'monto_fijo_dador': montoFijoDador,
      'empresa_origen_id': empresaOrigenId,
      'empresa_origen_nombre': empresaOrigenNombre,
      'ubicacion_origen_id': ubicacionOrigenId,
      'ubicacion_origen_etiqueta': ubicacionOrigenEtiqueta,
      'empresa_destino_id': empresaDestinoId,
      'empresa_destino_nombre': empresaDestinoNombre,
      'ubicacion_destino_id': ubicacionDestinoId,
      'ubicacion_destino_etiqueta': ubicacionDestinoEtiqueta,
      'flete': flete.codigo,
      'unidad_tarifa': unidadTarifa.codigo,
      'tarifa_real': tarifaReal,
      'tarifa_chofer': tarifaChofer,
      if (montoFijoChofer != null) 'monto_fijo_chofer': montoFijoChofer,
      if (producto != null && producto.trim().isNotEmpty)
        'producto': producto.trim(),
      'activa': true,
      if (notas != null && notas.trim().isNotEmpty) 'notas': notas.trim(),
      'vigente_desde': FieldValue.serverTimestamp(),
      'vigencias': [vigenciaInicial.toMap()],
      'creado_en': FieldValue.serverTimestamp(),
      'creado_por': PrefsService.dni,
    });
  }

  static Future<void> actualizarTarifa({
    required String id,
    required Map<String, dynamic> cambios,
  }) async {
    await tarifasCol.doc(id).update(cambios);
  }

  /// Registra un NUEVO PRECIO (vigencia) para una tarifa existente, vigente
  /// desde [desde]. No borra las versiones anteriores — quedan en el
  /// historial. Si ya hay una vigencia el MISMO día, la reemplaza (corrige
  /// un precio cargado mal). Recomputa los campos planos = precio vigente
  /// HOY (cache para listas + app vieja). Luego dispara el recálculo
  /// automático de los viajes NO liquidados que usan la tarifa (cada tramo
  /// por su fecha de carga) y devuelve cuántos viajes se recalcularon.
  ///
  /// Solo versiona IMPORTES; la ruta/dador/etc. se editan con
  /// [actualizarTarifa]. La vigencia se escribe ANTES del recálculo: si el
  /// recálculo se interrumpe, re-llamar a este método (o a
  /// `ViajesService.recalcularViajesNoLiquidadosConTarifa`) lo completa —
  /// es idempotente.
  static Future<int> registrarNuevoPrecio({
    required String id,
    required DateTime desde,
    required double tarifaReal,
    required double tarifaChofer,
    double? montoFijoChofer,
    double? porcentajeComisionDador,
    double? montoFijoDador,
  }) async {
    if (id.isEmpty) throw ArgumentError('id de tarifa vacío.');
    // Validaciones (espejo de crearTarifa).
    if (tarifaReal < 0 || tarifaChofer < 0) {
      throw ArgumentError('Las tarifas no pueden ser negativas.');
    }
    if (tarifaReal > 0 && tarifaChofer > 0 && tarifaChofer > tarifaReal) {
      throw ArgumentError(
          'La tarifa del chofer no puede superar la tarifa real.');
    }
    if (porcentajeComisionDador != null &&
        (porcentajeComisionDador < 0 || porcentajeComisionDador > 100)) {
      throw ArgumentError(
          'El porcentaje de comisión debe estar entre 0 y 100.');
    }
    if (montoFijoDador != null && montoFijoDador <= 0) {
      throw ArgumentError('El monto fijo del dador debe ser mayor a 0.');
    }
    if (montoFijoChofer != null && montoFijoChofer <= 0) {
      throw ArgumentError('El monto fijo del chofer debe ser mayor a 0.');
    }

    final snap = await tarifasCol.doc(id).get();
    if (!snap.exists) throw StateError('La tarifa no existe.');
    final previa = TarifaLogistica.fromMap(snap.id, snap.data()!);

    final ahora = DateTime.now();
    final nueva = TarifaVigencia(
      desde: desde, // el constructor normaliza a día
      tarifaReal: tarifaReal,
      tarifaChofer: tarifaChofer,
      montoFijoChofer: montoFijoChofer,
      porcentajeComisionDador: porcentajeComisionDador,
      montoFijoDador: montoFijoDador,
      registradoEn: ahora,
      registradoPorDni: PrefsService.dni,
    );
    // Reemplazar la vigencia del mismo día (corrige typo) + agregar la
    // nueva, ordenadas asc.
    final lista = [
      ...previa.vigencias.where((v) => !_mismoDia(v.desde, nueva.desde)),
      nueva,
    ]..sort((a, b) => a.desde.compareTo(b.desde));
    final vigenciasMap = lista.map((v) => v.toMap()).toList();

    // Tarifa con las vigencias nuevas (reusa vigenteEn para los planos).
    final actualizada = TarifaLogistica.fromMap(id, {
      ...snap.data()!,
      'vigencias': vigenciasMap,
    });
    final hoy = actualizada.vigenteEn(ahora);

    await tarifasCol.doc(id).update({
      'vigencias': vigenciasMap,
      // Campos planos = precio vigente hoy (cache: listas + app vieja).
      'tarifa_real': hoy.tarifaReal,
      'tarifa_chofer': hoy.tarifaChofer,
      'monto_fijo_chofer': hoy.montoFijoChofer,
      'porcentaje_comision_dador': hoy.porcentajeComisionDador,
      'monto_fijo_dador': hoy.montoFijoDador,
      'vigente_desde': Timestamp.fromDate(hoy.desde),
    });

    // Recálculo automático de viajes no liquidados (cada tramo por su
    // fecha de carga). Idempotente.
    return ViajesService.recalcularViajesNoLiquidadosConTarifa(
      actualizada,
      porDni: PrefsService.dni,
    );
  }

  static bool _mismoDia(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Cuenta cuántos viajes EN CURSO (estado PLANEADO o EN_CURSO,
  /// activos) usan esta tarifa en alguno de sus tramos.
  ///
  /// Por qué scan client-side: con multi-tramo la tarifa puede estar
  /// en cualquier posición del array `tramos[]`, y Firestore no
  /// soporta queries sobre campos dentro de arrays de objetos. Como
  /// son ~100-200 viajes activos típicamente, el scan es viable y
  /// más simple que mantener un campo denormalizado `tarifa_ids[]`.
  static Future<int> contarViajesEnCursoConTarifa(String tarifaId) async {
    if (tarifaId.isEmpty) return 0;
    final col = _db.collection(AppCollections.viajesLogistica);
    final snap = await col.where('activo', isEqualTo: true).get();
    var count = 0;
    for (final doc in snap.docs) {
      final data = doc.data();
      final estado = (data['estado'] ?? '').toString();
      // Solo viajes en curso. Históricos (CONCLUIDO, CANCELADO,
      // POSTERGADO) no bloquean el delete — usan tarifa_snapshot.
      if (estado != 'PLANEADO' && estado != 'EN_CURSO') continue;

      final tramos = data['tramos'] as List?;
      if (tramos != null) {
        for (final t in tramos) {
          if (t is Map && t['tarifa_id'] == tarifaId) {
            count++;
            break;
          }
        }
      } else if (data['tarifa_id'] == tarifaId) {
        // Compat viajes viejos single-tramo con `tarifa_id` al
        // nivel del doc.
        count++;
      }
    }
    return count;
  }

  /// Elimina (hard-delete) una tarifa. Antes verifica que no esté
  /// usada por viajes EN CURSO (PLANEADO/EN_CURSO) — sino tira
  /// [StateError] con mensaje accionable.
  ///
  /// Viajes históricos (CONCLUIDO/CANCELADO/POSTERGADO) NO bloquean:
  /// cada viaje persistió `tarifa_snapshot` con los datos cacheados
  /// al momento del viaje, así que siguen funcionando.
  static Future<void> eliminarTarifa(String id) async {
    if (id.isEmpty) {
      throw ArgumentError('id de tarifa vacío.');
    }
    final enCurso = await contarViajesEnCursoConTarifa(id);
    if (enCurso > 0) {
      throw StateError(
        'No se puede eliminar: la tarifa está en $enCurso '
        '${enCurso == 1 ? "viaje" : "viajes"} en curso. '
        'Primero concluí, cancelá o cambiale la tarifa a esos viajes.',
      );
    }
    await tarifasCol.doc(id).delete();
  }
}
