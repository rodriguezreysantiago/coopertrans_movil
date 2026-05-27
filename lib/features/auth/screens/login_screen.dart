import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/coopertrans_logo.dart';
import '../services/auth_service.dart';

/// Pantalla de login — REFACTOR 2026-05-27 (design-system catch-up).
///
/// A diferencia del resto de la app, NO usa AppScaffold porque necesita
/// ocupar toda la pantalla sin AppBar. Mantiene el mismo patrón visual:
/// gradient brand → fondo oscuro + card central con formulario.
///
/// **Cambios vs. la versión previa** (no la cubrió el sweep mecánico
/// porque no tenía `accentXxx` en el worklist):
/// - Todos los magic numbers (15/25/35/40/45/60) → tokens
///   ([AppSpacing], [AppRadius]).
/// - Heavy shadow del card removida (blur 25 + offset (0,15)). El
///   gradient ya separa visualmente; solo queda un borde brand 1px
///   sutil para definición.
/// - Botón "INICIAR SESIÓN" (uppercase + letterSpacing 1.5) →
///   `AppButton` con label "Ingresar" en sentence case.
/// - Tagline ilegible (10px + letterSpacing 1.5) → eliminado. El logo
///   y el contexto bastan; la review marcó que era ruido.
/// - Inputs ya no fuerzan `fontSize: 18` ad-hoc; toman el estilo del
///   [InputDecorationTheme]. Hint case "DNI (Usuario)" → "DNI".
/// - `Colors.white24/38/54` → tokens semánticos ([textDisabled],
///   [textHint], [textTertiary]).
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

    final result = await _authService.login(dni: dni, password: pass);

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
                      AppColors.surface0,
                      AppColors.surface0,
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),

            // Card central con el formulario
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                ),
                child: _LoginCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _Logo(),
                      const SizedBox(height: AppSpacing.xxxl),
                      _DniField(
                        controller: _dniController,
                        focusNode: _dniFocus,
                        autofocus: !_hasLastDni,
                        onSubmitted: () => FocusScope.of(context)
                            .requestFocus(_passFocus),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _PassField(
                        controller: _passController,
                        focusNode: _passFocus,
                        autofocus: _hasLastDni,
                        obscure: _obscurePass,
                        onToggleVisibility: () =>
                            setState(() => _obscurePass = !_obscurePass),
                        onSubmitted: _login,
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      AppButton(
                        label: 'Ingresar',
                        icon: Icons.arrow_forward,
                        size: AppButtonSize.lg,
                        expand: true,
                        isLoading: _isLoading,
                        onPressed: _login,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      // Versión leída de AppTexts.appVersion (sincronizada
                      // por bump_version.ps1 con pubspec + main.cpp en
                      // cada release). Antes era 'v2.0.26' hardcoded
                      // (de 4 versiones atrás) — quedaba stale en cada
                      // bump, confundía a los testers que pensaban
                      // estar en una versión vieja.
                      Text(
                        '${AppTexts.appVersion} · Bahía Blanca, Argentina',
                        style: AppType.label.copyWith(
                          color: AppColors.textDisabled,
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
      // En iPhone SE (375 dp) un width fijo + padding xxl da overflow.
      // Usamos maxWidth: el card topa en 420 dp en desktop/tablet, pero
      // en mobile se adapta al ancho disponible.
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(AppSpacing.xxl),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        // Antes había boxShadow blur 25 + offset (0, 15) — quedaba
        // demasiado pesado vs. el resto de la app (todo flat). El
        // gradient ya separa visualmente; un borde 1px con tint brand
        // suma definición sin gritar.
        border: Border.all(
          color: AppColors.brand.withAlpha(40),
          width: 1,
        ),
      ),
      child: child,
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    // Antes había un tagline 10px + letterSpacing 1.5 abajo del logo —
    // la review lo marcó como ilegible en la mayoría de los celus. El
    // logo + el contexto (estamos en /login) ya comunican qué app es.
    return const CoopertransLogo(
      size: CoopertransLogoSize.xl,
      centered: true,
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
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      // Sin TextStyle ad-hoc — el InputDecorationTheme global se ocupa.
      decoration: const InputDecoration(
        labelText: 'DNI',
        prefixIcon: Icon(Icons.person_outline, color: AppColors.brand),
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
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: 'Contraseña',
        prefixIcon: const Icon(Icons.lock_outline, color: AppColors.brand),
        suffixIcon: IconButton(
          icon: Icon(
            obscure ? Icons.visibility_off : Icons.visibility,
            color: AppColors.textHint,
          ),
          tooltip: obscure ? 'Mostrar contraseña' : 'Ocultar contraseña',
          onPressed: onToggleVisibility,
        ),
      ),
      onSubmitted: (_) => onSubmitted(),
    );
  }
}
