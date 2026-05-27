import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Diálogo modal de "cargando..." reutilizable.
///
/// Encapsula el patrón:
/// ```dart
/// unawaited(showDialog(
///   context: context,
///   barrierDismissible: false,
///   builder: (_) => const Center(
///     child: CircularProgressIndicator(color: AppColors.success),
///   ),
/// ));
/// ```
/// que estaba duplicado en `user_mis_vencimientos_screen.dart`,
/// `user_mi_perfil_screen.dart` y otros lugares.
///
/// Uso típico:
/// ```dart
/// final navigator = Navigator.of(context);
///
/// AppLoadingDialog.show(context);
/// try {
///   await algoLargo();
///   if (!mounted) return;
///   AppLoadingDialog.hide(navigator);
///   AppFeedback.success(context, 'Listo');
/// } catch (e) {
///   if (!mounted) return;
///   AppLoadingDialog.hide(navigator);
///   AppFeedback.error(context, 'Falló: $e');
/// }
/// ```
///
/// **Importante**: capturar `Navigator.of(context)` antes del await
/// y pasarlo a `hide()` evita el lint `use_build_context_synchronously`
/// y problemas si el widget se desmonta durante el await.
class AppLoadingDialog {
  AppLoadingDialog._();

  /// Abre el dialog modal. Es no-bloqueante: el `showDialog` se descarta
  /// con `unawaited` porque el Future solo se resuelve cuando lo cerramos
  /// con `hide()`. Esperarlo sería un deadlock.
  static void show(BuildContext context, {String? mensaje}) {
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        // No dejamos que el back del sistema cierre el loading — el
        // caller es el único que sabe cuándo terminó la tarea.
        canPop: false,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: AppColors.success),
                if (mensaje != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    mensaje,
                    style: AppType.body.copyWith(color: Colors.white, fontWeight: FontWeight.w500),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ));
  }

  /// Cierra el dialog si está abierto.
  ///
  /// Recibe un [navigator] (capturado antes del await) para evitar usar
  /// un `BuildContext` que pudo haber sido desmontado.
  static void hide(NavigatorState navigator) {
    if (navigator.canPop()) {
      navigator.pop();
    }
  }
}
