import 'package:coopertrans_movil/shared/constants/app_colors.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/choferes_service.dart';
import '../../../core/services/excluidos_service.dart';
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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Mes actual'),
                  selected: _periodo == _Periodo.mesActual,
                  onSelected: (_) => setState(() {
                    _periodo = _Periodo.mesActual;
                    _recargar();
                  }),
                ),
                ChoiceChip(
                  label: const Text('Mes anterior'),
                  selected: _periodo == _Periodo.mesAnterior,
                  onSelected: (_) => setState(() {
                    _periodo = _Periodo.mesAnterior;
                    _recargar();
                  }),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<_ReporteData>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text('Error: ${snap.error}',
                          style: const TextStyle(color: AppColors.error)),
                    ),
                  );
                }
                final data = snap.data!;
                final p = data.sel;
                if (p == null || p.vacio) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        'Aún no hay datos del ICM oficial de '
                        '${IcmOficialService.labelPeriodo(data.idSel)}.\n\n'
                        'Se sincroniza una vez al día desde el portal de '
                        'Sitrack.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white54, height: 1.4),
                      ),
                    ),
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
                      const SizedBox(height: AppSpacing.lg),
                      _KpisRow(periodo: p),
                      const SizedBox(height: 20),
                      const _SeccionTitulo('Infracciones de la flota'),
                      const SizedBox(height: AppSpacing.sm),
                      _InfraccionesFlota(periodo: p),
                      const SizedBox(height: 20),
                      const _SeccionTitulo(
                          'Choferes por severidad (con actividad)'),
                      const SizedBox(height: AppSpacing.sm),
                      _PieSeveridad(periodo: p),
                      const SizedBox(height: 20),
                      const _SeccionTitulo('Top 5 a abordar (peor ICM)'),
                      const SizedBox(height: AppSpacing.sm),
                      _ListaChoferes(choferes: p.peores(5)),
                      const SizedBox(height: 20),
                      const _SeccionTitulo('Top 5 mejores (mejor ICM)'),
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

class _HeaderFlota extends StatelessWidget {
  final IcmOficialPeriodo periodo;
  final IcmOficialPeriodo? prev;
  final String labelPrev;

  const _HeaderFlota(
      {required this.periodo, required this.prev, required this.labelPrev});

  @override
  Widget build(BuildContext context) {
    final tienePrev = prev != null && !prev!.vacio;
    final delta = tienePrev ? periodo.icmGeneral - prev!.icmGeneral : 0.0;
    final igual = delta.abs() < 0.05;
    final mejoro = delta < 0; // más bajo = mejor
    final deltaColor = !tienePrev || igual
        ? Colors.white54
        : (mejoro ? AppColors.success : AppColors.error);
    final deltaTxt = !tienePrev
        ? 'Sin mes anterior para comparar'
        : igual
            ? 'Sin cambios vs $labelPrev'
            : '${mejoro ? '▼' : '▲'} ${delta.abs().toStringAsFixed(1)} pts '
                'vs $labelPrev (${prev!.icmGeneral.toStringAsFixed(1)})';
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  periodo.icmGeneral.toStringAsFixed(1),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                    height: 1.0,
                  ),
                ),
                Text('ICM flota (oficial)',
                    style: AppType.eyebrow.copyWith(color: Colors.white60)),
              ],
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    IcmOficialService.labelPeriodo(periodo.periodo),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    deltaTxt,
                    textAlign: TextAlign.end,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.label.copyWith(color: deltaColor, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  const Text('más bajo = mejor',
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                          fontStyle: FontStyle.italic)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KpisRow extends StatelessWidget {
  final IcmOficialPeriodo periodo;
  const _KpisRow({required this.periodo});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Kpi(
          label: 'Choferes rankeables',
          valor: '${periodo.choferesConActividad.length}',
        ),
        const SizedBox(width: AppSpacing.sm),
        _Kpi(
          label: 'Distancia',
          valor: '${AppFormatters.formatearMiles(periodo.distanciaTotalKm)} km',
        ),
        const SizedBox(width: AppSpacing.sm),
        _Kpi(
          label: 'Tiempo',
          valor: '${AppFormatters.formatearMiles(periodo.tiempoTotalH)} h',
        ),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  final String label;
  final String valor;
  const _Kpi({required this.label, required this.valor});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AppCard(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: AppSpacing.xs),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(valor,
                    style: AppType.heading.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfraccionesFlota extends StatelessWidget {
  final IcmOficialPeriodo periodo;
  const _InfraccionesFlota({required this.periodo});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Kpi(
            label: 'Altas',
            valor: AppFormatters.formatearMiles(periodo.infraccionesAltas)),
        const SizedBox(width: AppSpacing.sm),
        _Kpi(
            label: 'Medias',
            valor: AppFormatters.formatearMiles(periodo.infraccionesMedias)),
        const SizedBox(width: AppSpacing.sm),
        _Kpi(
            label: 'Leves',
            valor: AppFormatters.formatearMiles(periodo.infraccionesLeves)),
      ],
    );
  }
}

class _PieSeveridad extends StatelessWidget {
  final IcmOficialPeriodo periodo;
  const _PieSeveridad({required this.periodo});

  @override
  Widget build(BuildContext context) {
    final c = periodo.conteoPorSeveridad;
    final altos = c[SeveridadIcm.alto] ?? 0;
    final medios = c[SeveridadIcm.medio] ?? 0;
    final bajos = (c[SeveridadIcm.bajo] ?? 0) +
        (c[SeveridadIcm.sinInfracciones] ?? 0);
    final total = altos + medios + bajos;
    if (total == 0) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: Text('Sin choferes con actividad en el período',
              style: TextStyle(color: Colors.white54)),
        ),
      );
    }
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            SizedBox(
              width: 150,
              height: 150,
              child: PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 30,
                  sections: [
                    if (altos > 0)
                      PieChartSectionData(
                        value: altos.toDouble(),
                        color: Colors.red.shade600,
                        title: '$altos',
                        radius: 48,
                        titleStyle: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold),
                      ),
                    if (medios > 0)
                      PieChartSectionData(
                        value: medios.toDouble(),
                        color: Colors.amber.shade700,
                        title: '$medios',
                        radius: 48,
                        titleStyle: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold),
                      ),
                    if (bajos > 0)
                      PieChartSectionData(
                        value: bajos.toDouble(),
                        color: Colors.green.shade600,
                        title: '$bajos',
                        radius: 48,
                        titleStyle: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _Leyenda(color: Colors.red.shade600, label: 'Alto', n: altos),
                const SizedBox(height: 6),
                _Leyenda(
                    color: Colors.amber.shade700, label: 'Medio', n: medios),
                const SizedBox(height: 6),
                _Leyenda(
                    color: Colors.green.shade600,
                    label: 'Bajo / sin infracc.',
                    n: bajos),
              ],
            ),
          ],
        ),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text('$label: $n',
            style: AppType.label.copyWith(color: Colors.white70)),
      ],
    );
  }
}

class _ListaChoferes extends StatelessWidget {
  final List<IcmOficialChofer> choferes;
  const _ListaChoferes({required this.choferes});

  @override
  Widget build(BuildContext context) {
    if (choferes.isEmpty) {
      return const SizedBox(
        height: 50,
        child: Center(
          child: Text('Sin choferes en este grupo',
              style: TextStyle(color: Colors.white54)),
        ),
      );
    }
    return Column(
      children: choferes.asMap().entries.map((e) {
        final pos = e.key + 1;
        final c = e.value;
        final color = colorSeveridadIcm(c.severidad);
        return Card(
          elevation: 1,
          margin: const EdgeInsets.symmetric(vertical: 3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(color: color.withValues(alpha: 0.40), width: 1),
          ),
          child: ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 16,
              backgroundColor: color,
              child: Text('$pos',
                  style: AppType.label.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            title: Text(
              c.nombre.isEmpty ? '(sin nombre)' : c.nombre,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.body.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${c.severidadLabel} · ${c.totalInfracciones} infracciones',
              style: AppType.eyebrow.copyWith(color: Colors.white54),
            ),
            trailing: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                c.icm.toStringAsFixed(1),
                style: AppType.body.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            onTap: c.tieneDni
                ? () => Navigator.pushNamed(
                      context,
                      AppRoutes.adminIcmDetalleChofer,
                      arguments: c.dni,
                    )
                : null,
          ),
        );
      }).toList(),
    );
  }
}

class _SeccionTitulo extends StatelessWidget {
  final String texto;
  const _SeccionTitulo(this.texto);

  @override
  Widget build(BuildContext context) {
    return Text(
      texto,
      style: AppType.body.copyWith(color: Colors.white, fontWeight: FontWeight.w600, letterSpacing: 0.3),
    );
  }
}
