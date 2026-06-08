import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/choferes_service.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/icm_oficial_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Reporte del ICM **oficial de Sitrack** (lo que audita YPF) de un mes:
///   - ICM de la flota + variación vs el mes anterior (más bajo = mejor).
///   - KPIs: choferes activos, distancia total, tiempo total.
///   - Infracciones de la flota (altas / medias / leves).
///   - Distribución de choferes por severidad (pie).
///   - Top 5 peores (a abordar) + Top 5 mejores.
///
/// NOTA: el archivo/ruta se siguen llamando "reporte_semanal" por
/// compatibilidad, pero el ICM oficial es MENSUAL (Sitrack lo cierra por
/// mes). El título y los datos son mensuales.
///
/// REFACTOR NÚCLEO (jun 2026): re-estilizado SIN tocar la capa de datos.
/// El State (`_periodo`, `_future`, `_recargar`, `_offset`, `_cargar`,
/// `_ReporteData`), los reads de `ICM_OFICIAL` + Choferes/Excluidos service,
/// el `PieChart` (fl_chart envuelto, sólo se mapean colores a tokens) y la
/// navegación al detalle quedan intactos — sólo se reescribió el árbol de
/// widgets: header con hero number (ICM en `c.text`, delta semántico), KPIs e
/// infracciones en grilla de `AppStat`, severidad con leyenda `AppDot`/`AppBadge`
/// y top 5 en filas `AppCard(tier:1)` con mono tabular. La clasificación por
/// severidad NO cambia.
class IcmReporteSemanalScreen extends StatefulWidget {
  const IcmReporteSemanalScreen({super.key});

  @override
  State<IcmReporteSemanalScreen> createState() =>
      _IcmReporteSemanalScreenState();
}

enum _Periodo { mesActual, mesAnterior }

class _IcmReporteSemanalScreenState extends State<IcmReporteSemanalScreen> {
  _Periodo _periodo = _Periodo.mesActual;
  Future<_ReporteData>? _future;

  @override
  void initState() {
    super.initState();
    _recargar();
  }

  void _recargar() => _future = _cargar(_periodo);

  int get _offset => _periodo == _Periodo.mesActual ? 0 : -1;

  Future<_ReporteData> _cargar(_Periodo p) async {
    final db = FirebaseFirestore.instance;
    final excluidos = await ExcluidosService.cargar(db: db);
    final dnisChofer = await ChoferesService.cargarDnisChofer(db: db);
    excluir(String dni) =>
        ExcluidosService.esExcluido(excluidos, dni: dni) ||
        (dnisChofer != null && !dnisChofer.contains(dni));
    final idSel = IcmOficialService.periodoId(offsetMeses: _offset);
    final idPrev = IcmOficialService.periodoId(offsetMeses: _offset - 1);
    final cargados = await Future.wait([
      IcmOficialService.cargarPeriodo(db, idSel, excluirDni: excluir),
      IcmOficialService.cargarPeriodo(db, idPrev, excluirDni: excluir),
    ]);
    return _ReporteData(
      sel: cargados[0],
      prev: cargados[1],
      idSel: idSel,
      idPrev: idPrev,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Reporte ICM — Oficial',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BarraPeriodo(
            actual: _periodo,
            onChanged: (p) => setState(() {
              _periodo = p;
              _recargar();
            }),
          ),
          Expanded(
            child: FutureBuilder<_ReporteData>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const AppSkeletonList(count: 5);
                }
                if (snap.hasError) {
                  return AppErrorState(
                    title: 'No se pudo cargar el reporte',
                    subtitle: '${snap.error}',
                  );
                }
                final data = snap.data!;
                final p = data.sel;
                if (p == null || p.vacio) {
                  return AppEmptyState(
                    icon: Icons.assessment_outlined,
                    title: 'Aún no hay datos del ICM oficial de '
                        '${IcmOficialService.labelPeriodo(data.idSel)}',
                    subtitle: 'Se sincroniza una vez al día desde el portal '
                        'de Sitrack.',
                  );
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _HeaderFlota(
                        periodo: p,
                        prev: data.prev,
                        labelPrev:
                            IcmOficialService.labelPeriodo(data.idPrev),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      const AppEyebrow('Recorrido del período'),
                      const SizedBox(height: AppSpacing.sm),
                      _KpisRow(periodo: p),
                      const SizedBox(height: AppSpacing.xl),
                      const AppEyebrow('Infracciones de la flota'),
                      const SizedBox(height: AppSpacing.sm),
                      _InfraccionesFlota(periodo: p),
                      const SizedBox(height: AppSpacing.xl),
                      const AppEyebrow('Choferes por severidad'),
                      const SizedBox(height: AppSpacing.sm),
                      _PieSeveridad(periodo: p),
                      const SizedBox(height: AppSpacing.xl),
                      const AppEyebrow('Top 5 a abordar · peor ICM'),
                      const SizedBox(height: AppSpacing.sm),
                      _ListaChoferes(choferes: p.peores(5)),
                      const SizedBox(height: AppSpacing.xl),
                      const AppEyebrow('Top 5 mejores · mejor ICM'),
                      const SizedBox(height: AppSpacing.sm),
                      _ListaChoferes(choferes: p.mejores(5)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ReporteData {
  final IcmOficialPeriodo? sel;
  final IcmOficialPeriodo? prev;
  final String idSel;
  final String idPrev;
  const _ReporteData(
      {required this.sel,
      required this.prev,
      required this.idSel,
      required this.idPrev});
}

/// Color semántico de la severidad oficial Sitrack mapeado a tokens del tema.
/// Reemplaza al `colorSeveridadIcm` de hex Material. Clasificación sin cambios.
Color _colorSeveridad(BuildContext context, String severidadRaw) {
  final c = context.colors;
  switch (severidadIcmDesde(severidadRaw)) {
    case SeveridadIcm.sinInfracciones:
    case SeveridadIcm.bajo:
      return c.success;
    case SeveridadIcm.medio:
      return c.warning;
    case SeveridadIcm.alto:
      return c.error;
    case SeveridadIcm.sinActividad:
    case SeveridadIcm.desconocida:
      return c.textMuted;
  }
}

/// Cabecera con el ICM de la flota (oficial) + variación vs mes anterior.
/// Hero number en `c.text` (nunca semántico); el delta sí lleva color
/// (verde mejoró / rojo empeoró), igual que el ranking.
class _HeaderFlota extends StatelessWidget {
  final IcmOficialPeriodo periodo;
  final IcmOficialPeriodo? prev;
  final String labelPrev;

  const _HeaderFlota(
      {required this.periodo, required this.prev, required this.labelPrev});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tienePrev = prev != null && !prev!.vacio;
    final delta = tienePrev ? periodo.icmGeneral - prev!.icmGeneral : 0.0;
    final igual = delta.abs() < 0.05;
    final mejoro = delta < 0; // más bajo = mejor
    final deltaColor = !tienePrev || igual
        ? c.textMuted
        : (mejoro ? c.success : c.error);
    final deltaTxt = !tienePrev
        ? 'Sin mes anterior para comparar'
        : igual
            ? 'Sin cambios vs $labelPrev'
            : '${mejoro ? 'Mejoró' : 'Empeoró'} '
                '${delta.abs().toStringAsFixed(1)} pts vs $labelPrev '
                '(${prev!.icmGeneral.toStringAsFixed(1)})';
    final deltaIcono = !tienePrev || igual
        ? Icons.remove
        : (mejoro ? Icons.arrow_downward : Icons.arrow_upward);
    return AppCard(
      tier: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(child: AppEyebrow('ICM flota · oficial Sitrack')),
              Flexible(
                child: Text(
                  IcmOficialService.labelPeriodo(periodo.periodo),
                  textAlign: TextAlign.end,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.monoSm.copyWith(color: c.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                periodo.icmGeneral.toStringAsFixed(1),
                style: AppType.h1.copyWith(
                  color: c.text,
                  fontSize: 56,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'más bajo = mejor',
                    style: AppType.monoSm.copyWith(
                      color: c.textMuted,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Icon(deltaIcono, color: deltaColor, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  deltaTxt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                      color: deltaColor, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KpisRow extends StatelessWidget {
  final IcmOficialPeriodo periodo;
  const _KpisRow({required this.periodo});

  @override
  Widget build(BuildContext context) {
    return _StatGrid(
      cells: [
        _StatCell(
          label: 'Rankeables',
          value: '${periodo.choferesConActividad.length}',
        ),
        _StatCell(
          label: 'Distancia',
          value: AppFormatters.formatearMiles(periodo.distanciaTotalKm),
          unit: 'km',
        ),
        _StatCell(
          label: 'Tiempo',
          value: AppFormatters.formatearMiles(periodo.tiempoTotalH),
          unit: 'h',
        ),
      ],
    );
  }
}

class _InfraccionesFlota extends StatelessWidget {
  final IcmOficialPeriodo periodo;
  const _InfraccionesFlota({required this.periodo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _StatGrid(
      cells: [
        _StatCell(
          label: 'Altas',
          value: AppFormatters.formatearMiles(periodo.infraccionesAltas),
          valueColor: c.error,
        ),
        _StatCell(
          label: 'Medias',
          value: AppFormatters.formatearMiles(periodo.infraccionesMedias),
          valueColor: c.warning,
        ),
        _StatCell(
          label: 'Leves',
          value: AppFormatters.formatearMiles(periodo.infraccionesLeves),
          valueColor: c.success,
        ),
      ],
    );
  }
}

/// Grilla de N celdas de stat en bento (cada una `Expanded` → ancho acotado).
///
/// Fix 2026-06-08: el `crossAxisAlignment: stretch` requiere altura finita en
/// el padre. Dentro del SingleChildScrollView del reporte mensual eso explota
/// porque el SCSV pasa constraints verticales infinitas → "RenderBox was not
/// laid out" en loop, freezea la pantalla y spamea Sentry. Envolver en
/// `IntrinsicHeight` le da a la Row el alto del hijo más alto antes de que el
/// stretch lo distribuya — comportamiento visual idéntico, sin assert.
class _StatGrid extends StatelessWidget {
  final List<_StatCell> cells;
  const _StatGrid({required this.cells});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cells.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.sm),
            Expanded(child: cells[i]),
          ],
        ],
      ),
    );
  }
}

/// Celda de stat bento: eyebrow + número héroe (sans, tabular) con unidad mono.
/// El número va en `FittedBox(scaleDown)` para que valores largos (miles) no
/// desborden en pantallas chicas (regla anti-overflow Núcleo).
class _StatCell extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;

  /// Color del número. `null` → `c.text`. Semántico sólo en stats que lo
  /// justifican (infracciones por gravedad).
  final Color? valueColor;

  const _StatCell({
    required this.label,
    required this.value,
    this.unit,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.eyebrow.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: AppType.h4.copyWith(
                    color: valueColor ?? c.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 4),
                  Text(unit!,
                      style: AppType.monoSm.copyWith(color: c.textMuted)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Distribución de choferes con actividad por severidad. El `PieChart`
/// (fl_chart) se conserva; sólo se mapean los colores de sección a tokens del
/// tema y la leyenda pasa a `AppDot` + mono tabular.
class _PieSeveridad extends StatelessWidget {
  final IcmOficialPeriodo periodo;
  const _PieSeveridad({required this.periodo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final conteo = periodo.conteoPorSeveridad;
    final altos = conteo[SeveridadIcm.alto] ?? 0;
    final medios = conteo[SeveridadIcm.medio] ?? 0;
    final bajos = (conteo[SeveridadIcm.bajo] ?? 0) +
        (conteo[SeveridadIcm.sinInfracciones] ?? 0);
    final total = altos + medios + bajos;
    if (total == 0) {
      return AppCard(
        tier: 1,
        child: Row(
          children: [
            Icon(Icons.pie_chart_outline, size: 18, color: c.textMuted),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                'Sin choferes con actividad en el período.',
                style: AppType.body.copyWith(color: c.textSecondary),
              ),
            ),
          ],
        ),
      );
    }
    return AppCard(
      tier: 2,
      child: Row(
        children: [
          SizedBox(
            width: 132,
            height: 132,
            child: PieChart(
              PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: 28,
                sections: [
                  if (altos > 0)
                    PieChartSectionData(
                      value: altos.toDouble(),
                      color: c.error,
                      title: '$altos',
                      radius: 42,
                      titleStyle: AppType.label.copyWith(
                        color: c.bg,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  if (medios > 0)
                    PieChartSectionData(
                      value: medios.toDouble(),
                      color: c.warning,
                      title: '$medios',
                      radius: 42,
                      titleStyle: AppType.label.copyWith(
                        color: c.bg,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  if (bajos > 0)
                    PieChartSectionData(
                      value: bajos.toDouble(),
                      color: c.success,
                      title: '$bajos',
                      radius: 42,
                      titleStyle: AppType.label.copyWith(
                        color: c.bg,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _Leyenda(color: c.error, label: 'Alto', n: altos),
                const SizedBox(height: AppSpacing.sm),
                _Leyenda(color: c.warning, label: 'Medio', n: medios),
                const SizedBox(height: AppSpacing.sm),
                _Leyenda(
                    color: c.success, label: 'Bajo / sin infracc.', n: bajos),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Leyenda extends StatelessWidget {
  final Color color;
  final String label;
  final int n;
  const _Leyenda(
      {required this.color, required this.label, required this.n});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        AppDot(color, size: 8),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.body.copyWith(color: c.textSecondary),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          '$n',
          style: AppType.mono.copyWith(
            color: c.text,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// Lista de choferes de un top 5 — filas `AppCard(tier:1)` con rank/score en
/// mono tabular + `AppDot` semántico según severidad Sitrack (sin cambiar la
/// clasificación). Navega al detalle si hay DNI. Mismo lenguaje que el ranking.
class _ListaChoferes extends StatelessWidget {
  final List<IcmOficialChofer> choferes;
  const _ListaChoferes({required this.choferes});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (choferes.isEmpty) {
      return AppCard(
        tier: 1,
        child: Row(
          children: [
            Icon(Icons.person_off_outlined, size: 18, color: c.textMuted),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                'Sin choferes en este grupo.',
                style: AppType.body.copyWith(color: c.textSecondary),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      children: choferes.asMap().entries.map((e) {
        final pos = e.key + 1;
        final ch = e.value;
        final color = _colorSeveridad(context, ch.severidad);
        return AppCard(
          tier: 1,
          margin: const EdgeInsets.only(bottom: AppSpacing.sm),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.md),
          onTap: ch.tieneDni
              ? () => Navigator.pushNamed(
                    context,
                    AppRoutes.adminIcmDetalleChofer,
                    arguments: ch.dni,
                  )
              : null,
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Text(
                  '#$pos',
                  style: AppType.monoSm.copyWith(
                    color: c.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ch.nombre.isEmpty ? '(sin nombre)' : ch.nombre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body.copyWith(
                          color: c.text, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${ch.severidadLabel} · ${ch.totalInfracciones} '
                      'infracciones',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.monoSm.copyWith(color: color),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppDot(color, size: 6),
              const SizedBox(width: 6),
              Text(
                ch.icm.toStringAsFixed(1),
                style: AppType.mono.copyWith(
                  color: c.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (ch.tieneDni) ...[
                const SizedBox(width: AppSpacing.sm),
                Icon(Icons.chevron_right, size: 18, color: c.textMuted),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }
}

/// Selector de período — pills Núcleo (activo = relleno `text` sobre `bg`;
/// inactivo = borde hairline), mismo look que el ranking.
class _BarraPeriodo extends StatelessWidget {
  final _Periodo actual;
  final ValueChanged<_Periodo> onChanged;
  const _BarraPeriodo({required this.actual, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _ChipPeriodo(
            label: 'Mes actual',
            activo: actual == _Periodo.mesActual,
            onTap: () => onChanged(_Periodo.mesActual),
          ),
          _ChipPeriodo(
            label: 'Mes anterior',
            activo: actual == _Periodo.mesAnterior,
            onTap: () => onChanged(_Periodo.mesAnterior),
          ),
        ],
      ),
    );
  }
}

class _ChipPeriodo extends StatelessWidget {
  final String label;
  final bool activo;
  final VoidCallback onTap;
  const _ChipPeriodo(
      {required this.label, required this.activo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: activo ? c.text : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: activo ? null : Border.all(color: c.borderStrong),
        ),
        child: Text(
          label,
          style: AppType.label.copyWith(
            color: activo ? c.bg : c.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
