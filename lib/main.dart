import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'firebase_options.dart';
import 'core/services/app_logger.dart';
import 'core/services/prefs_service.dart';
import 'core/services/notification_service.dart';
import 'routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';

// 🔹 DEPENDENCIAS
import 'features/vehicles/providers/vehiculo_provider.dart';
import 'features/vehicles/services/vehiculo_manager.dart';
import 'features/vehicles/services/vehiculo_repository.dart';
import 'features/vehicles/services/volvo_api_service.dart';

// Pantalla inicial
import 'features/auth/screens/login_screen.dart';
import 'features/auth/screens/splash_screen.dart';

// Clave global
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// ─── Rate limiter para Sentry beforeSend ───
// Map fingerprint→timestamp del último envío. Cualquier error con el
// mismo fingerprint dentro de la ventana se dropea. Vive a nivel
// top-level porque `SentryFlutter.init` espera un callback puro y
// necesitamos estado persistente entre invocaciones del callback.
// Auto-limpieza: cuando el map crece > 100 entradas, purga las > 5 min.
final Map<String, DateTime> _sentryRateLimiter = {};
const Duration _sentryDedupWindow = Duration(seconds: 10);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ================= FIREBASE =================
  // Inicializar Firebase ANTES que AppLogger porque Crashlytics depende
  // de FirebaseCore. Si falla acá, seguimos sin telemetría: el logger
  // detecta y cae al debugPrint local.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    AppLogger.log('Firebase conectado correctamente');

    // Bug conocido en Windows desktop con firebase_core 4 +
    // cloud_firestore 6 + firebase_auth 6: si Firestore tiene
    // persistencia ON (default) y el SDK detecta el cache local
    // corrupto/inconsistente entre runs, llama internamente a
    // `settings =` después de haber arrancado Firestore para
    // intentar reconfigurar — y eso aborta el proceso con
    // "Firestore instance has already been started".
    //
    // Workaround: deshabilitar persistencia explícitamente en Windows
    // antes de cualquier acceso a Firestore. Pierde el cache offline
    // (la app necesita conexión activa) pero evita el abort. En
    // Android/iOS dejamos los defaults — funcionan bien.
    if (!kIsWeb) {
      try {
        // ignore: deprecated_member_use
        // Targeting Windows; en otros platforms este branch no aplica
        // pero como TargetPlatform requiere context, chequeo por nombre.
        if (defaultTargetPlatform == TargetPlatform.windows) {
          FirebaseFirestore.instance.settings = const Settings(
            persistenceEnabled: false,
          );
          AppLogger.log('Firestore: persistencia OFF (workaround Windows)');
        }
      } catch (e) {
        AppLogger.log('Firestore.settings no se pudo configurar: $e');
      }
    }
  } catch (e, st) {
    AppLogger.recordError(e, st, reason: 'Firebase.initializeApp falló');
  }

  // ================= ERROR HANDLERS GLOBALES =================
  // En mobile, AppLogger.init engancha FlutterError.onError y
  // PlatformDispatcher.onError directo a Crashlytics. En Web/Windows
  // dejamos los defaults de Flutter (que loguean a consola) — los
  // try/catch puntuales del código siguen usando AppLogger.recordError.
  await AppLogger.init();
  await PrefsService.init();
  await NotificationService.init();

  // Inicializar símbolos de fecha en español-AR para que widgets como
  // TableCalendar muestren los nombres de días/meses en español.
  // MaterialApp.locale solo configura las localizations de Flutter
  // (botones, tooltips); el `intl` package usa una tabla aparte que
  // hay que cargar explícitamente con esta llamada.
  await initializeDateFormatting('es_AR', null);

  // ================= SENTRY =================
  // El DSN de Sentry NO es un secret crítico (solo permite enviar
  // eventos, no leer/borrar datos del proyecto), así que lo embebemos
  // como defaultValue en lugar de obligar a pasar
  // --dart-define-from-file. Cualquiera puede extraerlo del .exe build
  // de todos modos -- es público por diseño de Sentry.
  //
  // Para deshabilitar Sentry en dev / corridas locales:
  //   flutter run -d windows --dart-define=SENTRY_DSN=
  //
  // Para rotar el DSN: ir a sentry.io → Settings → Projects → Keys, y
  // cambiar el defaultValue de abajo + commit.
  const sentryDsn = String.fromEnvironment(
    'SENTRY_DSN',
    defaultValue:
        'https://4f80dcfb9d5a40506e61e0a5884fe362@o4511318386540544.ingest.us.sentry.io/4511318389358593',
  );
  const sentryEnv = String.fromEnvironment(
    'SENTRY_ENV',
    defaultValue: 'production',
  );

  if (sentryDsn.isEmpty) {
    AppLogger.log('SENTRY_DSN vacío → Sentry deshabilitado (modo dev)');
    runApp(_armarApp());
  } else {
    // Release normalizado: sin esto, el SDK detecta el bundle ID nativo
    // que varía entre plataformas (Windows="coopertrans_movil",
    // Android/iOS="com.coopertrans.movil") y Sentry agrupa la misma
    // release como 3 apps distintas. Forzamos formato único leyendo
    // version+build de package_info_plus (que SÍ es consistente).
    // Auditoría 2026-05-18: dashboard de Releases tenía mezclados
    // "coopertrans_movil@1.0.58+61" (Win) con "com.coopertrans.movil@1.0.58+13" (iOS).
    String? sentryRelease;
    try {
      final pi = await PackageInfo.fromPlatform();
      sentryRelease =
          'com.coopertrans.movil@${pi.version}+${pi.buildNumber}';
    } catch (e) {
      // Si PackageInfo falla (raro), dejamos que el SDK use su default
      // detectado automáticamente. El crash tracking sigue funcionando.
      AppLogger.log('PackageInfo falló: $e → Sentry usa release default');
    }

    await SentryFlutter.init(
      (options) {
        options.dsn = sentryDsn;
        options.environment = sentryEnv;
        if (sentryRelease != null) {
          options.release = sentryRelease;
        }
        // tracesSampleRate: 0.05 = 5% de transactions trackeadas para
        // perf monitoring. Bajado de 0.2 (2026-05-10) ahora que la app
        // está en producción interna con 90+ empleados — con 20% el
        // volumen de transactions trackeadas crecía linealmente con
        // los usuarios y se acercaba al free tier de 5K events/mes.
        // Con 5% queda margen 4× para crecimiento y los errores reales
        // (que NO son sample-rated, siempre se mandan) tienen
        // prioridad de bandwidth.
        options.tracesSampleRate = 0.05;
        // sendDefaultPii: false por privacidad (no mandar IPs ni
        // identificadores del usuario sin consentimiento explícito).
        options.sendDefaultPii = false;
        // beforeSend: filtra errores triviales antes de mandarlos a
        // Sentry. Los errores que NO aportan información de bug real
        // pero generan ruido (network glitches transient, cancelados
        // por el usuario, asserts internos de Flutter framework) se
        // descartan en cliente — ahorra cuota Sentry y reduce el
        // "noise" del dashboard. Errores de red persistentes o errores
        // de lógica siguen llegando normales.
        //
        // Capas de defensa (en orden):
        //   1. Drop por TIPO de error / mensaje (network glitches +
        //      cancelaciones + asserts internos de Flutter).
        //   2. Rate limiter client-side: máximo 1 event del mismo
        //      fingerprint cada 10s. Red de seguridad anti-storm.
        //
        // Auditoría 2026-05-18: un sample de 100 events tenía 86 del
        // mismo error en 1 segundo (FAB del Scaffold haciendo hit-test
        // mid-transición — assert benigno de Flutter framework). Sin
        // las capas 1 y 2 ese loop solito consume 86 events de cuota.
        options.beforeSend = (event, hint) {
          final msg = (event.message?.formatted ?? '').toLowerCase();
          final exc = event.exceptions?.firstOrNull;
          final errType = (exc?.type ?? '').toLowerCase();
          final errValue = (exc?.value ?? '').toLowerCase();
          // Combinamos message + exception.value porque algunos errores
          // tienen el detalle solo en `value` (caso típico FlutterError).
          final texto = '$msg $errValue';

          // ─── Capa 1a: Network glitches ───
          // SocketException con "failed host lookup" / "connection
          // refused" es transient (wifi se cae, 4G perdido). El usuario
          // reintentará; no es bug.
          if (texto.contains('failed host lookup') ||
              texto.contains('connection refused') ||
              texto.contains('connection closed') ||
              texto.contains('connection timed out')) {
            return null;
          }

          // ─── Capa 1b: Cancelaciones de usuario ───
          // CancelledByUserException de file_picker / image_picker
          // (chofer abre el picker y cancela). Flujo normal.
          if (errType.contains('cancelledbyuser')) {
            return null;
          }

          // ─── Capa 1c: Asserts internos de Flutter framework ───
          // Estos son asserts del rendering layer que NO afectan al
          // usuario en release builds (los asserts son no-op en
          // release, pero FlutterError.onError los captura igual y
          // Sentry los recibe). Casos típicos:
          //   - "Cannot hit test a render box that has never been laid
          //     out" → toque cae mid-transición (típico FAB del
          //     Scaffold cambiando dinámicamente, modal bottom sheets,
          //     AnimatedSwitcher). Sample 86x en 1 segundo (2026-05-18).
          //   - "RenderBox was not laid out" / "NEEDS-LAYOUT"/"NEEDS-PAINT"
          //     → mismo problema fenotipado diferente.
          //   - "!_debugDuringDeviceUpdate" / "!_debugDoingThisLayout"
          //     → asserts de mouse_tracker y layout pipeline.
          //
          // Si un error REAL de la app cae en estos patrones lo vamos a
          // perder — pero el costo/beneficio es claro: estos asserts
          // generan storms de cientos de events sin valor diagnóstico
          // (el stacktrace siempre apunta a Flutter framework, nunca a
          // código nuestro). Si una pantalla específica los dispara
          // mucho, conviene arreglar el widget tree (oscilación entre
          // frames, FAB condicional, etc.).
          if (texto.contains('cannot hit test a render box') ||
              texto.contains('renderbox was not laid out') ||
              texto.contains('needs-layout') ||
              texto.contains('needs-paint') ||
              texto.contains('!_debugduringdeviceupdate') ||
              texto.contains('!_debugdoingthislayout')) {
            return null;
          }

          // ─── Capa 1d: Firestore transient (auditoría 2026-05-24) ───
          // El SDK de Firestore reporta "service unavailable" cuando hay
          // microcaídas del backend. El propio mensaje literal del
          // framework dice "This is most likely a transient condition
          // and may be corrected by retrying with a backoff" → no es
          // bug, no es actionable. El SDK ya reintenta solo. Sentry
          // estaba reportando FLUTTER-25 (1 issue, ~25 events/14d) por
          // este patrón sin que hubiera nada que arreglar.
          if (texto.contains('cloud_firestore/unavailable') ||
              texto.contains('cloud_firestore/deadline-exceeded') ||
              texto.contains('the service is currently unavailable')) {
            return null;
          }

          // ─── Capa 1e: Pre-Launch Report de Google Play ───
          // (auditoría 2026-05-24). Cada vez que se sube un AAB a Play,
          // Google corre la app en farms de emuladores virtuales con
          // specs falsas (OnePlus 8 Pro pero CPU 2-core, screen 288x448
          // DPI 106, processorFrequency 0). Los crashes que genera ese
          // testing automatizado el SDK los reporta como si fueran
          // usuarios reales. FLUTTER-H + FLUTTER-W ambos del Pre-Launch.
          //
          // Heurística: `processorFrequency == 0` es la señal MÁS
          // confiable — devices reales nunca reportan 0 MHz. Si en el
          // futuro aparecen falsos positivos (usuarios reales
          // droppeados), endurecer agregando AND con screenWidth < 360
          // o processorCount < 4.
          final device = event.contexts.device;
          if (device?.processorFrequency == 0) {
            return null;
          }

          // ─── Capa 2: Rate limiter (anti event storm) ───
          // Red de seguridad para CUALQUIER error que entre en loop
          // (callback que se ejecuta 60-120 veces por segundo, listener
          // que dispara error en cada paint, etc.). Si el mismo
          // fingerprint apareció < 10s atrás, dropea. Limpia entradas
          // viejas cada vez que el map crece > 100 (no leak de memoria
          // en sesiones largas).
          final fingerprint =
              '$errType|${texto.length > 80 ? texto.substring(0, 80) : texto}';
          final ahora = DateTime.now();
          final ultimo = _sentryRateLimiter[fingerprint];
          if (ultimo != null &&
              ahora.difference(ultimo) < _sentryDedupWindow) {
            return null;
          }
          _sentryRateLimiter[fingerprint] = ahora;
          if (_sentryRateLimiter.length > 100) {
            final cutoff = ahora.subtract(const Duration(minutes: 5));
            _sentryRateLimiter.removeWhere(
              (_, v) => v.isBefore(cutoff),
            );
          }

          return event;
        };
      },
      appRunner: () => runApp(_armarApp()),
    );
    AppLogger.log('Sentry inicializado (env: $sentryEnv)');
  }
}

/// Construye el árbol de Providers + LogisticaApp. Extraído acá para
/// reusarlo desde el branch con/sin Sentry de `main()`.
Widget _armarApp() {
  return MultiProvider(
    providers: [
      // 🔹 API
      Provider(create: (_) => VolvoApiService()),

      // 🔹 REPO
      ProxyProvider<VolvoApiService, VehiculoRepository>(
        update: (_, api, __) => VehiculoRepository(api: api),
      ),

      // 🔹 MANAGER
      ProxyProvider2<VehiculoRepository, VolvoApiService, VehiculoManager>(
        update: (_, repo, api, __) => VehiculoManager(repo, api),
      ),

      // 🔹 PROVIDER UI
      ChangeNotifierProxyProvider2<VehiculoManager, VehiculoRepository, VehiculoProvider>(
        create: (context) => VehiculoProvider(
          manager: context.read<VehiculoManager>(),
          repository: context.read<VehiculoRepository>(),
        ),
        update: (_, manager, repo, provider) {
          provider!.manager = manager;
          provider.repository = repo;
          return provider;
        },
      ),

      // AutoSyncService + SyncDashboard eliminados 2026-05-24: el timer
      // cliente cada 60s era duplicado del cron server-side
      // `estadoVolvoPoller` (cada 5 min) que ya escribe VOLVO_ESTADO Y
      // propaga KM_ACTUAL/NIVEL_COMBUSTIBLE/AUTONOMIA_KM/SERVICE_DISTANCE_KM
      // a VEHICULOS. Las pantallas críticas (Mantenimiento Detalle, V6 Km
      // Recorridos) leen VOLVO_ESTADO/TELEMETRIA_HISTORICO directos —
      // refresco más fresco que el viejo dashboard de Sync, sin pegarle al
      // API Volvo desde cada admin abierto.
    ],
    child: const LogisticaApp(),
  );
}

// ================= APP =================

class LogisticaApp extends StatefulWidget {
  const LogisticaApp({super.key});

  @override
  State<LogisticaApp> createState() => _LogisticaAppState();
}

class _LogisticaAppState extends State<LogisticaApp> {
  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Precarga del cache de Volvo (no bloqueante: si falla, los reads
      // posteriores irán igual al endpoint individual).
      context.read<VehiculoProvider>().init();
    });

    NotificationService.selectNotificationStream.stream
        .listen((String? payload) {
      if (payload == null) return;
      final nav = navigatorKey.currentState;
      if (nav == null) return;
      if (payload == 'vencimiento') {
        nav.pushNamed(AppRoutes.misVencimientos);
      } else if (payload == 'admin_revision') {
        nav.pushNamed(AppRoutes.adminRevisiones);
      }
    });
  }

  @override
  void dispose() {
    // El stop del AutoSync lo maneja el provider tree.
    NotificationService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      // SentryNavigatorObserver graba cada push/pop de ruta como
      // breadcrumb. Crítico para diagnosticar errores: sin esto, los
      // events de Sentry no dicen en qué pantalla estaba el usuario
      // (auditoría 2026-05-18: 86 events del FAB hit-test sin saber
      // qué pantalla los disparó). No crea transactions automáticas
      // (las controla tracesSampleRate). Seguro pasarlo aunque Sentry
      // esté deshabilitado — si no hay client, no manda nada.
      navigatorObservers: [SentryNavigatorObserver()],
      title: AppTexts.appName,
      debugShowCheckedModeBanner: false,

      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      supportedLocales: const [
        Locale('es', 'AR'),
      ],

      locale: const Locale('es', 'AR'),

      theme: AppTheme.darkTheme,

      // Arrancamos en /splash (logo ~1.5s) y de ahí saltamos a /home.
      // El AuthGuard de /home (vía AppRouter.generateRoute) usa un
      // StreamBuilder con authStateChanges() para esperar que Firebase
      // Auth termine de restorear la sesión persistida en disco antes
      // de decidir si mostrar la pantalla o redirigir a login. Esto es
      // crítico en Windows desktop, donde el restore del C++ SDK es
      // async y un check síncrono al startup (como teníamos antes,
      // mirando solo `PrefsService.isLoggedIn`) podía bouncearte al
      // login aunque el token estuviera vivo.
      initialRoute: AppRoutes.splash,

      routes: {
        AppRoutes.login: (_) => const LoginScreen(),
        AppRoutes.splash: (_) => const SplashScreen(),
      },

      onGenerateRoute: AppRouter.generateRoute,
      onUnknownRoute: AppRouter.unknownRoute,
    );
  }
}