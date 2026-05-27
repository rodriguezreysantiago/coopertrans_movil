import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/audit_log_service.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../utils/etiquetas_alerta_volvo.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
/// Bottom sheet con el detalle de UN evento de VOLVO_ALERTAS.
///
/// Se muestra al tappear un marker en `AdminMapaVolvoScreen`. Permite
/// revisar la info del evento y marcarlo como atendido (mismo flujo que
/// el tablero "Alertas").
class EventoVolvoDetalleSheet extends StatelessWidget {
  final String alertId;
  final Map<String, dynamic> data;

  const EventoVolvoDetalleSheet({
    super.key,
    required this.alertId,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    final severidad = (data['severidad'] ?? '').toString().toUpperCase();
    final patente = (data['patente'] ?? '—').toString();
    final atendida = data['atendida'] == true;
    final atendidaPor = (data['atendida_por'] ?? '').toString();
    final creado = (data['creado_en'] as Timestamp?)?.toDate();
    final choferNombre = (data['chofer_nombre'] ?? '').toString().trim();
    final choferDni = (data['chofer_dni'] ?? '').toString().trim();
    final chofer = choferNombre.isNotEmpty
        ? choferNombre
        : choferDni.isNotEmpty
            ? 'DNI $choferDni'
            : '—';
    final gps = data['posicion_gps'] as Map<String, dynamic>?;
    final lat = (gps?['lat'] as num?)?.toDouble();
    final lng = (gps?['lng'] as num?)?.toDouble();

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: _colorSeveridad(severidad).withAlpha(60)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      patente,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // Resuelve subtipo cuando el tipo es GENERIC
                      // (SEATBELT, TELL_TALE, etc.) para evitar el
                      // genérico "Evento genérico" que no informa nada.
                      etiquetaAlertaVolvoFromDoc(data),
                      style: TextStyle(
                        color: _colorSeveridad(severidad),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              _SeveridadBadge(severidad: severidad, atendida: atendida),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _Linea(
            label: 'Cuándo',
            valor: AppFormatters.formatearFechaHoraSinSegundos(creado),
          ),
          _Linea(label: 'Chofer', valor: chofer),
          if (lat != null && lng != null)
            _LineaConAccion(
              label: 'Ubicación',
              valor: '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
              icono: Icons.open_in_new,
              onTap: () => _abrirMaps(lat, lng),
            ),
          if (atendida) ...[
            const SizedBox(height: AppSpacing.sm),
            _Linea(
              label: 'Atendida por',
              valor: atendidaPor.isEmpty ? '—' : atendidaPor,
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white54,
                    side: BorderSide(color: Colors.white.withAlpha(40)),
                  ),
                  child: const Text('Cerrar'),
                ),
              ),
              if (!atendida) ...[
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _marcarAtendida(context),
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Marcar atendida'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success.withAlpha(180),
                      foregroundColor: Colors.black,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _abrirMaps(double lat, double lng) async {
    final uri = Uri.parse('https://www.google.com/maps?q=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _marcarAtendida(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final dni = PrefsService.dni;
    if (dni.isEmpty) {
      AppFeedback.errorOn(messenger, 'Sin sesión activa.');
      return;
    }
    try {
      await FirebaseFirestore.instance
          .collection(AppCollections.volvoAlertas)
          .doc(alertId)
          .update({
        'atendida': true,
        'atendida_por': dni,
        'atendida_en': FieldValue.serverTimestamp(),
      });
      // Bitácora server-side. Fire-and-forget.
      unawaited(AuditLog.registrar(
        accion: AuditAccion.marcarAlertaVolvoAtendida,
        entidad: 'VOLVO_ALERTAS',
        entidadId: alertId,
        detalles: {
          'tipo': (data['tipo'] ?? '').toString(),
          'severidad': (data['severidad'] ?? '').toString(),
          'patente': (data['patente'] ?? '').toString(),
          'origen': 'mapa',
        },
      ));
      if (context.mounted) Navigator.of(context).pop();
      AppFeedback.successOn(messenger, 'Alerta marcada como atendida.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo marcar la alerta como atendida. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }
}

class _Linea extends StatelessWidget {
  final String label;
  final String valor;
  const _Linea({required this.label, required this.valor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              valor,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _LineaConAccion extends StatelessWidget {
  final String label;
  final String valor;
  final IconData icono;
  final VoidCallback onTap;

  const _LineaConAccion({
    required this.label,
    required this.valor,
    required this.icono,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 90,
              child: Text(
                label,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            Expanded(
              child: Text(
                valor,
                style: const TextStyle(color: AppColors.info, fontSize: 13),
              ),
            ),
            Icon(icono, color: AppColors.info, size: 14),
          ],
        ),
      ),
    );
  }
}

class _SeveridadBadge extends StatelessWidget {
  final String severidad;
  final bool atendida;

  const _SeveridadBadge({required this.severidad, required this.atendida});

  @override
  Widget build(BuildContext context) {
    final color = atendida ? Colors.white38 : _colorSeveridad(severidad);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        atendida ? 'ATENDIDA' : severidad,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

Color _colorSeveridad(String severidad) {
  switch (severidad) {
    case 'HIGH':
      return AppColors.error;
    case 'MEDIUM':
      return AppColors.warning;
    case 'LOW':
      return AppColors.success;
    default:
      return Colors.white54;
  }
}

