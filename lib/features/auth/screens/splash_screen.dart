import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/coopertrans_logo.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
/// Splash inicial al abrir la app.
///
/// Es 100% cosmético: muestra el logo grande sobre un gradient oscuro
/// durante un tiempo corto, después salta a [AppRoutes.home] donde el
/// AuthGuard decide si va al MainPanel o a Login.
///
/// No bloquea la inicialización de la app — esa ya se hizo en `main()`
/// antes de runApp(). Acá solo damos un beat visual de marca antes del
/// primer frame "real".
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  /// Tiempo MINIMO que se muestra el splash para que el branding
  /// quede visible aunque la sesion ya este caliente (caso reapertura).
  static const _duracionMinima = Duration(milliseconds: 1500);

  /// Tiempo MAXIMO antes de salir aunque Firebase Auth no haya
  /// terminado de restaurar (caso cold start con red lenta — antes
  /// el splash salia a los 1.5s, AuthGuard arrancaba con user=null y
  /// si justo el authStateChanges tardaba >1.5s mandaba a login y el
  /// usuario veia el ciclo "splash → home → login → home".
  static const _duracionMaxima = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    // Esperamos en paralelo:
    //  a) que pase la duracion minima (efecto visual de marca)
    //  b) que Firebase Auth resuelva el primer authStateChanges (user
    //     o null definitivo). Con timeout duro de _duracionMaxima por
    //     si la red se cuelga.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _esperarYSalir();
    });
  }

  Future<void> _esperarYSalir() async {
    final futureMin = Future.delayed(_duracionMinima);
    final futureAuth = FirebaseAuth.instance
        .authStateChanges()
        .first
        .timeout(_duracionMaxima, onTimeout: () => null);
    // Esperamos a ambos (el mas lento determina cuando salimos), pero
    // capeamos a _duracionMaxima por las dudas.
    await Future.wait([futureMin, futureAuth])
        .timeout(_duracionMaxima, onTimeout: () => const []);
    _salir();
  }

  void _salir() {
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(AppRoutes.home);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.brandDark,
              AppColors.background,
            ],
          ),
        ),
        child: const Stack(
          children: [
            Center(
              child: CoopertransLogo(
                size: CoopertransLogoSize.xl,
                centered: true,
              ),
            ),
            Positioned(
              bottom: 60,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(AppColors.brand),
                    ),
                  ),
                  SizedBox(height: AppSpacing.lg),
                  Text(
                    AppTexts.tagline,
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
