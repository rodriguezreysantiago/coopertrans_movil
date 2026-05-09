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
  completado('COMPLETADO', 'Completado'),
  cancelado('CANCELADO', 'Cancelado'),
  postergado('POSTERGADO', 'Postergado');

  final String codigo;
  final String etiqueta;
  const EstadoViaje(this.codigo, this.etiqueta);

  static EstadoViaje fromCodigo(String? codigo) {
    // Compat retro: 'PROGRAMADO' antiguo se mapea a planeado por si
    // hay docs viejos en Firestore (antes del rename 2026-05-09).
    if (codigo == 'PROGRAMADO') return EstadoViaje.planeado;
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
    };
  }
}

/// Un viaje real — la unidad operativa de Logística.
///
/// Ciclo: alta (PROGRAMADO) → carga (EN_CURSO) → descarga
/// (COMPLETADO) → liquidación. Si algo se cancela o posterga, el
/// estado refleja eso y el detalle queda para auditoría.
///
/// Soft-delete con `activo`. Eliminar un viaje setea `activo=false`
/// y agrega `borradoEn` + `borradoPorDni`. Las queries deben filtrar
/// por `activo` para no mostrar viajes borrados. Se conserva el
/// histórico para auditoría.
///
/// **NO se expone al chofer**: la información (tarifas, comisiones,
/// montos finales) es delicada operativamente. Decisión Santiago
/// 2026-05-09. Capability `verLogistica` (solo admin + supervisor).
class Viaje {
  final String id;

  // ─── Tarifa (referencia + snapshot) ───
  final String tarifaId;
  final TarifaSnapshot tarifaSnapshot;

  // ─── Asignaciones ───
  final String choferDni;
  final String? choferNombre;
  final String? vehiculoId;
  final String? engancheId;

  // ─── Estado ───
  final EstadoViaje estado;
  final String? motivoCancelacion;
  final DateTime? fechaPostergadoA;

  // ─── Carga ───
  final DateTime? fechaCarga;
  final double? kgCargados;

  // ─── Descarga ───
  final DateTime? fechaDescarga;
  final String? remitoNumero;
  final String? remitoUrl;
  final String? remitoPathStorage;
  final String? cargaTransportada;
  // kg_descargados se registra opcional para auditoría (cuánto llegó
  // efectivamente al destino). Pero el cálculo de monto se hace SOBRE
  // los kg cargados — decisión Santiago 2026-05-09.
  final double? kgDescargados;

  // ─── Adelanto ───
  final double? adelantoMonto;
  final DateTime? adelantoFecha;
  final String? adelantoObservacion;

  // ─── Gastos extraordinarios (a favor del chofer) ───
  final List<GastoViaje> gastos;

  // ─── Cálculos finales (snapshot — recomputados por el service al
  // crear/editar). Persistirlos evita recalcular en cada read y
  // garantiza coherencia con el monto que se le pagó al chofer aún
  // si la lógica de cálculo cambia más adelante.
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
    required this.tarifaId,
    required this.tarifaSnapshot,
    required this.choferDni,
    this.choferNombre,
    this.vehiculoId,
    this.engancheId,
    required this.estado,
    this.motivoCancelacion,
    this.fechaPostergadoA,
    this.fechaCarga,
    this.kgCargados,
    this.fechaDescarga,
    this.remitoNumero,
    this.remitoUrl,
    this.remitoPathStorage,
    this.cargaTransportada,
    this.kgDescargados,
    this.adelantoMonto,
    this.adelantoFecha,
    this.adelantoObservacion,
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

  factory Viaje.fromMap(String id, Map<String, dynamic> d) {
    final gastosRaw = d['gastos'] as List?;
    return Viaje(
      id: id,
      tarifaId: (d['tarifa_id'] ?? '').toString(),
      tarifaSnapshot: TarifaSnapshot.fromMap(
        Map<String, dynamic>.from(d['tarifa_snapshot'] as Map? ?? const {}),
      ),
      choferDni: (d['chofer_dni'] ?? '').toString(),
      choferNombre: d['chofer_nombre']?.toString(),
      vehiculoId: d['vehiculo_id']?.toString(),
      engancheId: d['enganche_id']?.toString(),
      estado: EstadoViaje.fromCodigo(d['estado']?.toString()),
      motivoCancelacion: d['motivo_cancelacion']?.toString(),
      fechaPostergadoA: (d['fecha_postergado_a'] as Timestamp?)?.toDate(),
      fechaCarga: (d['fecha_carga'] as Timestamp?)?.toDate(),
      kgCargados: (d['kg_cargados'] as num?)?.toDouble(),
      fechaDescarga: (d['fecha_descarga'] as Timestamp?)?.toDate(),
      remitoNumero: d['remito_numero']?.toString(),
      remitoUrl: d['remito_url']?.toString(),
      remitoPathStorage: d['remito_path_storage']?.toString(),
      cargaTransportada: d['carga_transportada']?.toString(),
      kgDescargados: (d['kg_descargados'] as num?)?.toDouble(),
      adelantoMonto: (d['adelanto_monto'] as num?)?.toDouble(),
      adelantoFecha: (d['adelanto_fecha'] as Timestamp?)?.toDate(),
      adelantoObservacion: d['adelanto_observacion']?.toString(),
      gastos: gastosRaw == null
          ? const []
          : gastosRaw
              .map((g) => GastoViaje.fromMap(Map<String, dynamic>.from(g as Map)))
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
