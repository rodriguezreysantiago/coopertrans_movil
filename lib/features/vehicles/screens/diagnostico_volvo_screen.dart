import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/volvo_api_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Pantalla de diagnóstico de la API de Volvo.
///
/// Pega al endpoint `/vehiclestatuses?vin=...&additionalContent=VOLVOGROUPSNAPSHOT`
/// y muestra el response crudo. Pensada para investigar por qué cierto
/// vehículo no devuelve algunos campos (p. ej. nivel de combustible o
/// autonomía estimada).
///
/// Lo que muestra:
/// - URL consultada
/// - Status code + statusMessage + duración
/// - Análisis rápido: ✓ / ✗ por cada campo crítico
/// - JSON crudo formateado, scrollable, copiable al clipboard
class DiagnosticoVolvoScreen extends StatefulWidget {
  final String patente;
  final String vin;

  const DiagnosticoVolvoScreen({
    super.key,
    required this.patente,
    required this.vin,
  });

  @override
  State<DiagnosticoVolvoScreen> createState() =>
      _DiagnosticoVolvoScreenState();
}

class _DiagnosticoVolvoScreenState extends State<DiagnosticoVolvoScreen> {
  final VolvoApiService _api = VolvoApiService();
  VolvoDiagnostico? _resultado;
  bool _cargando = false;

  @override
  void initState() {
    super.initState();
    _ejecutar();
  }

  Future<void> _ejecutar() async {
    setState(() => _cargando = true);
    final r = await _api.diagnosticarStatus(widget.vin);
    if (!mounted) return;
    setState(() {
      _resultado = r;
      _cargando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Diagnóstico Volvo',
      body: _cargando
          ? const AppLoadingState()
          : _resultado == null
              ? const AppErrorState(title: 'Sin datos')
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    _Header(patente: widget.patente, vin: widget.vin),
                    const SizedBox(height: AppSpacing.lg),
                    _ResumenRequest(diag: _resultado!),
                    const SizedBox(height: AppSpacing.lg),
                    _AnalisisCampos(diag: _resultado!),
                    const SizedBox(height: AppSpacing.lg),
                    _JsonViewer(diag: _resultado!),
                    const SizedBox(height: AppSpacing.lg),
                    _BotonReintentar(onPressed: _ejecutar),
                  ],
                ),
    );
  }
}

// =============================================================================
// HEADER
// =============================================================================

class _Header extends StatelessWidget {
  final String patente;
  final String vin;
  const _Header({required this.patente, required this.vin});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Icon(Icons.bug_report, color: AppColors.warning, size: 28),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  patente.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'VIN $vin',
                  style: AppType.eyebrow.copyWith(color: Colors.white60, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// RESUMEN DEL REQUEST (status, tiempo, URL)
// =============================================================================

class _ResumenRequest extends StatelessWidget {
  final VolvoDiagnostico diag;
  const _ResumenRequest({required this.diag});

  Color get _statusColor {
    if (diag.errorMessage != null) return AppColors.error;
    final s = diag.statusCode ?? 0;
    if (s >= 200 && s < 300) return AppColors.success;
    if (s >= 400) return AppColors.warning;
    return Colors.white54;
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'REQUEST',
            style: TextStyle(
              color: AppColors.success,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          _Linea(
            etiqueta: 'Status',
            valor: diag.errorMessage != null
                ? 'EXCEPCIÓN'
                : '${diag.statusCode ?? "—"} ${diag.statusMessage ?? ""}',
            valorColor: _statusColor,
            negrita: true,
          ),
          _Linea(
            etiqueta: 'Tiempo',
            valor: '${diag.duracion.inMilliseconds} ms',
          ),
          _Linea(
            etiqueta: 'URL',
            valor: diag.urlConsultada,
            monoespaciado: true,
            multiline: true,
          ),
          if (diag.errorMessage != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.error.withAlpha(20),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.error.withAlpha(60)),
              ),
              child: Text(
                diag.errorMessage!,
                style: AppType.label.copyWith(color: AppColors.error, fontFamily: 'monospace'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// ANÁLISIS AUTOMÁTICO DE CAMPOS CRÍTICOS
// =============================================================================

class _AnalisisCampos extends StatelessWidget {
  final VolvoDiagnostico diag;
  const _AnalisisCampos({required this.diag});

  /// Devuelve una lista con el estado de cada campo que nos interesa.
  /// Cada item: (label, valor encontrado o null, profundidad/path).
  List<_CampoCheck> _analizar() {
    final checks = <_CampoCheck>[];
    final body = diag.rawBody;
    if (body is! Map) {
      return [
        _CampoCheck(
          label: 'Body es un Map',
          encontrado: false,
          path: '(root)',
          valor: '${body.runtimeType}',
        ),
      ];
    }

    final statuses = body['vehicleStatusResponse']?['vehicleStatuses'];
    if (statuses is! List || statuses.isEmpty) {
      return [
        _CampoCheck(
          label: 'vehicleStatuses[] no vacío',
          encontrado: false,
          path: 'vehicleStatusResponse.vehicleStatuses',
          valor: statuses == null
              ? 'null'
              : (statuses is List ? 'array vacío' : statuses.runtimeType.toString()),
        ),
      ];
    }

    final s = statuses[0];
    if (s is! Map) {
      return [
        _CampoCheck(
          label: 'vehicleStatuses[0] es Map',
          encontrado: false,
          path: 'vehicleStatuses[0]',
          valor: s.runtimeType.toString(),
        ),
      ];
    }

    // Helpers para descender en el árbol del status (los campos
    // interesantes están dentro de snapshotData / volvoGroupSnapshot).
    final snap = s['snapshotData'];
    final volvoSnap = (snap is Map) ? snap['volvoGroupSnapshot'] : null;

    // Odómetro
    final odo = s['hrTotalVehicleDistance'];
    checks.add(_CampoCheck(
      label: 'Odómetro',
      encontrado: odo != null,
      path: 'hrTotalVehicleDistance',
      valor: odo == null
          ? null
          : '$odo metros (${(odo / 1000).toStringAsFixed(0)} km)',
    ));

    // Combustible — primero en el path real, después fallbacks.
    String? fuelPath;
    dynamic fuelValue;
    if (snap is Map && snap['fuelLevel1'] != null) {
      fuelPath = 'snapshotData.fuelLevel1';
      fuelValue = snap['fuelLevel1'];
    } else {
      final fuelObj = s['fuelLevel'];
      if (fuelObj is Map && fuelObj['fuelLevel1'] != null) {
        fuelPath = 'fuelLevel.fuelLevel1';
        fuelValue = fuelObj['fuelLevel1'];
      } else if (s['fuelLevel1'] != null) {
        fuelPath = 'fuelLevel1';
        fuelValue = s['fuelLevel1'];
      }
    }
    checks.add(_CampoCheck(
      label: 'Combustible',
      encontrado: fuelPath != null,
      path: fuelPath ??
          'snapshotData.fuelLevel1 / fuelLevel.fuelLevel1 / fuelLevel1',
      valor: fuelPath != null
          ? '$fuelValue%'
          : 'No se encontró en ninguno de los paths conocidos.',
    ));

    // Autonomía — buscar en todos los contenedores conocidos.
    const subContainers = [
      'chargingStatusInfo',
      'volvoGroupChargingStatusInfo',
      'batteryPackInfo',
    ];
    final candidatos = <(String path, dynamic obj)>[
      if (volvoSnap is Map)
        ('snapshotData.volvoGroupSnapshot', volvoSnap),
      if (snap is Map) ('snapshotData', snap),
      ('(root)', s),
      for (final c in subContainers)
        if (s[c] is Map) (c, s[c]),
    ];

    String? autonPath;
    dynamic autonValor;
    String? autonField;
    for (final (path, container) in candidatos) {
      final edte = container['estimatedDistanceToEmpty'];
      if (edte is Map) {
        for (final field in const ['total', 'fuel', 'batteryPack', 'gas']) {
          final v = edte[field];
          if (v is num && v > 0) {
            autonPath = '$path.estimatedDistanceToEmpty.$field';
            autonValor = v;
            autonField = field;
            break;
          }
        }
        if (autonPath != null) break;
      }
    }
    if (autonPath != null) {
      final m = (autonValor as num).toDouble();
      checks.add(_CampoCheck(
        label: 'Autonomía',
        encontrado: true,
        path: autonPath,
        valor: '$autonValor metros '
            '(${(m / 1000).toStringAsFixed(0)} km, fuente: $autonField)',
      ));
    } else {
      checks.add(const _CampoCheck(
        label: 'Autonomía',
        encontrado: false,
        path: 'snapshotData.volvoGroupSnapshot.estimatedDistanceToEmpty',
        valor: 'No reportada por este vehículo.\n'
            'Habitual en algunos modelos diésel sin computadora avanzada.',
      ));
    }

    // Velocidad (bonus, útil para anti-robo): puede estar en snapshotData
    // o al primer nivel.
    dynamic wheelSpeed;
    String wheelPath = 'wheelBasedSpeed';
    if (snap is Map && snap['wheelBasedSpeed'] != null) {
      wheelSpeed = snap['wheelBasedSpeed'];
      wheelPath = 'snapshotData.wheelBasedSpeed';
    } else {
      wheelSpeed = s['wheelBasedSpeed'] ?? s['speed'];
    }
    checks.add(_CampoCheck(
      label: 'Velocidad',
      encontrado: wheelSpeed != null,
      path: wheelPath,
      valor: wheelSpeed != null ? '$wheelSpeed km/h' : null,
    ));

    // Posición GPS (bonus). También puede estar bajo snapshotData.
    dynamic gnss = s['gnssPosition'];
    String gnssPath = 'gnssPosition';
    if (gnss is! Map && snap is Map && snap['gnssPosition'] is Map) {
      gnss = snap['gnssPosition'];
      gnssPath = 'snapshotData.gnssPosition';
    }
    if (gnss is Map && gnss['latitude'] != null) {
      checks.add(_CampoCheck(
        label: 'Posición GPS',
        encontrado: true,
        path: gnssPath,
        valor: '${gnss['latitude']}, ${gnss['longitude']}',
      ));
    } else {
      checks.add(_CampoCheck(
        label: 'Posición GPS',
        encontrado: false,
        path: gnssPath,
        valor: 'No reportada.',
      ));
    }

    return checks;
  }

  @override
  Widget build(BuildContext context) {
    final checks = _analizar();
    return AppCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'CAMPOS CRÍTICOS',
            style: TextStyle(
              color: AppColors.success,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          ...checks.map((c) => _CheckTile(check: c)),
        ],
      ),
    );
  }
}

class _CampoCheck {
  final String label;
  final bool encontrado;
  final String path;
  final String? valor;

  const _CampoCheck({
    required this.label,
    required this.encontrado,
    required this.path,
    required this.valor,
  });
}

class _CheckTile extends StatelessWidget {
  final _CampoCheck check;
  const _CheckTile({required this.check});

  @override
  Widget build(BuildContext context) {
    final color =
        check.encontrado ? AppColors.success : AppColors.warning;
    final icon =
        check.encontrado ? Icons.check_circle : Icons.cancel_outlined;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      check.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      check.path,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                if (check.valor != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    check.valor!,
                    style: AppType.label.copyWith(color: color),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// JSON VIEWER (con copy-to-clipboard)
// =============================================================================

class _JsonViewer extends StatefulWidget {
  final VolvoDiagnostico diag;
  const _JsonViewer({required this.diag});

  @override
  State<_JsonViewer> createState() => _JsonViewerState();
}

class _JsonViewerState extends State<_JsonViewer> {
  // Controller propio: el Scrollbar no puede usar el PrimaryScrollController
  // porque vivimos dentro de un Container con altura fija (el ListView padre
  // ya consumió el primary). Necesitamos uno dedicado para que Scrollbar
  // y SingleChildScrollView estén ligados al mismo viewport.
  final ScrollController _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String get _jsonFormateado {
    final body = widget.diag.rawBody;
    if (body == null) return '(sin body)';
    try {
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(body);
    } catch (_) {
      return body.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    final json = _jsonFormateado;
    return AppCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'JSON CRUDO',
                style: TextStyle(
                  color: AppColors.success,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.copy,
                    color: AppColors.success, size: 18),
                tooltip: 'Copiar al portapapeles',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: json));
                  if (context.mounted) {
                    AppFeedback.success(context, 'JSON copiado al portapapeles');
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // El JSON puede ser largo: contenedor con altura limitada y
          // scroll independiente para que no rompa la pantalla.
          Container(
            constraints: const BoxConstraints(maxHeight: 380),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(150),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: Colors.white12),
            ),
            child: Scrollbar(
              controller: _ctrl,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _ctrl,
                padding: const EdgeInsets.all(AppSpacing.md),
                child: SelectableText(
                  json,
                  style: AppType.eyebrow.copyWith(color: Colors.white70, fontFamily: 'monospace', height: 1.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// BOTÓN REINTENTAR
// =============================================================================

class _BotonReintentar extends StatelessWidget {
  final VoidCallback onPressed;
  const _BotonReintentar({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return AppButton.secondary(
      label: 'Reintentar',
      icon: Icons.refresh,
      expand: true,
      onPressed: onPressed,
    );
  }
}

// =============================================================================
// HELPERS
// =============================================================================

class _Linea extends StatelessWidget {
  final String etiqueta;
  final String valor;
  final Color? valorColor;
  final bool monoespaciado;
  final bool multiline;
  final bool negrita;

  const _Linea({
    required this.etiqueta,
    required this.valor,
    this.valorColor,
    this.monoespaciado = false,
    this.multiline = false,
    this.negrita = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              etiqueta,
              style: AppType.eyebrow.copyWith(color: Colors.white54, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(
              valor,
              style: AppType.label.copyWith(color: valorColor ?? Colors.white, fontFamily: monoespaciado ? 'monospace' : null, fontWeight: negrita ? FontWeight.bold : FontWeight.normal, letterSpacing: monoespaciado ? 0.3 : 0),
              maxLines: multiline ? 5 : 1,
              overflow: multiline
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
