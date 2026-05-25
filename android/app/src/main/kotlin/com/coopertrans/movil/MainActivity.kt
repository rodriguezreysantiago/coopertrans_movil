package com.coopertrans.movil

import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Android 15+ (API 35+) renderiza edge-to-edge por default.
        // Opt-in explícito recomendado por Google para compat con
        // versiones previas + silenciar el warning "es posible que la
        // pantalla de borde a borde no se muestre para todos los
        // usuarios" en Play Console.
        //
        // Bug 2026-05-25: probamos primero con `enableEdgeToEdge()` de
        // `androidx.activity` pero el build de Android falló con
        // "receiver type mismatch" — la extension function requiere
        // ComponentActivity y `FlutterActivity` actual no la matchea
        // limpio en el classpath. La API legacy
        // `WindowCompat.setDecorFitsSystemWindows(window, false)` hace
        // lo mismo a más bajo nivel y NO requiere downstream casting.
        //
        // Flutter ya maneja SafeArea internamente desde los Scaffolds,
        // así que este call solo asegura que el sistema sepa que la
        // app es consciente del modo edge-to-edge.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Esto asegura que todos los plugins (como Firestore) se registren
        // correctamente en el hilo principal de la aplicación.
        GeneratedPluginRegistrant.registerWith(flutterEngine)
    }
}
