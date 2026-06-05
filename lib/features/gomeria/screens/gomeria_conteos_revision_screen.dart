// lib/features/gomeria/screens/gomeria_conteos_revision_screen.dart
//
// Revisión de los conteos de inventario — la usa ADMIN/SUPERVISOR. Lista los
// conteos enviados por gomería y, al abrir uno, compara lo REPORTADO contra el
// stock teórico del sistema (`compararConteoVsStock`), marcando las
// diferencias. NO ajusta nada: el admin decide si corrige el stock (desde la
// pantalla de Stock) o investiga el faltante.

import 'package:flutter/material.dart';

import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/conteo_gomeria.dart';
import '../models/stock_movimiento.dart';
import '../services/conteos_service.dart';
import '../services/montajes_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

String _fechaHora(DateTime? d) {
  if (d == null) return '—';
  String dd(int n) => n.toString().padLeft(2, '0');
  return '${dd(d.day)}-${dd(d.month)}-${d.year} ${dd(d.hour)}:${dd(d.minute)}';
}

class GomeriaConteosRevisionScreen extends StatelessWidget {
  const GomeriaConteosRevisionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = ConteosService();
    return AppScaffold(
      title: 'Conteos de inventario',
      body: StreamBuilder<List<ConteoGomeria>>(
        stream: svc.streamConteos(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const AppErrorState(title: 'No se pudieron cargar los conteos');
          }
          if (!snap.hasData) return const AppLoadingState();
          final conteos = snap.data!;
          if (conteos.isEmpty) {
            return const AppEmptyState(
              icon: Icons.fact_check_outlined,
              title: 'Sin conteos todavía',
              subtitle: 'Cuando gomería envíe un conteo de inventario, aparece acá.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: conteos.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (_, i) => _FilaConteo(conteo: conteos[i]),
          );
        },
      ),
    );
  }
}

class _FilaConteo extends StatelessWidget {
  final ConteoGomeria conteo;
  const _FilaConteo({required this.conteo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _DetalleConteoScreen(conteo: conteo),
      )),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_fechaHora(conteo.creadoEn),
                    style: AppType.h5.copyWith(color: c.text)),
                const SizedBox(height: 2),
                Text(
                  '${conteo.responsableNombre} · ${conteo.totalContado} cubiertas',
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          AppBadge(
            text: conteo.revisado ? 'Revisado' : 'Pendiente',
            color: conteo.revisado ? AppColors.success : AppColors.warning,
            size: AppBadgeSize.sm,
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(Icons.chevron_right, size: 18, color: c.textMuted),
        ],
      ),
    );
  }
}

class _DetalleConteoScreen extends StatefulWidget {
  final ConteoGomeria conteo;
  const _DetalleConteoScreen({required this.conteo});

  @override
  State<_DetalleConteoScreen> createState() => _DetalleConteoScreenState();
}

class _DetalleConteoScreenState extends State<_DetalleConteoScreen> {
  final _conteosSvc = ConteosService();
  final _montajesSvc = MontajesService();
  late Future<List<StockItem>> _stockFut;
  bool _revisado = false;

  @override
  void initState() {
    super.initState();
    _stockFut = _montajesSvc.stockActual();
    _revisado = widget.conteo.revisado;
  }

  Future<void> _marcarRevisado() async {
    try {
      await _conteosSvc.marcarRevisado(widget.conteo.id, PrefsService.dni);
      if (!mounted) return;
      setState(() => _revisado = true);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Conteo marcado como revisado.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('No se pudo: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppScaffold(
      title: 'Conteo',
      body: FutureBuilder<List<StockItem>>(
        future: _stockFut,
        builder: (context, snap) {
          if (snap.hasError) {
            return const AppErrorState(title: 'No se pudo cargar el stock');
          }
          if (!snap.hasData) return const AppLoadingState();
          final difs = compararConteoVsStock(widget.conteo, snap.data!);
          final conDif = difs.where((d) => d.hayDiferencia).toList();
          final faltanN =
              conDif.fold<int>(0, (a, d) => a + (d.difNuevas < 0 ? -d.difNuevas : 0) + (d.difRecapadas < 0 ? -d.difRecapadas : 0));
          final sobranN =
              conDif.fold<int>(0, (a, d) => a + (d.difNuevas > 0 ? d.difNuevas : 0) + (d.difRecapadas > 0 ? d.difRecapadas : 0));

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Text(_fechaHora(widget.conteo.creadoEn),
                  style: AppType.h4.copyWith(color: c.text)),
              const SizedBox(height: 2),
              Text(
                  '${widget.conteo.responsableNombre} · ${widget.conteo.totalContado} contadas',
                  style: AppType.monoSm.copyWith(color: c.textMuted)),
              const SizedBox(height: AppSpacing.md),

              // Resumen
              Row(
                children: [
                  _Resumen('Diferencias', '${conDif.length}',
                      conDif.isEmpty ? AppColors.success : AppColors.warning),
                  const SizedBox(width: AppSpacing.sm),
                  _Resumen('Faltan', '$faltanN',
                      faltanN > 0 ? AppColors.error : c.textMuted),
                  const SizedBox(width: AppSpacing.sm),
                  _Resumen('Sobran', '$sobranN',
                      sobranN > 0 ? AppColors.warning : c.textMuted),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),

              if (conDif.isEmpty)
                AppCard(
                  glow: true,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(children: [
                    const Icon(Icons.check_circle_outline,
                        size: 18, color: AppColors.success),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text('Todo cuadra: lo contado coincide con el sistema.',
                          style: AppType.bodySm.copyWith(color: c.textSecondary)),
                    ),
                  ]),
                )
              else ...[
                Text('CON DIFERENCIA',
                    style: AppType.eyebrow.copyWith(
                        color: AppColors.error, letterSpacing: 1.2)),
                const SizedBox(height: AppSpacing.sm),
                ...conDif.map((d) => _FilaDif(dif: d)),
              ],

              // El resto (sin diferencia) plegado abajo, por completitud.
              if (difs.length > conDif.length) ...[
                const SizedBox(height: AppSpacing.lg),
                Text('SIN DIFERENCIA',
                    style: AppType.eyebrow.copyWith(
                        color: c.textMuted, letterSpacing: 1.2)),
                const SizedBox(height: AppSpacing.sm),
                ...difs.where((d) => !d.hayDiferencia).map((d) => _FilaDif(dif: d)),
              ],

              const SizedBox(height: AppSpacing.xl),
              AppButton(
                label: _revisado ? 'Revisado' : 'Marcar como revisado',
                icon: _revisado ? Icons.check : Icons.fact_check_outlined,
                expand: true,
                onPressed: _revisado ? null : _marcarRevisado,
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
          );
        },
      ),
    );
  }
}

class _FilaDif extends StatelessWidget {
  final DiferenciaConteo dif;
  const _FilaDif({required this.dif});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        tier: 1,
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dif.modeloEtiqueta,
                style: AppType.bodySm.copyWith(color: c.text),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: AppSpacing.xs),
            _LineaCond(
                cond: 'Nuevas',
                reportado: dif.reportadoNuevas,
                teorico: dif.teoricoNuevas,
                dif: dif.difNuevas),
            _LineaCond(
                cond: 'Recapadas',
                reportado: dif.reportadoRecapadas,
                teorico: dif.teoricoRecapadas,
                dif: dif.difRecapadas),
          ],
        ),
      ),
    );
  }
}

class _LineaCond extends StatelessWidget {
  final String cond;
  final int reportado;
  final int teorico;
  final int dif;
  const _LineaCond({
    required this.cond,
    required this.reportado,
    required this.teorico,
    required this.dif,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = dif == 0
        ? c.textMuted
        : (dif < 0 ? AppColors.error : AppColors.warning);
    final difTxt = dif == 0 ? '✓' : (dif > 0 ? '+$dif' : '$dif');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text(cond,
                style: AppType.monoSm.copyWith(color: c.textMuted)),
          ),
          Expanded(
            child: Text('contó $reportado · sistema $teorico',
                style: AppType.monoSm.copyWith(color: c.textSecondary)),
          ),
          Text(difTxt,
              style: AppType.monoSm
                  .copyWith(color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _Resumen extends StatelessWidget {
  final String label;
  final String valor;
  final Color color;
  const _Resumen(this.label, this.valor, this.color);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Column(
          children: [
            Text(valor,
                style: AppType.h4.copyWith(color: color, fontWeight: FontWeight.bold)),
            Text(label.toUpperCase(),
                style: AppType.eyebrow.copyWith(color: c.textMuted, fontSize: 9),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}
