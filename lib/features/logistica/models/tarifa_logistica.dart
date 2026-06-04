import 'package:cloud_firestore/cloud_firestore.dart';

/// Tipo de carga: si la operación la cierra Vecchi directo o si nos la
/// derivó otra empresa de transporte (dador) que cobra una comisión.
enum TipoCargaLogistica {
  propia('PROPIA', 'Propia'),
  terceros('TERCEROS', 'Terceros (dador)');

  final String codigo;
  final String etiqueta;
  const TipoCargaLogistica(this.codigo, this.etiqueta);

  static TipoCargaLogistica fromCodigo(String? codigo) {
    return TipoCargaLogistica.values.firstWhere(
      (t) => t.codigo == codigo,
      orElse: () => TipoCargaLogistica.propia,
    );
  }
}

/// Quién paga el flete: el cargador (origen) o el receptor (destino).
/// Convención de transporte argentino — define dónde se factura.
enum FleteLogistica {
  origen('ORIGEN', 'Paga origen'),
  destino('DESTINO', 'Paga destino');

  final String codigo;
  final String etiqueta;
  const FleteLogistica(this.codigo, this.etiqueta);

  static FleteLogistica fromCodigo(String? codigo) {
    return FleteLogistica.values.firstWhere(
      (f) => f.codigo == codigo,
      orElse: () => FleteLogistica.origen,
    );
  }
}

/// Unidad sobre la que aplica la tarifa.
enum UnidadTarifa {
  porTonelada('TN', 'Por tonelada'),
  porViaje('VIAJE', 'Por viaje');

  final String codigo;
  final String etiqueta;
  const UnidadTarifa(this.codigo, this.etiqueta);

  static UnidadTarifa fromCodigo(String? codigo) {
    return UnidadTarifa.values.firstWhere(
      (u) => u.codigo == codigo,
      orElse: () => UnidadTarifa.porTonelada,
    );
  }

  /// Sufijo corto para mostrar después de un monto. Ej. "$ 4.500/TN".
  String get sufijoMonto => codigo == 'TN' ? '/TN' : '/viaje';
}

/// Una versión de los IMPORTES de una tarifa, vigente a partir de [desde].
///
/// Versionado de tarifas (2026-06, pedido Santiago): cubre SOLO los
/// importes. La ruta, el dador, las empresas, el producto y la unidad son
/// identidad de la tarifa — si cambian, es otra tarifa, no una versión.
/// Cada cambio de precio registra una vigencia nueva con la fecha desde la
/// que rige; la anterior queda en el historial. El precio que se le aplica
/// a un viaje se resuelve por la FECHA DE CARGA del tramo (ver
/// [TarifaLogistica.vigenteEn]).
class TarifaVigencia {
  /// Fecha desde la que rige esta versión. SIEMPRE normalizada a día
  /// (medianoche local, sin hora) para comparar de forma estable contra
  /// la fecha de carga del tramo sin que la zona horaria corra el límite
  /// un día (la carga la pone el operador en hora local AR).
  final DateTime desde;
  final double tarifaReal;
  final double tarifaChofer;
  final double? montoFijoChofer;
  final double? porcentajeComisionDador;
  final double? montoFijoDador;

  /// Auditoría — cuándo y quién registró esta vigencia. Es client-time:
  /// `serverTimestamp()` no se permite dentro de elementos de un array.
  final DateTime? registradoEn;
  final String? registradoPorDni;

  TarifaVigencia({
    required DateTime desde,
    required this.tarifaReal,
    required this.tarifaChofer,
    this.montoFijoChofer,
    this.porcentajeComisionDador,
    this.montoFijoDador,
    this.registradoEn,
    this.registradoPorDni,
  }) : desde = DateTime(desde.year, desde.month, desde.day);

  factory TarifaVigencia.fromMap(Map<String, dynamic> d) {
    return TarifaVigencia(
      desde: (d['desde'] as Timestamp?)?.toDate() ?? DateTime(2000),
      tarifaReal: (d['tarifa_real'] as num?)?.toDouble() ?? 0,
      tarifaChofer: (d['tarifa_chofer'] as num?)?.toDouble() ?? 0,
      montoFijoChofer: (d['monto_fijo_chofer'] as num?)?.toDouble(),
      porcentajeComisionDador:
          (d['porcentaje_comision_dador'] as num?)?.toDouble(),
      montoFijoDador: (d['monto_fijo_dador'] as num?)?.toDouble(),
      registradoEn: (d['registrado_en'] as Timestamp?)?.toDate(),
      registradoPorDni: d['registrado_por_dni']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'desde': Timestamp.fromDate(desde),
      'tarifa_real': tarifaReal,
      'tarifa_chofer': tarifaChofer,
      if (montoFijoChofer != null) 'monto_fijo_chofer': montoFijoChofer,
      if (porcentajeComisionDador != null)
        'porcentaje_comision_dador': porcentajeComisionDador,
      if (montoFijoDador != null) 'monto_fijo_dador': montoFijoDador,
      if (registradoEn != null)
        'registrado_en': Timestamp.fromDate(registradoEn!),
      if (registradoPorDni != null) 'registrado_por_dni': registradoPorDni,
    };
  }
}

/// Tarifa de viaje — el corazón del módulo Logística. Cada doc es una
/// "ruta con precio" para un caso operativo concreto.
///
/// Doble tarifa por diseño:
///   - `tarifaReal`: lo que cobra Vecchi al cliente final.
///   - `tarifaChofer`: lo que se le paga al chofer que conduce.
///
/// **Versionado por vigencia** (2026-06): el historial de precios vive en
/// [vigencias] (lista ordenada por `desde`). Los campos planos
/// (`tarifaReal`, `tarifaChofer`, etc.) son un cache del precio vigente HOY
/// al último write — la UI usa [vigenteEn] (no los planos) para mostrar el
/// precio correcto, y los viajes snapshotean la versión que regía en su
/// fecha de carga. Tarifas creadas antes del versionado sintetizan 1
/// vigencia desde los campos planos (migración perezosa en [fromMap]).
class TarifaLogistica {
  final String id;
  final TipoCargaLogistica tipoCarga;

  /// ID del dador de transporte (`EMPRESAS_LOGISTICA` con
  /// `tipo=DADOR_TRANSPORTE`). Solo se usa cuando `tipoCarga=TERCEROS`.
  final String? dadorId;

  /// Snapshot del nombre del dador al momento de crear la tarifa —
  /// permite mostrar listas sin un round-trip extra a `EMPRESAS_LOGISTICA`.
  final String? dadorNombre;

  /// Porcentaje del flete que se lleva el dador (0–100). Variable por
  /// carga (decisión Vecchi 2026-05-07: depende de la calidad de la
  /// carga, no es fijo por dador).
  final double? porcentajeComisionDador;

  /// Monto FIJO por viaje del dador, alternativa al
  /// `porcentajeComisionDador`. Pedido Santiago 2026-05-21 (caso
  /// GASPERINI: nos brinda viajes con un monto fijo por viaje en lugar de
  /// un % del flete). Mutuamente excluyente con el %: si está seteado, la
  /// comisión del dador es ese monto flat por viaje.
  final double? montoFijoDador;

  // Origen: empresa + ubicación (refs a EMPRESAS_LOGISTICA y
  // UBICACIONES_LOGISTICA) + snapshots para listas rápidas.
  final String empresaOrigenId;
  final String empresaOrigenNombre;
  final String ubicacionOrigenId;
  final String ubicacionOrigenEtiqueta;

  // Destino.
  final String empresaDestinoId;
  final String empresaDestinoNombre;
  final String ubicacionDestinoId;
  final String ubicacionDestinoEtiqueta;

  /// Etiqueta de ubicación origen sin los paréntesis al final ni del
  /// medio. La etiqueta cruda del catálogo viene con la localidad
  /// anexa entre paréntesis (ej. "BAHIA BLANCA - PROFERTIL (BAHIA
  /// BLANCA)") — info útil para distinguir ubicaciones homónimas en
  /// el ABM, pero ruidosa en las vistas de tarifa donde Santiago ya
  /// sabe qué planta es. Pedido 2026-05-28.
  String get ubicacionOrigenLimpia => _stripParentesis(ubicacionOrigenEtiqueta);
  String get ubicacionDestinoLimpia =>
      _stripParentesis(ubicacionDestinoEtiqueta);

  /// Etiqueta de origen lista para mostrar: `"<ubicación> (<empresa>)"`
  /// EXCEPTO si la ubicación ya contiene el nombre de la empresa (caso
  /// típico: ubicación "PROFERTIL (BAHIA BLANCA)" + empresa
  /// "PROFERTIL" → mostrar solo "PROFERTIL (BAHIA BLANCA)" sin
  /// duplicar). Misma lógica que `TarifaSnapshot.origenDisplay` —
  /// duplicado para mantener cada modelo autocontenido.
  ///
  /// Usa la versión limpia (sin paréntesis de localidad), así el
  /// dedup con la empresa queda consistente y no se ve la localidad
  /// duplicada cuando esta coincide con el nombre de la empresa.
  String get origenDisplay =>
      _displayUbicacionConEmpresa(ubicacionOrigenLimpia, empresaOrigenNombre);

  /// Versión "display" de destino, misma lógica que [origenDisplay].
  String get destinoDisplay =>
      _displayUbicacionConEmpresa(ubicacionDestinoLimpia, empresaDestinoNombre);

  static String _displayUbicacionConEmpresa(
    String ubicacion,
    String empresa,
  ) {
    final u = ubicacion.trim();
    final e = empresa.trim();
    if (e.isEmpty) return u;
    return u.toUpperCase().contains(e.toUpperCase()) ? u : '$u ($e)';
  }

  /// Saca cualquier "(...)" de la etiqueta. Útil para vistas compactas
  /// donde la localidad anexa entre paréntesis no aporta info nueva
  /// (típico: "BAHIA BLANCA - PROFERTIL (BAHIA BLANCA)" → "BAHIA
  /// BLANCA - PROFERTIL"). Conserva el resto del texto y trimea
  /// dobles espacios que pudieron quedar.
  static String _stripParentesis(String s) => s
      .replaceAll(RegExp(r'\s*\([^)]*\)\s*'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  final FleteLogistica flete;
  final UnidadTarifa unidadTarifa;
  final double tarifaReal;
  final double tarifaChofer;

  /// Monto fijo POR VIAJE para el chofer, alternativa al cálculo
  /// `tarifaChofer × TN × 18%`. Si no es null, ese monto se paga al
  /// chofer FLAT, sin importar cuántas TN cargue y sin aplicar la
  /// comisión del 18%.
  ///
  /// Pedido Santiago 2026-05-19: "hay veces que les asignamos viajes
  /// cortos que se les paga un poco más que el 18%". El operador puede
  /// dejar este campo configurado en la tarifa para que los viajes
  /// cortos calculen automáticamente con el monto acordado.
  ///
  /// Si null → comportamiento legacy (porcentaje sobre tarifaChofer).
  /// En el form del viaje también se puede overridear puntualmente
  /// vía `TarifaSnapshot.montoFijoChofer` sin tocar la tarifa origen.
  final double? montoFijoChofer;

  /// Producto que se transporta (snapshot del nombre del catálogo de
  /// productos de la empresa origen). Opcional — si dos productos
  /// distintos cobran lo mismo, una sola tarifa cubre ambos sin
  /// especificar este campo. Si difiere, son tarifas distintas con
  /// `producto` distinto. Decisión Vecchi 2026-05-08.
  final String? producto;
  final DateTime? vigenteDesde;
  final bool activa;
  final String? notas;
  final DateTime? creadoEn;
  final String? creadoPor;

  /// Historial de precios, ordenado ascendente por `desde`. Invariante:
  /// `fromMap` garantiza ≥1 (sintetiza desde los campos planos si el doc
  /// no la trae). Construcción directa puede dejarla vacía — [vigenteEn]
  /// es defensivo ante ese caso.
  final List<TarifaVigencia> vigencias;

  const TarifaLogistica({
    required this.id,
    required this.tipoCarga,
    this.dadorId,
    this.dadorNombre,
    this.porcentajeComisionDador,
    this.montoFijoDador,
    required this.empresaOrigenId,
    required this.empresaOrigenNombre,
    required this.ubicacionOrigenId,
    required this.ubicacionOrigenEtiqueta,
    required this.empresaDestinoId,
    required this.empresaDestinoNombre,
    required this.ubicacionDestinoId,
    required this.ubicacionDestinoEtiqueta,
    required this.flete,
    required this.unidadTarifa,
    required this.tarifaReal,
    required this.tarifaChofer,
    this.montoFijoChofer,
    this.producto,
    this.vigenteDesde,
    this.activa = true,
    this.notas,
    this.creadoEn,
    this.creadoPor,
    this.vigencias = const [],
  });

  /// Diferencia bruta entre tarifa real y tarifa chofer (aproximación
  /// del margen ANTES de gastos como combustible, peajes, comisión del
  /// dador). El margen real se calcula en el módulo de viajes.
  double get diferenciaBruta => tarifaReal - tarifaChofer;

  /// Importes vigentes en [fecha] (típicamente la fecha de carga del
  /// tramo). Devuelve la vigencia con `desde` más reciente que sea
  /// <= [fecha]. Si [fecha] es anterior a la primera vigencia, devuelve la
  /// primera (un viaje cargado antes del primer precio conocido usa el más
  /// viejo). Defensivo: nunca null; si no hubiera vigencias, cae a una
  /// sintetizada de los campos planos. Robusto a desorden de la lista.
  TarifaVigencia vigenteEn(DateTime fecha) {
    final f = DateTime(fecha.year, fecha.month, fecha.day);
    if (vigencias.isEmpty) {
      return TarifaVigencia(
        desde: DateTime(2000),
        tarifaReal: tarifaReal,
        tarifaChofer: tarifaChofer,
        montoFijoChofer: montoFijoChofer,
        porcentajeComisionDador: porcentajeComisionDador,
        montoFijoDador: montoFijoDador,
      );
    }
    TarifaVigencia? elegida;
    for (final v in vigencias) {
      if (!v.desde.isAfter(f) &&
          (elegida == null || v.desde.isAfter(elegida.desde))) {
        elegida = v;
      }
    }
    if (elegida != null) return elegida;
    // fecha anterior a todas las vigencias → la más temprana.
    var primera = vigencias.first;
    for (final v in vigencias) {
      if (v.desde.isBefore(primera.desde)) primera = v;
    }
    return primera;
  }

  factory TarifaLogistica.fromMap(String id, Map<String, dynamic> d) {
    return TarifaLogistica(
      id: id,
      tipoCarga: TipoCargaLogistica.fromCodigo(d['tipo_carga']?.toString()),
      dadorId: d['dador_id']?.toString(),
      dadorNombre: d['dador_nombre']?.toString(),
      porcentajeComisionDador:
          (d['porcentaje_comision_dador'] as num?)?.toDouble(),
      montoFijoDador: (d['monto_fijo_dador'] as num?)?.toDouble(),
      empresaOrigenId: (d['empresa_origen_id'] ?? '').toString(),
      empresaOrigenNombre: (d['empresa_origen_nombre'] ?? '').toString(),
      ubicacionOrigenId: (d['ubicacion_origen_id'] ?? '').toString(),
      ubicacionOrigenEtiqueta:
          (d['ubicacion_origen_etiqueta'] ?? '').toString(),
      empresaDestinoId: (d['empresa_destino_id'] ?? '').toString(),
      empresaDestinoNombre: (d['empresa_destino_nombre'] ?? '').toString(),
      ubicacionDestinoId: (d['ubicacion_destino_id'] ?? '').toString(),
      ubicacionDestinoEtiqueta:
          (d['ubicacion_destino_etiqueta'] ?? '').toString(),
      flete: FleteLogistica.fromCodigo(d['flete']?.toString()),
      unidadTarifa: UnidadTarifa.fromCodigo(d['unidad_tarifa']?.toString()),
      tarifaReal: (d['tarifa_real'] as num?)?.toDouble() ?? 0,
      tarifaChofer: (d['tarifa_chofer'] as num?)?.toDouble() ?? 0,
      montoFijoChofer: (d['monto_fijo_chofer'] as num?)?.toDouble(),
      producto: (d['producto'] as String?)?.trim().isEmpty ?? true
          ? null
          : (d['producto'] as String).trim(),
      vigenteDesde: (d['vigente_desde'] as Timestamp?)?.toDate(),
      activa: d['activa'] != false,
      notas: (d['notas'] as String?)?.trim().isEmpty ?? true
          ? null
          : (d['notas'] as String).trim(),
      creadoEn: (d['creado_en'] as Timestamp?)?.toDate(),
      creadoPor: d['creado_por']?.toString(),
      vigencias: _parsearVigencias(d),
    );
  }

  /// Parsea [vigencias] del doc ordenadas asc por `desde`. Si el doc no las
  /// trae (tarifa anterior al versionado 2026-06), sintetiza UNA desde los
  /// campos planos — migración perezosa, sin script.
  static List<TarifaVigencia> _parsearVigencias(Map<String, dynamic> d) {
    final raw = d['vigencias'] as List?;
    if (raw != null && raw.isNotEmpty) {
      return raw
          .map((v) =>
              TarifaVigencia.fromMap(Map<String, dynamic>.from(v as Map)))
          .toList()
        ..sort((a, b) => a.desde.compareTo(b.desde));
    }
    final desde = (d['vigente_desde'] as Timestamp?)?.toDate() ??
        (d['creado_en'] as Timestamp?)?.toDate() ??
        DateTime(2000);
    return [
      TarifaVigencia(
        desde: desde,
        tarifaReal: (d['tarifa_real'] as num?)?.toDouble() ?? 0,
        tarifaChofer: (d['tarifa_chofer'] as num?)?.toDouble() ?? 0,
        montoFijoChofer: (d['monto_fijo_chofer'] as num?)?.toDouble(),
        porcentajeComisionDador:
            (d['porcentaje_comision_dador'] as num?)?.toDouble(),
        montoFijoDador: (d['monto_fijo_dador'] as num?)?.toDouble(),
      ),
    ];
  }

  factory TarifaLogistica.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) =>
      TarifaLogistica.fromMap(doc.id, doc.data());

  Map<String, dynamic> toMap() {
    return {
      'tipo_carga': tipoCarga.codigo,
      if (dadorId != null) 'dador_id': dadorId,
      if (dadorNombre != null) 'dador_nombre': dadorNombre,
      if (porcentajeComisionDador != null)
        'porcentaje_comision_dador': porcentajeComisionDador,
      if (montoFijoDador != null) 'monto_fijo_dador': montoFijoDador,
      'empresa_origen_id': empresaOrigenId,
      'empresa_origen_nombre': empresaOrigenNombre,
      'ubicacion_origen_id': ubicacionOrigenId,
      'ubicacion_origen_etiqueta': ubicacionOrigenEtiqueta,
      'empresa_destino_id': empresaDestinoId,
      'empresa_destino_nombre': empresaDestinoNombre,
      'ubicacion_destino_id': ubicacionDestinoId,
      'ubicacion_destino_etiqueta': ubicacionDestinoEtiqueta,
      'flete': flete.codigo,
      'unidad_tarifa': unidadTarifa.codigo,
      'tarifa_real': tarifaReal,
      'tarifa_chofer': tarifaChofer,
      if (montoFijoChofer != null) 'monto_fijo_chofer': montoFijoChofer,
      if (producto != null) 'producto': producto,
      'activa': activa,
      if (notas != null) 'notas': notas,
      if (creadoPor != null) 'creado_por': creadoPor,
      if (vigencias.isNotEmpty)
        'vigencias': vigencias.map((v) => v.toMap()).toList(),
    };
  }
}
