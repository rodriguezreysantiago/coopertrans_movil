import 'package:cloud_firestore/cloud_firestore.dart';

/// Tipo de geometría de una zona de descarga.
enum ZonaShape {
  /// Círculo definido por centro (lat/lng) + radio en metros. Más
  /// simple de cargar — alcanza para zonas chicas (planta YPF Anelo
  /// zona descarga ≈ radio 200 m).
  circulo('circulo'),

  /// Polígono definido por una lista ordenada de vértices (3+ puntos).
  /// Más preciso pero requiere copiar las coordenadas de cada esquina.
  poligono('poligono');

  final String codigo;
  const ZonaShape(this.codigo);

  static ZonaShape fromCodigo(String? c) {
    final t = (c ?? '').trim().toLowerCase();
    for (final v in ZonaShape.values) {
      if (v.codigo == t) return v;
    }
    return ZonaShape.circulo;
  }
}

/// Un par lat/lng (no usamos `LatLng` de latlong2 acá para no atar el
/// modelo al paquete de mapas; lo convierte la UI cuando lo necesita).
class LatLngPunto {
  final double latitud;
  final double longitud;
  const LatLngPunto(this.latitud, this.longitud);

  Map<String, dynamic> toMap() => {'lat': latitud, 'lng': longitud};

  factory LatLngPunto.fromMap(Map<String, dynamic> m) => LatLngPunto(
        (m['lat'] is num) ? (m['lat'] as num).toDouble() : 0.0,
        (m['lng'] is num) ? (m['lng'] as num).toDouble() : 0.0,
      );
}

/// Una zona de descarga configurable (1 doc en ZONAS_DESCARGA/{slug}).
///
/// Diseño: el operador define UNA zona por lugar de descarga (YPF
/// Anelo, otra planta cliente, etc). Para cada zona la Cloud Function
/// `zonaDescargaPoller` detecta entradas/salidas mirando
/// SITRACK_POSICIONES y mantiene la cola en vivo + histórico de
/// descargas para el módulo "Descargas" de la app.
class ZonaDescarga {
  /// Identificador estable, usado como docId. Generado desde el nombre
  /// (ej. "YPF Añelo" → `ypf_anelo`).
  final String slug;

  /// Nombre legible para mostrar en la UI ("YPF Añelo").
  final String nombre;

  /// Tipo de geometría: círculo (centro + radio) o polígono (vértices).
  final ZonaShape shape;

  /// Centro del círculo. Sólo si `shape == circulo`.
  final LatLngPunto? centro;

  /// Radio en metros. Sólo si `shape == circulo`.
  final double? radioMts;

  /// Vértices del polígono ordenados. Sólo si `shape == poligono`.
  /// Mínimo 3 puntos para formar un polígono cerrado.
  final List<LatLngPunto> vertices;

  /// Minutos mínimos que una unidad tiene que estar adentro para
  /// considerarse "en cola" (filtra unidades que sólo pasaron cerca).
  /// Default 5 min — ajustable por zona.
  final int estadiaMinMin;

  /// Si `false`, el poller la ignora (sin borrarla — útil para pausar
  /// una zona temporalmente sin perder configuración).
  final bool activo;

  /// Color hex sin `#` para el mapa (ej. "F44336" rojo). Opcional.
  final String? colorHex;

  /// Notas operativas opcionales ("zona descarga - no incluye
  /// estacionamiento de espera").
  final String? notas;

  final DateTime? creadoEn;
  final String? creadoPorDni;
  final DateTime? actualizadoEn;
  final String? actualizadoPorDni;

  const ZonaDescarga({
    required this.slug,
    required this.nombre,
    required this.shape,
    this.centro,
    this.radioMts,
    this.vertices = const [],
    this.estadiaMinMin = 5,
    this.activo = true,
    this.colorHex,
    this.notas,
    this.creadoEn,
    this.creadoPorDni,
    this.actualizadoEn,
    this.actualizadoPorDni,
  });

  /// Valida que la geometría sea consistente con el shape.
  /// Devuelve `null` si está OK o un mensaje de error legible.
  String? validar() {
    if (nombre.trim().isEmpty) return 'El nombre es obligatorio.';
    if (shape == ZonaShape.circulo) {
      if (centro == null) return 'Falta el centro del círculo.';
      if (radioMts == null || radioMts! <= 0) {
        return 'El radio debe ser > 0 metros.';
      }
      if (radioMts! > 10000) return 'Radio demasiado grande (máx 10 km).';
    } else {
      if (vertices.length < 3) {
        return 'El polígono necesita al menos 3 puntos.';
      }
    }
    if (estadiaMinMin < 1 || estadiaMinMin > 240) {
      return 'Estadía mínima debe estar entre 1 y 240 minutos.';
    }
    return null;
  }

  factory ZonaDescarga.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    final shape = ZonaShape.fromCodigo(m['shape']?.toString());
    final centroMap = m['centro'];
    final vertList = (m['vertices'] as List?) ?? const [];
    return ZonaDescarga(
      slug: (m['slug'] ?? doc.id).toString(),
      nombre: (m['nombre'] ?? '').toString(),
      shape: shape,
      centro: centroMap is Map
          ? LatLngPunto.fromMap(centroMap.cast<String, dynamic>())
          : null,
      radioMts: (m['radio_mts'] is num)
          ? (m['radio_mts'] as num).toDouble()
          : null,
      vertices: vertList
          .whereType<Map>()
          .map((v) => LatLngPunto.fromMap(v.cast<String, dynamic>()))
          .toList(),
      estadiaMinMin:
          (m['estadia_min_min'] is num) ? (m['estadia_min_min'] as num).toInt() : 5,
      activo: m['activo'] != false,
      colorHex: m['color_hex']?.toString(),
      notas: m['notas']?.toString(),
      creadoEn: (m['creado_en'] as Timestamp?)?.toDate(),
      creadoPorDni: m['creado_por_dni']?.toString(),
      actualizadoEn: (m['actualizado_en'] as Timestamp?)?.toDate(),
      actualizadoPorDni: m['actualizado_por_dni']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'slug': slug,
        'nombre': nombre,
        'shape': shape.codigo,
        if (centro != null) 'centro': centro!.toMap(),
        if (radioMts != null) 'radio_mts': radioMts,
        'vertices': vertices.map((v) => v.toMap()).toList(),
        'estadia_min_min': estadiaMinMin,
        'activo': activo,
        if (colorHex != null) 'color_hex': colorHex,
        if (notas != null) 'notas': notas,
      };
}
