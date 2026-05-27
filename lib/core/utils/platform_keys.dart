import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/widgets.dart' show TargetPlatform;

/// Helpers para mostrar atajos de teclado en cada plataforma —
/// REFACTOR 2026-05-27 (multiplatform addon).
///
/// **Problema:** la app corre en iOS, Android, Chrome (web), macOS y
/// Windows. Mostrar "Ctrl+K" en macOS es incorrecto (allá es ⌘K).
/// Y en mobile ni siquiera hay teclado, así que el hint a veces sobra.
///
/// **Reglas:**
/// - macOS y iOS → ⌘ (Cmd)
/// - Windows, Linux, Android, web no-Apple → Ctrl
/// - Mobile (iOS/Android) → idealmente NO mostrar el hint, salvo que
///   esté conectado un teclado externo. Para eso usar [isMobile].
class PlatformKeys {
  PlatformKeys._();

  /// `true` en plataformas táctiles primarias (iOS, Android).
  /// Si querés ocultar tips de teclado en mobile, gateá con esto.
  static bool get isMobile {
    if (kIsWeb) return false;
    return Platform.isIOS || Platform.isAndroid;
  }

  /// `true` en plataformas donde el modificador es ⌘ (Cmd).
  static bool get usesCmd {
    if (kIsWeb) {
      // En web no tenemos Platform.is*, pero defaultTargetPlatform
      // refleja el SO huésped del browser.
      return defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.iOS;
    }
    return Platform.isMacOS || Platform.isIOS;
  }

  /// El nombre humano del modificador (`⌘` o `Ctrl`).
  static String get modifier => usesCmd ? '⌘' : 'Ctrl';

  /// Render canónico de un atajo con un símbolo modificador + tecla.
  ///
  /// ```dart
  /// PlatformKeys.shortcut('K')       // → "⌘K" o "Ctrl+K"
  /// PlatformKeys.shortcut('K', sep: ' + ')  // → "⌘ + K" o "Ctrl + K"
  /// ```
  static String shortcut(String key, {String? sep}) {
    if (usesCmd) {
      return '$modifier${sep ?? ''}$key';
    }
    return '$modifier${sep ?? '+'}$key';
  }

  /// Hint humano para la command palette. Devuelve null en mobile
  /// salvo que [forceShow] sea true (útil si detectaste teclado externo).
  static String? commandPaletteHint({bool forceShow = false}) {
    if (isMobile && !forceShow) return null;
    return 'Buscá cualquier módulo con ${shortcut("K")}';
  }
}
