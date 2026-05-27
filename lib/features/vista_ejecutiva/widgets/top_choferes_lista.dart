// Lista compacta de top N choferes — usada en el hub ICM para "Top 5
// mejores" y "Top 5 a mejorar". Cada item es tappable y navega al
// detalle del chofer (mismo destino que el tap desde el ranking).

import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/vista_ejecutiva_service.dart';

class TopChoferesLista extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final Color colorTitulo;
  final List<ChoferRankingItem> items;
  final String? mensajeVacio;

  const TopChoferesLista({
    super.key,
    required this.titulo,
    required this.icono,
    required this.colorTitulo,
    required this.items,
    this.mensajeVacio,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icono, color: colorTitulo, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  titulo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorTitulo,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  mensajeVacio ?? 'Sin datos de la semana cerrada',
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            )
          else
            ...List.generate(items.length, (i) {
              final c = items[i];
              return _ChoferRow(
                puesto: i + 1,
                chofer: c,
                onTap: c.dni.isEmpty
                    ? null
                    : () => Navigator.pushNamed(
                          context,
                          AppRoutes.adminIcmDetalleChofer,
                          arguments: c.dni,
                        ),
              );
            }),
        ],
      ),
    );
  }
}

class _ChoferRow extends StatelessWidget {
  final int puesto;
  final ChoferRankingItem chofer;
  /// `null` desactiva el tap (chofer sin DNI no tiene detalle al que ir).
  final VoidCallback? onTap;

  const _ChoferRow({
    required this.puesto,
    required this.chofer,
    required this.onTap,
  });

  Color get _colorBadge {
    switch (chofer.categoria) {
      case 'verde':
        return AppColors.success;
      case 'amarillo':
        return AppColors.warning;
      case 'rojo':
        return AppColors.error;
      default:
        return Colors.white24;
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            // Puesto
            SizedBox(
              width: 24,
              child: Text(
                '$puesto°',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 4),
            // Nombre del chofer
            Expanded(
              child: Text(
                chofer.nombre,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Badge con ICM
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _colorBadge.withAlpha(35),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _colorBadge.withAlpha(140),
                  width: 1,
                ),
              ),
              child: Text(
                chofer.icm.toStringAsFixed(0),
                style: TextStyle(
                  color: _colorBadge,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right,
                  color: Colors.white24, size: 16),
            ],
          ],
        ),
      ),
    );
  }
}
