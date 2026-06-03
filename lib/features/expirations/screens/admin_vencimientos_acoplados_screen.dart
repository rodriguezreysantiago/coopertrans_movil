import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
import '../widgets/vencimiento_editor_sheet.dart';
import '../widgets/vencimiento_item.dart';
import '../widgets/vencimiento_item_card.dart';

/// Auditoría de vencimientos de los enganches de la flota: bateas,
/// tolvas, bivuelcos, tanques y acoplados (legacy).
class AdminVencimientosAcopladosScreen extends StatefulWidget {
  const AdminVencimientosAcopladosScreen({super.key});

  @override
  State<AdminVencimientosAcopladosScreen> createState() =>
      _AdminVencimientosAcopladosScreenState();
}

class _AdminVencimientosAcopladosScreenState
    extends State<AdminVencimientosAcopladosScreen> {
  late final Stream<QuerySnapshot> _vehiculosStream;

  static const List<String> _tiposIncluidos = AppTiposVehiculo.enganches;

  @override
  void initState() {
    super.initState();
    // where('TIPO', 'in', ...) filtra server-side los 5 tipos de
    // enganche (BATEA/TOLVA/BIVUELCO/TANQUE/ACOPLADO). Bajamos solo
    // los enganches en vez de toda la flota. Firestore acepta hasta
    // 30 valores en `whereIn`, asi que sumar tipos nuevos a
    // AppTiposVehiculo.enganches no rompe nada.
    _vehiculosStream = FirebaseFirestore.instance
        .collection(AppCollections.vehiculos)
        .where('TIPO', whereIn: _tiposIncluidos)
        .snapshots();
  }

  List<VencimientoItem> _construirItems(QuerySnapshot snapshot) {
    final items = <VencimientoItem>[];
    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>;
      // Soft-delete: enganches dados de baja no se auditan.
      if (!AppActivo.esActivo(data)) continue;
      final tipo = (data['TIPO'] ?? '').toString().toUpperCase();
      // Defensivo: el where ya filtra server-side, pero igual chequeamos
      // por casing o nulls inconsistentes.
      if (!_tiposIncluidos.contains(tipo)) continue;

      final patente = doc.id.toUpperCase();
      // Iteramos AppVencimientos.enganche para que sumar un vencimiento
      // nuevo a esa lista lo audite automáticamente.
      for (final spec in AppVencimientos.enganche) {
        final fecha = data[spec.campoFecha]?.toString();
        if (fecha == null || fecha.isEmpty) continue;
        final campoBase = spec.campoFecha.replaceFirst('VENCIMIENTO_', '');
        final dias = AppFormatters.calcularDiasRestantes(fecha);
        items.add(VencimientoItem(
          docId: patente,
          coleccion: 'VEHICULOS',
          titulo: '$tipo - $patente',
          tipoDoc: spec.etiqueta,
          campoBase: campoBase,
          fecha: fecha,
          dias: dias,
          urlArchivo: data[spec.campoArchivo]?.toString(),
          storagePath: 'VEHICULOS_DOCS',
        ));
      }
    }

    // Inválidas (dias == null) primero: son datos corruptos a arreglar.
    final criticos = items
        .where((it) => it.dias == null || it.dias! <= 60)
        .toList()
      ..sort((a, b) {
        if (a.dias == null && b.dias == null) return 0;
        if (a.dias == null) return -1;
        if (b.dias == null) return 1;
        return a.dias!.compareTo(b.dias!);
      });
    return criticos;
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Auditoría: Acoplados',
      body: StreamBuilder<QuerySnapshot>(
        stream: _vehiculosStream,
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AppErrorState(subtitle: snap.error.toString());
          }
          if (!snap.hasData) return const AppLoadingState();

          final items = _construirItems(snap.data!);

          if (items.isEmpty) {
            return const AppEmptyState(
              icon: Icons.check_circle_outline,
              title: 'Sin vencimientos próximos en enganches',
              subtitle: 'Las bateas/tolvas tienen documentación al día.',
            );
          }

          final c = context.colors;
          final vencidos =
              items.where((it) => it.dias != null && it.dias! < 0).length;
          final en7 = items
              .where((it) => it.dias != null && it.dias! >= 0 && it.dias! <= 7)
              .length;
          final en30 = items
              .where((it) => it.dias != null && it.dias! >= 0 && it.dias! <= 30)
              .length;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AppEyebrow('Enganches · auditoría'),
                    const SizedBox(height: 4),
                    Text(
                      '${items.length} vencimientos críticos',
                      style: AppType.h3.copyWith(color: c.text),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
                child: AppKpiStrip(stats: [
                  AppStat(label: 'Críticos', value: '${items.length}'),
                  AppStat(
                    label: 'Vencidos',
                    value: '$vencidos',
                    delta: vencidos > 0 ? 'requiere acción' : null,
                    deltaColor: c.error,
                  ),
                  AppStat(label: '≤7 días', value: '$en7'),
                  AppStat(label: '≤30 días', value: '$en30'),
                ]),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 80),
                  itemCount: items.length,
                  itemBuilder: (ctx, idx) => VencimientoItemCard(
                    item: items[idx],
                    onTap: () =>
                        VencimientoEditorSheet.show(context, items[idx]),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
