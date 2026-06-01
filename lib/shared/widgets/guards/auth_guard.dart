import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';

/// Guard que protege rutas autenticadas.
///
/// **Diseño basado en Firebase Auth como única fuente de verdad.**
///
/// En Windows desktop, Firebase Auth emite primero `null` por
/// `authStateChanges()` y unos cientos de ms después emite el user
/// realmente persistido en disco. Si el guard reacciona al primer
/// `null` (redirige a login, limpia prefs, etc), pierde el user
/// real que llega después → boucle de logout aunque la sesión esté
/// vigente.
///
/// Solución: damos un **grace period** de 1.5s. Mientras estamos en
/// ese período Y user es null, mostramos splash. Si Firebase emite
/// un user antes del timeout, mostramos [child]. Si pasa el timeout
/// y sigue null, redirigimos a login.
///
/// Después del grace period, el [StreamBuilder] sigue activo y
/// reacciona en vivo a futuros cambios (ej.: el usuario hace logout
/// desde un menú y la app vuelve al login automáticamente).
///
/// Las prefs locales (`PrefsService`) se mantienen como cache de UX
/// (nombre, rol, dni para mostrar) pero NO se usan para auth gating.
/// La fuente de verdad es Firebase Auth.
class AuthGuard extends StatefulWidget {
  final Widget child;

  const AuthGuard({
    super.key,
    required this.child,
  });

  @override
  State<AuthGuard> createState() => _AuthGuardState();
}

class _AuthGuardState extends State<AuthGuard> with WidgetsBindingObserver {
  bool _gracePeriodOver = false;
  Timer? _graceTimer;
  Timer? _revisionTimer;

  /// Códigos de FirebaseAuth que significan "esta sesión ya no vale":
  /// el admin revocó los tokens (cambio de rol / baja) o deshabilitó la
  /// cuenta. SOLO ante estos cerramos sesión. Cualquier otro error
  /// (red, timeout, función fría) NO toca la sesión — así evitamos sacar
  /// a un usuario legítimo por un problema transitorio.
  static const _codigosSesionRevocada = {
    'user-token-expired',
    'user-disabled',
    'user-not-found',
    'user-token-revoked',
    'invalid-user-token',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _graceTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _gracePeriodOver = true);
    });
    // Primer chequeo de sesión revocada tras un margen (que Firebase
    // termine de cargar la sesión persistida), y después cada 30 min
    // mientras la app esté abierta. Esto desbloquea el caso "le cambiaron
    // el rol / lo dieron de baja": revokeRefreshTokens server-side hace
    // que este getIdToken(true) falle → cerramos sesión → re-login con el
    // rol nuevo (antes el usuario quedaba en limbo: veía el menú viejo
    // pero el server le rechazaba todo).
    Future.delayed(const Duration(seconds: 3), _verificarSesionRevocada);
    _revisionTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => _verificarSesionRevocada(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al volver a primer plano, revalidamos: si mientras estuvo en
    // background le revocaron la sesión, lo detectamos acá.
    if (state == AppLifecycleState.resumed) {
      _verificarSesionRevocada();
    }
  }

  Future<void> _verificarSesionRevocada() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await user.getIdToken(true).timeout(const Duration(seconds: 12));
    } on FirebaseAuthException catch (e) {
      if (_codigosSesionRevocada.contains(e.code)) {
        await FirebaseAuth.instance.signOut();
        // El StreamBuilder de build() reacciona al null y redirige a login.
      }
    } catch (_) {
      // Red / timeout / error transitorio → NO tocar la sesión.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _graceTimer?.cancel();
    _revisionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      initialData: FirebaseAuth.instance.currentUser,
      builder: (context, snapshot) {
        final user = snapshot.data;

        // Caso 1: hay user — autenticado, mostrar contenido.
        if (user != null) {
          return widget.child;
        }

        // Caso 2: no hay user pero estamos en grace period —
        // esperamos a que Firebase Auth termine de cargar la sesión
        // persistida (~500-1500ms en Windows desktop al startup).
        if (!_gracePeriodOver) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // Caso 3: pasó el grace period y sigue sin user → redirigir
        // a login.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          Navigator.of(context).pushNamedAndRemoveUntil(
            AppRoutes.login,
            (route) => false,
          );
        });
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}
