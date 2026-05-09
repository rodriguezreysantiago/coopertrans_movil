import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/coopertrans_logo.dart';
import '../services/auth_service.dart';

/// Pantalla de login.
///
/// A diferencia del resto de la app, NO usa AppScaffold porque necesita
/// ocupar toda la pantalla sin AppBar. Mantiene el mismo patrón visual:
/// imagen de fondo + overlay oscuro + card central con formulario.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _dniController = TextEditingController();
  final TextEditingController _passController = TextEditingController();

  final FocusNode _dniFocus = FocusNode();
  final FocusNode _passFocus = FocusNode();

  final AuthService _authService = AuthService();

  bool _isLoading = false;
  bool _obscurePass = true;

  /// True si hay un DNI recordado de logins previos. Si es así, el
  /// `_PassField` se autofocusea (el admin solo escribe la pass). Si
  /// no hay DNI guardado, el `_DniField` autofocusea para arrancar de cero.
  late final bool _hasLastDni;

  @override
  void initState() {
    super.initState();
    final lastDni = PrefsService.lastDni;
    _hasLastDni = lastDni.isNotEmpty;
    if (_hasLastDni) {
      _dniController.text = lastDni;
    }
    // Nota: usamos `autofocus: true` en el TextField (ver build) en
    // lugar de `FocusNode.requestFocus()` desde initState, porque
    // en Windows desktop hay un race entre el postFrameCallback y el
    // layout del EditableText que dispara una assertion. La forma
    // idiomática (autofocus) usa el ciclo natural de Flutter y no
    // tiene ese problema.
  }

  @override
  void dispose() {
    _dniController.dispose();
    _passController.dispose();
    _dniFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_isLoading) return;

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final dni = _dniController.text.replaceAll(RegExp(r'[^0-9]'), '');
    final pass = _passController.text.trim();

    if (dni.isEmpty || pass.isEmpty) {
      AppFeedback.errorOn(messenger, 'Completá todos los campos para ingresar');
      return;
    }

    setState(() => _isLoading = true);

    final result =
        await _authService.login(dni: dni, password: pass);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result.success) {
      // El Future de pushReplacementNamed se completa recién cuando la
      // pantalla /home haga pop (o sea, nunca para nuestro caso). No
      // queremos esperarlo: lo descartamos explícito con unawaited().
      unawaited(
        navigator.pushReplacementNamed(
          '/home',
          arguments: {
            'dni': result.dni,
            'nombre': result.nombre,
            'rol': result.rol,
          },
        ),
      );
    } else {
      AppFeedback.errorOn(
        messenger,
        result.message ?? 'No se pudo iniciar sesión',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: Stack(
          children: [
            // Gradient brand → fondo oscuro. Reemplaza la foto histórica
            // por algo más limpio y consistente con el splash.
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.brandDark,
                      AppColors.background,
                      AppColors.background,
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),

            // Card central con el formulario
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 25),
                child: _LoginCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _LogoYTitulo(),
                      const SizedBox(height: 45),
                      _DniField(
                        controller: _dniController,
                        focusNode: _dniFocus,
                        autofocus: !_hasLastDni,
                        onSubmitted: () => FocusScope.of(context)
                            .requestFocus(_passFocus),
                      ),
                      const SizedBox(height: 25),
                      _PassField(
                        controller: _passController,
                        focusNode: _passFocus,
                        autofocus: _hasLastDni,
                        obscure: _obscurePass,
                        onToggleVisibility: () =>
                            setState(() => _obscurePass = !_obscurePass),
                        onSubmitted: _login,
                      ),
                      const SizedBox(height: 40),
                      _BotonIngresar(
                        isLoading: _isLoading,
                        onPressed: _login,
                      ),
                      const SizedBox(height: 25),
                      const Text(
                        'v2.0.26 — Bahía Blanca, Argentina',
                        style: TextStyle(
                          color: Colors.white24,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// COMPONENTES INTERNOS
// =============================================================================

class _LoginCard extends StatelessWidget {
  final Widget child;
  const _LoginCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      // En iPhone SE (375 dp) un width fijo de 420 dp + padding 35 daba
      // overflow horizontal garantizado. Cambiamos a maxWidth: el card
      // sigue topando en 420 dp en desktop/tablet, pero en mobile se
      // adapta al ancho disponible.
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(35),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: AppColors.brand.withAlpha(40)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(150),
            blurRadius: 25,
            offset: const Offset(0, 15),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _LogoYTitulo extends StatelessWidget {
  const _LogoYTitulo();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        CoopertransLogo(
          size: CoopertransLogoSize.xl,
          centered: true,
        ),
        SizedBox(height: 8),
        Text(
          AppTexts.tagline,
          style: TextStyle(
            color: Colors.white54,
            fontWeight: FontWeight.bold,
            fontSize: 10,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}

class _DniField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool autofocus;
  final VoidCallback onSubmitted;

  const _DniField({
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: const TextStyle(
        fontSize: 18,
        color: Colors.white,
        fontWeight: FontWeight.bold,
      ),
      decoration: InputDecoration(
        labelText: 'DNI (Usuario)',
        prefixIcon: Icon(Icons.person_outline, color: primary),
      ),
      onSubmitted: (_) => onSubmitted(),
    );
  }
}

class _PassField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool autofocus;
  final bool obscure;
  final VoidCallback onToggleVisibility;
  final VoidCallback onSubmitted;

  const _PassField({
    required this.controller,
    required this.focusNode,
    required this.obscure,
    required this.onToggleVisibility,
    required this.onSubmitted,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      obscureText: obscure,
      style: const TextStyle(fontSize: 18, color: Colors.white),
      decoration: InputDecoration(
        labelText: 'Contraseña',
        prefixIcon: Icon(Icons.lock_outline, color: primary),
        suffixIcon: IconButton(
          icon: Icon(
            obscure ? Icons.visibility_off : Icons.visibility,
            color: Colors.white38,
          ),
          onPressed: onToggleVisibility,
        ),
      ),
      onSubmitted: (_) => onSubmitted(),
    );
  }
}

class _BotonIngresar extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onPressed;

  const _BotonIngresar({
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const CircularProgressIndicator(color: AppColors.brand);
    }
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(double.infinity, 60),
        backgroundColor: AppColors.brand,
        foregroundColor: Colors.white,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
        ),
      ),
      onPressed: onPressed,
      child: const Text(
        'INICIAR SESIÓN',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}
