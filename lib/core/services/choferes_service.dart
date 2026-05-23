// =============================================================================
// CHOFERES — set de DNIs con ROL=CHOFER (para filtrar listados del módulo ICM)
// =============================================================================
//
// El doc `ICM_OFICIAL/{YYYY-MM}` que escribe el scraper de Sitrack incluye a
// TODOS los choferes que tienen una identificación cargada en Sitrack —
// incluyendo a los que en EMPLEADOS figuran con rol PLANTA / ADMIN / etc.
// El operador no quiere ver a esos en el ranking ICM (Santiago 2026-05-23:
// "los que son empleados de planta admin y demas, no tienen que estar en
// ranking icm solo los choferes").
//
// Este helper devuelve el `Set<String>?` de DNIs con ROL=CHOFER activos
// (incluye también el rol legacy 'USUARIO' que el script de migración aún
// no terminó de convertir — ver AppRoles.normalizar).
//
// El return type es nullable a propósito: si la query a Firestore falla
// (sin conexión, permisos), devuelve `null` para que el caller NO filtre
// por rol (fail-safe: mejor mostrar un par de no-choferes 100ms que
// vaciar el ranking entero por un error transitorio). Patrón típico:
//
//     final excluidos = await ExcluidosService.cargar(db: db);
//     final dnisChofer = await ChoferesService.cargarDnisChofer(db: db);
//     bool excluir(String dni) =>
//         ExcluidosService.esExcluido(excluidos, dni: dni) ||
//         (dnisChofer != null && !dnisChofer.contains(dni));
//
// Importante: los items del ICM con DNI vacío (unidad sin chofer identificado)
// NO pasan por `excluirDni` en `IcmOficialPeriodo.fromMap` — siguen
// apareciendo al final del ranking, sin puesto, como hoy. Solo los items
// con DNI real que NO sean CHOFER quedan filtrados.
//
// Cache TTL 10 min (mismo criterio que `ExcluidosService`).

import 'package:cloud_firestore/cloud_firestore.dart';

import '../constants/app_constants.dart';
import 'app_logger.dart';

class ChoferesService {
  ChoferesService._();

  static Set<String>? _cache;
  static DateTime _cacheExpiraEn = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _ttl = Duration(minutes: 10);

  /// In-flight future para evitar tormenta de queries si N pantallas
  /// se montan al mismo tiempo.
  static Future<Set<String>?>? _enVuelo;

  /// Cache sincrónico (para callers que ya saben que se cargó antes).
  /// `null` si nunca se cargó o expiró.
  static Set<String>? get cacheActual {
    if (_cache != null && DateTime.now().isBefore(_cacheExpiraEn)) {
      return _cache;
    }
    return null;
  }

  /// Devuelve el set de DNIs con rol CHOFER activos. Cache TTL 10 min.
  /// Devuelve `null` si la query fallo (caller debe no-filtrar).
  static Future<Set<String>?> cargarDnisChofer({
    FirebaseFirestore? db,
  }) async {
    final hit = cacheActual;
    if (hit != null) return hit;
    if (_enVuelo != null) return _enVuelo!;

    _enVuelo = _cargarInterno(db ?? FirebaseFirestore.instance);
    try {
      return await _enVuelo!;
    } finally {
      _enVuelo = null;
    }
  }

  static Future<Set<String>?> _cargarInterno(FirebaseFirestore db) async {
    try {
      // ROL IN [CHOFER, USUARIO]: incluye el rol legacy hasta que migren
      // todos a CHOFER (ver AppRoles.normalizar).
      final snap = await db
          .collection(AppCollections.empleados)
          .where('ROL',
              whereIn: [AppRoles.chofer, AppRoles.usuarioLegacy]).limit(2000).get();
      final dnis = <String>{};
      for (final d in snap.docs) {
        final data = d.data();
        if (data['ACTIVO'] == false) continue;
        dnis.add(d.id);
      }
      _cache = dnis;
      _cacheExpiraEn = DateTime.now().add(_ttl);
      AppLogger.log(
        '[ChoferesService] cache actualizado: ${dnis.length} DNIs CHOFER',
      );
      return dnis;
    } catch (e, st) {
      AppLogger.recordError(
        e,
        st,
        reason: '[ChoferesService] query fallo, caller NO filtra por rol',
      );
      return null;
    }
  }

  /// Solo para tests: invalida el cache.
  static void resetCacheParaTests() {
    _cache = null;
    _cacheExpiraEn = DateTime.fromMillisecondsSinceEpoch(0);
    _enVuelo = null;
  }
}
