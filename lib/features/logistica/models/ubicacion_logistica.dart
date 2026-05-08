import 'package:cloud_firestore/cloud_firestore.dart';

/// Punto físico de carga o descarga. Reusable entre tarifas.
///
/// `lat/lng` son opcionales — quedan disponibles para el futuro mapa
/// de planeamiento de viajes (cálculo de distancias, ETA, ruteo). No
/// se requieren para la operación actual.
///
/// `empresaId` (opcional) asocia la ubicación con su empresa "dueña"
/// (la que opera el lugar físico — planta, depósito, sector portuario).
/// Si dos empresas comparten un puerto físico, son 2 ubicaciones
/// distintas (sector CARGILL vs sector BUNGE) — operativamente NO es
/// lo mismo cargar para una u otra. `empresaNombre` es snapshot del
/// nombre al asociar; si renombran la empresa después, el snapshot
/// queda como referencia histórica visible en cards.
///
/// Ubicaciones sin empresa siguen funcionando (backwards compat con
/// ubicaciones cargadas antes de esta feature). Aparecen "huérfanas"
/// en la lista — el operador puede asociarlas desde la edición
/// inline cuando sume.
class UbicacionLogistica {
  final String id;
  final String nombre;
  final String localidad;
  final String provincia;
  final String? direccion;
  final double? lat;
  final double? lng;
  final String? empresaId;
  final String? empresaNombre;
  final bool activa;
  final DateTime? creadoEn;
  final String? creadoPor;

  const UbicacionLogistica({
    required this.id,
    required this.nombre,
    required this.localidad,
    required this.provincia,
    this.direccion,
    this.lat,
    this.lng,
    this.empresaId,
    this.empresaNombre,
    this.activa = true,
    this.creadoEn,
    this.creadoPor,
  });

  /// Texto compuesto para mostrar como subtítulo / chip.
  /// Ejemplo: "Tres Arroyos, Buenos Aires" o "Tres Arroyos, Buenos
  /// Aires — Av. San Martín 123".
  String get etiquetaCompleta {
    final base = '$localidad, $provincia';
    if (direccion == null || direccion!.isEmpty) return base;
    return '$base — $direccion';
  }

  factory UbicacionLogistica.fromMap(String id, Map<String, dynamic> d) {
    return UbicacionLogistica(
      id: id,
      nombre: (d['nombre'] ?? '').toString(),
      localidad: (d['localidad'] ?? '').toString(),
      provincia: (d['provincia'] ?? '').toString(),
      direccion: (d['direccion'] as String?)?.trim().isEmpty ?? true
          ? null
          : (d['direccion'] as String).trim(),
      lat: (d['lat'] as num?)?.toDouble(),
      lng: (d['lng'] as num?)?.toDouble(),
      empresaId: (d['empresa_id'] as String?)?.trim().isEmpty ?? true
          ? null
          : (d['empresa_id'] as String).trim(),
      empresaNombre: (d['empresa_nombre'] as String?)?.trim().isEmpty ?? true
          ? null
          : (d['empresa_nombre'] as String).trim(),
      activa: d['activa'] != false,
      creadoEn: (d['creado_en'] as Timestamp?)?.toDate(),
      creadoPor: d['creado_por']?.toString(),
    );
  }

  factory UbicacionLogistica.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) =>
      UbicacionLogistica.fromMap(doc.id, doc.data());

  Map<String, dynamic> toMap() {
    return {
      'nombre': nombre,
      'localidad': localidad,
      'provincia': provincia,
      if (direccion != null) 'direccion': direccion,
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (empresaId != null) 'empresa_id': empresaId,
      if (empresaNombre != null) 'empresa_nombre': empresaNombre,
      'activa': activa,
      if (creadoPor != null) 'creado_por': creadoPor,
    };
  }
}
