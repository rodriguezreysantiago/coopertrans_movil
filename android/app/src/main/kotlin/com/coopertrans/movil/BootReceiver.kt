package com.coopertrans.movil

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
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
 *  - BOOT_COMPLETED: boot estándar.
 *  - QUICKBOOT_POWERON: HTC y algunos OEMs que hacen "fast boot".
 *  - LOCKED_BOOT_COMPLETED: Android N+ Direct Boot (antes de unlock).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED
        ) {
            return
        }
        Log.i("BootReceiver", "boot detectado ($action), lanzando MainActivity")
        try {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            context.startActivity(launchIntent)
        } catch (e: Exception) {
            // En Android 10+ algunas restricciones de background activity launch
            // pueden bloquear esto; el log queda para debug. No tiramos para
            // no spamear logs si pasa.
            Log.w("BootReceiver", "no pude lanzar MainActivity: ${e.message}")
        }
    }
}
