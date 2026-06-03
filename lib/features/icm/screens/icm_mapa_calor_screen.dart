import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/constants/map_constants.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/icm_oficial_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
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
///
/// REFACTOR NÚCLEO (jun 2026): re-estilizado SIN tocar la capa de datos.
/// El State (`_periodo`, `_future`, `_mapCtrl`, `_recargar`, `_centrarEn`), el
/// read de `ICM_OFICIAL`, el orden de hotspots y la estructura de `FlutterMap`
/// (TileLayer + CircleLayer + MarkerLayer tappeable) quedan intactos — sólo se
/// reescribió la presentación: chips de período pill, markers con label pill
/// Núcleo, panel/lista bento (surface1 + AppDot + AppHairline), legend y popup
/// con los widgets del sistema. La clasificación por intensidad NO cambia —
/// los colores verde/ámbar/rojo pasan de hex Material a tokens del tema.
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  return const AppLoadingState(message: 'Cargando mapa…');
                }
                if (snap.hasError) {
                  return AppErrorState(
                    title: 'No se pudo cargar el mapa',
                    subtitle: '${snap.error}',
                  );
                }
                final per = snap.data;
                final hotspots =
                    (per?.infraccionesHeatmap ?? const <HotspotInfraccion>[])
                        .toList()
                      ..sort((a, b) => b.cantidad.compareTo(a.cantidad));
                if (per == null || hotspots.isEmpty) {
                  return const AppEmptyState(
                    icon: Icons.map_outlined,
                    title: 'Sin datos del mapa de calor',
                    subtitle: 'Aún no hay hotspots para este período. Se '
                        'sincroniza una vez al día desde Sitrack.',
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
                      const AppHairline(vertical: true),
                      SizedBox(width: 360, child: lista),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(flex: 3, child: mapa),
                    const AppHairline(),
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

// ─── Helpers de intensidad ───────────────────────────────────────
//
// Clasificación SIN cambios (umbrales 0.33 / 0.66 sobre la proporción al
// máximo); sólo se mapea a tokens del tema en lugar de hex Material.
// Más infracciones = peor → rojo; pocas = verde.

Color _colorPorCantidad(BuildContext context, int n, int maxN) {
  final c = context.colors;
  final r = maxN > 0 ? n / maxN : 0.0;
  if (r >= 0.66) return c.error;
  if (r >= 0.33) return c.warning;
  return c.success;
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

  double _radioPorCantidad(int n, int maxN) {
    // Radio entre 14 y 36 según proporción al máximo.
    final r = maxN > 0 ? n / maxN : 0.0;
    return 14 + r * 22;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final maxN =
        hotspots.fold<int>(0, (a, b) => b.cantidad > a ? b.cantidad : a);
    return Stack(
      children: [
        FlutterMap(
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
                    color: _colorPorCantidad(context, h.cantidad, maxN)
                        .withValues(alpha: 0.30),
                    borderColor:
                        _colorPorCantidad(context, h.cantidad, maxN),
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
                          style: AppType.mono.copyWith(
                            color: c.text,
                            fontWeight: FontWeight.w700,
                            shadows: const [
                              Shadow(offset: Offset(0, 1), blurRadius: 3),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        // Legend al pie (qué significa cada intensidad de color) — pill
        // cristal Núcleo con dots de token semántico.
        Positioned(
          left: AppSpacing.md,
          bottom: AppSpacing.md,
          child: AppMapInfoPill(
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _LegendItem(color: c.success, label: 'Pocas'),
                _LegendItem(color: c.warning, label: 'Medias'),
                _LegendItem(color: c.error, label: 'Muchas'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _mostrarPopup(BuildContext context, HotspotInfraccion h) {
    final c = context.colors;
    final maxN =
        hotspots.fold<int>(0, (a, b) => b.cantidad > a ? b.cantidad : a);
    final color = _colorPorCantidad(context, h.cantidad, maxN);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: AppDot(color, size: 10, glow: true),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(h.infraccion,
                      style: AppType.h5.copyWith(color: c.text)),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '${h.cantidad}',
                  style: AppType.h3.copyWith(
                    color: c.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (h.ubicacion.isNotEmpty)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.place, size: 14, color: c.textMuted),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(h.ubicacion,
                        style: AppType.body.copyWith(color: c.textSecondary)),
                  ),
                ],
              ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '${h.porcentaje.toStringAsFixed(1)}% del total de infracciones '
              '· puntaje ${h.puntaje.toStringAsFixed(2)} c/u',
              style: AppType.monoSm.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Lat/Lng ${h.latitud.toStringAsFixed(5)}, '
              '${h.longitud.toStringAsFixed(5)}',
              style: AppType.monoSm.copyWith(color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ítem de la legend del mapa: dot de token + label uppercase mono.
class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppDot(color, size: 6),
        const SizedBox(width: 6),
        Text(
          label.toUpperCase(),
          style: AppType.monoSm.copyWith(
            color: c.text,
            fontSize: 10,
            letterSpacing: 0.4,
          ),
        ),
      ],
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
    final c = context.colors;
    final maxN =
        hotspots.fold<int>(0, (a, b) => b.cantidad > a ? b.cantidad : a);
    return Container(
      color: c.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
            child: AppEyebrow('Hotspots · ${hotspots.length}'),
          ),
          const AppHairline(),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              itemCount: hotspots.length,
              separatorBuilder: (_, __) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: AppHairline(color: c.border),
              ),
              itemBuilder: (ctx, i) {
                final h = hotspots[i];
                final color = _colorPorCantidad(context, h.cantidad, maxN);
                return InkWell(
                  onTap: () => onTap(h),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Cantidad con dot semántico, en bloque mono.
                        SizedBox(
                          width: 44,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AppDot(color, size: 7),
                              const SizedBox(width: AppSpacing.xs),
                              Text(
                                '${h.cantidad}',
                                style: AppType.mono.copyWith(
                                  color: c.text,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                h.infraccion,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppType.body.copyWith(
                                    color: c.text,
                                    fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${h.porcentaje.toStringAsFixed(1)}%'
                                '${h.ubicacion.isEmpty ? '' : ' · ${h.ubicacion}'}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppType.monoSm
                                    .copyWith(color: c.textMuted),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Icon(Icons.center_focus_strong,
                            size: 16, color: c.textMuted),
                      ],
                    ),
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

// ─── Filtros ─────────────────────────────────────────────────────

/// Selector de período — pills Núcleo (activo = relleno `text` sobre `bg`;
/// inactivo = borde hairline), mismo look que el ranking.
class _BarraPeriodo extends StatelessWidget {
  final _Periodo actual;
  final ValueChanged<_Periodo> onChanged;
  const _BarraPeriodo({required this.actual, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _ChipPeriodo(
            label: 'Mes actual',
            activo: actual == _Periodo.mesActual,
            onTap: () => onChanged(_Periodo.mesActual),
          ),
          _ChipPeriodo(
            label: 'Mes anterior',
            activo: actual == _Periodo.mesAnterior,
            onTap: () => onChanged(_Periodo.mesAnterior),
          ),
        ],
      ),
    );
  }
}

class _ChipPeriodo extends StatelessWidget {
  final String label;
  final bool activo;
  final VoidCallback onTap;
  const _ChipPeriodo(
      {required this.label, required this.activo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: activo ? c.text : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: activo ? null : Border.all(color: c.borderStrong),
        ),
        child: Text(
          label,
          style: AppType.label.copyWith(
            color: activo ? c.bg : c.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
