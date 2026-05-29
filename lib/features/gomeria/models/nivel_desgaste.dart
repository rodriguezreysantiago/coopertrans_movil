/// Nivel de desgaste de una cubierta según el % de vida útil consumida.
/// Base del semáforo de la UI del rediseño de gomería (2026-05-29): cada
/// posición de una unidad se pinta verde / amarillo / rojo según esto.
enum NivelDesgaste {
  /// Verde — dentro de la vida útil estimada.
  ok('Dentro de vida útil'),

  /// Amarillo — cerca del límite, planificar recambio / recapado.
  alerta('Cerca del límite'),

  /// Rojo — superó la vida estimada de la marca: recapar o descartar.
  critico('Pasó la vida estimada'),

  /// Gris — no se puede estimar (falta km de vida del modelo o km recorrido,
  /// típico de las legacy "SIN IDENTIFICAR" o de un enganche sin dupla).
  sinDatos('Sin datos');

  final String etiqueta;
  const NivelDesgaste(this.etiqueta);
}

/// Umbrales por defecto, en % de vida consumida.
/// - Alerta a 80% (heredado del banner del sistema viejo).
/// - Crítico a 100% = superó la vida estimada de la marca.
/// Ajustables a futuro (por Santiago, o por modelo si hiciera falta).
const double kUmbralAlertaDesgaste = 80;
const double kUmbralCriticoDesgaste = 100;

/// Deriva el nivel de desgaste del % de vida consumida. PURA.
///
/// `porcentajeVidaConsumida` viene de `Montaje.porcentajeVidaConsumida(...)`
/// (puede pasar de 100%). `null` → [NivelDesgaste.sinDatos].
NivelDesgaste nivelDesgaste(
  double? porcentajeVidaConsumida, {
  double umbralAlerta = kUmbralAlertaDesgaste,
  double umbralCritico = kUmbralCriticoDesgaste,
}) {
  final p = porcentajeVidaConsumida;
  if (p == null) return NivelDesgaste.sinDatos;
  if (p >= umbralCritico) return NivelDesgaste.critico;
  if (p >= umbralAlerta) return NivelDesgaste.alerta;
  return NivelDesgaste.ok;
}
