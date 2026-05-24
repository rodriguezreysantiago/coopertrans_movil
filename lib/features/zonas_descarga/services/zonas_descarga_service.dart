import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../models/zona_descarga.dart';

/// CRUD de zonas de descarga (ZONAS_DESCARGA/{slug}). El operador
/// define las zonas desde la pantalla admin; la Cloud Function
/// `zonaDescargaPoller` las lee cada 5 min para detectar entradas/
/// salidas de las unidades.
///
/// Doc id = slug (estable, derivado del nombre). Si el slug ya existe
/// no se sobrescribe — el alta exige slug único.
class ZonasDescargaService {
  ZonasDescargaService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AppCollections.zonasDescarga);

  /// Convierte un nombre a slug (snake_case ASCII).
  /// "YPF Añelo zona descarga" → "ypf_anelo_zona_descarga".
  static String slugDesdeNombre(String nombre) {
    final sinAcentos = nombre
        .toLowerCase()
        .replaceAll(RegExp(r'[áàäâã]'), 'a')
        .replaceAll(RegExp(r'[éèëê]'), 'e')
        .replaceAll(RegExp(r'[íìïî]'), 'i')
        .replaceAll(RegExp(r'[óòöôõ]'), 'o')
        .replaceAll(RegExp(r'[úùüû]'), 'u')
        .replaceAll('ñ', 'n')
        .replaceAll('ç', 'c');
    final solo = sinAcentos.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return solo.replaceAll(RegExp(r'^_|_$'), '');
  }

  /// Stream de todas las zonas (activas e inactivas) ordenadas alfabético.
  static Stream<List<ZonaDescarga>> stream() =>
      _col.snapshots().map((s) {
        final l = s.docs.map(ZonaDescarga.fromDoc).toList();
        l.sort((a, b) =>
            a.nombre.toUpperCase().compareTo(b.nombre.toUpperCase()));
        return l;
      });

  /// Carga una vez (sin stream) — para CFs/scripts que no son reactivos.
  static Future<List<ZonaDescarga>> cargarTodas() async {
    final s = await _col.get();
    final l = s.docs.map(ZonaDescarga.fromDoc).toList();
    l.sort((a, b) =>
        a.nombre.toUpperCase().compareTo(b.nombre.toUpperCase()));
    return l;
  }

  /// Crea una nueva zona. El docId = slug. Falla si ya existe (no
  /// sobrescribe — para evitar perder config por colisión de nombres).
  static Future<void> crear(ZonaDescarga z) async {
    final err = z.validar();
    if (err != null) throw ArgumentError(err);
    final ref = _col.doc(z.slug);
    final existing = await ref.get();
    if (existing.exists) {
      throw StateError(
          'Ya existe una zona con el identificador "${z.slug}".');
    }
    await ref.set({
      ...z.toMap(),
      'creado_en': FieldValue.serverTimestamp(),
      'creado_por_dni': PrefsService.dni,
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': PrefsService.dni,
    });
  }

  /// Edita una zona existente — el slug NO se puede cambiar (porque la
  /// CF y la cola usan el slug para correlacionar entrada/salida). Si
  /// querés "cambiar el slug", borrá y creá una nueva.
  static Future<void> editar(ZonaDescarga z) async {
    final err = z.validar();
    if (err != null) throw ArgumentError(err);
    await _col.doc(z.slug).set({
      ...z.toMap(),
      'actualizado_en': FieldValue.serverTimestamp(),
      'actualizado_por_dni': PrefsService.dni,
    }, SetOptions(merge: true));
  }

  /// Pausa/reanuda una zona sin tocar su geometría.
  static Future<void> setActivo(String slug, bool activo) =>
      _col.doc(slug).set({
        'activo': activo,
        'actualizado_en': FieldValue.serverTimestamp(),
        'actualizado_por_dni': PrefsService.dni,
      }, SetOptions(merge: true));

  /// Borra una zona. Destructivo: si la CF tiene cola activa de esa
  /// zona, los docs `ZONA_DESCARGA_COLA/*_{slug}` quedan huérfanos. La
  /// UI debería confirmar antes de llamar.
  static Future<void> eliminar(String slug) => _col.doc(slug).delete();
}
