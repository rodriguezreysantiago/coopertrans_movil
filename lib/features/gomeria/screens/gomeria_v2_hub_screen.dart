import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
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
              _encabezado(context, 'Tractores (${tractores.length})'),
              for (final d in tractores)
                _tileUnidad(context, d.id, d.data(),
                    TipoUnidadCubierta.tractor),
              _encabezado(context, 'Enganches (${enganches.length})'),
              for (final d in enganches)
                _tileUnidad(context, d.id, d.data(),
                    TipoUnidadCubierta.enganche),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const GomeriaHubScreen()),
                ),
                icon: const Icon(Icons.history),
                label: const Text('Ver sistema anterior (datos viejos)'),
              ),
            ],
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
