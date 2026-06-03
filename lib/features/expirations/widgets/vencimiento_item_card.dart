import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import 'vencimiento_item.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Card de auditoría de un vencimiento.
///
/// Reusable entre las 3 pantallas de listas (choferes, chasis, acoplados).
/// Muestra:
/// - Thumbnail del archivo (PDF/imagen) — usando [AppFileThumbnail]
/// - Título (nombre del chofer o "TIPO - patente")
/// - Subtítulo: tipo de documento + fecha
/// - Badge de días restantes — usando [VencimientoBadge]
class VencimientoItemCard extends StatelessWidget {
  final VencimientoItem item;
  final VoidCallback onTap;

  const VencimientoItemCard({
    super.key,
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dias = item.dias;
    // Inválida (dias == null) la tratamos como peor que vencida:
    // borde rojo + highlight, así se ve a la primera que algo está mal
    // con el dato y nadie pasa de largo creyendo que vence en X dias.
    final esInvalida = dias == null;
    final esVencida = dias != null && dias < 0;
    final esCritica = dias != null && dias <= 14;
    return AppCard(
      onTap: onTap,
      highlighted: esInvalida || esCritica,
      borderColor: esInvalida || esVencida
          ? c.error.withValues(alpha: 0.47)
          : esCritica
              ? c.warning.withValues(alpha: 0.47)
              : null,
      child: Row(
        children: [
          AppFileThumbnail(
            url: item.urlArchivo,
            tituloVisor: '${item.tipoDoc} - ${item.docId}',
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.titulo,
                  style: AppType.bodyLg
                      .copyWith(color: c.text, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.tipoDoc,
                        style: AppType.bodySm.copyWith(color: c.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text('  ·  ',
                        style: AppType.bodySm.copyWith(color: c.textMuted)),
                    Text(
                      AppFormatters.formatearFecha(item.fecha),
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          VencimientoBadge(fecha: item.fecha),
        ],
      ),
    );
  }
}
