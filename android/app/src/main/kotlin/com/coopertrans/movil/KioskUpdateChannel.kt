package com.coopertrans.movil

import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * MethodChannel del auto-update SILENCIOSO de la tablet kiosk (Fase 2).
 *
 * Expone a Dart dos operaciones:
 *  - `esDeviceOwner`: ¿esta tablet es la kiosk dedicada? El servicio Dart
 *    (AndroidUpdateService) lo consulta antes de hacer NADA — en el celular de
 *    un chofer común devuelve false y el updater no toca nada.
 *  - `instalarApk(ruta)`: instala un APK ya descargado, EN SILENCIO, sin
 *    diálogo ni interacción del usuario. Esto sólo es posible porque la app es
 *    Device Owner (privilegio de instalación silenciosa via PackageInstaller).
 *    La app se reinicia sola con la versión nueva.
 *
 * Se registra desde MainActivity.configureFlutterEngine.
 */
object KioskUpdateChannel {
    private const val CHANNEL = "com.coopertrans.movil/kiosk_update"
    private const val TAG = "KioskUpdate"

    fun register(engine: FlutterEngine, context: Context) {
        val appCtx = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "esDeviceOwner" -> result.success(esDeviceOwner(appCtx))
                    "instalarApk" -> {
                        val ruta = call.argument<String>("ruta")
                        if (ruta.isNullOrEmpty()) {
                            result.error("arg", "falta la ruta del apk", null)
                        } else {
                            instalarApk(appCtx, ruta, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun esDeviceOwner(context: Context): Boolean {
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE)
            as? DevicePolicyManager ?: return false
        return dpm.isDeviceOwnerApp(context.packageName)
    }

    /**
     * Instala [rutaApk] en silencio. Requiere ser Device Owner (lo re-chequea
     * por las dudas). El APK tiene que estar firmado con la MISMA clave que la
     * app instalada — si no, Android rechaza el update (firma distinta). El
     * `release_kiosk_apk.ps1` usa el build release firmado, así que coincide.
     */
    private fun instalarApk(context: Context, rutaApk: String, result: MethodChannel.Result) {
        if (!esDeviceOwner(context)) {
            result.error("not_device_owner", "solo la tablet kiosk instala en silencio", null)
            return
        }
        val apk = File(rutaApk)
        if (!apk.exists() || apk.length() == 0L) {
            result.error("apk_missing", "no existe o está vacío: $rutaApk", null)
            return
        }
        try {
            val installer = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL,
            )
            val sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                session.openWrite("coopertrans", 0, apk.length()).use { out ->
                    FileInputStream(apk).use { input -> input.copyTo(out) }
                    session.fsync(out)
                }
                // commit() exige un IntentSender para reportar el estado. Como
                // somos Device Owner, la instalación procede sin interacción; el
                // resultado lo recibe KioskInstallResultReceiver (solo loguea).
                val intent = Intent(context, KioskInstallResultReceiver::class.java)
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val pi = PendingIntent.getBroadcast(context, sessionId, intent, flags)
                session.commit(pi.intentSender)
            }
            Log.i(TAG, "sesión de install commiteada (id=$sessionId, ${apk.length()} bytes)")
            result.success(true)
        } catch (e: Exception) {
            Log.w(TAG, "instalarApk falló: ${e.message}")
            result.error("install_failed", e.message, null)
        }
    }
}
