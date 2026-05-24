import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/constants/map_constants.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/icm_oficial_service.dart';

/// Mapa de calor de infracciones — hotspots agregados por ubicación
/// cartográfica única, igual al "Mapa de calor de infracciones" de
/// Sitrack. Los popula el scraper Python (`get_top_infractions`,
/// limit=10000) y los persiste en `ICM_OFICIAL/{periodo}.infracciones_heatmap`.
///
/// UX:
/// - Mapa con un CircleMarker por hotspot, tamaño/color proporcional a
///   la cantidad de infracciones en ese punto (verde = poco, ámbar =
///   medio, rojo = mucho).
/// - Lista lateral (o debajo en mobile) con los hotspots ordenados por
///   cantidad. Tap → centra el mapa en ese hotspot.
/// - Selector de período (mes actual / anterior).
class IcmMapaCalorScreen extends StatefulWidget {
  const IcmMapaCalorScreen({super.key});

  @override
  State<IcmMapaCalorScreen> createState() => _IcmMapaCalorScreenState();
}

enum _Periodo { mesActual, mesAnterior }

class _IcmMapaCalorScreenState extends State<IcmMapaCalorScreen> {
  // Centro Argentina (Bahía Blanca/Neuquén operativos).
  static const _centroInicial = LatLng(-38.7196, -65.0);
  static const _zoomInicial = 6.0;

  _Periodo _periodo = _Periodo.mesActual;
  Future<IcmOficialPeriodo?>? _future;
  final MapController _mapCtrl = MapController();

  @override
  void initState() {
    super.initState();
    _recargar();
  }

  void _recargar() {
    final id = IcmOficialService.periodoId(
        offsetMeses: _periodo == _Periodo.mesActual ? 0 : -1);
    _future = IcmOficialService.cargarPeriodo(
        FirebaseFirestore.instance, id);
  }

  void _centrarEn(HotspotInfraccion h) {
    _mapCtrl.move(LatLng(h.latitud, h.longitud), 13);
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Mapa de calor — ICM',
      body: Column(
        children: [
          _BarraPeriodo(
            actual: _periodo,
            onChanged: (p) => setState(() {
              _periodo = p;
              _recargar();
            }),
          ),
          Expanded(
            child: FutureBuilder<IcmOficialPeriodo?>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return _MensajeCentro(
                    'Error cargando el mapa: ${snap.error}',
                    color: Colors.redAccent,
                  );
                }
                final per = snap.data;
                final hotspots =
                    (per?.infraccionesHeatmap ?? const <HotspotInfraccion>[])
                        .toList()
                      ..sort((a, b) => b.cantidad.compareTo(a.cantidad));
                if (per == null || hotspots.isEmpty) {
                  return const _MensajeCentro(
                    'Aún no hay datos del mapa de calor para este período.\n'
                    'Se sincroniza una vez al día desde Sitrack.',
                    color: Colors.white54,
                  );
                }
                final esDesktop = MediaQuery.of(context).size.width >= 900;
                final mapa = _MapaHotspots(
                  hotspots: hotspots,
                  mapCtrl: _mapCtrl,
                  onHotspotTap: _centrarEn,
                );
                final lista = _ListaHotspots(
                  hotspots: hotspots,
                  onTap: _centrarEn,
                );
                if (esDesktop) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 3, child: mapa),
                      SizedBox(width: 360, child: lista),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(flex: 3, child: mapa),
                    Expanded(flex: 2, child: lista),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Mapa ─────────────────────────────────────────────────────────

class _MapaHotspots extends StatelessWidget {
  final List<HotspotInfraccion> hotspots;
  final MapController mapCtrl;
  final ValueChanged<HotspotInfraccion> onHotspotTap;

  const _MapaHotspots({
    required this.hotspots,
    required this.mapCtrl,
    required this.onHotspotTap,
  });

  Color _colorPorCantidad(int n, int maxN) {
    final r = maxN > 0 ? n / maxN : 0.0;
    if (r >= 0.66) return Colors.red.shade600;
    if (r >= 0.33) return Colors.amber.shade700;
    return Colors.green.shade600;
  }

  double _radioPorCantidad(int n, int maxN) {
    // Radio entre 14 y 36 según proporción al máximo.
    final r = maxN > 0 ? n / maxN : 0.0;
    return 14 + r * 22;
  }

  @override
  Widget build(BuildContext context) {
    final maxN = hotspots.fold<int>(0, (a, b) => b.cantidad > a ? b.cantidad : a);
    return FlutterMap(
      mapController: mapCtrl,
      options: const MapOptions(
        initialCenter: _IcmMapaCalorScreenState._centroInicial,
        initialZoom: _IcmMapaCalorScreenState._zoomInicial,
        minZoom: 4,
        maxZoom: 18,
      ),
      children: [
        TileLayer(
          urlTemplate: MapConstants.tileUrl,
          subdomains: const ['a', 'b', 'c', 'd'],
          userAgentPackageName: 'com.vecchi.coopertrans_movil',
        ),
        CircleLayer(
          circles: [
            for (final h in hotspots)
              CircleMarker(
                point: LatLng(h.latitud, h.longitud),
                radius: _radioPorCantidad(h.cantidad, maxN),
                color: _colorPorCantidad(h.cantidad, maxN)
                    .withValues(alpha: 0.45),
                borderColor: _colorPorCantidad(h.cantidad, maxN),
                borderStrokeWidth: 2,
                useRadiusInMeter: false,
              ),
          ],
        ),
        // Markers tappeables encima del CircleLayer (los círculos no son
        // tappeables por sí mismos en flutter_map).
        MarkerLayer(
          markers: [
            for (final h in hotspots)
              Marker(
                point: LatLng(h.latitud, h.longitud),
                width: _radioPorCantidad(h.cantidad, maxN) * 2,
                height: _radioPorCantidad(h.cantidad, maxN) * 2,
                child: GestureDetector(
                  onTap: () => _mostrarPopup(context, h),
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: Text(
                      '${h.cantidad}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        shadows: [
                          Shadow(offset: Offset(0, 1), blurRadius: 2),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  void _mostrarPopup(BuildContext context, HotspotInfraccion h) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning,
                    color: _colorPorCantidad(h.cantidad, h.cantidad), size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    h.infraccion,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  '${h.cantidad}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              h.ubicacion,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text(
              '${h.porcentaje.toStringAsFixed(1)}% del total de infracciones '
              '· puntaje ${h.puntaje.toStringAsFixed(2)} c/u',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Text(
              'Lat/Lng: ${h.latitud.toStringAsFixed(5)}, '
              '${h.longitud.toStringAsFixed(5)}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Lista lateral / debajo ──────────────────────────────────────

class _ListaHotspots extends StatelessWidget {
  final List<HotspotInfraccion> hotspots;
  final ValueChanged<HotspotInfraccion> onTap;

  const _ListaHotspots({required this.hotspots, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Text(
              'HOTSPOTS (${hotspots.length})',
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: hotspots.length,
              itemBuilder: (ctx, i) {
                final h = hotspots[i];
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 14,
                    backgroundColor: _colorPorCantidad(h.cantidad,
                        hotspots.first.cantidad),
                    child: Text(
                      '${h.cantidad}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(
                    h.infraccion,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${h.porcentaje.toStringAsFixed(1)}% · ${h.ubicacion}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11),
                  ),
                  trailing: const Icon(Icons.center_focus_strong,
                      size: 18, color: Colors.white38),
                  onTap: () => onTap(h),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Color _colorPorCantidad(int n, int maxN) {
    final r = maxN > 0 ? n / maxN : 0.0;
    if (r >= 0.66) return Colors.red.shade600;
    if (r >= 0.33) return Colors.amber.shade700;
    return Colors.green.shade600;
  }
}

// ─── Filtros + helpers ───────────────────────────────────────────

class _BarraPeriodo extends StatelessWidget {
  final _Periodo actual;
  final ValueChanged<_Periodo> onChanged;
  const _BarraPeriodo({required this.actual, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            label: const Text('Mes actual'),
            selected: actual == _Periodo.mesActual,
            onSelected: (_) => onChanged(_Periodo.mesActual),
          ),
          ChoiceChip(
            label: const Text('Mes anterior'),
            selected: actual == _Periodo.mesAnterior,
            onSelected: (_) => onChanged(_Periodo.mesAnterior),
          ),
        ],
      ),
    );
  }
}

class _MensajeCentro extends StatelessWidget {
  final String texto;
  final Color color;
  const _MensajeCentro(this.texto, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          texto,
          textAlign: TextAlign.center,
          style: TextStyle(color: color, fontSize: 14, height: 1.4),
        ),
      ),
    );
  }
}
