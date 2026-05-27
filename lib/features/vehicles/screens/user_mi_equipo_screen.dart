import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
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

  /// Pasa a `true` si pasan más de 10s sin que Firestore responda.
  /// Mostramos UI degradada en lugar de "Error al cargar perfil"
  /// (caso celus lentos — ver mi_perfil_screen para más contexto).
  bool _conexionLenta = false;
  Timer? _slowConnTimer;

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
    _slowConnTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _conexionLenta = true);
    });
  }

  @override
  void dispose() {
    _slowConnTimer?.cancel();
    super.dispose();
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
          // Sin data todavía: si pasaron >10s sin respuesta, fallback
          // con datos básicos cacheados + banner de conexión lenta.
          if (empSnap.connectionState == ConnectionState.waiting ||
              !empSnap.hasData) {
            if (_conexionLenta) {
              return const _EquipoOfflineFallback();
            }
            return const AppLoadingState();
          }
          if (!empSnap.data!.exists) {
            return const _EquipoOfflineFallback(
              motivo: 'Tu legajo no está disponible en este momento. '
                  'Contactá a administración.',
            );
          }

          // Cast defensivo: si el doc llegara con shape inesperado,
          // devolvemos error en lugar de crashear (mismo patrón que
          // user_mi_perfil_screen + user_mis_vencimientos_screen).
          final raw = empSnap.data!.data();
          if (raw is! Map<String, dynamic>) {
            return const AppErrorState(
              title: 'Datos corruptos',
              subtitle:
                  'El formato de tu legajo no es válido. Contactá a la oficina.',
            );
          }
          final empleado = raw;
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
                  const SizedBox(height: AppSpacing.xl),
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

/// UI degradada para conexión lenta o doc no disponible. Muestra el
/// nombre cacheado del chofer + banner naranja + indicador de carga.
/// El stream sigue activo en background; cuando llegue, este widget
/// se reemplaza solo con la vista completa.
class _EquipoOfflineFallback extends StatelessWidget {
  final String? motivo;

  const _EquipoOfflineFallback({this.motivo});

  @override
  Widget build(BuildContext context) {
    final nombre = PrefsService.apodo.trim().isNotEmpty
        ? PrefsService.apodo.trim()
        : PrefsService.nombre.trim();

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.warning.withAlpha(40),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.warning.withAlpha(120)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.signal_wifi_bad_outlined,
                  color: AppColors.warning),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      motivo == null ? 'Conexión lenta' : 'Datos incompletos',
                      style: const TextStyle(
                        color: AppColors.warning,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      motivo ??
                          'No pudimos cargar los datos de tu unidad. '
                              'Probá cambiar de red (WiFi / datos móviles) '
                              'o reintentar en unos minutos.',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 30),
        if (nombre.isNotEmpty)
          Text(
            'Hola, $nombre',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 30),
        if (motivo == null)
          const Center(
            child: Column(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.info,
                  ),
                ),
                SizedBox(height: 10),
                Text(
                  'Cargando datos de tu unidad…',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
