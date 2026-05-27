import 'package:flutter/material.dart';
import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
import 'package:flutter/services.dart'; // ✅ Necesario para el feedback háptico

class MenuCard extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final Color color;
  final VoidCallback onTap;

  const MenuCard({
    super.key,
    required this.titulo,
    required this.icono,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true, // Indica al sistema que es un elemento clickeable
      label: "Botón para $titulo",
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withAlpha(15)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(50),
              blurRadius: 10,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                // ✅ MEJORA PRO: Vibración sutil al tocar para confirmar la acción
                HapticFeedback.lightImpact();
                onTap();
              },
              // El color del splash (el efecto al tocar) se adapta al color del ícono
              splashColor: color.withAlpha(30),
              highlightColor: color.withAlpha(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Contenedor del ícono con acento de color
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    decoration: BoxDecoration(
                      color: color.withAlpha(25), 
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icono, 
                      size: 38, 
                      color: color, 
                    ),
                  ),
                  const SizedBox(height: 15),
                  // Texto del menú
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: Text(
                      titulo,
                      textAlign: TextAlign.center,
                      maxLines: 2, // ✅ MEJORA PRO: Evita que el texto deforme la tarjeta
                      overflow: TextOverflow.ellipsis, // Si es muy largo, pone "..."
                      style: AppType.label.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}