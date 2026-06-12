package com.coopertrans.movil

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.util.Log

/**
 * Recibe el resultado de la instalación silenciosa del auto-update kiosk
 * (PackageInstaller.commit usa este receiver como IntentSender). Solo loguea:
 * no toma ninguna acción de UI, porque en Device Owner la instalación es
 * silenciosa y la app se reinicia sola en caso de éxito.
 */
class KioskInstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        when (status) {
            PackageInstaller.STATUS_SUCCESS ->
                Log.i("KioskUpdate", "instalación OK (la app se reinicia con la versión nueva)")
            PackageInstaller.STATUS_PENDING_USER_ACTION ->
                // No debería pasar siendo Device Owner (instalación silenciosa).
                // Si pasara, NO forzamos el diálogo: rompería el lock task del
                // kiosk. Solo lo dejamos registrado.
                Log.w("KioskUpdate", "instalación pide acción de usuario (inesperado en Device Owner)")
            else ->
                Log.w("KioskUpdate", "instalación falló: status=$status msg=$msg")
        }
    }
}
