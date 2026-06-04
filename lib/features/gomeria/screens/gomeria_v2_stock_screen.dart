import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/cubierta_modelo.dart';
import '../models/stock_movimiento.dart';
import '../services/montajes_service.dart';

/// Pantalla de STOCK del depósito — modelo nuevo (rediseño 2026-05-29),
/// REFACTOR NÚCLEO (jun 2026). El stock se lleva por CANTIDADES (no por
/// cubiertas serializadas): cuántas hay de cada modelo+vida. Permite comprar,
/// ajustar por inventario físico (control anti-robo), mandar a recapar y
/// descartar.
///
/// SOLO PRESENTACIÓN: el `streamStock`, `calcularStock`, los flujos `_comprar`
/// / `_acciones` (ajustar / recapar / descartar) con sus services y el
/// `_pedirEntero` quedan intactos — sólo se reescribió el árbol de widgets a
/// tokens (`context.colors`), header eyebrow + hero number del total, tiles SKU
/// como `AppCard(tier:1)` con la cantidad en mono (faltante en `error`) y los
/// modales/diálogos re-skineados a Núcleo.
class GomeriaV2StockScreen extends StatefulWidget {
  const GomeriaV2StockScreen({super.key});

  @override
  State<GomeriaV2StockScreen> createState() => _GomeriaV2StockScreenState();
}

class _GomeriaV2StockScreenState extends State<GomeriaV2StockScreen> {
  final _service = MontajesService();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppScaffold(
      title: 'Stock de gomería',
      body: StreamBuilder<List<StockItem>>(
        stream: _service.streamStock(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AppErrorState(
              title: 'No se pudo cargar el stock',
              subtitle: snap.error.toString(),
            );
          }
          if (!snap.hasData) {
            return const AppSkeletonList(count: 6, conAvatar: false);
          }
          final stock = snap.data!;
          final total = stock.fold<int>(0, (a, s) => a + s.cantidad);
          if (stock.isEmpty) {
            return const AppEmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'Depósito vacío',
              subtitle: 'Tocá "Comprar" para cargar cubiertas al stock.',
            );
          }
          // Faltantes (cantidad negativa): señal de error de registro /
          // inventario físico pendiente. Se cuentan para el KPI.
          final faltantes = stock.where((s) => s.cantidad < 0).length;

          return LayoutBuilder(
            builder: (_, cns) {
              final ancho = cns.maxWidth;
              // Mismo criterio que el hub: grilla en tablet apaisada/desktop,
              // una columna en teléfono.
              final columnas = ancho >= 1200
                  ? 4
                  : ancho >= 900
                      ? 3
                      : ancho >= 600
                          ? 2
                          : 1;

              Widget skus() {
                if (columnas == 1) {
                  return Column(
                    children: [for (final s in stock) _TileSku(item: s, onTap: () => _acciones(s))],
                  );
                }
                const spacing = AppSpacing.md;
                final anchoTile =
                    (ancho - AppSpacing.lg * 2 - spacing * (columnas - 1)) /
                        columnas;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final s in stock)
                      SizedBox(
                        width: anchoTile,
                        child: _TileSku(item: s, onTap: () => _acciones(s)),
                      ),
                  ],
                );
              }

              return ListView(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 96),
                children: [
                  _Header(total: total, skus: stock.length, faltantes: faltantes),
                  const SizedBox(height: AppSpacing.md),
                  skus(),
                ],
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: c.brand,
        foregroundColor: c.brandFg,
        onPressed: _comprar,
        icon: const Icon(Icons.add),
        label: const Text('Comprar'),
      ),
    );
  }

  Future<void> _acciones(StockItem s) async {
    final accion = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.colors.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (sheetCtx) {
        final c = sheetCtx.colors;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SheetHeader(
                titulo: s.modeloEtiqueta,
                subtitulo: s.etiquetaVida,
              ),
              _SheetOpcion(
                icon: Icons.fact_check_outlined,
                titulo: 'Ajustar por inventario físico',
                onTap: () => Navigator.pop(sheetCtx, 'ajuste'),
              ),
              _SheetOpcion(
                icon: Icons.autorenew,
                titulo: 'Mandar a recapar',
                onTap: () => Navigator.pop(sheetCtx, 'recapar'),
              ),
              _SheetOpcion(
                icon: Icons.delete_outline,
                titulo: 'Descartar',
                iconColor: c.error,
                onTap: () => Navigator.pop(sheetCtx, 'descartar'),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        );
      },
    );
    if (accion == null || !mounted) return;

    if (accion == 'ajuste') {
      final fisico = await _pedirEntero('Cantidad contada (inventario físico)',
          inicial: s.cantidad);
      if (fisico == null || !mounted) return;
      final delta = await _service.ajustarInventario(
        modeloId: s.modeloId,
        modeloEtiqueta: s.modeloEtiqueta,
        vida: s.vida,
        cantidadFisica: fisico,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
      );
      if (mounted) {
        AppFeedback.success(
            context, delta == 0 ? 'Sin diferencias.' : 'Ajustado ($delta).');
      }
      return;
    }

    final cant = await _pedirEntero(
        accion == 'recapar' ? 'Cantidad a recapar' : 'Cantidad a descartar',
        inicial: 1);
    if (cant == null || !mounted) return;
    try {
      if (accion == 'recapar') {
        await _service.mandarARecapar(
          modeloId: s.modeloId,
          modeloEtiqueta: s.modeloEtiqueta,
          vida: s.vida,
          cantidad: cant,
          supervisorDni: PrefsService.dni,
          supervisorNombre: PrefsService.nombre,
        );
      } else {
        await _service.descartarDeDeposito(
          modeloId: s.modeloId,
          modeloEtiqueta: s.modeloEtiqueta,
          vida: s.vida,
          cantidad: cant,
          supervisorDni: PrefsService.dni,
          supervisorNombre: PrefsService.nombre,
        );
      }
      if (mounted) AppFeedback.success(context, 'Listo.');
    } catch (err) {
      if (mounted) AppFeedback.error(context, err.toString());
    }
  }

  Future<void> _comprar() async {
    final modelosSnap = await FirebaseFirestore.instance
        .collection(AppCollections.cubiertasModelos)
        .where('activo', isEqualTo: true)
        .get();
    final modelos = modelosSnap.docs.map(CubiertaModelo.fromDoc).toList();
    if (!mounted) return;
    if (modelos.isEmpty) {
      AppFeedback.error(context,
          'No hay modelos de cubierta cargados. Cargá marcas y modelos primero.');
      return;
    }
    final modelo = await showModalBottomSheet<CubiertaModelo>(
      context: context,
      backgroundColor: context.colors.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          children: [
            const _SheetHeader(titulo: 'Comprar', subtitulo: '¿Qué cubierta compraste?'),
            for (final m in modelos)
              _SheetOpcion(
                icon: Icons.tire_repair_outlined,
                titulo: '${m.marcaNombre} ${m.modelo} ${m.medida}',
                subtitulo: m.tipoUso.etiqueta,
                onTap: () => Navigator.pop(sheetCtx, m),
              ),
          ],
        ),
      ),
    );
    if (modelo == null || !mounted) return;
    final cant = await _pedirEntero('¿Cuántas compraste?', inicial: 1);
    if (cant == null || !mounted) return;
    try {
      await _service.comprar(
        modeloId: modelo.id,
        modeloEtiqueta:
            '${modelo.marcaNombre} ${modelo.modelo} ${modelo.medida}',
        cantidad: cant,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
      );
      if (mounted) AppFeedback.success(context, '$cant cubierta(s) al stock.');
    } catch (err) {
      if (mounted) AppFeedback.error(context, err.toString());
    }
  }

  Future<int?> _pedirEntero(String titulo, {required int inicial}) {
    final ctrl = TextEditingController(text: inicial.toString());
    return showDialog<int>(
      context: context,
      builder: (ctx) {
        final c = ctx.colors;
        return AlertDialog(
          backgroundColor: c.surface2,
          title: Text(titulo, maxLines: 2, overflow: TextOverflow.ellipsis),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Cantidad'),
          ),
          actions: [
            AppButton.ghost(
                label: 'Cancelar', onPressed: () => Navigator.pop(ctx)),
            AppButton(
              label: 'Aceptar',
              onPressed: () {
                final n = int.tryParse(ctrl.text.trim());
                Navigator.pop(ctx, n);
              },
            ),
          ],
        );
      },
    ).whenComplete(ctrl.dispose);
  }
}

// =============================================================================
// HEADER — eyebrow + hero number del total + KPIs (SKUs / faltantes).
// =============================================================================

class _Header extends StatelessWidget {
  final int total;
  final int skus;
  final int faltantes;
  const _Header(
      {required this.total, required this.skus, required this.faltantes});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppEyebrow('Depósito'),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$total',
                style: AppType.h2.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('cubiertas en total', style: AppType.monoSm),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          AppKpiStrip(
            stats: [
              AppStat(label: 'Modelos', value: '$skus'),
              AppStat(
                label: 'Faltantes',
                value: '$faltantes',
                accent: faltantes > 0 ? c.error : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// TILE SKU — AppCard(tier:1) con la cantidad como hero number (faltante en
// `error`), modelo + etiqueta de vida y un chevron de acciones.
// =============================================================================

class _TileSku extends StatelessWidget {
  final StockItem item;
  final VoidCallback onTap;
  const _TileSku({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final faltante = item.cantidad < 0;
    return AppCard(
      tier: 1,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          // Cantidad: hero number en tinta del texto; faltante en error.
          SizedBox(
            width: 44,
            child: Text(
              '${item.cantidad}',
              textAlign: TextAlign.center,
              style: AppType.h4.copyWith(
                color: faltante ? c.error : c.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.modeloEtiqueta,
                  style: AppType.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    AppBadge(
                      text: item.etiquetaVida,
                      color: item.esRecapada ? c.brandSoft : c.textSecondary,
                      size: AppBadgeSize.sm,
                    ),
                    if (faltante) ...[
                      const SizedBox(width: AppSpacing.sm),
                      AppBadge(
                        text: 'Faltante',
                        color: c.error,
                        dot: true,
                        size: AppBadgeSize.sm,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(Icons.more_vert, size: 18, color: c.textMuted),
        ],
      ),
    );
  }
}

// =============================================================================
// PRIMITIVAS de bottom sheet (Núcleo) — header + opción tappeable.
// =============================================================================

class _SheetHeader extends StatelessWidget {
  final String titulo;
  final String? subtitulo;
  const _SheetHeader({required this.titulo, this.subtitulo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppEyebrow(titulo),
          if (subtitulo != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitulo!,
              style: AppType.h5,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppHairline(color: c.border),
        ],
      ),
    );
  }
}

class _SheetOpcion extends StatelessWidget {
  final IconData icon;
  final String titulo;
  final String? subtitulo;
  final Color? iconColor;
  final VoidCallback onTap;

  const _SheetOpcion({
    required this.icon,
    required this.titulo,
    this.subtitulo,
    this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor ?? c.textSecondary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titulo,
                    style: AppType.body.copyWith(
                        color: iconColor ?? c.text,
                        fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitulo != null)
                    Text(
                      subtitulo!,
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
