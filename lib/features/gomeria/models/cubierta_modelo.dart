import 'package:cloud_firestore/cloud_firestore.dart';

import '../constants/posiciones.dart';

/// Modelo de cubierta — combinación específica de marca + modelo +
/// medida + tipo de uso. Ej: "Bridgestone R268 295/80R22.5 DIRECCION".
///
/// Cada modelo tiene su propia estimación de km de vida (nueva y
/// recapada). Esto le permite a Vecchi distinguir entre marcas premium
/// (que duran más y se recapan) vs marcas chinas (que duran menos y se
/// descartan al primer ciclo).
///
/// El `tipo_uso` (DIRECCION o TRACCION) define en qué posiciones se
/// puede instalar la cubierta. La validación es ESTRICTA — el sistema
/// bloquea instalar una cubierta TRACCION en posición DIRECCION
/// (decisión confirmada por Santiago: "es un error de tipeo seguramente").
class CubiertaModelo {
  final String id;

  /// FK al doc en CUBIERTAS_MARCAS.
  final String marcaId;

  /// Snapshot del nombre de la marca al crear el modelo. Permite mostrar
  /// "Bridgestone R268" sin un join extra.
  final String marcaNombre;

  /// Nombre comercial del modelo (ej. "R268", "M788", "Pirelli FR01").
  final String modelo;

  /// Medida estándar (ej. "295/80R22.5", "11R22.5"). Campo libre — el
  /// supervisor sabe qué medida tiene la cubierta. Si en el futuro se
  /// quiere validar medida vs posición, agregar matriz acá.
  final String medida;

  final TipoUsoCubierta tipoUso;

  /// Km esperados de vida cuando la cubierta es nueva (vidas=1).
  /// Usado para calcular el porcentaje de uso y disparar alertas
  /// "próxima a vencer".
  final int? kmVidaEstimadaNueva;

  /// Km esperados de vida cuando la cubierta es recapada (vidas>=2).
  /// Típicamente menos que [kmVidaEstimadaNueva] (~50%). Si la cubierta
  /// no es recapable, este valor es null.
  final int? kmVidaEstimadaRecapada;

  /// Si es `false`, no se ofrece la opción de mandar a recapar (típico
  /// de marcas chinas baratas que no rinden recapado).
  final bool recapable;

  /// Presión inflado recomendada en PSI. Opcional — referencia para
  /// el control diario en la gomería ("inflar a 100 PSI"). El módulo no
  /// alerta automáticamente si no se cumple, solo lo muestra.
  final int? presionRecomendadaPsi;

  /// Profundidad mínima de banda de rodamiento en mm. Por debajo de
  /// este valor la cubierta tiene que cambiarse (regulación + seguridad).
  /// La app no fuerza nada — es info al supervisor.
  final double? profundidadBandaMinimaMm;

  final bool activo;

  const CubiertaModelo({
    required this.id,
    required this.marcaId,
    required this.marcaNombre,
    required this.modelo,
    required this.medida,
    required this.tipoUso,
    required this.kmVidaEstimadaNueva,
    required this.kmVidaEstimadaRecapada,
    required this.recapable,
    required this.presionRecomendadaPsi,
    required this.profundidadBandaMinimaMm,
    required this.activo,
  });

  /// Marca + modelo + medida, sin campos vacíos. Evita el doble espacio
  /// cuando el modelo no tiene nombre (ej. los placeholders "DEFAULT", que
  /// tienen `modelo == ''`). Es la etiqueta que se snapshotea en montajes y
  /// movimientos de stock.
  String get etiquetaCorta =>
      [marcaNombre, modelo, medida].where((s) => s.trim().isNotEmpty).join(' ');

  /// Etiqueta legible compacta para listados ("Bridgestone R268
  /// 295/80R22.5 — Tracción").
  String get etiqueta => '$etiquetaCorta — ${tipoUso.etiqueta}';

  /// Devuelve los km esperados de vida según [vidas] (1 = nueva,
  /// 2+ = recapada). null si no hay valor configurado para esa vida.
  int? kmEsperadosParaVida(int vidas) {
    if (vidas <= 1) return kmVidaEstimadaNueva;
    return kmVidaEstimadaRecapada;
  }

  factory CubiertaModelo.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      CubiertaModelo.fromMap(doc.id, doc.data());

  factory CubiertaModelo.fromMap(String id, Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    return CubiertaModelo(
      id: id,
      marcaId: (d['marca_id'] ?? '').toString(),
      marcaNombre: (d['marca_nombre'] ?? '').toString(),
      modelo: (d['modelo'] ?? '').toString(),
      medida: (d['medida'] ?? '').toString(),
      tipoUso: TipoUsoCubierta.fromCodigo(d['tipo_uso']?.toString()) ??
          TipoUsoCubierta.traccion,
      kmVidaEstimadaNueva: (d['km_vida_estimada_nueva'] as num?)?.toInt(),
      kmVidaEstimadaRecapada:
          (d['km_vida_estimada_recapada'] as num?)?.toInt(),
      recapable: d['recapable'] is bool ? d['recapable'] as bool : false,
      presionRecomendadaPsi: (d['presion_recomendada_psi'] as num?)?.toInt(),
      profundidadBandaMinimaMm:
          (d['profundidad_banda_minima_mm'] as num?)?.toDouble(),
      activo: d['activo'] is bool ? d['activo'] as bool : true,
    );
  }

  Map<String, dynamic> toMap() => {
        'marca_id': marcaId,
        'marca_nombre': marcaNombre,
        'modelo': modelo,
        'medida': medida,
        'tipo_uso': tipoUso.codigo,
        'km_vida_estimada_nueva': kmVidaEstimadaNueva,
        'km_vida_estimada_recapada': kmVidaEstimadaRecapada,
        'recapable': recapable,
        'presion_recomendada_psi': presionRecomendadaPsi,
        'profundidad_banda_minima_mm': profundidadBandaMinimaMm,
        'activo': activo,
      };

  // Equality por id — necesario para DropdownButtonFormField (ver nota
  // en CubiertaMarca).
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CubiertaModelo && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
