// lib/features/gomeria/models/conteo_gomeria.dart
//
// Conteo de inventario "a ciegas" del depósito de gomería (pedido Santiago
// 2026-06-05). El operador (rol GOMERIA) reporta cuántas cubiertas VE de cada
// modelo, separando NUEVAS de RECAPADAS, SIN ver el stock teórico del sistema.
// Después, ADMIN/SUPERVISOR compara lo reportado contra el stock real y ve las
// diferencias. El sistema NO ajusta solo — el admin decide.
//
// Granularidad acordada: por modelo × {nueva, recapada}. El teórico se agrupa
// igual (nueva = vida 1; recapada = vida >= 2) para poder comparar.

import 'package:cloud_firestore/cloud_firestore.dart';

import 'stock_movimiento.dart';

/// Una línea del conteo: cuántas nuevas y recapadas contó el operador de un
/// modelo. Solo se persisten las líneas con algo (>0) — un modelo ausente del
/// conteo se interpreta como "contó 0" (el operador ve la lista completa).
class LineaConteo {
  final String modeloId;
  final String modeloEtiqueta; // snapshot
  final int nuevas;
  final int recapadas;

  const LineaConteo({
    required this.modeloId,
    required this.modeloEtiqueta,
    required this.nuevas,
    required this.recapadas,
  });

  int get total => nuevas + recapadas;

  factory LineaConteo.fromMap(Map<String, dynamic> m) => LineaConteo(
        modeloId: (m['modelo_id'] ?? '').toString(),
        modeloEtiqueta: (m['modelo_etiqueta'] ?? '').toString(),
        nuevas: (m['nuevas'] as num?)?.toInt() ?? 0,
        recapadas: (m['recapadas'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'modelo_id': modeloId,
        'modelo_etiqueta': modeloEtiqueta,
        'nuevas': nuevas,
        'recapadas': recapadas,
      };
}

/// Un conteo físico reportado por el operador de gomería.
class ConteoGomeria {
  final String id;
  final DateTime? creadoEn;
  final String responsableDni;
  final String responsableNombre;
  final List<LineaConteo> lineas;
  final bool revisado;
  final String? revisadoPorDni;
  final DateTime? revisadoEn;

  const ConteoGomeria({
    required this.id,
    required this.creadoEn,
    required this.responsableDni,
    required this.responsableNombre,
    required this.lineas,
    this.revisado = false,
    this.revisadoPorDni,
    this.revisadoEn,
  });

  int get totalContado => lineas.fold(0, (a, l) => a + l.total);

  factory ConteoGomeria.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    final rawLineas = (d['lineas'] as List?) ?? const [];
    return ConteoGomeria(
      id: doc.id,
      creadoEn: (d['creado_en'] as Timestamp?)?.toDate(),
      responsableDni: (d['responsable_dni'] ?? '').toString(),
      responsableNombre: (d['responsable_nombre'] ?? '').toString(),
      lineas: rawLineas
          .whereType<Map>()
          .map((e) => LineaConteo.fromMap(Map<String, dynamic>.from(e)))
          .toList(),
      revisado: d['revisado'] is bool ? d['revisado'] as bool : false,
      revisadoPorDni: d['revisado_por_dni']?.toString(),
      revisadoEn: (d['revisado_en'] as Timestamp?)?.toDate(),
    );
  }
}

/// Diferencia por modelo entre lo reportado por el operador y el stock teórico
/// del sistema. La produce [compararConteoVsStock]; la consume la pantalla de
/// revisión del admin.
class DiferenciaConteo {
  final String modeloId;
  final String modeloEtiqueta;
  final int reportadoNuevas;
  final int teoricoNuevas;
  final int reportadoRecapadas;
  final int teoricoRecapadas;

  const DiferenciaConteo({
    required this.modeloId,
    required this.modeloEtiqueta,
    required this.reportadoNuevas,
    required this.teoricoNuevas,
    required this.reportadoRecapadas,
    required this.teoricoRecapadas,
  });

  /// + = sobran (contó más que el sistema), − = faltan.
  int get difNuevas => reportadoNuevas - teoricoNuevas;
  int get difRecapadas => reportadoRecapadas - teoricoRecapadas;
  bool get hayDiferencia => difNuevas != 0 || difRecapadas != 0;
}

/// PURA: compara un [conteo] contra el [stock] teórico, por modelo y condición
/// (nueva/recapada). Considera la UNIÓN de modelos del conteo y del stock — así
/// detecta tanto faltantes (el sistema tiene, el operador no lo contó) como
/// sobrantes (el operador contó algo que el sistema no registra). Ordena por
/// etiqueta de modelo. Testeable sin Firestore.
List<DiferenciaConteo> compararConteoVsStock(
  ConteoGomeria conteo,
  List<StockItem> stock,
) {
  final teoNuevas = <String, int>{};
  final teoRecap = <String, int>{};
  final etiqueta = <String, String>{};

  for (final s in stock) {
    etiqueta[s.modeloId] = s.modeloEtiqueta;
    if (s.vida <= 1) {
      teoNuevas[s.modeloId] = (teoNuevas[s.modeloId] ?? 0) + s.cantidad;
    } else {
      teoRecap[s.modeloId] = (teoRecap[s.modeloId] ?? 0) + s.cantidad;
    }
  }

  final repNuevas = <String, int>{};
  final repRecap = <String, int>{};
  for (final l in conteo.lineas) {
    etiqueta[l.modeloId] ??= l.modeloEtiqueta;
    repNuevas[l.modeloId] = l.nuevas;
    repRecap[l.modeloId] = l.recapadas;
  }

  final modelos = <String>{
    ...teoNuevas.keys,
    ...teoRecap.keys,
    ...repNuevas.keys,
    ...repRecap.keys,
  };

  final out = modelos
      .map((m) => DiferenciaConteo(
            modeloId: m,
            modeloEtiqueta: etiqueta[m] ?? m,
            reportadoNuevas: repNuevas[m] ?? 0,
            teoricoNuevas: teoNuevas[m] ?? 0,
            reportadoRecapadas: repRecap[m] ?? 0,
            teoricoRecapadas: teoRecap[m] ?? 0,
          ))
      .toList()
    ..sort((a, b) => a.modeloEtiqueta.compareTo(b.modeloEtiqueta));
  return out;
}
