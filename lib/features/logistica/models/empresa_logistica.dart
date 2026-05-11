import 'package:cloud_firestore/cloud_firestore.dart';

/// Tipo de empresa en el módulo Logística.
///
/// - [cliente]: empresa origen o destino del viaje (silo, planta,
///   puerto, fábrica). Paga el flete o lo recibe.
/// - [dadorTransporte]: otra empresa de transporte que tenía la carga
///   asignada y nos la cede. Cobra un % del flete (variable por carga).
enum TipoEmpresaLogistica {
  cliente('CLIENTE', 'Cliente'),
  dadorTransporte('DADOR_TRANSPORTE', 'Dador de transporte');

  final String codigo;
  final String etiqueta;
  const TipoEmpresaLogistica(this.codigo, this.etiqueta);

  static TipoEmpresaLogistica fromCodigo(String? codigo) {
    return TipoEmpresaLogistica.values.firstWhere(
      (t) => t.codigo == codigo,
      orElse: () => TipoEmpresaLogistica.cliente,
    );
  }
}

/// Empresa con la que Vecchi opera. Reusable: una misma empresa puede
/// figurar como origen, destino o dador en distintas tarifas.
///
/// `nombre` es la razón social formal (ej. "ACOPIO LARTIRIGOYEN SRL").
/// `apodo` es el nombre comercial / de fantasía con que se la conoce
/// día a día (ej. "Lartirigoyen"). Cuando hay apodo, el operador lo
/// reconoce más rápido — la UI muestra apodo en primer plano y
/// nombre en gris debajo. El apodo es opcional.
class EmpresaLogistica {
  final String id;
  final String nombre;
  final String? apodo;
  final TipoEmpresaLogistica tipo;
  final String? cuit;
  /// Teléfono de contacto (canónico `549...` para WhatsApp, mismo
  /// formato que EMPLEADOS.TELEFONO). Históricamente el campo se
  /// llamaba "contacto" — el nombre del field en Firestore se
  /// mantiene por compat, pero conceptualmente ya es solo teléfono.
  final String? contacto;
  /// Nombre de la persona a contactar — útil para saber "el
  /// teléfono X de Cargill es de Juan Pérez, no el operativo
  /// general". Texto libre.
  final String? nombreContacto;
  /// Productos que la empresa carga / despacha. Strings libres
  /// porque cada empresa los nombra a su manera ("Urea granulada",
  /// "Soja", "Aceite crudo"). Tarifas opcionalmente apuntan a un
  /// producto específico — la misma ruta puede tener tarifa distinta
  /// según el producto que se transporta.
  final List<String> productos;
  final bool activa;
  final DateTime? creadoEn;
  final String? creadoPor;

  const EmpresaLogistica({
    required this.id,
    required this.nombre,
    this.apodo,
    required this.tipo,
    this.cuit,
    this.contacto,
    this.nombreContacto,
    this.productos = const [],
    this.activa = true,
    this.creadoEn,
    this.creadoPor,
  });

  /// Texto principal a mostrar al operador. Apodo si existe, sino
  /// el nombre formal. Útil en cards y selectores.
  String get etiquetaPrincipal => apodo?.isNotEmpty == true ? apodo! : nombre;

  /// Texto secundario (subtítulo). Devuelve el nombre formal si hay
  /// apodo (porque el principal ya muestra el apodo), o null si no
  /// hay apodo (no hace falta repetir el nombre).
  String? get etiquetaSecundaria =>
      apodo?.isNotEmpty == true ? nombre : null;

  /// Construye una empresa desde el id + map de datos. Permite usar
  /// tanto el resultado de un stream (`QueryDocumentSnapshot`) como una
  /// lectura puntual (`DocumentSnapshot.data()`).
  factory EmpresaLogistica.fromMap(String id, Map<String, dynamic> d) {
    return EmpresaLogistica(
      id: id,
      nombre: (d['nombre'] ?? '').toString(),
      apodo: (d['apodo'] as String?)?.trim().isEmpty ?? true
          ? null
          : (d['apodo'] as String).trim(),
      tipo: TipoEmpresaLogistica.fromCodigo(d['tipo']?.toString()),
      cuit: (d['cuit'] as String?)?.trim().isEmpty ?? true
          ? null
          : (d['cuit'] as String).trim(),
      contacto: (d['contacto'] as String?)?.trim().isEmpty ?? true
          ? null
          : (d['contacto'] as String).trim(),
      nombreContacto: (d['nombre_contacto'] as String?)?.trim().isEmpty ?? true
          ? null
          : (d['nombre_contacto'] as String).trim(),
      productos: (d['productos'] is List)
          ? (d['productos'] as List)
              .map((p) => p?.toString().trim() ?? '')
              .where((s) => s.isNotEmpty)
              .toList()
          : const [],
      activa: d['activa'] != false,
      creadoEn: (d['creado_en'] as Timestamp?)?.toDate(),
      creadoPor: d['creado_por']?.toString(),
    );
  }

  factory EmpresaLogistica.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) =>
      EmpresaLogistica.fromMap(doc.id, doc.data());

  /// Map listo para `add()` o `set()`. Excluye `id` (lo gestiona
  /// Firestore) y `creado_en` (que se setea con `serverTimestamp`
  /// en el service).
  Map<String, dynamic> toMap() {
    return {
      'nombre': nombre,
      if (apodo != null) 'apodo': apodo,
      'tipo': tipo.codigo,
      if (cuit != null) 'cuit': cuit,
      if (contacto != null) 'contacto': contacto,
      if (nombreContacto != null) 'nombre_contacto': nombreContacto,
      if (productos.isNotEmpty) 'productos': productos,
      'activa': activa,
      if (creadoPor != null) 'creado_por': creadoPor,
    };
  }
}
