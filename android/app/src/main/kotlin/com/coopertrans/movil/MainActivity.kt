package com.coopertrans.movil

import android.os.Bundle
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
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Esto asegura que todos los plugins (como Firestore) se registren
        // correctamente en el hilo principal de la aplicación.
        GeneratedPluginRegistrant.registerWith(flutterEngine)
    }
}
