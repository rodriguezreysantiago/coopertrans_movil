import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import '../models/cubierta_modelo.dart';
import '../models/estado_posicion.dart';
import '../models/montaje.dart';
import '../models/nivel_desgaste.dart';
import '../models/stock_movimiento.dart';
import '../services/montajes_service.dart';
import '../widgets/esquema_unidad_v2_view.dart';

/// Pantalla de detalle de una unidad — modelo NUEVO de gomería (rediseño
/// 2026-05-29). Muestra cada posición con su semáforo de desgaste (por km vs
/// vida de la marca) y permite montar/retirar en pocos toques. Sin serializar
/// cubiertas: lo que se monta es un modelo+vida del stock por cantidades.
class GomeriaV2UnidadScreen extends StatefulWidget {
  final String unidadId;
  final TipoUnidadCubierta unidadTipo;

  const GomeriaV2UnidadScreen({
    super.key,
    required this.unidadId,
    required this.unidadTipo,
  });

  @override
  State<GomeriaV2UnidadScreen> createState() => _GomeriaV2UnidadScreenState();
}

class _GomeriaV2UnidadScreenState extends State<GomeriaV2UnidadScreen> {
  final _service = MontajesService();

  Color _colorNivel(NivelDesgaste n) {
    switch (n) {
      case NivelDesgaste.ok:
        return Colors.green;
      case NivelDesgaste.alerta:
        return Colors.orange;
      case NivelDesgaste.critico:
        return Colors.red;
      case NivelDesgaste.sinDatos:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: widget.unidadId,
      body: StreamBuilder<List<Montaje>>(
        stream: _service.streamMontajesActivosPorUnidad(widget.unidadId),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AppErrorState(
              title: 'No se pudieron cargar las cubiertas',
              subtitle: snap.error.toString(),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final montajes = snap.data!;
          return FutureBuilder<Map<String, double?>>(
            future: _service.kmRecorridoPorPosicion(
              unidadId: widget.unidadId,
              unidadTipo: widget.unidadTipo,
              montajesActivos: montajes,
            ),
            builder: (ctx, kmSnap) {
              final kmPorPos = kmSnap.data ?? const <String, double?>{};
              final estados = construirEstadoUnidad(
                unidadTipo: widget.unidadTipo,
                montajesActivos: montajes,
                kmRecorridoPorPosicion: kmPorPos,
              );
              return _listaPosiciones(estados, montajes.length);
            },
          );
        },
      ),
    );
  }

  Widget _listaPosiciones(List<EstadoPosicion> estados, int ocupadas) {
    // Agrupar por eje para mostrar ordenado.
    final porEje = <int, List<EstadoPosicion>>{};
    for (final e in estados) {
      porEje.putIfAbsent(e.posicion.eje, () => []).add(e);
    }
    final ejes = porEje.keys.toList()..sort();

    final header = Card(
      child: ListTile(
        leading: const Icon(Icons.local_shipping),
        title: Text(
          widget.unidadTipo == TipoUnidadCubierta.tractor
              ? 'Tractor'
              : 'Enganche',
        ),
        subtitle:
            Text('$ocupadas de ${estados.length} posiciones con cubierta'),
      ),
    );

    // Esquema visual: el dibujo de la unidad con cada posición tappeable
    // (semáforo + % de vida). Tocar la rueda dispara el mismo montar/retirar
    // que el tile de la lista.
    final esquema = EsquemaUnidadV2View(
      tipo: widget.unidadTipo,
      estados: estados,
      onTapPosicion: (e) =>
          e.montaje == null ? _montar(e) : _retirar(e, e.montaje!),
    );

    const ayuda = Padding(
      padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
      child: Text(
        'Tocá una rueda en el dibujo (o un ítem de la lista) para montar o '
        'retirar. El color es el desgaste: verde OK · amarillo cerca del '
        'límite · rojo pasado · gris sin datos.',
        style: TextStyle(fontSize: 12, color: Colors.grey),
      ),
    );

    // Tiles de posiciones agrupados por eje (lista de la derecha / abajo).
    final tilesPorEje = <Widget>[
      for (final eje in ejes) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text('Eje $eje',
              style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final e in porEje[eje]!) _tilePosicion(e),
      ],
    ];

    return LayoutBuilder(
      builder: (ctx, c) {
        // Tablet apaisada: el dibujo queda FIJO a la izquierda y las posiciones
        // scrollean (poco) a la derecha → se elimina el scroll largo vertical.
        if (c.maxWidth >= 900) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                      child: header,
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: esquema,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: ayuda,
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 4,
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: tilesPorEje,
                ),
              ),
            ],
          );
        }
        // Teléfono / tablet en vertical: una sola columna scrolleable.
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            header,
            const SizedBox(height: 8),
            esquema,
            ayuda,
            const Divider(height: 24),
            ...tilesPorEje,
          ],
        );
      },
    );
  }

  Widget _tilePosicion(EstadoPosicion e) {
    final m = e.montaje;
    final pct = e.porcentajeVida;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _colorNivel(e.nivel),
          radius: 14,
          child: pct != null
              ? Text(
                  '${pct.round()}',
                  style: const TextStyle(fontSize: 10, color: Colors.white),
                )
              : const Icon(Icons.tire_repair, size: 14, color: Colors.white),
        ),
        title: Text(
          e.posicion.etiqueta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          m == null
              ? 'Vacía — tocá para montar'
              : '${m.modeloEtiqueta} · ${m.etiquetaVida}'
                  '${pct != null ? ' · ${pct.round()}% vida' : ''}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Icon(m == null ? Icons.add_circle_outline : Icons.chevron_right),
        onTap: () => m == null ? _montar(e) : _retirar(e, m),
      ),
    );
  }

  // ───────────────────────── MONTAR ─────────────────────────

  Future<void> _montar(EstadoPosicion e) async {
    // Stock disponible + modelos compatibles con el tipo de uso de la posición.
    final stock = await _service.stockActual();
    final modelosSnap = await FirebaseFirestore.instance
        .collection(AppCollections.cubiertasModelos)
        .where('activo', isEqualTo: true)
        .get();
    final modelos = {
      for (final d in modelosSnap.docs) d.id: CubiertaModelo.fromDoc(d),
    };
    // Filtrar stock por tipo de uso de la posición.
    final opciones = stock.where((s) {
      final mod = modelos[s.modeloId];
      return mod != null && mod.tipoUso == e.posicion.tipoUsoRequerido;
    }).toList();

    if (!mounted) return;
    if (opciones.isEmpty) {
      AppFeedback.error(context,
          'No hay stock ${e.posicion.tipoUsoRequerido.etiqueta} disponible para montar.');
      return;
    }

    final elegido = await showModalBottomSheet<StockItem>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Montar en ${e.posicion.etiqueta}',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final s in opciones)
              ListTile(
                leading: const Icon(Icons.tire_repair),
                title: Text('${s.modeloEtiqueta} · ${s.etiquetaVida}',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Text('${s.cantidad} en depósito'),
                onTap: () => Navigator.pop(context, s),
              ),
          ],
        ),
      ),
    );
    if (elegido == null || !mounted) return;

    final mod = modelos[elegido.modeloId]!;
    final kmVida =
        elegido.vida <= 1 ? mod.kmVidaEstimadaNueva : mod.kmVidaEstimadaRecapada;
    try {
      await _service.montar(
        unidadId: widget.unidadId,
        unidadTipo: widget.unidadTipo,
        posicion: e.posicion.codigo,
        modeloId: elegido.modeloId,
        modeloEtiqueta: elegido.modeloEtiqueta,
        tipoUso: mod.tipoUso,
        vida: elegido.vida,
        kmVidaEstimada: kmVida,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
      );
      if (mounted) AppFeedback.success(context, 'Cubierta montada.');
    } catch (err) {
      if (mounted) AppFeedback.error(context, err.toString());
    }
  }

  // ───────────────────────── RETIRAR ─────────────────────────

  Future<void> _retirar(EstadoPosicion e, Montaje m) async {
    var motivo = MotivoRetiro.desgaste;
    var destino = DestinoRetiro.deposito;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text('Retirar de ${e.posicion.etiqueta}',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Motivo'),
              DropdownButton<MotivoRetiro>(
                isExpanded: true,
                value: motivo,
                items: [
                  for (final mo in MotivoRetiro.values)
                    DropdownMenuItem(value: mo, child: Text(mo.etiqueta)),
                ],
                onChanged: (v) => setSt(() => motivo = v ?? motivo),
              ),
              const SizedBox(height: 8),
              const Text('Destino'),
              DropdownButton<DestinoRetiro>(
                isExpanded: true,
                value: destino,
                items: [
                  for (final d in DestinoRetiro.values)
                    DropdownMenuItem(value: d, child: Text(d.etiqueta)),
                ],
                onChanged: (v) => setSt(() => destino = v ?? destino),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Retirar')),
          ],
        ),
      ),
    );
    if (confirmar != true || !mounted) return;

    try {
      await _service.retirar(
        montajeId: m.id,
        motivo: motivo,
        destino: destino,
        kmRecorridos: e.porcentajeVida != null && m.kmVidaEstimada != null
            ? (e.porcentajeVida! / 100) * m.kmVidaEstimada!
            : null,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
      );
      if (mounted) AppFeedback.success(context, 'Cubierta retirada.');
    } catch (err) {
      if (mounted) AppFeedback.error(context, err.toString());
    }
  }
}
