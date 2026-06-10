import '../models/adelanto_chofer.dart';
import '../models/viaje.dart';

/// Totales de liquidación de un chofer (o de todo el período) separando
/// lo FIRME (viajes CONCLUIDOS) de la ESPECULACIÓN (EN_CURSO /
/// PLANEADOS), igual que la planilla Excel. Pedido Santiago 2026-06-10:
/// la pantalla de Liquidación adopta la visión del cuaderno
///   GANANCIA − ADELANTOS + GASTOS = NETO A PAGAR  (firme)
///   NETO A PAGAR + OTROS VIAJES = TOTAL ESTIMADO  (proyección)
///
/// Lógica idéntica a `ReportPlanillaChofer`/`CalculosViaje`: la ganancia
/// es el `montoChoferRedondeado` ya persistido (redondeo a múltiplo de 5
/// por tramo). Los gastos y adelantos solo entran al NETO firme; OTROS
/// VIAJES es la ganancia de los no-concluidos (sin gastos ni adelantos,
/// porque es especulación).
class LiquidacionTotales {
  /// Σ `montoVecchi` de los concluidos (lo facturado firme a la empresa).
  final double facturadoFirme;

  /// Σ `montoChoferRedondeado` de los concluidos (ganancia firme).
  final double gananciaFirme;

  /// Σ `gastosTotal` de los concluidos.
  final double gastosFirme;

  /// Σ `monto` de TODOS los adelantos del rango (se descuentan del firme).
  final double adelantos;

  /// `gananciaFirme − adelantos + gastosFirme`. Lo que se paga firme.
  final double netoFirme;

  /// Σ `montoChoferRedondeado` de EN_CURSO / PLANEADOS (especulación).
  final double gananciaOtros;

  /// `netoFirme + gananciaOtros`. Proyección si se concretan los otros.
  final double totalEstimado;

  final int nConcluidos;
  final int nOtros;
  final int nAdelantos;

  /// Concluidos NO liquidados (pendientes de pago).
  final int pendientes;

  const LiquidacionTotales({
    required this.facturadoFirme,
    required this.gananciaFirme,
    required this.gastosFirme,
    required this.adelantos,
    required this.netoFirme,
    required this.gananciaOtros,
    required this.totalEstimado,
    required this.nConcluidos,
    required this.nOtros,
    required this.nAdelantos,
    required this.pendientes,
  });

  /// `true` si hay viajes en curso/planeados → mostrar el bloque de
  /// especulación (OTROS VIAJES / TOTAL ESTIMADO).
  bool get hayOtros => nOtros > 0;

  factory LiquidacionTotales.de(
    Iterable<Viaje> viajes,
    Iterable<AdelantoChofer> adelantos,
  ) {
    var facturadoFirme = 0.0, gananciaFirme = 0.0, gastosFirme = 0.0;
    var gananciaOtros = 0.0;
    var nConcluidos = 0, nOtros = 0, pendientes = 0;
    for (final v in viajes) {
      if (v.estado == EstadoViaje.concluido) {
        nConcluidos++;
        facturadoFirme += v.montoVecchi;
        gananciaFirme += v.montoChoferRedondeado;
        gastosFirme += v.gastosTotal;
        if (!v.liquidado) pendientes++;
      } else {
        nOtros++;
        gananciaOtros += v.montoChoferRedondeado;
      }
    }
    var adelTotal = 0.0, nAdel = 0;
    for (final a in adelantos) {
      adelTotal += a.monto;
      nAdel++;
    }
    final netoFirme = gananciaFirme - adelTotal + gastosFirme;
    return LiquidacionTotales(
      facturadoFirme: facturadoFirme,
      gananciaFirme: gananciaFirme,
      gastosFirme: gastosFirme,
      adelantos: adelTotal,
      netoFirme: netoFirme,
      gananciaOtros: gananciaOtros,
      totalEstimado: netoFirme + gananciaOtros,
      nConcluidos: nConcluidos,
      nOtros: nOtros,
      nAdelantos: nAdel,
      pendientes: pendientes,
    );
  }
}
