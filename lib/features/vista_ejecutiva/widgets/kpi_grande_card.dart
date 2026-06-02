// features/vista_ejecutiva/widgets/kpi_grande_card.dart
//
// REFACTOR NÚCLEO · jun 2026 — re-estilizado SIN cambiar la API pública.
//
// API conservada bit a bit: KpiGrandeCard.mes / .icm / .simple /
// .eficiencia (las 4 factories) + el constructor base con los mismos
// nombres de parámetros. Las pantallas que la consumen (icm_hub_screen,
// admin_reports_screen, vista ejecutiva, otras) NO requieren cambios.
//
// CAMBIO INTERNO:
// - Look bento Núcleo (surface2 + border hairline, sin shadow gritado).
// - Hero number a 56px Geist, color SIEMPRE c.text (white). El semántico
//   solo aparece en el chip de variación al pie.
// - Icon chip 32x32 surface3 + brand 16px en la esquina superior.
// - Eyebrow uppercase + mono 10.5px para el label.
// - Sublabel mono 10.5px textMuted.
// - Variación: chip pill con dot del semántico (ok/wn/er) + texto mono.

import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/vista_ejecutiva_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

class KpiGrandeCard extends StatelessWidget {
  final String label;
  final String valorTexto;
  final IconData icono;
  final Color color;
  final String? sublabel;
  final double? variacion;
  final String? variacionTexto;
  final bool mejorEsSubir;
  final VoidCallback? onTap;

  const KpiGrandeCard({
    super.key,
    required this.label,
    required this.valorTexto,
    required this.icono,
    required this.color,
    this.sublabel,
    this.variacion,
    this.variacionTexto,
    this.mejorEsSubir = true,
    this.onTap,
  });

  // ────────────────────────────────────────────────────────────────────
  // Factories (API pública preservada)
  // ────────────────────────────────────────────────────────────────────

  factory KpiGrandeCard.mes({
    Key? key,
    required String label,
    required KpiMes kpi,
    required IconData icono,
    required Color color,
    String? sublabel,
    bool mejorEsSubir = true,
    VoidCallback? onTap,
  }) {
    final pct = kpi.variacionPct;
    final pctTexto = pct == null
        ? null
        : (pct >= 0
            ? '+${pct.toStringAsFixed(0)}%'
            : '${pct.toStringAsFixed(0)}%');
    return KpiGrandeCard(
      key: key,
      label: label,
      valorTexto: '${kpi.actual}',
      icono: icono,
      color: color,
      sublabel: sublabel ?? 'vs mes anterior (${kpi.anterior})',
      variacion: pct,
      variacionTexto: pctTexto,
      mejorEsSubir: mejorEsSubir,
      onTap: onTap,
    );
  }

  factory KpiGrandeCard.icm({
    Key? key,
    required String label,
    required KpiIcm kpi,
    required IconData icono,
    String? sublabel,
    VoidCallback? onTap,
  }) {
    final v = kpi.variacionAbs;
    final vTexto = v == null
        ? null
        : (v >= 0 ? '+${v.toStringAsFixed(1)} pts' : '${v.toStringAsFixed(1)} pts');
    return KpiGrandeCard(
      key: key,
      label: label,
      valorTexto: kpi.actual.toStringAsFixed(1),
      icono: icono,
      // ICM oficial Sitrack: NO coloreamos el número por umbrales (la
      // flota no tiene banda de color oficial). Va en brand neutro.
      color: AppColors.brand,
      sublabel: sublabel ?? 'mes anterior · ${kpi.anterior.toStringAsFixed(1)}',
      variacion: v,
      variacionTexto: vTexto,
      mejorEsSubir: false, // ICM más bajo = mejor
      onTap: onTap,
    );
  }

  factory KpiGrandeCard.simple({
    Key? key,
    required String label,
    required KpiSimple kpi,
    required IconData icono,
    required Color color,
    String? sublabel,
    VoidCallback? onTap,
  }) {
    return KpiGrandeCard(
      key: key,
      label: label,
      valorTexto: '${kpi.valor}',
      icono: icono,
      color: color,
      sublabel: sublabel ?? kpi.sublabel,
      onTap: onTap,
    );
  }

  factory KpiGrandeCard.eficiencia({
    Key? key,
    required String label,
    required KpiEficiencia kpi,
    required IconData icono,
    VoidCallback? onTap,
  }) {
    final v = kpi.variacionAbs;
    // Variación en L/100km absolutos. BAJAR = MEJOR.
    final vTexto = v == null
        ? null
        : (v >= 0
            ? '+${v.toStringAsFixed(1)} L'
            : '${v.toStringAsFixed(1)} L');
    final sub = kpi.diasConDatosActual == 0
        ? 'sin datos en el período'
        : '${kpi.kmTotalesActual.toStringAsFixed(0)} km · promedio de ${kpi.diasConDatosActual} días';
    return KpiGrandeCard(
      key: key,
      label: label,
      valorTexto: '${kpi.litrosPor100kmActual.toStringAsFixed(1)} L/100km',
      icono: icono,
      color: AppColors.brand,
      sublabel: sub,
      variacion: v,
      variacionTexto: vTexto,
      mejorEsSubir: false, // bajar L/100km = mejor
      onTap: onTap,
    );
  }

  // ────────────────────────────────────────────────────────────────────
  // Build
  // ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return AppCard(
      tier: 2,
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ─── Eyebrow + ícono ───
          Row(
            children: [
              Expanded(
                child: AppEyebrow(label),
              ),
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: c.surface3,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(icono, size: 16, color: c.brand),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // ─── Hero number ───
          Text(
            valorTexto,
            style: AppType.h1.copyWith(
              color: c.text,
              fontSize: _heroSize(valorTexto),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),

          // ─── Sublabel ───
          if (sublabel != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              sublabel!,
              style: AppType.monoSm.copyWith(color: c.textMuted),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],

          // ─── Variación pill (al pie) ───
          if (variacionTexto != null) ...[
            const SizedBox(height: AppSpacing.md),
            _VariacionPill(
              variacion: variacion,
              texto: variacionTexto!,
              mejorEsSubir: mejorEsSubir,
            ),
          ],
        ],
      ),
    );
  }

  /// Reduce el tamaño del hero number cuando el texto es largo
  /// (ej. "32.2 L/100km") para que no se salga del card. Heurística
  /// simple: <6 chars usa 56px, <10 usa 44px, sino 32px.
  double _heroSize(String t) {
    final n = t.length;
    if (n <= 5) return 56;
    if (n <= 10) return 44;
    return 32;
  }
}

class _VariacionPill extends StatelessWidget {
  final double? variacion;
  final String texto;
  final bool mejorEsSubir;
  const _VariacionPill({
    required this.variacion,
    required this.texto,
    required this.mejorEsSubir,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Color color;
    if (variacion == null || variacion == 0) {
      color = c.textMuted;
    } else {
      final subio = variacion! > 0;
      final esBueno = (subio && mejorEsSubir) || (!subio && !mejorEsSubir);
      color = esBueno ? c.success : c.error;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            texto,
            style: AppType.monoSm.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
