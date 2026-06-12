package com.coopertrans.movil

import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Lanza la app automáticamente cuando la tablet termina de bootear.
 *
 * Pedido Santiago 2026-06-09: tablet de Gomería dedicada a Coopertrans.
 * La estrategia "app como Home" (CATEGORY_HOME en MainActivity o un alias)
 * NO funciona en Samsung One UI Android 13+: Samsung Knox restringe el
 * "Default Home" a apps firmadas por Samsung o de Galaxy Store.
 *
 * Workaround: en vez de ser Home, escuchamos ACTION_BOOT_COMPLETED y
 * lanzamos MainActivity como cualquier app normal. Combinado con
 * "Pantalla fija" (Settings → Seguridad → ON + PIN para desfijar) que el
 * admin activa una sola vez, el operador queda encerrado dentro de la app
 * y la tablet siempre arranca con Coopertrans. Sirve para CUALQUIER OEM
 * (Samsung incluido), sin ADB, sin device owner.
 *
 * Filtros que escuchamos:
 *  - BOOT_COMPLETED: boot estándar (después del unlock del usuario).
 *  - QUICKBOOT_POWERON: HTC y algunos OEMs que hacen "fast boot".
 *  - LOCKED_BOOT_COMPLETED: Android N+ Direct Boot (ANTES del unlock).
 *    Para que llegue, el receiver tiene que ser directBootAware="true"
 *    en el AndroidManifest. Útil para tablets SIN PIN de pantalla — es
 *    el primer broadcast que dispara el sistema tras el boot.
 *
 * Reintentos: en Android 10+ el startActivity desde un BroadcastReceiver
 * en background está restringido. Aunque el manifest declare
 * SYSTEM_ALERT_WINDOW (el admin lo activa manualmente en Settings), el
 * sistema puede rechazar el lanzamiento si justo arranca el receiver
 * antes de que el ActivityManager esté listo. Hacemos 3 intentos
 * escalonados (inmediato, +5s, +30s) para maximizar la chance de éxito.
 * Si los 3 fallan, no insistimos — pasa con tablets que no tienen el
 * permiso "Mostrar sobre otras apps" activado (no se puede arreglar
 * sin intervención manual del admin de todas formas).
 */
class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "BootReceiver"
        private val RETRY_DELAYS_MS = longArrayOf(0L, 5_000L, 30_000L)
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED
        ) {
            return
        }

        // GUARD kiosk: solo auto-lanzamos en la tablet dedicada (Device Owner).
        // En el celular de un chofer común la app NO es Device Owner, así que
        // tras reiniciar el teléfono NO se abre sola (antes sí lo hacía — era
        // una molestia menor aceptada; ahora que sabemos distinguir el kiosk la
        // sacamos). `isDeviceOwnerApp` es legible incluso en Direct Boot porque
        // el estado de Device Owner vive en storage device-encrypted.
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE)
            as? DevicePolicyManager
        if (dpm?.isDeviceOwnerApp(context.packageName) != true) {
            Log.i(TAG, "boot ($action) ignorado: no es la tablet kiosk (Device Owner)")
            return
        }
        Log.i(TAG, "boot detectado ($action), agendando lanzamiento con reintentos")

        // Usamos applicationContext para evitar leaks: el Context que
        // llega al receiver puede ser el ReceiverRestrictedContext que
        // tiene scope corto, y el Handler con delay 30s podría
        // out-livir al receiver.
        val appCtx = context.applicationContext
        val handler = Handler(Looper.getMainLooper())

        for ((index, delay) in RETRY_DELAYS_MS.withIndex()) {
            handler.postDelayed({
                intentarLanzar(appCtx, index + 1)
            }, delay)
        }
    }

    private fun intentarLanzar(context: Context, intento: Int) {
        try {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                // NEW_TASK obligatorio cuando startActivity se llama desde un
                // Context que NO es una Activity. CLEAR_TOP por si la app ya
                // está en background corriendo — la trae al frente sin crear
                // segunda instancia. RESET_TASK_IF_NEEDED limpia tareas
                // residuales (ej. la app quedó en una pantalla específica
                // antes del shutdown).
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                )
            }
            context.startActivity(launchIntent)
            Log.i(TAG, "intento $intento: MainActivity lanzada OK")
        } catch (e: Exception) {
            // En Android 10+ algunas restricciones de background activity
            // launch pueden bloquear esto. Logueamos sin spamear (los 3
            // intentos van a quedar en logcat).
            Log.w(TAG, "intento $intento falló: ${e.message}")
        }
    }
}
