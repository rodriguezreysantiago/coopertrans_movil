import 'package:cloud_firestore/cloud_firestore.dart';

/// Tipo de movimiento de stock del depósito de gomería. Cada movimiento
/// suma o resta cubiertas de un SKU (modelo + vida). El stock actual de un
/// SKU = suma de los `delta` de todos sus movimientos.
///
/// Modelo REDISEÑADO (2026-05-29): el stock se lleva por CANTIDADES, no por
/// cubiertas serializadas. El log de movimientos con responsable + el
/// inventario físico periódico dan el control anti-robo que pidió Santiago.
enum TipoMovimientoStock {
  /// Compra de cubiertas nuevas → entran al depósito (+).
  compra('COMPRA', 'Compra', 1),

  /// Se montó una del depósito en una posición (−).
  montaje('MONTAJE', 'Montaje', -1),

  /// Se retiró de una posición y volvió al depósito (+).
  retiroADeposito('RETIRO_A_DEPOSITO', 'Vuelve al depósito', 1),

  /// Salió del depósito al proveedor de recapado (−).
  aRecapado('A_RECAPADO', 'A recapar', -1),

  /// Volvió recapada del proveedor → entra al depósito con vida+1 (+).
  deRecapado('DE_RECAPADO', 'Vuelve de recapado', 1),

  /// Baja definitiva (−).
  descarte('DESCARTE', 'Descarte', -1),

  /// Corrección por conteo físico. El signo lo define el conteo (el `delta`
  /// del movimiento puede ser + o −), por eso su signo "natural" es 0.
  ajuste('AJUSTE', 'Ajuste de inventario', 0);

  final String codigo;
  final String etiqueta;

  /// Signo natural sobre el stock del depósito (+1 entra, −1 sale, 0 = el
  /// signo lo define el `delta` explícito, caso ajuste).
  final int signo;

  const TipoMovimientoStock(this.codigo, this.etiqueta, this.signo);

  static TipoMovimientoStock? fromCodigo(String? codigo) {
    if (codigo == null) return null;
    final c = codigo.toUpperCase().trim();
    for (final t in values) {
      if (t.codigo == c) return t;
    }
    return null;
  }
}

/// Un movimiento del stock de depósito. Inmutable (log). El `delta` es la
/// cantidad CON SIGNO ya aplicado (+ entra al depósito, − sale).
class StockMovimiento {
  final String id;
  final TipoMovimientoStock tipo;
  final String modeloId;
  final String modeloEtiqueta; // snapshot
  final int vida; // 1 = nueva, 2+ = recapada N
  final int delta; // con signo: + suma al depósito, − resta
  final DateTime fecha;
  final String responsableDni;
  final String? responsableNombre;
  final String? motivo;

  /// Si el movimiento es montaje/retiro: a qué unidad+posición fue/vino.
  final String? refUnidad;
  final String? refPosicion;

  const StockMovimiento({
    required this.id,
    required this.tipo,
    required this.modeloId,
    required this.modeloEtiqueta,
    required this.vida,
    required this.delta,
    required this.fecha,
    required this.responsableDni,
    required this.responsableNombre,
    required this.motivo,
    required this.refUnidad,
    required this.refPosicion,
  });

  /// SKU = modelo + vida. Clave de agregación del stock.
  String get sku => '$modeloId|$vida';

  factory StockMovimiento.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      StockMovimiento.fromMap(doc.id, doc.data());

  factory StockMovimiento.fromMap(String id, Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    return StockMovimiento(
      id: id,
      tipo: TipoMovimientoStock.fromCodigo(d['tipo']?.toString()) ??
          TipoMovimientoStock.ajuste,
      modeloId: (d['modelo_id'] ?? '').toString(),
      modeloEtiqueta: (d['modelo_etiqueta'] ?? '').toString(),
      vida: (d['vida'] as num?)?.toInt() ?? 1,
      delta: (d['delta'] as num?)?.toInt() ?? 0,
      fecha: (d['fecha'] as Timestamp?)?.toDate() ?? DateTime.now(),
      responsableDni: (d['responsable_dni'] ?? '').toString(),
      responsableNombre: d['responsable_nombre']?.toString(),
      motivo: d['motivo']?.toString(),
      refUnidad: d['ref_unidad']?.toString(),
      refPosicion: d['ref_posicion']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'tipo': tipo.codigo,
        'modelo_id': modeloId,
        'modelo_etiqueta': modeloEtiqueta,
        'vida': vida,
        'delta': delta,
        'fecha': Timestamp.fromDate(fecha),
        'responsable_dni': responsableDni,
        'responsable_nombre': responsableNombre,
        'motivo': motivo,
        'ref_unidad': refUnidad,
        'ref_posicion': refPosicion,
      };
}

/// Stock agregado de un SKU (cubiertas de un modelo en una vida).
class StockItem {
  final String modeloId;
  final String modeloEtiqueta;
  final int vida;
  final int cantidad;

  const StockItem({
    required this.modeloId,
    required this.modeloEtiqueta,
    required this.vida,
    required this.cantidad,
  });

  bool get esRecapada => vida > 1;
  String get etiquetaVida => vida <= 1 ? 'Nueva' : 'Recapada ${vida - 1}';
}

/// Calcula el stock actual por SKU sumando los `delta` de los movimientos.
///
/// PURA — base del control de inventario (testeable sin Firestore). Devuelve
/// solo los SKU con cantidad distinta de 0 (incluye negativos a propósito:
/// una cantidad negativa señala un error de registro o un faltante que el
/// inventario físico debe resolver). Ordena por etiqueta de modelo y vida.
List<StockItem> calcularStock(List<StockMovimiento> movimientos) {
  final cant = <String, int>{};
  final etiqueta = <String, String>{};
  final modeloDeSku = <String, String>{};
  final vidaDeSku = <String, int>{};

  // Ordenar por fecha para que la etiqueta snapshot quede la más reciente.
  final ordenados = [...movimientos]
    ..sort((a, b) => a.fecha.compareTo(b.fecha));

  for (final m in ordenados) {
    final k = m.sku;
    cant[k] = (cant[k] ?? 0) + m.delta;
    etiqueta[k] = m.modeloEtiqueta;
    modeloDeSku[k] = m.modeloId;
    vidaDeSku[k] = m.vida;
  }

  final items = <StockItem>[];
  for (final k in cant.keys) {
    if (cant[k] == 0) continue;
    items.add(StockItem(
      modeloId: modeloDeSku[k]!,
      modeloEtiqueta: etiqueta[k] ?? '',
      vida: vidaDeSku[k]!,
      cantidad: cant[k]!,
    ));
  }
  items.sort((a, b) {
    final e = a.modeloEtiqueta.compareTo(b.modeloEtiqueta);
    return e != 0 ? e : a.vida.compareTo(b.vida);
  });
  return items;
}
