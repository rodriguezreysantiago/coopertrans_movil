/// Helpers para calcular `childAspectRatio` de GridViews que tienen que
/// llenar todo el alto disponible sin scrollear.
///
/// **Por qué existe**: el patrón "hub responsive" (Gomería / Logística /
/// main_panel del chofer) calcula el ratio dinámicamente según los
/// constraints reales del LayoutBuilder, en lugar de fijar
/// `childAspectRatio: 1.1` constante. Antes de centralizar acá, cada
/// hub repetía el mismo cálculo inline con leves variaciones — los
/// edge cases (alto cero, clamp inferior) se trataban distinto en
/// cada uno y eran difíciles de testear.
///
/// Función pura (sin dependencias de Flutter), testeable directo desde
/// `flutter test` sin overhead de widget tester.
library;

/// Calcula el `childAspectRatio` para un GridView que tiene que llenar
/// `boxWidth × boxHeight` con `cols × rows` celdas + `spacing` entre
/// ellas, conservando proporción razonable (con clamp).
///
/// - [boxWidth]: ancho disponible (típicamente `constraints.maxWidth`).
/// - [boxHeight]: alto disponible (típicamente `constraints.maxHeight`).
/// - [cols]: cantidad de columnas del grid.
/// - [rows]: cantidad de filas — calcular como `(N / cols).ceil()` desde
///   el caller.
/// - [spacing]: separación entre celdas (mismo valor para crossAxis y
///   mainAxis — los hubs usan idéntico horizontal/vertical).
/// - [clampMin]: ratio mínimo permitido (cards muy altas y angostas).
///   Default 0.45 — abajo de eso queda casi imposible de tappear.
/// - [clampMax]: ratio máximo permitido (cards muy anchas y bajas).
///   Default 2.0 — arriba de eso el ícono+texto del tile se ve raro.
/// - [fallback]: ratio a devolver si los constraints son inválidos
///   (alto ≤ 0, cols ≤ 0, rows ≤ 0). Default 1.0 (cuadrado).
double computeGridRatio({
  required double boxWidth,
  required double boxHeight,
  required int cols,
  required int rows,
  required double spacing,
  double clampMin = 0.45,
  double clampMax = 2.0,
  double fallback = 1.0,
}) {
  // Defensivo: si algún input es absurdo, devolvemos el fallback en
  // lugar de generar NaN o ratio negativo (que crashearía el GridView).
  if (cols <= 0 || rows <= 0 || boxWidth <= 0 || boxHeight <= 0) {
    return fallback;
  }
  final cellWidth = (boxWidth - spacing * (cols - 1)) / cols;
  final cellHeight = (boxHeight - spacing * (rows - 1)) / rows;
  // Si el spacing se come todo el espacio (caso extremo de pantalla
  // absurdamente chica), también caemos al fallback.
  if (cellWidth <= 0 || cellHeight <= 0) return fallback;
  final raw = cellWidth / cellHeight;
  return raw.clamp(clampMin, clampMax);
}
