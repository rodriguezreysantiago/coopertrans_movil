import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../models/cachatore_config.dart';
import '../models/cachatore_estado_bot.dart';
import '../models/cachatore_objetivo.dart';
import '../models/cachatore_turno.dart';
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

  static CollectionReference<Map<String, dynamic>> get turnosCol =>
      _db.collection(AppCollections.cachatoreTurnos);

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

  /// Turnos REALES de todos los choferes (los publica el bot). Para la pantalla
  /// "Turnos concretados".
  static Stream<List<CachatoreTurno>> streamTurnos() =>
      turnosCol.snapshots().map((s) {
        final lista = s.docs.map(CachatoreTurno.fromDoc).toList();
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

  // ─── Config global (interruptor maestro) ────────────────────────────
  static Future<void> setActivo(bool v) =>
      _configDoc.set({'activo': v, ..._meta}, SetOptions(merge: true));

  // ─── Objetivos (choferes a vigilar) ────────────────────────────────
  /// Alta de un chofer a vigilar. `fecha`: 'AAAA-MM-DD' o null = cualquiera.
  static Future<void> agregarObjetivo({
    required String dni,
    required String nombre,
    String? fecha,
    required FranjaCarga franja,
  }) =>
      objetivosCol.doc(dni).set({
        'dni': dni,
        'nombre': nombre,
        'fecha': fecha,
        'franja': franja.codigo,
        'reagendar': false,
        'activo': true,
        'creado_en': FieldValue.serverTimestamp(),
        'creado_por_dni': PrefsService.dni,
        ..._meta,
      }, SetOptions(merge: true));

  /// Cambia fecha+franja de un objetivo que TODAVÍA no tiene turno (vigilado).
  static Future<void> editarObjetivo({
    required String dni,
    String? fecha,
    required FranjaCarga franja,
  }) =>
      objetivosCol.doc(dni).set(
          {'fecha': fecha, 'franja': franja.codigo, ..._meta},
          SetOptions(merge: true));

  /// Pide reagendar un turno YA concretado a otra fecha+franja: setea el nuevo
  /// objetivo y marca reagendar=true para que el bot lo mueva al liberarse uno.
  static Future<void> reagendarObjetivo({
    required String dni,
    String? fecha,
    required FranjaCarga franja,
  }) =>
      objetivosCol.doc(dni).set({
        'fecha': fecha,
        'franja': franja.codigo,
        'reagendar': true,
        ..._meta,
      }, SetOptions(merge: true));

  static Future<void> setObjetivoActivo(String dni, bool v) =>
      objetivosCol.doc(dni).set({'activo': v, ..._meta}, SetOptions(merge: true));

  static Future<void> eliminarObjetivo(String dni) =>
      objetivosCol.doc(dni).delete();
}
