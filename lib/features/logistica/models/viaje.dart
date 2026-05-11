import 'package:cloud_firestore/cloud_firestore.dart';

import 'tarifa_logistica.dart';

/// Estado del ciclo de vida de un viaje. Transiciones esperadas:
///   PLANEADO  → EN_CURSO  → COMPLETADO
///                 ↓
///              CANCELADO  (por evento climático, mecánico, etc.)
///                 ↓
///              POSTERGADO (con `fechaPostergadoA` para reanudar)
///
/// PLANEADO es el default al crear: el viaje está en agenda pero
/// todavía no arrancó. Si por algún motivo no se realiza, pasa
/// directo a CANCELADO o POSTERGADO sin pasar por EN_CURSO.
///
/// El estado lo cambia el admin / supervisor manualmente en el form.
/// No hay transiciones automáticas — el operador es el que sabe la
/// realidad operativa.
enum EstadoViaje {
  planeado('PLANEADO', 'Planeado'),
  enCurso('EN_CURSO', 'En curso'),
  // Antes 'COMPLETADO' (rename 2026-05-11). Significa: el viaje
  // terminó la operación física (carga + descarga). La liquidación
  // del viaje (pagar al chofer + cobrar a la empresa) se maneja en
  // la pantalla LIQUIDACION via el flag `liquidado`, NO desde acá.
  // Etiqueta visible "Concluido" — más natural en español operativo.
  concluido('CONCLUIDO', 'Concluido'),
  cancelado('CANCELADO', 'Cancelado'),
  postergado('POSTERGADO', 'Postergado');

  final String codigo;
  final String etiqueta;
  const EstadoViaje(this.codigo, this.etiqueta);

  static EstadoViaje fromCodigo(String? codigo) {
    // Compat retro:
    //   'PROGRAMADO' antiguo se mapea a planeado (rename 2026-05-09).
    //   'COMPLETADO' antiguo se mapea a concluido (rename 2026-05-11).
    if (codigo == 'PROGRAMADO') return EstadoViaje.planeado;
    if (codigo == 'COMPLETADO') return EstadoViaje.concluido;
    return EstadoViaje.values.firstWhere(
      (e) => e.codigo == codigo,
      orElse: () => EstadoViaje.planeado,
    );
  }
}

/// Un gasto extraordinario asociado al viaje (peaje, combustible,
/// comida del chofer, etc.). Lo paga el chofer y Vecchi se lo
/// reembolsa — suma a la liquidación final.
///
/// Decisión Santiago 2026-05-09: opción "A" (gastos a favor del
/// chofer). Si en el futuro hay gastos en contra (multas, daños),
/// se modela aparte con un campo `aFavorDe`.
class GastoViaje {
  final double monto;
  final String? detalle;
  final DateTime fecha;

  const GastoViaje({
    required this.monto,
    this.detalle,
    required this.fecha,
  });

  factory GastoViaje.fromMap(Map<String, dynamic> d) {
    return GastoViaje(
      monto: (d['monto'] as num?)?.toDouble() ?? 0,
      detalle: (d['detalle'] as String?)?.trim().isEmpty ?? true
          ? null
          : (d['detalle'] as String).trim(),
      fecha: (d['fecha'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'monto': monto,
      if (detalle != null) 'detalle': detalle,
      'fecha': Timestamp.fromDate(fecha),
    };
  }
}

/// Snapshot de la tarifa al momento de crear el viaje. Persistir el
/// snapshot (en lugar de solo `tarifaId`) garantiza que cambios
/// futuros en `TARIFAS_LOGISTICA` (precio, comisión dador) no
/// alteren la liquidación de viajes ya registrados.
class TarifaSnapshot {
  final String origenEtiqueta;
  final String destinoEtiqueta;
  final String empresaOrigenNombre;
  final String empresaDestinoNombre;
  final String? dadorNombre;
  final double? porcentajeComisionDador;
  final UnidadTarifa unidadTarifa;
  final double tarifaReal;
  final double tarifaChofer;
  final String? producto;
  /// ID de la empresa origen — necesario para poblar el dropdown de
  /// productos en el form de viaje (cada tramo usa la empresa origen
  /// de su tarifa para mostrar los productos disponibles).
  final String? empresaOrigenId;

  const TarifaSnapshot({
    required this.origenEtiqueta,
    required this.destinoEtiqueta,
    required this.empresaOrigenNombre,
    required this.empresaDestinoNombre,
    this.dadorNombre,
    this.porcentajeComisionDador,
    required this.unidadTarifa,
    required this.tarifaReal,
    required this.tarifaChofer,
    this.producto,
    this.empresaOrigenId,
  });

  factory TarifaSnapshot.fromTarifa(TarifaLogistica t) {
    return TarifaSnapshot(
      origenEtiqueta: t.ubicacionOrigenEtiqueta,
      destinoEtiqueta: t.ubicacionDestinoEtiqueta,
      empresaOrigenNombre: t.empresaOrigenNombre,
      empresaDestinoNombre: t.empresaDestinoNombre,
      dadorNombre: t.dadorNombre,
      porcentajeComisionDador: t.porcentajeComisionDador,
      unidadTarifa: t.unidadTarifa,
      tarifaReal: t.tarifaReal,
      tarifaChofer: t.tarifaChofer,
      producto: t.producto,
      empresaOrigenId: t.empresaOrigenId,
    );
  }

  factory TarifaSnapshot.fromMap(Map<String, dynamic> d) {
    return TarifaSnapshot(
      origenEtiqueta: (d['origen_etiqueta'] ?? '').toString(),
      destinoEtiqueta: (d['destino_etiqueta'] ?? '').toString(),
      empresaOrigenNombre: (d['empresa_origen_nombre'] ?? '').toString(),
      empresaDestinoNombre: (d['empresa_destino_nombre'] ?? '').toString(),
      dadorNombre: d['dador_nombre']?.toString(),
      porcentajeComisionDador:
          (d['porcentaje_comision_dador'] as num?)?.toDouble(),
      unidadTarifa: UnidadTarifa.fromCodigo(d['unidad_tarifa']?.toString()),
      tarifaReal: (d['tarifa_real'] as num?)?.toDouble() ?? 0,
      tarifaChofer: (d['tarifa_chofer'] as num?)?.toDouble() ?? 0,
      producto: d['producto']?.toString(),
      empresaOrigenId: d['empresa_origen_id']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'origen_etiqueta': origenEtiqueta,
      'destino_etiqueta': destinoEtiqueta,
      'empresa_origen_nombre': empresaOrigenNombre,
      'empresa_destino_nombre': empresaDestinoNombre,
      if (dadorNombre != null) 'dador_nombre': dadorNombre,
      if (porcentajeComisionDador != null)
        'porcentaje_comision_dador': porcentajeComisionDador,
      'unidad_tarifa': unidadTarifa.codigo,
      'tarifa_real': tarifaReal,
      'tarifa_chofer': tarifaChofer,
      if (producto != null) 'producto': producto,
      if (empresaOrigenId != null) 'empresa_origen_id': empresaOrigenId,
    };
  }
}

/// Un tramo de un viaje — un par carga/descarga con su propia tarifa,
/// origen y destino. Un viaje puede tener 1+ tramos.
///
/// **Caso típico** (Santiago 2026-05-11): "el chofer sale de Bahía
/// Blanca hacia Olavarría con una carga, después vuelve a cargar en
/// Olavarría con otro destino, y otra carga; a veces hacen 3-4 cargas
/// y descargas en el mismo viaje físico". Cada uno de esos pares
/// carga-descarga es un **tramo**.
///
/// Por tramo: tarifa propia, fechas propias, kg propios, remito
/// propio, producto propio. Lo que se comparte entre tramos del
/// mismo viaje es: chofer, unidad, adelanto, gastos extraordinarios,
/// estado, liquidación.
///
/// **El primer tramo define la fecha de referencia del viaje** —
/// usada para el filtro mensual de LIQUIDACIÓN. Si un viaje carga
/// el 30/06 y descarga el 02/07, queda computado en JUNIO.
class TramoViaje {
  /// Identificador local del tramo dentro del viaje. Útil para los
  /// keys de Flutter al editar la lista. Se genera al construir un
  /// tramo nuevo (`DateTime.now().microsecondsSinceEpoch.toString()`).
  /// NO se usa como path en Firestore — el array se persiste por
  /// índice.
  final String id;

  // ─── Tarifa (referencia + snapshot) ───
  final String tarifaId;
  final TarifaSnapshot tarifaSnapshot;

  // ─── Producto cargado (dropdown de productos de empresa origen) ──
  /// Producto cargado en este tramo, elegido del dropdown poblado
  /// con `EMPRESAS_LOGISTICA/{empresaOrigenId}.productos`. Si es
  /// null, todavía no se eligió.
  final String? producto;
  /// Texto libre adicional sobre la carga ("descripción de la carga").
  /// Opcional — el producto del dropdown suele alcanzar.
  final String? descripcionCarga;

  // ─── Carga ───
  final DateTime? fechaCarga;
  final double? kgCargados;

  // ─── Descarga ───
  final DateTime? fechaDescarga;
  final String? remitoNumero;
  final String? remitoUrl;
  final String? remitoPathStorage;
  final double? kgDescargados;

  const TramoViaje({
    required this.id,
    required this.tarifaId,
    required this.tarifaSnapshot,
    this.producto,
    this.descripcionCarga,
    this.fechaCarga,
    this.kgCargados,
    this.fechaDescarga,
    this.remitoNumero,
    this.remitoUrl,
    this.remitoPathStorage,
    this.kgDescargados,
  });

  /// Genera un tramo nuevo vacío con id local generado. Para la UI
  /// cuando el operador toca "+ AGREGAR TRAMO".
  factory TramoViaje.nuevo({
    required String tarifaId,
    required TarifaSnapshot tarifaSnapshot,
  }) {
    return TramoViaje(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      tarifaId: tarifaId,
      tarifaSnapshot: tarifaSnapshot,
    );
  }

  factory TramoViaje.fromMap(Map<String, dynamic> d) {
    return TramoViaje(
      id: (d['id'] ?? DateTime.now().microsecondsSinceEpoch.toString())
          .toString(),
      tarifaId: (d['tarifa_id'] ?? '').toString(),
      tarifaSnapshot: TarifaSnapshot.fromMap(
        Map<String, dynamic>.from(d['tarifa_snapshot'] as Map? ?? const {}),
      ),
      producto: d['producto']?.toString(),
      descripcionCarga: d['descripcion_carga']?.toString(),
      fechaCarga: (d['fecha_carga'] as Timestamp?)?.toDate(),
      kgCargados: (d['kg_cargados'] as num?)?.toDouble(),
      fechaDescarga: (d['fecha_descarga'] as Timestamp?)?.toDate(),
      remitoNumero: d['remito_numero']?.toString(),
      remitoUrl: d['remito_url']?.toString(),
      remitoPathStorage: d['remito_path_storage']?.toString(),
      kgDescargados: (d['kg_descargados'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tarifa_id': tarifaId,
      'tarifa_snapshot': tarifaSnapshot.toMap(),
      if (producto != null) 'producto': producto,
      if (descripcionCarga != null) 'descripcion_carga': descripcionCarga,
      if (fechaCarga != null) 'fecha_carga': Timestamp.fromDate(fechaCarga!),
      if (kgCargados != null) 'kg_cargados': kgCargados,
      if (fechaDescarga != null)
        'fecha_descarga': Timestamp.fromDate(fechaDescarga!),
      if (remitoNumero != null) 'remito_numero': remitoNumero,
      if (remitoUrl != null) 'remito_url': remitoUrl,
      if (remitoPathStorage != null)
        'remito_path_storage': remitoPathStorage,
      if (kgDescargados != null) 'kg_descargados': kgDescargados,
    };
  }

  TramoViaje copyWith({
    String? tarifaId,
    TarifaSnapshot? tarifaSnapshot,
    String? producto,
    String? descripcionCarga,
    DateTime? fechaCarga,
    double? kgCargados,
    DateTime? fechaDescarga,
    String? remitoNumero,
    String? remitoUrl,
    String? remitoPathStorage,
    double? kgDescargados,
    bool clearProducto = false,
    bool clearDescripcionCarga = false,
    bool clearFechaCarga = false,
    bool clearKgCargados = false,
    bool clearFechaDescarga = false,
    bool clearRemitoNumero = false,
    bool clearRemitoUrl = false,
    bool clearRemitoPathStorage = false,
    bool clearKgDescargados = false,
  }) {
    return TramoViaje(
      id: id,
      tarifaId: tarifaId ?? this.tarifaId,
      tarifaSnapshot: tarifaSnapshot ?? this.tarifaSnapshot,
      producto: clearProducto ? null : (producto ?? this.producto),
      descripcionCarga: clearDescripcionCarga
          ? null
          : (descripcionCarga ?? this.descripcionCarga),
      fechaCarga:
          clearFechaCarga ? null : (fechaCarga ?? this.fechaCarga),
      kgCargados:
          clearKgCargados ? null : (kgCargados ?? this.kgCargados),
      fechaDescarga: clearFechaDescarga
          ? null
          : (fechaDescarga ?? this.fechaDescarga),
      remitoNumero: clearRemitoNumero
          ? null
          : (remitoNumero ?? this.remitoNumero),
      remitoUrl: clearRemitoUrl ? null : (remitoUrl ?? this.remitoUrl),
      remitoPathStorage: clearRemitoPathStorage
          ? null
          : (remitoPathStorage ?? this.remitoPathStorage),
      kgDescargados: clearKgDescargados
          ? null
          : (kgDescargados ?? this.kgDescargados),
    );
  }
}

/// Un viaje real — la unidad operativa de Logística.
///
/// Compuesto por **uno o varios tramos** ([tramos]). Cada tramo es
/// un par carga/descarga con su propia tarifa, origen, destino y
/// remito. Lo compartido entre tramos: chofer, unidad, adelanto,
/// gastos, estado, liquidación.
///
/// Ciclo: alta (PLANEADO) → carga primer tramo (EN_CURSO) → descarga
/// último tramo (CONCLUIDO) → liquidación. Si algo se cancela o
/// posterga, el estado refleja eso y el detalle queda para auditoría.
///
/// Soft-delete con `activo`. Eliminar un viaje setea `activo=false`
/// y agrega `borradoEn` + `borradoPorDni`. Las queries deben filtrar
/// por `activo` para no mostrar viajes borrados.
///
/// **NO se expone al chofer**: la información (tarifas, comisiones,
/// montos finales) es delicada operativamente. Decisión Santiago
/// 2026-05-09. Capability `verLogistica` (solo admin + supervisor).
///
/// **Compat hacia atrás**: viajes creados antes del refactor
/// multi-tramo (≤ 1.0.43) tienen los campos planos (tarifa_id,
/// fecha_carga, kg_cargados, etc.) al nivel del doc y NO tienen
/// `tramos`. `Viaje.fromMap` detecta eso y construye automáticamente
/// 1 tramo único con esos campos. Los viajes nuevos persisten
/// `tramos: [...]` + denormalización de campos del PRIMER tramo al
/// nivel del doc para preservar queries existentes (filtros por
/// fecha_carga, etc.).
class Viaje {
  final String id;

  /// Lista de tramos. Garantía: siempre tiene al menos 1 elemento.
  final List<TramoViaje> tramos;

  // ─── Asignaciones (compartidas — del viaje, no del tramo) ───
  final String choferDni;
  final String? choferNombre;
  final String? vehiculoId;
  final String? engancheId;

  // ─── Estado ───
  final EstadoViaje estado;
  final String? motivoCancelacion;
  final DateTime? fechaPostergadoA;

  // ─── Adelanto (uno por viaje) ───
  final double? adelantoMonto;
  final DateTime? adelantoFecha;
  final String? adelantoObservacion;
  /// Número correlativo del comprobante impreso. Se asigna en la
  /// PRIMERA impresión del comprobante (RecibosAdelantoService),
  /// no al crear el viaje — para no quemar correlativos en viajes
  /// borrados sin imprimir. Si es `null`, todavía no se imprimió.
  /// Reimpresiones usan el mismo número (NO se re-incrementa el
  /// counter).
  final int? numeroReciboAdelanto;
  /// Timestamp de la primera impresión del comprobante. Útil para
  /// auditoría — si reimprimís, queda este original.
  final DateTime? reciboImpresoEn;

  // ─── Gastos extraordinarios (a favor del chofer) ───
  final List<GastoViaje> gastos;

  // ─── Cálculos finales (snapshot — recomputados por el service al
  // crear/editar). Persistirlos evita recalcular en cada read y
  // garantiza coherencia con el monto que se le pagó al chofer aún
  // si la lógica de cálculo cambia más adelante.
  // Para multi-tramo: estos son AGREGADOS — suma sobre todos los
  // tramos.
  final double montoVecchi;
  final double montoChofer;
  final double montoChoferRedondeado;
  final double comisionChoferPct;
  final double gastosTotal;
  final double liquidacionChofer;

  // ─── Liquidación ───
  final bool liquidado;
  final DateTime? liquidadoEn;
  final String? liquidadoPorDni;

  // ─── Auditoría ───
  final DateTime? creadoEn;
  final String? creadoPorDni;
  final String? creadoPorNombre;
  final DateTime? actualizadoEn;
  final String? actualizadoPorDni;

  // ─── Soft-delete ───
  final bool activo;
  final DateTime? borradoEn;
  final String? borradoPorDni;
  final String? motivoBorrado;

  const Viaje({
    required this.id,
    required this.tramos,
    required this.choferDni,
    this.choferNombre,
    this.vehiculoId,
    this.engancheId,
    required this.estado,
    this.motivoCancelacion,
    this.fechaPostergadoA,
    this.adelantoMonto,
    this.adelantoFecha,
    this.adelantoObservacion,
    this.numeroReciboAdelanto,
    this.reciboImpresoEn,
    this.gastos = const [],
    required this.montoVecchi,
    required this.montoChofer,
    required this.montoChoferRedondeado,
    required this.comisionChoferPct,
    required this.gastosTotal,
    required this.liquidacionChofer,
    this.liquidado = false,
    this.liquidadoEn,
    this.liquidadoPorDni,
    this.creadoEn,
    this.creadoPorDni,
    this.creadoPorNombre,
    this.actualizadoEn,
    this.actualizadoPorDni,
    this.activo = true,
    this.borradoEn,
    this.borradoPorDni,
    this.motivoBorrado,
  });

  // ─── Getters de conveniencia (denormalizan al primer/último tramo) ──

  /// Tramo principal (primer tramo). Garantizado existir.
  TramoViaje get tramoPrincipal => tramos.first;

  /// Tramo final (último tramo). Igual al principal si single-tramo.
  TramoViaje get tramoFinal => tramos.last;

  /// Cantidad de tramos del viaje.
  int get cantidadTramos => tramos.length;

  /// `true` si el viaje tiene 2 o más tramos.
  bool get esMultiTramo => tramos.length > 1;

  /// Fecha de referencia del viaje = fecha de carga del PRIMER tramo.
  /// Usada para filtro mensual en LIQUIDACIÓN y para sort en el
  /// listado de viajes. Si por alguna razón el primer tramo no tiene
  /// fecha de carga, fallback a `creadoEn`.
  DateTime? get fechaReferencia =>
      tramoPrincipal.fechaCarga ?? creadoEn;

  /// Etiqueta corta del origen-destino para listados:
  ///   - Single-tramo: "Bahía Blanca → Olavarría"
  ///   - Multi-tramo:  "Bahía Blanca → … → Tres Arroyos (3 tramos)"
  String get rutaEtiqueta {
    final origen = tramoPrincipal.tarifaSnapshot.origenEtiqueta;
    final destinoFinal = tramoFinal.tarifaSnapshot.destinoEtiqueta;
    if (!esMultiTramo) return '$origen → $destinoFinal';
    return '$origen → … → $destinoFinal ($cantidadTramos tramos)';
  }

  // ─── Compat hacia atrás: getters que mapean al PRIMER tramo ───
  // Permiten que código viejo (UIs no migradas) siga compilando
  // accediendo a viaje.fechaCarga, viaje.kgCargados, etc.

  String get tarifaId => tramoPrincipal.tarifaId;
  TarifaSnapshot get tarifaSnapshot => tramoPrincipal.tarifaSnapshot;
  DateTime? get fechaCarga => tramoPrincipal.fechaCarga;
  double? get kgCargados => tramoPrincipal.kgCargados;
  DateTime? get fechaDescarga => tramoFinal.fechaDescarga;
  String? get remitoNumero => tramoFinal.remitoNumero;
  String? get remitoUrl => tramoFinal.remitoUrl;
  String? get remitoPathStorage => tramoFinal.remitoPathStorage;
  String? get cargaTransportada =>
      tramoPrincipal.descripcionCarga ?? tramoPrincipal.producto;
  double? get kgDescargados => tramoFinal.kgDescargados;

  factory Viaje.fromMap(String id, Map<String, dynamic> d) {
    final gastosRaw = d['gastos'] as List?;
    final tramosRaw = d['tramos'] as List?;

    // ─── Tramos: nuevo modelo o compat ───
    final List<TramoViaje> tramos;
    if (tramosRaw != null && tramosRaw.isNotEmpty) {
      // Modelo nuevo (≥ 1.0.44).
      tramos = tramosRaw
          .map((t) =>
              TramoViaje.fromMap(Map<String, dynamic>.from(t as Map)))
          .toList();
    } else {
      // Compat: viaje viejo single-tramo con campos planos al nivel
      // del doc. Construimos 1 tramo único.
      tramos = [
        TramoViaje(
          id: '0',
          tarifaId: (d['tarifa_id'] ?? '').toString(),
          tarifaSnapshot: TarifaSnapshot.fromMap(
            Map<String, dynamic>.from(
              d['tarifa_snapshot'] as Map? ?? const {},
            ),
          ),
          producto: d['carga_transportada']?.toString(),
          descripcionCarga: d['carga_transportada']?.toString(),
          fechaCarga: (d['fecha_carga'] as Timestamp?)?.toDate(),
          kgCargados: (d['kg_cargados'] as num?)?.toDouble(),
          fechaDescarga: (d['fecha_descarga'] as Timestamp?)?.toDate(),
          remitoNumero: d['remito_numero']?.toString(),
          remitoUrl: d['remito_url']?.toString(),
          remitoPathStorage: d['remito_path_storage']?.toString(),
          kgDescargados: (d['kg_descargados'] as num?)?.toDouble(),
        ),
      ];
    }

    return Viaje(
      id: id,
      tramos: tramos,
      choferDni: (d['chofer_dni'] ?? '').toString(),
      choferNombre: d['chofer_nombre']?.toString(),
      vehiculoId: d['vehiculo_id']?.toString(),
      engancheId: d['enganche_id']?.toString(),
      estado: EstadoViaje.fromCodigo(d['estado']?.toString()),
      motivoCancelacion: d['motivo_cancelacion']?.toString(),
      fechaPostergadoA: (d['fecha_postergado_a'] as Timestamp?)?.toDate(),
      adelantoMonto: (d['adelanto_monto'] as num?)?.toDouble(),
      adelantoFecha: (d['adelanto_fecha'] as Timestamp?)?.toDate(),
      adelantoObservacion: d['adelanto_observacion']?.toString(),
      numeroReciboAdelanto: (d['numero_recibo_adelanto'] as num?)?.toInt(),
      reciboImpresoEn: (d['recibo_impreso_en'] as Timestamp?)?.toDate(),
      gastos: gastosRaw == null
          ? const []
          : gastosRaw
              .map((g) =>
                  GastoViaje.fromMap(Map<String, dynamic>.from(g as Map)))
              .toList(),
      montoVecchi: (d['monto_vecchi'] as num?)?.toDouble() ?? 0,
      montoChofer: (d['monto_chofer'] as num?)?.toDouble() ?? 0,
      montoChoferRedondeado:
          (d['monto_chofer_redondeado'] as num?)?.toDouble() ?? 0,
      comisionChoferPct: (d['comision_chofer_pct'] as num?)?.toDouble() ?? 18,
      gastosTotal: (d['gastos_total'] as num?)?.toDouble() ?? 0,
      liquidacionChofer: (d['liquidacion_chofer'] as num?)?.toDouble() ?? 0,
      liquidado: d['liquidado'] == true,
      liquidadoEn: (d['liquidado_en'] as Timestamp?)?.toDate(),
      liquidadoPorDni: d['liquidado_por_dni']?.toString(),
      creadoEn: (d['creado_en'] as Timestamp?)?.toDate(),
      creadoPorDni: d['creado_por_dni']?.toString(),
      creadoPorNombre: d['creado_por_nombre']?.toString(),
      actualizadoEn: (d['actualizado_en'] as Timestamp?)?.toDate(),
      actualizadoPorDni: d['actualizado_por_dni']?.toString(),
      activo: d['activo'] != false,
      borradoEn: (d['borrado_en'] as Timestamp?)?.toDate(),
      borradoPorDni: d['borrado_por_dni']?.toString(),
      motivoBorrado: d['motivo_borrado']?.toString(),
    );
  }

  factory Viaje.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Viaje.fromMap(doc.id, doc.data() ?? const {});
}
