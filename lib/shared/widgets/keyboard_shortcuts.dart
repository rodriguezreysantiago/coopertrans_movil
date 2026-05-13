import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wrapper que liga atajos de teclado típicos de desktop a las
/// acciones más frecuentes del operador. Pensado para Windows
/// (Santiago opera la app full-time desde escritorio y tipea mucho).
///
/// Uso:
/// ```dart
/// AppScaffold(
///   body: KeyboardShortcutsScope(
///     onNuevo: _abrirAlta,
///     buscarFocusNode: _buscarFocus,
///     child: ...,
///   ),
/// );
/// ```
///
/// Atajos soportados:
///   - **Ctrl+N** → invoca `onNuevo` (típicamente "nuevo viaje",
///     "nuevo adelanto", etc.). Si `onNuevo` es null, el atajo no se
///     registra.
///   - **Ctrl+F** → enfoca `buscarFocusNode` (foco al campo de
///     búsqueda). Si el FocusNode es null, no se registra.
///
/// El widget usa `CallbackShortcuts`, que escucha eventos de teclado
/// que se propagan desde los descendants. Si el operador está
/// tipeando en un TextField, Ctrl+N igual dispara — el TextField no
/// captura ese atajo y el evento burbujea.
///
/// Para Tab navigation entre campos: Flutter ya lo maneja por defecto
/// en TextFields. No hace falta wiring extra. Asegurate de que los
/// widgets focusables estén en orden lógico en el árbol.
class KeyboardShortcutsScope extends StatelessWidget {
  /// Callback para Ctrl+N. Null = no registrar el atajo.
  final VoidCallback? onNuevo;

  /// FocusNode del campo de búsqueda. Null = no registrar Ctrl+F.
  /// El widget no es dueño del FocusNode — el caller lo crea y lo
  /// dispone.
  final FocusNode? buscarFocusNode;

  /// Contenido. Casi siempre es el body completo del Scaffold.
  final Widget child;

  const KeyboardShortcutsScope({
    super.key,
    this.onNuevo,
    this.buscarFocusNode,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final bindings = <ShortcutActivator, VoidCallback>{};
    if (onNuevo != null) {
      bindings[const SingleActivator(LogicalKeyboardKey.keyN, control: true)] =
          onNuevo!;
    }
    if (buscarFocusNode != null) {
      bindings[const SingleActivator(LogicalKeyboardKey.keyF, control: true)] =
          () => buscarFocusNode!.requestFocus();
    }
    if (bindings.isEmpty) return child;
    return CallbackShortcuts(
      bindings: bindings,
      child: Focus(
        autofocus: true,
        // canRequestFocus: true (default) → recibe foco cuando se
        // monta. Sin esto, los atajos solo disparan después de que el
        // operador clickee algo dentro del scope para darle foco.
        child: child,
      ),
    );
  }
}
