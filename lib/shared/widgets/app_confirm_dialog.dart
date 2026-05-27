import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// Diálogo de confirmación reutilizable.
///
/// Pensado para acciones que el usuario puede arrepentirse: desvincular
/// un equipo del chofer, rechazar una revisión, borrar un registro,
/// cambiar una fecha sensible, etc.
///
/// Devuelve `true` si confirmó, `false` o `null` si canceló (o cerró
/// con backdrop / back button). El caller debe checkear `== true` para
/// proceder, así null y false se tratan idénticos.
///
/// El parámetro `destructive: true` pinta el botón de confirmación en
/// rojo (acción irreversible). En modo no destructivo el botón es verde
/// (acción positiva, ej: "GUARDAR", "ENVIAR").
///
/// Uso:
/// ```dart
/// final ok = await AppConfirmDialog.show(
///   context,
///   title: '¿Desvincular tractor?',
///   message: 'El chofer quedará sin tractor asignado y la unidad volverá a LIBRE.',
///   confirmLabel: 'DESVINCULAR',
///   destructive: true,
/// );
/// if (ok == true) {
///   // ejecutar la acción
/// }
/// ```
class AppConfirmDialog {
  AppConfirmDialog._();

  /// Muestra el dialog y resuelve cuando el usuario confirma o cancela.
  ///
  /// - [title]: encabezado en bold blanco.
  /// - [message]: cuerpo principal. Si necesitás más control, pasá [content]
  ///   con un widget propio (ej. una columna con campos extra).
  /// - [content]: alternativa a [message] cuando hace falta layout custom.
  ///   Si pasás los dos, gana [content].
  /// - [confirmLabel]: texto del botón de confirmar (default `'CONFIRMAR'`).
  /// - [cancelLabel]: texto del botón de cancelar (default `'CANCELAR'`).
  /// - [destructive]: si es `true`, el botón de confirmar va en rojo.
  /// - [icon]: ícono opcional al lado del título (suele combinar con
  ///   `destructive: true` y `Icons.warning_amber_rounded`).
  static Future<bool?> show(
    BuildContext context, {
    required String title,
    String? message,
    Widget? content,
    String confirmLabel = 'CONFIRMAR',
    String cancelLabel = 'CANCELAR',
    bool destructive = false,
    IconData? icon,
  }) {
    assert(
      message != null || content != null,
      'AppConfirmDialog necesita al menos `message` o `content`.',
    );

    return showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(dCtx).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withAlpha(20)),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                color: destructive ? AppColors.error : AppColors.success,
                size: 22,
              ),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: content ??
            Text(
              message!,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                height: 1.4,
              ),
            ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: Text(
              cancelLabel,
              style: const TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  destructive ? AppColors.error : Colors.green,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dCtx, true),
            icon: Icon(
              destructive ? Icons.delete_outline : Icons.check,
              size: 18,
            ),
            label: Text(
              confirmLabel,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
