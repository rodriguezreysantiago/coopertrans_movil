import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/app_constants.dart';

/// Snapshot diario de odómetro + litros acumulados por unidad.
///
/// Doc ID `{patente}_{YYYY-MM-DD}`. La CF `telemetriaSnapshotScheduled`
/// (cada 6h) escribe el último valor del día — el último doc del día
/// queda como "cierre" del día. Hoy cubre los 53 tractores Volvo.
///
/// `km` y `litros_acumulados` son ACUMULADOS desde fábrica del vehículo —
/// el delta diario se calcula restando el doc del día anterior.
class OdometroDia {
  final String patente;
  final String fecha; // 'YYYY-MM-DD'
  final double kmAcumulado;
  final double litrosAcumulados;
  final DateTime? leidoEn;

  /// km recorridos en este día (precalculado por el service al armar la
  /// serie; vale 0 cuando no hay doc previo o cuando el delta es absurdo).
  final int deltaKm;

  /// L consumidos este día (mismo criterio).
  final double deltaLitros;

  const OdometroDia({
    required this.patente,
    required this.fecha,
    required this.kmAcumulado,
    required this.litrosAcumulados,
    required this.leidoEn,
    required this.deltaKm,
    required this.deltaLitros,
  });

  /// Consumo l/100km del día (0 si no hay km recorridos).
  double get litros100km =>
      deltaKm > 0 ? (deltaLitros * 100.0 / deltaKm) : 0.0;

  factory OdometroDia._fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc,
      {required int deltaKm, required double deltaLitros}) {
    final m = doc.data() ?? const <String, dynamic>{};
    final ts = m['timestamp'];
    DateTime? leidoEn;
    if (ts is Timestamp) leidoEn = ts.toDate();
    return OdometroDia(
      patente: (m['patente'] as String?) ?? '',
      fecha: (m['fecha'] as String?) ?? '',
      kmAcumulado: ((m['km'] as num?) ?? 0).toDouble(),
      litrosAcumulados: ((m['litros_acumulados'] as num?) ?? 0).toDouble(),
      leidoEn: leidoEn,
      deltaKm: deltaKm,
      deltaLitros: deltaLitros,
    );
  }
}

class OdometrosService {
  OdometrosService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AppCollections.telemetriaHistorico);

  /// Trae los últimos N días de snapshots de UNA patente, ordenados de
  /// más reciente a más viejo, con los deltas YA calculados.
  ///
  /// Pide N+1 docs internamente para poder calcular el delta del primer
  /// día (necesita el día anterior). Si el campo `km` baja entre días
  /// (caso raro: reset de odómetro, error), el delta se reporta como 0.
  static Future<List<OdometroDia>> cargarUltimosDias({
    required String patente,
    int dias = 30,
  }) async {
    final snap = await _col
        .where('patente', isEqualTo: patente)
        .orderBy('fecha', descending: true)
        .limit(dias + 1)
        .get();
    if (snap.docs.isEmpty) return const [];

    final docs = snap.docs;
    final out = <OdometroDia>[];
    // Iterar de más reciente a más viejo; el delta de docs[i] se calcula
    // contra docs[i+1] (el día anterior). El doc más viejo (último de la
    // lista) queda sin delta (su día anterior no está en este pedido).
    for (var i = 0; i < docs.length - 1; i++) {
      final hoy = docs[i].data();
      final ayer = docs[i + 1].data();
      final kmHoy = ((hoy['km'] as num?) ?? 0).toDouble();
      final kmAyer = ((ayer['km'] as num?) ?? 0).toDouble();
      final lHoy = ((hoy['litros_acumulados'] as num?) ?? 0).toDouble();
      final lAyer = ((ayer['litros_acumulados'] as num?) ?? 0).toDouble();
      final dKm = kmHoy >= kmAyer ? (kmHoy - kmAyer).round() : 0;
      final dL = lHoy >= lAyer ? (lHoy - lAyer) : 0.0;
      out.add(OdometroDia._fromDoc(docs[i], deltaKm: dKm, deltaLitros: dL));
    }
    // Para no perder el día más viejo del rango pedido, lo agregamos
    // con delta 0 (sin día anterior para comparar).
    final ult = docs.last;
    out.add(OdometroDia._fromDoc(ult, deltaKm: 0, deltaLitros: 0));
    // Si pedimos N+1 y devuelve N+1, recortamos a N (el extra era solo
    // para calcular el delta del primero).
    if (out.length > dias) out.removeRange(dias, out.length);
    return out;
  }

  /// Agrega los deltas por mes calendario (YYYY-MM). Devuelve un mapa
  /// {mes: {km, litros, dias_con_dato}} ordenado del mes más reciente al
  /// más viejo. Útil para una tabla "últimos 3 meses".
  static Future<Map<String, MesAgregado>> agruparPorMes({
    required String patente,
    int meses = 3,
  }) async {
    // Para "últimos 3 meses" pedimos 100 días (cubre cualquier mes y deja
    // un día previo para calcular el delta del 1ro del mes).
    final lista = await cargarUltimosDias(patente: patente, dias: 100);
    final out = <String, MesAgregado>{};
    for (final od in lista) {
      if (od.fecha.length < 7) continue;
      final ym = od.fecha.substring(0, 7); // 'YYYY-MM'
      out.putIfAbsent(ym, () => MesAgregado.vacio(ym));
      out[ym]!.kmTotal += od.deltaKm;
      out[ym]!.litrosTotal += od.deltaLitros;
      if (od.deltaKm > 0) out[ym]!.diasConDato++;
    }
    // Orden descendente por mes
    final orden = out.keys.toList()..sort((a, b) => b.compareTo(a));
    final result = <String, MesAgregado>{};
    for (final k in orden.take(meses)) {
      result[k] = out[k]!;
    }
    return result;
  }
}

class MesAgregado {
  final String mes; // 'YYYY-MM'
  int kmTotal;
  double litrosTotal;
  int diasConDato;

  MesAgregado({
    required this.mes,
    required this.kmTotal,
    required this.litrosTotal,
    required this.diasConDato,
  });

  factory MesAgregado.vacio(String mes) =>
      MesAgregado(mes: mes, kmTotal: 0, litrosTotal: 0, diasConDato: 0);

  /// Consumo l/100km promedio del mes (0 si sin km).
  double get litros100km =>
      kmTotal > 0 ? (litrosTotal * 100.0 / kmTotal) : 0.0;
}
