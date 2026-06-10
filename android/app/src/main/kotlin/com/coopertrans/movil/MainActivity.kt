package com.coopertrans.movil

import android.app.ActivityManager
import android.content.Context
import android.os.Bundle
import android.view.WindowManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity : FlutterActivity() {
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
        aplicarFlagsKioskSiCorresponde()
    }

    override fun onResume() {
        super.onResume()
        // En `onResume` también: cuando el usuario activa Pantalla Fija
        // por primera vez (la app ya estaba abierta), `onCreate` ya pasó
        // y no detectamos lockTaskMode todavía. Re-chequear acá garantiza
        // que la pantalla se quede encendida apenas se entra al modo kiosk.
        aplicarFlagsKioskSiCorresponde()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Esto asegura que todos los plugins (como Firestore) se registren
        // correctamente en el hilo principal de la aplicación.
        GeneratedPluginRegistrant.registerWith(flutterEngine)
    }

    /**
     * Si la tablet está en modo Pantalla Fija (lockTaskMode), activamos
     * los flags de ventana para que la tablet kiosk de Gomería se
     * comporte como un terminal dedicado:
     *
     *  - FLAG_KEEP_SCREEN_ON: la pantalla nunca se apaga mientras la
     *    activity esté en foreground. Sin esto, la tablet entra en
     *    standby al timeout del sistema (default 30s en Samsung) y el
     *    operador tiene que tocarla para despertarla. En modo kiosk
     *    queremos que esté siempre visible.
     *
     *  - FLAG_TURN_SCREEN_ON: al arrancar la activity (ej. después del
     *    boot), enciende la pantalla si estaba apagada.
     *
     *  - FLAG_SHOW_WHEN_LOCKED: muestra la activity sobre el lockscreen.
     *    En la tablet kiosk no debería haber lockscreen (Settings → Lock
     *    screen → Deslizar) pero si por error queda algo, esto la deja
     *    visible igual.
     *
     *  - FLAG_DISMISS_KEYGUARD: descarta el keyguard al mostrarse. Solo
     *    funciona si el keyguard no es seguro (sin PIN/patrón); con PIN,
     *    queda atrás.
     *
     * IMPORTANTE: solo activamos estos flags si la tablet está en
     * lockTaskMode (Pantalla Fija). En modo normal (uso del chofer
     * común), NO los activamos para no drenar batería ni interferir
     * con el lockscreen del usuario.
     */
    private fun aplicarFlagsKioskSiCorresponde() {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return
        val enKiosk = am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
        if (!enKiosk) return
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
        )
    }
}
