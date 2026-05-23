import 'package:cloud_firestore/cloud_firestore.dart';

/// Resultado de un chequeo one-shot al wizard Agregar del cachatore: el
/// operador pidió verificar si un chofer (que NO está en CACHATORE_OBJETIVOS)
/// tiene un turno preexistente sacado por la web de iTurnos. El bot escribe
/// el `resultado` al procesar el pedido (~3-10 s típico). Mientras el doc no
/// tenga resultado, la app muestra el spinner.
enum CachatoreChequeoResultado {
  /// El bot detectó turno preexistente en iTurnos. Ya escribió el TURNO y el
  /// OBJETIVO `detectado_externo`. La app puede cerrar el wizard y avisar.
  conTurno('con_turno'),

  /// El bot logueó y consultó OK pero el chofer no tenía turnos. La app
  /// muestra snackbar y el operador puede seguir el wizard normal si quiere.
  sinTurno('sin_turno'),

  /// El bot no pudo procesar el pedido (sin credenciales, Cloudflare, etc.).
  /// `detalle` trae el motivo. La app muestra snackbar de error.
  error('error');

  final String codigo;
  const CachatoreChequeoResultado(this.codigo);

  static CachatoreChequeoResultado? fromCodigo(String? c) {
    final t = (c ?? '').trim().toLowerCase();
    if (t.isEmpty) return null;
    for (final v in CachatoreChequeoResultado.values) {
      if (v.codigo == t) return v;
    }
    return null;
  }
}

class CachatoreChequeo {
  /// `null` mientras el bot todavía no procesa el doc. Una vez resuelto,
  /// trae el resultado.
  final CachatoreChequeoResultado? resultado;

  /// Texto adicional: si `conTurno` → texto del turno detectado (ej.
  /// "Miércoles 22 May 2026 14:00 hs."); si `error` → motivo legible
  /// (ej. "no pude loguear (¿Cloudflare bloqueando?)").
  final String? detalle;

  final DateTime? resueltoEn;

  const CachatoreChequeo({
    this.resultado,
    this.detalle,
    this.resueltoEn,
  });

  bool get pendiente => resultado == null;

  factory CachatoreChequeo.fromMap(Map<String, dynamic>? d) {
    if (d == null) return const CachatoreChequeo();
    return CachatoreChequeo(
      resultado: CachatoreChequeoResultado.fromCodigo(d['resultado']?.toString()),
      detalle: d['detalle']?.toString(),
      resueltoEn: (d['resuelto_en'] as Timestamp?)?.toDate(),
    );
  }
}
