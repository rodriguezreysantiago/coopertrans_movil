import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import 'vencimiento_item.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
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
          ? AppColors.error.withAlpha(120)
          : esCritica
              ? AppColors.warning.withAlpha(120)
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
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${item.tipoDoc} · ${AppFormatters.formatearFecha(item.fecha)}',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
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
