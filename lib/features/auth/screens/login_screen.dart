import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/auth_service.dart';

/// Pantalla de login — REFACTOR NÚCLEO (jun 2026).
///
/// Full-screen (sin card central): ambient glow de fondo, logo arriba,
/// eyebrow "Acceso" + saludo hero, dos AppInput y el CTA "Ingresar" con la
/// flecha. Footer hairline con versión + estado. La LÓGICA de autenticación
/// (controllers, focos, `_login`, DNI recordado) es idéntica a la previa —
/// solo cambió la piel.
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

  /// True si hay un DNI recordado de logins previos: el campo de contraseña
  /// autofocusea (el admin solo escribe la pass). Si no, autofocusea el DNI.
  late final bool _hasLastDni;

  @override
  void initState() {
    super.initState();
    final lastDni = PrefsService.lastDni;
    _hasLastDni = lastDni.isNotEmpty;
    if (_hasLastDni) {
      _dniController.text = lastDni;
    }
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

  String get _saludo {
    final h = DateTime.now().hour;
    if (h < 12) return 'Buenos\ndías.';
    if (h < 20) return 'Buenas\ntardes.';
    return 'Buenas\nnoches.';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: Stack(
          children: [
            const AppAmbient(),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(minHeight: constraints.maxHeight),
                      child: IntrinsicHeight(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 460),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // ── Logo ──
                                const Padding(
                                  padding: EdgeInsets.fromLTRB(28, 32, 28, 0),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: CoopertransLogo(
                                      size: CoopertransLogoSize.m,
                                    ),
                                  ),
                                ),

                                // ── Eyebrow + saludo hero ──
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(28, 44, 28, 28),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      AppEyebrow('Acceso',
                                          color: c.textSecondary),
                                      const SizedBox(height: 10),
                                      Text(
                                        _saludo,
                                        style: AppType.h1.copyWith(height: 0.95),
                                      ),
                                    ],
                                  ),
                                ),

                                // ── Formulario ──
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 28),
                                  child: Column(
                                    children: [
                                      AppInput(
                                        label: 'DNI',
                                        controller: _dniController,
                                        focusNode: _dniFocus,
                                        autofocus: !_hasLastDni,
                                        mono: true,
                                        keyboardType: TextInputType.number,
                                        inputFormatters: [
                                          FilteringTextInputFormatter.digitsOnly
                                        ],
                                        textInputAction: TextInputAction.next,
                                        onSubmitted: (_) => FocusScope.of(context)
                                            .requestFocus(_passFocus),
                                      ),
                                      const SizedBox(height: 10),
                                      AppInput(
                                        label: 'Contraseña',
                                        controller: _passController,
                                        focusNode: _passFocus,
                                        autofocus: _hasLastDni,
                                        obscure: true,
                                        mono: true,
                                        trailingAction: 'ver',
                                        textInputAction: TextInputAction.done,
                                        onSubmitted: (_) => _login(),
                                      ),
                                      const SizedBox(height: 18),
                                      AppButton.primary(
                                        label: 'Ingresar',
                                        iconAfter: Icons.arrow_forward,
                                        size: AppButtonSize.lg,
                                        full: true,
                                        loading: _isLoading,
                                        onPressed: _login,
                                      ),
                                    ],
                                  ),
                                ),

                                const Spacer(),

                                // ── Footer ──
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(28, 24, 28, 24),
                                  child: Column(
                                    children: [
                                      const AppHairline(),
                                      const SizedBox(height: 14),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const AppEyebrow(AppTexts.appVersion),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              AppDot(c.success, size: 5),
                                              const SizedBox(width: 6),
                                              const AppEyebrow('sistemas ok'),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
