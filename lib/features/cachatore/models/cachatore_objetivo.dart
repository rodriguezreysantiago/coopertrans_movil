import 'package:cloud_firestore/cloud_firestore.dart';

import 'franja_carga.dart';

/// Estado en vivo de un objetivo, tal como lo reporta el bot. Los `codigo`
/// los escribe el Python (cachatore/vigia.py); acá los mapeamos a etiqueta
/// + semántica para la UI.
enum EstadoObjetivo {
  buscando('buscando', 'Buscando turno', _Sev.info),
  reservado('reservado', 'Turno reservado', _Sev.ok),
  reagendado('reagendado', 'Turno reagendado', _Sev.ok),
  sinCredenciales('sin_credenciales', 'Sin mail/clave', _Sev.error),
  sinPatente('sin_patente', 'Sin unidad asignada', _Sev.error),
  loginFallo('login_fallo', 'No puede loguear', _Sev.error),
  revisar('revisar', 'Revisar', _Sev.warn);

  final String codigo;
  final String etiqueta;
  final _Sev _sev;
  const EstadoObjetivo(this.codigo, this.etiqueta, this._sev);

  bool get esOk => _sev == _Sev.ok;
  bool get esError => _sev == _Sev.error;
  bool get esWarn => _sev == _Sev.warn;

  static EstadoObjetivo fromCodigo(String? c) {
    final t = (c ?? '').trim().toLowerCase();
    for (final e in EstadoObjetivo.values) {
      if (e.codigo == t) return e;
    }
    return EstadoObjetivo.buscando;
  }
}

enum _Sev { info, ok, warn, error }

/// Un chofer que el bot debe vigilar (doc `CACHATORE_OBJETIVOS/{dni}`).
///
/// La app escribe la parte de configuración (franja, reagendar, activo); el
/// bot escribe de vuelta el estado en vivo (estado, hora del turno, etc).
class CachatoreObjetivo {
  final String dni;
  final String? nombre;
  final FranjaCarga franja;

  /// Si true, el bot mueve el turno de este chofer a su franja apenas se
  /// libere un slot mejor (en vez de solo conseguir uno nuevo).
  final bool reagendar;

  /// Si false, el bot ignora a este chofer (pausado individual) sin
  /// borrarlo de la lista.
  final bool activo;

  // ─── Estado en vivo (lo escribe el bot) ───
  final String? estadoRaw;
  final String? estadoHora; // 'HH:MM' del turno conseguido
  final String? estadoDetalle;
  final DateTime? estadoEn;

  const CachatoreObjetivo({
    required this.dni,
    this.nombre,
    required this.franja,
    this.reagendar = false,
    this.activo = true,
    this.estadoRaw,
    this.estadoHora,
    this.estadoDetalle,
    this.estadoEn,
  });

  EstadoObjetivo get estado => EstadoObjetivo.fromCodigo(estadoRaw);

  /// `true` si el chofer ya tiene turno conseguido por el bot.
  bool get tieneTurno =>
      estado == EstadoObjetivo.reservado || estado == EstadoObjetivo.reagendado;

  factory CachatoreObjetivo.fromMap(String id, Map<String, dynamic> d) {
    return CachatoreObjetivo(
      dni: (d['dni'] ?? id).toString(),
      nombre: d['nombre']?.toString(),
      franja: FranjaCarga.fromCodigo(d['franja']?.toString()),
      reagendar: d['reagendar'] == true,
      activo: d['activo'] != false, // default activo si falta el campo
      estadoRaw: d['estado']?.toString(),
      estadoHora: d['estado_hora']?.toString(),
      estadoDetalle: d['estado_detalle']?.toString(),
      estadoEn: (d['estado_en'] as Timestamp?)?.toDate(),
    );
  }

  factory CachatoreObjetivo.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) =>
      CachatoreObjetivo.fromMap(doc.id, doc.data() ?? const {});
}
