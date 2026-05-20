/// Las franjas horarias de carga YPF. El bot toma cualquier slot libre dentro
/// de la franja elegida para cada chofer. Los `codigo` coinciden EXACTO con los
/// del bot Python (cachatore/iturnos.py → FRANJAS + CUALQUIERA) — no cambiar uno
/// sin el otro.
///
/// `cualquiera` es un comodín (sin ventana): el bot agarra el primer slot que
/// se libere a CUALQUIER hora; combinado con "cualquier fecha" = el primer
/// turno futuro disponible, sea la fecha y la hora que sea.
enum FranjaCarga {
  cualquiera('cualquiera', 'Cualquier horario', 'A cualquier hora'),
  madrugada('madrugada', 'Madrugada', '00:00 a 05:30'),
  manana('manana', 'Mañana', '06:00 a 11:30'),
  tarde('tarde', 'Tarde', '12:00 a 17:30'),
  noche('noche', 'Noche', '18:00 a 23:30');

  /// Código que se guarda en Firestore y entiende el bot.
  final String codigo;

  /// Etiqueta legible para la UI.
  final String etiqueta;

  /// Rango horario para mostrar como ayuda.
  final String rango;

  const FranjaCarga(this.codigo, this.etiqueta, this.rango);

  /// `true` para el comodín "cualquier horario" (sin ventana de franja).
  bool get esCualquiera => this == FranjaCarga.cualquiera;

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
