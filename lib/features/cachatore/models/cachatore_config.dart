/// Config global del bot cachatore (doc `CACHATORE_CONFIG/global`).
///
/// La escribe la app; el bot Python la lee (throttle ~30 s — no en cada
/// escaneo). El `activo` es el interruptor maestro: en false el bot queda
/// pausado (no reserva ni reagenda nada).
class CachatoreConfig {
  /// Interruptor maestro. false = bot pausado (no toca nada).
  final bool activo;

  /// Objetivo de fecha: null = cualquier fecha que liberen dentro de la
  /// franja; 'hoy' / 'manana' se resuelven cada día; o 'AAAA-MM-DD'.
  final String? fecha;

  /// Hora del drop ('HH:MM'). Define la ventana en la que el bot pasa a
  /// modo agresivo (cada chofer caza su agenda a full).
  final String horaInicio;

  /// Largo de la ventana agresiva, en minutos.
  final int duracionMin;

  /// Cadencia del barrido latente (segundos) — cada cuánto rebusca turnos
  /// liberados el resto del día.
  final num pollLatenteSeg;

  const CachatoreConfig({
    this.activo = false,
    this.fecha,
    this.horaInicio = '10:29',
    this.duracionMin = 20,
    this.pollLatenteSeg = 5,
  });

  /// Lee del doc. Si el doc no existe (data == null) devuelve los defaults
  /// (activo=false: arranca pausado hasta que alguien lo prenda).
  factory CachatoreConfig.fromMap(Map<String, dynamic>? d) {
    if (d == null) return const CachatoreConfig();
    return CachatoreConfig(
      activo: d['activo'] == true,
      fecha: d['fecha']?.toString(),
      horaInicio: (d['hora_inicio'] ?? '10:29').toString(),
      duracionMin: (d['duracion_min'] as num?)?.toInt() ?? 20,
      pollLatenteSeg: (d['poll_latente_seg'] as num?) ?? 5,
    );
  }

  /// Etiqueta legible del objetivo de fecha (para mostrar en la UI).
  String get fechaEtiqueta {
    final f = (fecha ?? '').trim().toLowerCase();
    if (f.isEmpty) return 'Cualquier fecha';
    if (f == 'hoy') return 'Hoy';
    if (f == 'manana' || f == 'mañana') return 'Mañana';
    return fecha!; // fecha puntual AAAA-MM-DD
  }
}
