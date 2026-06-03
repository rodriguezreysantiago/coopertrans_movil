// lib/features/vehicles/screens/diagnostico_volvo_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — diagnóstico Volvo en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - el service (`VolvoApiService.diagnosticarStatus`) + `_ejecutar`,
//   - todo el análisis de campos crudos (`_analizar` → `_CampoCheck`),
//   - el copy-to-clipboard del JSON,
//   - el botón Reintentar.
//
// Herramienta de dev/soporte: investiga por qué un vehículo no devuelve
// ciertos campos (combustible, autonomía, etc.). Muestra status del request,
// chequeo de campos críticos y el JSON crudo copiable.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/volvo_api_service.dart';

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
          ? const AppLoadingState(message: 'Consultando la API de Volvo…')
          : _resultado == null
              ? const AppErrorState(title: 'Sin datos')
              : ListView(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                      AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
                  children: [
                    _Header(patente: widget.patente, vin: widget.vin),
                    const SizedBox(height: AppSpacing.mdDense),
                    _ResumenRequest(diag: _resultado!),
                    const SizedBox(height: AppSpacing.mdDense),
                    _AnalisisCampos(diag: _resultado!),
                    const SizedBox(height: AppSpacing.mdDense),
                    _JsonViewer(diag: _resultado!),
                    const SizedBox(height: AppSpacing.lg),
                    AppButton.secondary(
                      label: 'Reintentar',
                      icon: Icons.refresh,
                      full: true,
                      onPressed: _ejecutar,
                    ),
                  ],
                ),
    );
  }
}

// =============================================================================
// PRIMITIVAS NÚCLEO — sección bento + fila label/valor
// =============================================================================

/// Tarjeta de sección Núcleo: eyebrow (+ dot opcional) + contenido.
class _Seccion extends StatelessWidget {
  final String titulo;
  final Color? accentDot;
  final Widget? trailing;
  final List<Widget> children;

  const _Seccion({
    required this.titulo,
    this.accentDot,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (accentDot != null) ...[
                AppDot(accentDot!, size: 7),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(child: AppEyebrow(titulo, color: accentDot)),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ...children,
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
    final c = context.colors;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppEyebrow('DIAGNÓSTICO VOLVO'),
          const SizedBox(height: AppSpacing.md),
          Text(
            patente.toUpperCase(),
            style: AppType.h3.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            'VIN $vin',
            style: AppType.monoSm.copyWith(color: c.textMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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

  Color _statusColor(BuildContext context) {
    final c = context.colors;
    if (diag.errorMessage != null) return c.error;
    final s = diag.statusCode ?? 0;
    if (s >= 200 && s < 300) return c.success;
    if (s >= 400) return c.warning;
    return c.textMuted;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final statusColor = _statusColor(context);
    final tieneError = diag.errorMessage != null;

    return _Seccion(
      titulo: 'REQUEST',
      accentDot: statusColor,
      trailing: AppBadge(
        text: tieneError
            ? 'EXCEPCIÓN'
            : '${diag.statusCode ?? "—"}',
        color: statusColor,
        size: AppBadgeSize.sm,
      ),
      children: [
        _Linea(
          'Status',
          tieneError
              ? 'EXCEPCIÓN'
              : '${diag.statusCode ?? "—"} ${diag.statusMessage ?? ""}'.trim(),
          valorColor: statusColor,
          mono: true,
        ),
        _Linea('Tiempo', '${diag.duracion.inMilliseconds} ms', mono: true),
        _Linea('URL', diag.urlConsultada, mono: true, multiline: true),
        if (tieneError) ...[
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            tier: 1,
            accent: c.error,
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Text(
              diag.errorMessage!,
              style: AppType.mono.copyWith(color: c.error),
            ),
          ),
        ],
      ],
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
      for (final cont in subContainers)
        if (s[cont] is Map) (cont, s[cont]),
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
    final c = context.colors;
    final checks = _analizar();
    final encontrados = checks.where((x) => x.encontrado).length;
    return _Seccion(
      titulo: 'CAMPOS CRÍTICOS',
      trailing: Text(
        '$encontrados/${checks.length}',
        style: AppType.monoSm.copyWith(color: c.textMuted),
      ),
      children: [
        for (var i = 0; i < checks.length; i++) ...[
          if (i > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            const AppHairline(),
            const SizedBox(height: AppSpacing.sm),
          ],
          _CheckTile(check: checks[i]),
        ],
      ],
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
    final c = context.colors;
    final color = check.encontrado ? c.success : c.warning;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: AppDot(color, size: 7),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                check.label,
                style: AppType.body
                    .copyWith(color: c.text, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                check.path,
                style: AppType.monoSm.copyWith(color: c.textMuted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (check.valor != null) ...[
                const SizedBox(height: 4),
                Text(
                  check.valor!,
                  style: AppType.bodySm.copyWith(color: color),
                ),
              ],
            ],
          ),
        ),
      ],
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
    final c = context.colors;
    final json = _jsonFormateado;
    return _Seccion(
      titulo: 'JSON CRUDO',
      trailing: IconButton(
        icon: Icon(Icons.copy, color: c.brand, size: 18),
        tooltip: 'Copiar al portapapeles',
        visualDensity: VisualDensity.compact,
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: json));
          if (context.mounted) {
            AppFeedback.success(context, 'JSON copiado al portapapeles');
          }
        },
      ),
      children: [
        // El JSON puede ser largo: contenedor con altura limitada y
        // scroll independiente para que no rompa la pantalla.
        Container(
          constraints: const BoxConstraints(maxHeight: 380),
          decoration: BoxDecoration(
            color: c.surface1,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: c.border),
          ),
          child: Scrollbar(
            controller: _ctrl,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _ctrl,
              padding: const EdgeInsets.all(AppSpacing.md),
              child: SelectableText(
                json,
                style: AppType.monoSm.copyWith(color: c.textSecondary, height: 1.5),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// HELPERS
// =============================================================================

/// Fila label (izq) / valor (der) — Núcleo. `multiline` permite que la URL
/// del request se muestre completa.
class _Linea extends StatelessWidget {
  final String label;
  final String valor;
  final Color? valorColor;
  final bool mono;
  final bool multiline;

  const _Linea(
    this.label,
    this.valor, {
    this.valorColor,
    this.mono = false,
    this.multiline = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final valBase = mono ? AppType.mono : AppType.body;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              label,
              style: AppType.bodySm.copyWith(color: c.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 7,
            child: Text(
              valor,
              textAlign: TextAlign.right,
              style: valBase.copyWith(
                color: valorColor ?? c.text,
                fontWeight: FontWeight.w500,
              ),
              maxLines: multiline ? 6 : 1,
              overflow:
                  multiline ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
