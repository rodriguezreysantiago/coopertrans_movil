import 'package:cloud_firestore/cloud_firestore.dart';

/// Una jornada reconstruida de un chofer en un día (escala ART).
///
/// La produce la CF `reconstruirJornadasDiario` (cron 06:30 ART, procesa
/// AYER) agrupando los `SITRACK_EVENTOS` por `(driver_dni, día)` y
/// detectando tramos de manejo (speed >= 15 km/h) intercalados con
/// paradas. Doc id determinístico `{dni}_{YYYY-MM-DD}` → idempotente.
class JornadaDia {
  /// `{dni}_{YYYY-MM-DD}` — id del doc.
  final String id;
  final String choferDni;
  final String? choferNombre;

  /// Patente más usada en el día (si tocó varias).
  final String patentePrincipal;

  /// Todas las patentes que tocó (length normalmente 1).
  final List<String> patentes;

  /// 'YYYY-MM-DD' ART.
  final String fecha;

  /// Inicio del primer tramo de manejo.
  final DateTime inicio;

  /// Fin del último tramo de manejo.
  final DateTime fin;

  /// Suma de duraciones de todos los tramos de manejo, en minutos.
  final int manejoMin;

  /// Suma de duraciones de todas las paradas entre tramos, en minutos.
  final int paradasMin;

  /// Km totales del día (sumatoria de odómetros por tramo cuando hay).
  final int kmTotal;

  /// Velocidad máxima alcanzada (km/h).
  final int velocidadMax;

  /// Cantidad total de eventos Sitrack procesados para este chofer/día.
  final int totalEventos;

  final List<TramoManejo> tramos;
  final List<Parada> paradas;

  /// Serie de velocidad (downsampled a ~240 puntos) para el gráfico
  /// fl_chart. Cada punto: (ts_ms_since_epoch, speed_km_h).
  final List<PuntoVelocidad> serieVelocidad;

  const JornadaDia({
    required this.id,
    required this.choferDni,
    required this.choferNombre,
    required this.patentePrincipal,
    required this.patentes,
    required this.fecha,
    required this.inicio,
    required this.fin,
    required this.manejoMin,
    required this.paradasMin,
    required this.kmTotal,
    required this.velocidadMax,
    required this.totalEventos,
    required this.tramos,
    required this.paradas,
    required this.serieVelocidad,
  });

  factory JornadaDia.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    return JornadaDia(
      id: doc.id,
      choferDni: (m['chofer_dni'] as String?) ?? '',
      choferNombre: m['chofer_nombre'] as String?,
      patentePrincipal: (m['patente_principal'] as String?) ?? '',
      patentes: (m['patentes'] as List?)?.cast<String>() ?? const [],
      fecha: (m['fecha'] as String?) ?? '',
      inicio: (m['inicio'] as Timestamp).toDate(),
      fin: (m['fin'] as Timestamp).toDate(),
      manejoMin: (m['manejo_min'] as num?)?.toInt() ?? 0,
      paradasMin: (m['paradas_min'] as num?)?.toInt() ?? 0,
      kmTotal: (m['km_total'] as num?)?.toInt() ?? 0,
      velocidadMax: (m['velocidad_max'] as num?)?.toInt() ?? 0,
      totalEventos: (m['total_eventos'] as num?)?.toInt() ?? 0,
      tramos: ((m['tramos'] as List?) ?? const [])
          .map((t) => TramoManejo.fromMap(t as Map<String, dynamic>))
          .toList(),
      paradas: ((m['paradas'] as List?) ?? const [])
          .map((p) => Parada.fromMap(p as Map<String, dynamic>))
          .toList(),
      serieVelocidad: ((m['serie_velocidad'] as List?) ?? const [])
          .map((p) => PuntoVelocidad.fromMap(p as Map<String, dynamic>))
          .toList(),
    );
  }
}

class TramoManejo {
  final DateTime desde;
  final DateTime hasta;
  final int duracionMin;
  final int kmAprox;
  final int velocidadMax;
  final int velocidadProm;

  const TramoManejo({
    required this.desde,
    required this.hasta,
    required this.duracionMin,
    required this.kmAprox,
    required this.velocidadMax,
    required this.velocidadProm,
  });

  factory TramoManejo.fromMap(Map<String, dynamic> m) => TramoManejo(
        desde: (m['desde'] as Timestamp).toDate(),
        hasta: (m['hasta'] as Timestamp).toDate(),
        duracionMin: (m['duracion_min'] as num?)?.toInt() ?? 0,
        kmAprox: (m['km_aprox'] as num?)?.toInt() ?? 0,
        velocidadMax: (m['velocidad_max'] as num?)?.toInt() ?? 0,
        velocidadProm: (m['velocidad_prom'] as num?)?.toInt() ?? 0,
      );
}

class Parada {
  final DateTime desde;
  final DateTime hasta;
  final int duracionMin;
  final double? lat;
  final double? lng;

  /// True si la parada duró >= 15 min (umbral Vecchi para corte de
  /// bloque dentro de la jornada).
  final bool cumple15min;

  /// True si la parada duró >= 8 h (umbral Vecchi para descanso entre
  /// jornadas).
  final bool cumple8h;

  const Parada({
    required this.desde,
    required this.hasta,
    required this.duracionMin,
    required this.lat,
    required this.lng,
    required this.cumple15min,
    required this.cumple8h,
  });

  factory Parada.fromMap(Map<String, dynamic> m) => Parada(
        desde: (m['desde'] as Timestamp).toDate(),
        hasta: (m['hasta'] as Timestamp).toDate(),
        duracionMin: (m['duracion_min'] as num?)?.toInt() ?? 0,
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
        cumple15min: m['cumple_15min'] as bool? ?? false,
        cumple8h: m['cumple_8h'] as bool? ?? false,
      );

  /// Etiqueta corta para mostrar el tipo de parada en la UI según
  /// duración: "Técnica" / "Corta" / "Larga" / "Descanso".
  String get etiqueta {
    if (cumple8h) return 'Descanso';
    if (duracionMin >= 60) return 'Larga';
    if (cumple15min) return 'Corta';
    return 'Técnica';
  }

  /// True si la parada califica como "descanso suficiente" para cortar
  /// un bloque de 4h (≥ 15 min). En la UI se pinta verde cuando es
  /// suficiente, naranja cuando no.
  bool get cumpleAlgoUtil => cumple15min;
}

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
