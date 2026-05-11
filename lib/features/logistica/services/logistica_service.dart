import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../models/empresa_logistica.dart';
import '../models/tarifa_logistica.dart';
import '../models/ubicacion_logistica.dart';

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
  }) async {
    final nombreNorm = nombre.trim().toUpperCase();
    if (nombreNorm.isEmpty) {
      throw ArgumentError('El nombre de la empresa no puede estar vacío.');
    }
    // Pre-check de unicidad por nombre (case-insensitive). Best-effort
    // — sin transaction — pero suficiente para el caso real (operadores
    // humanos cargando uno por vez).
    final existentes = await empresasCol.get();
    for (final d in existentes.docs) {
      final n = (d.data()['nombre'] ?? '').toString().trim().toUpperCase();
      if (n == nombreNorm) {
        throw StateError('Ya existe una empresa con ese nombre.');
      }
    }
    final apodoTrim = apodo?.trim() ?? '';
    return empresasCol.add({
      'nombre': nombreNorm,
      if (apodoTrim.isNotEmpty) 'apodo': apodoTrim,
      'tipo': tipo.codigo,
      if (cuit != null && cuit.trim().isNotEmpty) 'cuit': cuit.trim(),
      if (contacto != null && contacto.trim().isNotEmpty)
        'contacto': contacto.trim(),
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
    // único para que las tarifas no muestren ambigüedad.
    final existentes = await ubicacionesCol.get();
    for (final d in existentes.docs) {
      final n = (d.data()['nombre'] ?? '').toString().trim().toUpperCase();
      if (n == nombreNorm) {
        throw StateError('Ya existe una ubicación con ese nombre.');
      }
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
    String? producto,
    String? notas,
  }) async {
    // Validaciones de negocio:
    if (tipoCarga == TipoCargaLogistica.terceros) {
      if (dadorId == null || dadorId.isEmpty) {
        throw ArgumentError('Si la carga es de TERCEROS, el dador es obligatorio.');
      }
    }
    if (tarifaReal <= 0 || tarifaChofer <= 0) {
      throw ArgumentError('Las tarifas deben ser mayores a 0.');
    }
    if (tarifaChofer > tarifaReal) {
      throw ArgumentError(
          'La tarifa del chofer no puede superar la tarifa real.');
    }
    if (porcentajeComisionDador != null) {
      if (porcentajeComisionDador < 0 || porcentajeComisionDador > 100) {
        throw ArgumentError('El porcentaje de comisión debe estar entre 0 y 100.');
      }
    }

    return tarifasCol.add({
      'tipo_carga': tipoCarga.codigo,
      if (dadorId != null) 'dador_id': dadorId,
      if (dadorNombre != null) 'dador_nombre': dadorNombre,
      if (porcentajeComisionDador != null)
        'porcentaje_comision_dador': porcentajeComisionDador,
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
      if (producto != null && producto.trim().isNotEmpty)
        'producto': producto.trim(),
      'activa': true,
      if (notas != null && notas.trim().isNotEmpty) 'notas': notas.trim(),
      'vigente_desde': FieldValue.serverTimestamp(),
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
}
