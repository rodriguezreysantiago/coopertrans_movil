import 'package:flutter/material.dart';

import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/registro_jornada.dart';
import '../services/registro_jornada_service.dart';
import '../widgets/registro_jornada_card.dart';

/// "Mi jornada" — el chofer ve su propio registro de jornada (v3): por cada
/// turno, el manejo neto, las pausas con su motivo (motor apagado / detenido),
/// los km recorridos y la confianza del dato. Transparencia: el chofer puede
/// revisar y entender qué registró el sistema (Paso 2 del plan vigilador v3).
///
/// Lee `REGISTRO_JORNADAS` filtrado a su propio DNI (la regla de Firestore se
/// lo permite). Solo lectura.
class MiJornadaScreen extends StatelessWidget {
  const MiJornadaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dni = PrefsService.dni;
    return AppScaffold(
      title: 'Mi jornada',
      body: StreamBuilder<List<RegistroJornada>>(
        stream: RegistroJornadaService.streamUltimasDelChofer(choferDni: dni),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return const AppErrorState(
              title: 'No se pudo cargar tu jornada',
              subtitle: 'Probá de nuevo en un rato.',
            );
          }
          if (!snap.hasData) {
            return const AppLoadingState(message: 'Cargando tu jornada…');
          }
          final jornadas = snap.data!;
          if (jornadas.isEmpty) {
            return const AppEmptyState(
              icon: Icons.route_outlined,
              title: 'Todavía no hay jornadas registradas',
              subtitle: 'Tu jornada del día queda registrada a la mañana '
                  'siguiente.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: jornadas.length + 1,
            separatorBuilder: (_, __) =>
                const SizedBox(height: AppSpacing.md),
            itemBuilder: (ctx, i) {
              if (i == 0) return const _Intro();
              return RegistroJornadaCard(j: jornadas[i - 1]);
            },
          );
        },
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs, left: 2, right: 2),
      child: Text(
        'Acá ves cómo quedó registrada tu jornada cada día: tus horas de '
        'manejo y tus paradas. Si algo no coincide, avisale al encargado.',
        style: AppType.label.copyWith(color: c.textMuted),
      ),
    );
  }
}
