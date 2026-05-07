import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Resultado de un request de diagnóstico contra Volvo. Pensado para
/// inspeccionar visualmente qué viene en el response cuando algo no
/// se está parseando como esperamos.
class VolvoDiagnostico {
  final int? statusCode;
  final String? statusMessage;
  final dynamic rawBody; // Map o String según el response
  final String? errorMessage;
  final Duration duracion;
  final String urlConsultada;

  const VolvoDiagnostico({
    required this.statusCode,
    required this.statusMessage,
    required this.rawBody,
    required this.errorMessage,
    required this.duracion,
    required this.urlConsultada,
  });

  bool get fueExitoso =>
      errorMessage == null && statusCode != null && statusCode! < 400;
}

/// Snapshot de telemetría de un vehículo, sacado de un solo request a
/// `/vehicle/vehiclestatuses`. Cualquier campo puede venir `null` si el
/// vehículo no lo reporta (típico en marcas no-Volvo o unidades viejas).
class VolvoTelemetria {
  /// Odómetro acumulado en metros. Para KM dividir entre 1000.
  final double? odometroMetros;

  /// Nivel de combustible 0..100. Lo entrega Volvo en porcentaje.
  final double? nivelCombustiblePct;

  /// Nivel de AdBlue (DEF — Diesel Exhaust Fluid) 0..100. Sin AdBlue
  /// el camión derateca en pocos km (Euro VI obliga). Volvo lo expone
  /// con varios nombres según firmware (`catalystFuelLevel`,
  /// `defLevel`, `adBlueLevel`, etc.) — el parser prueba todos los
  /// paths conocidos.
  final double? nivelAdbluePct;

  /// Autonomía estimada en kilómetros que el vehículo puede recorrer
  /// con el combustible actual antes de quedarse vacío.
  final double? autonomiaKm;

  /// Distancia restante hasta el próximo mantenimiento programado,
  /// en metros. Puede ser **negativa** si el service ya está vencido.
  /// Volvo lo entrega como `serviceDistance` en el response (al primer
  /// nivel o nested en `snapshotData`/`volvoGroupSnapshot`).
  final double? serviceDistanceMetros;

  /// Timestamp del snapshot que recibimos del vehículo (no del momento
  /// en que llamamos al API).
  final DateTime? leidoEn;

  const VolvoTelemetria({
    this.odometroMetros,
    this.nivelCombustiblePct,
    this.nivelAdbluePct,
    this.autonomiaKm,
    this.serviceDistanceMetros,
    this.leidoEn,
  });

  /// Atajo en KM (puede ser negativo si está vencido).
  double? get serviceDistanceKm => serviceDistanceMetros != null
      ? serviceDistanceMetros! / 1000
      : null;

  /// True cuando el response trajo al menos un dato útil.
  bool get tieneAlgunDato =>
      odometroMetros != null ||
      nivelCombustiblePct != null ||
      nivelAdbluePct != null ||
      autonomiaKm != null ||
      serviceDistanceMetros != null;
}

/// Resultado interno del proxy. Mimicea la estructura mínima de [Response]
/// para que las funciones públicas de [VolvoApiService] puedan parsear
/// el body de Volvo igual que cuando llamábamos directo.
class _ProxyResponse {
  final int statusCode;
  final dynamic data;
  const _ProxyResponse({required this.statusCode, required this.data});
}

/// Servicio de integración con Volvo Connect — Volvo Group Vehicle API.
///
/// 📚 BASADO EN DOC OFICIAL (Volvo Trucks Developer Portal):
///   - Volvo Group Vehicle API v1.0.6  →  /vehicle/...  (odómetro y estado)
///   - rFMS v2.1 (estándar abierto)    →  /rfms/...     (fallback)
///
/// 🔐 AUTH: A partir de 2026-04-29 las credenciales NO viajan en el
///   cliente. Toda llamada va a la Cloud Function `volvoProxy`, que
///   valida que el caller sea admin (custom claim `rol == 'ADMIN'` en el
///   JWT de Firebase Auth) y agrega el header Basic Auth contra Volvo
///   con credenciales guardadas en Secret Manager
///   (`VOLVO_USERNAME`/`VOLVO_PASSWORD`).
///
///   Setup inicial (una sola vez por proyecto):
///     firebase functions:secrets:set VOLVO_USERNAME
///     firebase functions:secrets:set VOLVO_PASSWORD
///     firebase deploy --only functions:volvoProxy
///
/// 📦 Campo de odómetro: `hrTotalVehicleDistance` en METROS, dentro de
///   vehicleStatusResponse.vehicleStatuses[i].hrTotalVehicleDistance
///
/// ⚠️ Rate limit: 1 request cada 10 seg por endpoint y por usuario
///   (lo aplica Volvo). El proxy NO agrega rate limit propio.
class VolvoApiService {
  // ============= ENDPOINT DEL PROXY =============
  // Cloud Function callable desplegada. Mismo project, misma región.
  // Si en el futuro cambiamos a Gen1 o cambia el pattern, solo ajustamos
  // esta constante.
  static const String _proxyEndpoint =
      'https://southamerica-east1-coopertrans-movil.cloudfunctions.net/volvoProxy';

  // ============= CIRCUIT BREAKER =============
  // Si auth/permisos fallan 3 veces seguidas, dejamos de pegarle al
  // proxy. Cubre los casos:
  //   - admin sesión vencida (HTTP 401 en el callable)
  //   - chofer logueado intentando sync (HTTP 403 en el callable)
  //   - credenciales Volvo expiradas (HTTP 401 propagado del proxy)
  //
  // Bug M4 del code review: antes el circuit breaker se quedaba
  // abierto hasta restart. Ahora se "abre temporalmente" — si pasaron
  // más de `_circuitCooldownMin` minutos desde el último fail, el
  // siguiente request ignora el circuit y reintenta. Si vuelve a
  // fallar, el circuit se mantiene abierto por otro cooldown.
  int _consecutive401 = 0;
  DateTime? _ultimoFailAt;
  static const int _max401 = 3;
  static const int _circuitCooldownMin = 5;

  bool get _circuitOpen {
    if (_consecutive401 < _max401) return false;
    final last = _ultimoFailAt;
    if (last == null) return true;
    final pasaron =
        DateTime.now().difference(last).inMinutes >= _circuitCooldownMin;
    if (pasaron) {
      // Permitimos un intento. Si sale OK, _trackAuthState resetea.
      // Si vuelve a fallar, _consecutive401 sigue en MAX y el ciclo
      // continúa con cooldown.
      return false;
    }
    return true;
  }

  void resetAuthFailures() {
    _consecutive401 = 0;
    _ultimoFailAt = null;
  }

  // ============= DIO =============
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 20),
    ),
  );

  // ===========================================================================
  // HELPER: llamada al proxy
  // ===========================================================================

  /// Llama a la Cloud Function `volvoProxy` con auth de Firebase Auth.
  /// Devuelve un [_ProxyResponse] con el statusCode HTTP que devolvió
  /// Volvo (no el del proxy) y el body crudo de Volvo. Si el proxy
  /// rechaza la llamada (no admin, sin token, etc) devuelve statusCode
  /// 401/403 con `data = null`.
  Future<_ProxyResponse> _callVolvoProxy({
    required String operation,
    Map<String, dynamic>? params,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      // Sin sesión Firebase no se puede llamar al proxy (rechaza con
      // 401 igual). Cortamos antes para no quemar latencia de red.
      return const _ProxyResponse(statusCode: 401, data: null);
    }

    try {
      final idToken = await user.getIdToken();
      final response = await _dio.post<Map<String, dynamic>>(
        _proxyEndpoint,
        data: {
          // Protocolo callable: payload va envuelto en `data`.
          'data': {
            'operation': operation,
            'params': params ?? const <String, dynamic>{},
          },
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          validateStatus: (_) => true,
          responseType: ResponseType.json,
        ),
      );

      final httpStatus = response.statusCode ?? 500;

      // Errores HTTP del proxy: body trae `{"error": {...}}`.
      if (httpStatus >= 400) {
        final err = response.data?['error'] as Map<String, dynamic>?;
        debugPrint(
            "🚨 [volvoProxy/$operation] HTTP $httpStatus → ${err?['status']}: ${err?['message']}");
        return _ProxyResponse(statusCode: httpStatus, data: null);
      }

      // Respuesta OK del callable: body es `{"result": {statusCode, data}}`.
      final result = response.data?['result'] as Map<String, dynamic>?;
      if (result == null) {
        return const _ProxyResponse(statusCode: 500, data: null);
      }
      final upstreamStatus =
          (result['statusCode'] as num?)?.toInt() ?? 500;
      final upstreamData = result['data'];
      return _ProxyResponse(
        statusCode: upstreamStatus,
        data: upstreamData,
      );
    } catch (e) {
      debugPrint("🚨 [volvoProxy/$operation] error: $e");
      return const _ProxyResponse(statusCode: 500, data: null);
    }
  }

  /// Reusa el contador del circuit breaker para los 3 modos de auth-fail
  /// (proxy 401/403 o Volvo 401 propagado vía proxy 200 con statusCode 401).
  void _trackAuthState(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      _consecutive401++;
      _ultimoFailAt = DateTime.now();
      debugPrint(
          "🚨 [VOLVO AUTH] Rechazo de auth ($_consecutive401/$_max401). "
          "${_consecutive401 >= _max401 ? 'Circuit breaker ABIERTO. Pausando llamadas (cooldown ${_circuitCooldownMin}min).' : ''}");
    } else if (statusCode >= 200 && statusCode < 300) {
      // Sale bien — resetea contador y timestamp para volver a estado
      // sano completamente. Log silenciado (antes era util pero ahora
      // el Sync Dashboard ya muestra el estado de auth en vivo).
      // if (_consecutive401 > 0) {
      //   debugPrint("✅ [VOLVO AUTH] Auth recuperada, reseteando circuit.");
      // }
      _consecutive401 = 0;
      _ultimoFailAt = null;
    }
  }

  // ===========================================================================
  // 1. FLOTA — /vehicle/vehicles
  // ===========================================================================

  /// Devuelve la lista de vehículos asignados a la cuenta de API.
  /// Respuesta: vehicleResponse.vehicles[]
  Future<List<dynamic>> traerDatosFlota() async {
    if (_circuitOpen) {
      debugPrint("⏸️ [VOLVO FLOTA] Circuit breaker abierto. Saltando llamada.");
      return [];
    }

    final res = await _callVolvoProxy(operation: 'flota');
    _trackAuthState(res.statusCode);

    if (res.statusCode == 200 && res.data is Map) {
      final body = res.data as Map;
      final list = body['vehicleResponse']?['vehicles'] ?? [];
      if (list is List) {
        debugPrint("📦 [VOLVO FLOTA] OK: ${list.length} unidades recibidas");
        return list;
      }
    }

    debugPrint("⚠️ [VOLVO FLOTA] HTTP ${res.statusCode}");
    return [];
  }

  // ===========================================================================
  // 2. KILOMETRAJE POR VIN — /vehicle/vehiclestatuses
  // ===========================================================================

  /// Trae el kilometraje (en metros) de un VIN específico.
  /// Devuelve null si la unidad no respondió o no hay datos.
  ///
  /// Field path: vehicleStatusResponse.vehicleStatuses[0].hrTotalVehicleDistance
  /// Unit: metros (int64). Para KM dividir por 1000.
  Future<double?> traerKilometrajeCualquierVia(String vin) async {
    final String cleanVin = vin.trim().toUpperCase();
    if (cleanVin.isEmpty) return null;

    if (_circuitOpen) {
      debugPrint("⏸️ [VOLVO KM $cleanVin] Circuit breaker abierto.");
      return null;
    }

    final res = await _callVolvoProxy(
      operation: 'kilometraje',
      params: {'vin': cleanVin},
    );
    _trackAuthState(res.statusCode);

    if (res.statusCode == 200 && res.data is Map) {
      final body = res.data as Map;
      final statuses = body['vehicleStatusResponse']?['vehicleStatuses'];
      if (statuses is List && statuses.isNotEmpty) {
        final s = statuses[0];
        final odo = s is Map ? s['hrTotalVehicleDistance'] : null;
        if (odo != null) {
          final m = double.tryParse(odo.toString());
          if (m != null && m > 0) {
            debugPrint(
                "✅ [VOLVO KM $cleanVin] ${(m / 1000).toStringAsFixed(0)} km");
            return m;
          }
        }
      }
      debugPrint("ℹ️ [VOLVO KM $cleanVin] Respuesta 200 pero sin odómetro.");
      return null;
    }

    debugPrint("⚠️ [VOLVO KM $cleanVin] HTTP ${res.statusCode}");
    return null;
  }

  // ===========================================================================
  // 2.b TELEMETRÍA COMPLETA POR VIN — /vehicle/vehiclestatuses
  // ===========================================================================
  //
  // Mismo endpoint que `traerKilometrajeCualquierVia`, pero parsea más
  // campos del response (combustible y autonomía) sin generar requests
  // adicionales. Cuesta lo mismo en términos de rate limit.

  /// Trae odómetro + nivel de combustible + autonomía estimada de un VIN
  /// en una sola llamada. Devuelve un [VolvoTelemetria] vacío si la
  /// unidad no respondió o no hay credenciales.
  Future<VolvoTelemetria> traerTelemetria(String vin) async {
    final String cleanVin = vin.trim().toUpperCase();
    if (cleanVin.isEmpty) return const VolvoTelemetria();

    if (_circuitOpen) {
      debugPrint("⏸️ [VOLVO TELE $cleanVin] Circuit breaker abierto.");
      return const VolvoTelemetria();
    }

    final res = await _callVolvoProxy(
      operation: 'telemetria',
      params: {'vin': cleanVin},
    );
    _trackAuthState(res.statusCode);

    if (res.statusCode == 200 && res.data is Map) {
      final body = res.data as Map;
      final statuses = body['vehicleStatusResponse']?['vehicleStatuses'];
      if (statuses is List && statuses.isNotEmpty) {
        final tele = _parseStatus(statuses[0]);
        if (tele.tieneAlgunDato) {
          // Log de éxito por vehículo desactivado: el dashboard de
          // sync ya muestra la info por unidad (km/fuel/autonomía).
          // Si necesitás re-debuggear, descomentar.
          return tele;
        }
      }
      // Silenciado: 200 sin datos pasa seguido cuando el endpoint no
      // tiene info reciente del vehiculo (ej. ignition off hace dias)
      // y el Sync Dashboard ya marca esos casos como "saltados".
      // debugPrint(
      //     "ℹ️ [VOLVO TELE $cleanVin] Respuesta 200 pero sin datos útiles.");
      return const VolvoTelemetria();
    }

    // Mantenemos el log de status code != 200 porque indica un problema
    // real de la API que conviene ver en consola al debuggear.
    debugPrint("⚠️ [VOLVO TELE $cleanVin] HTTP ${res.statusCode}");
    return const VolvoTelemetria();
  }

  /// Parser de un objeto `vehicleStatuses[i]` del response oficial.
  ///
  /// La estructura real del response (verificada con un VIN diésel +
  /// `additionalContent=VOLVOGROUPSNAPSHOT`) es:
  ///
  /// ```
  /// vehicleStatuses[i] = {
  ///   hrTotalVehicleDistance: <metros>,             // odómetro
  ///   snapshotData: {
  ///     fuelLevel1: <0-100>,                        // % combustible
  ///     volvoGroupSnapshot: {
  ///       estimatedDistanceToEmpty: {
  ///         fuel: <metros>, gas: <metros>           // autonomía por fuente
  ///       }
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// El parser igual probará paths "legacy" (sin snapshotData) por si una
  /// versión vieja del API los aplana al primer nivel.
  VolvoTelemetria _parseStatus(dynamic raw) {
    if (raw is! Map) return const VolvoTelemetria();
    final r = raw;
    final snap = r['snapshotData'];
    final volvoSnap = (snap is Map) ? snap['volvoGroupSnapshot'] : null;

    // Odómetro: doc oficial → hrTotalVehicleDistance al primer nivel.
    final double? odoMetros = _toDouble(r['hrTotalVehicleDistance']);

    // Nivel de combustible: snapshotData.fuelLevel1 (0..100). Algunos
    // responses lo aplanan al primer nivel.
    double? fuelPct;
    if (snap is Map) {
      fuelPct = _toDouble(snap['fuelLevel1']) ?? _toDouble(snap['fuelLevel']);
    }
    fuelPct ??= _toDouble(r['fuelLevel1']) ?? _toDouble(r['fuelLevel']);

    // Nivel de AdBlue (DEF): los nombres varían entre firmwares y
    // versiones del API. Probamos los conocidos en orden de
    // preferencia. Todos vienen como porcentaje 0..100 — clampeamos
    // al final por las dudas que un firmware exotico devuelva 0..1.
    double? adbluePct = _extraerAdbluePct(r, snap, volvoSnap);

    // Autonomía: estimatedDistanceToEmpty puede aparecer en muchos
    // contenedores. _extraerAutonomiaMetros recorre todos los posibles
    // y devuelve metros (luego convertimos a km).
    final autonomiaMetros = _extraerAutonomiaMetros(r, snap, volvoSnap);
    final autonomiaKm =
        autonomiaMetros != null ? (autonomiaMetros / 1000) : null;

    // Timestamp del snapshot — cualquiera de los path conocidos.
    DateTime? leidoEn;
    final ts = r['receivedDateTime'] ?? r['createdDateTime'];
    if (ts is String) {
      leidoEn = DateTime.tryParse(ts);
    }

    // serviceDistance: km al próximo mantenimiento programado. Volvo lo
    // expone en METROS y puede ser negativo (servicio vencido).
    //
    // Path oficial según doc Volvo Group Vehicle API v1.0.6:
    //   vehicleStatuses[i].uptimeData.serviceDistance
    // (junto con tellTaleInfo, engineCoolantTemperature, etc.)
    //
    // Probamos primero el path oficial. Después caemos a paths legacy
    // por si alguna unidad lo aplana distinto.
    double? serviceDist;
    final uptimeData = r['uptimeData'];
    if (uptimeData is Map) {
      serviceDist = _toDouble(uptimeData['serviceDistance']);
    }
    serviceDist ??= _toDouble(r['serviceDistance']);
    if (serviceDist == null && snap is Map) {
      serviceDist = _toDouble(snap['serviceDistance']);
    }
    if (serviceDist == null && volvoSnap is Map) {
      serviceDist = _toDouble(volvoSnap['serviceDistance']);
    }

    return VolvoTelemetria(
      odometroMetros: odoMetros,
      nivelCombustiblePct: fuelPct,
      nivelAdbluePct: adbluePct,
      autonomiaKm: autonomiaKm,
      serviceDistanceMetros: serviceDist,
      leidoEn: leidoEn,
    );
  }

  /// Extrae el % de AdBlue (DEF) probando los nombres más usados por
  /// distintos firmwares y versiones del Vehicle Status API.
  ///
  /// Volvo no estandariza esto en una sola key — históricamente vimos:
  ///   - `catalystFuelLevel`     (común en Vehicle API v1.0.6+ diésel Euro VI)
  ///   - `defLevel`              (rFMS)
  ///   - `adBlueLevel`           (firmwares viejos)
  ///   - `dieselExhaustFluidLevel` (alias largo)
  ///   - `ureaLevel`             (algunos OEM)
  ///
  /// Probamos en cada uno de los contenedores donde Volvo aplana el
  /// snapshot: el doc raíz, `snapshotData`, `volvoGroupSnapshot`.
  /// Devuelve null si nada matchea.
  ///
  /// Si algún firmware devuelve 0..1 en lugar de 0..100, lo
  /// normalizamos multiplicando por 100. Heurística: cualquier valor
  /// `<= 1` lo tratamos como fracción.
  double? _extraerAdbluePct(Map raw, dynamic snap, dynamic volvoSnap) {
    const keys = [
      'catalystFuelLevel',
      'defLevel',
      'adBlueLevel',
      'dieselExhaustFluidLevel',
      'ureaLevel',
    ];
    final candidatos = <Map>[
      raw,
      if (snap is Map) snap,
      if (volvoSnap is Map) volvoSnap,
    ];
    for (final container in candidatos) {
      for (final k in keys) {
        final v = _toDouble(container[k]);
        if (v != null) {
          // Normalizar 0..1 → 0..100 si aplica.
          final pct = v <= 1 ? v * 100 : v;
          // Clamp defensivo.
          if (pct >= 0 && pct <= 100) return pct;
        }
      }
    }
    return null;
  }

  /// Extrae `estimatedDistanceToEmpty` (en metros) recorriendo todos los
  /// contenedores posibles. Devuelve null si ninguno tiene valor útil.
  double? _extraerAutonomiaMetros(Map raw, dynamic snap, dynamic volvoSnap) {
    // Lista de Maps donde puede estar el objeto estimatedDistanceToEmpty.
    final candidatos = <Map>[
      if (volvoSnap is Map) volvoSnap, // ← path real confirmado para diésel
      if (snap is Map) snap,
      raw,
    ];

    // Bonus: contenedores específicos de vehículos eléctricos/híbridos.
    for (final c in const [
      'chargingStatusInfo',
      'volvoGroupChargingStatusInfo',
      'batteryPackInfo',
    ]) {
      final container = raw[c];
      if (container is Map) candidatos.add(container);
    }

    for (final container in candidatos) {
      final edte = container['estimatedDistanceToEmpty'];
      if (edte is Map) {
        // Probamos campos en orden de preferencia. La doc nueva usa
        // {fuel, gas, batteryPack} sin `total`; la doc vieja tiene `total`.
        final v = _toDouble(edte['total']) ??
            _toDouble(edte['fuel']) ??
            _toDouble(edte['batteryPack']) ??
            _toDouble(edte['gas']);
        if (v != null && v > 0) return v;
      } else if (edte is num) {
        // Edge case: algunos responses lo aplanan a número directo.
        return edte.toDouble();
      }
    }
    return null;
  }

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  // ===========================================================================
  // DIAGNÓSTICO — request crudo para inspección manual
  // ===========================================================================

  /// Hace el mismo request que `traerTelemetria` pero devuelve el response
  /// completo sin parsear. Para usar desde una pantalla de admin cuando
  /// algún campo no aparece y necesitamos ver qué viene literalmente.
  Future<VolvoDiagnostico> diagnosticarStatus(String vin) async {
    final cleanVin = vin.trim().toUpperCase();
    final urlInformativa =
        'volvoProxy(telemetria, vin=$cleanVin)';

    if (cleanVin.isEmpty) {
      return VolvoDiagnostico(
        statusCode: null,
        statusMessage: null,
        rawBody: null,
        errorMessage: 'VIN vacío.',
        duracion: Duration.zero,
        urlConsultada: urlInformativa,
      );
    }

    final stopwatch = Stopwatch()..start();
    final res = await _callVolvoProxy(
      operation: 'telemetria',
      params: {'vin': cleanVin},
    );
    stopwatch.stop();
    _trackAuthState(res.statusCode);

    return VolvoDiagnostico(
      statusCode: res.statusCode,
      statusMessage: null,
      rawBody: res.data,
      errorMessage: res.data == null && res.statusCode >= 400
          ? 'Proxy rechazó o Volvo devolvió error (HTTP ${res.statusCode}).'
          : null,
      duracion: stopwatch.elapsed,
      urlConsultada: urlInformativa,
    );
  }

  // ===========================================================================
  // 3. ESTADOS DE TODA LA FLOTA — para precarga en cache
  // ===========================================================================

  /// Trae el último estado de TODAS las unidades en una sola llamada.
  /// Útil como caché previo a sincronizar uno por uno.
  Future<List<dynamic>> traerEstadosFlota() async {
    if (_circuitOpen) return [];

    final res = await _callVolvoProxy(operation: 'estadosFlota');
    _trackAuthState(res.statusCode);

    if (res.statusCode == 200 && res.data is Map) {
      final body = res.data as Map;
      final list = body['vehicleStatusResponse']?['vehicleStatuses'] ?? [];
      if (list is List) {
        debugPrint("📦 [VOLVO STATUS] OK: ${list.length} estados recibidos");
        return list;
      }
    }

    debugPrint("⚠️ [VOLVO STATUS-ALL] HTTP ${res.statusCode}");
    return [];
  }
}
