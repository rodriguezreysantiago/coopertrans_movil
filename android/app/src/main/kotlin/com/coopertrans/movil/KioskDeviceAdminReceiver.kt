package com.coopertrans.movil

import android.app.admin.DeviceAdminReceiver

/**
 * Receiver de Device Admin para el modo kiosk DURO de la tablet de Gomería.
 *
 * Es el componente al que apunta el comando de provisioning (una sola vez por
 * tablet, con la tablet reseteada de fábrica y SIN cuenta de Google):
 *
 *     adb shell dpm set-device-owner com.coopertrans.movil/.KioskDeviceAdminReceiver
 *
 * Una vez que la app es Device Owner, `MainActivity` puede:
 *  - entrar en lock task mode REAL (sobrevive reinicios, el operador NO puede
 *    salir — a diferencia de "Pantalla Fija" del sistema, que se pierde al
 *    reiniciar),
 *  - setearse como Home preferido (Knox NO lo bloquea cuando lo hace el Device
 *    Owner, al revés que el intento manual de "app como Default Home" que
 *    descartamos — ver KioskHomeAlias en el manifest),
 *  - aplicar restricciones de usuario (no factory reset, no safe boot, etc.).
 *
 * NO declara lógica propia: la subclase vacía existe sólo para que el sistema
 * tenga un DeviceAdminReceiver concreto al cual asociar el rol de Device Owner.
 * Las políticas declaradas viven en res/xml/device_admin.xml.
 *
 * IMPORTANTE: esto NO afecta a los celulares de los choferes comunes. Si la app
 * no fue provisionada como Device Owner (el caso de cualquier teléfono normal),
 * `MainActivity` detecta `isDeviceOwnerApp == false` y NO toca nada.
 */
class KioskDeviceAdminReceiver : DeviceAdminReceiver()
