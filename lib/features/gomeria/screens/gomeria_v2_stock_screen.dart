import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/cubierta_modelo.dart';
import '../models/stock_movimiento.dart';
import '../services/montajes_service.dart';

/// Pantalla de STOCK del depósito — modelo nuevo (rediseño 2026-05-29). El
/// stock se lleva por CANTIDADES (no por cubiertas serializadas): cuántas hay
/// de cada modelo+vida. Permite comprar, ajustar por inventario físico (control
/// anti-robo), mandar a recapar y descartar.
class GomeriaV2StockScreen extends StatefulWidget {
  const GomeriaV2StockScreen({super.key});

  @override
  State<GomeriaV2StockScreen> createState() => _GomeriaV2StockScreenState();
}

class _GomeriaV2StockScreenState extends State<GomeriaV2StockScreen> {
  final _service = MontajesService();

  @override
  Widget build(BuildContext context) {
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
            return const Center(child: CircularProgressIndicator());
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
          return LayoutBuilder(
            builder: (_, c) {
              final ancho = c.maxWidth;
              // Mismo criterio que el hub: grilla en tablet apaisada/desktop,
              // una columna en teléfono.
              final columnas =
                  ancho >= 1200 ? 4 : ancho >= 900 ? 3 : ancho >= 600 ? 2 : 1;

              Widget skus() {
                if (columnas == 1) {
                  return Column(
                      children: [for (final s in stock) _tileSku(s)]);
                }
                const spacing = 8.0;
                final anchoTile =
                    (ancho - 24 - spacing * (columnas - 1)) / columnas;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final s in stock)
                      SizedBox(width: anchoTile, child: _tileSku(s)),
                  ],
                );
              }

              return ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.inventory_2),
                      title: const Text('Total en depósito'),
                      trailing: Text('$total',
                          style: Theme.of(context).textTheme.titleLarge),
                    ),
                  ),
                  const SizedBox(height: 8),
                  skus(),
                ],
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _comprar,
        icon: const Icon(Icons.add),
        label: const Text('Comprar'),
      ),
    );
  }

  Widget _tileSku(StockItem s) {
    final faltante = s.cantidad < 0;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: faltante ? Colors.red : null,
          child: Text('${s.cantidad}',
              style: TextStyle(color: faltante ? Colors.white : null)),
        ),
        title: Text(s.modeloEtiqueta,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(s.etiquetaVida),
        trailing: const Icon(Icons.more_vert),
        onTap: () => _acciones(s),
      ),
    );
  }

  Future<void> _acciones(StockItem s) async {
    final accion = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('${s.modeloEtiqueta} · ${s.etiquetaVida}',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            ListTile(
              leading: const Icon(Icons.fact_check_outlined),
              title: const Text('Ajustar por inventario físico'),
              onTap: () => Navigator.pop(context, 'ajuste'),
            ),
            ListTile(
              leading: const Icon(Icons.autorenew),
              title: const Text('Mandar a recapar'),
              onTap: () => Navigator.pop(context, 'recapar'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Descartar'),
              onTap: () => Navigator.pop(context, 'descartar'),
            ),
          ],
        ),
      ),
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
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('¿Qué cubierta compraste?'),
            ),
            for (final m in modelos)
              ListTile(
                title: Text('${m.marcaNombre} ${m.modelo} ${m.medida}',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(m.tipoUso.etiqueta),
                onTap: () => Navigator.pop(context, m),
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
        modeloEtiqueta: '${modelo.marcaNombre} ${modelo.modelo} ${modelo.medida}',
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
      builder: (ctx) => AlertDialog(
        title: Text(titulo, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Cantidad'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              Navigator.pop(ctx, n);
            },
            child: const Text('Aceptar'),
          ),
        ],
      ),
    );
  }
}
