import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';

// 10 widgets visuales (seccion unidad, cards de revision/sin-asignacion/
// unidad, bloque telemetria, datos, filas, selector de cambio, lista
// libres) extraidos para mantener navegable este screen. Comparten
// privacidad via `part of`.
part 'user_mi_equipo_widgets.dart';

/// Pantalla del chofer: ver y gestionar su equipo asignado (tractor + enganche).
///
/// Permite solicitar un cambio de unidad. La solicitud queda pendiente
/// hasta que el admin la apruebe.
class UserMiEquipoScreen extends StatefulWidget {
  final String dniUser;

  const UserMiEquipoScreen({super.key, required this.dniUser});

  @override
  State<UserMiEquipoScreen> createState() => _UserMiEquipoScreenState();
}

class _UserMiEquipoScreenState extends State<UserMiEquipoScreen> {
  late final Stream<DocumentSnapshot> _empleadoStream;
  late final Stream<QuerySnapshot> _solicitudesStream;

  @override
  void initState() {
    super.initState();
    _empleadoStream = FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .doc(widget.dniUser)
        .snapshots();
    _solicitudesStream = FirebaseFirestore.instance
        .collection(AppCollections.revisiones)
        .where('dni', isEqualTo: widget.dniUser)
        .where('tipo_solicitud', isEqualTo: 'CAMBIO_EQUIPO')
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Mi Equipo Asignado',
      body: StreamBuilder<DocumentSnapshot>(
        stream: _empleadoStream,
        builder: (context, empSnap) {
          if (empSnap.hasError) {
            return AppErrorState(
              title: 'No se pudo cargar tu perfil',
              subtitle: empSnap.error.toString(),
            );
          }
          if (empSnap.connectionState == ConnectionState.waiting) {
            return const AppLoadingState();
          }
          if (!empSnap.hasData || !empSnap.data!.exists) {
            return const AppErrorState(
              title: 'Error al cargar perfil',
              subtitle: 'No se encontraron tus datos.',
            );
          }

          final empleado = empSnap.data!.data() as Map<String, dynamic>;
          final nombreChofer = (empleado['NOMBRE'] ?? 'Chofer').toString();
          final patenteVehiculo =
              (empleado['VEHICULO'] ?? '').toString().trim();
          final patenteEnganche =
              (empleado['ENGANCHE'] ?? '').toString().trim();

          return StreamBuilder<QuerySnapshot>(
            stream: _solicitudesStream,
            builder: (context, soliSnap) {
              final solicitudes = soliSnap.data?.docs ?? [];

              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _SeccionUnidad(
                    titulo: 'TRACTOR / CHASIS',
                    icono: Icons.local_shipping_outlined,
                    patente: patenteVehiculo,
                    solicitudes: solicitudes,
                    claveSolicitud: 'SOLICITUD_VEHICULO',
                    nombreChofer: nombreChofer,
                    dni: widget.dniUser,
                  ),
                  const SizedBox(height: 24),
                  _SeccionUnidad(
                    titulo: 'ENGANCHE (Batea/Tolva)',
                    icono: Icons.grid_view_rounded,
                    patente: patenteEnganche,
                    solicitudes: solicitudes,
                    claveSolicitud: 'SOLICITUD_ENGANCHE',
                    nombreChofer: nombreChofer,
                    dni: widget.dniUser,
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

