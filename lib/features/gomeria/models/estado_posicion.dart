import '../constants/posiciones.dart';
import 'montaje.dart';
import 'nivel_desgaste.dart';

/// Estado de UNA posición de una unidad para el esquema de la UI (rediseño
/// gomería 2026-05-29): qué cubierta tiene montada (si alguna), cuánto de su
/// vida consumió y el semáforo de desgaste.
class EstadoPosicion {
  final PosicionCubierta posicion;

  /// Montaje activo en esta posición, o `null` si está vacía.
  final Montaje? montaje;

  /// % de vida consumida (puede pasar de 100%). `null` = vacía o sin datos.
  final double? porcentajeVida;

  /// Semáforo derivado del %.
  final NivelDesgaste nivel;

  const EstadoPosicion({
    required this.posicion,
    required this.montaje,
    required this.porcentajeVida,
    required this.nivel,
  });

  bool get ocupada => montaje != null;
}

/// Arma el estado de TODAS las posiciones de una unidad (ocupadas y vacías),
/// combinando los montajes activos con el km recorrido por posición. PURA —
/// no hace I/O: el caller calcula el km y lo pasa.
///
/// `kmRecorridoPorPosicion[codigoPos]` = km que rodó la cubierta de esa
/// posición; lo resuelve el caller según el tipo de unidad (tractor por
/// odómetro, enganche por el cálculo robusto vía duplas). Si para una posición
/// no hay ese dato, se cae a `kmActualUnidad - kmUnidadAlMontar` (tractor) y,
/// si tampoco, queda `sinDatos`.
List<EstadoPosicion> construirEstadoUnidad({
  required TipoUnidadCubierta unidadTipo,
  required List<Montaje> montajesActivos,
  Map<String, double?>? kmRecorridoPorPosicion,
  double? kmActualUnidad,
  double umbralAlerta = kUmbralAlertaDesgaste,
  double umbralCritico = kUmbralCriticoDesgaste,
}) {
  final montajePorPos = <String, Montaje>{
    for (final m in montajesActivos) m.posicion: m,
  };

  return posicionesParaUnidad(unidadTipo).map((pos) {
    final m = montajePorPos[pos.codigo];
    if (m == null) {
      return EstadoPosicion(
        posicion: pos,
        montaje: null,
        porcentajeVida: null,
        nivel: NivelDesgaste.sinDatos,
      );
    }
    final kmRec = kmRecorridoPorPosicion?[pos.codigo];
    final pct = m.porcentajeVidaConsumida(
      kmActualUnidad: kmActualUnidad,
      kmRecorridosCalculado: kmRec,
    );
    return EstadoPosicion(
      posicion: pos,
      montaje: m,
      porcentajeVida: pct,
      nivel: nivelDesgaste(pct,
          umbralAlerta: umbralAlerta, umbralCritico: umbralCritico),
    );
  }).toList();
}
