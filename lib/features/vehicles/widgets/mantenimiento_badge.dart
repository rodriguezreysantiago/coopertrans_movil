import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';

/// Color y etiqueta de cada estado del mantenimiento preventivo,
/// para que cualquier pantalla que muestre un tractor con su distancia
/// al próximo service use el mismo lenguaje visual.
///
/// Patrón espejo de `VencimientoEstadoX` en `vencimiento_badge.dart`.
extension MantenimientoEstadoX on MantenimientoEstado {
  Color get color {
    switch (this) {
      case MantenimientoEstado.vencido:
        return AppColors.error;
      case MantenimientoEstado.urgente:
        return AppColors.warning;
      case MantenimientoEstado.programar:
        return AppColors.warning;
      case MantenimientoEstado.atencion:
        // Lima/limón — más claro que amber, indica "todavía hay margen
        // pero conviene tenerlo en el radar".
        return const Color(0xFFC6FF00);
      case MantenimientoEstado.ok:
        return AppColors.success;
      case MantenimientoEstado.sinDato:
        return Colors.white24;
    }
  }
}

/// Badge visual del estado de mantenimiento. Muestra:
///   - "VENCIDO" cuando serviceDistance ≤ 0
///   - "X km" cuando hay datos válidos (X = km al próximo service, redondeado)
///   - "Sin datos" cuando no recibimos serviceDistance del API
class MantenimientoBadge extends StatelessWidget {
  /// KM restantes al próximo service. Negativo = vencido. Null = sin dato.
  final double? serviceDistanceKm;
  final bool compact;

  const MantenimientoBadge({
    super.key,
    required this.serviceDistanceKm,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final estado = AppMantenimiento.clasificar(serviceDistanceKm);

    final texto = switch (estado) {
      MantenimientoEstado.vencido => 'VENCIDO',
      MantenimientoEstado.sinDato => 'Sin datos',
      _ => '${serviceDistanceKm!.round()} km',
    };

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: estado.color.withAlpha(25),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: estado.color.withAlpha(80)),
      ),
      child: Text(
        texto,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: estado.color,
          fontSize: compact ? 9 : 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
