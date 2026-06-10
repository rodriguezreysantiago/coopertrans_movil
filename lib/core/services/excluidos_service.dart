// =============================================================================
// EXCLUIDOS — choferes/vehículos/usuarios que NO controla Coopertrans Móvil
// =============================================================================
//
// **Paralelo Dart de los helpers** `functions/src/excluidos.ts` y
// `whatsapp-bot/src/excluidos.js`. Misma lógica, mismas constantes. Si
// tocás uno, tocá los tres.
//
// Resumen del caso de negocio (ver header TS para detalles):
// (A) 3 choferes asignados a 3 enganches TANQUE (combustibles
//     líquidos). Otra área de Vecchi, no los controlamos.
// (B) Usuarios tester creados para Apple Reviewer y Android (review
//     Play Store / TestFlight). Empleados reales preguntaban "quién
//     es éste?" en los listados de adelantos.
//
// Identificación dinámica:
// - Tanqueros: `VEHICULOS where TIPO=TANQUE` → `EMPLEADOS where
//   ENGANCHE in patentesTanque` → DNIs + tractores asignados.
// - Testers: regex `/\b(reviewer|tester|demo)\b/i` sobre NOMBRE.
//
// Uso en Flutter — patrón típico (StatefulWidget):
//
//     ExcluidosSet? _excluidos;
//     bool _mostrarExcluidos = false; // toggle de auditoría opcional
//
//     @override
//     void initState() {
//       super.initState();
//       ExcluidosService.cargar().then((s) {
//         if (mounted) setState(() => _excluidos = s);
//       });
//     }
//
//     // En el filter del ListView/StreamBuilder:
//     if (!_mostrarExcluidos &&
//         ExcluidosService.esExcluido(_excluidos, dni: doc.id)) {
//       return false;
//     }
//
// Si `_excluidos` es null (cache no cargada todavía), `esExcluido`
// devuelve `false` (fail-safe — mejor mostrar a alguien indebido por
// 100ms que esconder a empleados reales por un bug).

import 'package:cloud_firestore/cloud_firestore.dart';

import '../constants/app_constants.dart';
import 'app_logger.dart';

/// Conjunto de DNIs y patentes excluidas de la operativa del día a día.
class ExcluidosSet {
  final Set<String> dnis;
  final Set<String> patentes;

  const ExcluidosSet({required this.dnis, required this.patentes});

  /// Set vacío (no excluye a nadie). Se usa como fail-safe ante errores.
  static const ExcluidosSet vacio =
      ExcluidosSet(dnis: <String>{}, patentes: <String>{});
}

/// Servicio singleton para cargar y consultar el set de exclusión.
class ExcluidosService {
  ExcluidosService._();

  /// Regex tester. Word boundary evita falsos positivos ("Demolición"
  /// NO matchea). Case-insensitive.
  static final RegExp _patternTester =
      RegExp(r'\b(reviewer|tester|demo)\b', caseSensitive: false);

  static ExcluidosSet? _cache;
  static DateTime _cacheExpiraEn = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _ttl = Duration(minutes: 10);

  /// In-flight future para evitar tormenta de queries si N pantallas
  /// se montan al mismo tiempo (cada una llama `cargar()` en initState).
  static Future<ExcluidosSet>? _enVuelo;

  /// Devuelve el cache si está fresco, sin hacer I/O. Útil para usar
  /// dentro del `filter` callback de `AppListPage` (sincrónico).
  /// Devuelve `null` si no se cargó nunca o expiró.
  static ExcluidosSet? get cacheActual {
    if (_cache != null && DateTime.now().isBefore(_cacheExpiraEn)) {
      return _cache;
    }
    return null;
  }

  /// Carga el set desde Firestore con cache TTL 10 min.
  /// Fail-safe: si Firestore falla, devuelve `ExcluidosSet.vacio` (NO
  /// excluye a nadie) y loguea WARN. El próximo ciclo reintenta.
  static Future<ExcluidosSet> cargar({FirebaseFirestore? db}) async {
    final hit = cacheActual;
    if (hit != null) return hit;
    if (_enVuelo != null) return _enVuelo!;

    _enVuelo = _cargarInterno(db ?? FirebaseFirestore.instance);
    try {
      final res = await _enVuelo!;
      return res;
    } finally {
      _enVuelo = null;
    }
  }

  static Future<ExcluidosSet> _cargarInterno(FirebaseFirestore db) async {
    try {
      // ─── 1. Patentes TANQUE ──────────────────────────────────────
      final tanquesSnap = await db
          .collection(AppCollections.vehiculos)
          .where('TIPO', isEqualTo: 'TANQUE')
          .limit(100)
          .get();
      final patentesTanque = <String>{
        for (final d in tanquesSnap.docs) d.id.toUpperCase(),
      };

      // ─── 2. EMPLEADOS — testers + tanqueros ──────────────────────
      // Sin filtro de rol — Apple Reviewer es ADMIN.
      final empSnap =
          await db.collection(AppCollections.empleados).limit(1000).get();
      final dnis = <String>{};
      final tractoresExcluidos = <String>{};
      for (final d in empSnap.docs) {
        final data = d.data();
        if (data['ACTIVO'] == false) continue;

        // (a) Tester por NOMBRE
        final nombre = (data['NOMBRE'] ?? '').toString();
        if (_patternTester.hasMatch(nombre)) {
          dnis.add(d.id);
          continue;
        }

        // (b) Chofer con ENGANCHE TANQUE
        if (patentesTanque.isEmpty) continue;
        final enganche =
            (data['ENGANCHE'] ?? '').toString().trim().toUpperCase();
        if (enganche.isEmpty || !patentesTanque.contains(enganche)) {
          continue;
        }
        dnis.add(d.id);
        final tractor =
            (data['VEHICULO'] ?? '').toString().trim().toUpperCase();
        if (tractor.isNotEmpty && tractor != '-') {
          tractoresExcluidos.add(tractor);
        }
      }

      // ─── 3. Combinar patentes ────────────────────────────────────
      final patentes = <String>{...patentesTanque, ...tractoresExcluidos};

      _cache = ExcluidosSet(dnis: dnis, patentes: patentes);
      _cacheExpiraEn = DateTime.now().add(_ttl);
      AppLogger.log(
        '[ExcluidosService] cache actualizado: '
        'tanques=${patentesTanque.length} '
        'testersOTanqueros=${dnis.length} '
        'tractoresExcl=${tractoresExcluidos.length} '
        'totalPatentes=${patentes.length}',
      );
      return _cache!;
    } catch (e, st) {
      AppLogger.recordError(
        e,
        st,
        reason: '[ExcluidosService] query fallo, devuelve vacio',
      );
      return ExcluidosSet.vacio;
    }
  }

  /// `true` si el DNI o patente está en el set. Si `excluidos` es null
  /// (cache no cargada) devuelve `false` (fail-safe). Acepta valores
  /// en cualquier case — internamente normaliza la patente a UPPER.
  static bool esExcluido(
    ExcluidosSet? excluidos, {
    String? dni,
    String? patente,
  }) {
    if (excluidos == null) return false;
    if (dni != null && dni.isNotEmpty && excluidos.dnis.contains(dni.trim())) {
      return true;
    }
    if (patente != null && patente.isNotEmpty) {
      final norm = patente.trim().toUpperCase();
      if (norm.isNotEmpty && excluidos.patentes.contains(norm)) {
        return true;
      }
    }
    return false;
  }

  /// Solo para tests: invalida el cache forzando re-lectura en la
  /// próxima llamada. NO usar en producción.
  static void resetCacheParaTests() {
    _cache = null;
    _cacheExpiraEn = DateTime.fromMillisecondsSinceEpoch(0);
    _enVuelo = null;
  }
}
