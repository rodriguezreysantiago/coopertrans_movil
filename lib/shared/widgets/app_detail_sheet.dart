import 'package:flutter/material.dart';

import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Helper estático para abrir BottomSheets de "detalle" uniformemente.
///
/// Reemplaza el patrón inconsistente actual donde:
/// - Personal usa BottomSheet draggable
/// - Revisiones usa AlertDialog
/// - Flota usa ExpansionTile inline
///
/// Uso típico:
/// ```
/// AppDetailSheet.show(
///   context: context,
///   title: 'Detalle del chofer',
///   builder: (ctx, scrollCtl) => ListView(
///     controller: scrollCtl,
///     children: [...],
///   ),
/// );
/// ```
///
/// El [builder] recibe el [ScrollController] que debe asignarse al
/// ListView/CustomScrollView interno para que el sheet se mueva correctamente.
class AppDetailSheet {
  AppDetailSheet._();

  /// Abre un BottomSheet draggable estándar.
  /// Devuelve el valor que el caller pase a `Navigator.pop(ctx, valor)`.
  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    required Widget Function(BuildContext, ScrollController) builder,
    double initialChildSize = 0.85,
    double minChildSize = 0.5,
    double maxChildSize = 0.95,
    List<Widget>? actions,
    IconData? icon,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: initialChildSize,
        minChildSize: minChildSize,
        maxChildSize: maxChildSize,
        expand: false,
        builder: (sheetCtx, scrollCtl) => Container(
          // `Border(top: ...)` + borderRadius dispara
          // "A borderRadius can only be given on borders with uniform colors"
          // (Sentry FLUTTER-2H, jun 2026) — los otros 3 lados implícitos son
          // BorderSide.none con color 0xFF000000, no uniforme contra primary.
          // El acento de 2px arriba va como Container hijo dentro del Column.
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(25),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              // Acento de 2px arriba (antes era `border: Border(top:)`).
              Container(
                height: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
              // Handle deslizable visual (como iOS / Material 3)
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Header con título + acciones
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(
                        icon,
                        color: Theme.of(context).colorScheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        title,
                        style: AppType.heading.copyWith(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                    ),
                    if (actions != null) ...actions,
                    IconButton(
                      icon: const Icon(Icons.close,
                          color: Colors.white54, size: 20),
                      onPressed: () => Navigator.of(sheetCtx).pop(),
                      tooltip: 'Cerrar',
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white10, height: 1),
              // Contenido scrollable proveído por el caller. Va envuelto en un
              // Material(transparency) porque el contenido casi siempre trae
              // ListTiles (fichas de empleado/vehículo): el ListTile pinta su
              // fondo e ink splash sobre el Material ancestro más cercano, y
              // sin este en el medio lo haría sobre el Container con color de
              // arriba → Flutter dispara "ListTile background color or ink
              // splashes may be invisible". `transparency` aporta el ancestro
              // sin pintar nada, así el color del sheet se ve igual.
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: builder(sheetCtx, scrollCtl),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
