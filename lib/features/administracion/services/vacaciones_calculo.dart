// lib/features/administracion/services/vacaciones_calculo.dart
//
// Cálculo de los días de vacaciones que corresponden por antigüedad, según
// la Ley de Contrato de Trabajo (LCT) argentina, art. 150 y 151.
//
// LÓGICA PURA (sin Firestore, sin UI) → 100% testeable. La usa el módulo de
// Vacaciones para autocompletar "días que corresponden" desde la fecha de
// ingreso del empleado (que ya vive en EMPLEADOS), dejando override manual
// para los casos proporcionales del primer año.
//
// Validado contra el Excel real "VACACIONES 2025" de Vecchi: 69/72 coinciden
// exacto por escala; los 3 restantes son proporcionales de primer año (art.
// 151), que dependen de días EFECTIVAMENTE trabajados y se ajustan a mano.

/// Resultado del cálculo de días por antigüedad.
class DiasVacaciones {
  /// Días corridos de vacaciones que corresponden.
  final int dias;

  /// `true` si es un proporcional del primer año (art. 151): el valor es un
  /// ESTIMADO y conviene verificarlo a mano (depende de días trabajados
  /// reales, no calculables sin parte de asistencia).
  final bool esProporcional;

  /// Texto corto explicando el cálculo (para mostrar en la UI / tooltip).
  final String detalle;

  const DiasVacaciones({
    required this.dias,
    required this.esProporcional,
    required this.detalle,
  });

  @override
  String toString() =>
      'DiasVacaciones(dias: $dias, proporcional: $esProporcional, "$detalle")';
}

/// Días de vacaciones por antigüedad al 31/12 del [anio], según LCT art. 150:
///   - hasta 5 años   → 14 días
///   - +5 a 10 años   → 21 días
///   - +10 a 20 años  → 28 días
///   - +20 años       → 35 días
/// y art. 151 (primer año, ingreso en la 2da mitad → no llega a 6 meses al
/// 31/12) → proporcional ESTIMADO (1 día cada ~20 corridos), marcado para
/// ajuste manual.
///
/// La antigüedad se computa al **31 de diciembre del año al que corresponden**
/// las vacaciones (criterio LCT), no a la fecha actual.
DiasVacaciones calcularDiasVacacionesLct({
  required DateTime ingreso,
  required int anio,
}) {
  // Normalizar a fecha (sin hora) para que las comparaciones sean por día.
  final ing = DateTime(ingreso.year, ingreso.month, ingreso.day);
  final corte = DateTime(anio, 12, 31);

  // Ingresó después del cierre del año → todavía no devenga nada.
  if (ing.isAfter(corte)) {
    return const DiasVacaciones(
      dias: 0,
      esProporcional: false,
      detalle: 'Ingreso posterior al período — 0 días',
    );
  }

  // Proporcional del primer año: ingresó en ESTE año y en la segunda mitad
  // (después del 30/6) → al 31/12 no tiene 6 meses → art. 151.
  final mitadDeAnio = DateTime(anio, 6, 30);
  if (ing.year == anio && ing.isAfter(mitadDeAnio)) {
    final diasCorridos = corte.difference(ing).inDays + 1; // inclusive
    // 1 día cada 20 (estimado conservador sobre corridos). El número fino
    // depende de días trabajados efectivos → se ajusta a mano.
    final prop = (diasCorridos / 20).round();
    return DiasVacaciones(
      dias: prop,
      esProporcional: true,
      detalle: 'Proporcional 1er año (~$diasCorridos días) — verificar a mano',
    );
  }

  // Escala por antigüedad (años con decimales, para que el umbral "más de N"
  // sea exacto al día).
  final antiguedadAnios = corte.difference(ing).inDays / 365.25;
  final aniosTxt = antiguedadAnios.toStringAsFixed(1);
  if (antiguedadAnios <= 5) {
    return DiasVacaciones(
      dias: 14,
      esProporcional: false,
      detalle: 'Hasta 5 años ($aniosTxt) → 14 días',
    );
  }
  if (antiguedadAnios <= 10) {
    return DiasVacaciones(
      dias: 21,
      esProporcional: false,
      detalle: '+5 a 10 años ($aniosTxt) → 21 días',
    );
  }
  if (antiguedadAnios <= 20) {
    return DiasVacaciones(
      dias: 28,
      esProporcional: false,
      detalle: '+10 a 20 años ($aniosTxt) → 28 días',
    );
  }
  return DiasVacaciones(
    dias: 35,
    esProporcional: false,
    detalle: '+20 años ($aniosTxt) → 35 días',
  );
}
