package com.coopertrans.movil

import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.UserManager
import android.util.Log
import android.view.WindowManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity : FlutterActivity() {

    /**
     * Modo mantenimiento: cuando un admin sale del kiosk para revisar algo, se
     * pone en true y `onResume` deja de re-bloquear. Es de instancia (no
     * persiste): si la app se reinicia o la tablet rebootea, vuelve a false y el
     * kiosk se re-arma solo. Así un olvido de "Volver al kiosk" se corrige con
     * un reinicio.
     */
    @Volatile
    private var modoMantenimiento = false

    companion object {
        private const val TAG = "Kiosk"
        private const val CONTROL_CHANNEL = "com.coopertrans.movil/kiosk_control"
        // El alias HOME que arranca la app al bootear (queda disabled en el
        // manifest y SOLO lo habilitamos en runtime si somos Device Owner, así
        // los celulares de los choferes comunes NO ven a Coopertrans ofrecida
        // como launcher).
        private const val HOME_ALIAS = "com.coopertrans.movil.KioskHomeAlias"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Android 15+ (API 35+): edge-to-edge. NO se puede usar el helper
        // androidx.activity `enableEdgeToEdge()`: el compilador de Kotlin lo
        // rechaza con "receiver type mismatch" — la ComponentActivity que
        // hereda FlutterActivity es de un artefacto androidx distinto al de la
        // extension (VERIFICADO: compileDebugKotlin falla, igual que 2026-05).
        // Equivalente de bajo nivel que SÍ compila y no está deprecado:
        // setDecorFitsSystemWindows(false). El modo edge-to-edge real lo activa
        // Flutter desde Dart con SystemChrome.setEnabledSystemUIMode(edgeToEdge)
        // (ver PlatformChrome.apply); los insets los maneja SafeArea.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
        configurarDeviceOwnerSiCorresponde()
        aplicarFlagsKioskSiCorresponde()
    }

    override fun onResume() {
        super.onResume()
        // `startLockTask()` se llama acá (no en onCreate): el lock task mode
        // sólo se puede iniciar con la activity ya en foreground. Idempotente —
        // si ya estamos en lock task, no hace nada. NO re-bloqueamos si un admin
        // pidió salir a mantenimiento.
        if (!modoMantenimiento) iniciarLockTaskSiCorresponde()
        // En `onResume` también re-aplicamos los flags de ventana: cuando el
        // admin activa "Pantalla Fija" del sistema con la app ya abierta (modo
        // kiosk BLANDO, sin Device Owner), `onCreate` ya pasó y no detectamos
        // lockTaskMode todavía. Re-chequear acá garantiza que la pantalla se
        // quede encendida apenas se entra al modo kiosk.
        aplicarFlagsKioskSiCorresponde()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Esto asegura que todos los plugins (como Firestore) se registren
        // correctamente en el hilo principal de la aplicación.
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        // Canal del auto-update silencioso del kiosk (Fase 2). En cualquier
        // teléfono que no sea Device Owner, el canal responde esDeviceOwner=false
        // y el updater de Dart no hace nada.
        KioskUpdateChannel.register(flutterEngine, this)
        // Canal de control del kiosk: salida a mantenimiento de un admin
        // (necesita la Activity para start/stopLockTask, por eso vive acá y no
        // en KioskUpdateChannel que usa applicationContext).
        registrarCanalControl(flutterEngine)
    }

    private fun registrarCanalControl(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CONTROL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "estaEnMantenimiento" -> result.success(modoMantenimiento)
                    "salirAMantenimiento" -> {
                        entrarMantenimiento()
                        result.success(true)
                    }
                    "volverAlKiosk" -> {
                        salirMantenimiento()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun adminComponent() = ComponentName(this, KioskDeviceAdminReceiver::class.java)

    /**
     * Salida a mantenimiento (la dispara un admin desde el panel, con
     * contraseña). Suelta el lock task y re-habilita la barra de estado para que
     * el admin pueda navegar a Ajustes, WiFi, etc. NO desactiva el Device Owner
     * (eso es irreversible sin factory reset) — sólo afloja el encierro hasta
     * que el admin vuelve al kiosk o reinicia la tablet.
     */
    private fun entrarMantenimiento() {
        if (!esDeviceOwner()) return
        modoMantenimiento = true
        try {
            dpm()?.setStatusBarDisabled(adminComponent(), false)
        } catch (e: Exception) {
            Log.w(TAG, "re-habilitar barra de estado falló: ${e.message}")
        }
        try {
            stopLockTask()
            Log.i(TAG, "modo mantenimiento ON — lock task soltado")
        } catch (e: Exception) {
            Log.w(TAG, "stopLockTask falló: ${e.message}")
        }
    }

    /** Vuelve al kiosk: re-bloquea y vuelve a ocultar la barra de estado. */
    private fun salirMantenimiento() {
        modoMantenimiento = false
        try {
            dpm()?.setStatusBarDisabled(adminComponent(), true)
        } catch (e: Exception) {
            Log.w(TAG, "ocultar barra de estado falló: ${e.message}")
        }
        iniciarLockTaskSiCorresponde()
        Log.i(TAG, "modo mantenimiento OFF — kiosk re-armado")
    }

    // ─────────────────────────────────────────────────────────────────────
    // KIOSK DURO (Device Owner)
    // ─────────────────────────────────────────────────────────────────────

    private fun dpm(): DevicePolicyManager? =
        getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager

    private fun esDeviceOwner(): Boolean =
        dpm()?.isDeviceOwnerApp(packageName) == true

    /**
     * Configura el kiosk DURO cuando la app fue provisionada como Device Owner
     * (`adb shell dpm set-device-owner com.coopertrans.movil/.KioskDeviceAdminReceiver`,
     * una vez por tablet con la tablet reseteada de fábrica y sin cuenta de
     * Google). En cualquier teléfono normal (no Device Owner) este método
     * retorna de entrada y NO toca nada.
     *
     * Hace, todo idempotente (se puede llamar en cada onCreate sin efectos
     * acumulativos):
     *  1. setLockTaskPackages: whitelist de paquetes permitidos en lock task =
     *     sólo nosotros. Sin esto, startLockTask() mostraría el diálogo de
     *     confirmación y el usuario podría salir.
     *  2. Habilita el KioskHomeAlias (CATEGORY_HOME) y lo fija como Home
     *     preferido persistente. Así, al reiniciar la tablet, el sistema lanza
     *     directo nuestra app — sin pasar por ningún launcher. A diferencia del
     *     intento manual de "Default Home" (que Knox bloquea en Samsung), el
     *     Device Owner tiene privilegio para fijarlo programáticamente.
     *  3. Restricciones de usuario: no factory reset, no safe boot, no agregar
     *     usuarios. NO bloqueamos debugging (DISALLOW_DEBUGGING_FEATURES) a
     *     propósito: queremos seguir pudiendo actualizar por `adb install -r`.
     *  4. Apaga la barra de estado y el keyguard (sin lockscreen): la tablet
     *     arranca directo en la app, terminal dedicado.
     */
    private fun configurarDeviceOwnerSiCorresponde() {
        val dpm = dpm() ?: return
        if (!dpm.isDeviceOwnerApp(packageName)) return
        val admin = ComponentName(this, KioskDeviceAdminReceiver::class.java)
        Log.i(TAG, "Device Owner detectado — configurando kiosk duro")

        // 1. Whitelist de lock task: sólo nuestra app.
        try {
            dpm.setLockTaskPackages(admin, arrayOf(packageName))
        } catch (e: Exception) {
            Log.w(TAG, "setLockTaskPackages falló: ${e.message}")
        }

        // 2. Home preferido persistente (sobrevive reinicios).
        try {
            packageManager.setComponentEnabledSetting(
                ComponentName(this, HOME_ALIAS),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP,
            )
            val filtroHome = IntentFilter(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                addCategory(Intent.CATEGORY_DEFAULT)
            }
            dpm.addPersistentPreferredActivity(
                admin,
                filtroHome,
                ComponentName(packageName, HOME_ALIAS),
            )
        } catch (e: Exception) {
            Log.w(TAG, "fijar Home preferido falló: ${e.message}")
        }

        // 3. Restricciones de usuario (anti-escape). NO incluimos
        //    DISALLOW_DEBUGGING_FEATURES: dejamos ADB disponible para poder
        //    actualizar la app con `adb install -r` mientras la tablet está
        //    bloqueada.
        for (restriccion in listOf(
            UserManager.DISALLOW_FACTORY_RESET,
            UserManager.DISALLOW_SAFE_BOOT,
            UserManager.DISALLOW_ADD_USER,
        )) {
            try {
                dpm.addUserRestriction(admin, restriccion)
            } catch (e: Exception) {
                Log.w(TAG, "addUserRestriction($restriccion) falló: ${e.message}")
            }
        }

        // 4. Sin barra de estado ni keyguard: terminal dedicado.
        try {
            dpm.setStatusBarDisabled(admin, true)
        } catch (e: Exception) {
            Log.w(TAG, "setStatusBarDisabled falló: ${e.message}")
        }
        try {
            dpm.setKeyguardDisabled(admin, true)
        } catch (e: Exception) {
            Log.w(TAG, "setKeyguardDisabled falló: ${e.message}")
        }
    }

    /**
     * Entra en lock task mode si somos Device Owner y no estamos ya adentro.
     * Como el paquete está en la whitelist (setLockTaskPackages), esto NO
     * muestra el diálogo de confirmación y el operador NO puede salir.
     */
    private fun iniciarLockTaskSiCorresponde() {
        if (!esDeviceOwner()) return
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return
        if (am.lockTaskModeState == ActivityManager.LOCK_TASK_MODE_NONE) {
            try {
                startLockTask()
                Log.i(TAG, "lock task iniciado")
            } catch (e: Exception) {
                Log.w(TAG, "startLockTask falló: ${e.message}")
            }
        }
    }

    /**
     * Si la tablet está en lock task mode —ya sea kiosk DURO (Device Owner) o
     * BLANDO ("Pantalla Fija" del sistema)— activamos los flags de ventana para
     * que se comporte como terminal dedicado:
     *
     *  - FLAG_KEEP_SCREEN_ON: la pantalla nunca se apaga mientras la activity
     *    esté en foreground.
     *  - FLAG_TURN_SCREEN_ON: al arrancar la activity (ej. después del boot),
     *    enciende la pantalla si estaba apagada.
     *  - FLAG_SHOW_WHEN_LOCKED: muestra la activity sobre el lockscreen si por
     *    error quedara alguno.
     *  - FLAG_DISMISS_KEYGUARD: descarta el keyguard no seguro (sin PIN).
     *
     * IMPORTANTE: solo si está en lockTaskMode. En modo normal (chofer común),
     * NO los activamos para no drenar batería ni interferir con su lockscreen.
     */
    private fun aplicarFlagsKioskSiCorresponde() {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return
        val enKiosk = am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
        if (!enKiosk) return
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
        )
    }
}
