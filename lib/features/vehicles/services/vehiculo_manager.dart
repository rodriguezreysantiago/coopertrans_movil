import 'dart:collection';
import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/prefs_service.dart';
import 'vehiculo_repository.dart';
import 'volvo_api_service.dart';

class VehiculoManager {
  final VehiculoRepository _repo;
  final VolvoApiService _api;

  VehiculoManager(this._repo, this._api);

  final Set<String> _sincronizando = {};

  // 🔥 LIMITADOR DE CONCURRENCIA
  final int _maxConcurrent = 5;
  int _currentRunning = 0;

  // 🔥 RATE LIMIT (200–500 ms)
  final int _minDelayMs = 200;
  final int _maxDelayMs = 500;
  final Random _random = Random();

  // 🔥 cola tipada correctamente
  final Queue<Future<void> Function()> _queue = Queue();

  List<dynamic> cacheVolvo = [];

  // ================================
  // INIT / CACHE
  // ================================
  Future<void> precargarDatosVolvo() async {
    // Solo ADMIN tiene permiso server-side para invocar `volvoProxy`
    // (el callable rechaza con 401/403 a cualquier otro rol). Para
    // los demás (chofer, planta, gomería, seg-higiene, supervisor)
    // salimos en silencio — sin llamada al API y sin log ruidoso.
    //
    // Bug observado vía Sentry breadcrumbs 2026-05-06: choferes
    // disparaban "[VOLVO FLOTA] HTTP 401" al arrancar la app porque
    // este método se ejecutaba sin gating de rol. La precarga es
    // útil solo para el panel admin (metadata de unidades para sync);
    // los demás roles ya leen del cache de Firestore.
    // Usar AppRoles.normalizar() para cubrir rol legacy 'USUARIO' que
    // se mapea a CHOFER. Antes el literal 'ADMIN' funcionaba por
    // casualidad — si el case cambiara (cualquier dato corrupto en
    // lowercase) el guard fallaba y los choferes disparaban
    // [VOLVO FLOTA] HTTP 401.
    if (AppRoles.normalizar(PrefsService.rol) != AppRoles.admin) {
      cacheVolvo = [];
      return;
    }
    try {
      cacheVolvo = await _repo.traerFlotaVolvo();
    } catch (e) {
      debugPrint("⚠️ Error cargando cache Volvo: $e");
      cacheVolvo = [];
    }
  }

  // ================================
  // 🔥 SYNC CENTRAL (CON POOL + RATE LIMIT)
  // ================================
  Future<void> sincronizarUnidadIndividual(
    String patente,
    String vin,
  ) async {
    if (_sincronizando.contains(patente)) return;

    final completer = Completer<void>();

    _queue.add(() async {
      try {
        await _executeSync(patente, vin);
        completer.complete();
      } catch (e) {
        completer.completeError(e);
      }
    });

    _processQueue();

    return completer.future;
  }

  void _processQueue() {
    while (_currentRunning < _maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      _currentRunning++;

      _runWithDelay(task);
    }
  }

  void _runWithDelay(Future<void> Function() task) async {
    // 🔥 delay random anti-rate-limit
    final delay = _minDelayMs +
        _random.nextInt(_maxDelayMs - _minDelayMs + 1);

    await Future.delayed(Duration(milliseconds: delay));

    // Fire-and-forget intencional: el pool de concurrencia depende de
    // que la task corra en paralelo. El whenComplete agenda el
    // decremento del contador para cuando termine. Esperarla acá
    // (await) rompería el paralelismo.
    unawaited(task().whenComplete(() {
      _currentRunning--;
      _processQueue();
    }));
  }

  Future<void> _executeSync(String patente, String vin) async {
    _sincronizando.add(patente);

    final cleanVin = vin.trim().toUpperCase();

    try {
      // 1️⃣ Pre-actualización de KM rápida desde el cache.
      //    Si la precarga masiva (`/vehicles`) ya nos dio odómetro,
      //    actualizamos el doc para que la UI tenga datos frescos
      //    inmediatamente. No reemplaza el call individual: el cache
      //    NO trae combustible, autonomía ni serviceDistance — para
      //    eso necesitamos el endpoint `/vehiclestatuses`.
      //
      //    Antes había un fast path que hacía RETURN acá, lo cual
      //    significaba que `serviceDistance` nunca se sincronizaba
      //    para tractores en cache. Bug C3 del code review.
      final metrosCache = _buscarEnCache(cleanVin);
      if (metrosCache != null && metrosCache > 0) {
        final kmCache = metrosCache / 1000;
        try {
          await _repo.actualizarKilometraje(patente: patente, km: kmCache);
        } catch (e) {
          // No es bloqueante — si falla, igual seguimos al call individual
          // que va a sobrescribir el campo.
          debugPrint("⚠️ pre-update KM cache falló para $patente: $e");
        }
      }

      // 2️⃣ API individual: trae odómetro + combustible + autonomía +
      //    serviceDistance (uptimeData) en un solo request. SIEMPRE
      //    se llama, incluso si el cache ya tenía odómetro — los otros
      //    campos solo vienen por este endpoint.
      final tele = await _api.traerTelemetria(cleanVin);

      if (!tele.tieneAlgunDato) {
        // Silenciado: vehiculos sin datos validos (ignition off, sin
        // GPS, etc.) son normales y aparecen como "saltados" en el
        // Sync Dashboard.
        // debugPrint("ℹ️ $patente sin datos válidos");
        return;
      }

      final km = tele.odometroMetros != null
          ? tele.odometroMetros! / 1000
          : null;

      await _repo.actualizarTelemetria(
        patente: patente,
        km: km,
        nivelCombustiblePct: tele.nivelCombustiblePct,
        nivelAdbluePct: tele.nivelAdbluePct,
        autonomiaKm: tele.autonomiaKm,
        serviceDistanceKm: tele.serviceDistanceKm,
      );

      // Mantenimiento preventivo: si el tractor cruzó al estado
      // VENCIDO en este sync, disparamos notificación local + escribimos
      // el evento para idempotencia. Fire-and-forget — un fallo acá NO
      // debe romper el sync.
      unawaited(_evaluarMantenimiento(patente, tele.serviceDistanceKm));

      // Log de éxito desactivado — visible desde el dashboard de sync.
    } catch (e, stack) {
      debugPrint("❌ Sync error $patente: $e");
      debugPrint(stack.toString());
      rethrow;
    } finally {
      _sincronizando.remove(patente);
    }
  }

  // ================================
  // CACHE
  // ================================
  double? _buscarEnCache(String vin) {
    try {
      final v = cacheVolvo.firstWhere(
        (e) => (e['vin'] ?? '').toString().toUpperCase() == vin,
      );

      final value =
          v['hrTotalVehicleDistance'] ?? v['lastKnownOdometer'];

      if (value == null) return null;

      return (value as num).toDouble();
    } catch (_) {
      return null;
    }
  }

  // ================================
  // ESTADO
  // ================================
  bool estaSincronizando(String patente) {
    return _sincronizando.contains(patente);
  }

  // ================================
  // MANTENIMIENTO PREVENTIVO
  // ================================
  //
  // Después de cada sync exitoso evaluamos si el tractor cruzó al
  // estado VENCIDO. La idempotencia se maneja con el doc
  // `MANTENIMIENTOS_AVISADOS/{patente}` que guarda el `ultimo_estado`
  // que ya notificamos. El cruce VÁLIDO es: estado anterior !=
  // VENCIDO  Y  estado nuevo == VENCIDO. En ese caso disparamos la
  // notificación local y persistimos el nuevo estado.
  //
  // Si después de un service el tractor vuelve a OK y más adelante
  // vuelve a vencer, la transición OK→VENCIDO disparará una nueva
  // notificación (porque el `ultimo_estado` quedó en OK).
  Future<void> _evaluarMantenimiento(
    String patente,
    double? serviceDistanceApiKm,
  ) async {
    final db = FirebaseFirestore.instance;
    final pat = patente.trim();

    // Resolución de serviceDistance: MANUAL > API > NINGUNO. MISMO criterio
    // que la UI (`_resolverServiceDistance` en admin_mantenimiento_widgets):
    // el service cargado a mano (`ULTIMO_SERVICE_KM`) gana porque el paquete
    // UPTIME del contrato Volvo no está activado y el `serviceDistance` del
    // API a veces trae basura (ej. AG218ZD: 642.069 km al próximo service
    // para un tractor que en realidad estaba vencido). Si clasificáramos solo
    // por el API acá, podríamos notificar "VENCIDO" (o NO notificar uno real)
    // en contra de lo que muestra la pantalla. Usamos el helper público
    // `serviceDistanceDesdeManual` para no duplicar la fórmula.
    double? manualServiceDistanceKm;
    try {
      final vehSnap =
          await db.collection(AppCollections.vehiculos).doc(pat).get();
      final vehData = vehSnap.data();
      if (vehData != null) {
        manualServiceDistanceKm = AppMantenimiento.serviceDistanceDesdeManual(
          ultimoServiceKm: (vehData['ULTIMO_SERVICE_KM'] as num?)?.toDouble(),
          kmActual: (vehData['KM_ACTUAL'] as num?)?.toDouble(),
        );
      }
    } catch (e) {
      // Si no podemos leer el doc, caemos al valor del API (mejor que nada).
      debugPrint("⚠️ [MANTENIMIENTO] no pude leer manual de $pat: $e");
    }

    final serviceDistanceKm = manualServiceDistanceKm ?? serviceDistanceApiKm;
    if (serviceDistanceKm == null) {
      // Sin datos (ni manual ni API) no podemos clasificar — no escribimos.
      return;
    }
    final nuevoEstado = AppMantenimiento.clasificar(serviceDistanceKm);

    final ref = db
        .collection(AppCollections.mantenimientosAvisados)
        .doc(pat);

    try {
      final snap = await ref.get();
      final data = snap.data();
      final ultimoCodigo =
          (data?['ultimo_estado'] as String?)?.toUpperCase();

      // Solo notificamos cuando hay TRANSICIÓN a VENCIDO. Si el
      // tractor ya estaba marcado como vencido y sigue vencido, no
      // re-notificamos (sería spam).
      final cruzoAVencido =
          nuevoEstado == MantenimientoEstado.vencido &&
              ultimoCodigo != MantenimientoEstado.vencido.name.toUpperCase();

      // Persistimos el estado actual SIEMPRE (aunque no notifiquemos).
      // Así, si en el próximo ciclo cambia, sabemos desde dónde venía.
      final update = <String, dynamic>{
        'patente': patente,
        'ultimo_estado': nuevoEstado.name.toUpperCase(),
        'ultimo_service_distance_km': serviceDistanceKm,
        'ultima_evaluacion_at': FieldValue.serverTimestamp(),
      };

      if (cruzoAVencido) {
        update['ultimo_aviso_vencido_at'] = FieldValue.serverTimestamp();
        // Notificación local — el método ya hace kIsWeb / Platform check.
        unawaited(NotificationService.mostrarAlertaMantenimiento(
          patente: patente,
        ));
      }

      await ref.set(update, SetOptions(merge: true));

      if (cruzoAVencido) {
        debugPrint(
            "🔧 [MANTENIMIENTO] $patente cruzó a VENCIDO — notificación local enviada.");
      }
    } catch (e) {
      // Si la idempotencia falla por algún motivo (rules / network),
      // logueamos pero no rompemos el sync. La próxima evaluación
      // volverá a intentarlo. Como no marcamos el aviso, podría
      // re-notificar — preferimos eso a NO notificar si hay un
      // service vencido real.
      debugPrint("⚠️ [MANTENIMIENTO] Error evaluando $patente: $e");
    }
  }
}