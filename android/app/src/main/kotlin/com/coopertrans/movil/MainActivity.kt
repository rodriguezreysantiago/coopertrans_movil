package com.coopertrans.movil

import android.os.Bundle
import androidx.activity.enableEdgeToEdge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Android 15+ (API 35+) renderiza edge-to-edge por default.
        // enableEdgeToEdge() es el opt-in explícito recomendado por
        // Google para compatibilidad con versiones previas + silenciar
        // el warning "es posible que la pantalla de borde a borde no
        // se muestre para todos los usuarios" en Play Console.
        // Flutter ya maneja SafeArea internamente desde los Scaffolds —
        // este call solo asegura que el sistema sepa que la app es
        // consciente del modo edge-to-edge.
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Esto asegura que todos los plugins (como Firestore) se registren
        // correctamente en el hilo principal de la aplicación.
        GeneratedPluginRegistrant.registerWith(flutterEngine)
    }
}
