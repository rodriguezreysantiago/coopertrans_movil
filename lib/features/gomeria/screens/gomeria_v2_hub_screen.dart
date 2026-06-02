import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import 'gomeria_hub_screen.dart';
import 'gomeria_v2_stock_screen.dart';
import 'gomeria_v2_unidad_screen.dart';

/// Hub del modelo NUEVO de gomería (rediseño 2026-05-29): acceso al stock del
/// depósito y a las unidades (tap → detalle con el semáforo de cada posición).
/// Convive con el módulo viejo hasta migrar.
class GomeriaV2HubScreen extends StatelessWidget {
  const GomeriaV2HubScreen({super.key});

  static bool _esEnganche(String tipo) =>
      RegExp(r'BATEA|TOLVA|TANQUE|ENGAN|ACOPL', caseSensitive: false)
          .hasMatch(tipo);

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Gomería (nueva)',
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection(AppCollections.vehiculos)
            .snapshots(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AppErrorState(
              title: 'No se pudieron cargar las unidades',
              subtitle: snap.error.toString(),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs
            ..sort((a, b) => a.id.compareTo(b.id));
          final tractores = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
          final enganches = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
          for (final d in docs) {
            final tipo = (d.data()['TIPO'] ?? '').toString();
            (_esEnganche(tipo) ? enganches : tractores).add(d);
          }

          return LayoutBuilder(
            builder: (_, c) {
              final ancho = c.maxWidth;
              // Grilla cuando hay ancho (tablet apaisada / desktop); en teléfono
              // queda 1 columna como antes. Evita el scroll eterno de 127 tiles.
              final columnas =
                  ancho >= 1200 ? 4 : ancho >= 900 ? 3 : ancho >= 600 ? 2 : 1;

              Widget grilla(
                List<QueryDocumentSnapshot<Map<String, dynamic>>> unidades,
                TipoUnidadCubierta tipo,
              ) {
                if (columnas == 1) {
                  return Column(
                    children: [
                      for (final d in unidades)
                        _tileUnidad(context, d.id, d.data(), tipo),
                    ],
                  );
                }
                const spacing = 8.0;
                final anchoTile =
                    (ancho - 24 - spacing * (columnas - 1)) / columnas;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final d in unidades)
                      SizedBox(
                        width: anchoTile,
                        child: _tileUnidad(context, d.id, d.data(), tipo),
                      ),
                  ],
                );
              }

              return ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: ListTile(
                      leading: const Icon(Icons.inventory_2),
                      title: const Text('Stock del depósito'),
                      subtitle: const Text('Comprar, recapar, inventario'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const GomeriaV2StockScreen()),
                      ),
                    ),
                  ),
                  // Catálogo de modelos (marca + medida + km de vida). Solo
                  // ADMIN: el gomero opera con los modelos ya cargados. La ruta
                  // también está protegida con RoleGuard(admin) en el router.
                  if (PrefsService.rol == AppRoles.admin)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.category_outlined),
                        title: const Text('Marcas y modelos'),
                        subtitle: const Text(
                            'Agregar o dar de baja modelos de cubierta'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pushNamed(
                            context, AppRoutes.adminGomeriaMarcasModelos),
                      ),
                    ),
                  _encabezado(context, 'Tractores (${tractores.length})'),
                  grilla(tractores, TipoUnidadCubierta.tractor),
                  _encabezado(context, 'Enganches (${enganches.length})'),
                  grilla(enganches, TipoUnidadCubierta.enganche),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const GomeriaHubScreen()),
                    ),
                    icon: const Icon(Icons.history),
                    label: const Text('Ver sistema anterior (datos viejos)'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _encabezado(BuildContext context, String texto) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
        child: Text(texto, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _tileUnidad(BuildContext context, String id,
      Map<String, dynamic> data, TipoUnidadCubierta tipo) {
    final marca = (data['MARCA'] ?? '').toString();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        leading: Icon(tipo == TipoUnidadCubierta.tractor
            ? Icons.local_shipping
            : Icons.rv_hookup),
        title: Text(id, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: marca.isEmpty
            ? null
            : Text(marca, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                GomeriaV2UnidadScreen(unidadId: id, unidadTipo: tipo),
          ),
        ),
      ),
    );
  }
}
