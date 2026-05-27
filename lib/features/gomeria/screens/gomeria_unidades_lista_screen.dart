import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Lista de unidades (tractores + enganches). Tap → vista detalle de
/// la unidad con grid de posiciones para cambiar cubiertas.
///
/// Filtro arriba: TODOS / TRACTORES / ENGANCHES. Por defecto TODOS para
/// que el supervisor encuentre rápido sin pensar.
class GomeriaUnidadesListaScreen extends StatefulWidget {
  const GomeriaUnidadesListaScreen({super.key});

  @override
  State<GomeriaUnidadesListaScreen> createState() =>
      _GomeriaUnidadesListaScreenState();
}

class _GomeriaUnidadesListaScreenState
    extends State<GomeriaUnidadesListaScreen> {
  /// `null` = todos. `'TRACTOR'` = solo tractores. `'ENGANCHE'` = solo
  /// los tipos de enganche (BATEA, TOLVA, BIVUELCO, TANQUE, ACOPLADO).
  String? _filtro;

  /// Lista de TIPOs a pasar a `where('TIPO', whereIn: ...)` según el
  /// chip seleccionado. Para "TODAS" devuelve TRACTOR + todos los
  /// enganches (excluye choferes u otros TIPO no-vehículo si los hubiera).
  List<String> _tiposParaQuery() {
    if (_filtro == 'TRACTOR') return const ['TRACTOR'];
    if (_filtro == 'ENGANCHE') return AppTiposVehiculo.enganches;
    return ['TRACTOR', ...AppTiposVehiculo.enganches];
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Unidades',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
            child: Wrap(
              spacing: AppSpacing.sm,
              children: [
                _Chip(
                  label: 'TODAS',
                  seleccionado: _filtro == null,
                  onTap: () => setState(() => _filtro = null),
                ),
                _Chip(
                  label: 'TRACTORES',
                  seleccionado: _filtro == 'TRACTOR',
                  onTap: () => setState(() => _filtro = 'TRACTOR'),
                ),
                _Chip(
                  label: 'ENGANCHES',
                  seleccionado: _filtro == 'ENGANCHE',
                  onTap: () => setState(() => _filtro = 'ENGANCHE'),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              // Filtro server-side: en lugar de bajar TODA la colección
              // VEHICULOS y filtrar en cliente (que con flotas grandes
              // consume datos y bandwith), `whereIn` baja solo los tipos
              // relevantes. Soporta hasta 30 valores — TRACTOR + 5
              // enganches caben de sobra.
              stream: FirebaseFirestore.instance
                  .collection(AppCollections.vehiculos)
                  .where('TIPO', whereIn: _tiposParaQuery())
                  .snapshots(),
              builder: (ctx, snap) {
                if (snap.hasError) {
                  return AppErrorState(
                    title: 'No se pudieron cargar las unidades',
                    subtitle: snap.error.toString(),
                  );
                }
                if (snap.connectionState == ConnectionState.waiting) {
                  return const AppSkeletonList(count: 10, conAvatar: false);
                }
                final docs = snap.data?.docs ?? const [];
                final filtrados = docs.toList()
                  ..sort((a, b) => a.id.compareTo(b.id));
                if (filtrados.isEmpty) {
                  return Center(
                    child: Text(
                      'No hay unidades para este filtro.',
                      style: AppType.body
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xl),
                  itemCount: filtrados.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (_, i) {
                    final doc = filtrados[i];
                    final data = doc.data();
                    final tipo =
                        (data['TIPO'] ?? '').toString().toUpperCase();
                    final esTractor = tipo == 'TRACTOR';
                    final modelo = (data['MODELO'] ?? '').toString();
                    return AppCard(
                      onTap: () => Navigator.pushNamed(
                        context,
                        AppRoutes.adminGomeriaUnidad,
                        arguments: {
                          'unidadId': doc.id,
                          'unidadTipo': esTractor
                              ? TipoUnidadCubierta.tractor
                              : TipoUnidadCubierta.enganche,
                          'tipoVehiculo': tipo,
                          'modelo': modelo,
                        },
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md, vertical: AppSpacing.md),
                      child: Row(
                        children: [
                          Icon(
                            esTractor
                                ? Icons.local_shipping_outlined
                                : Icons.rv_hookup_outlined,
                            color: esTractor
                                ? AppColors.warning
                                : AppColors.brandSoft,
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  doc.id,
                                  style: AppType.heading,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$tipo${modelo.isNotEmpty ? " · $modelo" : ""}',
                                  style: AppType.label.copyWith(
                                      color: AppColors.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              color: AppColors.textHint),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool seleccionado;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.seleccionado,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: seleccionado,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.warning,
      labelStyle: AppType.eyebrow.copyWith(
          color: seleccionado ? Colors.black : AppColors.textPrimary),
      backgroundColor: AppColors.background,
    );
  }
}
