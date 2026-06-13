import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../constants/app_constants.dart';
import 'app_logger.dart';
import 'deep_link_service.dart';
import 'notification_service.dart';
import 'prefs_service.dart';

/// Handler de mensajes en BACKGROUND. Top-level + `@pragma('vm:entry-point')`
/// requerido por firebase_messaging (corre en un isolate aparte). No hace
/// trabajo pesado: el SO ya muestra la notificación (el payload trae
/// `notification`); esto solo necesita EXISTIR para que FCM despierte la app
/// y entregue con la app en background/cerrada.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {}

/// Push FCM (Vertical 2 de deep-links+push). Registra el token del
/// dispositivo, muestra los push en foreground y navega al tappearlos
/// (reusa el resolver de los deep links — vocabulario único de `destino`).
///
/// **NO-OP en Windows/web**: `firebase_messaging` no soporta esas
/// plataformas, así que todos los métodos chequean [_soportado] primero. La
/// app admin corre en Windows desktop — sin esta guarda, instanciar
/// FirebaseMessaging tiraría en runtime.
class PushService {
  PushService._();

  static bool get _soportado =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static void Function(String ruta)? _navegar;

  /// Init temprano (permisos + handlers). [navegar] navega a la ruta del tap
  /// (main.dart la conecta a `navigatorKey`). NO registra el token todavía:
  /// eso necesita el dni (ver [vincularConUsuario], tras login).
  static Future<void> init(void Function(String ruta) navegar) async {
    if (!_soportado) return;
    _navegar = navegar;
    try {
      FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);
      await FirebaseMessaging.instance.requestPermission();

      // Foreground: con la app abierta el SO no muestra el push → notif local.
      FirebaseMessaging.onMessage.listen((m) {
        final n = m.notification;
        if (n != null) {
          NotificationService.mostrarPush(
            titulo: n.title ?? 'Coopertrans Móvil',
            cuerpo: n.body ?? '',
            payload: m.data['destino'] as String?,
          );
        }
      });

      // Tap con la app en background → foreground.
      FirebaseMessaging.onMessageOpenedApp.listen(_navegarDesde);
      // Tap con la app CERRADA (el push la abrió): mensaje inicial.
      final inicial = await FirebaseMessaging.instance.getInitialMessage();
      if (inicial != null) _navegarDesde(inicial);

      // Refresh del token → re-vincular al usuario actual.
      FirebaseMessaging.instance.onTokenRefresh.listen((t) {
        final dni = PrefsService.dni;
        if (dni.isNotEmpty) _guardarToken(dni, t);
      });
    } catch (e, s) {
      AppLogger.recordError(e, s, reason: 'PushService.init');
    }
  }

  /// Tras login (o al arrancar con sesión persistida): registra el token del
  /// dispositivo en `EMPLEADOS/{dni}/dispositivos/{installId}`. El backend
  /// (`enviarPush`) lo lee para mandar. No-op sin soporte / sin dni.
  static Future<void> vincularConUsuario(String dni) async {
    if (!_soportado || dni.isEmpty) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) await _guardarToken(dni, token);
    } catch (e, s) {
      AppLogger.recordError(e, s, reason: 'PushService.vincular');
    }
  }

  static Future<void> _guardarToken(String dni, String token) async {
    try {
      await FirebaseFirestore.instance
          .collection(AppCollections.empleados).doc(dni)
          .collection('dispositivos').doc(PrefsService.installId)
          .set({
        'token': token,
        'plataforma': Platform.isIOS ? 'ios' : 'android',
        'actualizado_en': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e, s) {
      AppLogger.recordError(e, s, reason: 'PushService.guardarToken');
    }
  }

  static void _navegarDesde(RemoteMessage m) {
    final ruta = DeepLinkService.rutaDeDestino(m.data['destino'] as String?);
    if (ruta != null) _navegar?.call(ruta);
  }
}
