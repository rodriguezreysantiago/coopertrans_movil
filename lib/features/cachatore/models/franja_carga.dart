/// Las 4 franjas horarias de carga YPF. El bot toma cualquier slot libre
/// dentro de la franja elegida para cada chofer. Los `codigo` coinciden
/// EXACTO con los del bot Python (cachatore/iturnos.py → FRANJAS) — no
/// cambiar uno sin el otro.
enum FranjaCarga {
  madrugada('madrugada', 'Madrugada', '00:00 a 05:30'),
  manana('manana', 'Mañana', '06:00 a 11:30'),
  tarde('tarde', 'Tarde', '12:00 a 17:30'),
  noche('noche', 'Noche', '18:00 a 23:00');

  /// Código que se guarda en Firestore y entiende el bot.
  final String codigo;

  /// Etiqueta legible para la UI.
  final String etiqueta;

  /// Rango horario para mostrar como ayuda.
  final String rango;

  const FranjaCarga(this.codigo, this.etiqueta, this.rango);

  /// Parser tolerante para leer de Firestore. Default `manana` si el
  /// código no existe (no debería pasar — la UI solo escribe válidos).
  static FranjaCarga fromCodigo(String? c) {
    final t = (c ?? '').trim().toLowerCase();
    for (final f in FranjaCarga.values) {
      if (f.codigo == t) return f;
    }
    return FranjaCarga.manana;
  }
}
