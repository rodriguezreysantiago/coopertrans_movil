import 'package:cloud_firestore/cloud_firestore.dart';

/// Medio por el cual se le entregó el adelanto al chofer. Importante
/// para la auditoría del comprobante — el chofer firma el recibo
/// donde dice cómo recibió la plata. Default = efectivo (la mayoría
/// de los adelantos se dan en mano, decisión Santiago 2026-05-13).
enum MedioPagoAdelanto {
  efectivo('EFECTIVO', 'Efectivo'),
  transferencia('TRANSFERENCIA', 'Transferencia');

  final String codigo;
  final String etiqueta;
  const MedioPagoAdelanto(this.codigo, this.etiqueta);

  /// Parser tolerante para leer de Firestore. Default a `efectivo` si
  /// el campo no existe (adelantos pre-feature) o trae un código que
  /// no reconocemos.
  static MedioPagoAdelanto fromCodigo(String? raw) {
    if (raw == null) return MedioPagoAdelanto.efectivo;
    final t = raw.trim().toUpperCase();
    for (final m in MedioPagoAdelanto.values) {
      if (m.codigo == t) return m;
    }
    return MedioPagoAdelanto.efectivo;
  }
}

/// Un adelanto entregado a un chofer. Puede ser:
///   - Por un viaje específico (campo `viajeId` poblado).
///   - Adelanto de sueldo, sin viaje asociado (`viajeId == null`).
///
/// Caso de uso (Santiago 2026-05-13): muchos adelantos NO están atados
/// a un viaje — el chofer pide $50k a cuenta de sueldo y no hay un
/// viaje que justifique. Antes los adelantos vivían como subcampos del
/// `Viaje` (adelantoMonto/Fecha/Observación), pero eso forzaba crear
/// un viaje vacío para registrar un adelanto de sueldo. Ahora son una
/// colección propia.
///
/// **Numeración del comprobante**: si el operador imprime el
/// comprobante, se le asigna un correlativo del counter compartido
/// `COUNTERS/recibos_adelanto.next` (misma serie física que tenían los
/// recibos cuando vivían en Viaje — no se reinicia). Se asigna al
/// primer imprimir, no al crear, para no quemar correlativos en
/// adelantos borrados sin imprimir.
///
/// **LIQUIDACIÓN**: la pantalla suma los adelantos del chofer en el
/// rango (no por viaje). Si el adelanto tiene `viajeId`, sigue siendo
/// del rango — el campo es solo informativo para auditoría.
class AdelantoChofer {
  final String id;

  /// DNI del chofer al que se le entregó.
  final String choferDni;
  /// Nombre cacheado al momento de crear (snapshot — sobrevive si el
  /// chofer cambia de nombre / se da de baja).
  final String? choferNombre;

  /// Fecha del adelanto (entregado físicamente). NO es la fecha de
  /// creación del doc — esa va en `creadoEn`. La fecha la elige el
  /// operador con el date picker.
  final DateTime fecha;

  /// Monto entregado, en pesos. > 0.
  final double monto;

  /// Observación / concepto. Texto libre. Ejemplo: "combustible
  /// Bahía-Olavarría", "adelanto sueldo julio", "viáticos".
  final String? observacion;

  /// Cómo se le entregó al chofer (efectivo / transferencia). Aparece
  /// en el comprobante impreso. Default = efectivo.
  final MedioPagoAdelanto medioPago;

  /// Si el adelanto fue por un viaje específico, este campo apunta a
  /// `VIAJES_LOGISTICA/{viajeId}`. Si es de sueldo o sin viaje
  /// concreto, queda null. Opcional — el operador puede asociarlo o
  /// dejarlo libre.
  final String? viajeId;

  // ─── Comprobante impreso ─────────────────────────────────────────
  /// Número correlativo asignado al imprimir por primera vez. null si
  /// nunca se imprimió. Se reusa en reimpresiones — no se incrementa
  /// el counter dos veces.
  final int? numeroRecibo;
  /// Timestamp de la primera impresión. null si nunca se imprimió.
  final DateTime? impresoEn;

  // ─── Auditoría ───────────────────────────────────────────────────
  final DateTime? creadoEn;
  final String? creadoPorDni;
  final String? creadoPorNombre;
  final DateTime? actualizadoEn;
  final String? actualizadoPorDni;

  const AdelantoChofer({
    required this.id,
    required this.choferDni,
    this.choferNombre,
    required this.fecha,
    required this.monto,
    this.observacion,
    this.medioPago = MedioPagoAdelanto.efectivo,
    this.viajeId,
    this.numeroRecibo,
    this.impresoEn,
    this.creadoEn,
    this.creadoPorDni,
    this.creadoPorNombre,
    this.actualizadoEn,
    this.actualizadoPorDni,
  });

  factory AdelantoChofer.fromMap(String id, Map<String, dynamic> d) {
    return AdelantoChofer(
      id: id,
      choferDni: (d['chofer_dni'] ?? '').toString(),
      choferNombre: d['chofer_nombre']?.toString(),
      fecha: (d['fecha'] as Timestamp?)?.toDate() ?? DateTime.now(),
      monto: (d['monto'] as num?)?.toDouble() ?? 0,
      observacion: d['observacion']?.toString(),
      medioPago: MedioPagoAdelanto.fromCodigo(d['medio_pago']?.toString()),
      viajeId: d['viaje_id']?.toString(),
      numeroRecibo: (d['numero_recibo'] as num?)?.toInt(),
      impresoEn: (d['impreso_en'] as Timestamp?)?.toDate(),
      creadoEn: (d['creado_en'] as Timestamp?)?.toDate(),
      creadoPorDni: d['creado_por_dni']?.toString(),
      creadoPorNombre: d['creado_por_nombre']?.toString(),
      actualizadoEn: (d['actualizado_en'] as Timestamp?)?.toDate(),
      actualizadoPorDni: d['actualizado_por_dni']?.toString(),
    );
  }

  factory AdelantoChofer.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) =>
      AdelantoChofer.fromMap(doc.id, doc.data() ?? const {});
}
