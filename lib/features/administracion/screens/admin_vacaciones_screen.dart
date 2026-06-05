// lib/features/administracion/screens/admin_vacaciones_screen.dart
//
// Submenú "Vacaciones" — gestión de vacaciones del personal.
//
// PLACEHOLDER. Estructura lista para que Santiago arme el módulo: AppScaffold
// del sistema (gesto Núcleo + back automático) + AppCard con estado y un
// hueco para que defina el primer flujo (solicitar / calendario / saldo).
//
// Cuando se sepa el modelo de datos, lo más probable es que viva en una
// colección Firestore tipo `VACACIONES` con docs por solicitud (chofer +
// fechas + estado: solicitada/aprobada/rechazada). El admin acá vería la
// lista, podría aprobar/rechazar y consultar el saldo por chofer.

import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Pantalla de Vacaciones — actualmente placeholder. Se rellena con la
/// lógica concreta cuando esté definido el flujo operativo (Santiago).
class AdminVacacionesScreen extends StatelessWidget {
  const AdminVacacionesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppScaffold(
      title: 'Vacaciones',
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: AppCard(
              glow: true,
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: c.surface3,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Icon(Icons.beach_access_outlined,
                            size: 16, color: c.brand),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      const AppEyebrow('En construcción'),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Vacaciones',
                    style: AppType.h4.copyWith(color: c.text),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Acá vamos a gestionar las vacaciones del personal: '
                    'solicitudes, calendario y saldo por empleado. Falta '
                    'definir el flujo (Santiago va sumando lo que viene).',
                    style: AppType.bodySm.copyWith(color: c.textSecondary),
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
