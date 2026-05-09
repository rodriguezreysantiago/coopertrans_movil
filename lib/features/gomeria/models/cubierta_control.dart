import 'package:cloud_firestore/cloud_firestore.dart';

/// Una lectura individual de control de presión y/o profundidad de
/// banda sobre una cubierta instalada. Inmutable — se crea y nunca se
/// modifica.
///
/// Vive en `CUBIERTAS_CONTROLES`. Cada `registrarLectura()` del
/// `GomeriaService` crea uno acá y, en paralelo, pisa los campos
/// `ultima_*` de la `CUBIERTAS_INSTALADAS` correspondiente (atajo para
/// listados sin join).
///
/// Para reportes de auditoría / análisis de desgaste / trending,
/// consultar esta colección — la última lectura sola no alcanza.
class CubiertaControl {
  final String id;

  /// FK a CUBIERTAS. Snapshot del código (CUB-XXXX) para listados.
  final String cubiertaId;
  final String cubiertaCodigo;

  /// FK a CUBIERTAS_INSTALADAS. Permite reconstruir si la cubierta se
  /// retiró y volvió a instalar después: cada instalación tiene su
  /// propio sub-stream de controles.
  final String instalacionId;

  /// Snapshot de la unidad y posición al momento de la lectura. Aunque
  /// se puede joinear con `CUBIERTAS_INSTALADAS`, capturarlo acá hace
  /// el reporte standalone (la cubierta puede haber rotado después).
  final String unidadId;
  final String posicion;

  /// Presión medida en PSI. `null` si solo se midió profundidad.
  final int? presionPsi;

  /// Profundidad de banda medida en mm. `null` si solo se midió presión.
  final double? profundidadBandaMm;

  /// Cuándo se hizo la lectura.
  final DateTime fecha;

  /// DNI del supervisor de gomería que tomó la lectura.
  final String registradoPorDni;
  final String? registradoPorNombre;

  const CubiertaControl({
    required this.id,
    required this.cubiertaId,
    required this.cubiertaCodigo,
    required this.instalacionId,
    required this.unidadId,
    required this.posicion,
    required this.presionPsi,
    required this.profundidadBandaMm,
    required this.fecha,
    required this.registradoPorDni,
    required this.registradoPorNombre,
  });

  factory CubiertaControl.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      CubiertaControl.fromMap(doc.id, doc.data());

  factory CubiertaControl.fromMap(String id, Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    return CubiertaControl(
      id: id,
      cubiertaId: (d['cubierta_id'] ?? '').toString(),
      cubiertaCodigo: (d['cubierta_codigo'] ?? '').toString(),
      instalacionId: (d['instalacion_id'] ?? '').toString(),
      unidadId: (d['unidad_id'] ?? '').toString(),
      posicion: (d['posicion'] ?? '').toString(),
      presionPsi: (d['presion_psi'] as num?)?.toInt(),
      profundidadBandaMm: (d['profundidad_banda_mm'] as num?)?.toDouble(),
      fecha: (d['fecha'] as Timestamp?)?.toDate() ?? DateTime.now(),
      registradoPorDni: (d['registrado_por_dni'] ?? '').toString(),
      registradoPorNombre: d['registrado_por_nombre']?.toString(),
    );
  }
}
