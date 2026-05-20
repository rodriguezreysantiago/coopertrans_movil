/// Formato de números de teléfono argentinos.
///
/// **Convención del proyecto**:
/// - **En Firestore guardamos siempre el formato completo**: `549<área><nro>`.
///   Ejemplo: `5492914567890`. Esto es lo que necesita el bot Node.js
///   para WhatsApp Web (`<numero>@c.us`).
/// - **En la UI mostramos el formato local**: `<área> <nro>` (sin 549).
///   Ejemplo: `2914567890`. Más legible para el admin que reconoce los
///   números argentinos por su código de área.
/// - **Al cargar/editar**: aceptamos cualquier formato razonable. Si el
///   admin escribe sin código país (ej. `2914567890`), lo agregamos
///   automáticamente al guardar.
///
/// Estos helpers centralizan la conversión en un solo lugar para que
/// no haya inconsistencias entre pantallas.
class PhoneFormatter {
  PhoneFormatter._();

  /// Toma cualquier formato razonable (con/sin 549, con/sin 0, con/sin 15,
  /// con espacios, guiones, paréntesis, +) y devuelve el formato canónico
  /// que vamos a persistir en Firestore: solo dígitos, prefijo `549`.
  ///
  /// Ejemplos:
  /// - `"2914567890"`           → `"5492914567890"`  (le agregamos 54+9)
  /// - `"5492914567890"`        → `"5492914567890"`  (ya está bien)
  /// - `"+54 9 291 456-7890"`   → `"5492914567890"`  (limpiamos formato)
  /// - `"02914567890"`          → `"5492914567890"`  (saca el 0 inicial)
  /// - `"0291 15-4567890"`      → `"5492914567890"`  (saca el 15 móvil)
  /// - `""` o `"-"` o `"abc"`   → `""`  (entrada inválida)
  ///
  /// Devuelve string vacío si el dato no parece un teléfono argentino
  /// válido (ej. menos de 10 dígitos útiles después de limpiar).
  static String paraGuardar(String? raw) {
    final input = (raw ?? '').trim();
    if (input.isEmpty || input == '-') return '';

    // 1) Solo dígitos.
    String digitos = input.replaceAll(RegExp(r'[^\d]'), '');
    if (digitos.isEmpty) return '';

    // 2) Quitar el "0" inicial de área (formato local AR: 0291...).
    if (digitos.startsWith('0')) {
      digitos = digitos.substring(1);
    }

    // 3) Quitar el "15" del formato viejo "0291-15-4567890". El "15" lo
    //    agregaba la línea fija para distinguir móviles, hoy ya no se usa
    //    para WhatsApp. Tras sacar el 0, ese formato queda en 12 dígitos
    //    (área+abonado = 10 SIEMPRE en AR, + los 2 del "15").
    //    CRÍTICO: un número NORMAL de 10 dígitos que CASUALMENTE contenga
    //    "15" (ej. "2915456789" = área 291 + abonado 5456789) NO se debe
    //    tocar — sin el guard de longitud, el regex lo mutilaba y devolvía
    //    "" (bug 2026-05-20: teléfonos que "no se guardaban").
    if (digitos.length == 12) {
      final m15 = RegExp(r'^(\d{2,4})15(\d{6,8})$').firstMatch(digitos);
      if (m15 != null) {
        digitos = '${m15.group(1)}${m15.group(2)}';
      }
    }

    // 4) Asegurar prefijo 549 (Argentina + móvil).
    if (digitos.startsWith('549')) {
      // Ya está completo. Nada que hacer.
    } else if (digitos.startsWith('54')) {
      // Vino con código país pero sin el "9" móvil.
      digitos = '549${digitos.substring(2)}';
    } else {
      // Asumimos número local (área + abonado): le anteponemos 54+9.
      digitos = '549$digitos';
    }

    // Sanity check: 549 + 10 dígitos = 13. Aceptamos 12-14 para tolerar
    // áreas de 2 ó 4 dígitos.
    if (digitos.length < 12 || digitos.length > 14) return '';
    return digitos;
  }

  /// Toma el formato canónico de Firestore (`549...`) y lo devuelve en
  /// formato local para mostrar al admin (sin código país ni 9 móvil).
  ///
  /// Si el dato no tiene el prefijo 549 (ej. ya estaba sin él, o vino
  /// vacío, o está corrupto), lo devuelve tal cual sin tocarlo —
  /// preferimos mostrar "algo raro" antes que perder información.
  ///
  /// Ejemplos:
  /// - `"5492914567890"` → `"2914567890"`
  /// - `"5491155551234"` → `"1155551234"`
  /// - `"2914567890"`     → `"2914567890"`  (ya estaba sin prefijo)
  /// - `""` o `"-"`        → `"-"` (placeholder de "sin teléfono")
  /// - `null`              → `"-"`
  static String paraMostrar(String? guardado) {
    final input = (guardado ?? '').trim();
    if (input.isEmpty || input == '-') return '-';
    if (input.startsWith('549') && input.length >= 12) {
      return input.substring(3);
    }
    if (input.startsWith('54') && input.length >= 11) {
      // Caso raro: número con prefijo 54 pero sin el 9 móvil.
      return input.substring(2);
    }
    return input;
  }
}
