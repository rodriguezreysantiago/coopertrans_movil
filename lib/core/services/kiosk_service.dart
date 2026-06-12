import 'package:flutter/services.dart';

/// Control del modo kiosk de la tablet de Gomería (Device Owner) desde Dart.
///
/// Dos usos:
///  - Saber si esta instancia corre en la tablet kiosk (`esDeviceOwner`) — para
///    mostrar u ocultar la salida a mantenimiento en el panel de admin.
///  - Salir a mantenimiento / volver al kiosk (un admin afloja el encierro para
///    revisar algo en la tablet, sin desactivar el Device Owner).
///
/// Todo es no-op seguro fuera de la tablet kiosk: en un teléfono común
/// `esDeviceOwner` da false y la UI ni muestra los controles.
class KioskService {
  KioskService._();

  // Canal del updater (ya expone esDeviceOwner) + canal de control (lock task).
  static const MethodChannel _update =
      MethodChannel('com.coopertrans.movil/kiosk_update');
  static const MethodChannel _control =
      MethodChannel('com.coopertrans.movil/kiosk_control');

  /// ¿Esta tablet es la kiosk dedicada (Device Owner)?
  static Future<bool> esDeviceOwner() async {
    try {
      return await _update.invokeMethod<bool>('esDeviceOwner') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// ¿Está ahora en modo mantenimiento (kiosk aflojado por un admin)?
  static Future<bool> estaEnMantenimiento() async {
    try {
      return await _control.invokeMethod<bool>('estaEnMantenimiento') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Suelta el lock task para que un admin pueda navegar la tablet (Ajustes,
  /// WiFi, etc.). NO desactiva el Device Owner. Se revierte con [volverAlKiosk]
  /// o reiniciando la tablet.
  static Future<void> salirAMantenimiento() async {
    await _control.invokeMethod('salirAMantenimiento');
  }

  /// Vuelve a encerrar la app en el kiosk.
  static Future<void> volverAlKiosk() async {
    await _control.invokeMethod('volverAlKiosk');
  }
}
