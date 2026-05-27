import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import '../utils/formatters.dart';

/// Estados posibles de un vencimiento, según los días restantes.
enum VencimientoEstado {
  vencido, // dias < 0
  critico, // dias <= 14
  proximo, // dias <= 30
  ok, // dias > 30
  sinFecha, // campo nunca cargado
  invalida, // campo cargado pero no parseable (typo en consola, dato corrupto)
}

/// Color y semántica de cada estado, en un solo lugar.
extension VencimientoEstadoX on VencimientoEstado {
  Color get color {
    switch (this) {
      case VencimientoEstado.vencido:
        return AppColors.accentRed;
      case VencimientoEstado.critico:
        return AppColors.accentOrange;
      case VencimientoEstado.proximo:
        return AppColors.accentAmber;
      case VencimientoEstado.ok:
        return AppColors.success;
      case VencimientoEstado.sinFecha:
        return Colors.white24;
      case VencimientoEstado.invalida:
        return AppColors.accentRed;
    }
  }
}

/// Calcula el estado a partir de los días restantes.
///
/// Tri-state según [tieneFecha] y [dias]:
/// - `!tieneFecha` → `sinFecha` (gris, neutro: nunca se cargó)
/// - `tieneFecha && dias == null` → `invalida` (rojo: hay valor pero
///   no parsea — typo manual en consola, migración rota, dato corrupto.
///   No silenciar)
/// - `dias != null` → vencido / critico / proximo / ok según valor
VencimientoEstado calcularEstadoVencimiento(
  int? dias, {
  bool tieneFecha = true,
}) {
  if (!tieneFecha) return VencimientoEstado.sinFecha;
  if (dias == null) return VencimientoEstado.invalida;
  if (dias < 0) return VencimientoEstado.vencido;
  if (dias <= 14) return VencimientoEstado.critico;
  if (dias <= 30) return VencimientoEstado.proximo;
  return VencimientoEstado.ok;
}

/// Badge visual del estado de vencimiento. Muestra:
/// - "VENCIDO" si dias < 0
/// - "Sin fecha" si no hay fecha cargada
/// - "Nd" en caso normal
///
/// Una sola fuente de verdad para colores y umbrales en toda la app.
/// Antes esto estaba duplicado en 5+ pantallas con pequeñas variaciones.
class VencimientoBadge extends StatelessWidget {
  final dynamic fecha;
  final double? width;
  final bool compact;

  const VencimientoBadge({
    super.key,
    required this.fecha,
    this.width,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final tieneFecha = fecha != null && fecha.toString().isNotEmpty;
    final dias = AppFormatters.calcularDiasRestantes(fecha ?? '');
    final estado = calcularEstadoVencimiento(dias, tieneFecha: tieneFecha);

    final texto = switch (estado) {
      VencimientoEstado.vencido => 'VENCIDO',
      VencimientoEstado.sinFecha => 'Sin fecha',
      VencimientoEstado.invalida => 'Inválida',
      _ => '${dias}d',
    };

    return Container(
      width: width,
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
