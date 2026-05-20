import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../models/cachatore_config.dart';
import '../models/cachatore_estado_bot.dart';
import '../models/cachatore_objetivo.dart';
import '../models/franja_carga.dart';

/// Capa de datos del módulo Cachatore. La app SOLO escribe configuración
/// (qué choferes, qué franja, prendido/pausado); el estado en vivo lo
/// escribe el bot Python (Admin SDK) y acá solo se lee.
class CachatoreService {
  CachatoreService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static DocumentReference<Map<String, dynamic>> get _configDoc =>
      _db.collection(AppCollections.cachatoreConfig).doc('global');

  static CollectionReference<Map<String, dynamic>> get objetivosCol =>
      _db.collection(AppCollections.cachatoreObjetivos);

  static DocumentReference<Map<String, dynamic>> get _estadoDoc =>
      _db.collection(AppCollections.cachatoreEstado).doc('bot');

  // ─── Streams ───────────────────────────────────────────────────────
  static Stream<CachatoreConfig> streamConfig() =>
      _configDoc.snapshots().map((d) => CachatoreConfig.fromMap(d.data()));

  static Stream<CachatoreEstadoBot> streamEstado() =>
      _estadoDoc.snapshots().map((d) => CachatoreEstadoBot.fromMap(d.data()));

  static Stream<List<CachatoreObjetivo>> streamObjetivos() =>
      objetivosCol.snapshots().map((s) {
        final lista = s.docs.map(CachatoreObjetivo.fromDoc).toList();
        // Orden alfabético por nombre (client-side; son ~50 choferes).
        lista.sort((a, b) => (a.nombre ?? a.dni)
            .toUpperCase()
            .compareTo((b.nombre ?? b.dni).toUpperCase()));
        return lista;
      });

  // Metadata de auditoría común a toda escritura de la app.
  static Map<String, dynamic> get _meta => {
        'actualizado_en': FieldValue.serverTimestamp(),
        'actualizado_por_dni': PrefsService.dni,
      };

  // ─── Config global ─────────────────────────────────────────────────
  static Future<void> setActivo(bool v) =>
      _configDoc.set({'activo': v, ..._meta}, SetOptions(merge: true));

  /// fecha: null = cualquier fecha en la franja; 'hoy' / 'manana' / 'AAAA-MM-DD'.
  static Future<void> setFecha(String? fecha) =>
      _configDoc.set({'fecha': fecha, ..._meta}, SetOptions(merge: true));

  static Future<void> setHoraInicio(String horaInicio) =>
      _configDoc.set({'hora_inicio': horaInicio, ..._meta}, SetOptions(merge: true));

  // ─── Objetivos (choferes a vigilar) ────────────────────────────────
  static Future<void> agregarObjetivo({
    required String dni,
    required String nombre,
    required FranjaCarga franja,
    bool reagendar = false,
  }) =>
      objetivosCol.doc(dni).set({
        'dni': dni,
        'nombre': nombre,
        'franja': franja.codigo,
        'reagendar': reagendar,
        'activo': true,
        'creado_en': FieldValue.serverTimestamp(),
        'creado_por_dni': PrefsService.dni,
        ..._meta,
      }, SetOptions(merge: true));

  static Future<void> setFranja(String dni, FranjaCarga franja) =>
      objetivosCol.doc(dni).set(
          {'franja': franja.codigo, ..._meta}, SetOptions(merge: true));

  static Future<void> setReagendar(String dni, bool v) =>
      objetivosCol.doc(dni).set({'reagendar': v, ..._meta}, SetOptions(merge: true));

  static Future<void> setObjetivoActivo(String dni, bool v) =>
      objetivosCol.doc(dni).set({'activo': v, ..._meta}, SetOptions(merge: true));

  static Future<void> eliminarObjetivo(String dni) =>
      objetivosCol.doc(dni).delete();
}
