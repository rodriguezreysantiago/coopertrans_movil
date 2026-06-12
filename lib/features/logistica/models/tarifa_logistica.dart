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

/// Una versión de la TARIFA REAL (lo que Vecchi le factura al cliente),
/// vigente a partir de [desde]. Línea de tiempo INDEPENDIENTE de la del
/// chofer (2026-06-11, pedido Santiago): la real y la chofer se negocian
/// por separado y cambian en fechas distintas. El dador (informativo) viaja
/// con la real por ser del lado ingreso.
///
/// El precio que se le aplica a un viaje se resuelve por la FECHA DE CARGA
/// del tramo (ver [TarifaLogistica.vigenteEn]).
class VigenciaReal {
  /// Fecha desde la que rige. SIEMPRE normalizada a día (medianoche local)
  /// para comparar de forma estable contra la fecha de carga sin que la zona
  /// horaria corra el límite un día.
  final DateTime desde;
  final double tarifaReal;

  /// Comisión del dador (informativa, no entra a ningún cálculo). Variable
  /// por carga. Mutuamente excluyente con [montoFijoDador].
  final double? porcentajeComisionDador;
  final double? montoFijoDador;

  /// Auditoría — client-time (`serverTimestamp()` no se permite dentro de
  /// elementos de un array).
  final DateTime? registradoEn;
  final String? registradoPorDni;

  VigenciaReal({
    required DateTime desde,
    required this.tarifaReal,
    this.porcentajeComisionDador,
    this.montoFijoDador,
    this.registradoEn,
    this.registradoPorDni,
  }) : desde = DateTime(desde.year, desde.month, desde.day);

  factory VigenciaReal.fromMap(Map<String, dynamic> d) {
    return VigenciaReal(
      desde: (d['desde'] as Timestamp?)?.toDate() ?? DateTime(2000),
      tarifaReal: (d['tarifa_real'] as num?)?.toDouble() ?? 0,
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
      if (porcentajeComisionDador != null)
        'porcentaje_comision_dador': porcentajeComisionDador,
      if (montoFijoDador != null) 'monto_fijo_dador': montoFijoDador,
      if (registradoEn != null)
        'registrado_en': Timestamp.fromDate(registradoEn!),
      if (registradoPorDni != null) 'registrado_por_dni': registradoPorDni,
    };
  }
}

/// Una versión del PAGO AL CHOFER (la base con la que se calcula lo que se
/// le paga), vigente a partir de [desde]. Línea de tiempo INDEPENDIENTE de
/// la real. El lado chofer tiene DOS modos mutuamente excluyentes: por unidad
/// ([tarifaChofer] × TN × 18%) o monto fijo por viaje ([montoFijoChofer]).
class VigenciaChofer {
  final DateTime desde;
  final double tarifaChofer;

  /// Monto fijo por viaje (override del 18%). Si != null, el chofer cobra
  /// este flat y [tarifaChofer] se ignora.
  final double? montoFijoChofer;

  final DateTime? registradoEn;
  final String? registradoPorDni;

  VigenciaChofer({
    required DateTime desde,
    required this.tarifaChofer,
    this.montoFijoChofer,
    this.registradoEn,
    this.registradoPorDni,
  }) : desde = DateTime(desde.year, desde.month, desde.day);

  factory VigenciaChofer.fromMap(Map<String, dynamic> d) {
    return VigenciaChofer(
      desde: (d['desde'] as Timestamp?)?.toDate() ?? DateTime(2000),
      tarifaChofer: (d['tarifa_chofer'] as num?)?.toDouble() ?? 0,
      montoFijoChofer: (d['monto_fijo_chofer'] as num?)?.toDouble(),
      registradoEn: (d['registrado_en'] as Timestamp?)?.toDate(),
      registradoPorDni: d['registrado_por_dni']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'desde': Timestamp.fromDate(desde),
      'tarifa_chofer': tarifaChofer,
      if (montoFijoChofer != null) 'monto_fijo_chofer': montoFijoChofer,
      if (registradoEn != null)
        'registrado_en': Timestamp.fromDate(registradoEn!),
      if (registradoPorDni != null) 'registrado_por_dni': registradoPorDni,
    };
  }
}

/// Los importes vigentes en una fecha dada — el resultado de componer la
/// VigenciaReal vigente + la VigenciaChofer vigente (ver
/// [TarifaLogistica.vigenteEn]). Reemplaza al `TarifaVigencia` único como
/// tipo de retorno: como real y chofer tienen líneas independientes, NO hay
/// un único `desde` — expone [desdeReal] y [desdeChofer] por separado.
///
/// Tiene los mismos getters de importe que el `TarifaVigencia` viejo
/// (`tarifaReal`/`tarifaChofer`/`montoFijoChofer`/`porcentajeComisionDador`/
/// `montoFijoDador`), por eso los consumidores que solo leen importes
/// (snapshot del viaje, mapa, lista, recálculo) no cambian.
class ImportesVigentes {
  final double tarifaReal;
  final double tarifaChofer;
  final double? montoFijoChofer;
  final double? porcentajeComisionDador;
  final double? montoFijoDador;

  /// Fecha desde la que rige la real / la chofer vigente. Las usa la UI de
  /// "Precio y vigencia"; el resto de los consumidores solo lee importes.
  final DateTime desdeReal;
  final DateTime desdeChofer;

  const ImportesVigentes({
    required this.tarifaReal,
    required this.tarifaChofer,
    this.montoFijoChofer,
    this.porcentajeComisionDador,
    this.montoFijoDador,
    required this.desdeReal,
    required this.desdeChofer,
  });
}

/// Una versión COMBINADA (real + chofer juntos en una fecha). Es el formato
/// de versionado VIEJO (2026-06, una sola línea de tiempo) que sigue VIVO en
/// producción: las apps publicadas antes del 2026-06-11 solo entienden el
/// array `vigencias`. Se conserva para (a) parsear tarifas guardadas con ese
/// formato (migración perezosa) y (b) DERIVAR un `vigencias` combinado fiel
/// al guardar, para que esas apps viejas sigan resolviendo el precio bien
/// (ver [TarifaLogistica.vigenciasCombinadas]).
class TarifaVigencia {
  final DateTime desde;
  final double tarifaReal;
  final double tarifaChofer;
  final double? montoFijoChofer;
  final double? porcentajeComisionDador;
  final double? montoFijoDador;
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
/// **Versionado por DOS vigencias independientes** (2026-06-11): el historial
/// de la real vive en [vigenciasReal] y el del chofer en [vigenciasChofer]
/// (cada una ordenada por `desde`). Se versionan por separado porque se
/// negocian y cambian en fechas distintas. Los campos planos (`tarifaReal`,
/// `tarifaChofer`, etc.) son un cache del precio vigente HOY al último write
/// — la UI usa [vigenteEn] (no los planos) para mostrar el precio correcto, y
/// los viajes snapshotean la versión que regía en su fecha de carga.
///
/// Migración perezosa en [fromMap]: tarifas con el formato viejo de UNA línea
/// (`vigencias` combinado, EN PRODUCCIÓN) se descomponen en las dos; tarifas
/// pre-versionado (sin nada) sintetizan 1 de cada desde los planos. [toMap]
/// escribe las dos líneas + un `vigencias` combinado derivado para compat con
/// apps viejas.
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
  /// carga, no es fijo por dador). Cache del vigente hoy — versionado en
  /// [vigenciasReal].
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

  /// Kilómetros del recorrido origen→destino (distancia del tramo). Identidad
  /// de la RUTA, no del precio → NO se versiona en las vigencias (un cambio de
  /// tarifa no cambia la distancia). Opcional (las tarifas viejas no lo traen):
  /// null = sin cargar. Lo carga el operador a mano y es el valor autoritativo
  /// de distancia; la lista solo estima por coordenadas/OSRM cuando esto es
  /// null. Entero en km.
  final int? km;

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
  /// comisión del 18%. Cache del vigente hoy — versionado en
  /// [vigenciasChofer].
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

  /// Historial de precios de la TARIFA REAL, ordenado ascendente por `desde`.
  /// Invariante: `fromMap` garantiza ≥1 (sintetiza desde los campos planos si
  /// el doc no la trae). Construcción directa puede dejarla vacía —
  /// [vigenteEn] es defensivo ante ese caso.
  final List<VigenciaReal> vigenciasReal;

  /// Historial de precios del PAGO AL CHOFER, ordenado ascendente por
  /// `desde`. Independiente de [vigenciasReal].
  final List<VigenciaChofer> vigenciasChofer;

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
    this.km,
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
    this.vigenciasReal = const [],
    this.vigenciasChofer = const [],
  });

  /// Diferencia bruta entre tarifa real y tarifa chofer (aproximación
  /// del margen ANTES de gastos como combustible, peajes, comisión del
  /// dador). El margen real se calcula en el módulo de viajes.
  double get diferenciaBruta => tarifaReal - tarifaChofer;

  /// Importes vigentes en [fecha] (típicamente la fecha de carga del tramo).
  /// Compone la VigenciaReal vigente + la VigenciaChofer vigente: cada lado
  /// se resuelve de forma independiente (puede haber subido la real el 1/3 y
  /// la chofer el 10/3). Defensivo: nunca null; sin vigencias cae a los campos
  /// planos. Robusto a desorden de las listas.
  ImportesVigentes vigenteEn(DateTime fecha) {
    final r = _realVigenteEn(fecha);
    final ch = _choferVigenteEn(fecha);
    return ImportesVigentes(
      tarifaReal: r.tarifaReal,
      porcentajeComisionDador: r.porcentajeComisionDador,
      montoFijoDador: r.montoFijoDador,
      tarifaChofer: ch.tarifaChofer,
      montoFijoChofer: ch.montoFijoChofer,
      desdeReal: r.desde,
      desdeChofer: ch.desde,
    );
  }

  /// VigenciaReal vigente en [fecha]. Defensivo: lista vacía → sintetiza de
  /// los planos. Ver [_elegirVigente] para la lógica de selección.
  VigenciaReal _realVigenteEn(DateTime fecha) {
    final f = DateTime(fecha.year, fecha.month, fecha.day);
    final v = _elegirVigente(vigenciasReal, f, (e) => e.desde);
    return v ??
        VigenciaReal(
          desde: DateTime(2000),
          tarifaReal: tarifaReal,
          porcentajeComisionDador: porcentajeComisionDador,
          montoFijoDador: montoFijoDador,
        );
  }

  /// VigenciaChofer vigente en [fecha]. Defensivo: lista vacía → sintetiza de
  /// los planos.
  VigenciaChofer _choferVigenteEn(DateTime fecha) {
    final f = DateTime(fecha.year, fecha.month, fecha.day);
    final v = _elegirVigente(vigenciasChofer, f, (e) => e.desde);
    return v ??
        VigenciaChofer(
          desde: DateTime(2000),
          tarifaChofer: tarifaChofer,
          montoFijoChofer: montoFijoChofer,
        );
  }

  /// Elige de [lista] el elemento con `desde` (vía [desdeDe]) más reciente que
  /// sea <= [f]. Si [f] es anterior a todos, devuelve el de `desde` más
  /// temprano (un viaje cargado antes del primer precio conocido usa el más
  /// viejo). Robusto a desorden. `null` solo si la lista está vacía.
  static T? _elegirVigente<T>(
    List<T> lista,
    DateTime f,
    DateTime Function(T) desdeDe,
  ) {
    if (lista.isEmpty) return null;
    T? elegida;
    for (final v in lista) {
      final d = desdeDe(v);
      if (!d.isAfter(f) &&
          (elegida == null || d.isAfter(desdeDe(elegida)))) {
        elegida = v;
      }
    }
    if (elegida != null) return elegida;
    var primera = lista.first;
    for (final v in lista) {
      if (desdeDe(v).isBefore(desdeDe(primera))) primera = v;
    }
    return primera;
  }

  /// Deriva la línea COMBINADA (real + chofer juntos por fecha) a partir de
  /// las dos líneas independientes. Para cada punto de quiebre (unión
  /// deduplicada de los `desde` de ambas listas) compone real-vigente +
  /// chofer-vigente en esa fecha. Reproduce EXACTO lo que el `vigenteEn` de
  /// una app vieja resolvería para cualquier fecha → se persiste como
  /// `vigencias` para compat (ver [toMap]).
  List<TarifaVigencia> vigenciasCombinadas() {
    final fechas = <DateTime>{
      ...vigenciasReal.map((v) => v.desde),
      ...vigenciasChofer.map((v) => v.desde),
    }.toList()
      ..sort();
    if (fechas.isEmpty) return const [];
    return fechas.map((f) {
      final r = _realVigenteEn(f);
      final ch = _choferVigenteEn(f);
      return TarifaVigencia(
        desde: f,
        tarifaReal: r.tarifaReal,
        tarifaChofer: ch.tarifaChofer,
        montoFijoChofer: ch.montoFijoChofer,
        porcentajeComisionDador: r.porcentajeComisionDador,
        montoFijoDador: r.montoFijoDador,
      );
    }).toList();
  }

  factory TarifaLogistica.fromMap(String id, Map<String, dynamic> d) {
    final (vReal, vChofer) = _parsearVigencias(d);
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
      km: (d['km'] as num?)?.toInt(),
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
      vigenciasReal: vReal,
      vigenciasChofer: vChofer,
    );
  }

  /// Parsea las dos líneas de vigencia del doc. Prioridad **(a) > (b) > (c)**:
  ///   (a) formato NUEVO (`vigencias_real` y/o `vigencias_chofer`) → directo
  ///       (si falta una de las dos, se sintetiza de los planos).
  ///   (b) formato VIEJO combinado (`vigencias`, EN PRODUCCIÓN) → se descompone
  ///       cada entrada en una VigenciaReal (real + dador) y una VigenciaChofer
  ///       (chofer + monto fijo), con el mismo `desde`.
  ///   (c) pre-versionado (sin nada) → sintetiza 1 de cada desde los planos.
  static (List<VigenciaReal>, List<VigenciaChofer>) _parsearVigencias(
    Map<String, dynamic> d,
  ) {
    final rawReal = d['vigencias_real'] as List?;
    final rawChofer = d['vigencias_chofer'] as List?;
    final hayReal = rawReal != null && rawReal.isNotEmpty;
    final hayChofer = rawChofer != null && rawChofer.isNotEmpty;
    if (hayReal || hayChofer) {
      // (a) — formato nuevo. La lista ausente (no debería pasar) se sintetiza.
      final real = hayReal
          ? (rawReal
              .map((v) => VigenciaReal.fromMap(Map<String, dynamic>.from(v as Map)))
              .toList()
            ..sort((a, b) => a.desde.compareTo(b.desde)))
          : [_realSinteticaDePlanos(d)];
      final chofer = hayChofer
          ? (rawChofer
              .map((v) =>
                  VigenciaChofer.fromMap(Map<String, dynamic>.from(v as Map)))
              .toList()
            ..sort((a, b) => a.desde.compareTo(b.desde)))
          : [_choferSinteticaDePlanos(d)];
      return (real, chofer);
    }
    final rawComb = d['vigencias'] as List?;
    if (rawComb != null && rawComb.isNotEmpty) {
      // (b) — formato viejo combinado: descomponer en las dos líneas.
      final comb = rawComb
          .map((v) => TarifaVigencia.fromMap(Map<String, dynamic>.from(v as Map)))
          .toList()
        ..sort((a, b) => a.desde.compareTo(b.desde));
      final real = comb
          .map((v) => VigenciaReal(
                desde: v.desde,
                tarifaReal: v.tarifaReal,
                porcentajeComisionDador: v.porcentajeComisionDador,
                montoFijoDador: v.montoFijoDador,
                registradoEn: v.registradoEn,
                registradoPorDni: v.registradoPorDni,
              ))
          .toList();
      final chofer = comb
          .map((v) => VigenciaChofer(
                desde: v.desde,
                tarifaChofer: v.tarifaChofer,
                montoFijoChofer: v.montoFijoChofer,
                registradoEn: v.registradoEn,
                registradoPorDni: v.registradoPorDni,
              ))
          .toList();
      return (real, chofer);
    }
    // (c) — pre-versionado: sintetizar 1 de cada desde los planos.
    return ([_realSinteticaDePlanos(d)], [_choferSinteticaDePlanos(d)]);
  }

  static VigenciaReal _realSinteticaDePlanos(Map<String, dynamic> d) {
    final desde = (d['vigente_desde'] as Timestamp?)?.toDate() ??
        (d['creado_en'] as Timestamp?)?.toDate() ??
        DateTime(2000);
    return VigenciaReal(
      desde: desde,
      tarifaReal: (d['tarifa_real'] as num?)?.toDouble() ?? 0,
      porcentajeComisionDador:
          (d['porcentaje_comision_dador'] as num?)?.toDouble(),
      montoFijoDador: (d['monto_fijo_dador'] as num?)?.toDouble(),
    );
  }

  static VigenciaChofer _choferSinteticaDePlanos(Map<String, dynamic> d) {
    final desde = (d['vigente_desde'] as Timestamp?)?.toDate() ??
        (d['creado_en'] as Timestamp?)?.toDate() ??
        DateTime(2000);
    return VigenciaChofer(
      desde: desde,
      tarifaChofer: (d['tarifa_chofer'] as num?)?.toDouble() ?? 0,
      montoFijoChofer: (d['monto_fijo_chofer'] as num?)?.toDouble(),
    );
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
      if (km != null) 'km': km,
      'flete': flete.codigo,
      'unidad_tarifa': unidadTarifa.codigo,
      'tarifa_real': tarifaReal,
      'tarifa_chofer': tarifaChofer,
      if (montoFijoChofer != null) 'monto_fijo_chofer': montoFijoChofer,
      if (producto != null) 'producto': producto,
      'activa': activa,
      if (notas != null) 'notas': notas,
      if (creadoPor != null) 'creado_por': creadoPor,
      // Dos líneas independientes (fuente de verdad).
      if (vigenciasReal.isNotEmpty)
        'vigencias_real': vigenciasReal.map((v) => v.toMap()).toList(),
      if (vigenciasChofer.isNotEmpty)
        'vigencias_chofer': vigenciasChofer.map((v) => v.toMap()).toList(),
      // Combinado derivado: compat con apps viejas (en producción) que solo
      // entienden `vigencias`. Reproduce el precio por fecha fielmente.
      if (vigenciasReal.isNotEmpty || vigenciasChofer.isNotEmpty)
        'vigencias': vigenciasCombinadas().map((v) => v.toMap()).toList(),
    };
  }
}
