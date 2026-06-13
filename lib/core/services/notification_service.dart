import 'dart:io';
import 'dart:async'; // ✅ MENTOR: Necesario para el StreamController
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../../shared/constants/app_colors.dart';
import '../../shared/utils/formatters.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  
  // ✅ MEJORA PRO: Stream para manejar la navegación al tocar notificaciones
  static final StreamController<String?> selectNotificationStream = StreamController<String?>.broadcast();

  static Future<void> init() async {
    // Timezone: necesario para `zonedSchedule` que usa el agendado de
    // recordatorios de vencimientos. `initializeTimeZones` carga la
    // base IANA y `setLocalLocation` define el huso local. Bahía Blanca
    // está en `America/Argentina/Buenos_Aires` — todo el equipo usa el
    // mismo huso así que no necesitamos detección dinámica.
    if (!kIsWeb) {
      tz.initializeTimeZones();
      try {
        tz.setLocalLocation(tz.getLocation('America/Argentina/Buenos_Aires'));
      } catch (_) {
        // Si falla la zona específica, dejamos UTC como fallback
        // (los avisos pueden quedar corridos pero igual disparan).
      }
    }

    // CONFIGURACIÓN ANDROID
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    // CONFIGURACIÓN IOS (DARWIN)
    const DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    // CONFIGURACIÓN LINUX
    const LinuxInitializationSettings initializationSettingsLinux =
        LinuxInitializationSettings(defaultActionName: 'Open');

    // CONFIGURACIÓN WINDOWS
    // Requerido por flutter_local_notifications 21+: si el binario corre
    // en Windows desktop y no se pasa este bloque, `initialize()` tira
    // `Invalid argument(s): Windows settings must be set when targeting
    // Windows platform` y la app crashea silenciosamente en release.
    //
    // - `appUserModelId`: identificador único del shell de Windows
    //   (formato Microsoft "Empresa.Producto.SubProducto"). NO usar
    //   espacios ni caracteres especiales — Windows agrupa toasts por
    //   este id en el centro de notificaciones.
    // - `guid`: identificador del callback de activación de toast.
    //   Generado una sola vez y debe quedar fijo (cambiarlo invalida
    //   los toasts persistidos).
    const WindowsInitializationSettings initializationSettingsWindows =
        WindowsInitializationSettings(
      appName: 'Coopertrans Móvil',
      appUserModelId: 'Coopertrans.Movil.Logistica',
      guid: '4F8A7B2E-9D6C-4B3A-8F1E-2C7D9A5B4E8F',
    );

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
      // macOS usa DarwinInitializationSettings igual que iOS. Sin este
      // parámetro, initialize() tira en macOS (mismo patrón que Windows
      // arriba) y, como init() corría sin try/catch en main(), tumbaba el
      // arranque entero -> pantalla negra. Reutiliza la config de iOS.
      macOS: initializationSettingsIOS,
      linux: initializationSettingsLinux,
      windows: initializationSettingsWindows,
    );

    await _notificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse details) {
        debugPrint("NOTIFICACIÓN TOCADA CON PAYLOAD: ${details.payload}");
        // ✅ MEJORA PRO: Emitimos el payload para que el main.dart pueda navegar a la pantalla correcta
        selectNotificationStream.add(details.payload);
      },
    );

    // ✅ CORRECCIÓN CRÍTICA (Bug Fix Web)
    // Debemos verificar kIsWeb de forma aislada PRIMERO.
    // Si es Web, salimos del método para que Platform.isAndroid NUNCA se ejecute.
    if (kIsWeb) return; 

    // Ahora es seguro usar Platform.isAndroid
    if (Platform.isAndroid) {
      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }
  }

  /// NOTIFICACIÓN PARA EL CHOFER (Vencimientos)
  static Future<void> mostrarAlertaVencimiento({
    required int id,
    required String titulo,
    required String mensaje,
  }) async {
    // Si la app está en la web, local_notifications no funciona. Salimos silenciosamente.
    if (kIsWeb) return; 

    AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'vencimientos_canal',
      'Alertas de Vencimientos',
      channelDescription: 'Notificaciones sobre documentos próximos a vencer',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      color: AppColors.warning,
      styleInformation: BigTextStyleInformation(mensaje), 
    );

    NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentAlert: true, 
        presentBadge: true, 
        presentSound: true,
      ),
    );

    // Payload 'vencimiento' será atrapado por el StreamController
    await _notificationsPlugin.show(
      id: id,
      title: titulo,
      body: mensaje,
      notificationDetails: platformDetails,
      payload: 'vencimiento',
    );
  }

  /// NOTIFICACIÓN PARA EL ADMIN (Mantenimiento vencido)
  ///
  /// Disparada por `VehiculoManager` cuando detecta que un tractor cruzó
  /// al estado "VENCIDO" en `serviceDistance`. La idempotencia (no
  /// notificar dos veces el mismo evento) la maneja el caller via la
  /// colección `MANTENIMIENTOS_AVISADOS`.
  static Future<void> mostrarAlertaMantenimiento({
    required String patente,
    String? marca,
    String? modelo,
  }) async {
    if (kIsWeb) return;

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'mantenimiento_canal',
      'Mantenimiento preventivo',
      channelDescription:
          'Avisos cuando un tractor cruza el umbral de service vencido.',
      importance: Importance.max,
      priority: Priority.high,
      color: AppColors.error,
      ledColor: AppColors.error,
      ledOnMs: 1000,
      ledOffMs: 500,
    );

    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
      ),
    );

    final unidad = (marca != null && modelo != null)
        ? '$marca $modelo ($patente)'
        : patente;

    // ID determinista por patente + día. Si por algún motivo el caller
    // re-dispara sin pasar por la idempotencia de Firestore (ej. test),
    // el plugin nativo deduplica con el mismo ID.
    final id = _idDeterministico('mantenimiento_$patente');

    await _notificationsPlugin.show(
      id: id,
      title: 'Service vencido',
      body: 'El tractor $unidad pasó el momento de service. '
          'Programá el ingreso al taller cuanto antes.',
      notificationDetails: platformDetails,
      payload: 'mantenimiento_$patente',
    );
  }

  /// NOTIFICACIÓN PARA EL ADMIN (Nuevos Trámites)
  static Future<void> mostrarAvisoAdmin({
    required String chofer,
    required String documento,
  }) async {
    if (kIsWeb) return;

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'admin_canal',
      'Avisos Administrativos',
      channelDescription: 'Notificaciones sobre nuevas revisiones pendientes',
      importance: Importance.max,
      priority: Priority.high,
      color: AppColors.success,
      ledColor: AppColors.success,
      ledOnMs: 1000,
      ledOffMs: 500,
    );

    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(
        presentAlert: true, 
        presentSound: true,
      ),
    );

    // Bug B1 del code review: antes usábamos un ID dinámico que no
    // garantizaba idempotencia — si el flujo se reintentaba (error de
    // red), el admin podía recibir dos notificaciones del mismo aviso.
    // Ahora el ID es determinístico por chofer + documento + día, así
    // re-intentos del mismo evento producen la MISMA notificación
    // (que el plugin nativo deduplica al mostrar).
    // Usamos componentes LOCALES (no UTC). Si usaramos toIso8601String,
    // entre 21:00 y 23:59 ART el ISO es del dia siguiente (UTC) y la
    // idempotencia "una notificacion por dia" se rompe.
    final hoyIso = AppFormatters.aIsoFechaLocal(DateTime.now());
    final id = _idDeterministico('admin_${chofer}_${documento}_$hoyIso');

    await _notificationsPlugin.show(
      id: id,
      title: "Nueva Revisión Pendiente",
      body: "$chofer subió: $documento",
      notificationDetails: platformDetails,
      payload: 'admin_revision',
    );
  }

  /// Muestra una notificación local genérica — para los push FCM recibidos
  /// en FOREGROUND (con la app abierta el SO no los muestra solo). El
  /// `payload` (keyword de destino) lo consume `selectNotificationStream`
  /// al tappear, que navega vía el mismo resolver que los deep links.
  static Future<void> mostrarPush({
    required String titulo,
    required String cuerpo,
    String? payload,
  }) async {
    if (kIsWeb) return;
    const NotificationDetails platformDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'push_canal',
        'Avisos push',
        channelDescription: 'Notificaciones push de Coopertrans Móvil',
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
      ),
    );
    await _notificationsPlugin.show(
      id: _idDeterministico('push_${titulo}_$cuerpo'),
      title: titulo,
      body: cuerpo,
      notificationDetails: platformDetails,
      payload: payload,
    );
  }

  // ===========================================================================
  // RECORDATORIOS AGENDADOS (vencimientos del chofer)
  // ===========================================================================

  /// Identifica el rango de IDs reservado para recordatorios agendados
  /// de vencimientos. Al cancelar todos los recordatorios usamos
  /// `cancelAll` global, así que este rango es solo documentación —
  /// la única razón por la que el rango importa es que los IDs deben
  /// ser únicos a través de toda la app y los hash truncados a 31 bits
  /// nos dan ~2 mil millones de slots, así que no chocamos con los
  /// `id` que usa `mostrarAlertaVencimiento` (los cuales son
  /// pasados explícitamente por el caller, raros).
  static const int _idMaxBits = 0x7FFFFFFF;

  /// Cancela TODOS los recordatorios agendados.
  /// Idempotente: pensado para ser llamado antes de re-agendar la lista
  /// completa, así no acumulamos avisos viejos.
  static Future<void> cancelarTodosLosRecordatorios() async {
    if (kIsWeb) return;
    try {
      await _notificationsPlugin.cancelAll();
    } catch (e) {
      debugPrint('No se pudieron cancelar recordatorios: $e');
    }
  }

  /// Agenda recordatorios locales para una lista de vencimientos.
  ///
  /// Por cada [VencimientoAviso] con fecha futura, crea hasta 4 avisos
  /// (a 30, 15, 7 y 1 día antes de la fecha). Los avisos del pasado
  /// se descartan silenciosamente — si hoy la fecha de aviso ya pasó,
  /// no tiene sentido programarla.
  ///
  /// El ID de cada notificación es un hash determinístico de
  /// `campoBase + dias_antes`, así que llamadas repetidas con la misma
  /// data producen los mismos IDs y `zonedSchedule` los reemplaza
  /// (idempotencia natural). Igual conviene `cancelarTodosLosRecordatorios`
  /// antes para limpiar campos que el chofer haya renovado y ya no
  /// están en la lista actual.
  ///
  /// **Plataforma**: solo Android/iOS. En Web no hace nada.
  ///
  /// Uso típico desde la pantalla de "Mis Vencimientos":
  /// ```dart
  /// await NotificationService.cancelarTodosLosRecordatorios();
  /// await NotificationService.agendarRecordatoriosVencimientos(items);
  /// ```
  static Future<void> agendarRecordatoriosVencimientos(
    List<VencimientoAviso> avisos,
  ) async {
    if (kIsWeb) return;

    const diasOffsets = [30, 15, 7, 1];
    final ahora = tz.TZDateTime.now(tz.local);

    for (final aviso in avisos) {
      for (final diasAntes in diasOffsets) {
        final cuando = tz.TZDateTime.from(aviso.fecha, tz.local)
            .subtract(Duration(days: diasAntes));
        // No agendar avisos del pasado.
        if (cuando.isBefore(ahora)) continue;

        final id = _idDeterministico(
          '${aviso.campoBase}_$diasAntes',
        );
        final mensaje = _mensajeRecordatorio(aviso, diasAntes);

        try {
          await _notificationsPlugin.zonedSchedule(
            id: id,
            title: 'Vencimiento ${aviso.tipoDoc}',
            body: mensaje,
            scheduledDate: cuando,
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'vencimientos_canal',
                'Alertas de Vencimientos',
                channelDescription:
                    'Notificaciones sobre documentos próximos a vencer',
                importance: Importance.high,
                priority: Priority.high,
                color: AppColors.warning,
              ),
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            // El parámetro `uiLocalNotificationDateInterpretation` se
            // removió en flutter_local_notifications v18+. Antes era
            // necesario para iOS UILocalNotification (deprecado por Apple
            // hace años); ahora `zonedSchedule` siempre interpreta el
            // `tz.TZDateTime` como momento absoluto en su huso, que es
            // el comportamiento que queremos para vencimientos fijos.
            payload: 'vencimiento',
            // Solo necesitamos el momento absoluto en el huso local; no
            // marcamos `matchDateTimeComponents` para que no se repita.
          );
        } catch (e) {
          // Si una notificación particular falla (permiso revocado,
          // canal no creado, etc.) seguimos con las siguientes.
          debugPrint('No se pudo agendar aviso $id: $e');
        }
      }
    }
  }

  /// Texto del recordatorio según los días que faltan. Tono y verbo
  /// alineados con los avisos que manda el bot de WhatsApp
  /// (`whatsapp-bot/src/aviso_builder.js`) para que el chofer reciba
  /// avisos consistentes vía push y vía WhatsApp.
  static String _mensajeRecordatorio(VencimientoAviso a, int diasAntes) {
    if (diasAntes == 1) {
      return 'Tu ${a.tipoDoc.toLowerCase()} vence MAÑANA. Si todavía no '
          'iniciaste el trámite, hacelo ya.';
    }
    if (diasAntes <= 7) {
      return 'Tu ${a.tipoDoc.toLowerCase()} vence en $diasAntes días. '
          'Empezá la renovación lo antes posible.';
    }
    if (diasAntes <= 15) {
      return 'Tu ${a.tipoDoc.toLowerCase()} vence en $diasAntes días. '
          'Es buen momento para empezar el trámite.';
    }
    return 'Aviso preventivo: tu ${a.tipoDoc.toLowerCase()} vence en '
        '$diasAntes días.';
  }

  /// Hash determinístico positivo de 31 bits a partir de un string.
  /// Útil para generar IDs de notificación reproducibles desde una
  /// clave estable (`campoBase_diasAntes`).
  static int _idDeterministico(String clave) {
    // Algoritmo simple tipo djb2: rápido, suficiente para IDs únicos
    // dentro del rango aceptado por el plugin nativo.
    var hash = 5381;
    for (final code in clave.codeUnits) {
      hash = ((hash << 5) + hash) + code;
      hash &= _idMaxBits;
    }
    return hash;
  }

  // ✅ MEJORA PRO: Método de limpieza para evitar fugas de memoria
  static void dispose() {
    selectNotificationStream.close();
  }
}

/// Datos mínimos para programar un recordatorio de vencimiento.
/// Lo declaramos acá (en el mismo archivo del servicio) porque
/// `VencimientoItem` tiene más campos de los que necesitamos y depende
/// de Firestore — preferimos un DTO simple desacoplado.
class VencimientoAviso {
  /// Fecha del vencimiento (no la del recordatorio — el servicio
  /// resta los días offsets internamente).
  final DateTime fecha;

  /// Etiqueta legible del documento (ej. "Licencia", "RTO").
  final String tipoDoc;

  /// Sufijo único del campo en Firestore (ej. "LICENCIA_DE_CONDUCIR").
  /// Se usa para construir IDs deterministas de notificaciones.
  final String campoBase;

  const VencimientoAviso({
    required this.fecha,
    required this.tipoDoc,
    required this.campoBase,
  });
}
