// lib/shared/widgets/app_data_table.dart
//
// REFACTOR NÚCLEO · jun 2026 — tabla densa.
//
// Para reportes y listas admin en DESKTOP donde una grilla de cards sería
// demasiado (muchas filas × pocas columnas comparables). Header en eyebrow,
// filas separadas por hairline, hover sutil, columnas numéricas alineadas a
// la derecha. En móvil preferimos cards (AppCard); esta tabla es para anchos.
//
// USO:
//   AppDataTable(
//     columns: const [
//       AppDataColumn('Chofer', flex: 2),
//       AppDataColumn('Viajes', numeric: true),
//       AppDataColumn('Total', numeric: true),
//     ],
//     rows: [
//       AppDataRow(cells: [
//         AppDataCell.text('PEREZ, Juan'),
//         AppDataCell.number('12'),
//         AppDataCell.number('\$1.240.000'),
//       ], onTap: () => abrir('juan')),
//     ],
//   );

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// Definición de una columna de [AppDataTable].
class AppDataColumn {
  /// Encabezado (se muestra en eyebrow / mayúsculas).
  final String label;

  /// Peso relativo del ancho (como `Expanded.flex`).
  final int flex;

  /// Columna de números (plata, contadores): alinea su contenido a la
  /// derecha. Las celdas conviene pasarlas con [AppDataCell.number] (mono).
  final bool numeric;

  const AppDataColumn(this.label, {this.flex = 1, this.numeric = false});
}

/// Una fila de [AppDataTable]. `cells.length` debe coincidir con `columns`.
class AppDataRow {
  final List<Widget> cells;
  final VoidCallback? onTap;
  const AppDataRow({required this.cells, this.onTap});
}

/// Helpers para las celdas de texto más comunes (evita repetir Text + estilo).
/// Para celdas custom (badges, íconos) pasá cualquier Widget directamente.
abstract final class AppDataCell {
  /// Celda de texto normal.
  static Widget text(String value, {bool strong = false}) =>
      _Cell(value, mono: false, strong: strong);

  /// Celda numérica (mono, para plata/contadores/fechas).
  static Widget number(String value, {bool strong = false}) =>
      _Cell(value, mono: true, strong: strong);
}

class _Cell extends StatelessWidget {
  final String value;
  final bool mono;
  final bool strong;
  const _Cell(this.value, {required this.mono, required this.strong});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      value,
      style: (mono ? AppType.mono : AppType.body).copyWith(
        color: c.text,
        fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Tabla densa Núcleo. Ver la cabecera del archivo.
class AppDataTable extends StatelessWidget {
  final List<AppDataColumn> columns;
  final List<AppDataRow> rows;

  /// Padding horizontal de cada celda/encabezado.
  final double hGap;

  const AppDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.hGap = AppSpacing.md,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header — eyebrow + hairline marcada abajo.
        Padding(
          padding:
              EdgeInsets.symmetric(horizontal: hGap, vertical: AppSpacing.sm),
          child: Row(
            children: [
              for (final col in columns)
                Expanded(
                  flex: col.flex,
                  child: Text(
                    col.label.toUpperCase(),
                    textAlign:
                        col.numeric ? TextAlign.right : TextAlign.left,
                    style: AppType.eyebrow.copyWith(color: c.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
        Container(height: 1, color: c.borderStrong),
        // Filas — hairline sutil entre cada una.
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Container(height: 1, color: c.border),
          _RowView(row: rows[i], columns: columns, hGap: hGap),
        ],
      ],
    );
  }
}

class _RowView extends StatelessWidget {
  final AppDataRow row;
  final List<AppDataColumn> columns;
  final double hGap;
  const _RowView({
    required this.row,
    required this.columns,
    required this.hGap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: hGap, vertical: AppSpacing.md),
      child: Row(
        children: [
          for (var j = 0; j < columns.length; j++)
            Expanded(
              flex: columns[j].flex,
              child: Align(
                alignment: columns[j].numeric
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: j < row.cells.length ? row.cells[j] : const SizedBox(),
              ),
            ),
        ],
      ),
    );
    if (row.onTap == null) return content;
    return InkWell(
      onTap: row.onTap,
      hoverColor: c.surfaceHover.withValues(alpha: 0.3),
      highlightColor: c.surfaceHover.withValues(alpha: 0.5),
      child: content,
    );
  }
}
