import '../models/tarifa_logistica.dart';
import '../models/viaje.dart';

/// Cálculos de un viaje — montos Vecchi, montos chofer, redondeo,
/// comisión, liquidación. Centralizados acá para que el formulario,
/// el service y los reportes usen la MISMA fórmula.
///
/// Decisiones operativas (Santiago 2026-05-09):
///   1. Comisión del chofer: 18% sobre la TARIFA DEL CHOFER (no sobre
///      el precio Vecchi). Hardcoded — si en el futuro debe variar
///      por chofer, se promueve a config en EMPLEADOS.
///   2. Redondeo: solo al monto del CHOFER (lo que se le paga en
///      mano). Vecchi factura el monto exacto al cliente.
///   3. Para tarifas POR_TONELADA: el monto se calcula sobre los
///      kg DESCARGADOS (lo efectivamente entregado al cliente).
///      Mientras el viaje está en curso (sin descargar), el cálculo
///      cae a kg CARGADOS como ESTIMADO. Cuando el operador carga
///      kg descargados, los montos se recalculan con esos.
///   4. Liquidación al chofer = monto_chofer_redondeado − adelanto
///      + gastos_total. Los gastos extraordinarios (peajes,
///      combustible, comida) los paga el chofer y Vecchi se los
///      reembolsa.
class CalculosViaje {
  CalculosViaje._();

  static const double comisionChoferDefaultPct = 18.0;

  /// Redondea un monto al múltiplo de 5 INMEDIATAMENTE INFERIOR.
  /// Quita centavos y baja al múltiplo de 5 más cercano por debajo.
  ///
  /// Ejemplos:
  ///   123.47  → 120
  ///   158.99  → 155
  ///   200.00  → 200  (ya múltiplo)
  ///   124.00  → 120
  ///   0.00    → 0
  ///   −12.50  → −15  (sigue siendo "descendente" — más negativo)
  ///
  /// El algoritmo es `floor(monto / 5) * 5`. `floor` (no `truncate`)
  /// para que números negativos también vayan al múltiplo de 5
  /// inferior (más negativo), aunque en práctica los montos son
  /// siempre ≥ 0.
  static double redondearMultiploDe5Descendente(num monto) {
    return (monto / 5).floor() * 5.0;
  }

  /// Calcula los montos brutos sin aplicar comisión ni redondeo.
  /// Devuelve (montoVecchi, montoChofer) según el tipo de tarifa.
  ///
  /// - POR_VIAJE: devuelve la tarifa fija tal cual.
  /// - POR_TONELADA: usa los kg DESCARGADOS si están (lo efectivamente
  ///   entregado al cliente). Si todavía no descargó, cae a kg
  ///   CARGADOS como estimado. La fórmula es `tarifa * kg / 1000`
  ///   (la tarifa está en $/TN, dividimos kg por 1000 para convertir
  ///   a toneladas).
  /// - Si no hay ni cargados ni descargados, devuelve 0 (viaje
  ///   recién planeado, antes de carga).
  static MontosBrutos calcularMontosBrutos({
    required UnidadTarifa unidadTarifa,
    required double tarifaReal,
    required double tarifaChofer,
    double? kgCargados,
    double? kgDescargados,
  }) {
    if (unidadTarifa == UnidadTarifa.porViaje) {
      return MontosBrutos(montoVecchi: tarifaReal, montoChofer: tarifaChofer);
    }
    // POR_TONELADA: kg descargados tienen prioridad (cifra final).
    // Si no están, usamos kg cargados como estimado en curso.
    final kgEfectivo = (kgDescargados != null && kgDescargados > 0)
        ? kgDescargados
        : kgCargados;
    if (kgEfectivo == null || kgEfectivo <= 0) {
      return const MontosBrutos(montoVecchi: 0, montoChofer: 0);
    }
    final tn = kgEfectivo / 1000.0;
    return MontosBrutos(
      montoVecchi: tarifaReal * tn,
      montoChofer: tarifaChofer * tn,
    );
  }

  /// Calcula la liquidación final al chofer:
  ///   redondeado − adelanto + gastos_reembolsables
  ///
  /// `redondeado` ya viene con el redondeo a múltiplo de 5
  /// descendente aplicado (ver `redondearMultiploDe5Descendente`).
  /// `adelanto` y `gastos` pueden ser 0.
  static double calcularLiquidacion({
    required double montoChoferRedondeado,
    double adelanto = 0,
    double gastosTotal = 0,
  }) {
    return montoChoferRedondeado - adelanto + gastosTotal;
  }

  /// Suma de la lista de gastos. `null` o lista vacía → 0.
  static double sumarGastos(Iterable<GastoViaje>? gastos) {
    if (gastos == null) return 0;
    var total = 0.0;
    for (final g in gastos) {
      total += g.monto;
    }
    return total;
  }

  /// Calcula TODOS los montos de un viaje en una sola pasada.
  /// Conveniente para el form (recomputar al cambiar cualquier input)
  /// y para el service (persistir todos coherentes en un mismo write).
  ///
  /// `comisionPct` queda como 18 si pasás `null` (default operativo).
  /// Cambiar este parámetro permite tests que usen otros porcentajes
  /// sin tocar la default.
  static MontosViaje calcularTodo({
    required UnidadTarifa unidadTarifa,
    required double tarifaReal,
    required double tarifaChofer,
    double? kgCargados,
    double? kgDescargados,
    double adelanto = 0,
    Iterable<GastoViaje>? gastos,
    double? comisionPct,
  }) {
    final pct = comisionPct ?? comisionChoferDefaultPct;
    final brutos = calcularMontosBrutos(
      unidadTarifa: unidadTarifa,
      tarifaReal: tarifaReal,
      tarifaChofer: tarifaChofer,
      kgCargados: kgCargados,
      kgDescargados: kgDescargados,
    );
    final redondeado = redondearMultiploDe5Descendente(brutos.montoChofer);
    final gastosTot = sumarGastos(gastos);
    final liquidacion = calcularLiquidacion(
      montoChoferRedondeado: redondeado,
      adelanto: adelanto,
      gastosTotal: gastosTot,
    );
    return MontosViaje(
      montoVecchi: brutos.montoVecchi,
      montoChofer: brutos.montoChofer,
      montoChoferRedondeado: redondeado,
      comisionChoferPct: pct,
      gastosTotal: gastosTot,
      liquidacionChofer: liquidacion,
    );
  }
}

/// Resultado intermedio — antes de redondeo, antes de aplicar
/// adelanto/gastos.
class MontosBrutos {
  final double montoVecchi;
  final double montoChofer;
  const MontosBrutos({required this.montoVecchi, required this.montoChofer});
}

/// Resultado completo — todos los montos del viaje.
class MontosViaje {
  final double montoVecchi;
  final double montoChofer;
  final double montoChoferRedondeado;
  final double comisionChoferPct;
  final double gastosTotal;
  final double liquidacionChofer;

  const MontosViaje({
    required this.montoVecchi,
    required this.montoChofer,
    required this.montoChoferRedondeado,
    required this.comisionChoferPct,
    required this.gastosTotal,
    required this.liquidacionChofer,
  });
}
