// lib/features/administracion/services/vacaciones_service.dart
//
// CRUD del módulo Administración > Vacaciones sobre la colección VACACIONES.
//
// `FirebaseFirestore` se inyecta por constructor (default a `.instance`) para
// poder testear con fake_cloud_firestore sin emulador — mismo patrón que el
// resto de los services del proyecto.
//
// NOTA Windows: nada de runTransaction (bug conocido en Windows desktop). Los
// escrituras son `set` directos, idempotentes por el id determinístico
// `<anio>_<dni>`.

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../models/vacacion.dart';

class VacacionesService {
  final FirebaseFirestore _db;

  VacacionesService({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get col =>
      _db.collection(AppCollections.vacaciones);

  /// Stream de todas las vacaciones de un [anio] devengado, ordenadas por
  /// nombre. Base de la tabla anual.
  Stream<List<Vacacion>> streamPorAnio(int anio) {
    return col
        .where('anio', isEqualTo: anio)
        .snapshots()
        .map((s) => s.docs.map(Vacacion.fromDoc).toList()
          ..sort((a, b) =>
              a.nombre.toUpperCase().compareTo(b.nombre.toUpperCase())));
  }

  /// Stream del historial de un empleado (todos sus años), más nuevo primero.
  Stream<List<Vacacion>> streamPorEmpleado(String dni) {
    return col
        .where('dni', isEqualTo: dni)
        .snapshots()
        .map((s) => s.docs.map(Vacacion.fromDoc).toList()
          ..sort((a, b) => b.anio.compareTo(a.anio)));
  }

  /// Lee el registro de un empleado/año, o `null` si no existe.
  Future<Vacacion?> obtener(String dni, int anio) async {
    final d = await col.doc(Vacacion.idDe(anio, dni)).get();
    return d.exists ? Vacacion.fromDoc(d) : null;
  }

  /// Crea o actualiza el registro (id determinístico → idempotente). Reemplaza
  /// el doc por el contenido del modelo + sella `actualizadoEn` server-side.
  /// `tomados`/`restan` quedan derivados en el mapa (los calcula el modelo).
  Future<void> guardar(Vacacion v, {String? actualizadoPorDni}) async {
    final data = v.toMap();
    data['actualizadoEn'] = FieldValue.serverTimestamp();
    if (actualizadoPorDni != null && actualizadoPorDni.isNotEmpty) {
      data['actualizadoPorDni'] = actualizadoPorDni;
    }
    await col.doc(v.docId).set(data);
  }

  /// Borra el registro de un empleado/año (ej. cargado por error).
  Future<void> eliminar(String dni, int anio) async {
    await col.doc(Vacacion.idDe(anio, dni)).delete();
  }

  /// Agrega un período a un empleado/año y guarda. Crea el registro si no
  /// existía (en ese caso hay que pasar los datos base del empleado por
  /// [crearSiFalta]; si es null y no existe, lanza StateError).
  Future<Vacacion> agregarPeriodo(
    String dni,
    int anio,
    PeriodoVacaciones periodo, {
    Vacacion? crearSiFalta,
    String? actualizadoPorDni,
  }) async {
    final actual = await obtener(dni, anio) ?? crearSiFalta;
    if (actual == null) {
      throw StateError(
          'No existe el registro $anio/$dni y no se pasó crearSiFalta');
    }
    final nuevo =
        actual.copyWith(periodos: [...actual.periodos, periodo]);
    await guardar(nuevo, actualizadoPorDni: actualizadoPorDni);
    return nuevo;
  }
}
