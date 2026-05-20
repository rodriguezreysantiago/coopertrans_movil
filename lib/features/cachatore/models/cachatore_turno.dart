import 'package:cloud_firestore/cloud_firestore.dart';

/// Un turno REAL que tiene un chofer en iTurnos (doc `CACHATORE_TURNOS/{dni}`),
/// lo haya sacado el bot o no (incluso turnos cargados por fuera del cachatore).
/// Lo escribe el bot escaneando `mis_turnos` de cada chofer. La pantalla
/// "Turnos concretados" lee de acá (no de los vigilados).
class CachatoreTurno {
  final String dni;
  final String? nombre;

  /// Texto legible del turno (ej. "Miércoles 20 May 2026 14:00 hs.").
  final String? cuando;

  /// 'HH:MM' del turno.
  final String? hora;

  /// UUID del turno en iTurnos (para reagendar/cancelar).
  final String? uuid;

  final DateTime? actualizadoEn;

  const CachatoreTurno({
    required this.dni,
    this.nombre,
    this.cuando,
    this.hora,
    this.uuid,
    this.actualizadoEn,
  });

  factory CachatoreTurno.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return CachatoreTurno(
      dni: (d['dni'] ?? doc.id).toString(),
      nombre: d['nombre']?.toString(),
      cuando: d['cuando']?.toString(),
      hora: d['hora']?.toString(),
      uuid: d['uuid']?.toString(),
      actualizadoEn: (d['actualizado_en'] as Timestamp?)?.toDate(),
    );
  }
}
