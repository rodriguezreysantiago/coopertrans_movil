import '../models/tarifa_logistica.dart';
import '../models/viaje.dart';

/// Cálculos de un viaje — montos Vecchi, montos chofer, redondeo,
/// comisión, liquidación. Centralizados acá para que el formulario,
/// el service y los reportes usen la MISMA fórmula.
///
/// Decisiones operativas (Santiago 2026-05-09 + corrección 2026-05-13):
///   1. **Tarifa real vs tarifa chofer**: cada tarifa tiene 2 montos.
///      `tarifaReal` es lo que se le factura al cliente. `tarifaChofer`
///      suele ser igual o un poco MÁS BAJA — es la base con la que
///      calculamos lo que cobra el chofer. Ejemplo típico: tarifa
///      real $70.000/TN, tarifa chofer $68.000/TN. Vecchi factura
///      con $70.000 pero al chofer le calcula el 18% sobre $68.000.
///   2. **Comisión del chofer: 18% sobre la BASE de tarifa chofer**
///      (Santiago 2026-05-13). La fórmula es:
///        `montoChofer = (tarifaChofer × TN) × 0.18`
///      Hardcoded — si en el futuro debe variar por chofer, se
///      promueve a config en EMPLEADOS.
///   3. **Redondeo: a múltiplo de 5 DESCENDENTE** sobre el monto
///      chofer ya con la comisión aplicada. Vecchi factura el monto
///      exacto al cliente; al chofer se le redondea por practicidad
///      de pago en efectivo / transferencias redondas.
///   4. Para tarifas POR_TONELADA: el monto se calcula sobre los
///      kg DESCARGADOS (lo efectivamente entregado al cliente).
///      Mientras el viaje está en curso (sin descargar), el cálculo
///      cae a kg CARGADOS como ESTIMADO. Cuando el operador carga
///      kg descargados, los montos se recalculan con esos.
///   5. Liquidación al chofer = monto_chofer_redondeado − adelanto
///      + gastos_total. Los gastos extraordinarios (peajes,
///      combustible, comida) los paga el chofer y Vecchi se los
///      reembolsa.
///   6. **Comisión / monto fijo del DADOR: informativos, NO se calculan**
///      (decisión Santiago 2026-06-04). Las tarifas guardan
///      `porcentajeComisionDador` / `montoFijoDador` para referencia, pero
///      NINGÚN total los descuenta: `montoVecchi = tarifaReal × TN` es el
///      BRUTO facturado al cliente. Si en el futuro el ingreso NETO de
///      Vecchi (descontando lo que se lleva el dador) tuviera que impactar
///      un total, hay que sumarlo acá Y re-resolverlo por vigencia en el
///      recálculo masivo (hoy ese campo no entra a ningún cálculo).
class CalculosViaje {
  CalculosViaje._();

  static const double comisionChoferDefaultPct = 18.0;

  /// Redondeo a 2 decimales (centavos) — anti-float drift.
  ///
  /// Auditoria 2026-05-18: sumas de doubles como `12.30 + 4.50` daban
  /// `16.799999999999997` y se persistian en Firestore tal cual. El
  /// `monto_chofer_redondeado` salvaba el display final, pero `montoVecchi`,
  /// `gastosTotal` y `liquidacionChofer` heredaban el error. Acumulado
  /// sobre meses, los Excel de liquidacion mostraban totales con cola
  /// de "...99999". Ahora todos los montos pasan por este helper antes
  /// de salir de `calcular*` → maximo 2 decimales reales.
  ///
  /// Defensa contra NaN/Infinity (no deberian llegar, pero por las dudas).
  static double _round2(double v) {
    if (v.isNaN || v.isInfinite) return 0;
    return (v * 100).round() / 100;
  }

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
    // Defensa contra NaN / Infinity (auditoria 2026-05-17): si por una
    // via indirecta el monto llega como NaN/Inf (tarifa corrupta en
    // Firebase Console, division por cero upstream, etc.) el `.floor()`
    // tira `Unsupported operation: Infinity or NaN`. Como el form vive
    // 100% client-side, el crash freezea la UX. Mejor devolver 0 y que
    // el operador vea $0 que un crash.
    if (monto.isNaN || monto.isInfinite) return 0;
    return (monto / 5).floor() * 5.0;
  }

  /// Calcula los montos brutos sin aplicar comisión ni redondeo.
  /// Devuelve `(montoVecchi, baseChoferBruta)` según el tipo de tarifa.
  ///
  /// ⚠️ `baseChoferBruta` NO es lo que se le paga al chofer — es la
  /// base de cálculo. Para obtener el monto del chofer hay que
  /// multiplicar por `comisionPct / 100` (típicamente 0.18). Los
  /// métodos públicos [calcularTodo] y [calcularTodoMultiTramo] ya
  /// hacen esa aplicación; usá esos en lugar de llamar a este crudo.
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

  /// Calcula TODOS los montos de un viaje **single-tramo** en una sola
  /// pasada. Conveniente para el form viejo / tests legacy. Para
  /// viajes multi-tramo, usar [calcularTodoMultiTramo].
  ///
  /// `comisionPct` queda como 18 si pasás `null` (default operativo).
  ///
  /// **Monto fijo del chofer** (Santiago 2026-05-19): si pasás
  /// `montoFijoChofer` no-null, esa cifra es lo que se le paga al
  /// chofer FLAT (sin multiplicar por TN ni aplicar `comisionPct`).
  /// Pensado para viajes cortos donde Vecchi acuerda un monto a mano
  /// con el chofer que no coincide con el cálculo del 18%. El monto
  /// Vecchi se sigue calculando normal.
  ///
  /// Fórmula (Santiago 2026-05-13):
  ///   baseBrutaChofer = tarifaChofer × TN
  ///   montoChofer     = baseBrutaChofer × (comisionPct / 100)
  ///   redondeado      = floor5(montoChofer)
  /// Override:
  ///   si montoFijoChofer != null → montoChofer = montoFijoChofer
  ///                                redondeado  = floor5(montoFijoChofer)
  ///                                comisionPct se reporta como 0 (no aplica)
  static MontosViaje calcularTodo({
    required UnidadTarifa unidadTarifa,
    required double tarifaReal,
    required double tarifaChofer,
    double? kgCargados,
    double? kgDescargados,
    double adelanto = 0,
    Iterable<GastoViaje>? gastos,
    double? comisionPct,
    double? montoFijoChofer,
  }) {
    final pct = comisionPct ?? comisionChoferDefaultPct;
    final brutos = calcularMontosBrutos(
      unidadTarifa: unidadTarifa,
      tarifaReal: tarifaReal,
      tarifaChofer: tarifaChofer,
      kgCargados: kgCargados,
      kgDescargados: kgDescargados,
    );
    // Si hay monto fijo del chofer, ése es el resultado final — no
    // pasa por porcentaje ni por TN. La cifra es flat por viaje. Si
    // no hay, cálculo legacy: base bruta × pct.
    final double montoChofer;
    final double pctReportado;
    if (montoFijoChofer != null) {
      montoChofer = montoFijoChofer;
      pctReportado = 0; // no aplica — el monto está fijado a mano
    } else {
      montoChofer = brutos.montoChofer * (pct / 100.0);
      pctReportado = pct;
    }
    final redondeado = redondearMultiploDe5Descendente(montoChofer);
    final gastosTot = sumarGastos(gastos);
    final liquidacion = calcularLiquidacion(
      montoChoferRedondeado: redondeado,
      adelanto: adelanto,
      gastosTotal: gastosTot,
    );
    return MontosViaje(
      montoVecchi: _round2(brutos.montoVecchi),
      montoChofer: _round2(montoChofer),
      montoChoferRedondeado: redondeado,
      comisionChoferPct: pctReportado,
      gastosTotal: _round2(gastosTot),
      liquidacionChofer: _round2(liquidacion),
    );
  }

  /// Calcula TODOS los montos de un viaje **multi-tramo**.
  ///
  /// Estrategia:
  ///   1. Calcula brutos POR TRAMO usando la tarifa y kgs propios de
  ///      cada tramo.
  ///   2. Suma los brutos de todos los tramos → totales del viaje
  ///      (base bruta chofer = suma de tarifaChofer × TN).
  ///   3. Aplica el porcentaje de comisión sobre la base bruta total
  ///      (Santiago 2026-05-13: corregido — antes se le pagaba al
  ///      chofer la base bruta entera, ahora es el `comisionPct`% de
  ///      esa base).
  ///   4. Aplica redondeo a múltiplo de 5 DESCENDENTE sobre el monto
  ///      con comisión aplicada (el redondeo es sobre el total que
  ///      se le paga al chofer, no por tramo — sino se acumularía
  ///      error de redondeo).
  ///   5. Suma los gastos de TODOS los tramos (cada tramo tiene su
  ///      propia lista de gastos desde 2026-05-13). Si el caller
  ///      pasa `gastos` explícito, lo respeta (usado por tests y
  ///      flujos legacy single-tramo).
  ///   6. Resta adelanto + suma gastos para la liquidación final.
  ///
  /// Si `tramos` es vacío (no debería pasar, el modelo garantiza ≥1),
  /// devuelve montos en cero.
  static MontosViaje calcularTodoMultiTramo({
    required List<TramoViaje> tramos,
    double adelanto = 0,
    Iterable<GastoViaje>? gastos,
    double? comisionPct,
  }) {
    final pct = comisionPct ?? comisionChoferDefaultPct;
    var totalVecchi = 0.0;
    // Suma del monto del chofer YA REDONDEADO POR TRAMO.
    // Pedido Santiago 2026-05-19: redondear a múltiplo de 5
    // descendente cada tramo individual y después sumar (en lugar de
    // sumar bruto y redondear al final). Eso permite ver el monto
    // exacto que cada tramo le aporta al chofer ya redondeado a
    // criterio operativo, y reduce errores de comparación al revisar
    // viajes con muchos tramos.
    var sumaRedondeadaPorTramo = 0.0;
    var montoSinRedondear = 0.0; // tracking del bruto para reporte
    var hayAlgunTramoConPct = false;
    for (final t in tramos) {
      final brutos = calcularMontosBrutos(
        unidadTarifa: t.tarifaSnapshot.unidadTarifa,
        tarifaReal: t.tarifaSnapshot.tarifaReal,
        tarifaChofer: t.tarifaSnapshot.tarifaChofer,
        kgCargados: t.kgCargados,
        kgDescargados: t.kgDescargados,
      );
      totalVecchi += brutos.montoVecchi;
      final fijo = t.tarifaSnapshot.montoFijoChofer;
      double montoTramo;
      if (fijo != null) {
        // Tramo con monto fijo: ese es el monto del chofer en ese
        // tramo (sin pct). Igual lo redondeamos para uniformidad.
        montoTramo = fijo;
      } else {
        // Tramo con porcentaje: aplicamos pct al bruto del tramo.
        montoTramo = brutos.montoChofer * (pct / 100.0);
        hayAlgunTramoConPct = true;
      }
      montoSinRedondear += montoTramo;
      sumaRedondeadaPorTramo +=
          redondearMultiploDe5Descendente(montoTramo);
    }
    final montoChofer = montoSinRedondear;
    final redondeado = sumaRedondeadaPorTramo;
    // Si TODOS los tramos son monto fijo, reportamos pct=0 porque no
    // hubo aplicación de porcentaje. Si al menos uno usa porcentaje,
    // reportamos el pct vigente (útil para la UI/reportes).
    final pctReportado = hayAlgunTramoConPct ? pct : 0.0;
    // Gastos: si el caller los pasa explícito (legacy / tests), se
    // respetan. Sino se suman de cada tramo. Esto resuelve el caso
    // 2026-05-13 donde los gastos pasaron de nivel viaje a nivel
    // tramo y el form de viaje los pasa directamente desde los tramos
    // sin un parámetro separado.
    final gastosTot = gastos != null
        ? sumarGastos(gastos)
        : tramos.fold<double>(0, (acc, t) => acc + t.gastosTotal);
    final liquidacion = calcularLiquidacion(
      montoChoferRedondeado: redondeado,
      adelanto: adelanto,
      gastosTotal: gastosTot,
    );
    return MontosViaje(
      montoVecchi: _round2(totalVecchi),
      montoChofer: _round2(montoChofer),
      montoChoferRedondeado: redondeado,
      comisionChoferPct: pctReportado,
      gastosTotal: _round2(gastosTot),
      liquidacionChofer: _round2(liquidacion),
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
