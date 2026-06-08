import 'package:cloud_firestore/cloud_firestore.dart';

/// Registro de jornada v3 (a posteriori) de un chofer en un turno.
///
/// Lo produce la CF `registrarJornadasV3Diario` reconstruyendo los
/// `SITRACK_EVENTOS` por SEÑALES (Contacto OFF/ON, detenido) — más preciso
/// que el speed-based del histórico. DocId `{dni}_{YYYY-MM-DD}_{HHMM}`
/// (único por turno; un chofer puede tener 2 turnos el mismo día).
class RegistroJornada {
  final String id;
  final String choferDni;
  final String? patente;

  /// 'YYYY-MM-DD' ART del inicio del turno.
  final String fecha;

  final DateTime inicioTurno;
  final DateTime finTurno;

  /// Manejo neto (segundos) — suma de los tramos de manejo del turno.
  final int manejoNetoSeg;

  /// Pausa total (segundos).
  final int pausaTotalSeg;

  /// Km recorridos (corrobora el manejo: recorrido ÷ horas ≈ crucero ⇒ real).
  final int recorridoKm;

  /// Lista completa de bloques (4h) con sus métricas.
  final List<BloqueJornada> bloques;

  /// Cuántos bloques superaron 4 h de manejo continuo (infracción).
  final int bloquesExcedidos;

  /// Manejo neto > 12 h (tope de jornada).
  final bool jornadaExcedida;

  /// Manejó en la veda nocturna 00:00–06:00 ART por encima del umbral.
  final bool vedaExcedida;

  /// Descanso antes de este turno (segundos), null si no se ve.
  final int? descansoPrevioSeg;

  /// Descanso previo < 8 h (mínimo legal entre jornadas).
  final bool descansoInsuficiente;

  /// Se descartaron eventos de otra patente (posible chofer distinto).
  final bool driftFiltrado;

  /// 'alta' | 'media' | 'baja'.
  final String confianza;

  final List<PausaJornada> pausas;

  /// Línea de tiempo completa (manejo + pausas alternados) del turno. Es la
  /// fuente para listar tramos de manejo y paradas en la UI v3.
  final List<SegmentoJornada> segmentos;

  /// Serie velocidad/tiempo downsampleada (≤ 240 puntos) para el gráfico
  /// fl_chart de la pantalla v3.
  final List<PuntoVelocidad> serieVelocidad;

  /// Líneas legibles armadas por el backend (turno, pausas, avisos).
  final List<String> explicacion;

  const RegistroJornada({
    required this.id,
    required this.choferDni,
    required this.patente,
    required this.fecha,
    required this.inicioTurno,
    required this.finTurno,
    required this.manejoNetoSeg,
    required this.pausaTotalSeg,
    required this.recorridoKm,
    required this.bloques,
    required this.bloquesExcedidos,
    required this.jornadaExcedida,
    required this.vedaExcedida,
    required this.descansoPrevioSeg,
    required this.descansoInsuficiente,
    required this.driftFiltrado,
    required this.confianza,
    required this.pausas,
    required this.segmentos,
    required this.serieVelocidad,
    required this.explicacion,
  });

  /// Cantidad de bloques (mantiene el nombre viejo de la card para evitar
  /// renames en la UI).
  int get bloquesCount => bloques.length;

  /// Tramos de manejo extraídos de `segmentos` (atajo común en la UI).
  List<SegmentoJornada> get tramosManejo =>
      segmentos.where((s) => s.tipo == 'manejo').toList();

  factory RegistroJornada.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    return RegistroJornada(
      id: doc.id,
      choferDni: (m['chofer_dni'] as String?) ?? '',
      patente: m['patente'] as String?,
      fecha: (m['fecha'] as String?) ?? '',
      inicioTurno: (m['inicio_turno'] as Timestamp?)?.toDate() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      finTurno: (m['fin_turno'] as Timestamp?)?.toDate() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      manejoNetoSeg: (m['manejo_neto_seg'] as num?)?.toInt() ?? 0,
      pausaTotalSeg: (m['pausa_total_seg'] as num?)?.toInt() ?? 0,
      recorridoKm: (m['recorrido_km'] as num?)?.toInt() ?? 0,
      bloques: ((m['bloques'] as List?) ?? const [])
          .map((b) => BloqueJornada.fromMap(b as Map<String, dynamic>))
          .toList(),
      bloquesExcedidos: (m['bloques_excedidos'] as num?)?.toInt() ?? 0,
      jornadaExcedida: m['jornada_excedida'] as bool? ?? false,
      vedaExcedida: m['veda_excedida'] as bool? ?? false,
      descansoPrevioSeg: (m['descanso_previo_seg'] as num?)?.toInt(),
      descansoInsuficiente: m['descanso_insuficiente'] as bool? ?? false,
      driftFiltrado: m['drift_filtrado'] as bool? ?? false,
      confianza: (m['confianza'] as String?) ?? 'alta',
      pausas: ((m['pausas'] as List?) ?? const [])
          .map((p) => PausaJornada.fromMap(p as Map<String, dynamic>))
          .toList(),
      segmentos: ((m['segmentos'] as List?) ?? const [])
          .map((s) => SegmentoJornada.fromMap(s as Map<String, dynamic>))
          .toList(),
      serieVelocidad: ((m['serie_velocidad'] as List?) ?? const [])
          .map((p) => PuntoVelocidad.fromMap(p as Map<String, dynamic>))
          .toList(),
      explicacion: ((m['explicacion'] as List?) ?? const []).cast<String>(),
    );
  }
}

/// Bloque de manejo (≤ 4h por política Vecchi).
class BloqueJornada {
  final int indice;
  final DateTime inicio;
  final DateTime fin;
  final int manejoNetoSeg;
  final bool excedido;
  final int kmAprox;
  final int velMax;
  final int velProm;

  const BloqueJornada({
    required this.indice,
    required this.inicio,
    required this.fin,
    required this.manejoNetoSeg,
    required this.excedido,
    required this.kmAprox,
    required this.velMax,
    required this.velProm,
  });

  factory BloqueJornada.fromMap(Map<String, dynamic> m) => BloqueJornada(
        indice: (m['indice'] as num?)?.toInt() ?? 0,
        inicio: (m['inicio'] as Timestamp?)?.toDate() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        fin: (m['fin'] as Timestamp?)?.toDate() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        manejoNetoSeg: (m['manejo_neto_seg'] as num?)?.toInt() ?? 0,
        excedido: m['excedido'] as bool? ?? false,
        kmAprox: (m['km_aprox'] as num?)?.toInt() ?? 0,
        velMax: (m['vel_max'] as num?)?.toInt() ?? 0,
        velProm: (m['vel_prom'] as num?)?.toInt() ?? 0,
      );
}

/// Una pausa del turno (entre dos tramos de manejo).
class PausaJornada {
  final DateTime inicio;
  final DateTime fin;
  final int durSeg;

  /// 'contacto_off' | 'detenido' | 'gap_misma_pos' | 'parado'.
  final String origen;

  /// 'alta' | 'media' | 'baja'.
  final String confianza;

  /// True si la pausa ≥ 15 min (cierra un bloque de manejo).
  final bool cierraBloque;

  /// Posición donde paró (del evento que abrió la pausa).
  final double? lat;
  final double? lng;

  const PausaJornada({
    required this.inicio,
    required this.fin,
    required this.durSeg,
    required this.origen,
    required this.confianza,
    required this.cierraBloque,
    required this.lat,
    required this.lng,
  });

  factory PausaJornada.fromMap(Map<String, dynamic> m) => PausaJornada(
        inicio: (m['inicio'] as Timestamp?)?.toDate() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        fin: (m['fin'] as Timestamp?)?.toDate() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        durSeg: (m['dur_seg'] as num?)?.toInt() ?? 0,
        origen: (m['origen'] as String?) ?? 'parado',
        confianza: (m['confianza'] as String?) ?? 'alta',
        cierraBloque: m['cierra_bloque'] as bool? ?? false,
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
      );

  /// Texto del motivo de la pausa para mostrar al chofer.
  String get motivo {
    switch (origen) {
      case 'contacto_off':
        return 'motor apagado';
      case 'detenido':
        return 'detenido';
      case 'gap_misma_pos':
        return 'parado (sin señal)';
      default:
        return 'parado';
    }
  }
}

/// Un segmento de la línea de tiempo del turno (manejo o pausa).
class SegmentoJornada {
  /// 'manejo' | 'pausa'.
  final String tipo;
  final DateTime inicio;
  final DateTime fin;
  final int durSeg;

  /// 'alta' | 'media' | 'baja'.
  final String confianza;

  /// Solo en pausas — cómo se detectó.
  final String? origen;
  final double? lat;
  final double? lng;
  final String? motivoBaja;

  /// Solo en segmentos de manejo (null en pausas).
  final int? kmAprox;
  final int? velMax;
  final int? velProm;

  const SegmentoJornada({
    required this.tipo,
    required this.inicio,
    required this.fin,
    required this.durSeg,
    required this.confianza,
    required this.origen,
    required this.lat,
    required this.lng,
    required this.motivoBaja,
    required this.kmAprox,
    required this.velMax,
    required this.velProm,
  });

  factory SegmentoJornada.fromMap(Map<String, dynamic> m) => SegmentoJornada(
        tipo: (m['tipo'] as String?) ?? 'manejo',
        inicio: (m['inicio'] as Timestamp?)?.toDate() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        fin: (m['fin'] as Timestamp?)?.toDate() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        durSeg: (m['dur_seg'] as num?)?.toInt() ?? 0,
        confianza: (m['confianza'] as String?) ?? 'alta',
        origen: m['origen'] as String?,
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
        motivoBaja: m['motivo_baja'] as String?,
        kmAprox: (m['km_aprox'] as num?)?.toInt(),
        velMax: (m['vel_max'] as num?)?.toInt(),
        velProm: (m['vel_prom'] as num?)?.toInt(),
      );

  bool get esManejo => tipo == 'manejo';
}

/// Punto (ts, velocidad) de la serie de velocidad del turno (para el gráfico).
class PuntoVelocidad {
  final int tsMs;
  final int speed;

  const PuntoVelocidad({required this.tsMs, required this.speed});

  factory PuntoVelocidad.fromMap(Map<String, dynamic> m) => PuntoVelocidad(
        tsMs: (m['ts_ms'] as num?)?.toInt() ?? 0,
        speed: (m['speed'] as num?)?.toInt() ?? 0,
      );

  DateTime get ts => DateTime.fromMillisecondsSinceEpoch(tsMs);
}
